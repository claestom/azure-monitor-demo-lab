<#
.SYNOPSIS
  Pre-flight availability + quota check for the Azure Monitor Demo Lab.

.DESCRIPTION
  Validates — BEFORE a 20-minute deployment starts — that everything the lab needs is
  actually deployable in the target region for the current subscription:

    1. VM SKUs (Linux/Windows VM, AKS nodes, VMSS) exist in the region and are NOT
       restricted for this subscription (NotAvailableForSubscription / zone restrictions).
    2. Per-family vCPU quota has enough headroom for the VMs the lab will create,
       plus the region-wide "Total Regional Cores" quota.
    3. The PaaS resource types the lab deploys (AKS, App Service, Managed Grafana,
       Azure Monitor Workspace, Event Hub, Key Vault, Log Analytics) are available
       in the region.

  Prints a PASS / WARN / FAIL table and returns a non-zero exit code (and throws when
  invoked from deploy.ps1) if any hard blocker is found, so you fail in ~15 seconds
  instead of 20 minutes in.

.PARAMETER Location
  Target region (e.g. swedencentral). Required.

.PARAMETER VmSize
  SKU for the Linux + Windows demo VMs. Defaults to the Bicep default (Standard_B2s).

.PARAMETER AksNodeVmSize
  SKU for the AKS node pool. Defaults to the Bicep default (Standard_B2s).

.PARAMETER AksNodeCount
  AKS node count. Defaults to 1 (Bicep default).

.PARAMETER VmssSize
  SKU for the predictive-autoscale VMSS. Defaults to the Bicep default (Standard_B1s).

.PARAMETER DeployLinuxVm
  Whether the Linux VM is part of the deployment. Default true.

.PARAMETER DeployWindowsVm
  Whether the Windows VM is part of the deployment. Default true.

.PARAMETER WarnOnly
  Report problems but do not fail (exit 0 / no throw). Useful for a dry inspection.

.EXAMPLE
  ./scripts/preflight-check.ps1 -Location swedencentral

.EXAMPLE
  ./scripts/preflight-check.ps1 -Location westeurope -AksNodeCount 2 -WarnOnly
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $Location,
  [string] $VmSize          = 'Standard_B2s',
  [string] $AksNodeVmSize   = 'Standard_B2s',
  [int]    $AksNodeCount    = 1,
  [string] $VmssSize        = 'Standard_B1s',
  [bool]   $DeployLinuxVm   = $true,
  [bool]   $DeployWindowsVm = $true,
  [switch] $WarnOnly
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# Accumulates one row per check: @{ Check; Detail; Status } where Status is PASS/WARN/FAIL.
$results = New-Object System.Collections.Generic.List[object]
function Add-Result($check, $detail, $status) {
  $results.Add([pscustomobject]@{ Check = $check; Detail = $detail; Status = $status })
}

# Normalize a region display name ("Sweden Central") or code ("swedencentral") to a
# comparable token so provider display-name locations line up with region codes.
function Get-RegionToken($s) { if ($null -eq $s) { '' } else { ($s -replace '\s','').ToLowerInvariant() } }
$locToken = Get-RegionToken $Location

Write-Step "Pre-flight availability + quota check for region '$Location'"
$sub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
Write-Host "   Subscription: $($sub.name) ($($sub.id))" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 0. Region sanity — is this a real region for the subscription?
# ---------------------------------------------------------------------------
$validLocations = az account list-locations --query "[].name" -o json | ConvertFrom-Json
if ($validLocations -notcontains $Location) {
  Add-Result 'Region name' "'$Location' is not a valid region for this subscription" 'FAIL'
  # Print what we have and bail early — every downstream query needs a real region.
  $results | Format-Table -AutoSize | Out-Host
  if ($WarnOnly) { exit 0 } else { throw "Pre-flight failed: '$Location' is not a valid Azure region." }
}
Add-Result 'Region name' "'$Location' is a valid region" 'PASS'

