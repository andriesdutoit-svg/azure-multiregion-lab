targetScope = 'subscription'

// CONTENTS
// 1. Configuration and stage selection
// 2. Placement model: region ordering and VM model
// 3. Placement and capacity calculations
// 4. Compute and network helper values
// 5. DNS configuration and validation
// 6. Network, compute, and identity stages
// 7. Deployment outputs

// ========================================
// DEPLOYMENT PURPOSE
// Subscription-scope entry point that orchestrates multi-region networking, security, routing, compute, and identity deployment.
// ========================================

// ========================================
// 1. CONFIGURATION AND STAGE SELECTION
// ========================================

// ----
// Deployment Control
// ----
@description('Deployment stage to execute: network, compute, identity, or all.')
@allowed([
  'network'
  'compute'
  'identity'
  'all'
])
param stage string

@description('Prefix for all resources')
param prefix string
@description('Tags applied to deployed resources.')
param tags object

// ----
// Regional & Deployment Configuration
// ----
@description('Maps region names to their deployment order and address-space index.')
param regionIndexMap object
@description('Number of regions included in this deployment.')
param regionCount int
@description('Maximum number of VMs allowed in each region.')
param maxVmsPerRegion int
@description('Regions with existing VNets and managed networking to reconcile. Route tables and standard subnet associations are deployed or updated by the network stage; resources in other regions are created (greenfield).')
param existingRegions array
@description('Existing VM placement inventory used for brownfield VM reconciliation.')
param existingVmPlacements array = []

// ----
// Networking Configuration
// ----
@description('Maps subnet role names to address indexes within each regional VNet.')
param subnetIndexMap object
@description('Public IP ranges allowed to access jumpbox RDP or SSH.')
param jumpboxAllowedSources array

// ----
// Compute: VM Sizing & Images
// ----
@description('Requested VM count by logical role.')
param vmCounts object
// Role-based VM size map keyed by logical workload roles.
@description('VM size by logical role.')
param vmSizes object
// Role-based OS disk map (storage SKU + disk size) keyed by logical workload roles.
@description('OS disk configuration by logical role.')
param osDisks object
@description('Windows Server image reference.')
param windowsServerImage object
@description('Windows client image reference.')
param windowsClientImage object
@description('Ubuntu image reference.')
param ubuntuImage object
@description('Automatic deletion settings for VM-associated resources.')
param vmAutoDeleteOptions object

// ----
// Admin Credentials & Access
// ----
@description('Local administrator username for jumpbox VMs.')
param jumpboxAdminUsername string
@description('Local administrator password for jumpbox VMs.')
@secure()
param jumpboxAdminPassword string
@description('Local administrator username for server and domain controller VMs.')
param serverAdminUsername string
@description('Local administrator password for server and domain controller VMs.')
@secure()
param serverAdminPassword string
@description('Local administrator username for client VMs.')
param clientAdminUsername string
@description('Local administrator password for client VMs.')
@secure()
param clientAdminPassword string
@description('Public SSH key used for Linux VM administration.')
param sshPublicKey string
@description('Private SSH key installed on jumpboxes for administrative hops to Linux VMs.')
@secure()
param sshPrivateKey string

// ----
// Identity & Directory Management
// ----
@description('Enable Active Directory forest, replica, population, and domain-join automation.')
param enableIdentity bool
@description('Active Directory DNS domain name for the lab environment.')
param domainName string
@description('System administration department definition used for directory groups and permissions.')
param sysAdminDepartment object
@description('Additional department definitions used for directory population and file services.')
param additionalDepartments object
@description('Total number of departments configured for directory population.')
param departmentCount int
@description('Number of users created for each configured department.')
param usersPerDepartment int

@description('Enable departmental file shares, SMB shares, and share permissions.')
param enableFileServices bool

@description('Use a dedicated Windows server for departmental file shares.')
param useDedicatedFileServer bool

var reconciliationToken = deployment().name

// ========================================
// 1.1 STAGE FLAGS
// Selects the completed deployment stages for this run.
// ========================================

