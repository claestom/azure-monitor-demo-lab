<#
.SYNOPSIS
  Provision the AI-stage demo agents and (optionally) simulate GenAI traffic.

.DESCRIPTION
  Run AFTER the optional AI stage (infra/stages/50-ai.bicep) has been deployed. It:
    1. Resolves the Foundry project endpoint + Application Insights connection string
       (discovered from the resource group, or passed explicitly).
    2. Installs the Python deps in workloads/ai/requirements.txt.
    3. Creates the four demo agents (workloads/ai/create_agents.py).
    4. Unless -SkipTraffic, drives simulated conversations (workloads/ai/simulate_traffic.py)
       so token / trace / cost telemetry flows to Application Insights and the Foundry
       portal Observability views + the token metric alerts light up.

  Requires: Python 3.10+, az login with rights on the Foundry project (the lab sub Owner
  qualifies), and the AI stage already deployed.

.PARAMETER ResourceGroup
  Resource group hosting the lab. Defaults to lab.config.json 'resourceGroup' or 'rg-azure-monitor-lab'.

.PARAMETER NamePrefix
  Lab name prefix used to locate the Foundry account + App Insights. Defaults to lab.config.json 'namePrefix' or 'amlab'.

.PARAMETER ProjectEndpoint
  Override the Foundry project endpoint (otherwise discovered from the resource group).

.PARAMETER Conversations
  Number of simulated conversations for the traffic run. Default 150.

.PARAMETER SkipTraffic
  Create the agents but do not simulate traffic.

.EXAMPLE
  ./scripts/setup-ai.ps1

.EXAMPLE
  ./scripts/setup-ai.ps1 -Conversations 300
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup,
  [string] $NamePrefix,
  [string] $ProjectEndpoint,
  [string] $ChatDeployment   = 'gpt-5-mini',
  [string] $RouterDeployment = 'model-router',
  [int]    $Conversations    = 150,
  [switch] $SkipTraffic
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

# Fall back to lab.config.json for RG + prefix when not passed explicitly.
$labConfigPath = Join-Path $repoRoot 'lab.config.json'
if (Test-Path $labConfigPath) {
  $labCfg = Get-Content -Raw $labConfigPath | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace($ResourceGroup) -and -not [string]::IsNullOrWhiteSpace($labCfg.resourceGroup)) { $ResourceGroup = $labCfg.resourceGroup }
  if ([string]::IsNullOrWhiteSpace($NamePrefix)    -and -not [string]::IsNullOrWhiteSpace($labCfg.namePrefix))    { $NamePrefix    = $labCfg.namePrefix }
}
if ([string]::IsNullOrWhiteSpace($ResourceGroup)) { $ResourceGroup = 'rg-azure-monitor-lab' }
if ([string]::IsNullOrWhiteSpace($NamePrefix))    { $NamePrefix    = 'amlab' }

# Subscription guardrail — same gate as deploy.ps1 / post-deploy.ps1.
$targetFile = Join-Path $repoRoot '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting setup-ai."
  }
}

# Python must be on PATH.
$python = (Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command python3 -ErrorAction SilentlyContinue)
if (-not $python) { throw "Python 3.10+ is required on PATH (python/python3) to run the AI demo scripts." }
$python = $python.Source

# --- Resolve the Foundry project endpoint ---
if ([string]::IsNullOrWhiteSpace($ProjectEndpoint)) {
  Write-Step "Discovering the Foundry account in $ResourceGroup"
  # Filter in PowerShell, not via a chained "[?...] | [?...]" --query string — az.cmd on
  # Windows can mangle quoted JMESPath filters before the CLI ever sees them.
  $accounts = az cognitiveservices account list -g $ResourceGroup -o json | ConvertFrom-Json
  $aiAccounts = $accounts | Where-Object { $_.kind -eq 'AIServices' }
  $acct = ($aiAccounts | Where-Object { $_.name -like "ai$NamePrefix*" } | Select-Object -First 1).name
  if ([string]::IsNullOrWhiteSpace($acct)) {
    $acct = ($aiAccounts | Select-Object -First 1).name
  }
  if ([string]::IsNullOrWhiteSpace($acct)) {
    throw "No Foundry (AIServices) account found in $ResourceGroup. Deploy the AI stage (infra/stages/50-ai.bicep) first."
  }
  $projectName = "$NamePrefix-ai-proj"
  $ProjectEndpoint = "https://$acct.services.ai.azure.com/api/projects/$projectName"
  Write-Host "   Account : $acct" -ForegroundColor DarkGray
  Write-Host "   Project : $projectName" -ForegroundColor DarkGray
}
Write-Host "   Endpoint: $ProjectEndpoint" -ForegroundColor Green

# --- App Insights connection string (enables tracing export) ---
Write-Step "Looking up Application Insights connection string (appi-$NamePrefix)"
$appiConn = az monitor app-insights component show -g $ResourceGroup -a "appi-$NamePrefix" --query connectionString -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($appiConn)) {
  Write-Host "   appi-$NamePrefix not found — traffic will run without tracing export." -ForegroundColor Yellow
}

# --- Environment for the Python steps ---
$env:AZURE_AI_PROJECT_ENDPOINT              = $ProjectEndpoint
$env:AZURE_CHAT_DEPLOYMENT                  = $ChatDeployment
$env:AZURE_ROUTER_DEPLOYMENT               = $RouterDeployment
$env:APPLICATIONINSIGHTS_CONNECTION_STRING = $appiConn

# --- Python deps + agents ---
$aiDir = Join-Path $repoRoot 'workloads' 'ai'
Write-Step "Installing Python dependencies"
& $python -m pip install -q -r (Join-Path $aiDir 'requirements.txt')

Write-Step "Creating demo agents"
& $python (Join-Path $aiDir 'create_agents.py')

# --- Traffic ---
if ($SkipTraffic) {
  Write-Step "Skipping traffic simulation (-SkipTraffic). Run it later with:"
  Write-Host "   python workloads/ai/simulate_traffic.py --conversations $Conversations --loop" -ForegroundColor Yellow
} else {
  Write-Step "Simulating $Conversations conversations (token/trace/cost telemetry)"
  & $python (Join-Path $aiDir 'simulate_traffic.py') --conversations $Conversations
}

Write-Host "`n✅ AI stage ready. Explore the Foundry project Observability/Tracing tab and Monitor > Alerts." -ForegroundColor Green
