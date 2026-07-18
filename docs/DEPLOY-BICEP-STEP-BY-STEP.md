# Azure Monitor Demo Lab - Step-by-Step Deployment with Bicep

This guide shows how to deploy the lab in controlled stages so you can enable scenarios progressively instead of shipping everything at once.

## 1) What you have today

The current repo deploys the full lab from:
- infra/main.bicep
- scripts/deploy.ps1

That is still the fastest path for internal demo prep. For customer-facing step-by-step delivery, use the stage model below.

## 2) Guardrails (must-do)

1. Pin subscription before every write:
   - az account set --subscription <your-subscription-id>
   - az account show --query "{name:name,id:id,tenantId:tenantId}" -o table
2. Keep using scripts/deploy.ps1 subscription guardrails (.azure-target.json).
3. Use az deployment what-if before each stage.

### Planning aid

For workshop planning and customer expectation-setting, use:
- [CUSTOMER-STAGE-HANDOUT.md](CUSTOMER-STAGE-HANDOUT.md)

### Per-stage deep dives (deployed inventory + speaker notes + UI/CLI walkthroughs)

- [STAGE-A-FOUNDATION.md](STAGE-A-FOUNDATION.md)
- [STAGE-B-WORKLOADS.md](STAGE-B-WORKLOADS.md)
- [STAGE-C-ALERTING.md](STAGE-C-ALERTING.md)
- [STAGE-D-SECURITY-POSTURE.md](STAGE-D-SECURITY-POSTURE.md)
- [STAGE-E-OPTIONAL-ADVANCED.md](STAGE-E-OPTIONAL-ADVANCED.md)

## 3) Stage model (recommended)

Deploy in this order.

1. Stage A - Core observability foundation
2. Stage B - Workload telemetry and dashboards
3. Stage C - Alerts and auto-mitigation
4. Stage D - Security posture scenarios
5. Stage E - Optional advanced/security add-ons

## 4) Stage details (scenarios + deployed services)

Use this as the workshop script: each stage adds a bounded set of capabilities and scenarios.

| Stage | High-level scenario goals | Scenario IDs (from DEMO-SCENARIOS.md) | Azure services/resources deployed |
|---|---|---|---|
| Stage A - Core observability foundation | Establish the telemetry backbone and governance baseline. | 1, 5, 6, 9 (foundation portions) | Resource group, central LAW + AppInsights LAW, Application Insights (workspace-based), Azure Monitor Workspace, Data Collection Endpoint, VNet/NSG baseline, baseline diagnostic settings and policy wiring, shared storage and Event Hub foundations. |
| Stage B - Workload telemetry and dashboards | Onboard compute and app workloads into the monitoring plane and expose dashboards. | 2, 3, 4, 22, 28, 29, 30, 31, 32, 34, 35, 36, 42 | Linux/Windows VMs + AMA/DCR association, AKS + Container Insights + Managed Prometheus, Managed Grafana, App Service plan/web app + App Insights connection, workbook(s), saved queries, KQL functions, availability test, connection monitor, flow logs, key vault/storage insights surfaces. |
| Stage C - Alerts and response | Add actionable detection and automated response controls. | 7, 8, 12, 15, 17, 19, 23, 37 | Action Group, metric alerts, scheduled query alerts, activity log alerts (service/resource health), AMBA baseline alerts, dynamic thresholds, VMSS predictive autoscale assets, alert processing rules, auto-mitigation Logic App webhook path. |
| Stage D - Security posture (Azure Monitor native) | Build non-SIEM security posture detections directly in Azure Monitor. | 27, 47, 48, 49 | Log Analytics RBAC model (workspace/table/row scope), AzureActivity routing prerequisite, scheduled query alerts for control-plane drift, role assignment changes, and exfil early-warning correlation, alert routing via existing Action Group. |
| Stage E - Optional advanced/security add-ons | Layer advanced SOC and reliability preview capabilities. | 43, 44, 45, 46 | Optional Sentinel onboarding + analytics rule, search job/restore script workflow enablement, health model resources, SLI identity prerequisites and helper scripts, optional service-group/SLI setup flow. |

### Stage dependency chain

1. Stage A is mandatory for all other stages.
2. Stage B depends on Stage A outputs (workspaces/network/monitor workspace).
3. Stage C depends on Stage B resources for alert scopes.
4. Stage D depends on Stage A ingestion and Stage C action routing.
5. Stage E depends on prior stages, especially LAW and monitoring identities.

### Stage acceptance criteria (high level)

1. Stage A done: data lands in LAW and baseline diagnostics/policy are visible.
2. Stage B done: VM/AKS/App Service telemetry and workbook panels render.
3. Stage C done: at least one alert test reaches the Action Group.
4. Stage D done: scenario 47/48/49 queries return data and alert rules evaluate.
5. Stage E done: optional feature endpoints/blades become accessible and testable.

## 5) Practical deployment commands (stage-by-stage)

This section uses the existing main template with targeted parameter toggles where possible, then overlays scenario-specific resources.

### Step 0 - Bootstrap inputs (recommended)

The `--parameters @infra/main.parameters.json` files referenced below are **generated** from a single central [`lab.config.json`](../lab.config.json.example) (gitignored). From the repo root:

```powershell
Copy-Item lab.config.json.example lab.config.json
notepad lab.config.json   # fill in subscriptionId, tenantId, alertEmail, vmAdminPassword, ...
./scripts/sync-config.ps1 # regenerates infra/main.parameters.json + .azure-target.json + terraform/stages.tfvars
```