# ---------------------------------------------------------------------------
# Build the VM demand list: which SKUs, and how many of each, will be created.
# ---------------------------------------------------------------------------
$vmDemand = @{}   # size -> count
function Add-VmDemand($size, $count) {
  if ($count -le 0 -or [string]::IsNullOrWhiteSpace($size)) { return }
  if ($vmDemand.ContainsKey($size)) { $vmDemand[$size] += $count } else { $vmDemand[$size] = $count }
}
if ($DeployLinuxVm)   { Add-VmDemand $VmSize 1 }
if ($DeployWindowsVm) { Add-VmDemand $VmSize 1 }
Add-VmDemand $AksNodeVmSize $AksNodeCount
Add-VmDemand $VmssSize 1   # predictive-autoscale VMSS, always 1 instance

# ---------------------------------------------------------------------------
# 1. VM SKU availability + subscription restrictions (single list-skus call).
# ---------------------------------------------------------------------------
Write-Step "Checking VM SKU availability + restrictions"
$skusJson = az vm list-skus --location $Location --resource-type virtualMachines --all -o json 2>$null
$skus = if ($skusJson) { $skusJson | ConvertFrom-Json } else { @() }
$skuBySize = @{}
foreach ($s in $skus) { $skuBySize[$s.name] = $s }

# size -> family, and per-family required vCPU totals (for the quota check below).
$familyRequired = @{}   # familyValue -> required vCPUs
$totalRequiredCores = 0

foreach ($size in $vmDemand.Keys) {
  $count = $vmDemand[$size]
  $sku = $skuBySize[$size]
  if ($null -eq $sku) {
    Add-Result "VM SKU $size" "not offered in $Location (x$count needed)" 'FAIL'
    continue
  }

  $vcpuCap = ($sku.capabilities | Where-Object { $_.name -eq 'vCPUs' } | Select-Object -First 1).value
  $vcpu = if ($vcpuCap) { [int]$vcpuCap } else { 0 }
  $family = $sku.family

  # Subscription-level restrictions: Location = hard block, Zone = soft (non-zonal still OK).
  $locRestricted  = $false
  $zoneRestricted = $false
  foreach ($r in @($sku.restrictions)) {
    if ($r.type -eq 'Location') { $locRestricted = $true }
    if ($r.type -eq 'Zone')     { $zoneRestricted = $true }
  }

  if ($locRestricted) {
    $reason = (@($sku.restrictions) | Where-Object { $_.type -eq 'Location' } | Select-Object -First 1).reasonCode
    Add-Result "VM SKU $size" "restricted in $Location for this subscription ($reason). Request access or pick another size/region." 'FAIL'
    continue
  }

  # Tally required vCPUs for quota check (only for SKUs that are actually deployable).
  if ($family) {
    if ($familyRequired.ContainsKey($family)) { $familyRequired[$family] += ($vcpu * $count) }
    else { $familyRequired[$family] = ($vcpu * $count) }
  }
  $totalRequiredCores += ($vcpu * $count)

  if ($zoneRestricted) {
    Add-Result "VM SKU $size" "available (x$count, ${vcpu} vCPU ea, family $family) but zone-restricted — OK for non-zonal deploy" 'WARN'
  } else {
    Add-Result "VM SKU $size" "available (x$count, ${vcpu} vCPU ea, family $family)" 'PASS'
  }
}

# ---------------------------------------------------------------------------
# 2. Per-family + total regional vCPU quota headroom.
# ---------------------------------------------------------------------------
Write-Step "Checking vCPU quota headroom"
$usageJson = az vm list-usage --location $Location -o json 2>$null
$usage = if ($usageJson) { $usageJson | ConvertFrom-Json } else { @() }
$usageByName = @{}
foreach ($u in $usage) { $usageByName[$u.name.value] = $u }

foreach ($family in $familyRequired.Keys) {
  $need = $familyRequired[$family]
  $u = $usageByName[$family]
  if ($null -eq $u) {
    Add-Result "Quota $family" "need $need vCPU — usage/limit not reported (assuming default). Verify manually if deploy fails." 'WARN'
    continue
  }
  $available = [int]$u.limit - [int]$u.currentValue
  $detail = "need $need vCPU, have $available free (limit $($u.limit), used $($u.currentValue))"
  if ($need -gt $available) { Add-Result "Quota $family" "$detail — INSUFFICIENT, request an increase" 'FAIL' }
  else { Add-Result "Quota $family" $detail 'PASS' }
}

