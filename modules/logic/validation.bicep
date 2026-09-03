targetScope = 'subscription'

// ========================================
// MODULE PURPOSE
// Evaluates placement and configuration rules and returns deterministic validation outputs.
// ========================================

// ========================================
// INPUTS
// ========================================

param vmCounts object
param vmSizes object
param osDisks object
param regionCount int
param regionIndexMap object
param subnetIndexMap object
param vmPlacements array
param regionKeys array
param maxVmsPerRegion int
param primaryRegion string
param hubRegion string
param hasTooManyDcs bool
param sysAdminDepartment object
param additionalDepartments object
param departmentCount int
param usersPerDepartment int
param invalidExistingRegions array
param invalidExistingVmPlacementCount int = 0
// Stage-based deployment flags for brownfield and dependency validation.
param deployNetwork bool
param deployControl bool
param deployWorkload bool
// Full existingRegions array used for brownfield consistency checks.
param existingRegions array = []
// Existing VM inventory used for brownfield capacity validation.
param existingVmPlacements array = []

// ========================================
// PLACEMENT & CAPACITY VALIDATION
// Counts and boolean checks evaluated from the final placement result, including retained brownfield VMs.
// ========================================

var vmPerRegionCounts = [
  for region in regionKeys: length(filter(vmPlacements, vm => vm.regionKey == region))
]

var regionOverflowFlags = [
  for count in vmPerRegionCounts: count > maxVmsPerRegion
]

var hasRegionOverflow = contains(regionOverflowFlags, true)
var invalidMinimums = vmCounts.dc < 1 || vmCounts.jumpbox < 1
var invalidRegionCount = regionCount > length(regionIndexMap)
var hasInvalidExistingVmPlacements = invalidExistingVmPlacementCount > 0
var missingPinnedDc = empty(filter(vmPlacements, vm => vm.type == 'dc' && vm.index == 0 && vm.regionKey == primaryRegion))
var missingPinnedJumpbox = empty(filter(vmPlacements, vm => vm.type == 'jmp' && vm.index == 0 && vm.regionKey == primaryRegion))
var invalidPrimaryPinning = missingPinnedDc || missingPinnedJumpbox
var hasNonControlInHub = length(filter(vmPlacements, vm => !(vm.type == 'dc' || vm.type == 'jmp') && vm.regionKey == hubRegion)) > 0
var nonControlVmCount = vmCounts.windowsServer + vmCounts.windowsClient + vmCounts.linuxServer + vmCounts.linuxClient
var existingNonControlVmCount = length(filter(existingVmPlacements, vm => !(vm.type == 'dc' || vm.type == 'jmp')))
var newNonControlVmCount = nonControlVmCount - existingNonControlVmCount
var totalVMs = vmCounts.dc + vmCounts.jumpbox + vmCounts.windowsServer + vmCounts.windowsClient + vmCounts.linuxServer + vmCounts.linuxClient
var totalCapacity = regionCount * maxVmsPerRegion
var invalidCapacity = totalVMs > totalCapacity
var hasInvalidRegionIndex = [
  for region in regionKeys: contains(regionIndexMap, region) ? false : true
]

var missingRegionIndex = contains(hasInvalidRegionIndex, true)
var hasInvalidSubnetIndex = !(contains(subnetIndexMap, 'firewall') && contains(subnetIndexMap, 'jumpbox') && contains(subnetIndexMap, 'dc') && contains(subnetIndexMap, 'server') && contains(subnetIndexMap, 'client'))

// ========================================
// ROLE CONFIG VALIDATION
// Ensures all role-based sizing and disk maps contain the required workload keys.
// ========================================

// Required role keys for role-based compute configuration.
var requiredRoleKeys = [
  'dc'
  'jumpbox'
  'windowsServer'
  'windowsClient'
  'linuxServer'
  'linuxClient'
]

// Flag any missing vmSizes role keys before module/resource evaluation fails deeper in the graph.
var vmSizeRoleMissingFlags = [
  for role in requiredRoleKeys: !contains(vmSizes, role)
]

// Flag any missing osDisks role keys before VM modules consume per-role disk settings.
var osDiskRoleMissingFlags = [
  for role in requiredRoleKeys: !contains(osDisks, role)
]

var hasMissingVmSizeRole = contains(vmSizeRoleMissingFlags, true)
var hasMissingOsDiskRole = contains(osDiskRoleMissingFlags, true)

var hasMissingIndexes = [
  for i in range(1, length(regionIndexMap) + 1): empty(filter(items(regionIndexMap), r => r.value == i))
]

var invalidIndexSequence = contains(hasMissingIndexes, true)

// ========================================
// BROWNFIELD & DEPLOYMENT DEPENDENCY VALIDATION
// Ensures network infrastructure and brownfield coverage meet stage requirements
// ========================================

// ----
// Stage-to-brownfield dependency validation
// ----

