<#
.SYNOPSIS
  Deploy the Azure Monitor Demo Lab.

.DESCRIPTION
  1. Creates the resource group (if missing).
  2. Deploys infra/main.bicep at RG scope (LAW x2, App Insights, AMW, VNet, VMs, AKS,
     Grafana, App Service, Action Group, Alerts, Diagnostic-Settings Policies,
     Saved Queries, Workbook).
  3. Calls post-deploy.ps1 to:
       - Push the .NET hello-world sample to the App Service (auto-instrumented App Insights)
       - Wire kubectl to AKS
       - Apply the K8s frontend + k6 load generator (pointing at the App Service URL)

.PARAMETER ResourceGroup
  Resource group name. Created if it does not already exist; reused if it does.
  Precedence: explicit -ResourceGroup > lab.config.json 'resourceGroup' > default 'rg-azure-monitor-lab'.

.PARAMETER Location
  Region. Precedence: explicit -Location > lab.config.json 'location' > default 'swedencentral'.

.PARAMETER ParametersFile
  Bicep parameters file. Defaults to infra/main.parameters.json.

.EXAMPLE
  ./scripts/deploy.ps1

.EXAMPLE
  ./scripts/deploy.ps1 -ResourceGroup rg-my-lab -Location westeurope
#>

[CmdletBinding()]
param(
  [string] $ResourceGroup  = 'rg-azure-monitor-lab',
  [string] $Location       = 'swedencentral',
  [string] $ParametersFile = (Join-Path $PSScriptRoot '..' 'infra' 'main.parameters.json')
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
  Write-Host "`n==> $msg" -ForegroundColor Cyan
}

# -------------------------------------------------------------------
# Materialize derived files (.azure-target.json, main.parameters.json,
# terraform/stages.tfvars) from the central lab.config.json — but only
# if the user has bootstrapped lab.config.json. Skipped silently for
# users who hand-manage the legacy per-tool files.
# -------------------------------------------------------------------
$labConfigPath = Join-Path $PSScriptRoot '..' 'lab.config.json'
if (Test-Path $labConfigPath) {
  Write-Host "==> Syncing derived config files from lab.config.json" -ForegroundColor Cyan
  & (Join-Path $PSScriptRoot 'sync-config.ps1')

  # Honor lab.config.json as the single source of truth for RG + region, but only
  # when the caller did not pass an explicit override. Precedence:
  #   explicit -ResourceGroup/-Location  >  lab.config.json  >  built-in defaults.
  $labCfg = Get-Content -Raw $labConfigPath | ConvertFrom-Json
  if (-not $PSBoundParameters.ContainsKey('ResourceGroup') -and -not [string]::IsNullOrWhiteSpace($labCfg.resourceGroup)) {
    $ResourceGroup = $labCfg.resourceGroup
  }
  if (-not $PSBoundParameters.ContainsKey('Location') -and -not [string]::IsNullOrWhiteSpace($labCfg.location)) {
    $Location = $labCfg.location
  }
}

# -------------------------------------------------------------------
# Subscription guardrail — hard-fail if not pointed at the lab sub.
# -------------------------------------------------------------------
function Assert-AllowedSubscription {
  $targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
  if (-not (Test-Path $targetFile)) { throw ".azure-target.json not found at $targetFile. Bootstrap with: Copy-Item lab.config.json.example lab.config.json; edit it; re-run this script." }
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json

  Write-Host "==> Pinning active az subscription to $($target.expectedSubscriptionName) ($($target.expectedSubscriptionId))" -ForegroundColor Cyan
  az account set --subscription $target.expectedSubscriptionId | Out-Null

  $active = az account show --query "{id:id, tenantId:tenantId, name:name}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: active sub '$($active.name)' ($($active.id), tenant $($active.tenantId)) is not the allowed lab sub ($($target.expectedSubscriptionId), tenant $($target.expectedTenantId)). Run 'az login --tenant $($target.expectedTenantId)' and retry."
  }
  if ($target.forbiddenSubscriptionIds -contains $active.id) {
    throw "BLOCKED: active sub '$($active.name)' is on the forbidden list."
  }
  Write-Host "   OK — $($active.name)" -ForegroundColor Green
}

Assert-AllowedSubscription

# 0. Sanity
Write-Step "Active subscription"
az account show --query "{name:name, id:id, tenantId:tenantId, user:user.name}" -o table

# 1. Resource group
Write-Step "Ensuring resource group $ResourceGroup in $Location"
az group create -n $ResourceGroup -l $Location --tags purpose=azure-monitor-demo-lab owner=demo-lab | Out-Null

