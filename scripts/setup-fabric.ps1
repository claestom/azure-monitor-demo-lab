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
  [string] $EventstreamName = 'AzureMonitorEvents',
  [ValidateRange(5, 120)] [int] $MaxOperationMinutes = 30,
  [switch] $Teardown
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
  param(
    [Parameter(Mandatory)] [string] $OperationUrl,
    [string] $OperationId = ''
  )

  if ($OperationUrl.StartsWith('/')) {
    $OperationUrl = "https://api.fabric.microsoft.com$OperationUrl"
  }
  if ([string]::IsNullOrWhiteSpace($OperationId)) {
    $OperationId = ($OperationUrl.TrimEnd('/') -split '/')[-1]
  }

  $deadline = [DateTime]::UtcNow.AddMinutes($MaxOperationMinutes)
  $lastStatus = ''
  $operation = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    $pollHeaders = $null
    $operation = Invoke-RestMethod `
      -Method Get `
      -Uri $OperationUrl `
      -Headers $script:fabricHeaders `
      -ResponseHeadersVariable pollHeaders
    if ($operation.status -ne $lastStatus) {
      $progress = if ($null -ne $operation.percentComplete) { " ($($operation.percentComplete)%)" } else { '' }
      Write-Info "Fabric operation $OperationId`: $($operation.status)$progress"
      $lastStatus = $operation.status
    }
    if ($operation.status -eq 'Succeeded') { return }
    if ($operation.status -in @('Failed', 'Cancelled')) {
      $errorDetails = $operation.error | ConvertTo-Json -Depth 8 -Compress
      throw "Fabric operation '$OperationId' ended with status '$($operation.status)': $errorDetails"
    }

    $retryAfter = 10
    if ($pollHeaders -and $pollHeaders.'Retry-After') {
      $parsedRetryAfter = 0
      if ([int]::TryParse(($pollHeaders.'Retry-After' | Select-Object -First 1), [ref]$parsedRetryAfter)) {
        $retryAfter = [Math]::Min([Math]::Max($parsedRetryAfter, 1), 60)
      }
    }
    Start-Sleep -Seconds $retryAfter
  }

  $lastOperationStatus = if ($operation -and $operation.status) { $operation.status } else { '<unknown>' }
  $lastUpdated = if ($operation.lastUpdatedTimeUtc) { $operation.lastUpdatedTimeUtc } else { '<unknown>' }
  $percentComplete = if ($null -ne $operation.percentComplete) { $operation.percentComplete } else { '<unknown>' }
  throw "Fabric operation '$OperationId' did not complete within $MaxOperationMinutes minutes. Last status: '$lastOperationStatus', progress: $percentComplete%, last updated: $lastUpdated. The operation may still complete; rerun this script safely to discover and reuse the item. Operation URL: $OperationUrl"
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
  $operationId = $responseHeaders.'x-ms-operation-id' | Select-Object -First 1
  if ($operationUrl) {
    Wait-FabricOperation -OperationUrl $operationUrl -OperationId $operationId
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
$active = az account show --query '{id:id,tenantId:tenantId,userName:user.name,userType:user.type}' -o json | ConvertFrom-Json
if ($active.id -ne $SubscriptionId) {
  throw "Subscription guardrail failed: expected '$SubscriptionId', got '$($active.id)'."
}
Write-Info "Subscription: $($active.id)"
Write-Info "Tenant: $($active.tenantId)"
Write-Info "Signed-in identity: $($active.userName) ($($active.userType))"

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

$capacityDetails = az resource show `
  --ids $armCapacity.id `
  --api-version 2023-11-01 `
  --query '{state:properties.state,administrators:properties.administration.members}' `
  -o json | ConvertFrom-Json
$capacityAdministrators = @($capacityDetails.administrators)
Write-Info "Capacity state: $($capacityDetails.state)"
Write-Info "Capacity administrators: $($capacityAdministrators -join ', ')"
if ($active.userType -ne 'user') {
  throw "Fabric setup requires an interactive Microsoft Entra user. Azure CLI is signed in as '$($active.userType)'."
}
if ($capacityAdministrators -notcontains $active.userName) {
  throw "Signed-in user '$($active.userName)' is not a configured Fabric capacity administrator. Redeploy with fabricAdminEmail set to this tenant user UPN, or sign in as one of: $($capacityAdministrators -join ', ')."
}

Write-Step 'Authenticating to the Fabric API'
$fabricToken = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
if ([string]::IsNullOrWhiteSpace($fabricToken)) { throw 'Could not acquire a Microsoft Fabric API token.' }
$script:fabricHeaders = @{ Authorization = "Bearer $fabricToken" }

if ($Teardown) {
  Write-Step 'Removing the Fabric workspace and contained items'
  $workspace = Get-CollectionItem -Path 'workspaces' -DisplayName $WorkspaceName
  if (-not $workspace) {
    Write-Info "Workspace '$WorkspaceName' does not exist; nothing to remove."
    return
  }

  Invoke-RestMethod `
    -Method Delete `
    -Uri "$fabricApi/workspaces/$($workspace.id)" `
    -Headers $script:fabricHeaders | Out-Null
  Write-Host "Fabric workspace '$WorkspaceName' and its contained items were deleted." -ForegroundColor Green
  return
}

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
  Write-Info 'Listen authorization rule: diagnostics-listen'
}

Write-Host "`nFabric setup completed." -ForegroundColor Green
Write-Host "Workspace: https://app.fabric.microsoft.com/groups/$($workspace.id)"
Write-Host "Eventhouse ID: $($eventhouse.id)"
Write-Host "KQL database ID: $($kqlDatabase.id)"
Write-Host "Eventstream ID: $($eventstream.id)"
Write-Host "`nManual Eventstream connection:" -ForegroundColor Cyan
Write-Host "1. Open '$EventstreamName', switch to Edit mode, and select Add source > Connect data sources > Azure Event Hubs."
Write-Host "2. Create a Shared Access Key connection to namespace '$eventHubNamespace' and Event Hub 'diagnostics'."
Write-Host "3. Use Shared Access Key Name 'diagnostics-listen' and its primary or secondary key from the Event Hubs namespace."
Write-Host "4. Set Consumer group to '`$Default', Data format to JSON, Data gateway to none, then add the source."
Write-Host "5. Add an Eventhouse destination, select the existing Eventhouse and '$KqlDatabaseName', and create a new destination table such as 'AzureDiagnosticsRaw'."
Write-Host "6. Select Publish, confirm events arrive, then create the Real-Time Dashboard from '$KqlDatabaseName'."
Write-Host "The connection key is entered only in Fabric; do not paste it into this script or source control."
Write-Host "`nSuspend F2 when idle: ./scripts/suspend-fabric.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup" -ForegroundColor Yellow