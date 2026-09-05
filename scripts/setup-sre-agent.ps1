<#
.SYNOPSIS
  Prepare and validate the Azure Monitor Demo Lab for an Azure SRE Agent trial.

.DESCRIPTION
  Azure SRE Agent creation and trial activation currently happen in the SRE Agent
  portal. This script validates the deployed lab, prints the guided portal steps,
  and checks the agent user-assigned managed identity after creation.

  By default, the script is read-only. Use -GrantMissingRoles with an agent
  principal ID to add the documented minimum roles after explicit confirmation.

.PARAMETER SubscriptionId
  Subscription containing the lab. Defaults to .azure-target.json or
  lab.config.json when available.

.PARAMETER ResourceGroup
  Resource group containing the lab. Defaults to lab.config.json or
  rg-azure-monitor-lab.

.PARAMETER AgentPrincipalId
  Object (principal) ID of the SRE Agent user-assigned managed identity.

.PARAMETER GrantMissingRoles
  Grant any missing documented SRE Agent roles. Without this switch the script
  only reports role status.

.PARAMETER Yes
  Skip the GRANT confirmation when used with -GrantMissingRoles.

.EXAMPLE
  ./scripts/setup-sre-agent.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>

.EXAMPLE
  ./scripts/setup-sre-agent.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group> `
    -AgentPrincipalId <object-id>
#>
[CmdletBinding()]
param(
  [string] $SubscriptionId,
  [string] $ResourceGroup,
  [string] $AgentPrincipalId,
  [switch] $GrantMissingRoles,
  [switch] $Yes
)

$ErrorActionPreference = 'Stop'
$sreAgentLocation = 'swedencentral'

function Write-Step($Message) {
  Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Check($Label, $Passed, $Detail) {
  $status = if ($Passed) { 'PASS' } else { 'WARN' }
  $color = if ($Passed) { 'Green' } else { 'Yellow' }
  Write-Host ("  [{0}] {1}: {2}" -f $status, $Label, $Detail) -ForegroundColor $color
}

if ($GrantMissingRoles -and [string]::IsNullOrWhiteSpace($AgentPrincipalId)) {
  throw '-GrantMissingRoles requires -AgentPrincipalId.'
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw 'Azure CLI is required. Install it and run az login before continuing.'
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$labConfigPath = Join-Path $repoRoot 'lab.config.json'
$targetPath = Join-Path $repoRoot '.azure-target.json'
$labConfig = if (Test-Path $labConfigPath) { Get-Content -Raw $labConfigPath | ConvertFrom-Json } else { $null }
$target = if (Test-Path $targetPath) { Get-Content -Raw $targetPath | ConvertFrom-Json } else { $null }

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
  if ($target -and -not [string]::IsNullOrWhiteSpace($target.expectedSubscriptionId)) {
    $SubscriptionId = $target.expectedSubscriptionId
  } elseif ($labConfig -and -not [string]::IsNullOrWhiteSpace($labConfig.subscriptionId)) {
    $SubscriptionId = $labConfig.subscriptionId
  }
}
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
  throw 'Pass -SubscriptionId or configure it in lab.config.json.'
}

if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
  $ResourceGroup = if ($labConfig -and -not [string]::IsNullOrWhiteSpace($labConfig.resourceGroup)) {
    $labConfig.resourceGroup
  } else {
    'rg-azure-monitor-lab'
  }
}

Write-Step "Pinning Azure CLI to subscription $SubscriptionId"
az account set --subscription $SubscriptionId | Out-Null
$activeAccount = az account show --query '{id:id,tenantId:tenantId,name:name}' -o json | ConvertFrom-Json
if ($activeAccount.id -ne $SubscriptionId) {
  throw "BLOCKED: active subscription is $($activeAccount.id), expected $SubscriptionId."
}
if ($target -and $target.expectedSubscriptionId -eq $SubscriptionId -and
    -not [string]::IsNullOrWhiteSpace($target.expectedTenantId) -and
    $activeAccount.tenantId -ne $target.expectedTenantId) {
  throw "BLOCKED: active tenant is $($activeAccount.tenantId), expected $($target.expectedTenantId)."
}
Write-Host "  Subscription: $($activeAccount.name) ($($activeAccount.id))" -ForegroundColor Green

Write-Step "Checking SRE Agent prerequisites in $ResourceGroup"
Write-Check 'SRE Agent region policy' $true "$sreAgentLocation (hard pinned)"
$resourceGroupDetails = az group show --subscription $SubscriptionId --name $ResourceGroup -o json 2>$null | ConvertFrom-Json
if (-not $resourceGroupDetails) {
  throw "Resource group '$ResourceGroup' was not found in subscription '$SubscriptionId'."
}

$resources = @(az resource list --subscription $SubscriptionId --resource-group $ResourceGroup -o json | ConvertFrom-Json)
$requiredTypes = @(
  @{ Label = 'Log Analytics workspace'; Type = 'microsoft.operationalinsights/workspaces' }
  @{ Label = 'Application Insights'; Type = 'microsoft.insights/components' }
  @{ Label = 'App Service'; Type = 'microsoft.web/sites' }
  @{ Label = 'AKS'; Type = 'microsoft.containerservice/managedclusters' }
)
foreach ($requiredType in $requiredTypes) {
  $resourceNames = [System.Collections.Generic.List[string]]::new()
  foreach ($resource in $resources) {
    if ($resource.type.ToLowerInvariant() -eq $requiredType.Type) {
      $resourceNames.Add($resource.name)
    }
  }
  Write-Check $requiredType.Label ($resourceNames.Count -gt 0) ($(if ($resourceNames.Count -gt 0) { ($resourceNames -join ', ') } else { 'not found' }))
}

$alertTypes = @(
  'microsoft.insights/metricalerts'
  'microsoft.insights/scheduledqueryrules'
  'microsoft.insights/activitylogalerts'
)
$alerts = @($resources | Where-Object { $alertTypes -contains $_.type.ToLowerInvariant() })
Write-Check 'Azure Monitor alert rules' ($alerts.Count -gt 0) ("{0} rule(s) found" -f $alerts.Count)

if (-not [string]::IsNullOrWhiteSpace($AgentPrincipalId)) {
  Write-Step "Checking SRE Agent managed identity roles"
  $subscriptionScope = "/subscriptions/$SubscriptionId"
  $resourceGroupScope = "$subscriptionScope/resourceGroups/$ResourceGroup"
  $requiredRoles = @(
    @{ Role = 'Reader'; Scope = $resourceGroupScope }
    @{ Role = 'Log Analytics Reader'; Scope = $resourceGroupScope }
    @{ Role = 'Monitoring Reader'; Scope = $resourceGroupScope }
    @{ Role = 'Monitoring Contributor'; Scope = $subscriptionScope }
  )

  $missingRoles = [System.Collections.Generic.List[object]]::new()
  foreach ($requiredRole in $requiredRoles) {
    $assignments = @(az role assignment list --subscription $SubscriptionId --assignee-object-id $AgentPrincipalId `
      --scope $requiredRole.Scope --include-inherited -o json | ConvertFrom-Json)
    $present = @($assignments | Where-Object { $_.roleDefinitionName -eq $requiredRole.Role }).Count -gt 0
    Write-Check $requiredRole.Role $present $requiredRole.Scope
    if (-not $present) {
      $missingRoles.Add($requiredRole)
    }
  }

  if ($GrantMissingRoles -and $missingRoles.Count -gt 0) {
    if (-not $Yes) {
      Write-Host "`nThe script will create $($missingRoles.Count) role assignment(s) for $AgentPrincipalId." -ForegroundColor Yellow
      $confirmation = Read-Host "Type GRANT to continue"
      if ($confirmation -cne 'GRANT') {
        throw 'Role assignment cancelled.'
      }
    }

    foreach ($missingRole in $missingRoles) {
      Write-Host "  Granting $($missingRole.Role) at $($missingRole.Scope)"
      az role assignment create --subscription $SubscriptionId --assignee-object-id $AgentPrincipalId `
        --assignee-principal-type ServicePrincipal --role $missingRole.Role --scope $missingRole.Scope -o none
    }
  } elseif ($missingRoles.Count -gt 0) {
    Write-Host "`n  Rerun with -GrantMissingRoles after reviewing the scopes above." -ForegroundColor Yellow
  } else {
    Write-Host "`n  All documented SRE Agent roles are present." -ForegroundColor Green
  }
}

Write-Step 'Complete the trial setup in the Azure SRE Agent portal'
Write-Host '  1. Open https://sre.azure.com and create a new agent.'
Write-Host '  2. Confirm the 30-day trial banner before creating the agent.'
Write-Host "  3. Select Sweden Central ($sreAgentLocation). This lab does not support another SRE Agent region."
Write-Host "  4. Add resource group '$ResourceGroup' with Reader permission level."
Write-Host '  5. In Builder > Incident platform, connect Azure Monitor and save.'
Write-Host '  6. Delete the generated quickstart response plan before adding the lab plans.'
Write-Host '  7. Keep the lab response plans in Review mode for the first runs.'
Write-Host "`nTrial note: baseline always-on charges are waived for 30 days, but active Azure Agent Unit usage is billed." -ForegroundColor Yellow
Write-Host 'See docs/STAGE-SRE-AGENT.md for the custom agent instructions, response plans, and demo flow.'