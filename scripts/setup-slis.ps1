<#
.SYNOPSIS
  Prepare the lab for demo Service Level Indicators (Microsoft.Monitor/slis
  preview) on the lab's service group — scenario 46.

.DESCRIPTION
  Microsoft.Monitor/slis is an *extension* resource on a tenant-scoped service
  group, so it can't live in RG-scoped Bicep. The 2025-03-01-preview RP also
  currently rejects the enum wire values documented in both the Bicep schema
  and the generated .NET SDK (e.g. `operator: '=='`, `comparator: '>='`), so
  scripted PUTs are parked until the spec stabilizes. This script does the
  prep that the SLI plane actually needs (which is non-trivial), then prints a
  portal URL and the exact field values to paste into the portal SLI form.

  Steps:
    1. Verify the service group exists (created by setup-health-model.ps1).
    2. Look up the UAMI 'id-sli-amlab' + AMW 'amw-amlab' by name.
    3. Grant Monitoring Metrics Publisher on the AMW's default DCR + DCE
       (the AMW role grant from Bicep is not enough — the SLI plane writes
        through the DCR in the managed RG `MA_<amw>_<region>_managed`).
    4. Print the portal URL and the UAMI/AMW IDs needed to fill the SLI form.

    -Teardown deletes the two SLIs by their canonical names. Idempotent —
    safe to run whether or not SLIs were created in the portal.

.PARAMETER ResourceGroup
  Lab resource group containing the AMW + UAMI.

.PARAMETER ServiceGroupId
  Service group that owns the SLIs (created by setup-health-model.ps1).

.PARAMETER Teardown
  Delete the two SLIs (by canonical name). Idempotent.

.NOTES
  API version: Microsoft.Monitor/slis  2025-03-01-preview
  RBAC required to run this script:
    * Reader on the lab RG.
    * User Access Administrator (or Owner) on the AMW's managed RG, so the
      script can grant Monitoring Metrics Publisher on its DCR + DCE.
  When PUTs are restored, you'll additionally need Owner/Contributor on the
  service group to write the SLI extension resources.
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup  = 'rg-azure-monitor-lab',
  [string] $ServiceGroupId = 'amlab-workload',
  [switch] $Teardown
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# --- Subscription guardrail ----------------------------------------------------
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting."
  }
} else {
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
}
Write-Info "Sub: $($active.id)"
Write-Info "RG : $ResourceGroup"
Write-Info "SG : $ServiceGroupId"

# --- API constants -------------------------------------------------------------
$sliApi = '2025-03-01-preview'
$sgApi  = '2024-02-01-preview'
$sgUrl  = "https://management.azure.com/providers/Microsoft.Management/serviceGroups/$ServiceGroupId" + "?api-version=$sgApi"

function Get-SliUrl {
  param([string] $SliName)
  return "https://management.azure.com/providers/Microsoft.Management/serviceGroups/$ServiceGroupId/providers/Microsoft.Monitor/slis/$SliName" + "?api-version=$sliApi"
}

# ===============================================================================
# TEARDOWN
# ===============================================================================
if ($Teardown) {
  Write-Step "Teardown: removing demo SLIs"
  foreach ($sli in @('sli-aks-pods-running', 'sli-aks-pod-start-latency')) {
    $url = Get-SliUrl -SliName $sli
    Write-Info "DELETE $url"
    az rest --method delete --url $url --only-show-errors 2>$null | Out-Null
  }
  Write-Host "`nTeardown submitted (DELETE is idempotent)." -ForegroundColor Green
  return
}

# ===============================================================================
# PREREQ — verify service group exists
# ===============================================================================
Write-Step "Verifying service group '$ServiceGroupId' exists"
$sgState = az rest --method get --url $sgUrl --only-show-errors 2>$null | ConvertFrom-Json
if (-not $sgState -or $sgState.properties.provisioningState -ne 'Succeeded') {
  throw "Service group '$ServiceGroupId' not found or not in Succeeded state. Run scripts/setup-health-model.ps1 first."
}
Write-Info "Service group OK ($($sgState.properties.provisioningState))."

# ===============================================================================
# PREREQ — locate UAMI + AMW by name (more robust than scanning deployments)
# ===============================================================================
Write-Step "Locating UAMI 'id-sli-amlab' and AMW 'amw-amlab' in $ResourceGroup"

