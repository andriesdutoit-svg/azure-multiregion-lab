// Controls when resources deploy.
@allowed([
  'network'
  'control'
  'workload'
  'all'
])
param stage string = 'all'

// Stage flags for conditional deployment of modules
var deployNetwork = stage == 'network' || stage == 'all'
var deployControl = stage == 'control' || stage == 'all'
var deployWorkload = stage == 'workload' || stage == 'all'



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

var subnetResourceIds = [
  for region in regionKeys: {
    dc: resourceId(
      subscription().subscriptionId,
      '${prefix}-rg-${region}',
      'Microsoft.Network/virtualNetworks/subnets',
      '${prefix}-vnet-${region}',
      'dc'
    )
    jumpbox: resourceId(
      subscription().subscriptionId,
      '${prefix}-rg-${region}',
      'Microsoft.Network/virtualNetworks/subnets',
      '${prefix}-vnet-${region}',
      'jumpbox'
    )
    server: resourceId(
      subscription().subscriptionId,
      '${prefix}-rg-${region}',
      'Microsoft.Network/virtualNetworks/subnets',
      '${prefix}-vnet-${region}',
      'server'
    )
    client: resourceId(
      subscription().subscriptionId,
      '${prefix}-rg-${region}',
      'Microsoft.Network/virtualNetworks/subnets',
      '${prefix}-vnet-${region}',
      'client'
    )
  }
]

var nsgResourceIds = [
  for region in regionKeys: {
    server: resourceId(
      subscription().subscriptionId,
      '${prefix}-rg-${region}',
      'Microsoft.Network/networkSecurityGroups',
      '${prefix}-nsg-server-${region}'
    )
    client: resourceId(
      subscription().subscriptionId,
      '${prefix}-rg-${region}',
      'Microsoft.Network/networkSecurityGroups',
      '${prefix}-nsg-client-${region}'
    )
  }
]

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
// This allows regionIndexMap to define more regions than are active in a given run.
var regionKeys = take(sortedRegions, regionCount)

var primaryRegion = regionKeys[0]
var isSingleRegion = regionCount == 1

// Pinned primary-region VMs are excluded from round-robin placement.
var roundRobinVmList = filter(vmList, vm =>
  !(vm.type == 'dc' && vm.index == 0) && !(vm.type == 'jmp' && vm.index == 0)
)

// Compute global index for VMs that are still eligible for round-robin placement.
// -1 marks pinned VMs so they are never used in modulo placement math.
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

      // Branch order is intentional:
      // single-region override -> pinned hub control-plane -> spoke-only workloads -> spoke-first DC/JMP -> hub-eligible fallback.

      // Always pin first DC and jumpbox
      : (vm.type == 'dc' && vm.index == 0)
        ? primaryRegion

      : (vm.type == 'jmp' && vm.index == 0)
        ? primaryRegion

      // Workloads NEVER go to hub
      : !(vm.type == 'dc' || vm.type == 'jmp')
        ? regionKeys[(roundRobinVmIndexList[i] % (regionCount - 1)) + 1]

      // DC/JMP prefer spokes first
      : vm.index < (regionCount - 1)
        ? regionKeys[(roundRobinVmIndexList[i] % (regionCount - 1)) + 1]

      // After spokes are “likely filled” → allow hub
      : regionKeys[roundRobinVmIndexList[i] % regionCount]
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

// Collect the region key for each DC placement entry.
// Non-DC VMs emit an empty marker that gets removed later.
var dcPlacements = [
  for vm in vmPlacements: vm.type == 'dc' ? vm.regionKey : ''
]

// Remove empty markers and de-duplicate region keys.
var dcRegions = filter(union(dcPlacements, []), region => !empty(region))

// Keep hub DC first, then append remaining DC regions.
// This preserves deterministic DNS ordering for all VNets.
var orderedDcRegions = concat(
  contains(dcRegions, primaryRegion) ? [primaryRegion] : [],
  filter(dcRegions, r => r != primaryRegion)
)

// Build candidate DNS server IPs from the DC subnet (.4) in each ordered DC region.
// This derives DNS from where DCs are actually placed, rather than from static region assumptions.
var dnsCandidates = [
  for region in orderedDcRegions: '10.${regionIndexMap[region]}.${subnetIndexMap.dc}.4'
]

// Each VNet supports up to 3 custom DNS servers.
var dnsServers = take(dnsCandidates, 3)

var jumpboxSubnets = [
  for (region, i) in regionKeys: subnetPrefixesArray[i].jumpbox
]

//
// ========================================
// VALIDATION ENGINE
// Delegated to modules/logic/validation.bicep
// ========================================

