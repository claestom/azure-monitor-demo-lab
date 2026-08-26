<#
.SYNOPSIS
  Post-deploy steps: push sample app to App Service + apply AKS workloads.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $WebAppName,
  [Parameter(Mandatory)] [string] $AksName,
  [Parameter(Mandatory)] [string] $WebAppHost,
  [string] $CentralLawName
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# Subscription guardrail
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting post-deploy."
  }
}

# 1. Build + zip-deploy the bundled .NET 8 minimal API (workloads/webapp/AmlabHello)
#    so App Insights gets requests/dependencies/failures from a real app.
Write-Step "Disabling Kudu build and setting startup command"
az webapp config appsettings set `
  --resource-group $ResourceGroup --name $WebAppName `
  --settings SCM_DO_BUILD_DURING_DEPLOYMENT=false `
  --output none
az webapp config set `
  --resource-group $ResourceGroup --name $WebAppName `
  --startup-file 'dotnet AmlabHello.dll' `
  --output none
Start-Sleep -Seconds 30

Write-Step "Publishing AmlabHello (workloads/webapp) and zip-deploying"
$pub = Join-Path $env:TEMP "amlab-pub-$([guid]::NewGuid().ToString('N'))"
$csproj = Join-Path $PSScriptRoot '..' 'workloads' 'webapp' 'AmlabHello.csproj'
dotnet publish $csproj -c Release -o $pub --nologo --verbosity quiet
$zip = "$pub.zip"
Compress-Archive -Path "$pub\*" -DestinationPath $zip -Force
$deployOutput = ''
$deployExitCode = 1
$scmRestartRetries = 0
$zipDeployRetries = 0
do {
  $deployOutput = & az webapp deploy `
    --resource-group $ResourceGroup --name $WebAppName `
    --src-path $zip --type zip --restart true --async true --track-status false --output none 2>&1 | Out-String
  $deployExitCode = $LASTEXITCODE
  $scmRestarted = $deployOutput -match 'SCM container restart|management operation and a deployment operation in quick succession'
  $zipDeploymentFailed = $deployOutput -match 'Zip deployment failed|Status Code: 502|Deployment Failed.*OneDeploy'
  if ($deployExitCode -ne 0 -and $scmRestarted -and $scmRestartRetries -lt 2) {
    $scmRestartRetries++
    Write-Host "   SCM restarted during ZIP deployment. Waiting 60 seconds before retry $scmRestartRetries/2..." -ForegroundColor Yellow
    Start-Sleep -Seconds 60
  } elseif ($deployExitCode -ne 0 -and $zipDeploymentFailed -and $zipDeployRetries -lt 2) {
    $zipDeployRetries++
    Write-Host "   OneDeploy failed after upload. Waiting 60 seconds before retry $zipDeployRetries/2..." -ForegroundColor Yellow
    Start-Sleep -Seconds 60
  } else {
    break
  }
} while ($true)

# Async deployment avoids Kudu's unreliable long startup poll. Wait quietly for the
# public endpoint before applying workloads that depend on the App Service URL.
if ($deployExitCode -ne 0) {
  throw "App Service ZIP upload failed. Details:`n$deployOutput"
}

$siteReachable = $false
for ($i = 0; $i -lt 36; $i++) {
  try {
    $response = Invoke-WebRequest -Uri "https://$WebAppHost/" -UseBasicParsing -TimeoutSec 15
    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
      $siteReachable = $true
      break
    }
  } catch { }
  Start-Sleep -Seconds 10
}
if (-not $siteReachable) {
  throw "App Service ZIP upload was accepted, but the site did not become reachable within 6 minutes. Check the App Service runtime logs."
}
Write-Host "   App Service ZIP upload accepted and the site is reachable." -ForegroundColor Green
Remove-Item -Recurse -Force $pub
Remove-Item -Force $zip

# 2. Get AKS credentials and apply the workload + k6 load generator
Write-Step "Getting AKS credentials"
az aks get-credentials --resource-group $ResourceGroup --name $AksName --overwrite-existing --output none

Write-Step "Applying frontend deployment + service"
$frontendYaml = Join-Path $PSScriptRoot '..' 'workloads' 'k8s' '01-frontend.yaml'
kubectl apply -f $frontendYaml

Write-Step "Substituting App Service URL into the k6 CronJob and applying"
$loadgenTemplate = Join-Path $PSScriptRoot '..' 'workloads' 'k8s' '02-loadgen.yaml'
$loadgenRendered = Join-Path $env:TEMP "amlab-loadgen-$([guid]::NewGuid().ToString('N')).yaml"
$webAppUrl = "https://$WebAppHost"
(Get-Content -Raw $loadgenTemplate).Replace('__APP_SERVICE_URL__', "'$webAppUrl'") | Set-Content -Encoding UTF8 $loadgenRendered
kubectl apply -f $loadgenRendered
Remove-Item $loadgenRendered -Force

# FEATURE 4 — Apply the OpenTelemetry distributed-tracing demo (AKS → App Service).
Write-Step "Looking up App Insights connection string for the OTel caller"
$appiName = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/components --query "[0].name" -o tsv
$appiConn = az monitor app-insights component show -g $ResourceGroup -a $appiName --query connectionString -o tsv

