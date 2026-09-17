targetScope = 'resourceGroup'

// ========================================
// MODULE PURPOSE
// Creates hub-to-spoke and spoke-to-hub peering.
// Does not create full-mesh peering between spokes.
// ========================================

// ========================================
// INPUTS
// VNet name, deployment region set, source region, and naming prefix.
// ========================================

param vnetName string
param regionKeys array
param sourceRegion string
param prefix string
param hubRegion string
param networkMode string

var useHubSpokePeering = contains([
  'hubSpokeFirewall'
  'hubSpoke'
], networkMode)

var useFullMeshPeering = networkMode == 'fullMesh'

// ========================================
// EXISTING DEPENDENCY: LOCAL VNET
// ========================================

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

// ========================================
// PEERING RULE
// Hub peers with every spoke. Each spoke peers only with the hub. No spoke-to-spoke peering.
// This enforces hub-centric traffic routing: spoke-to-spoke traffic must traverse hub firewall.
// ========================================

resource peerings 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2022-07-01' = [
  for target in regionKeys: if (useHubSpokePeering && sourceRegion == hubRegion && target != hubRegion || useHubSpokePeering && sourceRegion != hubRegion && target == hubRegion || useFullMeshPeering && sourceRegion != target) {
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