# 1b. Resource provider registration — Health Models (preview) is not auto-registered
function Register-ResourceProvider {
  param([string] $Namespace)
  $state = az provider show -n $Namespace --query registrationState -o tsv 2>$null
  if ($state -eq 'Registered') {
    Write-Host "   $Namespace already Registered" -ForegroundColor DarkGray
    return
  }
  Write-Host "   $Namespace : state = $state, registering..." -ForegroundColor Yellow
  az provider register -n $Namespace --only-show-errors 2>$null | Out-Null
  do {
    Start-Sleep -Seconds 10
    $state = az provider show -n $Namespace --query registrationState -o tsv
    Write-Host "   $Namespace : $state" -ForegroundColor DarkGray
  } while ($state -eq 'Registering')
  if ($state -ne 'Registered') { throw "Failed to register $Namespace (final state: $state)" }
}

Write-Step "Ensuring preview resource providers are registered"
Register-ResourceProvider -Namespace 'Microsoft.CloudHealth'

# 2. Deploy
Write-Step "Deploying main.bicep (this takes 15-25 minutes — AKS + VMs + Grafana)"
$deploymentName = "amlab-$(Get-Date -Format 'yyyyMMddHHmmss')"
$mainBicep = Join-Path $PSScriptRoot '..' 'infra' 'main.bicep'

az deployment group create `
  --resource-group $ResourceGroup `
  --name $deploymentName `
  --template-file $mainBicep `
  --parameters "@$ParametersFile" `
  --parameters location=$Location `
  --output none

Write-Step "Capturing deployment outputs"
$outputsJson = az deployment group show -g $ResourceGroup -n $deploymentName --query properties.outputs -o json
$outputs = $outputsJson | ConvertFrom-Json

$webAppName       = $outputs.webAppName.value
$webAppHost       = $outputs.webAppDefaultHost.value
$aksName          = $outputs.aksName.value
$grafanaEndpoint  = $outputs.grafanaEndpoint.value
$workbookId       = $outputs.workbookId.value
$linuxVm          = $outputs.linuxVmNameOut.value
$winVm            = $outputs.windowsVmNameOut.value

# 2b. Subscription-level Activity Log -> central LAW.
#     Subscription-scope diagnostic settings cannot be deployed from RG-scope Bicep,
#     so we manage this small piece via CLI. Idempotent (create-or-update by name).
#     Without this, AzureActivity is empty in the lab LAW and scenario 43's Sentinel
#     rule has no data to fire on — see scenario 43.
#
#     Note: we use `az monitor log-analytics workspace show` (which pins a known-good
#     API version) instead of `az resource show`. `az resource show` dynamically picks
#     the highest API version the CLI knows about, which in newer CLI builds (2.85+)
#     can be a future version that hasn't shipped to all regions yet (e.g. '2026-03-01'
#     returning NoRegisteredProviderFound in swedencentral).
Write-Step "Ensuring subscription Activity Log ships to law-amlab-central (scenario 43 prereq)"
$lawArmId = az monitor log-analytics workspace show -g $ResourceGroup -n 'law-amlab-central' --query id -o tsv
$diagName = 'amlab-activity-to-law'
$existingWs = az monitor diagnostic-settings subscription list --query "value[?name=='$diagName'].workspaceId | [0]" -o tsv 2>$null
if ($existingWs -and $existingWs -eq $lawArmId) {
  Write-Host "   '$diagName' already routes Activity Log to law-amlab-central" -ForegroundColor DarkGray
} else {
  $logsJson = '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"ServiceHealth","enabled":true},{"category":"Alert","enabled":true},{"category":"Recommendation","enabled":true},{"category":"Policy","enabled":true},{"category":"Autoscale","enabled":true},{"category":"ResourceHealth","enabled":true}]'
  az monitor diagnostic-settings subscription create --name $diagName --location global --workspace $lawArmId --logs $logsJson --only-show-errors | Out-Null
  Write-Host "   '$diagName' created -> Activity Log will start landing in law-amlab-central (5-15 min latency)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Deployment outputs:" -ForegroundColor Green
Write-Host "  Web App        : https://$webAppHost"
Write-Host "  AKS            : $aksName"
Write-Host "  Grafana        : $grafanaEndpoint"
Write-Host "  Workbook id    : $workbookId"
Write-Host "  Linux VM       : $linuxVm"
Write-Host "  Windows VM     : $winVm"

# 3. Post-deploy
$postDeploy = Join-Path $PSScriptRoot 'post-deploy.ps1'
& $postDeploy -ResourceGroup $ResourceGroup -WebAppName $webAppName -AksName $aksName -WebAppHost $webAppHost

# 4. Service Group (tenant-scoped, preview) + service group member relationship.
#    Required before SLIs can be attached as extensions on the group.
Write-Step "Provisioning service group + RG member (scenario 45 prerequisite)"
$setupHm = Join-Path $PSScriptRoot 'setup-health-model.ps1'
& $setupHm -ResourceGroup $ResourceGroup

# 5. Service Level Indicators (scenario 46) — extension on the service group.
Write-Step "Provisioning demo SLIs (scenario 46)"
$setupSli = Join-Path $PSScriptRoot 'setup-slis.ps1'
& $setupSli -ResourceGroup $ResourceGroup

Write-Host "`n✅ Lab is up. See README.md for the demo flow." -ForegroundColor Green
