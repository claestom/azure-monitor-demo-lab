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

After deployment, `setup-fabric.ps1` creates or reuses:

- Fabric workspace
- Eventhouse
- Read-write KQL database
- Empty Eventstream

The Event Hub source connection and Real-Time Dashboard are guided portal steps. This keeps connection credentials out of scripts and avoids relying on evolving dashboard item definitions.

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
3. Add an Azure Event Hubs source.
4. Select the deployed namespace, the `diagnostics` Event Hub, and an interactive Fabric connection.
5. Route the stream to the `MonitoringTelemetry` KQL database.
6. Create a Real-Time Dashboard from the KQL database after events arrive.

## Suspend and resume

```powershell
./scripts/suspend-fabric.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>
./scripts/resume-fabric.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>
```

Both commands require confirmation by default and verify the explicit subscription before changing the capacity.

## Demo scenarios

See scenarios 54 through 59 in [DEMO-SCENARIOS.md](DEMO-SCENARIOS.md).