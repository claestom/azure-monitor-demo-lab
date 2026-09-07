targetScope = 'subscription'

@description('System-assigned principal ID of the Azure SRE Agent connector identity.')
param principalId string

resource monitoringContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, '43bfe7e3-6883-4a1e-b686-33a7fe5db0c7')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43bfe7e3-6883-4a1e-b686-33a7fe5db0c7')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}