Alternatively, hand-edit `infra/main.parameters.json` directly (also gitignored; see `infra/main.parameters.json.template` for the shape). Either way, the rest of this guide assumes `infra/main.parameters.json` exists.

### Stage A deploy

1. Validate:

```powershell
$sub='<your-subscription-id>'
az account set --subscription $sub
az account show --query "{name:name,id:id,tenantId:tenantId}" -o table
az deployment group what-if -g rg-azure-monitor-lab --template-file infra/main.bicep --parameters @infra/main.parameters.json deployLinuxVm=false deployWindowsVm=false aksNodeCount=0 enableSentinel=false
```

2. Deploy:

```powershell
az deployment group create -g rg-azure-monitor-lab --name stage-a-foundation --template-file infra/main.bicep --parameters @infra/main.parameters.json deployLinuxVm=false deployWindowsVm=false aksNodeCount=0 enableSentinel=false
```

Notes:
- The current main.bicep still contains resources beyond foundation. For strict staging, create dedicated stage templates under infra/stages and move resources there over time.

### Stage B deploy

```powershell
az deployment group create -g rg-azure-monitor-lab --name stage-b-workloads --template-file infra/main.bicep --parameters @infra/main.parameters.json deployLinuxVm=true deployWindowsVm=true aksNodeCount=1 enableSentinel=false
```

### Stage C deploy

```powershell
az deployment group create -g rg-azure-monitor-lab --name stage-c-alerts --template-file infra/main.bicep --parameters @infra/main.parameters.json enableSentinel=false
```

### Stage D deploy

1. Ensure AzureActivity is routed to lab LAW:

```powershell
$rg='rg-azure-monitor-lab'
$lawArmId = az resource show -g $rg -n law-amlab-central --resource-type Microsoft.OperationalInsights/workspaces --query id -o tsv
$logs = '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"ServiceHealth","enabled":true},{"category":"Alert","enabled":true},{"category":"Recommendation","enabled":true},{"category":"Policy","enabled":true},{"category":"Autoscale","enabled":true},{"category":"ResourceHealth","enabled":true}]'
az monitor diagnostic-settings subscription create --name amlab-activity-to-law --location global --workspace $lawArmId --logs $logs
```

2. Apply scenario 47/48/49 query alerts (recommended as a dedicated Bicep module in infra/modules/security-posture-alerts.bicep).

### Stage E deploy

```powershell
az deployment group create -g rg-azure-monitor-lab --name stage-e-optional --template-file infra/main.bicep --parameters @infra/main.parameters.json enableSentinel=true
```

## 6) Recommended repo evolution for clean staging

For a cleaner customer story, split orchestration into:
- infra/stages/00-foundation.bicep
- infra/stages/10-workloads.bicep
- infra/stages/20-alerting.bicep
- infra/stages/30-security-posture.bicep
- infra/stages/40-optional-advanced.bicep

Each stage should accept prior-stage outputs as parameters and be deployable idempotently.

## 7) Validation checklist per stage

After each stage:
1. az deployment group show -g rg-azure-monitor-lab -n <stage-name>
2. Verify expected resources exist.
3. Run at least one saved query relevant to that stage.
4. For security stage, run:

```kql
AzureActivity
| where TimeGenerated > ago(1d)
| summarize count()
```

If count is zero, security-posture scenarios 47/48/49 will not fire.

## 8) Tearing down the lab

When done, delete the resource group. ARM cascade-deletes everything in it.

### Step 1 - Pin subscription

```powershell
$sub='<your-subscription-id>'
$rg='rg-azure-monitor-lab'
az account set --subscription $sub
az account show --query "{name:name,id:id,tenantId:tenantId}" -o table
```

### Step 2 - Delete the resource group

```powershell
az group delete -n $rg --yes --no-wait
```

This removes every resource the staged Bicep deployments created in this RG (LAWs, App Insights, VMs, AKS, App Service, DCRs, alerts, action group, workbooks, etc.) plus the deployment history records.

### Step 3 - Clean up artifacts that live outside the RG

A few resources are subscription-scoped or live in `NetworkWatcherRG` and survive RG deletion.

1. Soft-deleted Log Analytics workspaces (14-day grace period; names stay reserved):

```powershell
az monitor log-analytics workspace list-deleted-workspaces --subscription $sub --query "[?contains(name,'amlab')]" -o table
# Permanent purge if needed:
# az rest --method delete --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.OperationalInsights/locations/northeurope/deletedWorkspaces/<name>?api-version=2023-09-01"
```

2. Soft-deleted Application Insights components (also 14-day grace):

```powershell
az monitor app-insights component list-deleted --subscription $sub --query "[?contains(name,'amlab')]" -o table
```

3. NSG/VNet flow logs in `NetworkWatcherRG` (Stage B creates them outside the lab RG):

```powershell
az network watcher flow-log list -l northeurope --subscription $sub --query "[?contains(name,'amlab')].{name:name,enabled:enabled}" -o table
# az network watcher flow-log delete -l northeurope -n <flowLogName> --subscription $sub
```

4. Custom role definition from Stage D (`AMLAB - Granular Log Reader`). Auto-removed once no scopes reference it; force-delete if it lingers:

```powershell
az role definition list --custom-role-only true --subscription $sub --query "[?starts_with(roleName,'AMLAB - Granular Log Reader')]" -o table
# az role definition delete --name "AMLAB - Granular Log Reader" --subscription $sub
```

5. Sentinel onboarding (if Stage E enabled it) lives on the LAW, so it goes with the RG. No extra action needed.

### Step 4 - Confirm

```powershell
az group exists -n $rg --subscription $sub   # false once the async delete completes
```
