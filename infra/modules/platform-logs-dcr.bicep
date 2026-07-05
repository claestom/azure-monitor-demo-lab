// =====================================================================================
// Scenario 51 — Platform logs at scale with DCRs (PUBLIC PREVIEW).
//
// Reference: https://learn.microsoft.com/azure/azure-monitor/data-collection/platform-logs-collect
//
// What this is:
//   A single "PlatformTelemetry" Data Collection Rule that collects Azure resource
//   platform logs (a.k.a. resource logs) from one or more monitored resources and
//   routes them to the central Log Analytics workspace — replacing the classic
//   per-resource diagnostic setting model (scenario 5 DINE policy) with one rule
//   that can be associated with many resources.
//
// Why Key Vault as the demo target:
//   The lab already deploys a Key Vault (`kv-<prefix>-<suffix>`) whose AuditEvent
//   logs are a clean, low-volume platform-log stream — ideal to prove the pattern
//   without generating noise.
//
// Design notes / preview constraints:
//   * kind MUST be 'PlatformTelemetry' and api-version 2024-03-11 (DCR + DCRA).
//   * Log Analytics destination requires NO managed identity and NO RBAC.
//     (Storage / Event Hubs destinations would require a system-assigned identity
//      plus Storage Blob Data Contributor / Azure Event Hubs Data Sender.)
//   * The DCR and the destination LAW must be in the SAME region.
//   * A single resource can have at most 5 platform-telemetry DCRs associated.
//   * Disable the equivalent diagnostic-setting log categories on the target to
//     avoid duplicate ingestion when this rule is enabled.
// =====================================================================================

@description('Platform-logs DCR name.')
param name string

@description('Region. Must match the destination LAW region and be a supported preview region.')
param location string

@description('Central LAW resource ID (Log Analytics destination + DCR data path).')
param centralLawId string

@description('Name of the Key Vault to associate the DCR with (the monitored resource).')
param keyVaultName string

@description('Platform-telemetry log streams to collect (resourceType:Logs-Group-All).')
param streams array = [
  'microsoft.keyvault/vaults:Logs-Group-All'
]

@description('Name of the data collection rule association created on the Key Vault.')
param associationName string = 'amlab-platformlogs'

@description('Resource tags.')
param tags object = {}

// The monitored resource — an existing Key Vault deployed by the foundation stage.
resource keyVault 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: keyVaultName
}

// ---------------------------------------------------------------------------------
// Platform-telemetry DCR — collects platform logs and sends them to the central LAW.
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
          name: 'platformLogsSource'
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
// DCR Association — attach the single rule to the monitored resource.
// Scale-out: the same DCR can be associated with thousands of resources this way
// (here we associate one, but ARM / Bicep / Terraform / Azure Policy all use the
//  identical DCRA object to fan the rule out).
// ---------------------------------------------------------------------------------
resource dcra 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = {
  scope: keyVault
  name: associationName
  properties: {
    dataCollectionRuleId: dcr.id
    description: 'Platform-logs DCR association (scenario 51) — replaces per-resource diagnostic settings.'
  }
}

output dcrId string = dcr.id
output dcrName string = dcr.name
