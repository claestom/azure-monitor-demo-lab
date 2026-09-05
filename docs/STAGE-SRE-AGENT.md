# Stage SRE Agent - Azure Monitor incident investigation

> **Goal:** connect an Azure SRE Agent to the lab's Azure Monitor alerts and observability data, then demonstrate alert-driven investigation across Application Insights, Log Analytics, metrics, Resource Graph, and Activity Logs.
>
> **Deployment model:** Azure SRE Agent is created in [sre.azure.com](https://sre.azure.com/). The lab does not pretend that a portal operation is an IaC resource. `scripts/setup-sre-agent.ps1` validates the lab and the agent identity's Azure RBAC after creation.
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

## 1. Validate the lab

Enable the stage in `lab.config.json`:

```json
"stageToggles": {
  "enableStageSreAgent": true
}
```

For a one-shot deployment, `deploy.ps1` runs the read-only SRE Agent readiness check after the lab and its telemetry are available. For staged Bicep or Terraform deployments, `post-staged-deploy.ps1` runs the same handoff. This toggle does not create a billable agent because creation and trial activation remain portal operations.

You can also run the readiness check directly before creating the agent:

```powershell
./scripts/setup-sre-agent.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <resource-group>
```

The check pins Azure CLI to the explicit subscription and verifies that the resource group contains Log Analytics, Application Insights, App Service, AKS, and Azure Monitor alert rules.

## 2. Create one trial agent

1. Open [sre.azure.com](https://sre.azure.com/) and create an agent.
2. Confirm that the 30-day trial banner is visible. If it is absent, assume standard pricing applies.
3. Name the agent `Azure Monitor Demo SRE`.
4. Select **Sweden Central** (`swedencentral`). This location is mandatory for this lab.
5. Add the lab resource group as a managed resource group.
6. Select the **Reader** permission level for the first evaluation.
7. Finish creation, then open **Settings > Azure settings > Go to Identity**.
8. Copy the user-assigned managed identity's Object (principal) ID.

Reader mode supports investigation and uses on-behalf-of approval when a write is needed. Only an SRE Agent Administrator using a work or school account can approve that elevation.

## 3. Verify permissions

Run the script again with the agent identity:

```powershell
./scripts/setup-sre-agent.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <resource-group> `
  -AgentPrincipalId <agent-uami-object-id>
```

The documented role set is:

| Role | Scope | Purpose |
|---|---|---|
| Reader | Lab resource group | Discover resources and inspect configuration |
| Log Analytics Reader | Lab resource group | Query workspace and Application Insights logs |
| Monitoring Reader | Lab resource group | Read metrics and monitoring data |
| Monitoring Contributor | Subscription | Acknowledge and close Azure Monitor alerts |

Agent creation normally assigns these roles when the managed resource group and Azure Monitor incident platform are configured. If an assignment is missing, review the scope and grant it explicitly:

```powershell
./scripts/setup-sre-agent.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroup <resource-group> `
  -AgentPrincipalId <agent-uami-object-id> `
  -GrantMissingRoles
```

The script requires typing `GRANT` before it creates role assignments. Use `-Yes` only in controlled automation.

## 4. Connect Azure Monitor

1. In the SRE Agent portal, open **Builder > Incident platform**.
2. Select **Azure Monitor**, choose the lab subscription, and save.
3. Open **Builder > Incident response plans** and switch to Table view.
4. Delete the generated quickstart plan before adding the plans below. Leaving it active can process the same incident twice or route it to the wrong custom agent.

The Azure Monitor scanner checks approximately every minute. Its initial lookback is one day, repeated firings from the same alert rule merge into one active thread, and alert status synchronizes approximately every five minutes.

## 5. Create the custom agents

### Application Investigator

Create a custom agent named `AMLab Application Investigator` with these instructions:

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

Create a custom agent named `AMLab Platform Investigator` with these instructions:

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

Keep both plans in **Review** mode for the trial.

| Plan | Severity | Title contains | Custom agent |
|---|---|---|---|
| `amlab-app-alerts` | Sev2 | `webapp` or `failed-requests` | AMLab Application Investigator |
| `amlab-platform-alerts` | Sev2, Sev3 | `aks`, `pod`, or `vm` | AMLab Platform Investigator |

If the title filter accepts only one value, create one plan per title fragment. Turn off plans when the demo is idle to prevent expected lab alerts from consuming active-flow AAUs.

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