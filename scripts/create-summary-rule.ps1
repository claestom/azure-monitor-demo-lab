<#
.SYNOPSIS
  Create / update the hourly Perf summary rule that populates Perf_Hourly_CL.

.DESCRIPTION
  Uses the GA Summary Rules REST API:
    PUT  Microsoft.OperationalInsights/workspaces/{ws}/summarylogs/{ruleName}
    api-version  2025-07-01
  See: https://learn.microsoft.com/azure/azure-monitor/logs/summary-rules

  Powers scenario 21 in DEMO-SCENARIOS.md.

  Source : Perf  (high-volume VM perf counters from AMA)
  Target : Perf_Hourly_CL  (custom table pre-created by
           infra/modules/summary-rules.bicep, Analytics plan, 180-day retention)
  Bin    : 60 minutes (hourly aggregation)

  Idempotent — PUT upserts the rule definition. Safe to re-run.

.PARAMETER ResourceGroup
  Resource group containing the demo lab.

.PARAMETER WorkspaceName
  Central LAW name (default: law-amlab-central).

.PARAMETER RuleName
  Summary rule name (default: rule-perf-hourly).
#>
param(
  [string]$ResourceGroup = 'rg-azure-monitor-lab',
  [string]$WorkspaceName = 'law-amlab-central',
  [string]$RuleName      = 'rule-perf-hourly'
)

$ErrorActionPreference = 'Stop'

Write-Host "`n=== Summary Rule: Perf -> Perf_Hourly_CL ($RuleName) ===" -ForegroundColor Cyan

$subId      = az account show --query id -o tsv
$apiVersion = '2025-07-01'
$uri        = "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/summarylogs/$RuleName`?api-version=$apiVersion"

# Single-line KQL — the bin window provides the time range, so the query must NOT
# include its own time filter (per summary-rules docs).
$query = 'Perf | where ObjectName in ("Processor","Memory","LogicalDisk") | where CounterName in ("% Processor Time","Available MBytes","% Free Space") | summarize AvgValue=avg(CounterValue), MinValue=min(CounterValue), MaxValue=max(CounterValue), SampleCount=count() by Computer, CounterName'

$body = @{
  properties = @{
    ruleType    = 'User'
    description = 'Hourly aggregation of VM perf counters (CPU/Memory/Disk) into Perf_Hourly_CL. Powers demo scenario 21.'
    ruleDefinition = @{
      query            = $query
      binSize          = 60                    # minutes
      destinationTable = 'Perf_Hourly_CL'
    }
  }
} | ConvertTo-Json -Depth 6 -Compress

# az rest --body with embedded quotes is fragile on Windows; write to a temp file.
$bodyFile = New-TemporaryFile
try {
  $body | Set-Content -Path $bodyFile -Encoding utf8

  Write-Host "  PUT $uri" -ForegroundColor DarkGray
  $resp = az rest --method PUT --uri $uri --body "@$bodyFile" --headers "Content-Type=application/json" --only-show-errors -o json
  if ($LASTEXITCODE -ne 0) {
    throw "az rest returned exit code $LASTEXITCODE. Output: $resp"
  }
  $parsed = $resp | ConvertFrom-Json
  $state  = $parsed.properties.provisioningState
  Write-Host "  Rule upserted: $($parsed.name) (provisioningState=$state)" -ForegroundColor Green
  Write-Host "  First aggregation runs shortly after the next whole hour (~3-6 min delay)." -ForegroundColor DarkGray
  Write-Host "  Monitor via:  LASummaryLogs | where RuleName == '$RuleName' | order by TimeGenerated desc" -ForegroundColor DarkGray
} catch {
  Write-Host "  Failed to create summary rule: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "  Perf_Hourly_CL will remain empty until the rule is in place." -ForegroundColor Yellow
  throw
} finally {
  Remove-Item -Force $bodyFile -ErrorAction SilentlyContinue
}
