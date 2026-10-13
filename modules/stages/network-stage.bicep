targetScope = 'subscription'

// ========================================
// NETWORK STAGE
//
// Responsibilities:
// - Resource Groups
// - VNets
// - Peerings
// - Azure Firewall
// - Route tables
// - Role subnets and additional policy-neutral subnets
//
// Provides:
// - subnetMap
//
// Consumed by:
// - compute-stage
// ========================================

// Outputs:
//
// subnetMap
//
// Consumed by:
// compute-stage.bicep

param prefix string
param regionKeys array
param hubRegion string

param deployNetwork bool

@description('Network topology mode.')
@allowed([
  'hubSpokeFirewall'
  'hubSpoke'
  'fullMesh'
])
param networkMode string

@description('Resource ID of the User Assigned Managed Identity used by Deployment Scripts.')
param automationManagedIdentityResourceId string

param tags object

param existingRegions array

param enableBastion bool
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param bastionSku string

param addressPrefixes array
param subnetPrefixesArray array

param dnsServers array
param jumpboxSubnets array
param jumpboxAllowedSources array
param additionalSubnetsByRegion array

// Capability helpers
var deployFirewall = contains([
  'hubSpokeFirewall'
], networkMode)

var deployRouteTables = contains([
  'hubSpokeFirewall'
], networkMode)

var deployPeerings = contains([
  'hubSpokeFirewall'
  'hubSpoke'
  'fullMesh'
], networkMode)

// Network reconciliation runs in brownfield deployments when resources outside desired state require removal:
// 1. Candidate spoke-to-spoke peerings when moving to a non-full-mesh topology
// 2. Existing Bastion resources in the hub when enableBastion is false
var requiresPeeringReconciliation = deployNetwork && networkMode != 'fullMesh' && length(existingRegions) > 0
var requiresBastionReconciliation = deployNetwork && !enableBastion && contains(existingRegions, hubRegion)
var requiresNetworkReconciliation = requiresPeeringReconciliation || requiresBastionReconciliation

resource rgs 'Microsoft.Resources/resourceGroups@2022-09-01' = [
  for region in regionKeys: {
    name: '${prefix}-rg-${region}'
    location: region
    tags: union(tags, {
      project: prefix
    })
  }
]

module vnets '../networking/vnet.bicep' = [
  for (region, i) in regionKeys: if (deployNetwork) {

    name: '${prefix}-vnet-${region}'

    scope: resourceGroup('${prefix}-rg-${region}')

    dependsOn: [
      rgs
    ]

    params: {
      vnetName: '${prefix}-vnet-${region}'
      location: region
      isHub: region == hubRegion
      deployAzureFirewallSubnet: deployFirewall
      enableBastion: enableBastion

      existingRegions: existingRegions

      addressPrefix: addressPrefixes[i]
      subnetPrefix: subnetPrefixesArray[i]
      bastionSubnetPrefix: subnetPrefixesArray[i].bastion

      dnsServers: dnsServers
      jumpboxSubnets: jumpboxSubnets
      jumpboxAllowedSources: jumpboxAllowedSources
      tags: union(tags, {
        project: prefix
      })
    }
  }
]

module firewall '../networking/firewall.bicep' = if (deployNetwork && deployFirewall) {
  name: '${prefix}-firewall-${hubRegion}'

  scope: resourceGroup('${prefix}-rg-${hubRegion}')

  dependsOn: [
    rgs
    vnets
  ]

  params: {
    location: hubRegion
    firewallName: '${prefix}-fw-${hubRegion}'
    vnetName: '${prefix}-vnet-${hubRegion}'
    publicIpName: '${prefix}-fw-pip-${hubRegion}'
  }
}

module routeTables '../networking/routeTable.bicep' = [
  for (region, i) in regionKeys: if (deployNetwork && deployRouteTables && region != hubRegion) {

    name: '${prefix}-rt-${region}'
    scope: resourceGroup('${prefix}-rg-${region}')

    dependsOn: [
      #disable-next-line no-unnecessary-dependson
      firewall
      vnets[i]
    ]

    params: {
      location: region

      dcSubnetName: '${prefix}-vnet-${region}-subnet-dc'
      jumpboxSubnetName: '${prefix}-vnet-${region}-subnet-jumpbox'
      serverSubnetName: '${prefix}-vnet-${region}-subnet-server'

      clientSubnetName: '${prefix}-vnet-${region}-subnet-client'

      #disable-next-line BCP318
      nextHopIp: firewall.outputs.firewallPrivateIp
    }
  }
]

