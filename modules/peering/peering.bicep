targetScope = 'resourceGroup'

param vnetName string
param regionKeys array
param sourceRegion string
param prefix string
param hubRegion string

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

resource peerings 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2022-07-01' = [
  for target in regionKeys: if (sourceRegion == hubRegion && target != hubRegion || sourceRegion != hubRegion && target == hubRegion) {
    name: '${vnet.name}-to-${prefix}-vnet-${target}'
    parent: vnet
    properties: {
      remoteVirtualNetwork: {
        id: resourceId(
          '${prefix}-rg-${target}',
          'Microsoft.Network/virtualNetworks',
          '${prefix}-vnet-${target}'
        )
      }
      allowVirtualNetworkAccess: true
      allowForwardedTraffic: true
      allowGatewayTransit: false
      useRemoteGateways: false
    }
  }
]
