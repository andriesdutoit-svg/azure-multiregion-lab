targetScope = 'subscription'

// ========================================
// MODULE PURPOSE
// Evaluates placement and configuration rules and returns deterministic validation outputs.
// ========================================

// ========================================
// INPUTS
// ========================================

@allowed([
  'reportOnly'
  'enforce'
])
param validationMode string

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
param newVmPlacements array
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
var hasNoDomainControllers = empty(filter(vmPlacements, vm => vm.type == 'dc'))
var hasNoJumpboxes = empty(filter(vmPlacements, vm => vm.type == 'jmp'))
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
  for i in range(1, length(regionIndexMap)): empty(filter(items(regionIndexMap), r => r.value == i))
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

var networkRegionsMissingFromInventory = filter(regionKeys, region => nonNetworkStageDeployed && networkStageSkipped && !contains(existingRegions, region))
var hasMissingNetworkPrerequisites = nonNetworkStageDeployed && !empty(networkRegionsMissingFromInventory)
var networkRegionsMissingFromInventoryText = join(networkRegionsMissingFromInventory, ', ')

var newVmPlacementsForStage = filter(newVmPlacements, vm => (deployControl && (vm.type == 'dc' || vm.type == 'jmp')) || (deployWorkload && !(vm.type == 'dc' || vm.type == 'jmp')))
var newVmRegionsWithoutNetwork = filter(regionKeys, region => !deployNetwork && !contains(existingRegions, region) && !empty(filter(newVmPlacementsForStage, vm => vm.regionKey == region)))

var hasUncoveredNewVmNetworks = !empty(newVmRegionsWithoutNetwork)

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
var hasInvalidGpoNames = enableIdentity && (empty(gpoNames.?serverAdministration) || empty(gpoNames.?clientAdministration) || empty(gpoNames.?windowsLaps))

// ========================================
// VALIDATION FINDING CATALOG
// Each finding owns its flag state, severity, category, and message.
// Blocking findings are defined first, followed by advisory findings.
// ========================================

// Blocking findings.

