// =====================================================================================
// VNet Flow Logs + Traffic Analytics
//
//   - VNet flow logs are the modern replacement for NSG flow logs (single log per
//     VNet, regardless of how many NSGs are attached).
//   - Traffic Analytics on top enriches them with geo-IP + topology + protocol
//     breakdowns and exposes the `NTANetAnalytics` + `NTAIpDetails` tables in
//     Log Analytics, plus the "Network → Traffic Analytics" blade.
//
// Storage account from storage-account.bicep is reused as the raw-log target.
// =====================================================================================

@description('Flow log resource name.')
param name string

@description('Region.')
param location string

@description('Target VNet resource ID (the thing we capture flows for).')
param targetVnetId string

@description('Network Watcher resource ID (must be same region).')
param networkWatcherId string

@description('Storage account resource ID where raw flow logs are written.')
param storageAccountId string

@description('Central LAW resource ID — Traffic Analytics workspace.')
param centralLawId string

@description('Central LAW region (Traffic Analytics needs the workspace region).')
param centralLawRegion string

@description('Central LAW GUID (customerId) — Traffic Analytics needs the workspace customer ID.')
param centralLawCustomerId string

@description('Retention days for raw flow logs in storage.')
param retentionDays int = 7

@description('Resource tags.')
param tags object = {}

// Flow log resource sits as a child of the Network Watcher.
// Note: 2024-01-01 supports the modern `targetResourceId` (VNet) directly.
resource flowLog 'Microsoft.Network/networkWatchers/flowLogs@2024-01-01' = {
  // Network Watcher names contain dashes that are awkward in resource refs;
  // we accept the ID and use last() to derive the parent name when needed.
  name: '${last(split(networkWatcherId, '/'))}/${name}'
  location: location
  tags: tags
  properties: {
    targetResourceId: targetVnetId
    storageId: storageAccountId
    enabled: true
    format: {
      type: 'JSON'
      version: 2
    }
    retentionPolicy: {
      days: retentionDays
      enabled: true
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        enabled: true
        workspaceId: centralLawCustomerId
        workspaceRegion: centralLawRegion
        workspaceResourceId: centralLawId
        trafficAnalyticsInterval: 10
      }
    }
  }
}

output id string = flowLog.id
output name string = flowLog.name
