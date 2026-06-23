// =====================================================================================
// Custom Logs ingestion infrastructure: Data Collection Endpoint + custom table +
// Data Collection Rule.  Used with the Logs Ingestion API (scripts/send-custom-logs.ps1).
// =====================================================================================

@description('Name prefix for resources.')
param namePrefix string

@description('Region.')
param location string

@description('Resource ID of the central LAW.')
param centralLawId string

@description('Central LAW name.')
param centralLawName string

@description('Resource tags.')
param tags object = {}

// ---------------------------------------------------------------------------------
// Data Collection Endpoint (DCE) — public ingestion endpoint for the Logs Ingestion API
// ---------------------------------------------------------------------------------
resource dceCustom 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: 'dce-${namePrefix}-customlogs'
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ---------------------------------------------------------------------------------
// Custom table in the central LAW — SecurityAudit_CL
//   Stores security-relevant custom events sent via the Logs Ingestion API.
// ---------------------------------------------------------------------------------
resource centralLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: centralLawName
}

resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: centralLaw
  name: 'SecurityAudit_CL'
  properties: {
    plan: 'Analytics'
    schema: {
      name: 'SecurityAudit_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime', description: 'Event timestamp' }
        { name: 'EventType', type: 'string', description: 'Type of security event (Login, AccessDenied, PrivilegeEscalation, etc.)' }
        { name: 'Severity', type: 'string', description: 'Event severity (Info, Warning, Critical)' }
        { name: 'UserPrincipal', type: 'string', description: 'UPN or service principal name' }
        { name: 'SourceIP', type: 'string', description: 'Source IP address' }
        { name: 'Resource', type: 'string', description: 'Target resource path' }
        { name: 'Action', type: 'string', description: 'Action attempted' }
        { name: 'Result', type: 'string', description: 'Outcome (Success, Denied, Error)' }
        { name: 'Details', type: 'string', description: 'Free-text detail / reason' }
      ]
    }
    retentionInDays: 30
  }
}

// ---------------------------------------------------------------------------------
// Data Collection Rule — maps incoming JSON to the SecurityAudit_CL table
// ---------------------------------------------------------------------------------
resource dcrCustomLogs 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-${namePrefix}-customlogs'
  location: location
  tags: tags
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dceCustom.id
    streamDeclarations: {
      'Custom-SecurityAudit_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'EventType', type: 'string' }
          { name: 'Severity', type: 'string' }
          { name: 'UserPrincipal', type: 'string' }
          { name: 'SourceIP', type: 'string' }
          { name: 'Resource', type: 'string' }
          { name: 'Action', type: 'string' }
          { name: 'Result', type: 'string' }
          { name: 'Details', type: 'string' }
        ]
      }
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
        streams: [ 'Custom-SecurityAudit_CL' ]
        destinations: [ 'centralLaw' ]
        transformKql: 'source'
        outputStream: 'Custom-SecurityAudit_CL'
      }
    ]
  }
  dependsOn: [ customTable ]
}

output dceEndpoint string = dceCustom.properties.logsIngestion.endpoint
output dceName string = dceCustom.name
output dcrName string = dcrCustomLogs.name
output dcrId string = dcrCustomLogs.id
output dcrImmutableId string = dcrCustomLogs.properties.immutableId
output tableName string = customTable.name
