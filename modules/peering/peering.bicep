targetScope = 'resourceGroup'

param vnetName string
param remoteVnetName string
param remoteVnetId string

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2022-07-01' = {
  parent: vnet
  name: '${vnet.name}-to-${remoteVnetName}'

  properties: {
    remoteVirtualNetwork: {
      id: remoteVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}
