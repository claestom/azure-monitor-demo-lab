<#
.SYNOPSIS
  Provision a Grafana contact point + alert rule that fires on Prometheus pod-restart
  signal and forwards to the demo Action Group.

.DESCRIPTION
  Grafana alerting is a data-plane API. This script:
    1. Resolves the Grafana endpoint + the Action Group resource ID from the RG.
    2. Creates a 'Azure Monitor Action Group' contact point in Grafana.
    3. Creates a folder 'amlab' and an alert rule on the AMW data source that
       triggers when `kube_pod_container_status_restarts_total` rises sharply.
    4. Wires the rule's notification policy to the new contact point.

  Auth: the current `az login` user must have **Grafana Admin** on the Managed
  Grafana instance (this is automatic for the deployer).

.PARAMETER ResourceGroup
  Demo lab resource group.
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup = 'rg-azure-monitor-lab'
)
$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
}

Write-Step "Resolving Grafana + Action Group"
$grafana = az resource list -g $ResourceGroup --resource-type 'Microsoft.Dashboard/grafana' -o json | ConvertFrom-Json | Select-Object -First 1
if (-not $grafana) { throw "Managed Grafana not found in $ResourceGroup" }
$grafanaEndpoint = (az grafana show -g $ResourceGroup -n $grafana.name --query 'properties.endpoint' -o tsv)

$ag = az resource list -g $ResourceGroup --resource-type 'Microsoft.Insights/actionGroups' -o json | ConvertFrom-Json | Select-Object -First 1
if (-not $ag) { throw "Action Group not found in $ResourceGroup" }

Write-Host "  Grafana endpoint : $grafanaEndpoint"
Write-Host "  Action Group ID  : $($ag.id)"

# Get a bearer token for the Grafana data plane
Write-Step "Acquiring data-plane access token"
$token = az account get-access-token --resource 'ce34e7e5-485f-4d76-964f-b3d2b16d1e4f' --query accessToken -o tsv
if (-not $token) { throw "Failed to acquire Grafana data-plane token." }

$headers = @{
  Authorization = "Bearer $token"
  'Content-Type' = 'application/json'
}

# 1. Folder
Write-Step "Creating Grafana folder 'amlab' (idempotent)"
$folderBody = @{ uid = 'amlab'; title = 'amlab' } | ConvertTo-Json
try {
  Invoke-RestMethod -Method POST -Uri "$grafanaEndpoint/api/folders" -Headers $headers -Body $folderBody -ErrorAction Stop | Out-Null
  Write-Host "  Folder created." -ForegroundColor Green
} catch {
  if ($_.Exception.Response.StatusCode -ne 'PreconditionFailed' -and $_.Exception.Response.StatusCode -ne 'Conflict') { throw }
  Write-Host "  Folder already exists." -ForegroundColor Yellow
}

# 2. Contact point — Azure Monitor Action Group integration
Write-Step "Creating 'amlab-actiongroup' contact point"
$cpBody = @{
  name = 'amlab-actiongroup'
  type = 'azure-monitor'
  settings = @{
    actionGroup = $ag.id
  }
  disableResolveMessage = $false
} | ConvertTo-Json -Depth 5

try {
  Invoke-RestMethod -Method POST -Uri "$grafanaEndpoint/api/v1/provisioning/contact-points" -Headers $headers -Body $cpBody -ErrorAction Stop | Out-Null
  Write-Host "  Contact point created." -ForegroundColor Green
} catch {
  Write-Host "  Contact point may already exist (response: $($_.Exception.Response.StatusCode))." -ForegroundColor Yellow
}

# 3. Notification policy — default route → amlab-actiongroup
Write-Step "Updating root notification policy"
$polBody = @{
  receiver = 'amlab-actiongroup'
  group_by = @('grafana_folder', 'alertname')
  routes   = @()
} | ConvertTo-Json -Depth 5
Invoke-RestMethod -Method PUT -Uri "$grafanaEndpoint/api/v1/provisioning/policies" -Headers $headers -Body $polBody | Out-Null
Write-Host "  Policy updated." -ForegroundColor Green

# 4. Alert rule on AMW Prometheus data source
Write-Step "Looking up AMW data source UID"
$dsList = Invoke-RestMethod -Method GET -Uri "$grafanaEndpoint/api/datasources" -Headers $headers
$amwDs  = $dsList | Where-Object { $_.type -eq 'grafana-azure-monitor-datasource' -or $_.type -eq 'prometheus' } | Select-Object -First 1
if (-not $amwDs) { throw "AMW / Prometheus data source not found in Grafana." }
Write-Host "  Data source: $($amwDs.name) ($($amwDs.uid))"

$ruleBody = @{
  uid          = 'amlab-pod-restart-spike'
  title        = 'amlab — Pod restart spike'
  ruleGroup    = 'amlab'
  folderUID    = 'amlab'
  noDataState  = 'OK'
  execErrState = 'Error'
  for          = '5m'
  condition    = 'A'
  data = @(
    @{
      refId            = 'A'
      queryType        = ''
      relativeTimeRange = @{ from = 600; to = 0 }
      datasourceUid    = $amwDs.uid
      model = @{
        expr     = 'sum(rate(kube_pod_container_status_restarts_total[5m])) > 0.05'
        refId    = 'A'
        instant  = $true
      }
    }
  )
  labels      = @{ team = 'demo-lab' }
  annotations = @{ summary = 'Pod restart rate above threshold' }
} | ConvertTo-Json -Depth 10

try {
  Invoke-RestMethod -Method POST -Uri "$grafanaEndpoint/api/v1/provisioning/alert-rules" -Headers $headers -Body $ruleBody -ErrorAction Stop | Out-Null
  Write-Host "  Alert rule created." -ForegroundColor Green
} catch {
  Write-Host "  Alert rule may already exist or data source query rejected (response: $($_.Exception.Response.StatusCode))." -ForegroundColor Yellow
}

Write-Host "`n✅ Grafana alerting configured." -ForegroundColor Green
Write-Host "Open: $grafanaEndpoint/alerting/list" -ForegroundColor Yellow