var deployNetwork = stage == 'network' || stage == 'all'
var deployCompute = stage == 'compute' || stage == 'all'
var deployIdentity = enableIdentity && (stage == 'identity' || stage == 'all')
// The compute stage owns control-plane and workload VM deployment. These internal flags
// describe the VM groups that the compute module activates for each public stage value.
var deployControl = deployCompute
var deployWorkload = deployCompute || deployIdentity

// ========================================
// 2. PLACEMENT MODEL: REGION ORDERING AND VM MODEL
//
// Placement is evaluated in the subscription-scope composition root because its results
// drive deployment-time loops, scopes, names, and conditions.
//
// Responsibilities:
// - VM model building
// - Brownfield reconciliation
// - Region ordering
// - Hub modelling
// - Capacity calculations
// - VM placement
// - Placement-derived objects
//
// Values consumed by validation and deployment stages:
// regionKeys
// primaryRegion
// hubRegion
// invalidExistingRegions
// invalidExistingVmPlacements
// hasTooManyDcs
// finalVmPlacements
// primaryDc
// replicaDcList
// fileServerVm
// fileServerName
// ========================================

// ========================================
// 2.1 REGION ORDERING (Index-Based Sorting)
// Converts regionIndexMap to the ordered region set used by placement and networking.
// ========================================

// Extract regions in order of their index value (1 to N).
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

// Select only the required number of regions. regionIndexMap may define more regions
// than are active in the current deployment.
var regionKeys = take(sortedRegions, regionCount)

var primaryRegion = regionKeys[0]
var isSingleRegion = regionCount == 1

var invalidExistingRegions = filter(
  existingRegions,
  region => !contains(regionKeys, region)
)

var invalidExistingVmPlacements = filter(
  existingVmPlacements,
  vm => !contains(regionKeys, vm.regionKey)
)

// ========================================
// 2.2 VM MODEL BUILDING
// Constructs unified list of all VMs from role-based counts
// ========================================

// ----
// Array building for each VM role type
// ----

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

// Existing VM keys identify resources that should be retained during brownfield reconciliation.
var existingVmKeys = [
  for vm in existingVmPlacements: '${vm.type}-${string(vm.index)}'
]

var missingVmList = filter(
  vmList,
  vm => !contains(existingVmKeys, '${vm.type}-${string(vm.index)}')
)

// Split the unified VM model into control-plane and workload sets.
// Placement uses different rules for these two groups.
var controlPlaneVmList = filter(missingVmList, vm =>
  vm.type == 'dc' || vm.type == 'jmp'
)

var workloadVmList = filter(missingVmList, vm =>
  !(vm.type == 'dc' || vm.type == 'jmp')
)

// Pinned primary-region control-plane VMs are excluded from the spoke placement below.
// The remaining control-plane VMs are placed first-fit: one spoke is filled to capacity before
// placement continues to the next spoke.
var controlPlanePlacementVmList = filter(controlPlaneVmList, vm =>
  !(vm.type == 'dc' && vm.index == 0) && !(vm.type == 'jmp' && vm.index == 0)
)

// ========================================
// 3. PLACEMENT AND CAPACITY CALCULATIONS
// ========================================

// ========================================
// 3.1 HUB MODEL
// ========================================

var hubRegion = primaryRegion

// Existing VMs consume capacity before new control-plane or workload VMs are placed.
var spokeRegionKeys = filter(regionKeys, region => region != hubRegion)

var existingVmCountBySpoke = [
  for region in spokeRegionKeys: length(filter(existingVmPlacements, vm => vm.regionKey == region))
]

var availableControlPlaneCapacityBySpoke = [
  for (count, i) in existingVmCountBySpoke: maxVmsPerRegion > count ? maxVmsPerRegion - count : 0
]

var totalAvailableControlPlaneCapacity = reduce(
  availableControlPlaneCapacityBySpoke,
  0,
  (current, item) => current + item
)

var controlPlaneCapacityCumulative = [
  for (capacity, i) in availableControlPlaneCapacityBySpoke: {
    region: spokeRegionKeys[i]
    capacity: capacity
    cumulativeCapacity: reduce(
      take(availableControlPlaneCapacityBySpoke, i + 1),
      0,
      (current, item) => current + item
    )
  }
]

