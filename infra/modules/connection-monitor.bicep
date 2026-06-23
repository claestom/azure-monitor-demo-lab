// =====================================================================================
// Network Watcher + Connection Monitor — hop-by-hop network telemetry between
// the Linux VM and the App Service (HTTPS endpoint) + the AKS LB IP target.
//
// Why this matters:
//   - VM Insights answers "what's the VM doing?". Connection Monitor answers
//     "can the VM TALK to the things it should?".
//   - Results flow into the workspace as `NWConnectionMonitorTestResult` rows
//     (and the Network Insights blade in the portal picks them up automatically).
//
// Requires: Network Watcher in the same region (created here explicitly), plus
// the Network Watcher Agent extension on the source VMs (added in
// vm-linux.bicep / vm-windows.bicep).
// =====================================================================================

@description('Region.')
param location string

@description('Central LAW resource ID (results destination).')
param centralLawId string

@description('Resource ID of the Linux VM source.')
param linuxVmId string = ''

@description('Resource ID of the Windows VM source.')
param windowsVmId string = ''

@description('App Service URL to test (no scheme, just host: e.g. app-amlab.azurewebsites.net).')
param appServiceHost string

@description('Resource tags.')
param tags object = {}

// -----------------------------------------------------------------------------
// Network Watcher — Azure auto-creates one per region per subscription in the
// "NetworkWatcherRG" resource group; we just reference that singleton.
// This module MUST be deployed at NetworkWatcherRG scope (see main.bicep).
// -----------------------------------------------------------------------------
resource nw 'Microsoft.Network/networkWatchers@2024-01-01' existing = {
  name: 'NetworkWatcher_${location}'
}

// -----------------------------------------------------------------------------
// Connection Monitor v2 — HTTPS test from each VM (if present) to the App Service.
// Multiple test-groups in one Connection Monitor instance keep this compact.
// -----------------------------------------------------------------------------
var hasLinux = !empty(linuxVmId)
var hasWin   = !empty(windowsVmId)

var endpoints = concat(
  hasLinux ? [{
    name: 'src-vm-linux'
    type: 'AzureVM'
    resourceId: linuxVmId
  }] : [],
  hasWin ? [{
    name: 'src-vm-windows'
    type: 'AzureVM'
    resourceId: windowsVmId
  }] : [],
  [{
    name: 'dst-appservice'
    type: 'ExternalAddress'
    address: appServiceHost
  }]
)

var testConfigs = [
  {
    name: 'tc-https-appservice'
    testFrequencySec: 60
    protocol: 'Tcp'
    tcpConfiguration: {
      port: 443
      disableTraceRoute: false
    }
    successThreshold: {
      checksFailedPercent: 30
      roundTripTimeMs: 2000
    }
  }
]

var sourceNames = concat(
  hasLinux ? [ 'src-vm-linux' ] : [],
  hasWin   ? [ 'src-vm-windows' ] : []
)

var testGroups = empty(sourceNames) ? [] : [
  {
    name: 'tg-vms-to-appservice'
    disable: false
    sources: sourceNames
    destinations: [ 'dst-appservice' ]
    testConfigurations: [ 'tc-https-appservice' ]
  }
]

resource cm 'Microsoft.Network/networkWatchers/connectionMonitors@2024-01-01' = if (!empty(testGroups)) {
  parent: nw
  name: 'cm-amlab-vms-to-appservice'
  location: location
  tags: tags
  properties: {
    endpoints: endpoints
    testConfigurations: testConfigs
    testGroups: testGroups
    outputs: [
      {
        type: 'Workspace'
        workspaceSettings: {
          workspaceResourceId: centralLawId
        }
      }
    ]
  }
}

output networkWatcherId string = nw.id
output connectionMonitorName string = !empty(testGroups) ? cm!.name : ''
