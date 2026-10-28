targetScope = 'subscription'

// Network stage overview
// Responsibilities:
// - Declare regional resource groups and create/reuse VNets with managed role NSGs and subnets.
// - Provision topology-specific firewall, route tables, peerings, and optional hub Bastion.
// - Run bounded cleanup of candidate spoke peerings and disabled framework-owned Bastion resources.
// Consumes:
// - The root's ordered region model, declared existing network inventory, and addressing/policy inputs.
// - Stage activation, topology/access settings, and the cleanup managed identity.
// Provides:
// - subnetMap with dc/jumpbox/server/client IDs per region for compute-stage.
// Boundaries:
// - Resource groups are declared on every invocation; network modules require deployNetwork.
// - VM placement stays in main.bicep; this stage neither discovers arbitrary resources
//   nor changes Public IPs on retained jumpboxes.

// 1. Parameters
// Resource metadata and stage activation
param prefix string
param tags object
param deployNetwork bool

// Desired regions and declared existing network inventory
param regionKeys array
param hubRegion string
param existingRegions array

// Topology, administrator ingress, and cleanup identity
@description('Network topology mode.')
@allowed([
  'hubSpokeFirewall'
  'hubSpoke'
  'fullMesh'
])
param networkMode string

param enableBastion bool
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param bastionSku string

@description('Resource ID of the User Assigned Managed Identity used by Deployment Scripts.')
param automationManagedIdentityResourceId string

// Addressing and subnet policy inputs aligned by regionKeys index
param addressPrefixes array
param subnetPrefixesArray array
param additionalSubnetsByRegion array

param dnsServers array
param jumpboxSubnets array
param jumpboxAllowedSources array

// 2. Topology capabilities and reconciliation gate
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
// 2. Framework-owned Bastion resources when disabled and the hub is in existingRegions
// Script creation requires authorized identity access even if no obsolete resource is found.
var requiresPeeringReconciliation = deployNetwork && networkMode != 'fullMesh' && length(existingRegions) > 0
var requiresBastionReconciliation = deployNetwork && !enableBastion && contains(existingRegions, hubRegion)
var requiresNetworkReconciliation = requiresPeeringReconciliation || requiresBastionReconciliation

// 3. Regional resource groups and VNet assembly
// Resource groups are declared for every stage; networking modules are gated by deployNetwork.
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
      tags: union(tags, {
        project: prefix
      })

      isHub: region == hubRegion
      existingRegions: existingRegions
      deployAzureFirewallSubnet: deployFirewall
      enableBastion: enableBastion

      addressPrefix: addressPrefixes[i]
      subnetPrefix: subnetPrefixesArray[i]
      bastionSubnetPrefix: subnetPrefixesArray[i].bastion

      dnsServers: dnsServers
      jumpboxSubnets: jumpboxSubnets
      jumpboxAllowedSources: jumpboxAllowedSources
    }
  }
]

// 4. Optional hub infrastructure and spoke routing
// Explicit dependencies preserve hub-subnet readiness and the firewall next-hop contract.
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

// 5. Standard and additional subnet updates
// Module-output references order spoke policy associations after VNet/NSG and route-table provisioning.
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

// 6. Desired peerings and bounded cleanup
// Creation and cleanup are separate operations, not full topology discovery or retirement.
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
      prefix: prefix
      vnetName: '${prefix}-vnet-${source}'
      regionKeys: regionKeys
      sourceRegion: source
      hubRegion: hubRegion
      networkMode: networkMode
    }
  }
]

// Reconciles network resources (obsolete spoke-to-spoke peerings and disabled Bastion components) in brownfield deployments.
module networkReconciliation '../networking/network-reconciliation.bicep' = if (requiresNetworkReconciliation) {
  name: '${prefix}-network-reconciliation'
  scope: resourceGroup('${prefix}-rg-${hubRegion}')

  // Bastion cleanup writes a whole-VNet snapshot; wait for desired subnet and topology writes.
  dependsOn: [
    peerings
    firewall
    bastion
  ]

  params: {
    prefix: prefix
    hubRegion: hubRegion
    existingRegions: existingRegions
    networkMode: networkMode
    enableBastion: enableBastion
    automationManagedIdentityResourceId: automationManagedIdentityResourceId
  }
}

// 7. Compute subnet contract
// Preserve region order and the dc/jumpbox/server/client ID shape expected by compute.
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
