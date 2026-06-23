<#
.SYNOPSIS
  Tear the lab down: deletes the resource group + sub-scoped artefacts (none here).
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
