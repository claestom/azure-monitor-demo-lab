# Stage AI — Optional Microsoft Foundry GenAI workload

> **Goal of this stage:** add a real **GenAI workload** to the lab so the observability stack has token/trace/cost telemetry to reason about — the "AI FinOps" story. It layers a Microsoft Foundry account + models, wires them into the lab's Application Insights, and lands token-spike alerting plus an AI FinOps query pack, workbook, and health model. Fully **opt-in** and **off by default** (it deploys billable models).
>
> **Depends only on Stage A** (it connects to `appi-amlab`). Pinned to **swedencentral** regardless of the lab region, because the `gpt-5-*` / `model-router` SKUs, the Foundry portal, and the CloudHealth preview are region-limited — the same reason the workload Health Model is pinned.

## 1) What gets created

| Group | Resource(s) | Purpose |
|---|---|---|
| Foundry workload | `ai<amlab><suffix>` (AI Services account) + `amlab-ai-proj` project, both swedencentral | The GenAI control plane. Project management enabled; system-assigned identity. |
| Model deployments | `gpt-5-mini` (chat), `text-embedding-3-small` (embeddings), `gpt-5.4` (optimization), **`model-router`** — all `GlobalStandard` | The models the agents + traffic simulator exercise. `model-router` picks a cheaper/stronger underlying model per request. |
| Tracing connection | Project → `appi-amlab` Application Insights connection | Lights up the Foundry portal Observability/Tracing tab and lands `gen_ai.*` spans in the lab App Insights. |
| Token alerts | `alert-amlab-token-anomaly` (dynamic threshold) + `alert-amlab-token-spike` (static ceiling) on the account's `TotalTokens` metric, split per deployment | Anomaly detection + a hard guardrail for runaway token spend. Optional `ag-amlab-ai` action group when `alertEmail` is set. |
| AI FinOps observability | `qp-ai-finops` query pack (14 GenAI KQL queries) + a shared **AI FinOps workbook** | Token usage, estimated cost by agent, cached-token ratio, model-router distribution, PTU break-even, latency/error percentiles. |
| AI health tier | An **"AI" tier folded into the workload health model** (`hm-amlab-workload`): an `aiworkload` node → the Foundry account entity (Latency / TotalErrors / TotalTokens metric signals) + 4 agent entities carrying error-rate + estimated-cost Log Analytics signals | One health model for the whole estate — the AI workload rolls up next to frontend/compute/platform; high cost or error rate turns an agent unhealthy. A separate `ai-healthmodel.bicep` exists as an opt-in fallback for standalone A+AI deployments (no Stage E). |
| Agents + traffic | 4 agents (`Support Triage`, `FinOps Q&A`, `Doc Summarizer`, `Context-Rich Assistant`) + a traffic simulator, provisioned by `scripts/setup-ai.ps1` | Generates the live token/trace/cost telemetry the queries, workbook, health model, and alerts consume. Python packages listed in [`workloads/ai/requirements.txt`](../workloads/ai/requirements.txt) are pip-installed first. |

> Cross-stage references: `appi-amlab` and its backing App Insights LAW (Stage A). No dependency on Stages B–E; the AI stage creates its own action group.

## 2) Speaker notes

1. **"This is the observability stack pointed at AI spend."**
   Everything in Stages A–E is infra/platform telemetry. Stage AI adds the *GenAI* pillar: tokens are the new unit of cost, and this stage treats them exactly like any other signal — queried, charted, alerted, and rolled up into a health model.

2. **"swedencentral on purpose."**
   Call out that only the AI resources move to swedencentral (co-located with the workload Health Model); the rest of the lab stays in its region. One resource group, mixed regions — a normal Azure pattern.

3. **"model-router is the cost lever."**
   Open the *Model router routed-model distribution* query. Easy prompts get a cheap model, hard prompts a strong one — surfaced as `gen_ai.response.model`. Even a modest routing rate compounds into real savings.

4. **"Prompt caching is free money."**
   The `Context-Rich Assistant` uses a >1024-token static system prompt, so repeated calls hit the prompt cache. Show the *Cached-input token ratio* query — cached input is billed at a steep discount.

5. **"Token alerts = guardrails before the bill."**
   Two alerts on `TotalTokens`: a dynamic-threshold anomaly detector that learns each deployment's baseline, and a static ceiling as a hard stop. Trigger it live by running the simulator hot (`--conversations 100 --interval 5`).

6. **"One health model, AI included."**
   The AI workload is folded into `hm-amlab-workload` as a fourth **AI** tier (alongside frontend/compute/platform). The 4 agent entities carry both an error-rate signal and an estimated-cost signal — a cost breach alone turns an agent unhealthy. Frame the CloudHealth blade as executive dashboarding (preview; API still moving).

## 3) Portal walkthrough (UI)

