# Azure Monitor Demo Lab

A self-contained, reproducible demo of the **Azure Monitor + Microsoft Sentinel** stack. One resource group, two IaC paths (Bicep or Terraform), two delivery modes (**one-shot** for internal demos or a **5-stage workshop** for progressive enablement), and **52 demo scenarios** — all driven from a single, gitignored config file.

Built for **demos, microhacks, and hackathons**: deploy it into your own subscription, explore Azure Monitor end-to-end, break it, restore it, and tear it down.

## What's inside

A single resource group wired end-to-end across the observability stack:

- **Telemetry backbone** — 2 × Log Analytics, Application Insights, Azure Monitor Workspace (Managed Prometheus), DCRs + ingest-time workspace transformation.
- **Workloads** — Linux/Windows VMs (VM Insights), AKS (Container Insights + Managed Prometheus + Grafana + OpenTelemetry), Linux VMSS (predictive autoscale), .NET 8 App Service (codeless auto-instrumentation).
- **Networking** — Connection Monitor, NSG Flow Logs + Traffic Analytics, Network Insights.
- **Governance** — Diagnostic Settings via DeployIfNotExists policy, cross-workspace KQL, reusable KQL functions.
- **Alerting & response** — Action Group, 7+ metric/KQL/activity/dynamic-threshold alerts, AMBA, alert processing rules, Logic App auto-mitigation.
- **Security** — Microsoft Sentinel onboarding, security-posture alert rules, granular (workspace/table/row) RBAC.
- **Cost & data routing** — daily caps, Basic/Analytics table plans, Summary Rules, Data Export, dedicated cost workbook.
- **Reliability previews** — Service Groups + Health Models, SLIs/SLOs, Search Jobs + archive restore.

