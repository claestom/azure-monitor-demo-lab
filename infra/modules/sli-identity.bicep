// =====================================================================================
// SLI prerequisites — scenario 46
//
// Service Level Indicators (Microsoft.Monitor/slis, preview) need:
//   1. A User-Assigned Managed Identity (UAMI) authorised to read metrics on the
//      source Azure Monitor Workspace and write them back to the destination AMW.
//   2. Two role assignments on the AMW:
//        * Monitoring Reader            (43d0d8ad-25c7-4714-9337-8ba259a9fe05)
//        * Monitoring Metrics Publisher (3913510d-42f4-4e42-8a64-420c390055eb)
//
// The SLI resource itself is an EXTENSION on the tenant-scoped service group, so
// it can't be expressed in this RG-scoped Bicep file. scripts/setup-slis.ps1 PUTs
// the SLI bodies via `az rest`, referencing the UAMI + AMW IDs exported below.
// =====================================================================================
@description('User-Assigned Managed Identity name used by every SLI in this lab.')
param uamiName string

@description('Region for the UAMI.')
param location string

@description('Tags applied to the UAMI.')
param tags object = {}

@description('Resource ID of the Azure Monitor Workspace used as both the SLI source and destination.')
param azureMonitorWorkspaceId string

// -----------------------------------------------------------------------------
// User-Assigned Managed Identity
// -----------------------------------------------------------------------------
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
  tags: tags
}

// -----------------------------------------------------------------------------
// Existing AMW reference (so we can scope the role assignments to it)
// -----------------------------------------------------------------------------
var amwName = last(split(azureMonitorWorkspaceId, '/'))

resource amw 'Microsoft.Monitor/accounts@2023-04-03' existing = {
  name: amwName
}

// -----------------------------------------------------------------------------
// RBAC on the AMW (source + destination)
// -----------------------------------------------------------------------------
// Monitoring Reader = 43d0d8ad-25c7-4714-9337-8ba259a9fe05
resource amwMonitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(amw.id, uami.id, '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
  scope: amw
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Monitoring Metrics Publisher = 3913510d-42f4-4e42-8a64-420c390055eb
resource amwMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(amw.id, uami.id, '3913510d-42f4-4e42-8a64-420c390055eb')
  scope: amw
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// Outputs (consumed by scripts/setup-slis.ps1)
// -----------------------------------------------------------------------------
output uamiName string        = uami.name
output uamiId string          = uami.id
output uamiPrincipalId string = uami.properties.principalId
output uamiClientId string    = uami.properties.clientId
output amwId string           = amw.id
