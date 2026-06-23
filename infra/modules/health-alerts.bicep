@description('Action Group resource ID.')
param actionGroupId string

@description('Resource tags.')
param tags object = {}

// Service Health alert (any incident in any subscription region/service we use)
resource serviceHealth 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-service-health'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    description: 'Notify on any Azure Service Health event affecting this subscription'
    scopes: [ subscription().id ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
      ]
    }
    actions: {
      actionGroups: [
        { actionGroupId: actionGroupId }
      ]
    }
  }
}

// Resource Health alert (any resource in this RG goes Unavailable/Degraded)
resource resourceHealth 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-resource-health'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    description: 'Notify on Resource Health changes (Unavailable / Degraded) inside this resource group'
    scopes: [ resourceGroup().id ]
    condition: {
      allOf: [
        { field: 'category', equals: 'ResourceHealth' }
        {
          anyOf: [
            { field: 'properties.currentHealthStatus', equals: 'Unavailable' }
            { field: 'properties.currentHealthStatus', equals: 'Degraded' }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        { actionGroupId: actionGroupId }
      ]
    }
  }
}
