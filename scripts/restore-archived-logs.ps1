<#
.SYNOPSIS
  Restore archived/cold data from a table back to an Analytics-tier restore table.

.DESCRIPTION
  When a LAW table has long-term retention enabled, older data sits in cheap
  archived storage and can't be queried directly. A **Restore** brings a time
  range back into a queryable restore table (`<TableName>_RST`). The restored
  data is queryable for the duration you specify, then disappears.

  Restores incur cost (per GB scanned) and time (often several minutes for small
  ranges). Use sparingly — Search Jobs are the cheaper, async alternative.

.PARAMETER ResourceGroup
  Lab RG.

.PARAMETER WorkspaceName
  LAW name.

.PARAMETER TableName
  Source table to restore from (default ContainerLogV2).

.PARAMETER LookbackDays
  How far back to restore (default 14 days).
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup = 'rg-azure-monitor-lab',
  [string] $WorkspaceName = 'law-amlab-central',
  [string] $TableName     = 'ContainerLogV2',
  [int]    $LookbackDays  = 14
)
$ErrorActionPreference = 'Stop'

$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
}

$restoreTable = "${TableName}_RST"
$start = (Get-Date).ToUniversalTime().AddDays(-$LookbackDays).ToString('o')
$end   = (Get-Date).ToUniversalTime().ToString('o')

$body = @{
  properties = @{
    restoredLogs = @{
      sourceTable      = $TableName
      startRestoreTime = $start
      endRestoreTime   = $end
    }
  }
} | ConvertTo-Json -Depth 6

$subId = az account show --query id -o tsv
$uri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/tables/${restoreTable}?api-version=2023-09-01"
$token = az account get-access-token --resource 'https://management.azure.com' --query accessToken -o tsv

Write-Host "==> Restoring $TableName  ->  $restoreTable" -ForegroundColor Cyan
Write-Host "  Window: $start  ->  $end"
Invoke-RestMethod -Method PUT -Uri $uri -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } -Body $body | Out-Null

Write-Host "`n✅ Restore submitted. Track with:" -ForegroundColor Green
Write-Host "  az monitor log-analytics workspace table show -g $ResourceGroup --workspace-name $WorkspaceName -n $restoreTable --query 'properties.provisioningState' -o tsv" -ForegroundColor Yellow
Write-Host "`nQuery the restored data via:  $restoreTable | take 100" -ForegroundColor Yellow