var blockingValidationFindings = [
  {
    flag: 'invalidMinimums'
    active: invalidMinimums
    severity: 'block'
    category: 'Platform'
    message: 'At least 1 DC and 1 Jumpbox are required.'
    remediation: 'Set vmCounts.dc and vmCounts.jumpbox to at least 1, and inventory any retained instances in existingVmPlacements.'
  }
  {
    flag: 'hasNoDomainControllers'
    active: hasNoDomainControllers
    severity: 'block'
    category: 'Platform'
    message: 'No domain controller is present in the final VM placement model. The Active Directory control plane will be unavailable.'
    remediation: 'Request at least one DC and, for a retained DC, add its valid dc placement to existingVmPlacements in an active region.'
  }
  {
    flag: 'hasNoJumpboxes'
    active: hasNoJumpboxes
    severity: 'block'
    category: 'Platform'
    message: 'No jumpbox is present in the final VM placement model. The environment will have no jumpbox remote-access path.'
    remediation: 'Request at least one jumpbox and, for a retained jumpbox, add its valid jmp placement to existingVmPlacements in an active region.'
  }

  {
    flag: 'invalidRegionCount'
    active: invalidRegionCount
    severity: 'block'
    category: 'Capacity'
    message: 'Region count exceeds available regions.'
    remediation: 'Reduce regionCount to the number of entries in regionIndexMap, or add the required region entries.'
  }
  {
    flag: 'invalidCapacity'
    active: invalidCapacity
    severity: 'block'
    category: 'Capacity'
    message: 'Too many VMs for the allowed capacity per region.'
    remediation: 'Reduce VM counts, add regions, or increase maxVmsPerRegion.'
  }
  {
    flag: 'hasInsufficientWorkloadCapacity'
    active: hasInsufficientWorkloadCapacity
    severity: 'block'
    category: 'Capacity'
    message: 'Insufficient spoke capacity. Requested workload VMs require ${newNonControlVmCount} spoke slots, but only ${totalWorkloadRegionCapacity} remain after DC/jumpbox placement. Reduce VM counts, add regions, or increase maxVmsPerRegion.'
    remediation: 'Reduce workload VM counts, add spoke regions, or increase maxVmsPerRegion.'
  }
  {
    flag: 'hasRegionOverflow'
    active: hasRegionOverflow
    severity: 'block'
    category: 'Capacity'
    message: 'One or more regions exceed the maximum allowed VMs per region.'
    remediation: 'Reduce the VM count in overflowing regions, add regions to redistribute placement, or increase maxVmsPerRegion.'
  }
  {
    flag: 'hasTooManyDcs'
    active: hasTooManyDcs
    severity: 'block'
    category: 'Capacity'
    message: 'Too many DCs for the available regions.'
    remediation: 'Reduce vmCounts.dc, add regions, or increase maxVmsPerRegion so all requested domain controllers can be placed.'
  }

  {
    flag: 'missingRegionIndex'
    active: missingRegionIndex
    severity: 'block'
    category: 'Addressing'
    message: 'One or more regions are missing in regionIndexMap.'
    remediation: 'Add an address index for every selected region in regionIndexMap.'
  }
  {
    flag: 'hasInvalidSubnetIndex'
    active: hasInvalidSubnetIndex
    severity: 'block'
    category: 'Addressing'
    message: 'Subnet index map must include firewall, dc, jumpbox, server, and client.'
    remediation: 'Add all required subnet role keys to subnetIndexMap.'
  }
  {
    flag: 'hasDuplicateRegionIndexes'
    active: hasDuplicateRegionIndexes
    severity: 'block'
    category: 'Addressing'
    message: 'regionIndexMap contains duplicate index values, which would create overlapping VNet address spaces.'
    remediation: 'Assign a unique address index to each region; avoid renumbering deployed regions unless planning the resulting address-space migration.'
  }
  {
    flag: 'hasOutOfBoundsRegionIndex'
    active: hasOutOfBoundsRegionIndex
    severity: 'block'
    category: 'Addressing'
    message: 'regionIndexMap values must be between 1 and 255.'
    remediation: 'Change out-of-range region indexes to unique values between 1 and 255, preserving deployed region indexes where possible.'
  }
  {
    flag: 'hasDuplicateSubnetIndexes'
    active: hasDuplicateSubnetIndexes
    severity: 'block'
    category: 'Addressing'
    message: 'subnetIndexMap contains duplicate index values, which would create overlapping subnet address spaces.'
    remediation: 'Assign a unique subnet index to each subnet role and plan address migration before changing deployed subnet indexes.'
  }
  {
    flag: 'hasOutOfBoundsSubnetIndex'
    active: hasOutOfBoundsSubnetIndex
    severity: 'block'
    category: 'Addressing'
    message: 'subnetIndexMap values must be between 0 and 255.'
    remediation: 'Change out-of-range subnet indexes to values between 0 and 255.'
  }
  {
    flag: 'invalidIndexSequence'
    active: invalidIndexSequence
    severity: 'block'
    category: 'Addressing'
    message: 'Region index map must have continuous values starting at 1.'
    remediation: 'Reassign regionIndexMap values to a continuous sequence from 1 through the number of mapped regions, preserving deployed address assignments where possible.'
  }

  {
    flag: 'hasMissingVmSizeRole'
    active: hasMissingVmSizeRole
    severity: 'block'
    category: 'Compute'
    message: 'vmSizes must include dc, jumpbox, windowsServer, windowsClient, linuxServer, and linuxClient.'
    remediation: 'Add a vmSizes entry for every required VM role.'
  }
  {
    flag: 'hasMissingOsDiskRole'
    active: hasMissingOsDiskRole
    severity: 'block'
    category: 'Compute'
    message: 'osDisks must include dc, jumpbox, windowsServer, windowsClient, linuxServer, and linuxClient.'
    remediation: 'Add an osDisks entry for every required VM role.'
  }
  {
    flag: 'hasEmptyVmSizeRole'
    active: hasEmptyVmSizeRole
    severity: 'block'
    category: 'Compute'
    message: 'vmSizes values must be non-empty for all required roles.'
    remediation: 'Set a non-empty, Azure-supported VM size for every required role.'
  }
  {
    flag: 'hasInvalidOsDiskConfiguration'
    active: hasInvalidOsDiskConfiguration
    severity: 'block'
    category: 'Compute'
    message: 'osDisks entries must include a storageAccountType and a positive diskSizeGB for all required roles.'
    remediation: 'Set a supported storageAccountType and positive diskSizeGB for each required role.'
  }
  {
    flag: 'hasIncompleteImageReference'
    active: hasIncompleteImageReference
    severity: 'block'
    category: 'Compute'
    message: 'Image references must include publisher, offer, sku, and version.'
    remediation: 'Provide non-empty publisher, offer, sku, and version values for each image reference.'
  }

  {
    flag: 'hasInvalidExistingRegions'
    active: length(invalidExistingRegions) > 0
    severity: 'block'
    category: 'Brownfield'
    message: 'existingRegions contains regions that are not selected for the current deployment.'
    remediation: 'Remove stale region entries from existingRegions or include those regions in the active region selection.'
  }
  {
    flag: 'hasInvalidExistingVmPlacements'
    active: hasInvalidExistingVmPlacements
    severity: 'block'
    category: 'Brownfield'
    message: 'existingVmPlacements contains one or more regionKey values that are not present in the active regionKeys set. Remove stale inventory entries or include the missing regions in regionIndexMap.'
    remediation: 'Correct each regionKey to an active region, or add the VM region to regionIndexMap and increase regionCount as needed.'
  }
  {
    flag: 'hasDuplicateExistingRegions'
    active: hasDuplicateExistingRegions
    severity: 'block'
    category: 'Brownfield'
    message: 'existingRegions contains duplicate region entries.'
    remediation: 'Remove duplicate region names from existingRegions.'
  }
  {
    flag: 'hasDuplicateExistingVmPlacements'
    active: hasDuplicateExistingVmPlacements
    severity: 'block'
    category: 'Brownfield'
    message: 'existingVmPlacements contains duplicate type and index entries.'
    remediation: 'Keep only one existingVmPlacements entry for each VM type and index.'
  }
  {
    flag: 'hasUnsupportedExistingVmType'
    active: hasUnsupportedExistingVmType
    severity: 'block'
    category: 'Brownfield'
    message: 'existingVmPlacements contains an unsupported VM type.'
    remediation: 'Use one of the supported VM types: dc, jmp, srvwin, cliwin, srvlin, or clilin; remove entries for other types.'
  }
  {
    flag: 'hasInvalidExistingVmIndex'
    active: hasInvalidExistingVmIndex
    severity: 'block'
    category: 'Brownfield'
    message: 'existingVmPlacements contains an index outside the requested vmCounts range.'
    remediation: 'Increase the corresponding vmCounts value to include the retained VM index, or remove the stale inventory entry.'
  }

  {
    flag: 'invalidDedicatedFileServerConfiguration'
    active: invalidDedicatedFileServerConfiguration
    severity: 'block'
    category: 'FileServices'
    message: 'useDedicatedFileServer cannot be true when enableFileServices is false.'
    remediation: 'Enable file services or set useDedicatedFileServer to false.'
  }
  {
    flag: 'invalidFileServicesIdentityConfiguration'
    active: invalidFileServicesIdentityConfiguration
    severity: 'block'
    category: 'FileServices'
    message: 'enableIdentity must be true when enableFileServices or useDedicatedFileServer is true. File services depend on Active Directory users and groups.'
    remediation: 'Enable identity or disable file services and dedicated file-server mode.'
  }
]

