# Azure Monitor Demo Lab

A self-contained demo of the Azure Monitor and Microsoft Sentinel stack. Everything runs from a single config file that stays out of git, so you can stand the whole thing up in your own subscription and tear it back down when you're finished.

- One resource group: the whole lab lands in `rg-azure-monitor-lab`.
- Two ways to deploy it: Bicep or Terraform.
- Two ways to run it: one-shot for a quick internal demo, or a 5-stage workshop if you'd rather walk through it piece by piece.
- 58 demo scenarios that cover Azure Monitor, Sentinel, and Azure SRE Agent from end to end.

It's built for demos, microhacks, and hackathons. Deploy it, poke around, break it, restore it, and tear it down.

## Architecture

Everything lands in a single resource group (`rg-azure-monitor-lab`), with telemetry flowing from left to right:

1. Workloads emit signals.
2. Agents and policies collect them.
3. The telemetry backplane stores them.
4. The consumption layer turns them into dashboards, alerts, and responses.

There's also an optional GenAI workload (off by default) that plugs into the same backbone:

- What it adds: a Microsoft Foundry account and project with chat, embedding, optimization, and model-router deployments, plus a few agents and a traffic simulator.
- How it's observed: token, trace, and cost telemetry flows into Application Insights, which drives token anomaly and spike alerts and an AI FinOps query pack and workbook, and adds an AI tier to the workload health model.

