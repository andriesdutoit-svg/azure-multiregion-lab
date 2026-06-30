param location string
param firewallName string
param vnetName string
param publicIpName string

//
// ========================================
// PUBLIC IP (required for firewall)
// ========================================
//

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-02-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

//
// ========================================
// EXISTING VNET
// ========================================
//

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

//
// ========================================
// FIREWALL
// ========================================
//

resource firewall 'Microsoft.Network/azureFirewalls@2023-02-01' = {
  name: firewallName
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }

    ipConfigurations: [
      {
        name: 'firewall-ipconfig'
        properties: {
          subnet: {
            id: resourceId(
              'Microsoft.Network/virtualNetworks/subnets',
              vnet.name,
              'AzureFirewallSubnet'
            )
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]

    networkRuleCollections: [
      {
        name: 'allow-internal-traffic'
        properties: {
          priority: 100
          action: {
            type: 'Allow'
          }
          rules: [
            {
              name: 'allow-all-internal'
              protocols: [
                'Any'
              ]
              sourceAddresses: [
                '10.0.0.0/8'
              ]
              destinationAddresses: [
                '10.0.0.0/8'
              ]
              destinationPorts: [
                '*'
              ]
            }
          ]
        }
      }
    ]
  }
}

//
// ========================================
// OUTPUT
// ========================================
//

output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
