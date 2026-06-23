<#
.SYNOPSIS
  Toggle a LAW table between Analytics and Basic Logs plan to demo cost savings.

.DESCRIPTION
  Switches a table (default: ContainerLogV2) between Analytics and Basic plan.
  Shows the 8x cost difference and query limitations of Basic Logs.

.PARAMETER ResourceGroup
  Resource group containing the demo lab.

.PARAMETER WorkspaceName
  LAW name (default: law-amlab-central).

.PARAMETER TableName
  Table to toggle (default: ContainerLogV2).

.PARAMETER Plan
  Target plan: 'Basic' or 'Analytics'.
#>
param(
  [string]$ResourceGroup = 'rg-azure-monitor-lab',
  [string]$WorkspaceName = 'law-amlab-central',
  [string]$TableName = 'ContainerLogV2',

  [Parameter(Mandatory)]
  [ValidateSet('Basic', 'Analytics')]
  [string]$Plan
)

$ErrorActionPreference = 'Stop'

Write-Host "`n=== Table Plan Toggle ===" -ForegroundColor Cyan

# Show current plan
$current = az monitor log-analytics workspace table show `
  -g $ResourceGroup --workspace-name $WorkspaceName -n $TableName `
  --query "properties.plan" -o tsv

Write-Host "Table:        $TableName" -ForegroundColor Gray
Write-Host "Current plan: $current" -ForegroundColor Yellow
Write-Host "Target plan:  $Plan" -ForegroundColor Yellow

if ($current -eq $Plan) {
  Write-Host "`nTable is already on the '$Plan' plan. No change needed." -ForegroundColor Green
  return
}

# Toggle
Write-Host "`nSwitching $TableName to '$Plan'..." -ForegroundColor Yellow

if ($Plan -eq 'Basic') {
  # Basic Logs requires workspace-default retention — reset any custom retention first
  az monitor log-analytics workspace table update `
    -g $ResourceGroup --workspace-name $WorkspaceName -n $TableName `
    --retention-time -1 --total-retention-time -1 -o none 2>$null
}

az monitor log-analytics workspace table update `
  -g $ResourceGroup --workspace-name $WorkspaceName -n $TableName `
  --plan $Plan -o none

Write-Host "Done. $TableName is now on the '$Plan' plan." -ForegroundColor Green

if ($Plan -eq 'Basic') {
  Write-Host @"

=== Basic Logs: what changes ===
  Cost:        ~8x cheaper ingestion (per-GB rate)
  Retention:   8 days (fixed, no interactive retention extension)
  KQL:         Limited — only: where, extend, parse, project, search
               NO: join, union, summarize, sort, distinct, count
  Search jobs: Use search jobs for complex analytics on Basic Logs data
  Alerts:      Log search alerts work (at higher cost per evaluation)

  Try this KQL (works on Basic):
    SecurityAudit_CL | where Severity == "Critical" | take 10

  This KQL will FAIL on Basic:
    SecurityAudit_CL | summarize count() by EventType
"@ -ForegroundColor Gray
} else {
  Write-Host "`nFull KQL and 30-day interactive retention restored." -ForegroundColor Gray
}