// Model the new control-plane assignments separately from the final VM list.
// Existing VM occupancy is removed from spoke capacity first; pinned primary VMs remain in the hub.
// Once spoke capacity (totalAvailableControlPlaneCapacity) is exhausted, remaining VMs fall back
// to the hub via "?? hubRegion" below, with no capacity limit enforced on the hub at this stage.
var controlPlanePlacements = [
  for (vm, i) in missingVmList: !(vm.type == 'dc' || vm.type == 'jmp') ? {
    type: ''
    index: -1
    regionKey: ''
  } : {
    type: vm.type
    index: vm.index
    regionKey: isSingleRegion
      ? regionKeys[0]
      : (vm.type == 'dc' && vm.index == 0)
        ? primaryRegion
      : (vm.type == 'jmp' && vm.index == 0)
        ? primaryRegion
        : totalAvailableControlPlaneCapacity > 0 && indexOf(controlPlanePlacementVmList, vm) < totalAvailableControlPlaneCapacity
        ? first(filter(
            controlPlaneCapacityCumulative,
          slot => slot.capacity > 0 && indexOf(controlPlanePlacementVmList, vm) < slot.cumulativeCapacity
          )).?region ?? hubRegion
        : hubRegion
  }
]

// Model remaining spoke capacity after existing and new control-plane placement.
// Each cumulative slot represents one legal workload position; workloads never use the hub.
var workloadRegionCapacity = [
  for region in filter(regionKeys, candidate => candidate != hubRegion): {
    region: region
    remainingCapacity: maxVmsPerRegion > length(filter(controlPlanePlacements, vm => vm.regionKey == region)) + length(filter(existingVmPlacements, vm => vm.regionKey == region))
      ? maxVmsPerRegion - length(filter(controlPlanePlacements, vm => vm.regionKey == region)) - length(filter(existingVmPlacements, vm => vm.regionKey == region))
      : 0
  }
]

var workloadRegionCapacityCounts = [
  for slot in workloadRegionCapacity: slot.remainingCapacity
]

// Total number of workload slots still available across all spokes.
var totalWorkloadRegionCapacity = reduce(
  workloadRegionCapacityCounts,
  0,
  (current, item) => current + item
)

// Cumulative slot boundaries used to map each workload ordinal to a specific spoke.
var workloadRegionCapacityCumulative = [
  for (slot, i) in workloadRegionCapacity: {
    region: slot.region
    remainingCapacity: slot.remainingCapacity
    cumulativeCapacity: reduce(
      take(workloadRegionCapacityCounts, i + 1),
      0,
      (current, item) => current + item
    )
  }
]

// ========================================
// 3.2 VM PLACEMENT
// Assigns each missing VM to a region using topology and capacity rules.
// ========================================

var vmPlacements = [
  for (vm, i) in missingVmList: {
    type: vm.type
    index: vm.index
    name: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    regionKey: isSingleRegion
      ? regionKeys[0]

      // Branch order: single-region override -> pinned primary VMs -> workloads -> capacity-aware control-plane placement.

      // Always pin first DC and jumpbox
      : (vm.type == 'dc' && vm.index == 0)
        ? primaryRegion

      : (vm.type == 'jmp' && vm.index == 0)
        ? primaryRegion

      // Workloads NEVER go to hub and only consume remaining spoke capacity slots.
      // Workload placement uses modulo (%) to distribute across available slots fairly,
      // avoiding concentration in a single spoke if capacity allows distribution.
      : !(vm.type == 'dc' || vm.type == 'jmp')
        ? totalWorkloadRegionCapacity > 0
          ? first(filter(
              workloadRegionCapacityCumulative,
              slot => slot.remainingCapacity > 0 && ((indexOf(workloadVmList, vm) % totalWorkloadRegionCapacity) < slot.cumulativeCapacity)
            )).?region ?? regionKeys[1]
          : regionKeys[1]

      // New DC/JMP VMs fill spoke capacity first-fit (one spoke to its max before the next),
      // then fall back to the hub with no capacity limit once spoke capacity is exhausted.
        : totalAvailableControlPlaneCapacity > 0 && indexOf(controlPlanePlacementVmList, vm) < totalAvailableControlPlaneCapacity
        ? first(filter(
            controlPlaneCapacityCumulative,
            slot => slot.capacity > 0 && indexOf(controlPlanePlacementVmList, vm) < slot.cumulativeCapacity
          )).?region ?? hubRegion
        : hubRegion
  }
]