$uamiId = az identity show -g $ResourceGroup -n 'id-sli-amlab' --query id -o tsv 2>$null
if (-not $uamiId) {
  throw "User-Assigned MI 'id-sli-amlab' not found in '$ResourceGroup'. Re-run deploy.ps1 with the latest main.bicep (the sli-identity module must have run)."
}
$uamiClientId = az identity show -g $ResourceGroup -n 'id-sli-amlab' --query clientId -o tsv 2>$null
if (-not $uamiClientId) {
  throw "Could not read clientId for UAMI 'id-sli-amlab'."
}

$amwId = az resource show -g $ResourceGroup -n 'amw-amlab' --resource-type 'Microsoft.Monitor/accounts' --query id -o tsv 2>$null
if (-not $amwId) {
  throw "Azure Monitor Workspace 'amw-amlab' not found in '$ResourceGroup'."
}
$amwName  = 'amw-amlab'
$location = az group show -n $ResourceGroup --query location -o tsv
Write-Info "UAMI    : $uamiId"
Write-Info "UAMI cid: $uamiClientId"
Write-Info "AMW     : $amwId ($amwName) @ $location"

$uamiPrincipalId = az identity show -g $ResourceGroup -n 'id-sli-amlab' --query principalId -o tsv 2>$null
if (-not $uamiPrincipalId) {
  throw "Could not read principalId for UAMI 'id-sli-amlab'."
}

# ===============================================================================
# PREREQ — grant Monitoring Metrics Publisher on the AMW's default DCR + DCE
# (the AMW role assignment is not enough; the SLI plane writes through the DCR
#  in the managed resource group MA_<amw>_<region>_managed).
# ===============================================================================
Write-Step "Granting Monitoring Metrics Publisher on AMW default DCR + DCE"

$ingest = az resource show --ids $amwId --query 'properties.defaultIngestionSettings' -o json | ConvertFrom-Json
if (-not $ingest.dataCollectionRuleResourceId) {
  throw "AMW '$amwName' has no defaultIngestionSettings.dataCollectionRuleResourceId."
}
$dcrId = $ingest.dataCollectionRuleResourceId
$dceId = $ingest.dataCollectionEndpointResourceId
$metricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'  # Monitoring Metrics Publisher
Write-Info "DCR : $dcrId"
Write-Info "DCE : $dceId"

foreach ($scope in @($dcrId, $dceId)) {
  if (-not $scope) { continue }
  $existing = az role assignment list --assignee-object-id $uamiPrincipalId --assignee-principal-type ServicePrincipal --scope $scope --role $metricsPublisherRoleId --query "[0].id" -o tsv 2>$null
  if ($existing) {
    Write-Info "Already assigned on $($scope.Split('/')[-3..-1] -join '/')"
  } else {
    Write-Info "Assigning Monitoring Metrics Publisher on $($scope.Split('/')[-3..-1] -join '/')"
    az role assignment create --assignee-object-id $uamiPrincipalId --assignee-principal-type ServicePrincipal --role $metricsPublisherRoleId --scope $scope --only-show-errors | Out-Null
  }
}
Write-Info "Waiting 30s for role propagation..."
Start-Sleep -Seconds 30

# ===============================================================================
# Helper to build + PUT an SLI body
# ===============================================================================
function New-SignalSource {
  param(
    [string] $Id,
    [string] $MetricName,
    [string] $MetricNamespace = 'default',
    [array]  $Filters = @(),
    [string] $TemporalType = 'Increase',
    [int]    $WindowSizeMinutes = 5,
    [string] $SpatialType = 'Sum'
  )
  return [pscustomobject]@{
    signalSourceId                  = $Id
    metricName                      = $MetricName
    metricNamespace                 = $MetricNamespace
    filters                         = @($Filters)
    sourceAmwAccountResourceId      = $amwId
    sourceAmwAccountManagedIdentity = $uamiClientId
    temporalAggregation             = @{ type = $TemporalType; windowSizeMinutes = $WindowSizeMinutes }
    spatialAggregation              = @{ type = $SpatialType;  dimensions = @() }
  }
}

