targetScope = 'subscription'
@description('Prefix for all resources')
param prefix string
param tags object


param jumpboxAdminUsername string
@secure()
param jumpboxAdminPassword string
param serverAdminUsername string
@secure()
param serverAdminPassword string
param clientAdminUsername string
@secure()
param clientAdminPassword string

param vmSize string
param osDisk object

param jumpboxAllowedSources array
param enableClientSsh bool

param regions object
param dc01RegionKey string
param dc02RegionKey string
param dc03RegionKey string
param dc04RegionKey string
param dc05RegionKey string
param windowsClient01RegionKey string
param windowsClient02RegionKey string
param ubuntu01RegionKey string
param ubuntu02RegionKey string
param jumpboxRegionKey string

param windowsServerImage object
param windowsClientImage object
param ubuntuImage object

param dcIps object

var finalTags = union(tags, {
  project: prefix
})

var regionKeys = [for r in items(regions): r.key]

var dcRegionKeys = [
  dc01RegionKey
  dc02RegionKey
  dc03RegionKey
  dc04RegionKey
  dc05RegionKey
]

var dcIpArray = [
  dcIps.dc01
  dcIps.dc02
  dcIps.dc03
  dcIps.dc04
  dcIps.dc05
]

var dnsServers = dcIpArray

var jumpboxSubnets = [
  for r in items(regions): r.value.subnetPrefix.jumpbox
]

//
// RESOURCE GROUPS
//

resource rgs 'Microsoft.Resources/resourceGroups@2022-09-01' = [
  for region in items(regions): {
    name: '${prefix}-rg-${region.key}'
    location: region.value.location
    tags: finalTags
  }
]

//
// VNets
//

module vnets 'modules/networking/vnet.bicep' = [
  for region in items(regions): {
    name: 'vnet-${region.key}'
    scope: resourceGroup('${prefix}-rg-${region.key}')
    dependsOn: [
      rgs
    ]
    params: {
      vnetName: '${prefix}-vnet-${region.key}'
      location: region.value.location
      addressPrefix: region.value.addressPrefix
      subnetPrefix: region.value.subnetPrefix
      dnsServers: dnsServers
      jumpboxSubnets: jumpboxSubnets
      jumpboxAllowedSources: jumpboxAllowedSources
      enableClientSsh: enableClientSsh
      tags: finalTags
    }
  }
]

//
// PEERING (loop)
//

module peerings 'modules/peering/peering.bicep' = [
  for source in regionKeys: {
    name: 'peerings-${source}'
    scope: resourceGroup('${prefix}-rg-${source}')
    dependsOn: vnets
    params: {
      vnetName: '${prefix}-vnet-${source}'
      regionKeys: regionKeys
      sourceRegion: source
      prefix: prefix
    }
  }
]

//
// DOMAIN CONTROLLERS
//

module dcs 'modules/compute/vm-windows.bicep' = [
  for (dcRegionKey, i) in dcRegionKeys: {
    name: 'dc0${i + 1}'
    scope: resourceGroup('${prefix}-rg-${dcRegionKey}')
    params: {
      vmName: '${prefix}-dc0${i + 1}'
      vmSize: vmSize
      adminUsername: serverAdminUsername
      adminPassword: serverAdminPassword
      subnetId: vnets[indexOf(regionKeys, dcRegionKey)].outputs.subnets.dc.id
      privateIp: dcIpArray[i]
      enablePublicIp: false
//      testTargets: dcIpArray
      tags: union(finalTags, {
        role: 'domain-controller'
      })
      image: windowsServerImage
      osDisk: osDisk
    }
  }
]

//
// JUMPBOX
//

module jumpbox 'modules/compute/vm-windows.bicep' = {
  name: 'jumpbox'
  scope: resourceGroup('${prefix}-rg-${jumpboxRegionKey}')
  params: {
    vmName: '${prefix}-jumpbox'
    vmSize: vmSize
    adminUsername: jumpboxAdminUsername
    adminPassword: jumpboxAdminPassword
    subnetId: vnets[indexOf(regionKeys, jumpboxRegionKey)].outputs.subnets.jumpbox.id
    enablePublicIp: true
    tags: union(finalTags, {
      role: 'jumpbox'
    })
    image: windowsServerImage
    osDisk: osDisk
  }
}

//
// WINDOWS CLIENT
//

module win01 'modules/compute/vm-windows.bicep' = {
  name: 'win01'
  scope: resourceGroup('${prefix}-rg-${windowsClient01RegionKey}')
  params: {
    vmName: '${prefix}-win01'
    vmSize: vmSize
    adminUsername: clientAdminUsername
    adminPassword: clientAdminPassword
    subnetId: vnets[indexOf(regionKeys, windowsClient01RegionKey)].outputs.subnets.client.id
    enablePublicIp: false
//      testTargets: []
      tags: union(finalTags, {
        role: 'client'
      })
    image: windowsClientImage     
    osDisk: osDisk                
  }
}

module win02 'modules/compute/vm-windows.bicep' = {
  name: 'win02'
  scope: resourceGroup('${prefix}-rg-${windowsClient02RegionKey}')
  params: {
    vmName: '${prefix}-win02'
    vmSize: vmSize
    adminUsername: clientAdminUsername
    adminPassword: clientAdminPassword
    subnetId: vnets[indexOf(regionKeys, windowsClient02RegionKey)].outputs.subnets.client.id
    enablePublicIp: false
//      testTargets: []
      tags: union(finalTags, {
        role: 'client'
      })
    image: windowsClientImage     
    osDisk: osDisk                
  }
}

//
// LINUX VM
//
module ubu01 'modules/compute/vm-linux.bicep' = {
  name: 'ubu01'
  scope: resourceGroup('${prefix}-rg-${ubuntu01RegionKey}')
  params: {
    vmName: '${prefix}-ubu01'
    vmSize: vmSize
    adminUsername: serverAdminUsername
    adminPassword: serverAdminPassword
    subnetId: vnets[indexOf(regionKeys, ubuntu01RegionKey)].outputs.subnets.server.id
    enablePublicIp: false
         tags: union(finalTags, {
        role: 'server'
      })
    image: ubuntuImage               
    osDisk: osDisk                 
  }
}

module ubu02 'modules/compute/vm-linux.bicep' = {
  name: 'ubu02'
  scope: resourceGroup('${prefix}-rg-${ubuntu02RegionKey}')
  params: {
    vmName: '${prefix}-ubu02'
    vmSize: vmSize
    adminUsername: clientAdminUsername
    adminPassword: clientAdminPassword
    subnetId: vnets[indexOf(regionKeys, ubuntu02RegionKey)].outputs.subnets.client.id
    enablePublicIp: false
      tags: union(finalTags, {
        role: 'client'
      })
    image: ubuntuImage               
    osDisk: osDisk                 
  }
}
