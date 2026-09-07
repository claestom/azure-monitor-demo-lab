# Stage SRE Agent - Azure Monitor incident investigation

> **Goal:** connect an Azure SRE Agent to the lab's Azure Monitor alerts and observability data, then demonstrate alert-driven investigation across Application Insights, Log Analytics, metrics, Resource Graph, and Activity Logs.
>
> **Deployment model:** the one-shot Bicep path deploys `Microsoft.App/agents`, a dedicated managed identity, least-privilege RBAC, and Azure Monitor connectors. `scripts/setup-sre-agent.ps1` validates the deployed agent and prints its portal URL.
>
> **Region:** the SRE Agent is hard pinned to **Sweden Central** (`swedencentral`). Do not select another region for this lab.

## Trial cost facts

The 30-day evaluation waives the fixed always-on charge, not all SRE Agent charges.

| Item | Trial behavior |
|---|---|
| Eligibility | Azure customers without an SRE Agent as of August 25, 2026 |
| Allowance | Up to 3 agents per customer, including deleted agents |
| Duration | 30 days from each agent's creation |
| Always-on flow | Waived during the 30-day window |
| Active flow | Billed whenever chat, incidents, tasks, or other processing runs |
| Day 31 | Always-on billing starts automatically unless the agent is deleted |
| Feature limits | No trial-specific feature limitations |

Use one agent for this lab. In **Settings > Agent consumption**, set the smallest active-flow allocation appropriate for the demo and monitor consumption by thread. Stopping an agent stops active flow but does not stop always-on billing after the trial. Delete the agent before day 31 to stop all SRE Agent billing.

References:

