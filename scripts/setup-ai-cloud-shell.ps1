<#
.SYNOPSIS
  Provision the optional AI demo from Azure Cloud Shell.

.DESCRIPTION
  Pins and verifies the selected subscription, discovers the Microsoft Foundry
  project and Application Insights through core ARM commands, then invokes the
  existing setup-ai.ps1 without requiring optional Azure CLI extensions.

.EXAMPLE
  ./scripts/setup-ai-cloud-shell.ps1 -SubscriptionId <subscription-id> -ResourceGroup rg-azure-monitor-lab
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [int] $Conversations = 150,
  [switch] $SkipTraffic
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

Write-Step "Pinning the Azure subscription"
az account set --subscription $SubscriptionId | Out-Null
$activeSubscriptionId = az account show --query id -o tsv
if ($activeSubscriptionId -ne $SubscriptionId) {
  throw "Subscription guardrail failed: expected '$SubscriptionId', got '$activeSubscriptionId'."
}

Write-Step "Discovering Microsoft Foundry through ARM"
$accounts = az resource list `
  --resource-group $ResourceGroup `
  --resource-type Microsoft.CognitiveServices/accounts `
  -o json | ConvertFrom-Json
$account = @($accounts | Where-Object {
  $_.kind -eq 'AIServices' -and $_.name -like "ai$NamePrefix*"
}) | Select-Object -First 1
if (-not $account) {
  $account = @($accounts | Where-Object { $_.kind -eq 'AIServices' }) | Select-Object -First 1
}
if (-not $account) {
  throw "No Microsoft Foundry AIServices account was found in '$ResourceGroup'."
}

$projectEndpoint = "https://$($account.name).services.ai.azure.com/api/projects/$NamePrefix-ai-proj"
Write-Info "Account: $($account.name)"
Write-Info "Project endpoint: $projectEndpoint"

Write-Step "Resolving Application Insights through ARM"
$appInsights = az resource list `
  --resource-group $ResourceGroup `
  --resource-type Microsoft.Insights/components `
  --query "[?name=='appi-$NamePrefix'] | [0].{id:id,name:name}" `
  -o json | ConvertFrom-Json
if (-not $appInsights) {
  throw "Application Insights 'appi-$NamePrefix' was not found in '$ResourceGroup'."
}

$appInsightsConnectionString = az resource show `
  --ids $appInsights.id `
  --api-version 2020-02-02 `
  --query properties.ConnectionString `
  -o tsv
if ([string]::IsNullOrWhiteSpace($appInsightsConnectionString)) {
  throw "Application Insights connection string lookup returned no value."
}

Write-Step "Running AI agent and traffic setup"
$setupAiParameters = @{
  ResourceGroup = $ResourceGroup
  NamePrefix = $NamePrefix
  ProjectEndpoint = $projectEndpoint
  AppInsightsConnectionString = $appInsightsConnectionString
  Conversations = $Conversations
}
if ($SkipTraffic) {
  $setupAiParameters.SkipTraffic = $true
}
& (Join-Path $PSScriptRoot 'setup-ai.ps1') @setupAiParameters