var maxDcPerRegion = maxVmsPerRegion
var totalDcs = vmCounts.dc
var minRegionsNeededForDcs = (totalDcs + maxDcPerRegion - 1) / maxDcPerRegion
var hasTooManyDcs = minRegionsNeededForDcs > regionCount

var existingVmPlacementModels = [
  for vm in filter(existingVmPlacements, vm => contains(regionKeys, vm.regionKey)): {
    type: vm.type
    index: vm.index
    name: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'
    regionKey: vm.regionKey
  }
]

var finalVmPlacements = concat(
  existingVmPlacementModels,
  vmPlacements
)

var primaryDc = first(filter(finalVmPlacements, vm =>
  vm.type == 'dc' && vm.index == 0
))!

var replicaDcList = filter(finalVmPlacements, vm =>
  vm.type == 'dc' && vm.index > 0
)

var fileServerVmList = filter(finalVmPlacements, vm =>
  vm.type == 'srvwin'
)

var fileServerVm = useDedicatedFileServer && length(fileServerVmList) > 0
  ? fileServerVmList[0]
  : primaryDc

var fileServerName = useDedicatedFileServer
  ? fileServerVm.name
  : primaryDc!.name

// ========================================
// 4. COMPUTE AND NETWORK HELPER VALUES
// ========================================

// ========================================
// 4.1 VM GROUPING AND SUPPORT VARIABLES
// ========================================

var finalTags = union(tags, {
  project: prefix
})

// ========================================
// 4.2 COMPUTE HELPER VARIABLES
// ========================================

// Maps deployment VM role keys to their role-specific compute settings.
// Keys match vm.type values used by the placement model: dc, jmp, srvwin, cliwin, srvlin, clilin.
var roleSizingMap = {
  dc: {
    vmSize: vmSizes.dc
    osDisk: osDisks.dc
  }
  jmp: {
    vmSize: vmSizes.jumpbox
    osDisk: osDisks.jumpbox
  }
  srvwin: {
    vmSize: vmSizes.windowsServer
    osDisk: osDisks.windowsServer
  }
  cliwin: {
    vmSize: vmSizes.windowsClient
    osDisk: osDisks.windowsClient
  }
  srvlin: {
    vmSize: vmSizes.linuxServer
    osDisk: osDisks.linuxServer
  }
  clilin: {
    vmSize: vmSizes.linuxClient
    osDisk: osDisks.linuxClient
  }
}

// Passed to compute-stage so it can decide whether jumpbox SSH-key installation is needed.
var hasLinuxVMs = vmCounts.linuxServer > 0 || vmCounts.linuxClient > 0

// ========================================
// 4.3 NETWORK HELPER VARIABLES
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

// Each region gets its own /16 (10.<regionIndex>.0.0/16), and each role subnet is a /24 carved
// out of that /16 using its octet from subnetIndexMap (e.g. subnetIndexMap.dc = 2 -> 10.x.2.0/24).
var subnetPrefixesArray = [
  for region in regionKeys: {
    firewall: '10.${regionIndexMap[region]}.${subnetIndexMap.firewall}.0/24'
    jumpbox: '10.${regionIndexMap[region]}.${subnetIndexMap.jumpbox}.0/24'
    dc:      '10.${regionIndexMap[region]}.${subnetIndexMap.dc}.0/24'
    server:  '10.${regionIndexMap[region]}.${subnetIndexMap.server}.0/24'
    client:  '10.${regionIndexMap[region]}.${subnetIndexMap.client}.0/24'
  }
]

var reservedSubnetKeys = [
  'firewall'
  'jumpbox'
  'dc'
  'server'
  'client'
]

