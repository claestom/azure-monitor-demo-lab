# Stage Fabric - Microsoft Fabric Real-Time Intelligence

Stage Fabric adds an optional Microsoft Fabric F2 capacity and a guided Real-Time Intelligence scenario. It is disabled by default because F2 bills while active.

## Cost warning

The deployment is pinned to **F2 in Sweden Central**. Indicative Microsoft PAYG retail pricing is:

| Active time | Approximate F2 compute cost |
|---|---:|
| 1 hour | $0.36 USD |
| 24 hours | $8.64 USD |
| 1 month | $262.80 USD |

Actual pricing varies by agreement, currency, and region. OneLake storage and other Fabric meters can add charges. Suspend the capacity whenever the demo is idle.

> Microsoft currently recommends at least four capacity units (F4) for Eventstreams. This lab intentionally pins to F2 to limit demo cost. F2 is suitable for light, short-lived sample traffic but can throttle under sustained ingestion; use the Capacity Metrics app in scenario 58 to show that tradeoff.

## Architecture

```text
App Service and AKS
        |
        v
Azure Event Hubs diagnostics
        |
        v
Fabric Eventstream
        |
        v
Eventhouse and KQL database
        |
        v
Real-Time Dashboard and KQL exploration
```

Azure Monitor remains the operational monitoring system. Fabric demonstrates streaming analytics, broader event correlation, and Real-Time Intelligence over the same application estate.

## What is automated

The Bicep or Terraform deployment creates:

- One `Microsoft.Fabric/capacities` resource
- SKU fixed to `F2`
- Location fixed to `swedencentral`
- Capacity administrator set to the explicit `fabricAdminEmail` tenant user UPN
- A **Real-Time Intelligence** tier in `hm-amlab-workload`, with the F2 capacity represented as an Azure resource entity using Resource Health
- A dynamic **Fabric F2 Capacity Health** section in the main Azure Monitor Health Dashboard workbook, discovered through Azure Resource Graph

After deployment, `setup-fabric.ps1` creates or reuses:

- Fabric workspace
- Eventhouse
- Read-write KQL database
- Empty Eventstream

The Event Hub source connection and Real-Time Dashboard are guided portal steps. This keeps connection credentials out of scripts and avoids relying on evolving dashboard item definitions.

The Azure Monitor workbook reports the ARM capacity state and provisioning state. Fabric Eventstream is a tenant-scoped SaaS item rather than an ARM resource, so its item and data-flow status is inspected in the Fabric workspace instead of queried directly by the Azure workbook.

## Prerequisites

- Microsoft Fabric enabled for the tenant
- Permission to create Fabric workspaces
- Capacity administrator or contributor access
- A Microsoft Entra user UPN from the deployment tenant for `fabricAdminEmail`; an external alert or guest notification address is not sufficient
- Stage A deployed if the Eventstream will use the lab Event Hub
- Azure CLI and PowerShell 7+

## One-shot deployment

Set the Fabric toggle in `lab.config.json`:

```json
"stageToggles": {
  "enableStageFabric": true
},
"fabricAdminEmail": "admin@yourtenant.onmicrosoft.com"
```

Then deploy and configure the Fabric items:

```powershell
./scripts/deploy.ps1
./scripts/setup-fabric.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>
```

Fabric item creation is asynchronous and can be slower on F2. The setup script waits up to 30 minutes by default, honors the service `Retry-After` header, and prints operation IDs and progress. Override the ceiling with `-MaxOperationMinutes <5-120>`. If a caller times out, the Fabric operation can still finish; rerun the same command safely and the script will reuse every item that already exists.

## Staged Bicep deployment

```powershell
az deployment group create `
  --subscription <subscription-id> `
  --resource-group <resource-group> `
  --name stage-fabric-capacity `
  --template-file infra/stages/60-fabric.bicep `
        --parameters namePrefix=amlab fabricAdminEmail=admin@yourtenant.onmicrosoft.com

./scripts/setup-fabric.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>
```

## Terraform deployment

Set `enable_stage_fabric = true` in `terraform/stages.tfvars`, then run:

```powershell
terraform -chdir=terraform plan -var-file stages.tfvars
terraform -chdir=terraform apply -var-file stages.tfvars
./scripts/setup-fabric.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>
```

## Complete the Eventstream in Fabric

1. Open the workspace URL printed by `setup-fabric.ps1`.
2. Open the `AzureMonitorEvents` Eventstream.
3. Switch to **Edit** mode and select **Add source** > **Connect data sources** > **Azure Event Hubs**.
4. Create a **Shared Access Key** connection for the deployed namespace and the `diagnostics` Event Hub.
5. Use Shared Access Key Name `diagnostics-listen` and retrieve its primary or secondary key from **Event Hubs namespace** > **Shared access policies**. Do not use `diagnostics-send`; it cannot consume events.
6. Set Consumer group to `$Default`, Data format to **JSON**, and Data gateway to **none**.
7. Add an **Eventhouse** destination, select `Azure Monitor Demo Eventhouse` and `MonitoringTelemetry`, and create a destination table such as `AzureDiagnosticsRaw`.
8. Select **Publish**, confirm events arrive, then create a Real-Time Dashboard from the KQL database.

## Suspend and resume

```powershell
./scripts/suspend-fabric.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>
./scripts/resume-fabric.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>
```

Both commands require confirmation by default and verify the explicit subscription before changing the capacity.

Full lab teardown also removes the tenant-scoped workspace and its contained Eventhouse, KQL database, and Eventstream before deleting the resource group. To run only that cleanup:

```powershell
./scripts/setup-fabric.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group> -Teardown
```

## Authorization troubleshooting

`Unable to authorize with Azure Active Directory` during `Microsoft.Fabric/capacities` creation means the administrator value could not be authorized in the deployment tenant. Confirm that:

1. `fabricAdminEmail` is not empty.
2. It is a Microsoft Entra user UPN in the subscription tenant, not an external alert address.
3. The user can sign in to Microsoft Fabric and the tenant has Fabric enabled.

For this sponsored lab tenant, the known working administrator format is `admin@MngEnvMCAP363544.onmicrosoft.com`. The portal, Bicep, config-sync, and Terraform inputs now require a separate Fabric administrator value. `setup-fabric.ps1` also compares the signed-in Azure CLI user with the deployed capacity administrators before requesting a Fabric API token.

## Demo scenarios

See scenarios 54 through 59 in [DEMO-SCENARIOS.md](DEMO-SCENARIOS.md).

For staged Bicep deployment, deploy Stage Fabric before Stage E, or rerun `40-optional-advanced.bicep` with `enableFabric=true` afterward so the Real-Time Intelligence tier is added to the Health Model. Terraform enforces this dependency automatically.