module validationEngine 'modules/logic/validation.bicep' = {
  name: 'validation-engine'
  params: {
    vmCounts: vmCounts
    regionCount: regionCount
    regionIndexMap: regionIndexMap
    subnetIndexMap: subnetIndexMap
    vmPlacements: vmPlacements
    regionKeys: regionKeys
    maxVmsPerRegion: maxVmsPerRegion
    primaryRegion: primaryRegion
    hubRegion: hubRegion
    hasTooManyDcs: hasTooManyDcs
  }
}

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
  for (region, i) in regionKeys: if (deployNetwork) {

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

      dnsServers: dnsServers
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
  for source in regionKeys: if (deployNetwork) {
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

module firewall 'modules/networking/firewall.bicep' = if (deployNetwork) {
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
  for (region, i) in regionKeys: if (deployNetwork && region != hubRegion) {
    name: 'rt-${region}'
    scope: resourceGroup('${prefix}-rg-${region}')

    dependsOn: [
      #disable-next-line no-unnecessary-dependson
      firewall
      vnets[i]
    ]

    params: {
      location: region

      serverSubnetId: subnetResourceIds[i].server
      clientSubnetId: subnetResourceIds[i].client
  
      serverSubnetPrefix: subnetPrefixesArray[i].server
      clientSubnetPrefix: subnetPrefixesArray[i].client

      serverNsgId: nsgResourceIds[i].server
      clientNsgId: nsgResourceIds[i].client

      nextHopIp: firewall.outputs.firewallPrivateIp
    }
  }
]

// ========================================
// DEPLOYMENT STAGE 6: WINDOWS VMS
// ========================================

// Compute waits for routeTables so spoke subnet route associations are applied before VM provisioning starts.

// ------------------------------
// Stage-based filtering
// ------------------------------

var controlWindowsVMs = filter(windowsVMList, vm =>
  vm.type == 'dc' || vm.type == 'jmp'
)

var workloadWindowsVMs = filter(windowsVMList, vm =>
  vm.type == 'srvwin' || vm.type == 'cliwin'
)

var activeWindowsVMs = concat(
  deployControl ? controlWindowsVMs : [],
  deployWorkload ? workloadWindowsVMs : []
)

// ------------------------------
// Windows VM Module Deployment
// ------------------------------

module windowsVMs 'modules/compute/vm-windows.bicep' = [
  for (vm, i) in activeWindowsVMs: {
    name: '${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      vnets
      routeTables
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
        ? subnetResourceIds[indexOf(regionKeys, vm.regionKey)].dc
        : vm.type == 'jmp'
          ? subnetResourceIds[indexOf(regionKeys, vm.regionKey)].jumpbox
          : vm.type == 'srvwin'
            ? subnetResourceIds[indexOf(regionKeys, vm.regionKey)].server
            : subnetResourceIds[indexOf(regionKeys, vm.regionKey)].client

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

// Same ordering guarantee as Windows VMs: network pathing is established first.

var activeLinuxVMs = deployWorkload ? linuxVMList : []

module linuxVMs 'modules/compute/vm-linux.bicep' = [
  for vm in activeLinuxVMs: {
    name: '${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      vnets
      routeTables
    ]

    params: {
      vmName: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'
      vmSize: vmSize

      adminUsername: vm.type == 'srvlin' ? serverAdminUsername : clientAdminUsername
      adminPublicKey: adminPublicKey

      subnetId: vm.type == 'srvlin'
        ? subnetResourceIds[indexOf(regionKeys, vm.regionKey)].server
        : subnetResourceIds[indexOf(regionKeys, vm.regionKey)].client


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

output validationDebug object = validationEngine.outputs.validationFlags
output validationMessage string = validationEngine.outputs.validationMessage
output validationSummary string = empty(validationEngine.outputs.validationMessage)
  ? 'Validation passed.'
  : validationEngine.outputs.validationMessage

// Per-region VM count after placement
// Useful for confirming even distribution and ensuring no region exceeds limits
output vmCountPerRegion array = [
  for (region, i) in regionKeys: {
    region: region
    count: validationEngine.outputs.vmPerRegionCounts[i]
  }
]

// Summary of capacity vs requested VMs
// Helps quickly determine if deployment is within allowed limits
output capacityCheck object = {
  totalVMs: validationEngine.outputs.totalVMs
  capacity: validationEngine.outputs.totalCapacity
  withinLimit: validationEngine.outputs.totalVMs <= validationEngine.outputs.totalCapacity
}

output selectedRegionsOutput array = regionKeys

// Total number of VMs requested across all types
output totalVmRequested int = validationEngine.outputs.totalVMs

// Maximum number of VMs that can be deployed based on region count and per-region limit
output totalCapacityAvailable int = validationEngine.outputs.totalCapacity

output regionSummary array = [
  for (region, i) in regionKeys: {
    region: region
    addressSpace: addressPrefixes[i]
    subnets: subnetPrefixesArray[i]
    vmCount: length(filter(vmPlacements, vm => vm.regionKey == region))
  }
]
