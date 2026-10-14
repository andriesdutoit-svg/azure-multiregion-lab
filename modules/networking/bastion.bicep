// Deploys Azure Bastion and its Public IP.
// The network stage must provision AzureBastionSubnet before calling this module.
// Consumes canonical host/Public IP names and SKU; exposes the host resource ID to its caller.
// Disabling its caller's condition skips deployment, so removal of old Bastion resources needs separate cleanup.

// 1. Resource identities and SKU
param location string
param bastionName string
param vnetName string
param publicIpName string

@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param bastionSku string

// 2. Public IP and existing subnet references

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

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: vnet
  name: 'AzureBastionSubnet'
}

// 3. Bastion host
// The Public IP reference orders creation; retirement is owned by network reconciliation.

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: bastionName
  location: location
  sku: {
    name: bastionSku
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

// 4. Host identity

output bastionId string = bastion.id