var nonNetworkStageDeployed = deployControl || deployWorkload
var networkStageSkipped = !deployNetwork
var insufficientBrownfieldCoverage = length(existingRegions) < regionCount
var insufficientBrownfieldForStage = nonNetworkStageDeployed && networkStageSkipped && insufficientBrownfieldCoverage

// ----
// Hub region availability validation
// ----

var hubRequiredButMissing = (deployControl || deployWorkload) && !deployNetwork && !contains(existingRegions, hubRegion)

// ----
// Spoke region coverage validation
// ----

var spokesNotCovered = filter(
  regionKeys,
  region => region != hubRegion && !contains(existingRegions, region) && !deployNetwork
)

var spokeRegionsCovered = empty(spokesNotCovered)

// ----
// Greenfield vs brownfield consistency
// ----

var hasMixedCreationMode = deployNetwork && length(existingRegions) > 0 && length(existingRegions) < regionCount

// ========================================
// WORKLOAD CAPACITY VALIDATION
// Confirms that spokes have remaining workload slots after control-plane placement
// ========================================

// Per-region control-plane occupancy and remaining workload capacity.
// Existing VMs are part of vmPlacements, and the hub contributes zero workload capacity by design.
var workloadCapacityDebug = [
  for region in regionKeys: {
    region: region
    isHub: region == hubRegion
    controlPlaneVmCount: length(filter(vmPlacements, vm => (vm.type == 'dc' || vm.type == 'jmp') && vm.regionKey == region))
    remainingWorkloadCapacity: region == hubRegion
      ? 0
      : (maxVmsPerRegion > length(filter(vmPlacements, vm => (vm.type == 'dc' || vm.type == 'jmp') && vm.regionKey == region))
        ? maxVmsPerRegion - length(filter(vmPlacements, vm => (vm.type == 'dc' || vm.type == 'jmp') && vm.regionKey == region))
        : 0)
  }
]

var workloadRemainingCapacityCounts = [
  for slot in workloadCapacityDebug: slot.isHub ? 0 : slot.remainingWorkloadCapacity
]

// Aggregate remaining spoke workload capacity for comparison against requested non-control VMs.
var totalWorkloadRegionCapacity = reduce(
  workloadRemainingCapacityCounts,
  0,
  (current, item) => current + item
)

var hasInsufficientWorkloadCapacity = newNonControlVmCount > totalWorkloadRegionCapacity

// ========================================
// IDENTITY & DIRECTORY POPULATION VALIDATION
// Validates department/user input integrity for identity population
// ========================================

var totalAvailableDepartments = length(items(sysAdminDepartment)) + length(items(additionalDepartments))

var invalidDepartmentCount = departmentCount > totalAvailableDepartments

var invalidMinimumDepartments = departmentCount < length(items(sysAdminDepartment))

var invalidUsersPerDepartment = usersPerDepartment < 1

var departmentCodes = [
  for d in concat(
    items(sysAdminDepartment),
    items(additionalDepartments)
  ): d.value
]

var duplicateDepartmentCodes = length(distinct(departmentCodes)) != length(departmentCodes)

// Includes one manager account per department in addition to usersPerDepartment user accounts.
var requestedDirectoryAccounts = departmentCount * (usersPerDepartment + 1)

// ========================================
// VALIDATION FLAG MODEL
// Consolidated rule state emitted for diagnostics.
// ========================================

var validationFlags = {
  invalidMinimums: invalidMinimums
  invalidRegionCount: invalidRegionCount
  invalidPrimaryPinning: invalidPrimaryPinning
  hasNonControlInHub: hasNonControlInHub
  invalidCapacity: invalidCapacity
  missingRegionIndex: missingRegionIndex
  hasInvalidSubnetIndex: hasInvalidSubnetIndex
  hasMissingVmSizeRole: hasMissingVmSizeRole
  hasMissingOsDiskRole: hasMissingOsDiskRole
  hasInsufficientWorkloadCapacity: hasInsufficientWorkloadCapacity
  invalidIndexSequence: invalidIndexSequence
  hasRegionOverflow: hasRegionOverflow
  hasTooManyDcs: hasTooManyDcs
  invalidDepartmentCount: invalidDepartmentCount
  invalidMinimumDepartments: invalidMinimumDepartments
  invalidUsersPerDepartment: invalidUsersPerDepartment
  duplicateDepartmentCodes: duplicateDepartmentCodes
  hasInvalidExistingRegions: length(invalidExistingRegions) > 0
  insufficientBrownfieldForStage: insufficientBrownfieldForStage
  hubRequiredButMissing: hubRequiredButMissing
  spokeRegionsCovered: !spokeRegionsCovered
  hasMixedCreationMode: hasMixedCreationMode
}

// ========================================
// MESSAGE COMPOSITION
// First-match message preserves stable and concise feedback.
// Messages are categorized by validation concern; only the first error is returned.
// ========================================