var additionalSubnetKeys = map(
  filter(items(subnetIndexMap), item => !contains(reservedSubnetKeys, item.key)),
  item => item.key
)

var additionalSubnetsByRegion = map(regionKeys, region => map(additionalSubnetKeys, subnetKey => {
  name: '${prefix}-vnet-${region}-subnet-${subnetKey}'
  addressPrefix: '10.${regionIndexMap[region]}.${subnetIndexMap[subnetKey]}.0/24'
}))

var jumpboxSubnets = [
  for (region, i) in regionKeys: subnetPrefixesArray[i].jumpbox
]

// The network stage exposes subnetMap with one entry per selected region.
// The compute stage consumes that contract for managed VM placement.

// ========================================
// 5. DNS CONFIGURATION AND VALIDATION
// ========================================

// ========================================
// 5.1 DNS CONFIGURATION: DYNAMIC FROM DC PLACEMENTS
// DNS servers are dynamically derived from actual DC placement positions,
// not from static region assumptions. This ensures VNets point to DCs that
// actually exist in the deployment rather than theoretical placements.
// ========================================

// Collect the region key for each DC placement entry.
// Non-DC VMs emit an empty marker that gets removed later.
var dcPlacements = [
  for vm in finalVmPlacements: vm.type == 'dc' ? vm.regionKey : ''
]

// Remove empty markers and de-duplicate region keys.
var dcRegions = filter(union(dcPlacements, []), region => !empty(region))

// Keep hub DC first, then append remaining DC regions.
// This preserves deterministic DNS ordering for all VNets.
var orderedDcRegions = concat(
  contains(dcRegions, primaryRegion) ? [primaryRegion] : [],
  filter(dcRegions, r => r != primaryRegion)
)

// Build candidate DNS server IPs from the DC subnet's fourth IP (.4) in each ordered DC region.
// .4 is the 4th usable IP in the /24 subnet (after .0, .1, .2, .3 reserved by Azure).
// This derives DNS from where DCs are actually placed, rather than from static region assumptions.
var dnsCandidates = [
  for region in orderedDcRegions: '10.${regionIndexMap[region]}.${subnetIndexMap.dc}.4'
]

// Each VNet supports up to 3 custom DNS servers; limit to avoid waste.
var dnsServers = take(dnsCandidates, 3)

//
// ========================================
// 5.2 VALIDATION ENGINE
// Delegated to modules/logic/validation.bicep
// ========================================

module validationEngine 'modules/logic/validation.bicep' = {
  name: '${prefix}-validation-engine-${take(deployment().name, 20)}'
  params: {
    vmCounts: vmCounts
    vmSizes: vmSizes
    osDisks: osDisks
    regionCount: regionCount
    regionIndexMap: regionIndexMap
    subnetIndexMap: subnetIndexMap
    vmPlacements: finalVmPlacements
    regionKeys: regionKeys
    maxVmsPerRegion: maxVmsPerRegion
    primaryRegion: primaryRegion
    hubRegion: hubRegion
    hasTooManyDcs: hasTooManyDcs
    sysAdminDepartment: sysAdminDepartment
    additionalDepartments: additionalDepartments
    departmentCount: departmentCount
    usersPerDepartment: usersPerDepartment
    invalidExistingRegions: invalidExistingRegions
    invalidExistingVmPlacementCount: length(invalidExistingVmPlacements)
    deployNetwork: deployNetwork
    deployControl: deployControl
    deployWorkload: deployWorkload
    existingRegions: existingRegions
    existingVmPlacements: existingVmPlacements
    enableIdentity: enableIdentity
    useDedicatedFileServer: useDedicatedFileServer
    enableFileServices: enableFileServices
    fileServerVmAvailable: length(fileServerVmList) > 0
  }
}

// ========================================
// 6. NETWORK, COMPUTE, AND IDENTITY STAGES
// ========================================

// ========================================
// 6.1 NETWORK STAGE
// ========================================

module networkStage 'modules/stages/network-stage.bicep' = {
  name: '${prefix}-network-stage-${take(deployment().name, 20)}'