> 📦 For a full, resource-by-resource list of what gets created, see [REFERENCE.md → What gets deployed](docs/REFERENCE.md#what-gets-deployed).

[![Azure Monitor Demo Lab architecture - Azure-icon overview](docs/architecture-overview.svg?v=2)](docs/architecture.drawio)

> 🎨 Full Azure-icon diagram (editable): [docs/architecture.drawio](docs/architecture.drawio). Open it with [diagrams.net](https://app.diagrams.net) or the VS Code *Draw.io Integration* extension. It has a per-tier overview plus a detail page for each pillar, including a dedicated AI / GenAI page.

## Prerequisites

- Azure CLI (`az`) 2.60 or later, logged in with `az login`
- `kubectl` (any recent version)
- Bicep CLI (bundled with `az` 2.20+), or Terraform 1.6+ if you take the Terraform path
- PowerShell 7+
- A subscription with quota for ~5 small VMs/nodes (`Standard_B2s`), 1 App Service B1, Managed Grafana, Storage, Event Hub, and Key Vault
- For the optional AI stage only: Python 3.10+. `scripts/setup-ai.ps1` provisions the demo agents and traffic simulator from [`workloads/ai/`](workloads/ai/), and the models it deploys are billable.

> Two IaC paths, one config. Bicep is the primary one (`infra/`); Terraform (`terraform/`) is a parallel implementation driven from the same `lab.config.json`. Pick one and don't mix them.

## Deploy

> Recommended region: `northeurope` (the default), which has the widest feature availability. A few things pin themselves to a fixed region no matter what you pick: the Health Model preview and the optional GenAI / AI stage (Microsoft Foundry and its models) go to `swedencentral` (they aren't available in `northeurope`), and the App Service goes to `westeurope` (the sponsored lab subscriptions have no Basic App Service quota in `northeurope`). Everything else follows the region you choose.

### Option 1: Deploy to Azure (portal, no local setup)

<div align="center">

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fclaestom%2Fazure-monitor-demo-lab%2Fmaster%2Finfra%2Fmain.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fclaestom%2Fazure-monitor-demo-lab%2Fmaster%2Finfra%2FcreateUiDefinition.json)

</div>

Opens a guided Custom deployment wizard in the Azure Portal, where you enter every value in the UI and don't need any local files. Sensible defaults are pre-filled throughout; the only things you have to supply are an alert email and a VM admin password.

| Tab | You provide |
|---|---|
| **Basics** | Resource group (recommended `rg-azure-monitor-lab`), Region (recommended `northeurope`), name prefix, alert email, VM admin username + password |
| **Workloads** | Deploy Linux/Windows VMs, VM size, AKS node size + count |
| **Monitoring & cost** | Daily ingestion cap, Sentinel, platform-logs/metrics-export DCRs, LAW replication |
| **Advanced** | Owner tag, App Service sample repo, optional SIEM/Teams webhook, optional AI stage |

After the portal deployment succeeds, open **Cloud Shell** in the Azure portal, select **PowerShell**, and run the commands below. The Cloud Shell wrapper discovers the deployed resources, publishes the App Service sample, and installs the AKS, Health Model, and SLI demo components without requiring optional Azure CLI extensions:

```powershell
git clone https://github.com/claestom/azure-monitor-demo-lab.git
cd azure-monitor-demo-lab
az account set --subscription <subscription-id>
./scripts/post-cloud-shell-deploy.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>
```

If the repository is already present in Cloud Shell, update it before rerunning the wrapper:

```powershell
cd ~/azure-monitor-demo-lab
git pull
./scripts/post-cloud-shell-deploy.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>
```

The optional AI stage deploys Microsoft Foundry and four billable model deployments in `swedencentral`, together with AI monitoring, token alerts, and an AI FinOps workbook. If you enabled it in the portal, use the dedicated Cloud Shell AI wrapper to create the demo agents and generate simulated traffic without optional Azure CLI extensions:

```powershell
./scripts/setup-ai-cloud-shell.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>
```

> Use Option 2 for a scripted one-shot deployment, or Option 3 for the staged workshop and progressive deployment.

### Option 2: Scripted one-shot (Bicep / Terraform, full control)

This repo ships no secrets. You fill in one central config file, and `sync-config.ps1` generates every derived input from it.

```powershell
# 1. Clone the repo and enter it
git clone https://github.com/claestom/azure-monitor-demo-lab.git
cd azure-monitor-demo-lab

# 2. Copy the template and fill in subscriptionId, tenantId, alertEmail, vmAdminPassword, ...
Copy-Item lab.config.json.example lab.config.json
notepad lab.config.json
#    → edit the values, then save the file (Ctrl+S) and close Notepad before continuing
#    → stageToggles.enableStageA-E are only used by the staged/Terraform paths; the
#      one-shot deploy always deploys everything and can leave them untouched.
#      enableStageAI deploys the optional Foundry resources, while
#      enableStageSreAgent runs the post-deployment SRE Agent readiness handoff.

# 3. Deploy (deploy.ps1 calls sync-config.ps1 for you)
./scripts/deploy.ps1

# Or target a custom resource group / region (created if it doesn't exist yet):
./scripts/deploy.ps1 -ResourceGroup rg-my-lab -Location westeurope
```

Defaults: resource group `rg-azure-monitor-lab`, region `northeurope`. Override them with `-ResourceGroup` / `-Location` (explicit args win over `lab.config.json`, which in turn wins over these defaults). The group is created if it doesn't exist yet, or reused if it does. The whole run takes about 5 minutes. See [REFERENCE.md → Deploy](docs/REFERENCE.md#deploy) for the config details and the subscription guardrail.

<details>
<summary><b>Pre-flight check</b> (region SKU / quota validation before deploy)</summary>

Before creating anything, `deploy.ps1` runs [`scripts/preflight-check.ps1`](scripts/preflight-check.ps1), which checks in about 15 seconds that every VM SKU, vCPU quota, and PaaS resource type the lab needs is actually available in the region you picked for your subscription. It fails fast with a PASS/WARN/FAIL table instead of blowing up 20 minutes into the deployment. You can run it on its own to vet a region before committing (`./scripts/preflight-check.ps1 -Location westeurope`), or skip it with `./scripts/deploy.ps1 -SkipPreflight`.

The pre-flight checks *availability and quota*, not *live service capacity*. Transient, region-wide shortages like AKS `AksCapacityHeavyUsage` have no pre-check API and only surface at deploy time. If one hits, `deploy.ps1` catches it and points you to the fix: deploy to another region (`-Location northeurope`) or retry (`-MaxDeployRetries 3`), since capacity frees up as other clusters are deleted.

</details>

> Optional AI stage. An extra stage (off by default) adds a Microsoft Foundry GenAI workload (pinned to `swedencentral`) that emits token, trace, and cost telemetry, plus token-spike alerts and an AI FinOps query pack and workbook. Turn it on with `stageToggles.enableStageAI` (Bicep one-shot) or Terraform's `enable_stage_ai`, then run `./scripts/setup-ai.ps1` to create the demo agents and simulate traffic. Check the Model Router version for your region first (`az cognitiveservices account list-models`).

> Optional SRE Agent evaluation. Set `stageToggles.enableStageSreAgent` to `true` to run the post-deployment readiness handoff. New eligible customers can use a 30-day waiver of the fixed always-on charge while active Azure Agent Unit usage remains billable. The lab hard pins the SRE Agent to `swedencentral`. Follow [Stage SRE Agent](docs/STAGE-SRE-AGENT.md) to create one trial agent, connect Azure Monitor, validate least-privilege access, and run scenarios 54 through 58.

### Option 3: Staged workshop (progressive deployment)

Use the staged approach when you want to pause between capabilities, walk through the lab with an audience, or deploy only the stages needed for a particular demo. Stages A to E can be toggled in `lab.config.json`, and the optional AI stage can be enabled separately after Stage A.

Step-by-step guides:

- [Bicep staged deployment](docs/DEPLOY-BICEP-STEP-BY-STEP.md)
- [Terraform staged deployment](docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md)

## Cost and lifecycle

The full lab is roughly **€6-11 per day** when left running 24/7, based on the indicative list-price estimate in [REFERENCE.md](docs/REFERENCE.md#cost-notes-north-europe-list-pricing-may-2026). The optional AI stage adds model usage when `setup-ai.ps1` generates traffic. Do not leave the environment deployed when it is not needed: stop or deallocate compute between sessions, or run `./scripts/teardown.ps1 -Yes` and redeploy the stages for the next demo. Actual costs vary by region, usage, retention, and Azure pricing.

When the lab is no longer needed, set `$rg` to the resource group where you deployed the lab, then run the command below. If you used the default configuration, use `rg-azure-monitor-lab`.

```powershell
$rg = "rg-azure-monitor-lab"   # change this to the RG used for your deployment
./scripts/teardown.ps1 -ResourceGroup $rg -Yes   # deletes the whole resource group
```

## Documentation

| Doc | What's in it |
|---|---|
| [REFERENCE.md](docs/REFERENCE.md) | Full capability matrix · every deployed resource · demo walkthrough · cost breakdown · folder layout · optional add-ons · troubleshooting |
| [DEMO-SCENARIOS.md](docs/DEMO-SCENARIOS.md) | All 58 demo scenarios, each with a story, a click-path, and a "killer line", plus audience-pivoted shortlists |
| [docs/DEPLOY-BICEP-STEP-BY-STEP.md](docs/DEPLOY-BICEP-STEP-BY-STEP.md) · [docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md](docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md) | Staged deployment tutorials |
| Stage notes: [A](docs/STAGE-A-FOUNDATION.md) · [B](docs/STAGE-B-WORKLOADS.md) · [C](docs/STAGE-C-ALERTING.md) · [D](docs/STAGE-D-SECURITY-POSTURE.md) · [E](docs/STAGE-E-OPTIONAL-ADVANCED.md) · [AI](docs/STAGE-AI.md) · [SRE Agent](docs/STAGE-SRE-AGENT.md) | Per-stage speaker notes, including optional AI FinOps and SRE Agent evaluation stages |
| [docs/CUSTOMER-STAGE-HANDOUT.md](docs/CUSTOMER-STAGE-HANDOUT.md) | Per-stage time + cost cheat sheet |

## Contributing & license

Contributions are welcome. See [CONTRIBUTING.md](.github/CONTRIBUTING.md) and the [Code of Conduct](.github/CODE_OF_CONDUCT.md). To report a security issue, see [SECURITY.md](.github/SECURITY.md).

Licensed under the [MIT License](LICENSE): free to use, modify, and redistribute (including for microhacks, hackathons, and your own demos), and provided as-is without warranty.
