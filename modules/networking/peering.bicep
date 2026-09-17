targetScope = 'resourceGroup'

// ========================================
// MODULE PURPOSE
// Creates VNet peerings according to networkMode.
// Supported:
// - hubSpokeFirewall
// - hubSpoke
// - fullMesh
// Hub-spoke modes create hub-to-spoke peerings only.
// Full mesh mode creates peerings between all regions.
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
// Hub-spoke modes create hub-to-spoke and spoke-to-hub peerings only.
// In hubSpokeFirewall mode, cross-spoke traffic is routed through the hub firewall.
// In hubSpoke mode, spokes remain connected through the hub without firewall routing.
// fullMesh mode creates peerings between every pair of distinct regions.
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
