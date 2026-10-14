targetScope = 'subscription'

// Subscription-scope entry point that orchestrates multi-region networking, security, routing, compute, and identity deployment.
// Responsibilities: build the declared region/VM model, derive stage inputs, evaluate validation,
// and invoke network, compute, and identity modules through their established dependency contracts.
// Consumes: parameter-file intent and manually maintained existing-resource inventories.
// Provides: modeled placement/capacity summaries and validation diagnostics, not live discovery.
// Boundary: resource-specific and guest configuration stay in the owning modules; retained
// VM locations and collection order are preserved throughout the root placement model.

// 1. Parameters

// Deployment control
@description('Deployment stage to execute: network, compute, identity, or all.')
@allowed([
  'all'
  'network'
  'compute'
  'identity'
])
param stage string

@allowed([
  'reportOnly'
  'enforce'
])
@description('Validation behavior: report findings only, or fail the validation gate when blocking findings are active.')
param validationMode string

// Resource metadata
@description('Prefix for all resources')
param prefix string
@description('Tags applied to deployed resources.')
param tags object

// Regions, capacity, and existing inventory
// Inventories are declared by the operator, not discovered from Azure. Keep all retained
// VMs and existing network regions listed so subsequent deployments can reuse them.
@description('Maps region names to their deployment order and address-space index.')
param regionIndexMap object
@description('Number of regions included in this deployment.')
param regionCount int
@description('Maximum number of VMs allowed in each region.')
param maxVmsPerRegion int
@description('Regions with existing VNet infrastructure where networking is reconciled. Route tables and standard subnet associations are deployed or updated; networking in other regions is created from scratch.')
param existingRegions array
@description('Existing VM placement inventory used for brownfield VM reconciliation.')
param existingVmPlacements array = []

// Networking and reconciliation
@description('Network topology mode.')
@allowed([
  'hubSpokeFirewall'
  'hubSpoke'
  'fullMesh'
])
param networkMode string

// Bastion adds an access path; new jumpboxes still receive Public IPs in either mode.
// Disabling Bastion does not add, detach, or remove Public IPs on retained jumpboxes.
@description('Deploy Azure Bastion in the hub region.')
param enableBastion bool
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
@description('Azure Bastion SKU.')
param bastionSku string

// Reconciliation validates and uses this identity only when cleanup is scheduled;
// the parameter itself remains required even for deployments that do not run cleanup.
@description('Resource ID of the User Assigned Managed Identity used by Deployment Scripts.')
param automationManagedIdentityResourceId string

@description('Maps subnet role names to address indexes within each regional VNet.')
param subnetIndexMap object
@description('Public IP ranges allowed to access jumpbox RDP or SSH.')
param jumpboxAllowedSources array

// Compute sizing, images, and lifecycle settings
@description('Requested VM count by logical role.')
param vmCounts object
@description('VM size by logical role.')
param vmSizes object
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

// Administrator credentials and SSH keys
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

// Identity and directory management
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

// File services
@description('Enable departmental file shares, SMB shares, and share permissions.')
param enableFileServices bool

@description('Use a dedicated Windows server for departmental file shares.')
param useDedicatedFileServer bool

// 2. Shared configuration and stage flags

var finalTags = union(tags, {
  project: prefix
})

// A new deployment name supplies a new rerun token to downstream guest automation.
var reconciliationToken = deployment().name
var gpoNames = {
  serverAdministration: 'Server Administration'
  clientAdministration: 'Client Administration'
  windowsLaps: 'Windows LAPS'
}

var deployNetwork = stage == 'network' || stage == 'all'
var deployCompute = stage == 'compute' || stage == 'all'
var deployIdentity = enableIdentity && (stage == 'identity' || stage == 'all')
// Compute owns VM creation. Identity runs also activate missing workload VMs needed
// for domain join, but do not create missing control-plane DCs or jumpboxes.
var deployControl = deployCompute
var deployWorkload = deployCompute || deployIdentity

// 3. Placement model
// Placement is evaluated in the subscription-scope composition root because its results
// drive deployment-time loops, scopes, names, and conditions.

// 3.1 Region ordering
// Indexes define deployment priority and the second address-space octet. Retaining
// their values preserves regional network identities when expanding the region set.
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

// The first selected region is the primary region and later becomes the hub.
var primaryRegion = regionKeys[0]
var isSingleRegion = regionCount == 1

