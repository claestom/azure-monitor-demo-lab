<#
.SYNOPSIS
  Create the optional Microsoft Fabric Real-Time Intelligence demo items.

.DESCRIPTION
  Pins and verifies the Azure subscription, finds the deployed Fabric F2 capacity,
  then creates or reuses a workspace, Eventhouse, KQL database, and empty Eventstream.
  The Event Hub connection remains a guided portal step so no shared keys are handled.

.EXAMPLE
  ./scripts/setup-fabric.ps1 -SubscriptionId <subscription-id> -ResourceGroup rg-azure-monitor-lab
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [string] $WorkspaceName = 'Azure Monitor Demo Lab',
  [string] $EventhouseName = 'Azure Monitor Demo Eventhouse',
  [string] $KqlDatabaseName = 'MonitoringTelemetry',
  [string] $EventstreamName = 'AzureMonitorEvents'
)

$ErrorActionPreference = 'Stop'
$fabricApi = 'https://api.fabric.microsoft.com/v1'

function Write-Step($Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Info($Message) { Write-Host "    $Message" -ForegroundColor DarkGray }

function Get-CollectionItem {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $DisplayName
  )

  $response = Invoke-RestMethod -Method Get -Uri "$fabricApi/$Path" -Headers $script:fabricHeaders
  return @($response.value | Where-Object { $_.displayName -eq $DisplayName }) | Select-Object -First 1
}

function Wait-FabricOperation {
  param([Parameter(Mandatory)] [string] $OperationUrl)

  if ($OperationUrl.StartsWith('/')) {
    $OperationUrl = "https://api.fabric.microsoft.com$OperationUrl"
  }

  for ($attempt = 1; $attempt -le 60; $attempt++) {
    $operation = Invoke-RestMethod -Method Get -Uri $OperationUrl -Headers $script:fabricHeaders
    if ($operation.status -eq 'Succeeded') { return }
    if ($operation.status -in @('Failed', 'Cancelled')) {
      throw "Fabric operation ended with status '$($operation.status)': $($operation.error.message)"
    }
    Start-Sleep -Seconds 5
  }

  throw 'Fabric operation did not complete within five minutes.'
}

function New-FabricItem {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [hashtable] $Body
  )

  $responseHeaders = $null
  $request = @{
    Method = 'Post'
    Uri = "$fabricApi/$Path"
    Headers = $script:fabricHeaders
    ContentType = 'application/json'
    Body = ($Body | ConvertTo-Json -Depth 8)
    ResponseHeadersVariable = 'responseHeaders'
  }
  $result = Invoke-RestMethod @request
  $operationUrl = $responseHeaders.Location | Select-Object -First 1
  if ($operationUrl) {
    Wait-FabricOperation -OperationUrl $operationUrl
  }
  return $result
}

function Ensure-FabricItem {
  param(
    [Parameter(Mandatory)] [string] $CollectionPath,
    [Parameter(Mandatory)] [string] $DisplayName,
    [Parameter(Mandatory)] [hashtable] $CreateBody
  )

  $item = Get-CollectionItem -Path $CollectionPath -DisplayName $DisplayName
  if ($item) {
    Write-Info "Reusing '$DisplayName' ($($item.id))"
    return $item
  }

  Write-Info "Creating '$DisplayName'"
  $created = New-FabricItem -Path $CollectionPath -Body $CreateBody
  if ($created.id) { return $created }

  $item = Get-CollectionItem -Path $CollectionPath -DisplayName $DisplayName
  if (-not $item) { throw "Fabric created '$DisplayName', but it could not be resolved afterward." }
  return $item
}

Write-Step 'Pinning the Azure subscription'
az account set --subscription $SubscriptionId | Out-Null
$active = az account show --query '{id:id,tenantId:tenantId}' -o json | ConvertFrom-Json
if ($active.id -ne $SubscriptionId) {
  throw "Subscription guardrail failed: expected '$SubscriptionId', got '$($active.id)'."
}
Write-Info "Subscription: $($active.id)"
Write-Info "Tenant: $($active.tenantId)"

