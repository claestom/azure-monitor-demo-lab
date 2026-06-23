<#
.SYNOPSIS
  Demonstrates Granular RBAC by querying Log Analytics with 3 service principals.

.DESCRIPTION
  Runs the same KQL query against the Log Analytics workspace using three different
  service principals, each with a different ABAC access level:

    SP1 (workspace-level) — sees ALL tables, ALL rows
    SP2 (table-level)     — sees ONLY SecurityAudit_CL, ALL rows
    SP3 (row-level)       — sees ONLY SecurityAudit_CL, ONLY Severity==Critical

  Each SP authenticates via OAuth2 client credentials flow and calls the
  Log Analytics Query REST API. The script shows the different result sets
  side-by-side to prove ABAC filtering works.

  Requires: scripts/.rbac-demo-config.json (created by setup-rbac-demo.ps1).

.PARAMETER Query
  KQL query to run against SecurityAudit_CL. Default: summarise by Severity and EventType.

.EXAMPLE
  ./scripts/demo-granular-rbac.ps1
  ./scripts/demo-granular-rbac.ps1 -Query "SecurityAudit_CL | take 5"
#>
param(
    [string]$Query = 'SecurityAudit_CL | where TimeGenerated > ago(24h) | summarize EventCount = count() by Severity, EventType | order by Severity asc, EventType asc'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
$configPath = Join-Path $PSScriptRoot '.rbac-demo-config.json'
if (-not (Test-Path $configPath)) {
    Write-Error "Config not found at $configPath. Run setup-rbac-demo.ps1 first."
    return
}
$config      = Get-Content $configPath -Raw | ConvertFrom-Json
$tenantId    = $config.tenantId
$workspaceId = $config.workspaceId

# ---------------------------------------------------------------------------
# Helper: get OAuth2 token via client credentials flow
# ---------------------------------------------------------------------------
function Get-LAToken {
    param([string]$AppId, [string]$Secret)

    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $AppId
        client_secret = $Secret
        scope         = 'https://api.loganalytics.io/.default'
    }
    $response = Invoke-RestMethod `
        -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded'
    return $response.access_token
}

# ---------------------------------------------------------------------------
# Helper: query Log Analytics REST API
# ---------------------------------------------------------------------------
function Invoke-LAQuery {
    param([string]$Token, [string]$KqlQuery)

    $headers = @{
        Authorization  = "Bearer $Token"
        'Content-Type' = 'application/json'
    }
    $body = @{ query = $KqlQuery } | ConvertTo-Json

    try {
        $result = Invoke-RestMethod `
            -Uri "https://api.loganalytics.io/v1/workspaces/$workspaceId/query" `
            -Method POST -Headers $headers -Body $body
        return @{ success = $true; table = $result.tables[0] }
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        $detail = $null
        try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch {}
        if (-not $detail) { $detail = $_.Exception.Message }
        return @{ success = $false; error = "$status — $detail" }
    }
}

# ---------------------------------------------------------------------------
# Helper: render query results
# ---------------------------------------------------------------------------
function Show-Results {
    param($Result, [string]$Label)

    if (-not $Result.success) {
        Write-Host "  ❌ $($Result.error)" -ForegroundColor Red
        return
    }

    $table = $Result.table
    if (-not $table -or -not $table.rows -or $table.rows.Count -eq 0) {
        Write-Host "  📭 0 rows returned" -ForegroundColor Yellow
        return
    }

    $colNames = $table.columns | ForEach-Object { $_.name }

    # Build PSObjects for Format-Table
    $rows = foreach ($row in $table.rows) {
        $obj = [ordered]@{}
        for ($i = 0; $i -lt $colNames.Count; $i++) {
            $obj[$colNames[$i]] = $row[$i]
        }
        [PSCustomObject]$obj
    }

    $rows | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
    Write-Host "  ── $($table.rows.Count) row(s) returned" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Run queries for each service principal
# ---------------------------------------------------------------------------
$tiers = @(
    @{ key = 'workspace'; label = 'WORKSPACE-LEVEL'; desc = 'Log Analytics Reader — all tables, all rows' }
    @{ key = 'table';     label = 'TABLE-LEVEL';     desc = 'Granular Reader + ABAC — SecurityAudit_CL only' }
    @{ key = 'row';       label = 'ROW-LEVEL';       desc = 'Granular Reader + ABAC — SecurityAudit_CL, Severity==Critical only' }
)

$queries = @(
    @{ name = 'SecurityAudit_CL (allowed table)'; kql = $Query }
    @{
        name = 'Heartbeat (different table — blocked for table/row SP)'
        kql  = 'Heartbeat | summarize HeartbeatCount = count() by Computer | order by Computer asc'
    }
)

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║          Granular RBAC Demo — ABAC Condition Comparison           ║" -ForegroundColor Magenta
Write-Host "╚════════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta

foreach ($q in $queries) {
    Write-Host "`n━━━ Query: $($q.name) ━━━" -ForegroundColor Magenta
    Write-Host "    $($q.kql)" -ForegroundColor DarkGray

    foreach ($tier in $tiers) {
        $sp = $config.servicePrincipals.($tier.key)

        Write-Host "`n┌──────────────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
        Write-Host "│  $($tier.label): $($sp.displayName)" -ForegroundColor Cyan
        Write-Host "│  $($tier.desc)" -ForegroundColor DarkCyan
        Write-Host "└──────────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan

        # Authenticate and query
        try {
            $token  = Get-LAToken -AppId $sp.appId -Secret $sp.secret
            $result = Invoke-LAQuery -Token $token -KqlQuery $q.kql
            Show-Results -Result $result -Label $tier.label
        }
        catch {
            Write-Host "  ❌ Auth failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host "`n════════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "Expected results:" -ForegroundColor Magenta
Write-Host "  SP1 (workspace): SecurityAudit_CL → all severities  |  Heartbeat → all VMs" -ForegroundColor White
Write-Host "  SP2 (table):     SecurityAudit_CL → all severities  |  Heartbeat → 0 rows / error" -ForegroundColor White
Write-Host "  SP3 (row):       SecurityAudit_CL → Critical only   |  Heartbeat → 0 rows / error" -ForegroundColor White
Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Magenta
