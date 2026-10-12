// ========================================
// MODULE PURPOSE
// Deploys Azure Bastion and its Public IP.
// Assumes AzureBastionSubnet already exists.
// ========================================

// ========================================
// INPUTS
// ========================================

param location string
param bastionName string
param vnetName string
param publicIpName string

// ========================================
// RESOURCE CREATED: PUBLIC IP
// ========================================

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

// ========================================
// EXISTING DEPENDENCIES
// ========================================

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: vnet
  name: 'AzureBastionSubnet'
}

// ========================================
// RESOURCE CREATED: BASTION HOST
// ========================================

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: bastionName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ipconfig'
        properties: {
          subnet: {
            id: bastionSubnet.id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// ========================================
// OUTPUTS
// ========================================

output bastionId string = bastion.id