// 3.2 Desired VM identities and missing-VM selection
// Each logical identity is a role code plus a zero-based index. Resource names later
// use index + 1, so { type: 'jmp', index: 0 } becomes <prefix>-jmp01.

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

// Match retained VMs by type and index, not location. Missing identities receive new
// placements; declared existing identities are not relocated or redeployed here.
var existingVmKeys = [
  for vm in existingVmPlacements: '${vm.type}-${string(vm.index)}'
]

var missingVmList = filter(
  vmList,
  vm => !contains(existingVmKeys, '${vm.type}-${string(vm.index)}')
)

// Partition only missing VMs: DCs and jumpboxes use control-plane placement;
// servers and clients use the remaining workload capacity.
var controlPlaneVmList = filter(missingVmList, vm =>
  vm.type == 'dc' || vm.type == 'jmp'
)

var workloadVmList = filter(missingVmList, vm =>
  !(vm.type == 'dc' || vm.type == 'jmp')
)

// New dc01 and jmp01 are pinned to the primary region and excluded from spoke allocation.
// The remaining control-plane VMs are placed first-fit: one spoke is filled to capacity before
// placement continues to the next spoke.
var controlPlanePlacementVmList = filter(controlPlaneVmList, vm =>
  !(vm.type == 'dc' && vm.index == 0) && !(vm.type == 'jmp' && vm.index == 0)
)

// 3.3 Hub, spokes, and existing occupancy

var hubRegion = primaryRegion

// Existing VMs consume capacity before new control-plane or workload VMs are placed.
var spokeRegionKeys = filter(regionKeys, region => region != hubRegion)

var existingVmCountBySpoke = [
  for region in spokeRegionKeys: length(filter(existingVmPlacements, vm => vm.regionKey == region))
]

// 3.4 Control-plane capacity and planned assignments
// Existing occupancy is deducted first. Cumulative capacities map each unpinned
// control-plane ordinal to the first spoke with room, in selected-region order.
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

// This intermediate model reserves spoke capacity before workload placement. Non-control-plane
// entries emit empty markers that match no region and therefore consume no capacity.
// Pinned VMs and control-plane overflow use the hub; this step does not enforce a hub limit.
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

// 3.5 Remaining workload capacity
// Subtract retained VMs and planned control-plane VMs before allocating workload slots.
// This capacity model excludes the hub; single-region placement is handled separately below.
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

// Cumulative boundaries map a workload slot to its spoke. Regions with more remaining
// capacity contribute more slots; this is not equal round-robin allocation across regions.
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

// 3.6 New VM placements
// Apply the same control-plane assignments used above, then map workloads into the
// remaining spoke slots. Only missing VM identities are included in this collection.