// ========================================
// ADVISORY VALIDATION FINDINGS
// Non-blocking validation findings that
// provide design and operational guidance.
// ========================================

var advisoryValidationFindings = [
  {
    flag: 'invalidPrimaryPinning'
    active: invalidPrimaryPinning
    severity: 'advisory'
    category: 'Placement'
    message: 'Primary pinning failed: dc01 and jmp01 must be placed in the primary region.'
    remediation: 'Correct existingVmPlacements so retained dc01 and jmp01 are in the primary region; otherwise let the placement model assign them there.'
  }
  {
    flag: 'hasNonControlInHub'
    active: hasNonControlInHub
    severity: 'advisory'
    category: 'Placement'
    message: 'One or more non-control VMs were placed in the hub region.'
    remediation: 'Move retained workload VMs to a spoke and update existingVmPlacements; keep workload placements out of the hub.'
  }
  {
    flag: 'invalidDepartmentCount'
    active: invalidDepartmentCount
    severity: 'advisory'
    category: 'Identity'
    message: 'Department count exceeds the number of available mandatory and additional departments.'
    remediation: 'Reduce departmentCount or add enough department definitions to sysAdminDepartment and additionalDepartments.'
  }
  {
    flag: 'invalidMinimumDepartments'
    active: invalidMinimumDepartments
    severity: 'advisory'
    category: 'Identity'
    message: 'At least one department is required.'
    remediation: 'Set departmentCount to include every required system-administration department.'
  }
  {
    flag: 'invalidUsersPerDepartment'
    active: invalidUsersPerDepartment
    severity: 'advisory'
    category: 'Identity'
    message: 'Users per department must be at least 1.'
    remediation: 'Set usersPerDepartment to 1 or greater.'
  }
  {
    flag: 'duplicateDepartmentCodes'
    active: duplicateDepartmentCodes
    severity: 'advisory'
    category: 'Identity'
    message: 'Department codes must be unique.'
    remediation: 'Assign a unique code to every department across sysAdminDepartment and additionalDepartments.'
  }
  {
    flag: 'hasMissingNetworkPrerequisites'
    active: hasMissingNetworkPrerequisites
    severity: 'advisory'
    category: 'Brownfield'
    message: 'Network prerequisites are not declared for all selected regions during compute/identity deployment. Missing from existingRegions: ${networkRegionsMissingFromInventoryText}. Deploy stage=network first, or add the regions to existingRegions only if their networking already exists.'
    remediation: 'Run stage=network before compute/identity, or add each missing region to existingRegions only after confirming its VNet and required subnets already exist.'
  }
  {
    flag: 'hubRequiredButMissing'
    active: hubRequiredButMissing
    severity: 'advisory'
    category: 'Brownfield'
    message: 'Hub region is required but not available. Either deploy stage=network or add hub region to existingRegions.'
    remediation: 'Run stage=network or include the hub in existingRegions after confirming its networking exists.'
  }
  {
    flag: 'spokeRegionsNotCovered'
    active: !spokeRegionsCovered
    severity: 'advisory'
    category: 'Brownfield'
    message: 'One or more spoke regions are not available. Either deploy stage=network or add all spoke regions to existingRegions.'
    remediation: 'Run stage=network or include every existing spoke in existingRegions after confirming its networking exists.'
  }
  {
    flag: 'hasMixedCreationMode'
    active: hasMixedCreationMode
    severity: 'advisory'
    category: 'Brownfield'
    message: 'Mixing greenfield (create) and brownfield (reuse) regions in same deployment. Ensure consistent creation mode across all regions.'
    remediation: 'Check existingRegions against Azure: list every region whose networking already exists and omit regions intended for network creation.'
  }
  {
    flag: 'missingDedicatedFileServer'
    active: missingDedicatedFileServer
    severity: 'advisory'
    category: 'FileServices'
    message: 'useDedicatedFileServer is true but no srvwin virtual machine exists. Add a Windows server (vmCounts.windowsServer) or set useDedicatedFileServer to false.'
    remediation: 'Add or retain at least one srvwin VM, or disable dedicated file-server mode.'
  }
  {
    flag: 'hasInvalidPeeringCleanupIdentity'
    active: hasInvalidPeeringCleanupIdentity
    severity: 'advisory'
    category: 'Operations'
    message: 'automationManagedIdentityResourceId must be a User Assigned Managed Identity resource ID when brownfield peering cleanup is applicable.'
    remediation: 'Provide the resource ID of a User Assigned Managed Identity with the required subscription-scope Network Contributor role.'
  }
  {
    flag: 'hasMalformedDomainName'
    active: hasMalformedDomainName
    severity: 'advisory'
    category: 'GroupPolicy'
    message: 'domainName must be a multi-label DNS name (for example amrl.lab) without spaces, slashes, or @. Group Policy provisioning derives the domain DN and the SYSVOL path to Groups.xml from this value.'
    remediation: 'Set domainName to a valid multi-label DNS name such as amrl.lab.'
  }
  {
    flag: 'hasEmptySysAdminDepartmentCode'
    active: hasEmptySysAdminDepartmentCode
    severity: 'advisory'
    category: 'GroupPolicy'
    message: 'sysAdminDepartment must define a non-empty department code. Group Policy provisioning resolves the Windows admins group that directory population creates from this code.'
    remediation: 'Add a non-empty department code to sysAdminDepartment.'
  }
  {
    flag: 'hasNoGpoTargetDc'
    active: hasNoGpoTargetDc
    severity: 'advisory'
    category: 'GroupPolicy'
    message: 'Group Policy provisioning runs on the primary domain controller, which is not placed in the primary region. Correct dc01 placement or set enableIdentity to false.'
    remediation: 'Pin dc01 to the primary region in existingVmPlacements, or enable identity only when a primary-DC target is available.'
  }
  {
    flag: 'hasInvalidGpoNames'
    active: hasInvalidGpoNames
    severity: 'advisory'
    category: 'GroupPolicy'
    message: 'GPO names must define non-empty serverAdministration, clientAdministration, and windowsLaps values so the import script can match the exported backups.'
    remediation: 'Set all three gpoNames values to the corresponding display names in the exported GPO backups.'
  }
    {
    flag: 'hasUnsafeJumpboxAllowedSources'
    active: hasUnsafeJumpboxAllowedSources
    severity: 'advisory'
    category: 'Security'
    message: 'jumpboxAllowedSources is empty or contains 0.0.0.0/0. Remote access is broadly exposed and should be reviewed.'
    remediation: 'Specify trusted source CIDRs and remove 0.0.0.0/0.'
  }
  {
    flag: 'hasUncoveredNewVmNetworks'
    active: hasUncoveredNewVmNetworks
    severity: 'advisory'
    category: 'Networking'
    message: 'One or more virtual machines are assigned to regions that do not have corresponding network resources.'
    remediation: 'Run stage=network before creating the VMs, or include the regions in existingRegions only if their required networking already exists.'
  }
]

