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

param windowsServerImage object
param windowsClientImage object
param ubuntuImage object

param regionIndexMap object
param subnetIndexMap object
param regionPool array
param regionCount int
param maxVmsPerRegion int
param vmCounts object

param jumpboxAllowedSources array
param enableClientSsh bool

param vmSize string
param osDisk object

// VM TYPE ARRAYS //

var jumpboxArray = [
  for i in range(0, vmCounts.jumpbox): {
    type: 'jumpbox'
    index: i
  }
]
var windowsServerArray = [
  for i in range(0, vmCounts.windowsServer): {
    type: 'srvwin'
    index: i
  }
]
var windowsClientArray = [
  for i in range(0, vmCounts.windowsClient): {
    type: 'cliwin'
    index: i
  }
]
var linuxServerArray = [
  for i in range(0, vmCounts.linuxServer): {
    type: 'srvlin'
    index: i
  }
]
var linuxClientArray = [
  for i in range(0, vmCounts.linuxClient): {
    type: 'clilin'
    index: i
  }
]

var vmList = concat(
  jumpboxArray,
  windowsServerArray,
  windowsClientArray,
  linuxServerArray,
  linuxClientArray
)

var regionKeys = selectedRegions

var vmListWithPlacement = [
  for (vm, i) in vmList: {
    type: vm.type
    index: vm.index
    globalIndex: i
    regionIndex: int(i / maxVmsPerRegion)
  }
]

var jumpboxesWithRegion = [
  for (vm, i) in vmListWithPlacement: vm.type == 'jumpbox' ? { type: vm.type, index: vm.index, globalIndex: vm.globalIndex, regionKey: regionKeys[i] } : null
]

var workloadWithRegion = [
  for vm in vmListWithPlacement: vm.type != 'jumpbox' ? { type: vm.type, index: vm.index, globalIndex: vm.globalIndex, regionKey: regionKeys[vm.regionIndex] } : null
]

var finalVmPlacement = concat(jumpboxesWithRegion, workloadWithRegion)

var finalTags = union(tags, {
  project: prefix
})

var selectedRegions = take(regionPool, regionCount)

var dcRegionKeys = regionKeys

var dcIpArray = [
  for (region, i) in regionKeys: replace(subnetPrefixesArray[i].dc, '0/24', '4')
]

var dnsServers = dcIpArray

var jumpboxSubnets = [
  for (region, i) in regionKeys: subnetPrefixesArray[i].jumpbox
]

var safeVmList = [
  for vm in finalVmPlacement: empty(vm) ? {
    type: ''
    index: -1
    regionKey: ''
  } : vm
]

var windowsVMList = [
  for vm in safeVmList: (vm.type == 'jumpbox' || vm.type == 'srvwin' || vm.type == 'cliwin') ? vm : null
]

var linuxVMList = [
  for vm in safeVmList: (vm.type == 'srvlin' || vm.type == 'clilin') ? vm : null
]

var addressPrefixes = [
  for region in regionKeys: '10.${regionIndexMap[region]}.0.0/16'
]

var subnetPrefixesArray = [
  for region in regionKeys: {
    jumpbox: '10.${regionIndexMap[region]}.${subnetIndexMap.jumpbox}.0/24'
    dc:      '10.${regionIndexMap[region]}.${subnetIndexMap.dc}.0/24'
    server:  '10.${regionIndexMap[region]}.${subnetIndexMap.server}.0/24'
    client:  '10.${regionIndexMap[region]}.${subnetIndexMap.client}.0/24'
  }
]

// VALIDATION //

// VALIDATION //

var invalidRegionCount = regionCount > length(regionPool)

var invalidJumpboxCount = vmCounts.jumpbox > regionCount

var totalDCs = length(regionKeys)

var totalVMs = totalDCs + vmCounts.jumpbox + vmCounts.windowsServer + vmCounts.windowsClient + vmCounts.linuxServer + vmCounts.linuxClient

