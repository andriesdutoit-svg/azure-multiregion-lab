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
param windowsServerImage object
param windowsClientImage object
param ubuntuImage object
param regionCount int
param regionIndexMap object
param subnetIndexMap object
param jumpboxAllowedSources array
param networkMode string
param automationManagedIdentityResourceId string
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
// Dedicated file server mode: requires at least one srvwin VM to exist.
param enableIdentity bool
param useDedicatedFileServer bool
param enableFileServices bool
param fileServerVmAvailable bool
// Domain name consumed by the Group Policy Run Command to build DNs and SYSVOL paths.
param domainName string = ''
// GPO display names consumed by the import script and matched against Backup.xml.
param gpoNames object = {}

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

var regionIndexValues = [
  for region in items(regionIndexMap): region.value
]

var subnetIndexValues = [
  for subnet in items(subnetIndexMap): subnet.value
]

var hasDuplicateRegionIndexes = length(distinct(regionIndexValues)) != length(regionIndexValues)
var outOfBoundsRegionIndexFlags = [
  for index in regionIndexValues: index < 1 || index > 255
]
var hasOutOfBoundsRegionIndex = contains(outOfBoundsRegionIndexFlags, true)
var hasDuplicateSubnetIndexes = length(distinct(subnetIndexValues)) != length(subnetIndexValues)
var outOfBoundsSubnetIndexFlags = [
  for index in subnetIndexValues: index < 0 || index > 255
]
var hasOutOfBoundsSubnetIndex = contains(outOfBoundsSubnetIndexFlags, true)

// Existing inventory must map one-to-one to the logical VM model.
var supportedExistingVmTypes = [
  'dc'
  'jmp'
  'srvwin'
  'cliwin'
  'srvlin'
  'clilin'
]

var existingVmCountByType = {
  dc: vmCounts.dc
  jmp: vmCounts.jumpbox
  srvwin: vmCounts.windowsServer
  cliwin: vmCounts.windowsClient
  srvlin: vmCounts.linuxServer
  clilin: vmCounts.linuxClient
}

var existingVmKeys = [
  for vm in existingVmPlacements: '${vm.type}-${string(vm.index)}'
]

var hasDuplicateExistingRegions = length(distinct(existingRegions)) != length(existingRegions)
var hasDuplicateExistingVmPlacements = length(distinct(existingVmKeys)) != length(existingVmKeys)
var unsupportedExistingVmTypeFlags = [
  for vm in existingVmPlacements: !contains(supportedExistingVmTypes, vm.type)
]
var hasUnsupportedExistingVmType = contains(unsupportedExistingVmTypeFlags, true)
var invalidExistingVmIndexFlags = [
  for vm in existingVmPlacements: contains(supportedExistingVmTypes, vm.type)
    ? vm.index < 0 || vm.index >= existingVmCountByType[vm.type]
    : false
]
var hasInvalidExistingVmIndex = contains(invalidExistingVmIndexFlags, true)

// Empty or public-wide jumpbox access is reported for operator review without blocking deployment.
var hasUnsafeJumpboxAllowedSources = empty(jumpboxAllowedSources) || contains(jumpboxAllowedSources, '0.0.0.0/0')

// Brownfield cleanup requires a User Assigned Managed Identity only when the cleanup script is deployed.
var requiresPeeringCleanupIdentity = networkMode != 'fullMesh' && !empty(existingRegions)
var hasMissingPeeringCleanupIdentity = empty(automationManagedIdentityResourceId)
var hasMalformedPeeringCleanupIdentity = !startsWith(toLower(automationManagedIdentityResourceId), '/subscriptions/') || !contains(toLower(automationManagedIdentityResourceId), '/providers/microsoft.managedidentity/userassignedidentities/')
var hasInvalidPeeringCleanupIdentity = requiresPeeringCleanupIdentity && (hasMissingPeeringCleanupIdentity || hasMalformedPeeringCleanupIdentity)

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

var emptyVmSizeRoleFlags = [
  for role in requiredRoleKeys: contains(vmSizes, role) ? empty(vmSizes[role]) : false
]
var hasEmptyVmSizeRole = contains(emptyVmSizeRoleFlags, true)

var invalidOsDiskConfigurationFlags = [
  for role in requiredRoleKeys: !contains(osDisks, role)
    ? false
    : !contains(osDisks[role], 'storageAccountType')
      ? true
      : empty(osDisks[role].storageAccountType)
        ? true
        : !contains(osDisks[role], 'diskSizeGB')
          ? true
          : osDisks[role].diskSizeGB < 1
]
var hasInvalidOsDiskConfiguration = contains(invalidOsDiskConfigurationFlags, true)

var imageReferences = [
  windowsServerImage
  windowsClientImage
  ubuntuImage
]

var incompleteImageReferenceFlags = [
  for image in imageReferences: empty(image.?publisher) || empty(image.?offer) || empty(image.?sku) || empty(image.?version)
]
var hasIncompleteImageReference = contains(incompleteImageReferenceFlags, true)

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

var missingDedicatedFileServer = useDedicatedFileServer && !fileServerVmAvailable