function Submit-Sli {
  param(
    [string] $Name,
    [hashtable] $Body
  )
  $url = Get-SliUrl -SliName $Name
  $tmp = New-TemporaryFile
  ($Body | ConvertTo-Json -Depth 20 -Compress) | Set-Content -Path $tmp -Encoding UTF8
  Write-Info "PUT $url"
  # `az rest` writes errors to stderr but exits 0 — capture combined output and
  # check $LASTEXITCODE *and* the response for an error envelope before polling.
  $putOutput = & az rest --method put --url $url --body "@$tmp" 2>&1
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  if ($LASTEXITCODE -ne 0 -or ($putOutput -join "`n") -match 'ERROR: ') {
    throw "Failed to PUT SLI '$Name'.`n$putOutput"
  }

  # Poll for terminal state
  $deadline = (Get-Date).AddSeconds(180)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $resp = az rest --method get --url $url --only-show-errors 2>$null | ConvertFrom-Json
    $state = $resp.properties.provisioningState
    Write-Info "$Name : provisioningState = $state"
    if ($state -eq 'Succeeded') { return }
    if ($state -in 'Failed','Canceled') {
      throw "SLI '$Name' ended in state '$state'. Response: $($resp | ConvertTo-Json -Depth 8)"
    }
  }
  Write-Warn "SLI '$Name' did not reach Succeeded within 180s — continuing anyway. Re-check in the portal."
}

# ===============================================================================
# SLI bodies (parked) — portal-driven creation for now
# ===============================================================================
# Why: the Microsoft.Monitor/slis 2025-03-01-preview RP currently rejects the
# enum wire values documented in both the Bicep schema and the generated .NET
# SDK (e.g. operator '==' and comparator '>='), and the published OpenAPI
# spec / SDK source disagree with the live control-plane validator. Without a
# captured portal payload to mirror exactly, scripted SLI creation is a
# coin-flip. Everything *around* the SLI is set up correctly by this script
# (UAMI, role assignments on AMW + DCR + DCE, service group), so the operator
# only needs to fill in the form fields below in the portal.
#
# Once a known-good portal payload is captured (F12 -> Network -> PUT body
# on the .../slis/<name> request), restore Submit-Sli + the two SLI blocks
# kept in git history (commit 043fb73 and the preview-debug attempts after).
#
# Tracking: this is a preview API. Re-evaluate at GA.

Write-Step "SLI bodies parked — create the two SLIs in the portal"
$portalSgUrl = "https://portal.azure.com/#@$($active.tenantId)/resource/providers/Microsoft.Management/serviceGroups/$ServiceGroupId/serviceLevelIndicators"
Write-Host @"

   Open: $portalSgUrl

   Click '+ Add SLI' twice and paste these values:

   --- SLI #1 : sli-aks-pods-running (Availability, Window-Based) -----------
   Category                   Availability
   Evaluation type            Window-based
   Source AMW                 $amwName  ($amwId)
   Source AMW managed identity (UAMI client ID below)
   Metric 1 (s1)              kube_pod_status_phase   filter: phase == Running
                              temporal: Average / 5 min   spatial: Sum
   Metric 2 (s2)              kube_pod_status_phase
                              temporal: Average / 5 min   spatial: Sum
   Signal formula             (100 * `$s1) / `$s2
   Window uptime criteria     >= 95
   Baseline                   99   / 7d   / RollingDays
   Destination AMW            $amwName  (same UAMI)

   --- SLI #2 : sli-aks-pod-start-latency (Latency, Window-Based) -----------
   Category                   Latency
   Evaluation type            Window-based
   Source AMW                 $amwName  ($amwId)
   Source AMW managed identity (UAMI client ID below)
   Metric 1 (s1)              kubelet_pod_start_duration_seconds_bucket
                              filter: le == 30
                              temporal: Rate / 5 min      spatial: Sum
   Metric 2 (s2)              kubelet_pod_start_duration_seconds_count
                              temporal: Rate / 5 min      spatial: Sum
   Signal formula             (100 * `$s1) / `$s2
   Window uptime criteria     >= 95
   Baseline                   95   / 7d   / RollingDays
   Destination AMW            $amwName  (same UAMI)

   --- Values to paste -----------------------------------------------------
   UAMI client ID             $uamiClientId
   UAMI resource ID           $uamiId
   UAMI principal (object) ID $uamiPrincipalId
   AMW resource ID            $amwId
   AMW default DCR            $dcrId
   AMW default DCE            $dceId

   IMPORTANT — when adding multiple signal sources, keep their spatial
   aggregation 'dimensions' identical (both empty, or both ['cluster'], etc).
   Mis-aligned dimensions fail validation with [SignalSourceValidator].

   To remove the UAMI + role assignments (after deleting the SLIs in portal):
     ./scripts/teardown.ps1

"@ -ForegroundColor Green
return
