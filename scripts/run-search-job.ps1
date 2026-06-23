<#
.SYNOPSIS
  Run an asynchronous Search Job over data in a Basic-Logs / Auxiliary-Logs table.

.DESCRIPTION
  Basic Logs tables can't be queried with full KQL interactively. A Search Job
  scans the data with a limited KQL subset and writes results to a new table
  named `<TableName>_SRCH`. Once it lands, you can query the _SRCH table with
  full KQL like any Analytics table.

  Use case: investigate a security event in `ContainerLogV2` AFTER you've moved
  the table to Basic Logs (cheap ingest, expensive query) for cost reasons.

.PARAMETER ResourceGroup
  Lab RG.

.PARAMETER WorkspaceName
  LAW name.

.PARAMETER TableName
  Table to search (default ContainerLogV2).

.PARAMETER Query
  KQL search to run. Default: lines containing 'error'.

.PARAMETER LookbackHours
  Time range to search (default 24h).
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup = 'rg-azure-monitor-lab',
  [string] $WorkspaceName = 'law-amlab-central',
  [string] $TableName     = 'ContainerLogV2',
  [string] $Query         = "{0} | where LogMessage has 'error' | project TimeGenerated, PodName, ContainerName, LogMessage",
  [int]    $LookbackHours = 24
)
$ErrorActionPreference = 'Stop'

$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
}

$searchTable = "${TableName}_SRCH"
$fullQuery   = $Query -f $TableName

$start = (Get-Date).ToUniversalTime().AddHours(-$LookbackHours).ToString('o')
$end   = (Get-Date).ToUniversalTime().ToString('o')

$body = @{
  properties = @{
    searchResults = @{
      query  = $fullQuery
      limit  = 1000
      startSearchTime = $start
      endSearchTime   = $end
    }
  }
} | ConvertTo-Json -Depth 8

$subId = az account show --query id -o tsv
$uri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/tables/${searchTable}?api-version=2023-09-01"
$token = az account get-access-token --resource 'https://management.azure.com' --query accessToken -o tsv

Write-Host "==> Submitting Search Job" -ForegroundColor Cyan
Write-Host "  Source table  : $TableName"
Write-Host "  Result table  : $searchTable"
Write-Host "  Query         : $fullQuery"
Write-Host "  Window        : $start  ->  $end"

Invoke-RestMethod -Method PUT -Uri $uri -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } -Body $body | Out-Null

Write-Host "`n✅ Search Job submitted. Poll completion with:" -ForegroundColor Green
Write-Host "  az monitor log-analytics workspace table show -g $ResourceGroup --workspace-name $WorkspaceName -n $searchTable --query 'properties.provisioningState' -o tsv" -ForegroundColor Yellow
Write-Host "`nWhen state == 'Succeeded', query the results in the portal:" -ForegroundColor Yellow
Write-Host "  $searchTable | take 100" -ForegroundColor Yellow
