// =====================================================================================
// Azure Policy: assign 4 built-in DeployIfNotExists policies that send "allLogs" +
// metrics to the central Log Analytics workspace for every supported resource in this
// resource group. This implements the pattern from
// https://learn.microsoft.com/en-us/azure/azure-monitor/platform/diagnostic-settings-policy
//
// Scope: resource group (the parent of this module).
// Effect: DeployIfNotExists — Azure Policy will auto-create diagnostic settings on
//         every existing or new App Service / VNet / NSG / Public IP in this RG.
// Identity: each assignment uses a System-Assigned Managed Identity which is granted
//           Log Analytics Contributor + Monitoring Contributor on the RG.
// =====================================================================================

@description('Resource ID of the central Log Analytics workspace destination.')
param centralLawId string

var policies = [
  {
    key: 'appservice'
    displayName: 'Diag → Central LAW for App Services'
    builtInId: '/providers/Microsoft.Authorization/policyDefinitions/c0d8e23a-47be-4032-961f-8b0ff3957061'
    hasCategoryGroup: false
  }
  {
    key: 'vnet'
    displayName: 'Diag → Central LAW for Virtual Networks'
    builtInId: '/providers/Microsoft.Authorization/policyDefinitions/3234ff41-8bec-40a3-b5cb-109c95f1c8ce'
    hasCategoryGroup: true
  }
  {
    key: 'nsg'
    displayName: 'Diag → Central LAW for Network Security Groups'
    builtInId: '/providers/Microsoft.Authorization/policyDefinitions/baa4c6de-b7cf-4b12-b436-6e40ef44c8cb'
    hasCategoryGroup: true
  }
  {
    key: 'pip'
    displayName: 'Diag → Central LAW for Public IP Addresses'
    builtInId: '/providers/Microsoft.Authorization/policyDefinitions/1513498c-3091-461a-b321-e9b433218d28'
    hasCategoryGroup: true
  }
]

var baseParams = {
  effect:                { value: 'DeployIfNotExists' }
  diagnosticSettingName: { value: 'setByPolicy-LogAnalytics' }
  logAnalytics:          { value: centralLawId }
}
var withCategoryGroup = union(baseParams, {
  categoryGroup: { value: 'allLogs' }
})

resource assignments 'Microsoft.Authorization/policyAssignments@2024-04-01' = [for p in policies: {
  name: 'amlab-diag-${p.key}'
  location: resourceGroup().location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: p.displayName
    description: 'Demo lab: ensure diagnostic settings exist on ${p.key} resources, sending allLogs to the central LAW.'
    policyDefinitionId: p.builtInId
    parameters: p.hasCategoryGroup ? withCategoryGroup : baseParams
    enforcementMode: 'Default'
  }
}]

// Grant each assignment's MSI the roles needed to write diagnostic settings + read LAW.
// Log Analytics Contributor: 92aaf0da-9dab-42b6-94a3-d43ce8d16293
// Monitoring Contributor:    749f88d5-cbae-40b8-bcfc-e573ddc772fa
var roleIds = [
  '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
  '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
]

resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for i in range(0, length(policies) * length(roleIds)): {
  name: guid(resourceGroup().id, policies[i / length(roleIds)].key, roleIds[i % length(roleIds)])
  properties: {
    principalId: assignments[i / length(roleIds)].identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds[i % length(roleIds)])
    principalType: 'ServicePrincipal'
  }
}]

output assignmentIds array = [for (p, i) in policies: assignments[i].id]
