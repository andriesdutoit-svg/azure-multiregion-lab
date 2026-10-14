targetScope = 'resourceGroup'

// Creates the source VNet's outgoing peerings for the declared topology.
// The network stage calls this per region to supply both directions of each connection.

// 1. Naming, source VNet, and desired topology
param prefix string
param vnetName string
param sourceRegion string
param regionKeys array
param hubRegion string
param networkMode string

// 2. Desired target selection
// Empty markers retain input indexing and are skipped by the resource loop.
var useHubSpokePeering = contains([
  'hubSpokeFirewall'
  'hubSpoke'
], networkMode)

var useFullMeshPeering = networkMode == 'fullMesh'

var desiredPeeringTargets = [
  for target in regionKeys: (useHubSpokePeering && sourceRegion == hubRegion && target != hubRegion) || useHubSpokePeering && sourceRegion != hubRegion && target == hubRegion || useFullMeshPeering && sourceRegion != target ? target : ''
]

// 3. Existing source and desired peerings

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

// Hub-spoke modes create hub-to-spoke and spoke-to-hub peerings only.
// In hubSpokeFirewall mode, cross-spoke traffic is routed through the hub firewall.
// In hubSpoke mode, only hub-to-spoke traffic is available; VNet peering is non-transitive.
// fullMesh mode creates peerings between every pair of distinct regions.
// Removing a target from this loop does not delete its existing peering; cleanup is separate.

resource peerings 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2022-07-01' = [
  for target in desiredPeeringTargets: if (!empty(target)) {
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
