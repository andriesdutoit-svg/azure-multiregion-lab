targetScope = 'subscription'

// ========================================
// PLACEMENT ENGINE
//
// Responsible for:
// - Region ordering
// - VM modelling
// - Brownfield reconciliation
// - Capacity calculations
// - VM placement
//
// No resource deployment occurs here.
// ========================================

// NOTE:
// This file is a reference implementation of the placement logic.
// The subscription-scope root keeps the executable logic because placement
// results are required for deployment-time counts, loops, scopes, conditions,
// and names.
//
// Future options:
// - User-defined functions (if suitable)
// - Bicep compile-time constructs (if Microsoft adds support)
// - Documentation/reference implementation

param vmCounts object

param existingVmPlacements array

param regionIndexMap object
param regionCount int
param maxVmsPerRegion int

param existingRegions array

param prefix string

param useDedicatedFileServer bool

// Outputs contract:
//
// regionKeys
// primaryRegion
// hubRegion
//
// invalidExistingRegions
// invalidExistingVmPlacements
//
// hasTooManyDcs
//
// finalVmPlacements
//
// primaryDc
// replicaDcList
//
// fileServerVm
// fileServerName

// Internal implementation sections:
//
// 1. VM Model Building
// 2. Region Ordering
// 3. Hub Model
// 4. Capacity Model
// 5. Placement Engine
// 6. Derived Placement Objects
//
// Public outputs:
//
// regionKeys
// primaryRegion
// hubRegion
//
// invalidExistingRegions
// invalidExistingVmPlacements
//
// hasTooManyDcs
//
// finalVmPlacements
//
// primaryDc
// replicaDcList
//
// fileServerVm
// fileServerName

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

var regionKeys = take(sortedRegions, regionCount)

var primaryRegion = regionKeys[0]

var hubRegion = primaryRegion

var isSingleRegion = regionCount == 1

// ========================================
// VM MODEL BUILDING
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

var invalidExistingRegions = filter(
  existingRegions,
  region => !contains(regionKeys, region)
)

var invalidExistingVmPlacements = filter(
  existingVmPlacements,
  vm => !contains(regionKeys, vm.regionKey)
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
// HUB MODEL
// ========================================

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

//
// ========================================
// PLACEMENT ENGINE
// Assigns each VM to a region using rules
// ========================================
//

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
))

var replicaDcList = filter(finalVmPlacements, vm =>
  vm.type == 'dc' && vm.index > 0
)

var fileServerVmList = filter(finalVmPlacements, vm =>
  vm.type == 'srvwin'
)

var fileServerVm = useDedicatedFileServer && length(fileServerVmList) > 0
  ? fileServerVmList[0]
  : primaryDc!

var fileServerName = useDedicatedFileServer
  ? fileServerVm.name
  : primaryDc!.name

output regionKeys array = regionKeys
output primaryRegion string = primaryRegion
output hubRegion string = hubRegion

output invalidExistingRegions array = invalidExistingRegions

output invalidExistingVmPlacements array = invalidExistingVmPlacements

output hasTooManyDcs bool = hasTooManyDcs

output finalVmPlacements array = finalVmPlacements

output primaryDc object = primaryDc!

output replicaDcList array = replicaDcList

output fileServerVm object = fileServerVm!

output fileServerName string = fileServerName
