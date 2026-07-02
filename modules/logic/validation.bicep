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

// ========================================
// DERIVED METRICS
// Counts and boolean checks used by validation rules.
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
  invalidIndexSequence: invalidIndexSequence
  hasRegionOverflow: hasRegionOverflow
  hasTooManyDcs: hasTooManyDcs
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
var msg9 = hasRegionOverflow ? 'One or more regions exceed the maximum allowed VMs per region.' : ''
var msg10 = invalidCapacity ? 'Too many VMs for the allowed capacity per region.' : ''
var msg11 = invalidIndexSequence ? 'Region index map must have continuous values starting at 1.' : ''
var msg12 = hasTooManyDcs ? 'Too many DCs for the available regions.' : ''

var validationMessage = msg1 != '' ? msg1 : msg2 != '' ? msg2 : msg3 != '' ? msg3 : msg4 != '' ? msg4 : msg5 != '' ? msg5 : msg6 != '' ? msg6 : msg7 != '' ? msg7 : msg8 != '' ? msg8 : msg9 != '' ? msg9 : msg10 != '' ? msg10 : msg11 != '' ? msg11 : msg12 != '' ? msg12 : ''

// ========================================
// OUTPUTS
// ========================================

output validationFlags object = validationFlags
output validationMessage string = validationMessage
output totalVMs int = totalVMs
output totalCapacity int = totalCapacity
output vmPerRegionCounts array = vmPerRegionCounts