Write-Step "Rendering and applying OTel caller deployment"
$otelTemplate = Join-Path $PSScriptRoot '..' 'workloads' 'k8s' '04-otel-caller.yaml'
$otelRendered = Join-Path $env:TEMP "amlab-otel-$([guid]::NewGuid().ToString('N')).yaml"
(Get-Content -Raw $otelTemplate).Replace('__APP_SERVICE_URL__', $webAppUrl).Replace('__APPI_CONN_STR__', $appiConn) | Set-Content -Encoding UTF8 $otelRendered
kubectl apply -f $otelRendered
Remove-Item $otelRendered -Force

# NEW — Node.js auto-instrumentation via @azure/monitor-opentelemetry (GA distro).
Write-Step "Rendering and applying Node.js OTel deployment"
$nodeTemplate = Join-Path $PSScriptRoot '..' 'workloads' 'k8s' '05-nodeapp-otel.yaml'
$nodeRendered = Join-Path $env:TEMP "amlab-nodeapp-$([guid]::NewGuid().ToString('N')).yaml"
(Get-Content -Raw $nodeTemplate).Replace('__APP_SERVICE_URL__', $webAppUrl).Replace('__APPI_CONN_STR__', $appiConn) | Set-Content -Encoding UTF8 $nodeRendered
kubectl apply -f $nodeRendered
Remove-Item $nodeRendered -Force

# 3. Wait for the LoadBalancer IP and print it
Write-Step "Waiting up to 3 minutes for the AKS LoadBalancer IP..."
$externalIp = $null
for ($i = 0; $i -lt 18; $i++) {
  $externalIp = kubectl get svc hello-frontend -n demo -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
  if ($externalIp) { break }
  Start-Sleep -Seconds 10
}

if ($externalIp) {
  Write-Host "`nAKS frontend exposed at: http://$externalIp" -ForegroundColor Green
} else {
  Write-Host "`nLoadBalancer IP not yet assigned. Check with: kubectl get svc -n demo" -ForegroundColor Yellow
}

Write-Host "`nApp Service URL : https://$WebAppHost" -ForegroundColor Green
Write-Host "Trigger an immediate first load-test run with:" -ForegroundColor Yellow
Write-Host "  kubectl create job --from=cronjob/loadgen loadgen-now -n demo" -ForegroundColor Yellow

# 4. Assign Monitoring Metrics Publisher role on the custom-logs DCR
#    so send-custom-logs.ps1 can ingest data via the Logs Ingestion API.
Write-Step "Assigning 'Monitoring Metrics Publisher' role for custom log ingestion"
$currentUser = az ad signed-in-user show -o json | ConvertFrom-Json
$dcrInfo = az resource list -g $ResourceGroup --resource-type "Microsoft.Insights/dataCollectionRules" -o json | ConvertFrom-Json
$customLogsDcr = $dcrInfo | Where-Object { $_.name -like '*customlogs*' }
if ($customLogsDcr) {
  $existing = az role assignment list --assignee $currentUser.id --scope $customLogsDcr.id --role "Monitoring Metrics Publisher" -o json | ConvertFrom-Json
  if ($existing.Count -eq 0) {
    az role assignment create --assignee $currentUser.id --role "Monitoring Metrics Publisher" --scope $customLogsDcr.id -o none 2>$null
    Write-Host "  Role assigned. NOTE: RBAC propagation on the Monitor data plane can take up to 30 minutes." -ForegroundColor Yellow
  } else {
    Write-Host "  Role already assigned." -ForegroundColor Green
  }
} else {
  Write-Host "  Custom logs DCR not found — skipping." -ForegroundColor Yellow
}

# 5. Create the hourly Perf -> Perf_Hourly_CL summary rule (scenario 21 prereq).
#    Bicep created the destination table; the rule itself is REST-only.
Write-Step "Creating summary rule rule-perf-hourly (scenario 21 prereq)"
$summaryRuleScript = Join-Path $PSScriptRoot 'create-summary-rule.ps1'
if (Test-Path $summaryRuleScript) {
  try {
    & $summaryRuleScript -ResourceGroup $ResourceGroup -WorkspaceName $CentralLawName
  } catch {
    Write-Host "  Summary rule provisioning failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Continuing — re-run scripts/create-summary-rule.ps1 manually." -ForegroundColor Yellow
  }
} else {
  Write-Host "  create-summary-rule.ps1 not found — skipping." -ForegroundColor Yellow
}

# 6. Post a release annotation on App Insights so the deploy is visible on charts.
Write-Step "Posting Application Insights release annotation"
$releaseScript = Join-Path $PSScriptRoot 'send-release-annotation.ps1'
if (Test-Path $releaseScript) {
  & $releaseScript -ResourceGroup $ResourceGroup -Name "deploy-$(Get-Date -Format yyyyMMdd-HHmmss)" -Category 'Deployment'
} else {
  Write-Host "  send-release-annotation.ps1 not found — skipping." -ForegroundColor Yellow
}
