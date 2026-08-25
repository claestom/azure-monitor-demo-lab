<#
.SYNOPSIS
  Tear the lab down: remove monitoring dependencies, then delete the resource group.
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup = 'rg-azure-monitor-lab',
  [switch] $Yes
)
$ErrorActionPreference = 'Stop'

# Subscription guardrail
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting teardown."
  }
}

if (-not $Yes) {
  $confirm = Read-Host "About to delete RG '$ResourceGroup' and EVERYTHING in it. Type DELETE to confirm"
  if ($confirm -ne 'DELETE') { Write-Host "Aborted." -ForegroundColor Yellow; return }
}

# Remove dependencies that can prevent Azure from deleting the monitoring estate.
# The final RG deletion remains --no-wait.
Write-Host "Removing LAW replication, DCR associations, DCRs, and DCEs ..." -ForegroundColor Yellow

$workspaces = az resource list -g $ResourceGroup --resource-type Microsoft.OperationalInsights/workspaces -o json | ConvertFrom-Json
foreach ($workspace in @($workspaces)) {
  if ($workspace.properties.replication.enabled -eq $true) {
    Write-Host "  Disabling replication on $($workspace.name)" -ForegroundColor DarkGray
    az resource update --ids $workspace.id --api-version 2025-02-01 --set properties.replication.enabled=false | Out-Null
  }
}

$dcrAssociations = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionRuleAssociations -o json | ConvertFrom-Json

# Workspace and resource-scoped associations are child resources, so the RG-level
# resource list can omit them (notably the LAW microsoft-default association).
$allResources = az resource list -g $ResourceGroup -o json | ConvertFrom-Json
foreach ($resource in @($allResources)) {
  $nestedJson = az rest --method get --url "$($resource.id)/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11" 2>$null
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($nestedJson)) {
    $nested = $nestedJson | ConvertFrom-Json
    $dcrAssociations += @($nested.value)
  }
}

$associationIds = @($dcrAssociations | Where-Object { $_.id } | Select-Object -ExpandProperty id -Unique)
foreach ($associationId in $associationIds) {
  Write-Host "  Removing DCR association $associationId" -ForegroundColor DarkGray
  az resource delete --ids $associationId --api-version 2023-03-11
}

$dcrs = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionRules -o json | ConvertFrom-Json
foreach ($dcr in @($dcrs)) {
  Write-Host "  Removing DCR $($dcr.name)" -ForegroundColor DarkGray
  az resource delete --ids $dcr.id --api-version 2024-03-11
}

$dces = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionEndpoints -o json | ConvertFrom-Json
foreach ($dce in @($dces)) {
  Write-Host "  Removing DCE $($dce.name)" -ForegroundColor DarkGray
  az resource delete --ids $dce.id --api-version 2023-03-11 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "    DCE is managed by Azure; it will be removed with the LAW/RG cascade." -ForegroundColor DarkGray
  }
}

# Tear down tenant-scoped artefacts FIRST (they survive RG delete otherwise and
# end up dangling against the deleted AMW). Safe + idempotent — both helper
# scripts swallow 404s.
Write-Host "Removing demo SLIs (scenario 46) ..." -ForegroundColor Yellow
$setupSli = Join-Path $PSScriptRoot 'setup-slis.ps1'
if (Test-Path $setupSli) {
  & $setupSli -ResourceGroup $ResourceGroup -Teardown
}

Write-Host "Removing service group + member relationship (scenario 45) ..." -ForegroundColor Yellow
$setupHm = Join-Path $PSScriptRoot 'setup-health-model.ps1'
if (Test-Path $setupHm) {
  & $setupHm -ResourceGroup $ResourceGroup -Teardown
}

Write-Host "Deleting $ResourceGroup ..." -ForegroundColor Yellow
az group delete -n $ResourceGroup --yes --no-wait
Write-Host "Delete kicked off (running in background)." -ForegroundColor Green
