targetScope = 'subscription'

// ========================================
// MODULE PURPOSE
// Subscription-scope orchestrator for multi-region networking, security, routing, and VM deployment.
// ========================================

// ========================================
// INPUTS
// ========================================

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
@description('Subnet index used for hub services (only applies to hub VNet)')
param hubSubnetIndex int
@description('Controls whether subnets should be created/modified')
param deploySubnets bool
param subnetIndexMap object
param regionCount int
param maxVmsPerRegion int
param vmCounts object

param jumpboxAllowedSources array
param enableClientSsh bool

param vmSize string
param osDisk object

//
// ========================================
// VM MODEL (builds unified list of all VMs)
// ========================================
//

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

//
// ========================================
// REGION ORDERING (Index-Based Sorting)
// Converts regionIndexMap → ordered region list
// ========================================
//

// Extract regions in order of their index value (1 → N)
var regionPairs = [
  for r in items(regionIndexMap): {
    key: r.key
    index: r.value
  }
]

var sortedRegionPairs = sort(regionPairs, (a, b) => a.index < b.index)

var sortedRegions = [
  for r in sortedRegionPairs: r.key
]

// Select only the required number of regions
var regionKeys = take(sortedRegions, regionCount)

var primaryRegion = regionKeys[0]
var isSingleRegion = regionCount == 1

// Pinned primary-region VMs are excluded from round-robin placement.
var roundRobinVmList = filter(vmList, vm =>
  !(vm.type == 'dc' && vm.index == 0) && !(vm.type == 'jmp' && vm.index == 0)
)

// Compute global index for VMs that are still eligible for round-robin placement.
var roundRobinVmIndexList = [
  for vm in vmList: (vm.type == 'dc' && vm.index == 0) || (vm.type == 'jmp' && vm.index == 0) ? -1 : indexOf(roundRobinVmList, vm)
]

// ========================================
// HUB MODEL
// ========================================

var hubRegion = primaryRegion

//
// ========================================
// PLACEMENT ENGINE
// Assigns each VM to a region using rules
// ========================================
//

var vmPlacements = [
  for (vm, i) in vmList: {
    type: vm.type
    index: vm.index
    dcSlot: 0
    regionKey: isSingleRegion
      ? regionKeys[0]
      // Pin the first DC to the primary region.
      : (vm.type == 'dc' && vm.index == 0)
        ? primaryRegion
        // Pin the first jumpbox to the primary region.
        : (vm.type == 'jmp' && vm.index == 0)
          ? primaryRegion
          // Place all remaining VMs across non-primary regions only.
          : regionKeys[(roundRobinVmIndexList[i] % (regionCount - 1)) + 1]
  }
]

var maxDcPerRegion = maxVmsPerRegion

var totalDcs = vmCounts.dc

var minRegionsNeededForDcs = (totalDcs + maxDcPerRegion - 1) / maxDcPerRegion

var hasTooManyDcs = minRegionsNeededForDcs > regionCount

// ========================================
// VM GROUPING + SUPPORT VARIABLES
// ========================================

var finalTags = union(tags, {
  project: prefix
})

// ========================================
// NETWORK HELPER VARIABLES
// ========================================

var windowsVMList = filter(vmPlacements, vm =>
  vm.type == 'dc' || vm.type == 'jmp' || vm.type == 'srvwin' || vm.type == 'cliwin'
)

var linuxVMList = filter(vmPlacements, vm =>
  vm.type == 'srvlin' || vm.type == 'clilin'
)

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

var nonHubDcCandidates = [
  for region in regionKeys: region != hubRegion && length(filter(vmPlacements, vm => vm.type == 'dc' && vm.regionKey == region)) > 0 ? region : ''
]

var nonHubDcRegions = filter(nonHubDcCandidates, r => !empty(r))

var jumpboxSubnets = [
  for (region, i) in regionKeys: subnetPrefixesArray[i].jumpbox
]

//
// ========================================
// PER-REGION CAPACITY VALIDATION
// ========================================

var vmPerRegionCounts = [
  for region in regionKeys: length(filter(vmPlacements, vm => vm.regionKey == region))
]

