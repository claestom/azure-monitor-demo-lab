<#
.SYNOPSIS
  Bootstrap and run the Azure Monitor Demo Lab post-deployment setup from Azure Cloud Shell.

.DESCRIPTION
  Downloads only the scripts and workload files required by post-staged-deploy.ps1,
  verifies the selected subscription, and runs the portal post-deployment setup.
  Use -SetupAi when the optional AI stage was enabled in the portal.

.EXAMPLE
  ./cloud-shell-post-deploy.ps1 -SubscriptionId <subscription-id> -ResourceGroup rg-azure-monitor-lab

.EXAMPLE
  ./cloud-shell-post-deploy.ps1 -SubscriptionId <subscription-id> -ResourceGroup rg-azure-monitor-lab -SetupAi
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [switch] $SetupAi,
  [int] $Conversations = 150,
  [string] $RepositoryRef = 'master',
  [string] $WorkDirectory = (Join-Path $HOME '.azure-monitor-demo-lab')
)

$ErrorActionPreference = 'Stop'
$repositoryBaseUrl = "https://raw.githubusercontent.com/claestom/azure-monitor-demo-lab/$RepositoryRef"
$curl = (Get-Command curl -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

foreach ($commandName in @('az', 'kubectl', 'dotnet')) {
  if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
    throw "Required command '$commandName' is not available in this Cloud Shell session."
  }
}
if ($SetupAi -and -not ((Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command python3 -ErrorAction SilentlyContinue))) {
  throw "Python 3.10+ is required when -SetupAi is specified."
}

function Get-RepositoryFile {
  param([Parameter(Mandatory)] [string] $RelativePath)

  $destination = Join-Path $WorkDirectory $RelativePath
  $directory = Split-Path $destination -Parent
  New-Item -ItemType Directory -Path $directory -Force | Out-Null

  Write-Host "Downloading $RelativePath" -ForegroundColor DarkGray
  & $curl --fail --silent --show-error --location `
    "$repositoryBaseUrl/$RelativePath" --output $destination
  if ($LASTEXITCODE -ne 0) {
    throw "Download failed for $RelativePath"
  }
}

$requiredFiles = @(
  'scripts/post-staged-deploy.ps1'
  'scripts/post-deploy.ps1'
  'scripts/create-summary-rule.ps1'
  'scripts/send-release-annotation.ps1'
  'scripts/setup-health-model.ps1'
  'scripts/setup-slis.ps1'
  'workloads/webapp/AmlabHello.csproj'
  'workloads/webapp/Program.cs'
  'workloads/webapp/appsettings.json'
  'workloads/k8s/01-frontend.yaml'
  'workloads/k8s/02-loadgen.yaml'
  'workloads/k8s/04-otel-caller.yaml'
  'workloads/k8s/05-nodeapp-otel.yaml'
)

if ($SetupAi) {
  $requiredFiles += @(
    'scripts/setup-ai.ps1'
    'workloads/ai/requirements.txt'
    'workloads/ai/create_agents.py'
    'workloads/ai/simulate_traffic.py'
  )
}

foreach ($relativePath in $requiredFiles) {
  Get-RepositoryFile -RelativePath $relativePath
}

az account set --subscription $SubscriptionId | Out-Null
$activeSubscriptionId = az account show --query id -o tsv
if ($activeSubscriptionId -ne $SubscriptionId) {
  throw "Subscription guardrail failed: expected $SubscriptionId, got $activeSubscriptionId"
}

Write-Host "Running post-deployment setup in $ResourceGroup" -ForegroundColor Cyan
& (Join-Path $WorkDirectory 'scripts/post-staged-deploy.ps1') `
  -ResourceGroup $ResourceGroup `
  -NamePrefix $NamePrefix

if ($SetupAi) {
  Write-Host "Running optional AI agent and traffic setup" -ForegroundColor Cyan
  & (Join-Path $WorkDirectory 'scripts/setup-ai.ps1') `
    -ResourceGroup $ResourceGroup `
    -NamePrefix $NamePrefix `
    -Conversations $Conversations
}

Write-Host "`nCloud Shell post-deployment setup completed." -ForegroundColor Green