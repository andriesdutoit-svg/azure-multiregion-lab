// Creates or updates a subnet under an existing VNet with explicit security and routing associations.
// The caller supplies the complete intended prefix and association IDs and orders shared-parent writes.
// Returned subnetId supports downstream wiring; changing prefixes or associations is a real network update.

// 1. Parent, address space, and optional associations
param vnetName string
param subnetName string
param addressPrefix string
param nsgId string
param routeTableId string = ''

// 2. Existing parent and subnet update
// This is a full declaration of the managed properties, not an additive association patch.

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' = {
  name: subnetName
  parent: vnet
  properties: {
    addressPrefix: addressPrefix

    privateEndpointNetworkPolicies: 'Disabled'

    // An empty ID declares no NSG, including when updating a previously associated subnet.
    networkSecurityGroup: empty(nsgId) ? null : {
      id: nsgId
    }

    // An empty ID declares no route table; callers must supply associations they intend to retain.
    routeTable: empty(routeTableId) ? null : {
      id: routeTableId
    }
  }
}

// 3. Subnet identity

output subnetId string = subnet.id
