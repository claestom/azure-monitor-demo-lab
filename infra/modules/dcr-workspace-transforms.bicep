// =====================================================================================
// FEATURE 1 — Workspace Transformation DCR on AzureActivity (cost-control demo).
//
// Pattern: https://learn.microsoft.com/azure/azure-monitor/essentials/data-collection-transformations-workspace
//
// Why a workspace transformation?
//   - No agent involved; no Logs Ingestion API plumbing.
//   - Applies to data that ALREADY flows into the central LAW (AzureActivity).
//   - One DCR, one DCRA (name MUST be "microsoft-default"), and you instantly
//     reshape rows before they hit billing.
//
// The transform does TWO things to every row in the `AzureActivity` stream:
//   (a) FILTER:  drops "_read" operations (huge volume, minimal forensic value).
//                In real environments this typically removes 60-90% of the table.
//   (b) ENRICH:  adds an in-row marker so we can prove the transform ran without
//                touching the table schema. (Built-in tables don't accept new
//                columns at the schema level without an explicit Add-Column op;
//                so we stuff the marker into the existing `Properties_d` dynamic
//                column via `pack`.)
// =====================================================================================

@description('Workspace-transform DCR name.')
param name string

@description('Region.')
param location string

@description('Central LAW resource ID (data path target + DCRA scope).')
param centralLawId string

@description('Central LAW name (needed for the DCRA child resource).')
param centralLawName string

@description('Resource tags.')
param tags object = {}

// ---------------------------------------------------------------------------------
// Workspace Transformation DCR
// ---------------------------------------------------------------------------------
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: name
  location: location
  tags: tags
  kind: 'WorkspaceTransforms'
  properties: {
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: centralLawId
          name: 'centralLaw'
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-Table-AzureActivity' ]
        destinations: [ 'centralLaw' ]
        // FILTER + ENRICH at ingest. Notes:
        //   * Stream "Microsoft-Table-AzureActivity" is the workspace-transform
        //     stream name (matches the AzureActivity table).
        //   * We DROP anything whose OperationNameValue ends in "/read" — these
        //     are noisy GET-style activities (LIST, READ, GET) that contribute
        //     huge volume to AzureActivity with low forensic value.
        //   * We ADD an enrichment marker by packing it into the existing dynamic
        //     `Properties` column (built-in tables don't allow new top-level
        //     columns at the workspace-transform level without a separate Add-Column).
        transformKql: 'source\n| where tolower(OperationNameValue) !endswith "/read"\n| extend Properties = bag_merge(parse_json(Properties), pack("FilteredBy","amlab-workspace-transform","FilteredAt", tostring(now())))'
      }
    ]
  }
}

// ---------------------------------------------------------------------------------
// Data Collection Rule Association — the magic name "microsoft-default" tells
// Log Analytics: "use this DCR as the workspace's default transformation pipeline".
// Scope: the LAW itself.
// ---------------------------------------------------------------------------------
resource lawRef 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: centralLawName
}

resource dcra 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  scope: lawRef
  name: 'microsoft-default'
  properties: {
    dataCollectionRuleId: dcr.id
    description: 'Workspace transformation DCR (FEATURE 1 cost-control demo).'
  }
}

output dcrId string   = dcr.id
output dcrName string = dcr.name
