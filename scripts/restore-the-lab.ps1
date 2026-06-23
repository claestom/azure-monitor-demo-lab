<#
.SYNOPSIS
  Reverse break-the-lab.ps1: restart VMs, fix AKS image, restore healthy load-gen.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $ResourceGroup
)
$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Green }

# Subscription guardrail
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting restore-the-lab."
  }
}

Write-Step "Starting all VMs in $ResourceGroup"
$vms = az vm list -g $ResourceGroup --query "[].name" -o tsv
foreach ($vm in $vms) {
  Write-Host "  starting $vm"
  az vm start -g $ResourceGroup -n $vm --no-wait | Out-Null
}

Write-Step "Restoring AKS frontend image"
kubectl -n demo set image deployment/hello-frontend hello=mcr.microsoft.com/azuredocs/aks-helloworld:v1 | Out-Null

Write-Step "Restoring healthy load-gen ConfigMap"
$loadgenYaml = Join-Path $PSScriptRoot '..' 'workloads' 'k8s' '02-loadgen.yaml'
$webAppHost  = az webapp list -g $ResourceGroup --query "[?starts_with(name,'app-')] | [0].defaultHostName" -o tsv
$webAppUrl   = "https://$webAppHost"
$rendered    = Join-Path $env:TEMP "amlab-restore-$([guid]::NewGuid().ToString('N')).yaml"
(Get-Content -Raw $loadgenYaml).Replace('__APP_SERVICE_URL__', "'$webAppUrl'") | Set-Content -Encoding UTF8 $rendered
kubectl apply -f $rendered | Out-Null
Remove-Item $rendered -Force

Write-Host "`n✅ Lab restored. Workbook should return to Green within ~3 minutes." -ForegroundColor Green

# Drop an App Insights release annotation so the recovery is visible on charts.
$annot = Join-Path $PSScriptRoot 'send-release-annotation.ps1'
if (Test-Path $annot) {
  & $annot -ResourceGroup $ResourceGroup -Name "restore-$(Get-Date -Format yyyyMMdd-HHmmss)" -Category 'Deployment'
}