// Placement & Capacity Validation (msg1-5, msg10-11): VM placement logic, region capacity
var msg1 = invalidMinimums ? 'At least 1 DC and 1 Jumpbox are required.' : ''
var msg2 = invalidRegionCount ? 'Region count exceeds available regions.' : ''
var msg3 = invalidPrimaryPinning ? 'Primary pinning failed: dc01 and jmp01 must be placed in the primary region.' : ''
var msg4 = hasNonControlInHub ? 'One or more non-control VMs were placed in the hub region.' : ''
var msg5 = missingRegionIndex ? 'One or more regions are missing in regionIndexMap.' : ''

// Configuration & Role Validation (msg6-8, msg12): VM role sizing, region indexing, OS disk definitions
var msg6 = hasInvalidSubnetIndex ? 'Subnet index map must include firewall, dc, jumpbox, server, and client.' : ''
var msg7 = hasMissingVmSizeRole ? 'vmSizes must include dc, jumpbox, windowsServer, windowsClient, linuxServer, and linuxClient.' : ''
var msg8 = hasMissingOsDiskRole ? 'osDisks must include dc, jumpbox, windowsServer, windowsClient, linuxServer, and linuxClient.' : ''
var msg9 = hasInsufficientWorkloadCapacity
  ? 'Insufficient spoke capacity. Requested workload VMs require ${newNonControlVmCount} spoke slots, but only ${totalWorkloadRegionCapacity} remain after DC/jumpbox placement. Reduce VM counts, add regions, or increase maxVmsPerRegion.'
  : ''
var msg10 = hasRegionOverflow ? 'One or more regions exceed the maximum allowed VMs per region.' : ''
var msg11 = invalidCapacity ? 'Too many VMs for the allowed capacity per region.' : ''
var msg12 = invalidIndexSequence ? 'Region index map must have continuous values starting at 1.' : ''
var msg13 = hasTooManyDcs ? 'Too many DCs for the available regions.' : ''

// Identity & Directory Population Validation (msg14-17): Department configuration, user counts
var msg14 = invalidDepartmentCount
  ? 'Department count exceeds the number of available mandatory and additional departments.' : ''
var msg15 = invalidMinimumDepartments ? 'At least one department is required.' : ''
var msg16 = invalidUsersPerDepartment ? 'Users per department must be at least 1.' : ''
var msg17 = duplicateDepartmentCodes ? 'Department codes must be unique.' : ''

// Brownfield & Deployment Stage Validation (msg18-23): Region reuse, hub/spoke availability for incremental deployments
var msg18 = length(invalidExistingRegions) > 0
  ? 'existingRegions contains regions that are not selected for the current deployment.'
  : ''

var msg19 = hasInvalidExistingVmPlacements
  ? 'existingVmPlacements contains one or more regionKey values that are not present in the active regionKeys set. Remove stale inventory entries or include the missing regions in regionIndexMap.'
  : ''
var msg20 = insufficientBrownfieldForStage
  ? 'Stage deployment (control/workload/identity) requires either stage=network or existingRegions to include all deployed regions.'
  : ''
var msg21 = hubRequiredButMissing
  ? 'Hub region is required but not available. Either deploy stage=network or add hub region to existingRegions.'
  : ''
var msg22 = !spokeRegionsCovered
  ? 'One or more spoke regions are not available. Either deploy stage=network or add all spoke regions to existingRegions.'
  : ''
var msg23 = hasMixedCreationMode
  ? 'Mixing greenfield (create) and brownfield (reuse) regions in same deployment. Ensure consistent creation mode across all regions.'
  : ''

var validationMessage = msg1 != '' ? msg1 : msg2 != '' ? msg2 : msg3 != '' ? msg3 : msg4 != '' ? msg4 : msg5 != '' ? msg5 : msg6 != '' ? msg6 : msg7 != '' ? msg7 : msg8 != '' ? msg8 : msg9 != '' ? msg9 : msg10 != '' ? msg10 : msg11 != '' ? msg11 : msg12 != '' ? msg12 : msg13 != '' ? msg13 : msg14 != '' ? msg14 : msg15 != '' ? msg15 : msg16 != '' ? msg16 : msg17 != '' ? msg17 : msg18 != '' ? msg18 : msg19 != '' ? msg19 : msg20 != '' ? msg20 : msg21 != '' ? msg21 : msg22 != '' ? msg22 : msg23 != '' ? msg23 : 'All validation checks passed.'

// ========================================
// OUTPUTS
// ========================================

output validationFlags object = validationFlags
output validationMessage string = validationMessage
output totalVMs int = totalVMs
output totalCapacity int = totalCapacity
output vmPerRegionCounts array = vmPerRegionCounts
output nonControlVmCount int = nonControlVmCount
output totalWorkloadRegionCapacity int = totalWorkloadRegionCapacity
output workloadCapacityDebug array = workloadCapacityDebug
output departmentCount int = departmentCount
output usersPerDepartment int = usersPerDepartment
output requestedDirectoryAccounts int = requestedDirectoryAccounts
output invalidExistingRegions array = invalidExistingRegions