var regionOverflowFlags = [
  for count in vmPerRegionCounts: count > maxVmsPerRegion
]

var hasRegionOverflow = contains(regionOverflowFlags, true)

//
// ========================================
// VALIDATION ENGINE
// Ensures configuration is valid BEFORE deployment
// ========================================
//

var invalidMinimums = vmCounts.dc < 1 || vmCounts.jumpbox < 1

var invalidRegionCount = regionCount > length(regionIndexMap)

var invalidJumpboxCount = vmCounts.jumpbox > regionCount

var totalVMs = vmCounts.dc + vmCounts.jumpbox + vmCounts.windowsServer + vmCounts.windowsClient + vmCounts.linuxServer + vmCounts.linuxClient

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

var validationFlags = {
  invalidMinimums: invalidMinimums
  invalidRegionCount: invalidRegionCount
  invalidJumpboxCount: invalidJumpboxCount
  invalidCapacity: invalidCapacity
  missingRegionIndex: missingRegionIndex
  hasInvalidSubnetIndex: hasInvalidSubnetIndex
  invalidIndexSequence: invalidIndexSequence
  hasRegionOverflow: hasRegionOverflow
  hasTooManyDcs: hasTooManyDcs
}

var msg1 = invalidMinimums ? 'At least 1 DC and 1 Jumpbox are required.' : ''
var msg2 = invalidRegionCount ? 'Region count exceeds available regions.' : ''
var msg3 = invalidJumpboxCount ? 'Jumpboxes cannot exceed number of regions.' : ''
var msg4 = missingRegionIndex ? 'One or more regions are missing in regionIndexMap.' : ''
var msg5 = hasInvalidSubnetIndex ? 'Subnet index map must include dc, jumpbox, server, and client.' : ''
var msg6 = hasRegionOverflow ? 'One or more regions exceed the maximum allowed VMs per region.' : ''
var msg7 = invalidCapacity ? 'Too many VMs for the allowed capacity per region.' : ''
var msg8 = invalidIndexSequence ? 'Region index map must have continuous values starting at 1.' : ''
var msg9 = hasTooManyDcs ? 'Too many DCs for the available regions.' : ''

var validationMessage = msg1 != '' ? msg1 : msg2 != '' ? msg2 : msg3 != '' ? msg3 : msg4 != '' ? msg4 : msg5 != '' ? msg5 : msg6 != '' ? msg6 : msg7 != '' ? msg7 : msg8 != '' ? msg8 : msg9 != '' ? msg9 : ''

// ========================================
// DEPLOYMENT STAGE 1: RESOURCE GROUPS
// ========================================

resource rgs 'Microsoft.Resources/resourceGroups@2022-09-01' = [
  for region in regionKeys: {
    name: '${prefix}-rg-${region}'
    location: region
    tags: finalTags
  }
]

// ========================================
// DEPLOYMENT STAGE 2: VNETS + NSGS + SUBNETS
// ========================================

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
      regionIndex: regionIndexMap[region]
      hubSubnetIndex: hubSubnetIndex
      isHub: region == hubRegion

      deploySubnets: deploySubnets

      addressPrefix: addressPrefixes[i]
      subnetPrefix: subnetPrefixesArray[i]

      dnsServers: take(concat(
        // 1. Local DC
        (region != hubRegion && length(filter(vmPlacements, vm => vm.type == 'dc' && vm.regionKey == region)) > 0) ? [
          '10.${regionIndexMap[region]}.${subnetIndexMap.dc}.4'
        ] : [],

        // 2. Hub DC
        [
          '10.${regionIndexMap[hubRegion]}.${subnetIndexMap.dc}.4'
        ],

        // 3. Remote DC fallback
        length(filter(nonHubDcRegions, x => x != region)) > 0 ? [
          '10.${regionIndexMap[filter(nonHubDcRegions, x => x != region)[0]]}.${subnetIndexMap.dc}.4'
        ] : []
      ), 3)
      jumpboxSubnets: jumpboxSubnets
      jumpboxAllowedSources: jumpboxAllowedSources
      enableClientSsh: enableClientSsh
      tags: finalTags
    }
  }
]