module bastion '../networking/bastion.bicep' = if (deployNetwork && enableBastion) {
  name: '${prefix}-bastion-${hubRegion}'

  scope: resourceGroup('${prefix}-rg-${hubRegion}')

  dependsOn: [
    rgs
    vnets
  ]

  params: {
    location: hubRegion
    bastionName: '${prefix}-bas-${hubRegion}'
    vnetName: '${prefix}-vnet-${hubRegion}'
    publicIpName: '${prefix}-bas-pip-${hubRegion}'
    bastionSku: bastionSku
  }
}

module roleSubnets '../networking/roleSubnets.bicep' = [
  for (region, i) in regionKeys: if (deployNetwork && region != hubRegion) {
    name: '${prefix}-role-subnets-${region}'

    scope: resourceGroup('${prefix}-rg-${region}')

    params: {
      #disable-next-line BCP318
      vnetName: vnets[i].outputs.vnetName

      #disable-next-line BCP318
      subnetNames: vnets[i].outputs.subnetNames

      #disable-next-line BCP318
      subnetPrefixes: vnets[i].outputs.subnetPrefixes

      #disable-next-line BCP318
      nsgIds: vnets[i].outputs.nsgIds

      #disable-next-line BCP318
      dcRouteTableId: deployRouteTables ? routeTables[i].outputs.dcRouteTableId : ''
      #disable-next-line BCP318
      jumpboxRouteTableId: deployRouteTables ? routeTables[i].outputs.jumpboxRouteTableId : ''
      #disable-next-line BCP318
      serverRouteTableId: deployRouteTables ? routeTables[i].outputs.serverRouteTableId : ''
      #disable-next-line BCP318
      clientRouteTableId: deployRouteTables ? routeTables[i].outputs.clientRouteTableId : ''
    }
  }
]

module additionalSubnets '../networking/additionalSubnets.bicep' = [
  for (region, i) in regionKeys: if (deployNetwork && !empty(additionalSubnetsByRegion[i])) {
    name: '${prefix}-additional-subnets-${region}'
    scope: resourceGroup('${prefix}-rg-${region}')
    dependsOn: [
      vnets
      roleSubnets
    ]
    params: {
      #disable-next-line BCP318
      vnetName: vnets[i].outputs.vnetName
      subnets: additionalSubnetsByRegion[i]
    }
  }
]

module peerings '../networking/peering.bicep' = [
  for source in regionKeys: if (deployNetwork && deployPeerings) {
    name: '${prefix}-peerings-${source}'
    scope: resourceGroup('${prefix}-rg-${source}')
    dependsOn: [
      vnets
      roleSubnets
      additionalSubnets
    ]
    params: {
      vnetName: '${prefix}-vnet-${source}'
      regionKeys: regionKeys
      sourceRegion: source
      prefix: prefix
      hubRegion: hubRegion
      networkMode: networkMode
    }
  }
]

// Reconciles network resources (obsolete spoke-to-spoke peerings and disabled Bastion components) in brownfield deployments.
module networkReconciliation '../networking/network-reconciliation.bicep' = if (requiresNetworkReconciliation) {
  name: '${prefix}-network-reconciliation'
  scope: resourceGroup('${prefix}-rg-${hubRegion}')

  params: {
    prefix: prefix
    hubRegion: hubRegion
    existingRegions: existingRegions
    networkMode: networkMode
    automationManagedIdentityResourceId: automationManagedIdentityResourceId
    enableBastion: enableBastion
  }
}

// ========================================
// NETWORK STAGE OUTPUT CONTRACT
// ========================================
//
// Output contract consumed by compute-stage
//


output subnetMap array = [
  for (region, i) in regionKeys: {
    regionKey: region

    subnets: {
      dc: {
        #disable-next-line BCP318
        id: vnets[i].outputs.subnets.dc.id
      }

      jumpbox: {
        #disable-next-line BCP318
        id: vnets[i].outputs.subnets.jumpbox.id
      }

      server: {
        #disable-next-line BCP318
        id: vnets[i].outputs.subnets.server.id
      }

      client: {
        #disable-next-line BCP318
        id: vnets[i].outputs.subnets.client.id
      }
    }
  }
]