- [Evaluate Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/evaluate)
- [Azure SRE Agent pricing and billing](https://sre.azure.com/docs/reference/pricing-billing)
- [Azure Monitor alerts in Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/azure-monitor-alerts)
- [Diagnose with Azure Observability](https://learn.microsoft.com/azure/sre-agent/diagnose-azure-observability)

## 1. Deploy the agent

Enable the stage in `lab.config.json`:

```json
"stageToggles": {
  "enableStageSreAgent": true
}
```

For a one-shot deployment, `deploy.ps1` maps this toggle to the Bicep `enableSreAgent` parameter. The deployment creates:

- `Microsoft.App/agents` in `swedencentral`
- A regional user-assigned managed identity
- Reader, Monitoring Reader, and Log Analytics Reader access to the lab resource group
- SRE Agent Administrator access for the deploying user and agent identity
- Azure Monitor, Application Insights, and Log Analytics connectors

The agent uses Review mode, Low access, the Microsoft Foundry automatic model, and a 1,000 monthly Agent Unit limit. Creating the resource can start billing. Eligible new customers receive the 30-day always-on charge waiver automatically; confirm the evaluation status in **Settings > Agent consumption** after deployment.

You can rerun validation directly after deployment:

```powershell
./scripts/setup-sre-agent.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <resource-group>
```

The check pins Azure CLI to the explicit subscription and verifies the lab resources, SRE Agent region, connectors, managed identity, and RBAC.

## 2. Review the deployed agent

1. Open the URL printed by `deploy.ps1`, or open [sre.azure.com](https://sre.azure.com/).
2. Select the deployed `sre-amlab-<suffix>` agent.
3. Confirm the region is **Sweden Central** and the action mode is **Review**.
4. Open **Settings > Agent consumption** and confirm whether the 30-day evaluation applies.
5. Open **Settings > Azure settings > Go to Identity** to inspect the managed identity.

Reader mode supports investigation and uses on-behalf-of approval when a write is needed. Only an SRE Agent Administrator using a work or school account can approve that elevation.

## 3. Verify permissions

Run the validation script. It discovers the agent identity automatically:

```powershell
./scripts/setup-sre-agent.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <resource-group>
```

The documented role set is:

| Role | Scope | Purpose |
|---|---|---|
| Reader | Lab resource group | Discover resources and inspect configuration |
| Log Analytics Reader | Lab resource group | Query workspace and Application Insights logs |
| Monitoring Reader | Lab resource group | Read metrics and monitoring data |
| Monitoring Contributor | Subscription | Acknowledge and close Azure Monitor alerts |

The Bicep deployment assigns the resource-group roles. If Monitoring Contributor is needed to acknowledge or close alerts, review the subscription scope and grant it explicitly:

```powershell
./scripts/setup-sre-agent.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <resource-group> `
  -GrantMissingRoles
```

The script requires typing `GRANT` before it creates role assignments. Use `-Yes` only in controlled automation.

## 4. Verify Azure Monitor

1. In the SRE Agent portal, open **Builder > Connectors** and confirm Azure Monitor, Application Insights, and Log Analytics are present.
2. Open **Incidents > Triggers & response plans**.
3. If the page displays **Connect an incident platform**, select it, choose **Azure Monitor**, select the lab subscription, and save. The **Create a response plan** button remains disabled until this connection is complete.
4. On the **Triggers & response plans** tab, delete any generated quickstart plan before adding the plans below. Leaving it active can process the same incident twice or route it to the wrong custom agent.

The Azure Monitor scanner checks approximately every minute. Its initial lookback is one day, repeated firings from the same alert rule merge into one active thread, and alert status synchronizes approximately every five minutes.

## 5. Create the custom agents

Open **Builder > Agent Canvas** and select **Create > Custom Agent**. Custom-agent names can contain only letters, numbers, or hyphens and must be 36 characters or fewer. In the Custom Agent form, enter the name and supplied **Instructions**, then scroll below Instructions to **Handoff Description**. Some portal versions label this field **Handoff instructions**. Enter the indicated handoff text and save. **Handoff Agents**, tools, and knowledge sources are separate optional settings and can remain empty for this lab.

### Application Investigator

Create a custom agent named `amlab-app-investigator` with these instructions:

**Handoff description:** `Investigates App Service and Application Insights incidents.`

```text
Investigate Azure Monitor incidents for the Azure Monitor Demo Lab resource group.
Start with the affected resource and alert time. Inspect Application Insights
requests, exceptions, traces, and dependencies, then App Service metrics,
resource configuration, Activity Logs, and deployment or release annotations.
Correlate evidence from 15 minutes before the first signal through 30 minutes
after it. State the observed impact, timeline, likely cause, confidence, and the
smallest reversible mitigation. Separate evidence from inference. Do not modify
resources without approval. After an approved action, verify the original alert
signal and application failure rate before declaring recovery.
```

### Platform Investigator

Create a custom agent named `amlab-platform-investigator` with these instructions:

**Handoff description:** `Investigates AKS and virtual machine incidents.`

```text
Investigate Azure Monitor incidents for AKS and virtual machines in the Azure
Monitor Demo Lab resource group. For AKS, inspect KubePodInventory,
ContainerLogV2, Kubernetes events, pod status, restart counts, and Azure Monitor
metrics. For virtual machines, inspect power state, heartbeat, metrics, Resource
Health, and Activity Logs. Build a timestamped evidence chain and identify the
affected component and blast radius. Separate evidence from inference. Use
passive diagnostics first. Ask for approval before active VM commands or any
resource change. Verify the original signal after an approved mitigation.
```

## 6. Create response plans

Keep both plans in **Review** mode for the trial. Open **Incidents > Triggers & response plans** and select **Create a response plan**. For each row below, enter the plan name, severity, title filter, and response custom agent in **Step 1: Response plan**. Set **Agent autonomy level** to **Review** because the default is Autonomous. Select **Next**, choose **Last 7 days** in **Step 2: Incidents preview**, review any matches, and select **Create**. An empty preview is expected when no matching alert has fired yet.

| Plan | Severity | Title contains | Custom agent |
|---|---|---|---|
| `amlab-app-alerts` | Sev2 | `webapp` or `failed-requests` | `amlab-app-investigator` |
| `amlab-platform-alerts` | Sev2, Sev3 | `aks`, `pod`, or `vm` | `amlab-platform-investigator` |

The portal currently accepts one **Title contains** value per plan. Use `webapp` for `amlab-app-alerts` and `aks` for `amlab-platform-alerts`. To cover each additional title fragment in the table, clone the corresponding plan with a unique name and replace the title filter. Confirm every plan shows status **On** and mode **Review**. Turn off plans when the demo is idle to prevent expected lab alerts from consuming active-flow AAUs.

## 7. Run the scenarios

Scenarios 54 through 58 in `DEMO-SCENARIOS.md` form one 20-minute SRE Agent flow:

1. Validate the trial, scope, and permissions.
2. Trigger an App Service incident and watch automatic investigation start.
3. Diagnose the AKS crash loop with the platform investigator.
4. Correlate the incident with Activity Log changes and release annotations.
5. Demonstrate repeated-alert merging, restore the lab, and verify recovery.

## 8. Done when

1. The trial banner and creation date are recorded.
2. The SRE Agent location is Sweden Central (`swedencentral`).
3. The lab resource group is the only managed resource group.
4. All four documented role checks pass.
5. Azure Monitor is connected as the incident platform.
6. The quickstart response plan is removed.
7. Both lab response plans are enabled in Review mode only during the demo.
8. A fired lab alert creates or updates an investigation thread.
9. The agent cites evidence from at least two Azure observability sources.
10. The agent confirms recovery after `restore-the-lab.ps1`.

## 9. Stop costs

After the demo:

1. Turn off both incident response plans.
2. Open **Settings > Agent consumption** and review active-flow AAUs by thread.
3. Stop the agent when it is not being evaluated.
4. Delete the agent before day 31 if you do not intend to pay the fixed always-on charge.

Deleting the lab resource group does not delete the SRE Agent. Remove the agent separately in **Settings > Basics > Delete agent**.