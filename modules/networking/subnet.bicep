// ========================================
// MODULE PURPOSE
// Creates a subnet in an existing VNet, with optional NSG association.
// ========================================

// ========================================
// INPUTS
// ========================================

param vnetName string
param subnetName string
param addressPrefix string
param nsgId string

// ========================================
// EXISTING DEPENDENCY: PARENT VNET
// ========================================

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

// ========================================
// RESOURCE CREATED: SUBNET
// ========================================

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' = {
  name: subnetName
  parent: vnet
  properties: {
    addressPrefix: addressPrefix
    // Optional NSG binding: if nsgId is empty, subnet is created without NSG.
    networkSecurityGroup: empty(nsgId) ? null : {
      id: nsgId
    }
  }
}

// ========================================
// OUTPUTS
// ========================================

output subnetId string = subnet.id
