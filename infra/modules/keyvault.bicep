// =====================================================================================
// Key Vault — subject of the Key Vault Insights demo (resource-type Insights).
// Diag settings → central LAW so the AuditEvent table fills with key-vault traffic.
// =====================================================================================

@description('Key Vault name (globally unique, 3-24 chars).')
param name string

@description('Region.')
param location string

@description('Central LAW resource ID for diagnostic settings.')
param centralLawId string

@description('AAD tenant ID (defaults to the deploying tenant).')
param tenantId string = subscription().tenantId

@description('Resource tags.')
param tags object = {}

resource kv 'Microsoft.KeyVault/vaults@2024-04-01-preview' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// Demo secret — exists only so Key Vault Insights has at least one entry to show in
// the "vault usage" / "secret operations" charts. Value is a deterministic placeholder.
resource demoSecret 'Microsoft.KeyVault/vaults/secrets@2024-04-01-preview' = {
  parent: kv
  name: 'amlab-demo-secret'
  properties: {
    value: 'amlab-demo-value'
    contentType: 'text/plain'
  }
}

// Diag settings: AuditEvent + AzurePolicyEvaluationDetails -> central LAW.
// Key Vault Insights blade reads from these tables.
resource diagKv 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: kv
  name: 'send-to-central-law'
  properties: {
    workspaceId: centralLawId
    logs: [
      { categoryGroup: 'audit',   enabled: true }
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output id string   = kv.id
output name string = kv.name
output uri string  = kv.properties.vaultUri