1. **Foundry portal (`ai.azure.com`) → project `amlab-ai-proj` → Observability / Tracing** — show agent runs, token consumption by model, and traces from the simulated conversations.
2. **`appi-amlab` → Logs** — run a query from the `qp-ai-finops` pack (Queries hub), e.g. *Estimated cost by agent* or *Model router routed-model distribution*.
3. **Monitor → Workbooks → Shared → "AI FinOps — Foundry Agents"** — time-range picker, token/cost tiles, PTU break-even, cost-share pie.
4. **Monitor → Alerts → Alert rules** — `alert-amlab-token-anomaly` + `alert-amlab-token-spike`.
5. **Monitor → Health models → `hm-amlab-workload`** *(preview)* — open the graph; show the **AI** tier (`aiworkload` → Foundry account + 4 agent entities) rolling up alongside frontend/compute/platform.

## 4) CLI validation

```powershell
$sub = '<your-subscription-id>'
$rg  = 'rg-azure-monitor-lab'   # or your test RG
az account set --subscription $sub

# Foundry account + model deployments (incl. model-router)
$acct = az cognitiveservices account list -g $rg --query "[?kind=='AIServices'].name | [0]" -o tsv
az cognitiveservices account deployment list -g $rg -n $acct --query "[].{name:name,model:properties.model.name,version:properties.model.version,sku:sku.name}" -o table

# Query pack (14 queries) — count via az rest (avoid --query on Windows az.cmd with ? URLs)
$qp = az resource list -g $rg --resource-type Microsoft.OperationalInsights/queryPacks --query "[?starts_with(name,'qp-ai-finops')].name | [0]" -o tsv
$url = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.OperationalInsights/queryPacks/$qp/queries?api-version=2019-09-01"
(az rest --method get --url $url | ConvertFrom-Json).value.Count   # -> 14

# Token alerts
az monitor metrics alert list -g $rg --query "[?contains(name,'token')].{name:name,enabled:enabled}" -o table

# AI health model
az resource list -g $rg --resource-type Microsoft.CloudHealth/healthmodels --query "[?ends_with(name,'-ai')].{name:name,location:location}" -o table

# Telemetry landed? (after running scripts/setup-ai.ps1, allow a few minutes)
az monitor app-insights query --app appi-amlab -g $rg --analytics-query "dependencies | where timestamp > ago(1h) | extend agent=tostring(customDimensions['gen_ai.agent.name']) | where isnotempty(agent) | summarize calls=count() by agent" --query "tables[0].rows" -o json
```

## 5) Done-when

1. The Foundry account has **4** model deployments including `model-router`, all `GlobalStandard`.
2. `qp-ai-finops` contains **14** saved queries and the AI FinOps workbook is visible under Monitor → Workbooks → Shared.
3. `alert-amlab-token-anomaly` and `alert-amlab-token-spike` exist and are enabled.
4. `hm-amlab-workload` renders in the Health Models preview blade with an **AI** tier (`aiworkload` → Foundry + 4 agent entities) alongside the original frontend/compute/platform tiers.
5. After `scripts/setup-ai.ps1`, App Insights `dependencies` shows `gen_ai.agent.name` spans for all agents plus Model Router.

## 6) Enable + run

`setup-ai.ps1` pip-installs the packages in [`workloads/ai/requirements.txt`](../workloads/ai/requirements.txt) (azure-ai-projects, azure-ai-agents, azure-identity, azure-monitor-opentelemetry, opentelemetry-sdk, openai, python-dotenv) before creating the agents and simulating traffic.

**Bicep one-shot** (`lab.config.json`): set `stageToggles.enableStageAI = true` → `deploy.ps1` passes `enableAi=true` to `main.bicep` and runs `setup-ai.ps1` at the end.

**Terraform / staged**: `enable_stage_ai = true` (deploys `infra/stages/50-ai.json`), then run `scripts/setup-ai.ps1`.

**Standalone Bicep stage**:

```powershell
az deployment group create -g $rg -n stage-ai-foundry `
  --template-file infra/stages/50-ai.bicep -p namePrefix=amlab alertEmail=you@contoso.com
./scripts/setup-ai.ps1 -g $rg
```

> **Verify the Model Router version for your region first:** `az cognitiveservices model list -l swedencentral` and pass `-p routerModelVersion=<version>` (or `router_model_version` in Terraform) if the default has rolled forward.

## 7) Tear-down nuance

- Deleting the resource group removes everything. CognitiveServices accounts are **soft-deleted** — if you plan to redeploy the same name, purge it: `az cognitiveservices account purge -l swedencentral -g <rg> -n <account>`.
- The health model's role assignments (Reader / Monitoring Reader / Log Analytics Reader on the RG) are removed with the RG.
- Agents created by `setup-ai.ps1` live in the Foundry project and go with the account; `workloads/ai/agents.json` (their ids) is git-ignored local state.
- To stop token spend without deleting anything, just stop the traffic simulator — models bill per token, near-zero when idle.
