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
- [STAGE-AI.md](STAGE-AI.md)

## 3) Stage model (recommended)

Deploy in this order.

1. Stage A - Core observability foundation
2. Stage B - Workload telemetry and dashboards
3. Stage C - Alerts and auto-mitigation
4. Stage D - Security posture scenarios
5. Stage E - Optional advanced/security add-ons
6. Stage AI - Optional Microsoft Foundry GenAI workload (off by default)

## 4) Stage details (scenarios + deployed services)

Use this as the workshop script: each stage adds a bounded set of capabilities and scenarios.

| Stage | High-level scenario goals | Scenario IDs (from DEMO-SCENARIOS.md) | Azure services/resources deployed |
|---|---|---|---|
| Stage A - Core observability foundation | Establish the telemetry backbone and governance baseline. | 1, 5, 6, 9 (foundation portions) | Resource group, central LAW + AppInsights LAW, Application Insights (workspace-based), Azure Monitor Workspace, Data Collection Endpoint, VNet/NSG baseline, baseline diagnostic settings and policy wiring, shared storage and Event Hub foundations. |
| Stage B - Workload telemetry and dashboards | Onboard compute and app workloads into the monitoring plane and expose dashboards. | 2, 3, 4, 22, 28, 29, 30, 31, 32, 34, 35, 36, 42 | Linux/Windows VMs + AMA/DCR association, AKS + Container Insights + Managed Prometheus, Managed Grafana, App Service plan/web app + App Insights connection, workbook(s), saved queries, KQL functions, availability test, connection monitor, flow logs, key vault/storage insights surfaces. |
| Stage C - Alerts and response | Add actionable detection and automated response controls. | 7, 8, 12, 15, 17, 19, 23, 37 | Action Group, metric alerts, scheduled query alerts, activity log alerts (service/resource health), AMBA baseline alerts, dynamic thresholds, VMSS predictive autoscale assets, alert processing rules, auto-mitigation Logic App webhook path. |
| Stage D - Security posture (Azure Monitor native) | Build non-SIEM security posture detections directly in Azure Monitor. | 27, 47, 48, 49 | Log Analytics RBAC model (workspace/table/row scope), AzureActivity routing prerequisite, scheduled query alerts for control-plane drift, role assignment changes, and exfil early-warning correlation, alert routing via existing Action Group. |
| Stage E - Optional advanced/security add-ons | Layer advanced SOC and reliability preview capabilities. | 43, 44, 45, 46 | Optional Sentinel onboarding + analytics rule, search job/restore script workflow enablement, health model resources, SLI identity prerequisites and helper scripts, optional service-group/SLI setup flow. |
| Stage AI - Optional GenAI workload | Add a Microsoft Foundry workload emitting token/trace/cost telemetry, with AI FinOps observability. Off by default (billable models, region-limited). | - | Foundry (AI Services) account + project pinned to swedencentral, four model deployments (gpt-5-mini, text-embedding-3-small, gpt-5.4, model-router), App Insights connection, token anomaly + spike metric alerts, AI FinOps query pack + workbook, and an AI tier folded into the workload health model. Agents + traffic via scripts/setup-ai.ps1. |

### Stage dependency chain

1. Stage A is mandatory for all other stages.
2. Stage B depends on Stage A outputs (workspaces/network/monitor workspace).
3. Stage C depends on Stage B resources for alert scopes.
4. Stage D depends on Stage A ingestion and Stage C action routing.
5. Stage E depends on prior stages, especially LAW and monitoring identities.
6. Stage AI depends only on Stage A (it connects to `appi-amlab`); deploy it any time after Stage A.

### Stage acceptance criteria (high level)

1. Stage A done: data lands in LAW and baseline diagnostics/policy are visible.
2. Stage B done: VM/AKS/App Service telemetry and workbook panels render.
3. Stage C done: at least one alert test reaches the Action Group.
4. Stage D done: scenario 47/48/49 queries return data and alert rules evaluate.
5. Stage E done: optional feature endpoints/blades become accessible and testable.
6. Stage AI done: Foundry model deployments exist, App Insights receives AI telemetry, and the AI FinOps queries return data after `setup-ai.ps1` runs.

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

> **Why `-g $rg` on every command below?** `lab.config.json`'s `resourceGroup` field only feeds the **one-shot** `deploy.ps1` path and the **Terraform** `resource_group_name` variable — it is not read by these raw `az deployment group create/what-if` calls. The target resource group for an ARM/Bicep deployment is a CLI/API-level scope (`-g`), not a template parameter, so it must be passed explicitly on every command. Set `$rg` once below to match whatever you put in `lab.config.json` (or your own name), then reuse it throughout.

### Stage A deploy

1. Validate:

```powershell
$sub='<your-subscription-id>'
$rg='rg-azure-monitor-lab'   # match lab.config.json 'resourceGroup', or use your own name
az account set --subscription $sub
az account show --query "{name:name,id:id,tenantId:tenantId}" -o table
az group create -n $rg -l northeurope
az deployment group what-if -g $rg --template-file infra/main.bicep --parameters @infra/main.parameters.json deployLinuxVm=false deployWindowsVm=false aksNodeCount=1 enableSentinel=false
```

2. Deploy:

```powershell
az deployment group create -g $rg --name stage-a-foundation --template-file infra/main.bicep --parameters @infra/main.parameters.json deployLinuxVm=false deployWindowsVm=false aksNodeCount=1 enableSentinel=false
```

Notes:
- The current main.bicep still contains resources beyond foundation. For strict staging, create dedicated stage templates under infra/stages and move resources there over time.
- `aksNodeCount` cannot be `0`: the AKS system node pool requires at least 1 node, so the minimum footprint for this monolithic template is 1 node even when treating this as a "foundation-only" pass.

