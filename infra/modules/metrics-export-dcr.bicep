// =====================================================================================
// Scenario 52 — Azure Monitor Metrics Export via DCRs (GENERALLY AVAILABLE).
//
// Reference: https://learn.microsoft.com/azure/azure-monitor/essentials/data-collection-metrics
//
// What this is:
//   A single "PlatformTelemetry" Data Collection Rule that continuously exports
//   platform METRICS from one or more monitored resources to the central Log
//   Analytics workspace (stored in the `AzureMetricsV2` table). Unlike the metrics
//   half of a diagnostic setting, DCR-based export:
//     * preserves multidimensional metrics (dimensions kept, not flattened),
//     * lets you filter by metric name to control downstream volume / cost,
//     * delivers with ~3 min end-to-end latency,
//     * is now GA across 44 Azure regions.
//
// Why Key Vault as the demo target:
//   Key Vault emits richly-dimensioned metrics (e.g. ServiceApiLatency /
//   ServiceApiHit broken out by StatusCode / ActivityName) — the perfect way to
//   show dimensional fidelity that diagnostic settings would drop.
//
// Design notes / constraints:
//   * kind MUST be 'PlatformTelemetry' and api-version 2024-03-11 (DCR + DCRA).
//   * Log Analytics destination requires NO managed identity and NO RBAC.
//     (Storage / Event Hubs destinations require a system-assigned identity plus
//      Storage Blob Data Contributor / Azure Event Hubs Data Sender.)
//   * For a LAW destination the DCR must be in the same region as the LAW; the
//     monitored resource may live in any region.
//   * A single resource can have at most 5 metrics-export DCRs associated.
//   * Hourly-grain metrics are not supported for export.
//   * Disable the equivalent diagnostic-setting metric export on the target to
//     avoid duplicate ingestion when this rule is enabled.
// =====================================================================================

@description('Metrics-export DCR name.')
param name string

@description('Region. Must match the destination LAW region.')
param location string

@description('Central LAW resource ID (Log Analytics destination + DCR data path).')
param centralLawId string

@description('Name of the Key Vault to associate the DCR with (the monitored resource).')
param keyVaultName string

@description('Platform-telemetry metric streams to export. Use ":Metrics-Group-All" for all metrics of a type, or narrow to specific metric names to control cost.')
param streams array = [
  'Microsoft.KeyVault/vaults:Metrics-Group-All'
]

@description('Name of the data collection rule association created on the Key Vault.')
param associationName string = 'amlab-metricsexport'

@description('Resource tags.')
param tags object = {}

// The monitored resource — an existing Key Vault deployed by the foundation stage.
resource keyVault 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: keyVaultName
}

// ---------------------------------------------------------------------------------
// Platform-telemetry DCR — exports platform metrics to the central LAW
// (AzureMetricsV2 table), preserving dimensions.
// ---------------------------------------------------------------------------------
resource dcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: name
  location: location
  tags: tags
  kind: 'PlatformTelemetry'
  properties: {
    dataSources: {
      platformTelemetry: [
        {
          streams: streams
          name: 'metricsExportSource'
        }
      ]
    }
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
        streams: streams
        destinations: [ 'centralLaw' ]
      }
    ]
  }
}

// ---------------------------------------------------------------------------------
// DCR Association — attach the export rule to the monitored resource.
// ---------------------------------------------------------------------------------
resource dcra 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = {
  scope: keyVault
  name: associationName
  properties: {
    dataCollectionRuleId: dcr.id
    description: 'Metrics-export DCR association (scenario 52) — dimensional metrics to AzureMetricsV2.'
  }
}

output dcrId string = dcr.id
output dcrName string = dcr.name