  params: {
    prefix: prefix
    regionKeys: regionKeys
    hubRegion: hubRegion

    deployNetwork: deployNetwork

    tags: finalTags

    existingRegions: existingRegions

    addressPrefixes: addressPrefixes
    subnetPrefixesArray: subnetPrefixesArray

    dnsServers: dnsServers

    jumpboxSubnets: jumpboxSubnets
    jumpboxAllowedSources: jumpboxAllowedSources
    additionalSubnetsByRegion: additionalSubnetsByRegion
  }
}

// ========================================
// 6.2 COMPUTE STAGE
// ========================================

module computeStage 'modules/stages/compute-stage.bicep' = {
  name: '${prefix}-compute-stage-${take(deployment().name, 20)}'

  params: {
    prefix: prefix

    reconciliationToken: reconciliationToken

    deployControl: deployControl
    deployWorkload: deployWorkload
    deployIdentity: deployIdentity

    windowsVMList: windowsVMList
    linuxVMList: linuxVMList

    hasLinuxVMs: hasLinuxVMs

    roleSizingMap: roleSizingMap
    finalTags: finalTags

    windowsServerImage: windowsServerImage
    windowsClientImage: windowsClientImage
    ubuntuImage: ubuntuImage

    vmAutoDeleteOptions: vmAutoDeleteOptions

    jumpboxAdminUsername: jumpboxAdminUsername
    jumpboxAdminPassword: jumpboxAdminPassword

    serverAdminUsername: serverAdminUsername
    serverAdminPassword: serverAdminPassword

    clientAdminUsername: clientAdminUsername
    clientAdminPassword: clientAdminPassword

    sshPublicKey: sshPublicKey
    sshPrivateKey: sshPrivateKey

    subnetMap: networkStage.outputs.subnetMap
  }
}

// ========================================
// 6.3 IDENTITY STAGE
// ========================================

module identityStage 'modules/stages/identity-stage.bicep' = {
  name: '${prefix}-identity-stage-${take(deployment().name, 20)}'

  dependsOn: [
    computeStage
  ]

  params: {
    prefix: prefix

    deployIdentity: deployIdentity

    reconciliationToken: reconciliationToken

    primaryDc: primaryDc
    replicaDcList: replicaDcList

    fileServerVm: fileServerVm
    fileServerName: fileServerName

    finalVmPlacements: finalVmPlacements

    domainName: domainName

    usersPerDepartment: usersPerDepartment
    departmentCount: departmentCount

    sysAdminDepartment: sysAdminDepartment
    additionalDepartments: additionalDepartments

    enableFileServices: enableFileServices

    serverAdminUsername: serverAdminUsername
    serverAdminPassword: serverAdminPassword

    clientAdminPassword: clientAdminPassword
  }
}

// ========================================
// 7. DEPLOYMENT OUTPUTS
// ========================================

// List of regions selected for this deployment (ordered by regionIndexMap) and assigned region
// This is the primary output used to verify distribution logic
output vmPlacement array = finalVmPlacements

// Validation message describing the first detected validation issue, or a success message when all checks pass.

output validationFlags object = validationEngine.outputs.validationFlags
output workloadCapacitySummary object = {
  nonControlVmCount: validationEngine.outputs.nonControlVmCount
  totalWorkloadRegionCapacity: validationEngine.outputs.totalWorkloadRegionCapacity
}
output workloadCapacityByRegion array = validationEngine.outputs.workloadCapacityByRegion
output validationMessage string = validationEngine.outputs.validationMessage
output validationSummary string = empty(validationEngine.outputs.validationMessage)
  ? 'Validation passed.'
  : validationEngine.outputs.validationMessage

// Brownfield inventory details identify existing VM entries outside the active region set.
output invalidExistingVmPlacementDetails array = invalidExistingVmPlacements
output invalidExistingVmPlacementCount int = validationEngine.outputs.invalidExistingVmPlacementCount
output hasInvalidExistingVmPlacements bool = validationEngine.outputs.hasInvalidExistingVmPlacements

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
    vmCount: length(filter(finalVmPlacements, vm => vm.regionKey == region))
  }
]