# Total Regional Cores (name.value = 'cores').
$coresUsage = $usageByName['cores']
if ($coresUsage) {
  $availCores = [int]$coresUsage.limit - [int]$coresUsage.currentValue
  $detail = "need $totalRequiredCores vCPU, have $availCores free (limit $($coresUsage.limit), used $($coresUsage.currentValue))"
  if ($totalRequiredCores -gt $availCores) { Add-Result 'Quota Total Regional Cores' "$detail — INSUFFICIENT" 'FAIL' }
  else { Add-Result 'Quota Total Regional Cores' $detail 'PASS' }
}

# ---------------------------------------------------------------------------
# 3. PaaS resource-type availability in the region.
# ---------------------------------------------------------------------------
Write-Step "Checking PaaS resource-type availability"
$paasTypes = @(
  @{ Label = 'AKS';                    Ns = 'Microsoft.ContainerService'; Type = 'managedClusters' }
  @{ Label = 'App Service (Linux)';    Ns = 'Microsoft.Web';              Type = 'sites' }
  @{ Label = 'Managed Grafana';        Ns = 'Microsoft.Dashboard';        Type = 'grafana' }
  @{ Label = 'Azure Monitor Workspace';Ns = 'Microsoft.Monitor';          Type = 'accounts' }
  @{ Label = 'Event Hub';              Ns = 'Microsoft.EventHub';         Type = 'namespaces' }
  @{ Label = 'Key Vault';              Ns = 'Microsoft.KeyVault';         Type = 'vaults' }
  @{ Label = 'Log Analytics';          Ns = 'Microsoft.OperationalInsights'; Type = 'workspaces' }
)
foreach ($t in $paasTypes) {
  $locsJson = az provider show -n $t.Ns --query "resourceTypes[?resourceType=='$($t.Type)'].locations | [0]" -o json 2>$null
  $locs = if ($locsJson) { $locsJson | ConvertFrom-Json } else { $null }
  if ($null -eq $locs -or @($locs).Count -eq 0) {
    # Global services (e.g. some are location-agnostic) report no per-region list.
    Add-Result "$($t.Label)" "$($t.Ns)/$($t.Type): no region list (global or provider not registered) — skipped" 'WARN'
    continue
  }
  $tokens = @($locs | ForEach-Object { Get-RegionToken $_ })
  if ($tokens -contains $locToken) {
    Add-Result "$($t.Label)" "available in $Location" 'PASS'
  } else {
    Add-Result "$($t.Label)" "$($t.Ns)/$($t.Type) NOT available in $Location — pick a supported region" 'FAIL'
  }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Step "Pre-flight results"
foreach ($r in $results) {
  $color = switch ($r.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
  Write-Host ("  [{0,-4}] {1,-26} {2}" -f $r.Status, $r.Check, $r.Detail) -ForegroundColor $color
}

$failCount = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = ($results | Where-Object { $_.Status -eq 'WARN' }).Count
Write-Host ""
Write-Host ("Summary: {0} pass, {1} warn, {2} fail" -f `
  (($results | Where-Object { $_.Status -eq 'PASS' }).Count), $warnCount, $failCount) `
  -ForegroundColor ($(if ($failCount) { 'Red' } elseif ($warnCount) { 'Yellow' } else { 'Green' }))

if ($failCount -gt 0) {
  if ($WarnOnly) {
    Write-Host "WarnOnly set — continuing despite $failCount blocker(s)." -ForegroundColor Yellow
    exit 0
  }
  throw "Pre-flight failed: $failCount blocker(s) in '$Location'. Fix the FAIL rows above (change region, pick another SKU, or request a quota increase) and retry."
}

Write-Host "✅ Pre-flight OK — region '$Location' can host the lab." -ForegroundColor Green
exit 0