// ========================================
// DEPLOYMENT STAGE 3: VNET PEERING
// ========================================

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
      hubRegion: hubRegion
    }
  }
]

// ========================================
// DEPLOYMENT STAGE 4: HUB FIREWALL
// ========================================

module firewall 'modules/networking/firewall.bicep' = {
  name: 'firewall-${hubRegion}'

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

// ========================================
// DEPLOYMENT STAGE 5: ROUTE TABLES (SPOKE REGIONS)
// ========================================

module routeTables 'modules/networking/routeTable.bicep' = [
  for (region, i) in regionKeys: if (region != hubRegion) {
    name: 'rt-${region}'
    scope: resourceGroup('${prefix}-rg-${region}')

    dependsOn: [
      #disable-next-line no-unnecessary-dependson
      firewall
      vnets[i]
    ]

    params: {
      location: region

      serverSubnetId: vnets[i].outputs.subnets.server.id
      clientSubnetId: vnets[i].outputs.subnets.client.id

      serverSubnetPrefix: subnetPrefixesArray[i].server
      clientSubnetPrefix: subnetPrefixesArray[i].client

      serverNsgId: vnets[i].outputs.nsgs.server
      clientNsgId: vnets[i].outputs.nsgs.client

      nextHopIp: firewall.outputs.firewallPrivateIp
    }
  }
]

// ========================================
// DEPLOYMENT STAGE 6: WINDOWS VMS
// ========================================

module windowsVMs 'modules/compute/vm-windows.bicep' = [
  for (vm, i) in windowsVMList: {
    name: '${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      vnets
    ]

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

      subnetId: vm.type == 'dc'
        ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.dc.id
        : vm.type == 'jmp'
          ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.jumpbox.id
          : vm.type == 'srvwin'
            ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.server.id
            : vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.client.id

      assignPublicIp: vm.type == 'jmp'

      tags: union(finalTags, {
        role: vm.type == 'dc'
          ? 'domain-controller'
          : vm.type == 'jmp'
            ? 'jumpbox'
            : vm.type == 'srvwin'
              ? 'server'
              : 'client'
      })

      image: vm.type == 'cliwin'
        ? windowsClientImage
        : windowsServerImage

      osDisk: osDisk
    }
  }
]

// ========================================
// DEPLOYMENT STAGE 7: LINUX VMS
// ========================================

module linuxVMs 'modules/compute/vm-linux.bicep' = [
  for vm in linuxVMList: {
    name: '${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      vnets
    ]

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

// ========================================
// OUTPUTS: PLACEMENT, VALIDATION, CAPACITY, REGIONAL SUMMARY
// ========================================

// List of regions selected for this deployment (ordered by regionIndexMap)// and assigned region
// This is the primary output used to verify distribution logic
output vmPlacement array = vmPlacements

// Validation message describing why deployment failed (empty if no validation errors)

output validationDebug object = validationFlags
output validationMessage string = validationMessage

// Per-region VM count after placement
// Useful for confirming even distribution and ensuring no region exceeds limits
output vmCountPerRegion array = [
  for region in regionKeys: {
    region: region
    count: length(filter(vmPlacements, vm => vm.regionKey == region))
  }
]

// Summary of capacity vs requested VMs
// Helps quickly determine if deployment is within allowed limits
output capacityCheck object = {
  totalVMs: totalVMs
  capacity: totalCapacity
  withinLimit: totalVMs <= totalCapacity
}

output selectedRegionsOutput array = regionKeys

// Total number of VMs requested across all types
output totalVmRequested int = totalVMs

// Maximum number of VMs that can be deployed based on region count and per-region limit
output totalCapacityAvailable int = totalCapacity

output regionSummary array = [
  for (region, i) in regionKeys: {
    region: region
    addressSpace: addressPrefixes[i]
    subnets: subnetPrefixesArray[i]
    vmCount: length(filter(vmPlacements, vm => vm.regionKey == region))
  }
]