var blockingValidationDetails = map(
  activeBlockingValidationFindings,
  item => {
    category: item.category
    flag: item.flag
    message: item.message
    remediation: item.remediation
  }
)

var validationFindings = concat(
  blockingValidationFindings,
  advisoryValidationFindings
)

// Derive the public Boolean flag object from the complete finding catalog.
var validationFlags = toObject(
  validationFindings,
  item => item.flag,
  item => item.active
)

// Select active findings and derive the overall validation message and severity summaries.
var activeValidationFindings = filter(
  validationFindings,
  item => item.active
)

// The primary validation message is the first active finding
// in catalog order. Blocking findings are evaluated before
// advisory findings because validationFindings is assembled
// as blockingValidationFindings followed by advisoryValidationFindings.

var validationMessage = empty(activeValidationFindings)
  ? 'All validation checks passed.'
  : activeValidationFindings[0].message

var activeBlockingValidationFindings = filter(
  validationFindings,
  item => item.active && item.severity == 'block'
)

var activeAdvisoryValidationFindings = filter(
  validationFindings,
  item => item.active && item.severity == 'advisory'
)

var advisoryValidationFlags = map(
  activeAdvisoryValidationFindings,
  item => item.flag
)

var advisoryValidationDetails = map(
  activeAdvisoryValidationFindings,
  item => {
    category: item.category
    flag: item.flag
    message: item.message
    remediation: item.remediation
  }
)