Write-Step 'Discovering the deployed Fabric capacity'
$armCapacity = az resource list `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --resource-type Microsoft.Fabric/capacities `
  --query '[0].{id:id,name:name,location:location,sku:sku.name}' `
  -o json | ConvertFrom-Json
if (-not $armCapacity) {
  throw "No Microsoft Fabric capacity was found in '$ResourceGroup'. Enable the Fabric stage first."
}
if ($armCapacity.sku -ne 'F2' -or $armCapacity.location.Replace(' ', '').ToLowerInvariant() -ne 'swedencentral') {
  throw "Expected an F2 capacity in swedencentral, found '$($armCapacity.sku)' in '$($armCapacity.location)'."
}
Write-Info "Capacity: $($armCapacity.name) (F2, swedencentral)"
Write-Host '    Cost warning: indicative PAYG retail cost while active is about $0.36/hour, $8.64/day, or $262.80/month.' -ForegroundColor Yellow

Write-Step 'Authenticating to the Fabric API'
$fabricToken = az account get-access-token `
  --resource https://api.fabric.microsoft.com `
  --query accessToken `
  -o tsv
if ([string]::IsNullOrWhiteSpace($fabricToken)) { throw 'Could not acquire a Microsoft Fabric API token.' }
$script:fabricHeaders = @{ Authorization = "Bearer $fabricToken" }

$capacities = Invoke-RestMethod -Method Get -Uri "$fabricApi/capacities" -Headers $script:fabricHeaders
$fabricCapacity = @($capacities.value | Where-Object { $_.displayName -eq $armCapacity.name }) | Select-Object -First 1
if (-not $fabricCapacity) {
  throw "Fabric API did not return capacity '$($armCapacity.name)'. Confirm the tenant is Fabric-enabled and your identity is a capacity administrator."
}

Write-Step 'Creating or reusing the Fabric workspace'
$workspace = Ensure-FabricItem `
  -CollectionPath 'workspaces' `
  -DisplayName $WorkspaceName `
  -CreateBody @{
    displayName = $WorkspaceName
    description = 'Real-Time Intelligence scenarios for the Azure Monitor Demo Lab.'
    capacityId = $fabricCapacity.id
  }

Write-Step 'Creating or reusing Real-Time Intelligence items'
$eventhouse = Ensure-FabricItem `
  -CollectionPath "workspaces/$($workspace.id)/eventhouses" `
  -DisplayName $EventhouseName `
  -CreateBody @{
    displayName = $EventhouseName
    description = 'Eventhouse for operational and business event correlation.'
  }

$kqlDatabase = Ensure-FabricItem `
  -CollectionPath "workspaces/$($workspace.id)/kqlDatabases" `
  -DisplayName $KqlDatabaseName `
  -CreateBody @{
    displayName = $KqlDatabaseName
    description = 'Read-write KQL database for streamed lab telemetry.'
    creationPayload = @{
      databaseType = 'ReadWrite'
      parentEventhouseItemId = $eventhouse.id
    }
  }

$eventstream = Ensure-FabricItem `
  -CollectionPath "workspaces/$($workspace.id)/eventstreams" `
  -DisplayName $EventstreamName `
  -CreateBody @{
    displayName = $EventstreamName
    description = 'Eventstream shell for the Azure Event Hubs diagnostics source.'
  }

Write-Step 'Resolving the Azure Event Hub source'
$eventHubNamespace = az resource list `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --resource-type Microsoft.EventHub/namespaces `
  --query '[0].name' `
  -o tsv
if ([string]::IsNullOrWhiteSpace($eventHubNamespace)) {
  Write-Host '    No Event Hubs namespace was found. Deploy Stage A before configuring the Eventstream source.' -ForegroundColor Yellow
} else {
  Write-Info "Namespace: $eventHubNamespace"
  Write-Info 'Event Hub: diagnostics'
  Write-Info 'Authorization rule: diagnostics-send'
}

Write-Host "`nFabric setup completed." -ForegroundColor Green
Write-Host "Workspace: https://app.fabric.microsoft.com/groups/$($workspace.id)"
Write-Host "Eventhouse ID: $($eventhouse.id)"
Write-Host "KQL database ID: $($kqlDatabase.id)"
Write-Host "Eventstream ID: $($eventstream.id)"
Write-Host "`nManual Eventstream connection:" -ForegroundColor Cyan
Write-Host "1. Open the Eventstream '$EventstreamName' in the workspace."
Write-Host "2. Add an Azure Event Hubs source for '$eventHubNamespace' / 'diagnostics'."
Write-Host "3. Select or create the Fabric connection interactively; do not paste credentials into this script."
Write-Host "4. Route the stream to '$KqlDatabaseName', then create the Real-Time Dashboard from the KQL database."
Write-Host "`nSuspend F2 when idle: ./scripts/suspend-fabric.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup" -ForegroundColor Yellow