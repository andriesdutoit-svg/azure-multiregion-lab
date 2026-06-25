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

param adminPublicKey string

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
param jumpbox01RegionKey string
param serverWindows01RegionKey string
param clientWindows01RegionKey string
param serverLinux01RegionKey string
param clientLinux01RegionKey string

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
    name: 'dc${(i + 1) < 10 ? '0${i + 1}' : i + 1}'
    scope: resourceGroup('${prefix}-rg-${dcRegionKey}')
    params: {
      vmName: '${prefix}-dc${(i + 1) < 10 ? '0${i + 1}' : i + 1}'
      vmSize: vmSize
      adminUsername: serverAdminUsername
      adminPassword: serverAdminPassword
      subnetId: vnets[indexOf(regionKeys, dcRegionKey)].outputs.subnets.dc.id
      privateIp: dcIpArray[i]
      assignPublicIp: false
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
  scope: resourceGroup('${prefix}-rg-${jumpbox01RegionKey}')
  params: {
    vmName: '${prefix}-jmp01'
    vmSize: vmSize
    adminUsername: jumpboxAdminUsername
    adminPassword: jumpboxAdminPassword
    subnetId: vnets[indexOf(regionKeys, jumpbox01RegionKey)].outputs.subnets.jumpbox.id
    assignPublicIp: true
    tags: union(finalTags, {
      role: 'jumpbox'
    })
    image: windowsServerImage
    osDisk: osDisk
  }
}

//
// WINDOWS SERVER
//

module srvwin01 'modules/compute/vm-windows.bicep' = {
  name: 'srvwin01'
  scope: resourceGroup('${prefix}-rg-${serverWindows01RegionKey}')
  params: {
    vmName: '${prefix}-srvwin01'
    vmSize: vmSize
    adminUsername: serverAdminUsername
    adminPassword: serverAdminPassword
    subnetId: vnets[indexOf(regionKeys, serverWindows01RegionKey)].outputs.subnets.server.id
    assignPublicIp: false
      tags: union(finalTags, {
        role: 'server'
      })
    image: windowsServerImage     
    osDisk: osDisk                
  }
}

//
// WINDOWS CLIENT
//

module cliwin01 'modules/compute/vm-windows.bicep' = {
  name: 'cliwin01'
  scope: resourceGroup('${prefix}-rg-${clientWindows01RegionKey}')
  params: {
    vmName: '${prefix}-cliwin01'
    vmSize: vmSize
    adminUsername: clientAdminUsername
    adminPassword: clientAdminPassword
    subnetId: vnets[indexOf(regionKeys, clientWindows01RegionKey)].outputs.subnets.client.id
    assignPublicIp: false
      tags: union(finalTags, {
        role: 'client'
      })
    image: windowsClientImage     
    osDisk: osDisk                
  }
}

//
// LINUX SERVER VM
//

module srvlin01 'modules/compute/vm-linux.bicep' = {
  name: 'srvlin01'
  scope: resourceGroup('${prefix}-rg-${serverLinux01RegionKey}')
  params: {
    vmName: '${prefix}-srvlin01'
    vmSize: vmSize
    adminUsername: serverAdminUsername
    adminPublicKey: adminPublicKey
    subnetId: vnets[indexOf(regionKeys, serverLinux01RegionKey)].outputs.subnets.server.id
    assignPublicIp: false
         tags: union(finalTags, {
        role: 'server'
      })
    image: ubuntuImage               
    osDisk: osDisk                 
  }
}

//
// LINUX SERVER VM
//

module clilin01 'modules/compute/vm-linux.bicep' = {
  name: 'clilin01'
  scope: resourceGroup('${prefix}-rg-${clientLinux01RegionKey}')
  params: {
    vmName: '${prefix}-clilin01'
    vmSize: vmSize
    adminUsername: clientAdminUsername
    adminPublicKey: adminPublicKey
    subnetId: vnets[indexOf(regionKeys, clientLinux01RegionKey)].outputs.subnets.client.id
    assignPublicIp: false
      tags: union(finalTags, {
        role: 'client'
      })
    image: ubuntuImage               
    osDisk: osDisk                 
  }
}