var blockingValidationFlags = map(
  activeBlockingValidationFindings,
  item => item.flag
)

var hasBlockingValidationFailures = !empty(blockingValidationFlags)

var blockingValidationSummary = empty(blockingValidationFlags)
  ? 'No blocking validation failures detected.'
  : 'Blocking validation failures detected: ${join(blockingValidationFlags, ', ')}'

// ========================================
// ENFORCEMENT MODE DECISION
// Combine blocking findings with validationMode to determine
// whether the deployment gate should fail.
// ========================================

var enforcementEnabled = validationMode == 'enforce'

var shouldBlockDeployment = enforcementEnabled && hasBlockingValidationFailures

var deploymentBlockMessage = shouldBlockDeployment
  ? 'Deployment blocked by validation enforcement. ${length(activeBlockingValidationFindings)} blocking validation finding(s) detected. Review blockingValidationDetails for full diagnostics.'
  : 'Deployment not blocked.'

// ========================================
// OUTPUTS
// ========================================

// Validation findings and deployment enforcement outputs.

output validationFlags object = validationFlags
output validationMessage string = validationMessage

output hasBlockingValidationFailures bool = hasBlockingValidationFailures
output blockingValidationFlags array = blockingValidationFlags
output enforcementEnabled bool = enforcementEnabled
output shouldBlockDeployment bool = shouldBlockDeployment
output deploymentBlockMessage string = deploymentBlockMessage
output blockingValidationSummary string = blockingValidationSummary
output blockingValidationDetails array = blockingValidationDetails
output advisoryValidationFlags array = advisoryValidationFlags
output advisoryValidationDetails array = advisoryValidationDetails

// Capacity and placement summaries.
output totalVMs int = totalVMs
output totalCapacity int = totalCapacity
output vmPerRegionCounts array = vmPerRegionCounts
output nonControlVmCount int = nonControlVmCount
output totalWorkloadRegionCapacity int = totalWorkloadRegionCapacity
output workloadCapacityByRegion array = workloadCapacityByRegion

// Identity population metrics.
output departmentCount int = departmentCount
output usersPerDepartment int = usersPerDepartment
output requestedDirectoryAccounts int = requestedDirectoryAccounts

// Brownfield inventory and network diagnostics.
output invalidExistingRegions array = invalidExistingRegions
output invalidExistingVmPlacementCount int = invalidExistingVmPlacementCount
output hasInvalidExistingVmPlacements bool = hasInvalidExistingVmPlacements
output networkRegionsMissingFromInventory array = networkRegionsMissingFromInventory
output newVmRegionsWithoutNetwork array = newVmRegionsWithoutNetwork