var invalidDedicatedFileServerConfiguration = !enableFileServices && useDedicatedFileServer
var invalidFileServicesIdentityConfiguration = !enableIdentity && (enableFileServices || useDedicatedFileServer)

// ========================================
// WORKLOAD CAPACITY VALIDATION
// Confirms that spokes have remaining workload slots after control-plane placement
// ========================================

// Per-region control-plane occupancy and remaining workload capacity.
// Existing VMs are part of vmPlacements, and the hub contributes zero workload capacity by design.
var workloadCapacityByRegion = [
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
  for slot in workloadCapacityByRegion: slot.isHub ? 0 : slot.remainingWorkloadCapacity
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
// GROUP POLICY PROVISIONING VALIDATION
// The GPO Run Command derives the domain DN and the SYSVOL UNC path holding
// Groups.xml from domainName, and reconciles the Windows admins group that
// directory population creates from the system administration department.
// ========================================

var domainLabels = split(domainName, '.')

var emptyDomainLabelFlags = [
  for label in domainLabels: empty(label)
]

// Flag blank, single-label, or UNC-unsafe names before the GPO script builds DNs and SYSVOL paths.
var malformedDomainName = empty(domainName) || length(domainLabels) < 2 || contains(emptyDomainLabelFlags, true) || contains(domainName, ' ') || contains(domainName, '\\') || contains(domainName, '@') || contains(domainName, '/')

var hasMalformedDomainName = enableIdentity && malformedDomainName

var emptySysAdminDepartmentCodeFlags = [
  for d in items(sysAdminDepartment): empty(d.value)
]

// The GPO group reference resolves GGS_<windowsAdmins>, which population sources from this code.
var hasEmptySysAdminDepartmentCode = enableIdentity && (empty(items(sysAdminDepartment)) || contains(emptySysAdminDepartmentCodeFlags, true))

// Group Policy is provisioned on the primary DC, so a missing primary DC pin also breaks GPO import.
var hasNoGpoTargetDc = enableIdentity && missingPinnedDc
var hasInvalidGpoNames = enableIdentity && (empty(gpoNames.?serverAdministration) || empty(gpoNames.?clientAdministration))

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
  hasDuplicateRegionIndexes: hasDuplicateRegionIndexes
  hasOutOfBoundsRegionIndex: hasOutOfBoundsRegionIndex
  hasDuplicateSubnetIndexes: hasDuplicateSubnetIndexes
  hasOutOfBoundsSubnetIndex: hasOutOfBoundsSubnetIndex
  hasDuplicateExistingRegions: hasDuplicateExistingRegions
  hasDuplicateExistingVmPlacements: hasDuplicateExistingVmPlacements
  hasUnsupportedExistingVmType: hasUnsupportedExistingVmType
  hasInvalidExistingVmIndex: hasInvalidExistingVmIndex
  hasUnsafeJumpboxAllowedSources: hasUnsafeJumpboxAllowedSources
  hasInvalidPeeringCleanupIdentity: hasInvalidPeeringCleanupIdentity
  hasMissingVmSizeRole: hasMissingVmSizeRole
  hasMissingOsDiskRole: hasMissingOsDiskRole
  hasEmptyVmSizeRole: hasEmptyVmSizeRole
  hasInvalidOsDiskConfiguration: hasInvalidOsDiskConfiguration
  hasIncompleteImageReference: hasIncompleteImageReference
  hasInsufficientWorkloadCapacity: hasInsufficientWorkloadCapacity
  invalidIndexSequence: invalidIndexSequence
  hasRegionOverflow: hasRegionOverflow
  hasTooManyDcs: hasTooManyDcs
  invalidDepartmentCount: invalidDepartmentCount
  invalidMinimumDepartments: invalidMinimumDepartments
  invalidUsersPerDepartment: invalidUsersPerDepartment
  duplicateDepartmentCodes: duplicateDepartmentCodes
  hasInvalidExistingRegions: length(invalidExistingRegions) > 0
  hasInvalidExistingVmPlacements: hasInvalidExistingVmPlacements
  insufficientBrownfieldForStage: insufficientBrownfieldForStage
  hubRequiredButMissing: hubRequiredButMissing
  spokeRegionsCovered: !spokeRegionsCovered
  hasMixedCreationMode: hasMixedCreationMode
  missingDedicatedFileServer: missingDedicatedFileServer
  invalidDedicatedFileServerConfiguration: invalidDedicatedFileServerConfiguration
  invalidFileServicesIdentityConfiguration: invalidFileServicesIdentityConfiguration
  hasMalformedDomainName: hasMalformedDomainName
  hasEmptySysAdminDepartmentCode: hasEmptySysAdminDepartmentCode
  hasNoGpoTargetDc: hasNoGpoTargetDc
  hasInvalidGpoNames: hasInvalidGpoNames
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
  ? 'Stage deployment (compute/identity) requires either stage=network or existingRegions to include all deployed regions.'
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
var msg24 = missingDedicatedFileServer
  ? 'useDedicatedFileServer is true but no srvwin virtual machine exists. Add a Windows server (vmCounts.windowsServer) or set useDedicatedFileServer to false.'
  : ''
var msg25 = invalidDedicatedFileServerConfiguration
    ? 'useDedicatedFileServer cannot be true when enableFileServices is false.'
    : ''
var msg26 = invalidFileServicesIdentityConfiguration
  ? 'enableIdentity must be true when enableFileServices or useDedicatedFileServer is true. File services depend on Active Directory users and groups.'
  : ''
var msg27 = hasDuplicateRegionIndexes
  ? 'regionIndexMap contains duplicate index values, which would create overlapping VNet address spaces.'
  : ''
var msg28 = hasOutOfBoundsRegionIndex
  ? 'regionIndexMap values must be between 1 and 255.'
  : ''
var msg29 = hasDuplicateSubnetIndexes
  ? 'subnetIndexMap contains duplicate index values, which would create overlapping subnet address spaces.'
  : ''
var msg30 = hasOutOfBoundsSubnetIndex
  ? 'subnetIndexMap values must be between 0 and 255.'
  : ''
var msg31 = hasDuplicateExistingRegions
  ? 'existingRegions contains duplicate region entries.'
  : ''
var msg32 = hasDuplicateExistingVmPlacements
  ? 'existingVmPlacements contains duplicate type and index entries.'
  : ''
var msg33 = hasUnsupportedExistingVmType
  ? 'existingVmPlacements contains an unsupported VM type.'
  : ''
var msg34 = hasInvalidExistingVmIndex
  ? 'existingVmPlacements contains an index outside the requested vmCounts range.'
  : ''
var msg35 = hasInvalidPeeringCleanupIdentity
  ? 'automationManagedIdentityResourceId must be a User Assigned Managed Identity resource ID when brownfield peering cleanup is applicable.'
  : ''
var msg36 = hasEmptyVmSizeRole
  ? 'vmSizes values must be non-empty for all required roles.'
  : ''
var msg37 = hasInvalidOsDiskConfiguration
  ? 'osDisks entries must include a storageAccountType and a positive diskSizeGB for all required roles.'
  : ''
var msg38 = hasIncompleteImageReference
  ? 'Image references must include publisher, offer, sku, and version.'
  : ''

// Group Policy Provisioning Validation (msg39-42): inputs the GPO Run Command derives paths and group names from
var msg39 = hasMalformedDomainName
  ? 'domainName must be a multi-label DNS name (for example amrl.lab) without spaces, slashes, or @. Group Policy provisioning derives the domain DN and the SYSVOL path to Groups.xml from this value.'
  : ''
var msg40 = hasEmptySysAdminDepartmentCode
  ? 'sysAdminDepartment must define a non-empty department code. Group Policy provisioning resolves the Windows admins group that directory population creates from this code.'
  : ''
var msg41 = hasNoGpoTargetDc
  ? 'Group Policy provisioning runs on the primary domain controller, which is not placed in the primary region. Correct dc01 placement or set enableIdentity to false.'
  : ''
var msg42 = hasInvalidGpoNames
  ? 'GPO names must define non-empty serverAdministration and clientAdministration values so the import script can match the exported backups.'
  : ''

var validationMessage = msg1 != '' ? msg1 : msg2 != '' ? msg2 : msg3 != '' ? msg3 : msg4 != '' ? msg4 : msg5 != '' ? msg5 : msg6 != '' ? msg6 : msg7 != '' ? msg7 : msg8 != '' ? msg8 : msg9 != '' ? msg9 : msg10 != '' ? msg10 : msg11 != '' ? msg11 : msg12 != '' ? msg12 : msg13 != '' ? msg13 : msg14 != '' ? msg14 : msg15 != '' ? msg15 : msg16 != '' ? msg16 : msg17 != '' ? msg17 : msg18 != '' ? msg18 : msg19 != '' ? msg19 : msg20 != '' ? msg20 : msg21 != '' ? msg21 : msg22 != '' ? msg22 : msg23 != '' ? msg23 : msg24 != '' ? msg24 : msg25 != '' ? msg25 : msg26 != '' ? msg26 : msg27 != '' ? msg27 : msg28 != '' ? msg28 : msg29 != '' ? msg29 : msg30 != '' ? msg30 : msg31 != '' ? msg31 : msg32 != '' ? msg32 : msg33 != '' ? msg33 : msg34 != '' ? msg34 : msg35 != '' ? msg35 : msg36 != '' ? msg36 : msg37 != '' ? msg37 : msg38 != '' ? msg38 : msg39 != '' ? msg39 : msg40 != '' ? msg40 : msg41 != '' ? msg41 : msg42 != '' ? msg42 : 'All validation checks passed.'

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
output workloadCapacityByRegion array = workloadCapacityByRegion
output departmentCount int = departmentCount
output usersPerDepartment int = usersPerDepartment
output requestedDirectoryAccounts int = requestedDirectoryAccounts
output invalidExistingRegions array = invalidExistingRegions
output invalidExistingVmPlacementCount int = invalidExistingVmPlacementCount
output hasInvalidExistingVmPlacements bool = hasInvalidExistingVmPlacements
