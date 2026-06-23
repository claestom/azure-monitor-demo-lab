@description('Log Analytics workspace name.')
param name string

@description('Region.')
param location string

@description('Daily ingestion cap in GB. Set to -1 to disable.')
param dailyQuotaGb int = -1

@description('Resource tags.')
param tags object = {}

@description('OperationsManagement solutions to install on this workspace (e.g. VMInsights, ContainerInsights).')
param solutions array = []

@description('Enable LAW cross-region replication. Doubles ingestion cost — default OFF.')
param enableReplication bool = false

@description('Secondary region for replication (must be a paired region). Required when enableReplication = true.')
param replicationLocation string = ''

resource law 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb == -1 ? json('-1') : dailyQuotaGb
    }
    features: {
      // Granular RBAC (ABAC conditions) requires workspace-permissions mode.
      // Set to false so ABAC table/row filters are enforced on all role assignments.
      enableLogAccessUsingOnlyResourcePermissions: false
    }
    replication: enableReplication ? {
      enabled: true
      location: replicationLocation
    } : null
  }
}

resource sols 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = [for s in solutions: {
  name: '${s}(${name})'
  location: location
  tags: tags
  properties: {
    workspaceResourceId: law.id
  }
  plan: {
    name: '${s}(${name})'
    promotionCode: ''
    product: 'OMSGallery/${s}'
    publisher: 'Microsoft'
  }
}]

output id string = law.id
output name string = law.name
output customerId string = law.properties.customerId
