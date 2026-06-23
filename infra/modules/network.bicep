@description('VNet name.')
param vnetName string

@description('NSG name applied to the workload subnet.')
param nsgName string

@description('Region.')
param location string

@description('Resource tags.')
param tags object = {}

var addressSpace      = '10.50.0.0/16'
var workloadSubnet    = '10.50.1.0/24'
var aksSubnet         = '10.50.2.0/23'
var bastionSubnet     = '10.50.10.0/26'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-From-Internet'
        properties: {
          priority: 1000
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-RDP-From-Internet'
        properties: {
          priority: 1010
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ addressSpace ]
    }
    subnets: [
      {
        name: 'snet-workload'
        properties: {
          addressPrefix: workloadSubnet
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: 'snet-aks'
        properties: {
          addressPrefix: aksSubnet
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnet
        }
      }
    ]
  }
}

// Reserved (not deployed) — uncomment to add Bastion later for password-free admin
// resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = { ... }

output vnetId string           = vnet.id
output workloadSubnetId string = '${vnet.id}/subnets/snet-workload'
output aksSubnetId string      = '${vnet.id}/subnets/snet-aks'
