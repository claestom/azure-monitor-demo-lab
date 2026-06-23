// =====================================================================================
// Storage account — multi-purpose for the lab:
//   - Target for VNet flow logs (used by flow-logs.bicep)
//   - Target for diagnostic settings "archive" fan-out (multi-destination demo)
//   - Target for LAW continuous Data Export rule
//   - Subject of the Storage Insights demo (its own diag settings -> central LAW)
// =====================================================================================

@description('Storage account name (must be globally unique, 3-24 lowercase).')
param name string

@description('Region.')
param location string

@description('Central LAW resource ID — used so the SA itself reports to LAW for Storage Insights.')
param centralLawId string

@description('Resource tags.')
param tags object = {}

resource sa 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices, Logging, Metrics'
    }
  }
}

// Pre-create a container the data-export rule can write to.
resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: sa
  name: 'default'
}

resource exportContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobSvc
  name: 'law-export'
  properties: {
    publicAccess: 'None'
  }
}

resource archiveContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobSvc
  name: 'diag-archive'
  properties: {
    publicAccess: 'None'
  }
}

// Storage Insights demo: diag settings on the account itself -> central LAW.
// (Storage emits Transaction metrics + Capacity metrics + (optional) data-plane logs.)
resource diagAccount 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: sa
  name: 'send-to-central-law'
  properties: {
    workspaceId: centralLawId
    metrics: [
      { category: 'Transaction', enabled: true }
      { category: 'Capacity',    enabled: true }
    ]
  }
}

// Data-plane logs go on the BLOB sub-resource (not the account scope).
resource diagBlob 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: blobSvc
  name: 'send-to-central-law'
  properties: {
    workspaceId: centralLawId
    logs: [
      { categoryGroup: 'audit',   enabled: true }
      { categoryGroup: 'allLogs', enabled: false }
    ]
    metrics: [
      { category: 'Transaction', enabled: true }
    ]
  }
}

output id string   = sa.id
output name string = sa.name
output exportContainerName string = exportContainer.name
output archiveContainerName string = archiveContainer.name
