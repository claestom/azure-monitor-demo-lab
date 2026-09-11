# Azure Monitor Lab Control Center

The ASP.NET Core 8 app serves **Azure Monitor Lab Control Center** at `/`. Four keyboard-accessible tabs separate Infra Health (first/default), Traffic & Faults, SRE MCP Assistant, and Foundry Playground. It runs in the existing App Service and uses the existing Application Insights integration. Basic traffic actions need no additional resources. Health reads, MCP assistant, and Foundry execution require explicit enablement, authenticated access, and a backend identity with the appropriate permissions.

Start with the [Control Center guide](../../docs/LAB-CONTROL-CENTER.md) for the application overview, screenshot, and scenario mapping. This page is the technical reference for configuration, local development, deployment, and runtime limits. The shared environment strip reuses existing context/catalog calls; it does not perform background model requests. Guide and Related Scenarios links open repository documentation without executing actions.

## Infrastructure Health

`GET /api/infra/health` performs read-only checks against one configured lab resource group. It uses `Azure.Identity` with system-assigned managed identity when hosted and `AzureCliCredential` locally, plus `Azure.Monitor.Query.Logs` for fixed workspace queries. The backend never accepts a resource scope, endpoint, time range, or KQL query from the browser.

The tab includes only `Microsoft.Compute/virtualMachines`, `Microsoft.Compute/virtualMachineScaleSets`, `Microsoft.ContainerService/managedClusters`, and `Microsoft.Web/sites`. This case-insensitive filter is applied before selecting telemetry queries and computing the response, so supporting resources do not appear in rows or status totals. The tab combines Azure Resource Health availability with the existing [workbook](../../infra/modules/workbook.bicep) thresholds for VM heartbeats, AKS node/pod reporting, and App Service HTTP 5xx. Signals join by resource ID, not resource name. Read failures, absent telemetry, and partial query results remain explicit. Provisioning success is not an availability signal. The [Control Center guide](../../docs/LAB-CONTROL-CENTER.md#infrastructure-health) explains thresholds and limitations.

### Hosted Access

1. Publish this version of the app. The standard package helper discovers the central workspace and the App Insights component's associated workspace in the same resource group. Health reads default to disabled.
2. Configure single-tenant App Service Authentication and `LabConsole__AllowedPrincipalIds__0` for an approved operator. Existing agent-tab authentication can be reused; the health helper does not create or modify an Entra registration. Without AI/SRE, configure the same operator-only authentication directly in App Service, preserving anonymous access to the demo endpoints.
3. Review the opt-in helper using the actual workspace names, including any deployment suffix:

```powershell
../../scripts/setup-webapp-health-access.ps1 `
  -SubscriptionId '<lab-subscription-id>' -TenantId '<lab-tenant-id>' `
  -ResourceGroup '<lab-resource-group>' -WebAppName '<lab-web-app>' `
  -CentralLawName '<central-workspace-name>' -AppInsightsLawName '<application-workspace-name>' `
  -WhatIf
```

Remove `-WhatIf` only after reviewing the scope. The helper requires an existing system-assigned app identity, matching tenant, configured authentication, and a backend operator allowlist. It grants **Reader** on this resource group and **Log Analytics Reader** on the two named workspaces, preserves unrelated settings and all agent settings, and enables health only after role setup succeeds. A role failure leaves health disabled. Repeated runs reuse existing exact assignments. The caller needs role-assignment write permission and permission to update this App Service's settings. Allow RBAC propagation before refreshing.

The roles are not subscription-wide, but the shared backend identity can read resource metadata across this lab and logs in the assigned workspaces. The API restricts queries to this resource group and returns only aggregates. This is not delegated browser-user access. No workload start/stop, AI execution, secret access, or authentication change is performed by the helper. Disabling `LabConsole__Health__Enabled` stops future queries but does not revoke roles already granted.

### Configuration And Limits

| Setting | Value |
|---|---|
| `LabConsole__Health__Enabled` | `true` to opt in; defaults to `false` |
| `LabConsole__Health__SubscriptionId` | Expected lab subscription GUID |
| `LabConsole__Health__TenantId` | Intended Azure CLI tenant for local runs; stored by hosted setup too |
| `LabConsole__Health__CentralWorkspaceResourceId` | Full ARM ID of the central workspace in this lab resource group |
| `LabConsole__Health__AppInsightsWorkspaceResourceId` | Retained for setup compatibility; the infra-only view does not query this workspace |
| `LabConsole__ResourceGroup` | Resource group used by the existing console context |

For local access, use the existing config helper with `-EnableInfrastructureHealth -TenantId '<lab-tenant-id>'`, or set the health environment variables before starting the app. Local requests require loopback IP and Host; hosted requests use the existing authenticated operator allowlist. Use the intended signed-in Azure CLI account with read access. Do not overwrite an existing local agent configuration without preserving its settings.

The UI checks once on first opening and offers manual refresh. A per-instance semaphore coalesces concurrent checks; snapshots are cached for 60 seconds and top-level failures for 15 seconds. The endpoint allows 30 requests per minute per app instance. One check is bounded by 45 seconds, at most 10 pages / 500 resources per ARM list, and at most three concurrent fixed telemetry queries against the central workspace. Each Logs query has a 15-second server timeout, a one-hour upper time range, a 500-row cap, and at most one SDK retry. Pagination cannot change the ARM host or scoped path; redirects are disabled. No background queries or model calls are scheduled. Usual Azure Monitor data/query charges and workspace policies still apply.

Snapshot age and failed refreshes remain visible. Platform reports older than 30 minutes are unknown. Missing tables are not created; missing or partial queries are discarded for that signal. VM scale sets use platform availability only; other supporting resource types and out-of-group resources such as AKS-managed infrastructure are excluded. This is not the preview Azure Monitor Health Model or an autonomous remediation engine.

The shared **Web app health** header independently probes `/healthz` on initial page load and each accepted Infra Health refresh. The probe bypasses the browser cache, rejects redirects, and times out after 10 seconds. It never contributes to traffic counters, latency charts, or request history, but the server can still record the HTTP request in telemetry. Manual health actions continue to update both the header and traffic results. Clearing traffic preserves the last header result; request sequencing prevents an older response from overwriting a newer check. These probes do not poll in the background or depend on Azure operator access.

References: [Azure Monitor Logs SDK](https://learn.microsoft.com/en-us/dotnet/api/overview/azure/monitor.query.logs-readme?view=azure-dotnet), [Resource Health list by resource group](https://learn.microsoft.com/en-us/rest/api/resourcehealth/availability-statuses/list-by-resource-group?view=rest-resourcehealth-2025-05-01).

## Agent Views

**SRE MCP Assistant** uses an existing Foundry model to select direct Azure MCP management tools and explain their results. Ask about agents, connectors, incidents, scheduled tasks, memories, prompts, and workflows. Read calls run within a bounded question budget. Writes produce an exact tool-and-arguments preview and require a separate one-time approval in the app. Results appear in an operation log. No SRE thread is created, no investigation starts, and no browser evidence is attached. The model is the MCP host, not an SRE investigation agent. See [SRE-MCP.md](SRE-MCP.md) for supported operations, setup, model permissions, limits, and recovery.

**Foundry Playground** invokes existing classic persistent service agents created by [create_agents.py](../ai/create_agents.py): Support Triage, FinOps Q&A, Doc Summarizer, and Context-Rich Assistant. It does not create agents, replace their instructions, or route requests to an unrelated chat-completions endpoint. Each approved task starts a fresh thread. Up to ten results are held in browser memory, with answer text, the model reported by the run, token usage, latency, run ID, and trace ID. Switching tabs preserves local state. Clear removes browser results only.

The backend uses `Azure.AI.Agents.Persistent` and `Azure.Identity`. Catalog discovery does not generate model traffic. Discovery is cached for 60 seconds when available and 15 seconds on failure, scans at most 100 agents newest-first, and includes only known lab names with no tools. Optional `LabConsole:Foundry:AgentIds:<key>` settings pin exact IDs; otherwise the newest matching agent is selected. Missing configuration, identity permissions, or supported agents produce explicit unavailable states.

### Enable Foundry Access

1. Ensure the AI stage and its existing agents are deployed. The resource-discovery helper finds the single Foundry project endpoint and SRE destination in the selected resource group. Multiple projects or SRE agents require explicit configuration rather than an arbitrary choice.
2. Enable the App Service system-assigned managed identity. Assign **Foundry User** at the Foundry project scope for agent usage. Confirm the assigned role includes the required list/get agent and thread/message/run operations, including cancellation and thread deletion; project policies may require a tailored role. Do not grant subscription-wide Contributor to the app.
3. Configure **App Service Authentication** with Microsoft Entra ID and restrict access to approved lab users. Set `LabConsole__AllowedPrincipalIds__0` to an approved operator's Entra object ID, with numbered entries for additional operators. The hosted agent endpoints require platform authentication and membership in this allowlist. Both tabs offer Sign In when access is unauthenticated. The [hosted access helper](../../scripts/setup-webapp-agent-access.ps1) can configure both tabs with explicit consent; see [SRE-MCP.md](SRE-MCP.md). Do not trust client-supplied `X-MS-*` headers outside App Service. The helper preserves anonymous demo endpoints for external load generators.
4. Set `LabConsole__Foundry__Enabled=true` in App Service settings. The project endpoint comes from generated configuration, or override it with `LabConsole__Foundry__ProjectEndpoint`. Regenerate/publish configuration after adding the AI or SRE stages, or configure the new destinations explicitly. The publish helper always defaults agent execution to disabled; environment settings override the generated file.

No role assignment, authentication setting, or Azure deployment is performed by the UI or configuration helper. HTTPS-only public Azure Foundry project endpoints are accepted. The browser never receives credentials. Hosted calls use system-assigned managed identity; local calls use `AzureCliCredential` and require a loopback connection and a localhost/loopback Host header. User-assigned identities, private-cloud endpoint suffixes, and generic self-hosted authentication proxies are not supported by this demo integration.

For local execution, log into the intended lab tenant with Azure CLI, then set `$env:LabConsole__Foundry__Enabled = 'true'` before starting the app. Alternatively, generate local configuration with the helper's `-EnableFoundryPlayground` switch. Each submitted task still requires explicit billable-usage consent. Tests force execution off and use fake service responses, so they do not spend model tokens.

### Agent Limits And Telemetry

- One concurrent task and six submissions per fixed minute per app instance, not a distributed quota. Invalid submissions count toward the rate limit. Inputs are limited to 4,000 characters and 20,000 request bytes.
- Runs use at most 8,192 prompt tokens and 2,048 completion tokens, with a 90-second deadline. Reasoning tokens may consume the completion budget; incomplete runs are reported as failures rather than silently retried. SDK retries are disabled to avoid duplicate billable run creation.
- The backend rechecks the selected agent and overrides run tools with an empty list. It does not execute function calls or submit tool outputs. Agents with tools are excluded from the catalog and rejected if changed before invocation.
- On completion, failure, timeout, or browser cancellation, the backend attempts to cancel a known active run and delete its own temporary thread within a bounded cleanup window. Cancellation and deletion are best-effort. If a network failure prevents receipt of a created run/thread ID, full cleanup cannot be guaranteed; consult project retention and server cleanup warnings. Previously incurred usage remains billable. Persistent agents themselves are never deleted.
- Usage is taken from the service, never estimated from text. Missing usage is shown as not reported. Cached-token counts are not fabricated because this persistent-agent API does not reliably report them.
- Cost is unavailable by default. Optional `LabConsole:Foundry:Pricing:<reported-model>:InputUsdPerMillion` and `OutputUsdPerMillion` decimal settings enable an estimated USD cost. These are operator-supplied rates, not a live pricing feed, and ignore cached-input discounts. Reconcile estimates against Cost Management.
- The existing Application Insights SDK records HTTP requests/dependencies. Known agent runs also emit a `GenAI` dependency named `invoke_agent`, with `gen_ai.agent.name`, `gen_ai.response.model`, `run.id`, and available token counts in custom dimensions. Successful tasks emit `AgentPlaygroundCompleted` with numerical usage metrics. No prompt or response body is included in these custom records. Sampling and ingestion delay still apply; existing workbook filters may need to include `source=web-console`.

## Interactions

| Control | Endpoint | Result |
|---|---|---|
| Check Health | `GET /healthz` | Web app health and browser round-trip latency, not whole-lab health |
| Slow Request | `GET /api/slow` | A deliberately delayed response, approximately 1.5-3 seconds |
| Trigger Error | `GET /api/explode` | Intentional HTTP 500 and exception telemetry |
| Test Dependency | `GET /api/dep` | An outbound HTTPS dependency |
| Simulate Checkout | `GET /api/checkout` | Cart metrics and `CheckoutCompleted` event; channel and payment outcome controls |
| Run Inefficient Code | `POST /api/console/performance` | Confirmation-gated CPU/exception/dependency experiment with a cooldown |

Requests update session counts, failure percentage, average latency, the latest 30 latency measurements, and an expandable activity table. The table retains the latest 100 requests; statistics cover the whole session until cleared. Response details include a copyable `X-Amlab-Trace-Id`, matching the server's W3C trace ID and Application Insights operation ID. No response HTML is executed.

Checkout supports `outcome=random`, `outcome=success`, and `outcome=declined`. Omitting the parameter retains the original random behavior, including approximately 5% declined payments. `X-Amlab-Channel` accepts up to 32 ASCII letters, digits, or hyphens. Cart values are illustrative numbers, not billed purchases.

## Traffic And Safety

- Normal traffic cycles through health, successful checkout, and dependency requests. Latency spike mixes health and slow requests. Error burst mixes health and intentional failures.
- Console traffic runs are sequential, capped at 30 requests, and start requests no more often than once per second. Settings offer 1, 2, or 5-second minimum intervals. Slow responses naturally lower throughput.
- Stop prevents future requests. An in-flight server request can still finish. Closing the page also stops the browser-generated run; there is no background server job.
- The browser times out requests after 15 seconds. Server-side outbound HTTP calls time out after 10 seconds.
- The performance control requires confirmation and a 30-second browser cooldown. Its POST endpoint also permits one request per fixed 30-second window per app instance and returns HTTP 429 with `Retry-After` when limited. This is not a distributed quota across scaled-out instances.
- Existing script endpoints, including `GET /api/inefficient`, remain available for compatibility. They are not protected by the new console performance limiter. This is an intentional-failure demo, not a hardened public production application. Use App Service access restrictions or authentication when broader access is inappropriate.
- Session results are kept in browser memory only. Clear resets the UI, not Azure telemetry. Counts cover this browser's actions, not other users or the existing load generator.
- Azure ingestion, sampling, alert evaluation windows, and thresholds still apply. A successful button action does not guarantee an alert. Code Optimizations recommendations require profiling and sufficient traffic and may take hours.

## Run Locally

From this directory, with the .NET 8 SDK or later:

```powershell
dotnet run --no-launch-profile --urls http://localhost:5189
```

Open `http://localhost:5189`. Built frontend assets are kept in `wwwroot`, so Node is not required to run or publish the app. Leave the Application Insights connection string unset for local testing that should not send telemetry to Azure.

After changing frontend source, use Node.js 20 or later:

```powershell
npm ci
npm run build
npx playwright install chromium
npm test
./tests/console-config.Tests.ps1
./tests/webapp-package.Tests.ps1
./tests/webapp-access.Tests.ps1
./tests/webapp-health-access.Tests.ps1
dotnet test ../webapp.Tests/AmlabHello.Tests.csproj -c Release
```

Playwright starts and stops its own app at `http://127.0.0.1:5188`; keep that port free. Tests force health reads and both agent integrations off and mock successful responses, so no paid traffic or Azure changes occur. Coverage includes health snapshots, filters, freshness, partial failures, API guards, W3C correlation, checkout outcomes, traffic completion/stopping, cooldowns, tab navigation, MCP questions and write review, consent/cancellation/error states, safe rendering, and desktop/mobile screenshots with canvas-pixel checks. Configuration and access-helper tests mock all Azure operations. Unit tests cover health thresholds, SDK response handling, scoped pagination, caching, direct-MCP scope validation, ownership, one-time approvals, rejected investigations, bounded tool selection, and the actual model SDK wire format, plus existing Foundry usage/cleanup behavior.

Commit regenerated `wwwroot` bundles/assets with frontend source changes. `dotnet publish` includes those assets and excludes frontend sources, Node dependencies, tests, and local `lab-console.json`. The deployment helper generates fresh disabled-by-default configuration after publishing. App Service ZIP deployment continues to use `dotnet AmlabHello.dll`.

## Monitoring Destinations

To update only an existing Web App, without reapplying AKS workloads, use [deploy-webapp.ps1](../../scripts/deploy-webapp.ps1). It publishes the current checkout and uses the same package helper as normal lab deployment:

```powershell
../../scripts/deploy-webapp.ps1 `
  -SubscriptionId '<lab-subscription-id>' -TenantId '<lab-tenant-id>' `
  -ResourceGroup '<lab-resource-group>' -WebAppName '<lab-web-app>' -WhatIf
```

Remove `-WhatIf` to deploy after reviewing the target. This does not enable agent execution or grant permissions; existing environment settings are retained. To open the deployed console in the portal, select the App Service and choose **Browse**.

The existing [post-deploy script](../../scripts/post-deploy.ps1), shared by scripted, staged, and Cloud Shell deployments, calls [prepare-webapp-package.ps1](../../scripts/prepare-webapp-package.ps1) before creating the ZIP. It verifies the published console assets, generates fresh configuration through [write-webapp-console-config.ps1](../../scripts/write-webapp-console-config.ps1), and packages the pinned Linux MCP runtime automatically when an SRE Agent is discovered. Discovery uses explicit subscription and resource-group parameters and only reads Azure resources. Packaging fails visibly if a required asset or MCP runtime cannot be prepared.

The four destinations are Application Insights, the central workspace's Logs view, the lab Health Dashboard/Traffic Lights workbook, and the Grafana endpoint. Missing resources remain unavailable in the UI; no destination is guessed. Opening them uses the signed-in user's Azure permissions, not the app identity. Separately, the opt-in Infrastructure Health tab fetches its read-only snapshot with the backend identity.

For a local preview with links to an existing lab, run from this directory:

```powershell
../../scripts/write-webapp-console-config.ps1 `
  -SubscriptionId '<lab-subscription-id>' `
  -ResourceGroup '<lab-resource-group>' `
  -OutputPath ./lab-console.json
```

The generated local file is git-ignored. It contains nonsecret resource context, public HTTPS URLs, and the disabled-by-default Foundry setting, never credentials or connection strings. Environment settings such as `LabConsole__Links__ApplicationInsights`, `LabConsole__Links__Logs`, `LabConsole__Links__Workbook`, and `LabConsole__Links__Grafana` override it. Agent destinations use `LabConsole__Links__SreAgent` and `LabConsole__Links__Foundry`. `/api/console/config` exposes only monitoring links and cooldown; `/api/agents/context` exposes resource group, app name, and validated agent portal links. Neither endpoint exposes arbitrary application configuration.

## Frontend Assets

The UI bundles [Lucide](https://lucide.dev/license) icons (ISC), [Chart.js](https://github.com/chartjs/Chart.js/blob/master/LICENSE.md) (MIT), and [Manrope](https://github.com/fontsource/fontsource/tree/main/fonts/variable/manrope) (SIL Open Font License). Dependency versions are recorded in `package-lock.json`; the build preserves license notices in `wwwroot/third-party-notices.txt`. The Azure Monitor mark reuses the repository's existing Azure architecture asset. No CDN requests are required for fonts, charts, or icons.