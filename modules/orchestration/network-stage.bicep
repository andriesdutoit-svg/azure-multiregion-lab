targetScope = 'subscription'

// NOTE:
// Stage module under construction.
// Not yet wired into deployment execution.
// Networking resources remain in main.bicep until
// compute-stage dependencies are refactored.

// ========================================
// NETWORK STAGE ORCHESTRATION
// Resource Groups
// VNets
// Peerings
// Firewall
// Route Tables
// Workload Subnets
// ========================================

param prefix string
param regionKeys array
param hubRegion string

param deployNetwork bool

param tags object

param existingRegions array

param addressPrefixes array
param subnetPrefixesArray array

param dnsServers array
param jumpboxSubnets array
param jumpboxAllowedSources array

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

      existingRegions: existingRegions

      addressPrefix: addressPrefixes[i]
      subnetPrefix: subnetPrefixesArray[i]

      dnsServers: dnsServers
      jumpboxSubnets: jumpboxSubnets
      jumpboxAllowedSources: jumpboxAllowedSources
      tags: union(tags, {
        project: prefix
      })
    }
  }
]

module peerings '../networking/peering.bicep' = [
  for source in regionKeys: if (deployNetwork) {
    name: '${prefix}-peerings-${source}'
    scope: resourceGroup('${prefix}-rg-${source}')
    dependsOn: vnets
    params: {
      vnetName: '${prefix}-vnet-${source}'
      regionKeys: regionKeys
      sourceRegion: source
      prefix: prefix
      hubRegion: hubRegion
    }
  }
]

module firewall '../networking/firewall.bicep' = if (deployNetwork) {
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
  for (region, i) in regionKeys: if (deployNetwork && region != hubRegion) {

    name: '${prefix}-rt-${region}'
    scope: resourceGroup('${prefix}-rg-${region}')

    dependsOn: [
      #disable-next-line no-unnecessary-dependson
      firewall
      vnets[i]
    ]

    params: {
      location: region

      serverSubnetName: '${prefix}-vnet-${region}-subnet-server'

      clientSubnetName: '${prefix}-vnet-${region}-subnet-client'

      #disable-next-line BCP318
      nextHopIp: firewall.outputs.firewallPrivateIp
    }
  }
]

module workloadSubnets '../networking/workloadSubnets.bicep' = [
  for (region, i) in regionKeys: if (deployNetwork && region != hubRegion) {
    name: '${prefix}-workload-subnets-${region}'

    scope: resourceGroup('${prefix}-rg-${region}')

    dependsOn: [
      routeTables[i]
    ]

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
      serverRouteTableId: routeTables[i].outputs.serverRouteTableId
      #disable-next-line BCP318
      clientRouteTableId: routeTables[i].outputs.clientRouteTableId
    }
  }
]

output resourceGroupNames array = [
  for region in regionKeys: '${prefix}-rg-${region}'
]