var totalCapacity = regionCount * maxVmsPerRegion

var invalidCapacity = totalVMs > totalCapacity

var hasInvalidRegionIndex = [
  for region in regionKeys: contains(regionIndexMap, region) ? false : true
]

var missingRegionIndex = contains(hasInvalidRegionIndex, true)

var hasInvalidSubnetIndex = !(contains(subnetIndexMap, 'jumpbox') && contains(subnetIndexMap, 'dc') && contains(subnetIndexMap, 'server') && contains(subnetIndexMap, 'client'))

var hasValidationError = invalidRegionCount || invalidJumpboxCount || invalidCapacity || missingRegionIndex || hasInvalidSubnetIndex

resource validation 'Microsoft.Resources/deployments@2021-04-01' = if (hasValidationError) {
  name: 'validationFailure'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: []
      outputs: {
        error: {
          type: 'string'
          value: 'Validation failed: check regionCount, jumpbox count, or capacity limits.'
        }
      }
    }
  }
}

//
// RESOURCE GROUPS
//

resource rgs 'Microsoft.Resources/resourceGroups@2022-09-01' = [
  for region in regionKeys: {
    name: '${prefix}-rg-${region}'
    location: region
    tags: finalTags
  }
]

//
// VNets
//

module vnets 'modules/networking/vnet.bicep' = [
  for (region, i) in regionKeys: {

    name: 'vnet-${region}'

    scope: resourceGroup('${prefix}-rg-${region}')

    dependsOn: [
      rgs
    ]

    params: {
      vnetName: '${prefix}-vnet-${region}'
      location: region

      addressPrefix: addressPrefixes[i]
      subnetPrefix: subnetPrefixesArray[i]

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

module windowsVMs 'modules/compute/vm-windows.bicep' = [
  for vm in windowsVMList: if (vm != null) {
    name: 'win-${vm.type}-${vm.index}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    params: {
      vmName: '${prefix}-${vm.type}${(vm.index + 1) < 10 ? '0${vm.index + 1}' : vm.index + 1}'
      vmSize: vmSize

      adminUsername: vm.type == 'jumpbox' ? jumpboxAdminUsername : vm.type == 'srvwin' ? serverAdminUsername : clientAdminUsername

      adminPassword: vm.type == 'jumpbox' ? jumpboxAdminPassword : vm.type == 'srvwin' ? serverAdminPassword : clientAdminPassword

      subnetId: vm.type == 'jumpbox' ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.jumpbox.id : vm.type == 'srvwin' ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.server.id : vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.client.id

      assignPublicIp: vm.type == 'jumpbox'

      tags: union(finalTags, {
        role: vm.type == 'jumpbox' ? 'jumpbox' : vm.type == 'srvwin' ? 'server' : 'client'
      })

      image: vm.type == 'cliwin' ? windowsClientImage : windowsServerImage
      osDisk: osDisk
    }
  }
]

module linuxVMs 'modules/compute/vm-linux.bicep' = [
  for vm in linuxVMList: if (vm != null) {
    name: 'lin-${vm.type}-${vm.index}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    params: {
      vmName: '${prefix}-${vm.type}${(vm.index + 1) < 10 ? '0${vm.index + 1}' : vm.index + 1}'
      vmSize: vmSize

      adminUsername: vm.type == 'srvlin' ? serverAdminUsername : clientAdminUsername

      adminPublicKey: adminPublicKey

      subnetId: vm.type == 'srvlin' ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.server.id : vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.client.id

      assignPublicIp: false

      tags: union(finalTags, {
        role: vm.type == 'srvlin' ? 'server' : 'client'
      })

      image: ubuntuImage
      osDisk: osDisk
    }
  }
]

// DEBUG OUTPUTS //

output selectedRegionsOutput array = selectedRegions
output totalVmRequested int = totalVMs
output totalCapacityAvailable int = totalCapacity

output finalPlacement array = finalVmPlacement
