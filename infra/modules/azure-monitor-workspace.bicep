@description('Azure Monitor Workspace name (used for Managed Prometheus).')
param name string

@description('Region.')
param location string

@description('Resource tags.')
param tags object = {}

resource amw 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: name
  location: location
  tags: tags
  properties: {}
}

output id string = amw.id
output name string = amw.name
output prometheusQueryEndpoint string = amw.properties.metrics.prometheusQueryEndpoint