> For the exact list of every resource that gets deployed, see **[REFERENCE.md → What gets deployed](REFERENCE.md#what-gets-deployed)**.

## Architecture

Everything below lands in a **single resource group** (`rg-azure-monitor-lab`). Telemetry flows left-to-right: workloads emit signals, agents/policies collect them, the backplane stores them, and the consumption layer turns them into dashboards, alerts, and responses.

[![Azure Monitor Demo Lab architecture — Azure-icon overview](docs/architecture-overview.svg)](docs/architecture.drawio)

<details>
<summary>Text / emoji version (Mermaid)</summary>

```mermaid
flowchart LR
  subgraph WL["🖥️ Workloads"]
    VM["🖥️ Linux &amp; Windows VMs"]
    VMSS["🧱 Linux VMSS<br/>predictive autoscale"]
    AKS["☸️ AKS<br/>Container Insights"]
    APP["🌐 .NET 8 App Service<br/>auto-instrumented"]
    NET["🕸️ VNet / NSG<br/>Connection Monitor"]
  end

  subgraph COL["📥 Collection"]
    AMA["🛰️ Azure Monitor Agent<br/>DCRs · DCE"]
    FLOW["🌊 NSG Flow Logs"]
    POL["📜 Diag Settings via<br/>Policy (DINE)"]
  end

  subgraph DATA["🗄️ Telemetry backplane"]
    LAW["🗃️ Log Analytics<br/>central"]
    LAWAI["🗃️ Log Analytics<br/>App Insights"]
    AI["💡 Application Insights"]
    AMW["🔥 Azure Monitor Workspace<br/>Managed Prometheus"]
    PLAT["📦 Storage · Event Hub · Key Vault"]
  end

  subgraph USE["📊 Consumption &amp; response"]
    GRAF["📈 Managed Grafana"]
    WB["📓 Workbooks<br/>Traffic Lights · Cost · Security"]
    AG["🚨 Action Group<br/>Alerts · AMBA"]
    LOGIC["⚡ Logic App<br/>auto-mitigation"]
    SENT["🛡️ Microsoft Sentinel"]
  end

  VM --> AMA
  VMSS --> AMA
  AKS --> AMA
  AKS --> AMW
  APP --> AI
  NET --> FLOW
  AMA --> LAW
  AMA --> AMW
  FLOW --> PLAT
  POL --> LAW
  AI --> LAWAI
  PLAT --> LAW
  LAW --> WB
  LAWAI --> WB
  AMW --> GRAF
  LAW --> AG
  AI --> AG
  AG --> LOGIC
  LAW --> SENT

  classDef workload fill:#12314D,stroke:#4AA3E0,color:#D6EBFB,stroke-width:1px;
  classDef collect fill:#123322,stroke:#57B96A,color:#D8F3DE,stroke-width:1px;
  classDef data fill:#3A2A0D,stroke:#D9A441,color:#F7E6C4,stroke-width:1px;
  classDef use fill:#2C1C40,stroke:#A877D6,color:#EADDF7,stroke-width:1px;

  class VM,VMSS,AKS,APP,NET workload;
  class AMA,FLOW,POL collect;
  class LAW,LAWAI,AI,AMW,PLAT data;
  class GRAF,WB,AG,LOGIC,SENT use;

  style WL fill:#0E2438,stroke:#4AA3E0,color:#D6EBFB;
  style COL fill:#0E2615,stroke:#57B96A,color:#D8F3DE;
  style DATA fill:#2A1E08,stroke:#D9A441,color:#F7E6C4;
  style USE fill:#1F1430,stroke:#A877D6,color:#EADDF7;
```

</details>

> 🎨 **Full Azure-icon diagram (editable):** [docs/architecture.drawio](docs/architecture.drawio) — open with [diagrams.net](https://app.diagrams.net) or the VS Code *Draw.io Integration* extension. It contains a per-tier overview plus detail pages for each pillar.

## Prerequisites

- Azure CLI (`az`) ≥ 2.60, logged in: `az login`
- `kubectl` (any recent version)
- Bicep CLI (bundled with `az` ≥ 2.20) — **or** Terraform ≥ 1.6 for the Terraform path
- PowerShell 7+
- A subscription with quota for ~5 small VMs/nodes (`Standard_B2s`), 1 App Service B1, Managed Grafana, Storage, Event Hub, Key Vault.

> **Two IaC paths, one config.** Bicep is primary (`infra/`); Terraform (`terraform/`) is a parallel implementation driven from the same `lab.config.json`. Pick one — don't mix.

## Deploy

This repo ships **zero secrets**. Populate one central config file; `sync-config.ps1` generates every derived input from it.

```powershell
# 1. Copy the template and fill in subscriptionId, tenantId, alertEmail, vmAdminPassword, ...
Copy-Item lab.config.json.example lab.config.json
notepad lab.config.json

# 2. Deploy (deploy.ps1 calls sync-config.ps1 for you)
./scripts/deploy.ps1

# Or target a custom resource group / region (created if it doesn't exist yet):
./scripts/deploy.ps1 -ResourceGroup rg-my-lab -Location westeurope
```

Defaults: resource group `rg-azure-monitor-lab`, region `swedencentral`. Override with `-ResourceGroup` / `-Location` (explicit args win over `lab.config.json`, which wins over these defaults). The group is created if it doesn't already exist, or reused if it does. End-to-end ~20–25 minutes. See [REFERENCE.md → Deploy](REFERENCE.md#deploy) for the config details and the subscription guardrail.

**Two delivery modes:**

- **One-shot** — `./scripts/deploy.ps1` deploys everything at once (fastest, internal demos).
- **Staged workshop** — 5 progressive stages (A–E) you can pause between, toggled in `lab.config.json`. Step-by-step guides: [Bicep](docs/DEPLOY-BICEP-STEP-BY-STEP.md) · [Terraform](docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md).

When you're done (cost guardrails of 1 GB/day are baked in either way):

```powershell
./scripts/teardown.ps1 -Yes   # deletes the whole resource group
```

## Documentation

| Doc | What's in it |
|---|---|
| [REFERENCE.md](REFERENCE.md) | Full capability matrix · every deployed resource · demo walkthrough · cost breakdown · folder layout · optional add-ons · troubleshooting |
| [DEMO-SCENARIOS.md](DEMO-SCENARIOS.md) | All 52 demo scenarios — story, click-path, and "killer line", plus audience-pivoted shortlists |
| [docs/DEPLOY-BICEP-STEP-BY-STEP.md](docs/DEPLOY-BICEP-STEP-BY-STEP.md) · [docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md](docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md) | Staged deployment tutorials |
| Stage notes: [A](docs/STAGE-A-FOUNDATION.md) · [B](docs/STAGE-B-WORKLOADS.md) · [C](docs/STAGE-C-ALERTING.md) · [D](docs/STAGE-D-SECURITY-POSTURE.md) · [E](docs/STAGE-E-OPTIONAL-ADVANCED.md) | Per-stage speaker notes |
| [docs/CUSTOMER-STAGE-HANDOUT.md](docs/CUSTOMER-STAGE-HANDOUT.md) | Per-stage time + cost cheat sheet |

## Contributing & license

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). To report a security issue, see [SECURITY.md](SECURITY.md).

Licensed under the **[MIT License](LICENSE)** — free to use, modify, and redistribute (including for microhacks, hackathons, and your own demos), provided as-is without warranty.
