<#
.SYNOPSIS
  Intentionally degrade resources so the Traffic-Lights workbook turns Orange/Red.
.DESCRIPTION
  - Stops both VMs (heartbeat ages out → Red after 15 min)
  - Scales the AKS frontend to 0 + crashloops it to bump restart counts (Orange/Red)
  - Bumps load-gen failure rate by editing the ConfigMap (more 5xx in App Service)
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $ResourceGroup
)
$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Magenta }

# Subscription guardrail
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting break-the-lab."
  }
}

Write-Step "Stopping all VMs in $ResourceGroup (heartbeat will go Red)"
$vms = az vm list -g $ResourceGroup --query "[].name" -o tsv
foreach ($vm in $vms) {
  Write-Host "  deallocating $vm"
  az vm deallocate -g $ResourceGroup -n $vm --no-wait | Out-Null
}

Write-Step "Crashlooping the AKS frontend (Orange — restart spike)"
kubectl -n demo set image deployment/hello-frontend hello=mcr.microsoft.com/azuredocs/aks-helloworld:doesnotexist | Out-Null

Write-Step "Boosting load-gen failure rate to 80% (App Service goes Red)"
$cm = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-script
  namespace: demo
data:
  loadtest.js: |
    import http from 'k6/http';
    import { sleep } from 'k6';
    export const options = { vus: 5, duration: '50s' };
    export default function () {
      // 80% of requests hit a forced-failure path
      if (Math.random() < 0.8) {
        http.get('https://example.invalid/' + Math.random());
      } else {
        http.get('http://localhost/');
      }
      sleep(1);
    }
"@
$tmp = Join-Path $env:TEMP "amlab-broken-cm-$([guid]::NewGuid().ToString('N')).yaml"
$cm | Set-Content -Encoding UTF8 $tmp
kubectl apply -f $tmp | Out-Null
Remove-Item $tmp -Force

Write-Host "`n💥 Lab is now broken on purpose. Refresh the workbook in 1-3 minutes." -ForegroundColor Magenta
Write-Host "Run scripts/restore-the-lab.ps1 to bring everything back." -ForegroundColor Yellow

# Drop an App Insights release annotation tagged 'Incident' so the chart shows the moment.
$annot = Join-Path $PSScriptRoot 'send-release-annotation.ps1'
if (Test-Path $annot) {
  & $annot -ResourceGroup $ResourceGroup -Name "break-the-lab-$(Get-Date -Format yyyyMMdd-HHmmss)" -Category 'Incident'
}