### Stage B deploy

```powershell
az deployment group create -g $rg --name stage-b-workloads --template-file infra/main.bicep --parameters @infra/main.parameters.json deployLinuxVm=true deployWindowsVm=true aksNodeCount=1 enableSentinel=false
```

### Stage C deploy

```powershell
az deployment group create -g $rg --name stage-c-alerts --template-file infra/main.bicep --parameters @infra/main.parameters.json enableSentinel=false
```

### Stage D deploy

1. Ensure AzureActivity is routed to lab LAW:

```powershell
# The central LAW name gets a per-deployment suffix (law-<prefix>-central-<hash>), so look it
# up from the Stage A deployment output rather than guessing the name.
$lawArmId = az deployment group show -g $rg -n stage-a-foundation --query properties.outputs.centralLawId.value -o tsv
$logs = '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"ServiceHealth","enabled":true},{"category":"Alert","enabled":true},{"category":"Recommendation","enabled":true},{"category":"Policy","enabled":true},{"category":"Autoscale","enabled":true},{"category":"ResourceHealth","enabled":true}]'
az monitor diagnostic-settings subscription create --name amlab-activity-to-law --location global --workspace $lawArmId --logs $logs
```

2. Apply scenario 27/47/48/49 (granular LAW RBAC + control-plane drift / privilege escalation / exfil query alerts). `main.bicep` doesn't include these — deploy the dedicated stage template directly against the same `$rg`, which finds the Stage A LAW and Stage C action group as `existing` resources:

```powershell
az deployment group create -g $rg --name stage-d-security-alerts --template-file infra/stages/30-security-posture.bicep --parameters namePrefix=amlab
```

### Stage E deploy

```powershell
az deployment group create -g $rg --name stage-e-optional --template-file infra/main.bicep --parameters @infra/main.parameters.json enableSentinel=true
```

### Stage AI deploy (optional)

Deploys the Foundry GenAI workload (pinned to swedencentral) directly from the stage template, then creates the demo agents and simulates traffic. Verify the Model Router version for your region first with `az cognitiveservices account list-models`.

```powershell
az deployment group create -g $rg --name stage-ai-foundry --template-file infra/stages/50-ai.bicep --parameters namePrefix=amlab alertEmail=your.alias@example.com
./scripts/setup-ai.ps1 -g $rg   # pip install + create agents + simulate traffic
```

`setup-ai.ps1` pip-installs the packages listed in [`workloads/ai/requirements.txt`](../workloads/ai/requirements.txt) before creating the agents and simulating traffic.

Stage AI depends only on Stage A and can be deployed before or after Stages B to E. If you are using the central config workflow, set `stageToggles.enableStageAI` to `true` in `lab.config.json`, run `./scripts/sync-config.ps1`, and deploy the generated parameters with the same Stage AI template. The stage is off by default because the model deployments are billable.

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
1. az deployment group show -g $rg -n <stage-name>
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
$rg='rg-azure-monitor-lab'   # set this to the RG where you deployed the lab; this is the default
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
# Keep the filter in PowerShell. Windows Azure CLI can strip quoted JMESPath
# expressions before az receives them, producing "] was unexpected at this time."
$deletedLaw = az monitor log-analytics workspace list-deleted-workspaces --subscription $sub -o json | ConvertFrom-Json
$deletedLaw | Where-Object { $_.name -like '*amlab*' } | Format-Table
# Permanent purge if needed:
# az rest --method delete --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.OperationalInsights/locations/northeurope/deletedWorkspaces/<name>?api-version=2023-09-01"
```

2. Soft-deleted Application Insights components (also 14-day grace):

```powershell
$deletedAppInsights = az monitor app-insights component list-deleted --subscription $sub -o json | ConvertFrom-Json
$deletedAppInsights | Where-Object { $_.name -like '*amlab*' } | Format-Table
```

3. Soft-deleted Key Vault (7-day retention, `enablePurgeProtection: null` so it can be purged). Key Vault names are deterministic (`kv-${namePrefix}-${take(suffix,5)}` from `resourceGroup().id`), so redeploying to the **same RG name** before the vault is purged fails with `VaultAlreadyExists`:

```powershell
$deletedVaults = az keyvault list-deleted --subscription $sub -o json | ConvertFrom-Json
$deletedVaults | Where-Object { $_.name -like 'kv-amlab-*' } | Format-Table name, @{n='location';e={$_.properties.location}}
# Purge before redeploying to the same RG name:
# az keyvault purge --name <vaultName> --subscription $sub
```

4. NSG/VNet flow logs in `NetworkWatcherRG` (Stage B creates them outside the lab RG):

```powershell
$flowLogs = az network watcher flow-log list -l northeurope --subscription $sub -o json | ConvertFrom-Json
$flowLogs | Where-Object { $_.name -like '*amlab*' } | Select-Object name, enabled | Format-Table
# az network watcher flow-log delete -l northeurope -n <flowLogName> --subscription $sub
```

5. Custom role definition from Stage D (`AMLAB - Granular Log Reader`). Auto-removed once no scopes reference it; force-delete if it lingers:

```powershell
az role definition list --custom-role-only true --subscription $sub --query "[?starts_with(roleName,'AMLAB - Granular Log Reader')]" -o table
# az role definition delete --name "AMLAB - Granular Log Reader" --subscription $sub
```

6. Sentinel onboarding (if Stage E enabled it) lives on the LAW, so it goes with the RG. No extra action needed.

### Step 4 - Confirm

```powershell
az group exists -n $rg --subscription $sub   # false once the async delete completes
```