var vmPlacements = [
  for (vm, i) in missingVmList: {
    type: vm.type
    index: vm.index
    name: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    regionKey: isSingleRegion
      ? regionKeys[0]

      // The single-region override precedes pinning, workload, and control-plane allocation.

      // Pin newly placed dc01 and jmp01; retained VMs keep their declared regions.
      : (vm.type == 'dc' && vm.index == 0)
        ? primaryRegion

      : (vm.type == 'jmp' && vm.index == 0)
        ? primaryRegion

      // In multi-region deployments, workloads use only spoke capacity slots.
      // Modulo rotates through those slots; when no slots remain, a spoke fallback
      // keeps the model evaluable so validation can report insufficient capacity.
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

// 3.7 Retained and final VM inventory
// Preserve retained locations in active regions and normalize their names. Entries
// outside the active region set are omitted here and reported by validation below.
var existingVmPlacementModels = [
  for vm in filter(existingVmPlacements, vm => contains(regionKeys, vm.regionKey)): {
    type: vm.type
    index: vm.index
    name: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'
    regionKey: vm.regionKey
  }
]

// Retained entries precede new entries. Preserve this order: downstream first(...) target
// selection can depend on it. This is the combined model, not a live Azure inventory.
var finalVmPlacements = concat(
  existingVmPlacementModels,
  vmPlacements
)

// 3.8 Placement validation inputs
// These calculations report invalid inventory and capacity; they do not block by
// themselves. The validation engine classifies findings and the gate enforces them.
var invalidExistingRegions = filter(
  existingRegions,
  region => !contains(regionKeys, region)
)

var invalidExistingVmPlacements = filter(
  existingVmPlacements,
  vm => !contains(regionKeys, vm.regionKey)
)

// Ceiling division estimates the region count required at the configured per-region DC limit.
var maxDcPerRegion = maxVmsPerRegion
var totalDcs = vmCounts.dc
var minRegionsNeededForDcs = (totalDcs + maxDcPerRegion - 1) / maxDcPerRegion
var hasTooManyDcs = minRegionsNeededForDcs > regionCount

// 4. Deployment helper values

// 4.1 Compute configuration and VM collections
// Translate public sizing-role keys (for example, jumpbox/windowsServer) into the
// placement role codes (jmp/srvwin) consumed by compute modules.
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

// VM creation uses new placements only; retained VMs must not be recreated by these loops.
var windowsVMList = filter(vmPlacements, vm =>
  vm.type == 'dc' || vm.type == 'jmp' || vm.type == 'srvwin' || vm.type == 'cliwin'
)

var linuxVMList = filter(vmPlacements, vm =>
  vm.type == 'srvlin' || vm.type == 'clilin'
)

// SSH-key deployment includes retained jumpboxes, unlike the new-VM collections above.
var sshKeyJumpboxPlacements = filter(finalVmPlacements, vm =>
  vm.type == 'jmp'
)

// Passed to compute-stage so it can decide whether jumpbox SSH-key installation is needed.
var hasLinuxVMs = vmCounts.linuxServer > 0 || vmCounts.linuxClient > 0

// 4.2 Network addressing and subnets
var addressPrefixes = [
  for region in regionKeys: '10.${regionIndexMap[region]}.0.0/16'
]

// Each region gets its own /16 (10.<regionIndex>.0.0/16), and each role subnet is a /24 carved
// out of that /16 using its octet from subnetIndexMap (e.g. subnetIndexMap.dc = 2 -> 10.x.2.0/24).
var subnetPrefixesArray = [
  for region in regionKeys: {
    firewall: '10.${regionIndexMap[region]}.${subnetIndexMap.firewall}.0/24'
    bastion:  '10.${regionIndexMap[region]}.${subnetIndexMap.bastion}.0/24'
    jumpbox: '10.${regionIndexMap[region]}.${subnetIndexMap.jumpbox}.0/24'
    dc:      '10.${regionIndexMap[region]}.${subnetIndexMap.dc}.0/24'
    server:  '10.${regionIndexMap[region]}.${subnetIndexMap.server}.0/24'
    client:  '10.${regionIndexMap[region]}.${subnetIndexMap.client}.0/24'
  }
]

// Reserved roles are handled by the network modules. Only other configured keys
// become additional subnets, without inferred role-specific NSG or route-table policy.
var reservedSubnetKeys = [
  'firewall'
  'bastion'
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

// 4.3 Identity and file-service targets
// Target the logical primary DC and replicas from the combined retained/new model.
// Supported configurations require dc01; validation reports invalid DC arrangements.
var primaryDc = first(filter(finalVmPlacements, vm =>
  vm.type == 'dc' && vm.index == 0
))!

var replicaDcList = filter(finalVmPlacements, vm =>
  vm.type == 'dc' && vm.index > 0
)

var fileServerVmList = filter(finalVmPlacements, vm =>
  vm.type == 'srvwin'
)

// Dedicated mode selects the first Windows server in final inventory order. The DC
// fallback keeps evaluation possible when no server exists; validation reports that
// invalid dedicated configuration rather than treating the fallback as a valid target.
var fileServerVm = useDedicatedFileServer && length(fileServerVmList) > 0
  ? fileServerVmList[0]
  : primaryDc

var fileServerName = useDedicatedFileServer
  ? fileServerVm.name
  : primaryDc!.name

// 4.4 DNS candidates from modeled DC regions
// Candidates use declared/planned placement, not live NIC discovery. The network
// modules decide where DNS settings are applied; retained VNet DNS is not repaired here.

// Empty markers from non-DC entries are removed while de-duplicating regions.
var dcPlacements = [
  for vm in finalVmPlacements: vm.type == 'dc' ? vm.regionKey : ''
]

var dcRegions = filter(union(dcPlacements, []), region => !empty(region))

// Keep hub DC first, then append remaining DC regions.
// This preserves deterministic DNS ordering for all VNets.
var orderedDcRegions = concat(
  contains(dcRegions, primaryRegion) ? [primaryRegion] : [],
  filter(dcRegions, r => r != primaryRegion)
)

// .4 is an addressing assumption, not a discovered or statically assigned DC address.
// Verify actual DC IPs and VNet DNS during readiness checks, especially in brownfield labs.
var dnsCandidates = [
  for region in orderedDcRegions: '10.${regionIndexMap[region]}.${subnetIndexMap.dc}.4'
]

// AMRL caps the ordered candidate list at three; this is not an Azure platform-limit claim.
var dnsServers = take(dnsCandidates, 3)

// 5. Module orchestration
// References and dependsOn establish execution dependencies; declaration order alone does not.

// 5.1 Validation engine and enforcement gate
// The engine reports configuration findings. The gate blocks dependent stages only
// when enforcement is enabled and blocking findings exist; advisories do not block.

module validationEngine 'modules/logic/validation.bicep' = {
  name: '${prefix}-validation-engine-${take(deployment().name, 20)}'
  params: {
    validationMode: validationMode
    deployNetwork: deployNetwork
    deployControl: deployControl
    deployWorkload: deployWorkload

    regionIndexMap: regionIndexMap
    regionCount: regionCount
    regionKeys: regionKeys
    primaryRegion: primaryRegion
    hubRegion: hubRegion
    existingRegions: existingRegions
    existingVmPlacements: existingVmPlacements
    vmPlacements: finalVmPlacements
    newVmPlacements: vmPlacements
    invalidExistingRegions: invalidExistingRegions
    invalidExistingVmPlacementCount: length(invalidExistingVmPlacements)

    vmCounts: vmCounts
    maxVmsPerRegion: maxVmsPerRegion
    hasTooManyDcs: hasTooManyDcs
    vmSizes: vmSizes
    osDisks: osDisks
    windowsServerImage: windowsServerImage
    windowsClientImage: windowsClientImage
    ubuntuImage: ubuntuImage

    networkMode: networkMode
    enableBastion: enableBastion
    automationManagedIdentityResourceId: automationManagedIdentityResourceId
    subnetIndexMap: subnetIndexMap
    jumpboxAllowedSources: jumpboxAllowedSources

    enableIdentity: enableIdentity
    domainName: domainName
    gpoNames: gpoNames
    sysAdminDepartment: sysAdminDepartment
    additionalDepartments: additionalDepartments
    departmentCount: departmentCount
    usersPerDepartment: usersPerDepartment

    enableFileServices: enableFileServices
    useDedicatedFileServer: useDedicatedFileServer
    fileServerVmAvailable: length(fileServerVmList) > 0
  }
}

module validationGate 'modules/logic/validation-gate.bicep' = {
  name: '${prefix}-validation-gate-${take(deployment().name, 20)}'

  params: {
    shouldBlockDeployment: validationEngine.outputs.shouldBlockDeployment
    deploymentBlockMessage: validationEngine.outputs.deploymentBlockMessage
  }
}

// 5.2 Network stage
// Owns network creation and bounded peering/Bastion cleanup. Its subnetMap output
// provides per-region subnet IDs for compute; existing network regions must be declared.

module networkStage 'modules/stages/network-stage.bicep' = {
  dependsOn: [
    validationGate
  ]
  name: '${prefix}-network-stage-${take(deployment().name, 20)}'

  params: {
    prefix: prefix
    tags: finalTags

    deployNetwork: deployNetwork

    regionKeys: regionKeys
    hubRegion: hubRegion
    existingRegions: existingRegions

    networkMode: networkMode
    enableBastion: enableBastion
    bastionSku: bastionSku
    automationManagedIdentityResourceId: automationManagedIdentityResourceId

    addressPrefixes: addressPrefixes
    subnetPrefixesArray: subnetPrefixesArray
    additionalSubnetsByRegion: additionalSubnetsByRegion
    dnsServers: dnsServers
    jumpboxSubnets: jumpboxSubnets
    jumpboxAllowedSources: jumpboxAllowedSources
  }
}

// 5.3 Compute stage
// Referencing networkStage.outputs.subnetMap creates the network-to-compute dependency.
// Stage flags select creation groups; retained jumpboxes remain eligible for SSH-key automation.

module computeStage 'modules/stages/compute-stage.bicep' = {
  dependsOn: [
    validationGate
  ]
  name: '${prefix}-compute-stage-${take(deployment().name, 20)}'

  params: {
    prefix: prefix
    finalTags: finalTags
    reconciliationToken: reconciliationToken

    deployControl: deployControl
    deployWorkload: deployWorkload
    deployIdentity: deployIdentity

    windowsVMList: windowsVMList
    linuxVMList: linuxVMList
    sshKeyJumpboxPlacements: sshKeyJumpboxPlacements
    hasLinuxVMs: hasLinuxVMs
    subnetMap: networkStage.outputs.subnetMap

    roleSizingMap: roleSizingMap
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
  }
}

// 5.4 Identity stage
// Wait for compute before guest configuration. Placement targets include retained
// VMs so identity automation can reconcile selected guest state without recreating them.

module identityStage 'modules/stages/identity-stage.bicep' = {
  name: '${prefix}-identity-stage-${take(deployment().name, 20)}'

  dependsOn: [
    validationGate
    computeStage
  ]

  params: {
    prefix: prefix
    reconciliationToken: reconciliationToken

    deployIdentity: deployIdentity
    enableFileServices: enableFileServices

    finalVmPlacements: finalVmPlacements
    primaryDc: primaryDc
    replicaDcList: replicaDcList
    fileServerVm: fileServerVm
    fileServerName: fileServerName

    domainName: domainName
    gpoNames: gpoNames

    sysAdminDepartment: sysAdminDepartment
    additionalDepartments: additionalDepartments
    departmentCount: departmentCount
    usersPerDepartment: usersPerDepartment

    serverAdminUsername: serverAdminUsername
    serverAdminPassword: serverAdminPassword
  }
}

// 6. Deployment outputs

// 6.1 Validation and enforcement
// These outputs describe configuration findings and gate decisions, not live resource
// health, guest readiness, or proof that all reconciliation actions succeeded.
output validationFlags object = validationEngine.outputs.validationFlags
output validationMessage string = validationEngine.outputs.validationMessage
output validationSummary string = empty(validationEngine.outputs.validationMessage)
  ? 'Validation passed.'
  : validationEngine.outputs.validationMessage

output enforcementEnabled bool = validationEngine.outputs.enforcementEnabled
output shouldBlockDeployment bool = validationEngine.outputs.shouldBlockDeployment
output deploymentBlockMessage string = validationEngine.outputs.deploymentBlockMessage
output hasBlockingValidationFailures bool = validationEngine.outputs.hasBlockingValidationFailures
output blockingValidationFlags array = validationEngine.outputs.blockingValidationFlags
output blockingValidationSummary string = validationEngine.outputs.blockingValidationSummary
output blockingValidationDetails array = validationEngine.outputs.blockingValidationDetails
output advisoryValidationFlags array = validationEngine.outputs.advisoryValidationFlags
output advisoryValidationDetails array = validationEngine.outputs.advisoryValidationDetails

// 6.2 Existing inventory and network coverage
// Distinguish invalid declared placements from network inventory missing for planned VMs.
output invalidExistingVmPlacementDetails array = invalidExistingVmPlacements
output invalidExistingVmPlacementCount int = validationEngine.outputs.invalidExistingVmPlacementCount
output hasInvalidExistingVmPlacements bool = validationEngine.outputs.hasInvalidExistingVmPlacements
output networkRegionsMissingFromInventory array = validationEngine.outputs.networkRegionsMissingFromInventory
output newVmRegionsWithoutNetwork array = validationEngine.outputs.newVmRegionsWithoutNetwork

// 6.3 Final placements and regional summaries
// Report the combined model and selected-region order; these are not Azure discovery results.
output vmPlacement array = finalVmPlacements
output selectedRegionsOutput array = regionKeys

output vmCountPerRegion array = [
  for (region, i) in regionKeys: {
    region: region
    count: validationEngine.outputs.vmPerRegionCounts[i]
  }
]

output regionSummary array = [
  for (region, i) in regionKeys: {
    region: region
    addressSpace: addressPrefixes[i]
    subnets: subnetPrefixesArray[i]
    vmCount: length(filter(finalVmPlacements, vm => vm.regionKey == region))
  }
]

// 6.4 Capacity
// Aggregate configured limits and remaining spoke workload slots are different checks;
// use the detailed validation outputs alongside these summaries.
output totalVmRequested int = validationEngine.outputs.totalVMs
output totalCapacityAvailable int = validationEngine.outputs.totalCapacity
output capacityCheck object = {
  totalVMs: validationEngine.outputs.totalVMs
  capacity: validationEngine.outputs.totalCapacity
  withinLimit: validationEngine.outputs.totalVMs <= validationEngine.outputs.totalCapacity
}
output workloadCapacitySummary object = {
  nonControlVmCount: validationEngine.outputs.nonControlVmCount
  totalWorkloadRegionCapacity: validationEngine.outputs.totalWorkloadRegionCapacity
}
output workloadCapacityByRegion array = validationEngine.outputs.workloadCapacityByRegion
