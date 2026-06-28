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
param regionCount int
param maxVmsPerRegion int
param vmCounts object

param jumpboxAllowedSources array
param enableClientSsh bool

param vmSize string
param osDisk object

// VM TYPE ARRAYS //

var dcArray = [
  for i in range(0, vmCounts.dc): {
    type: 'dc'
    index: i
  }
]
var jumpboxArray = [
  for i in range(0, vmCounts.jumpbox): {
    type: 'jmp'
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
  dcArray,
  jumpboxArray,
  windowsServerArray,
  windowsClientArray,
  linuxServerArray,
  linuxClientArray
)

// Build region items once (clean + efficient)
var regionItems = items(regionIndexMap)

// Build ordered region list safely
var sortedRegions = [
  for i in range(1, length(regionItems) + 1): length(filter(regionItems, r => r.value == i)) == 1 ? first(filter(regionItems, r => r.value == i)).key : ''
]

// Remove invalid entries (empty strings)
var cleanedRegions = [
  for r in sortedRegions: r != '' ? r : null
]

// Take only the required number of regions
var regionKeys = take(cleanedRegions, regionCount)

var primaryRegion = regionKeys[0]
var isSingleRegion = regionCount == 1

var vmListWithPlacement = [
  for (vm, i) in vmList: {
    type: vm.type
    index: vm.index
    regionKey: isSingleRegion ? regionKeys[0] : (vm.type == 'dc' && vm.index == 0) ? primaryRegion : (vm.type == 'jmp' && vm.index == 0) ? primaryRegion : vm.type == 'dc' ? regionKeys[vm.index % regionCount] : vm.type == 'jmp' ? regionKeys[vm.index % regionCount] : (vm.type == 'srvwin' || vm.type == 'srvlin') ? regionKeys[vm.index % regionCount] : regionKeys[i % regionCount]
  }
]

var vmPerRegionCounts = [
  for region in regionKeys: length(filter(vmListWithPlacement, vm => vm.regionKey == region))
]

var regionOverflowFlags = [
  for count in vmPerRegionCounts: count > maxVmsPerRegion
]

var hasRegionOverflow = contains(regionOverflowFlags, true)

var jumpboxesWithRegion = [
  for vm in vmListWithPlacement: vm.type == 'jmp'
    ? { type: vm.type, index: vm.index, globalIndex: vm.index, regionKey: vm.regionKey }
    : null
]

var workloadWithRegion = [for vm in vmListWithPlacement: vm.type != 'jmp' ? { type: vm.type, index: vm.index, globalIndex: vm.index, regionKey: vm.regionKey } : null]

var finalVmPlacement = concat(jumpboxesWithRegion, workloadWithRegion)

var finalTags = union(tags, {
  project: prefix
})

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
  for vm in safeVmList: (vm.type == 'dc' || vm.type == 'jmp' || vm.type == 'srvwin' || vm.type == 'cliwin') ? vm : null
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

var invalidMinimums = vmCounts.dc < 1 || vmCounts.jumpbox < 1

var invalidRegionCount = regionCount > length(regionIndexMap)

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

var hasMissingIndexes = [
  for i in range(1, length(regionIndexMap) + 1): empty(filter(items(regionIndexMap), r => r.value == i))
]

var invalidIndexSequence = contains(hasMissingIndexes, true)

var hasValidationError = invalidRegionCount || invalidJumpboxCount || invalidCapacity || missingRegionIndex || hasInvalidSubnetIndex || invalidMinimums || invalidIndexSequence || hasRegionOverflow
var validationMessage = invalidMinimums ? 'At least 1 DC and 1 Jumpbox are required.' : invalidRegionCount ? 'Region count exceeds available regions.' : invalidJumpboxCount ? 'Jumpboxes cannot exceed number of regions.' : missingRegionIndex ? 'One or more regions are missing in regionIndexMap.' : hasInvalidSubnetIndex ? 'Subnet index map must include dc, jumpbox, server, and client.' : hasRegionOverflow ? 'One or more regions exceed the maximum allowed VMs per region.' : invalidCapacity ? 'Too many VMs for the allowed capacity per region.' : invalidIndexSequence ? 'Region index map must have continuous values starting at 1.' : ''

resource validationFailure 'Microsoft.Resources/deployments@2021-04-01' = if (hasValidationError) {
  name: 'validationFailure'
  location: deployment().location

  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: []
      outputs: {
        error: {
          type: 'string'
          value: json(validationMessage != '' ? validationMessage : 'Validation failed')
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

module windowsVMs 'modules/compute/vm-windows.bicep' = [
  for vm in windowsVMList: if (vm != null) {
    name: '${vm.type}-${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    params: {
      vmName: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'
      vmSize: vmSize

      adminUsername: vm.type == 'jmp'
        ? jumpboxAdminUsername
        : (vm.type == 'dc' || vm.type == 'srvwin'
          ? serverAdminUsername
          : clientAdminUsername)

      adminPassword: vm.type == 'jmp'
        ? jumpboxAdminPassword
        : (vm.type == 'dc' || vm.type == 'srvwin'
          ? serverAdminPassword
          : clientAdminPassword)

      subnetId: vm.type == 'dc' ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.dc.id : vm.type == 'jmp' ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.jumpbox.id : vm.type == 'srvwin' ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.server.id : vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.client.id

      assignPublicIp: vm.type == 'jmp'

      tags: union(finalTags, {
        role:   vm.type == 'dc' ? 'domain-controller' : vm.type == 'jmp' ? 'jumpbox' : vm.type == 'srvwin' ? 'server' : 'client'
      })

      image: vm.type == 'cliwin' ? windowsClientImage : windowsServerImage
      osDisk: osDisk
    }
  }
]

module linuxVMs 'modules/compute/vm-linux.bicep' = [
  for vm in linuxVMList: if (vm != null) {
    name: '${vm.type}-${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    params: {
      vmName: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'
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

output selectedRegionsOutput array = regionKeys
output totalVmRequested int = totalVMs
output totalCapacityAvailable int = totalCapacity

output finalPlacement array = finalVmPlacement
