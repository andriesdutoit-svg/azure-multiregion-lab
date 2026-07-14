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
param departments object
param departmentCount int
param usersPerDepartment int

// ========================================
// DERIVED METRICS
// Counts and boolean checks evaluated from the final placement result.
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
var missingPinnedDc = empty(filter(vmPlacements, vm => vm.type == 'dc' && vm.index == 0 && vm.regionKey == primaryRegion))
var missingPinnedJumpbox = empty(filter(vmPlacements, vm => vm.type == 'jmp' && vm.index == 0 && vm.regionKey == primaryRegion))
var invalidPrimaryPinning = missingPinnedDc || missingPinnedJumpbox
var hasNonControlInHub = length(filter(vmPlacements, vm => !(vm.type == 'dc' || vm.type == 'jmp') && vm.regionKey == hubRegion)) > 0
var nonControlVmCount = vmCounts.windowsServer + vmCounts.windowsClient + vmCounts.linuxServer + vmCounts.linuxClient
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
// WORKLOAD CAPACITY VALIDATION
// Confirms that spokes still have enough remaining workload slots after control-plane placement.
// ========================================

// Per-region control-plane occupancy and remaining workload capacity.
// The hub contributes zero workload capacity by design.
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

var hasInsufficientWorkloadCapacity = nonControlVmCount > totalWorkloadRegionCapacity

// ========================================
// DIRECTORY POPULATION VALIDATION
// Validates department/user input integrity for identity population.
// ========================================

var invalidDepartmentCount = departmentCount > length(items(departments))

var invalidMinimumDepartments = departmentCount < 1

var invalidUsersPerDepartment = usersPerDepartment < 1

var departmentCodes = [
  for d in items(departments): d.value
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
}

// ========================================
// MESSAGE COMPOSITION
// First-match message preserves stable and concise feedback.
// ========================================

var msg1 = invalidMinimums ? 'At least 1 DC and 1 Jumpbox are required.' : ''
var msg2 = invalidRegionCount ? 'Region count exceeds available regions.' : ''
var msg3 = invalidPrimaryPinning ? 'Primary pinning failed: dc01 and jmp01 must be placed in the primary region.' : ''
var msg4 = hasNonControlInHub ? 'One or more non-control VMs were placed in the hub region.' : ''
var msg5 = missingRegionIndex ? 'One or more regions are missing in regionIndexMap.' : ''
var msg6 = hasInvalidSubnetIndex ? 'Subnet index map must include firewall, dc, jumpbox, server, and client.' : ''
var msg7 = hasMissingVmSizeRole ? 'vmSizes must include dc, jumpbox, windowsServer, windowsClient, linuxServer, and linuxClient.' : ''
var msg8 = hasMissingOsDiskRole ? 'osDisks must include dc, jumpbox, windowsServer, windowsClient, linuxServer, and linuxClient.' : ''
var msg9 = hasInsufficientWorkloadCapacity ? 'Non-control workloads exceed the remaining spoke capacity after DC/jumpbox placement.' : ''
var msg10 = hasRegionOverflow ? 'One or more regions exceed the maximum allowed VMs per region.' : ''
var msg11 = invalidCapacity ? 'Too many VMs for the allowed capacity per region.' : ''
var msg12 = invalidIndexSequence ? 'Region index map must have continuous values starting at 1.' : ''
var msg13 = hasTooManyDcs ? 'Too many DCs for the available regions.' : ''
var msg14 = invalidDepartmentCount ? 'Department count exceeds the number of defined departments.' : ''
var msg15 = invalidMinimumDepartments ? 'At least one department is required.' : ''
var msg16 = invalidUsersPerDepartment ? 'Users per department must be at least 1.' : ''
var msg17 = duplicateDepartmentCodes ? 'Department codes must be unique.' : ''

var validationMessage = msg1 != '' ? msg1 : msg2 != '' ? msg2 : msg3 != '' ? msg3 : msg4 != '' ? msg4 : msg5 != '' ? msg5 : msg6 != '' ? msg6 : msg7 != '' ? msg7 : msg8 != '' ? msg8 : msg9 != '' ? msg9 : msg10 != '' ? msg10 : msg11 != '' ? msg11 : msg12 != '' ? msg12 : msg13 != '' ? msg13 : msg14 != '' ? msg14 : msg15 != '' ? msg15 : msg16 != '' ? msg16 : msg17 != '' ? msg17 : 'All validation checks passed.'

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

