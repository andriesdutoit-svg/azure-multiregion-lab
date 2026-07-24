targetScope = 'subscription'

// Controls when resources deploy.
@allowed([
  'network'
  'control'
  'identity'
  'workload'
  'all'
])
param stage string

// ========================================
// MODULE PURPOSE
// Subscription-scope orchestrator for multi-region networking, security, routing, and VM deployment.
// ========================================

// ========================================
// CONFIGURATION INPUTS
// ========================================

// ----
// Regional & Deployment Configuration
// ----
param regionIndexMap object
param regionCount int
param maxVmsPerRegion int
@description('Regions where VNets, NSGs, subnets, and route tables already exist and should be reused. Resources in listed regions are reused; resources in other regions are created (greenfield).')
param existingRegions array

// ----
// Networking Configuration
// ----
param subnetIndexMap object
param jumpboxAllowedSources array
param enableClientSsh bool

// ----
// Compute: VM Sizing & Images
// ----
param vmCounts object
// Role-based VM size map keyed by logical workload roles.
param vmSizes object
// Role-based OS disk map (storage SKU + disk size) keyed by logical workload roles.
param osDisks object
param windowsServerImage object
param windowsClientImage object
param ubuntuImage object
param vmAutoDeleteOptions object

// ----
// Admin Credentials & Access
// ----
param jumpboxAdminUsername string
@secure()
param jumpboxAdminPassword string
param serverAdminUsername string
@secure()
param serverAdminPassword string
param clientAdminUsername string
@secure()
param clientAdminPassword string
param sshPublicKey string
@secure()
param sshPrivateKey string

// ----
// Identity & Directory Management
// ----
param enableIdentity bool
param domainName string
param sysAdminDepartment object
param additionalDepartments object
param departmentCount int
param usersPerDepartment int

// ----
// Tagging & Resource Identification
// ----
@description('Prefix for all resources')
param prefix string
param tags object

var reconciliationToken = deployment().name

// ========================================
// STAGE FLAGS
// Determines which deployment stages execute during this run
// ========================================

var deployNetwork = stage == 'network' || stage == 'all'
var deployControl = stage == 'control' || stage == 'all'
// Identity bootstrap is currently not an independent first-run stage.
// It assumes control-plane Windows DC resources are already present (or stage=all is used).
var deployIdentity = enableIdentity && (stage == 'identity' || stage == 'all')
var deployWorkload = stage == 'workload' || stage == 'all'

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

//
// ========================================
// REGION ORDERING (Index-Based Sorting)
// Converts regionIndexMap to an ordered region list
// ========================================
//

// Extract regions in order of their index value (1 to N)
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

var invalidExistingRegions = filter(
  existingRegions,
  region => !contains(regionKeys, region)
)

// Split the unified VM model into control-plane and workload sets.
// Placement uses different rules for these two groups.
var controlPlaneVmList = filter(vmList, vm =>
  vm.type == 'dc' || vm.type == 'jmp'
)

var workloadVmList = filter(vmList, vm =>
  !(vm.type == 'dc' || vm.type == 'jmp')
)

// Pinned primary-region control-plane VMs are excluded from control-plane round-robin placement.
var roundRobinControlPlaneVmList = filter(controlPlaneVmList, vm =>
  !(vm.type == 'dc' && vm.index == 0) && !(vm.type == 'jmp' && vm.index == 0)
)

// Track control-plane and workload positions independently.
// This prevents workload placement from inheriting offsets created by DC/jumpbox placement.
var roundRobinControlPlaneVmIndexList = [
  for vm in vmList: !(vm.type == 'dc' || vm.type == 'jmp')
    ? -1
    : (vm.type == 'dc' && vm.index == 0) || (vm.type == 'jmp' && vm.index == 0)
      ? -1
      : indexOf(roundRobinControlPlaneVmList, vm)
]

var workloadVmIndexList = [
  for vm in vmList: vm.type == 'dc' || vm.type == 'jmp'
    ? -1
    : indexOf(workloadVmList, vm)
]

// ========================================
// HUB MODEL
// ========================================

var hubRegion = primaryRegion

// Place control-plane VMs first so workload placement can see how much spoke capacity remains.
// Non-control VMs never use hub capacity.
var controlPlanePlacements = [
  for (vm, i) in vmList: !(vm.type == 'dc' || vm.type == 'jmp') ? {
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
        : roundRobinControlPlaneVmIndexList[i] < (regionCount - 1)
        ? regionKeys[(roundRobinControlPlaneVmIndexList[i] % (regionCount - 1)) + 1]
      : regionKeys[roundRobinControlPlaneVmIndexList[i] % regionCount]
  }
]

// Model remaining spoke capacity after control-plane placement.
// Workloads are then mapped to the first spoke whose cumulative remaining capacity contains the workload ordinal.
// This avoids overfilling spokes that already consumed capacity with DC/jumpbox placements.
var workloadRegionCapacity = [
  for region in filter(regionKeys, candidate => candidate != hubRegion): {
    region: region
    remainingCapacity: maxVmsPerRegion > length(filter(controlPlanePlacements, vm => vm.regionKey == region))
      ? maxVmsPerRegion - length(filter(controlPlanePlacements, vm => vm.regionKey == region))
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
  for (vm, i) in vmList: {
    type: vm.type
    index: vm.index
    name: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'
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

      // Workloads NEVER go to hub and only consume remaining spoke capacity slots.
      // Workload placement uses modulo (%) to distribute across available slots fairly,
      // avoiding concentration in a single spoke if capacity allows distribution.
      : !(vm.type == 'dc' || vm.type == 'jmp')
        ? totalWorkloadRegionCapacity > 0
          ? first(filter(
              workloadRegionCapacityCumulative,
              slot => slot.remainingCapacity > 0 && ((workloadVmIndexList[i] % totalWorkloadRegionCapacity) < slot.cumulativeCapacity)
            )).?region ?? regionKeys[1]
          : regionKeys[1]

      // DC/JMP prefer spokes first: round-robin across non-hub regions until spokes exhaust.
      // (regionCount - 1) excludes hub from round-robin; index + 1 shifts to spoke range [1..N-1].
        : roundRobinControlPlaneVmIndexList[i] < (regionCount - 1)
        ? regionKeys[(roundRobinControlPlaneVmIndexList[i] % (regionCount - 1)) + 1]

      // Once the first spoke pass is exhausted, additional control-plane VMs may use the hub.
      // Full modulo wraps across all regions, allowing hub placement on overflow.
      : regionKeys[roundRobinControlPlaneVmIndexList[i] % regionCount]
  }
]

var maxDcPerRegion = maxVmsPerRegion
var totalDcs = vmCounts.dc
var minRegionsNeededForDcs = (totalDcs + maxDcPerRegion - 1) / maxDcPerRegion
var hasTooManyDcs = minRegionsNeededForDcs > regionCount

var primaryDc = first(filter(vmPlacements, vm =>
  vm.type == 'dc' && vm.index == 0
))

var replicaDcList = filter(vmPlacements, vm =>
  vm.type == 'dc' && vm.index > 0
)

// ========================================
// VM GROUPING + SUPPORT VARIABLES
// ========================================

var finalTags = union(tags, {
  project: prefix
})

// ========================================
// COMPUTE HELPER VARIABLES
// ========================================

// Maps deployment VM role keys to their role-specific compute settings.
// Keys match vm.type values used by the placement engine: dc, jmp, srvwin, cliwin, srvlin, clilin.
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
    firewall: '10.${regionIndexMap[region]}.${subnetIndexMap.firewall}.0/24'
    jumpbox: '10.${regionIndexMap[region]}.${subnetIndexMap.jumpbox}.0/24'
    dc:      '10.${regionIndexMap[region]}.${subnetIndexMap.dc}.0/24'
    server:  '10.${regionIndexMap[region]}.${subnetIndexMap.server}.0/24'
    client:  '10.${regionIndexMap[region]}.${subnetIndexMap.client}.0/24'
  }
]

// ----
// DNS configuration: derived from actual DC placements
// ----
// DNS servers are dynamically derived from DC placement positions, not static configuration.
// This ensures VNets point to DCs that actually exist in the deployment.
//
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

// Build candidate DNS server IPs from the DC subnet's fourth IP (.4) in each ordered DC region.
// .4 is the 4th usable IP in the /24 subnet (after .0, .1, .2, .3 reserved by Azure).
// This derives DNS from where DCs are actually placed, rather than from static region assumptions.
var dnsCandidates = [
  for region in orderedDcRegions: '10.${regionIndexMap[region]}.${subnetIndexMap.dc}.4'
]

// Each VNet supports up to 3 custom DNS servers; limit to avoid waste.
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
  name: '${prefix}-validation-engine-${take(deployment().name, 20)}'
  params: {
    vmCounts: vmCounts
    vmSizes: vmSizes
    osDisks: osDisks
    regionCount: regionCount
    regionIndexMap: regionIndexMap
    subnetIndexMap: subnetIndexMap
    vmPlacements: vmPlacements
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
    deployNetwork: deployNetwork
    deployControl: deployControl
    deployWorkload: deployWorkload
    existingRegions: existingRegions
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

    name: '${prefix}-vnet-${region}'

    scope: resourceGroup('${prefix}-rg-${region}')

    dependsOn: [
      rgs
    ]

    params: {
      vnetName: '${prefix}-vnet-${region}'
      location: region
      isHub: region == hubRegion

      existingRegions: existingRegions

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
    name: '${prefix}-peerings-${source}'
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
  name: '${prefix}-firewall-${hubRegion}'

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

// Suppressions in this module are intentional: BCP318 appears because vnet/firewall outputs are conditionally evaluated
// by the analyser in this loop, and no-unnecessary-dependson is kept to enforce firewall-before-route-table ordering
// that helps avoid Azure concurrent network update conflicts during subnet route association.

module routeTables 'modules/networking/routeTable.bicep' = [
  for (region, i) in regionKeys: if (deployNetwork && region != hubRegion) {

    name: '${prefix}-rt-${region}'
    scope: resourceGroup('${prefix}-rg-${region}')

    dependsOn: [
      #disable-next-line no-unnecessary-dependson
      firewall
      vnets[i]
    ]

    params: {
      location: region

      #disable-next-line BCP318
      serverSubnetId: vnets[i].outputs.subnets.server.id

      #disable-next-line BCP318
      clientSubnetId: vnets[i].outputs.subnets.client.id

      #disable-next-line BCP318
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

var deployIdentityTargets = deployWorkload || deployIdentity


var activeWindowsVMs = concat(
  deployControl ? controlWindowsVMs : [],
  deployIdentityTargets ? workloadWindowsVMs : []
)

var activeJumpboxVMs = filter(activeWindowsVMs, vm =>
  vm.type == 'jmp'
)

// ------------------------------
// Windows VM Module Deployment
// ------------------------------

module windowsVMs 'modules/compute/vm-windows.bicep' = [
  for (vm, i) in activeWindowsVMs: {
    name: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      vnets
      routeTables
    ]

    params: {
      vmName: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'
      // Resolve compute sizing from the role map so each VM role can scale independently.
      vmSize: roleSizingMap[vm.type].vmSize

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
      
      // BCP318 suppressions below are intentional: subnet outputs are resolved by VM type at runtime,
      // but the static analyser cannot always prove the selected branch is non-null in this conditional chain.
      // Role-to-subnet mapping: DC→dc subnet, JMP→jumpbox subnet, Windows servers→server subnet, clients→client subnet.
      // Each role has a dedicated subnet enforcing network segmentation and security group policies.
      subnetId: vm.type == 'dc'
        #disable-next-line BCP318
        ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.dc.id
        : vm.type == 'jmp'
          #disable-next-line BCP318
          ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.jumpbox.id
          : vm.type == 'srvwin'
            #disable-next-line BCP318
            ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.server.id
            #disable-next-line BCP318
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

      // Resolve OS disk profile per role (SKU + capacity).
      osDisk: roleSizingMap[vm.type].osDisk

      vmAutoDeleteOptions: vmAutoDeleteOptions
    }
  }
]

// ========================================
// DEPLOYMENT STAGE 7: IDENTITY BOOTSTRAP (PRIMARY DC)
// ========================================

var directoryModel = {
  preventOuDeletion: false

  rootOuName: '_ROOT'

  customOus: [
    'Computers'
    'Computers/Servers'
    'Computers/Clients'
    'Groups'
    'Groups/GGS'
    'Groups/DLGS'
    'Users'
    'Users/Disabled'
  ]

  computerOuMapping: {
    srvwin: 'Computers/Servers'
    srvlin: 'Computers/Servers'
    cliwin: 'Computers/Clients'
    clilin: 'Computers/Clients'
  }

  groupOuMapping: {
    globalSecurity: 'Groups/GGS'
    domainLocalSecurity: 'Groups/DLGS'
  }

  groupNaming: {
    globalSecurityPrefix: 'GGS'
    domainLocalSecurityPrefix: 'DLGS'
  }

  platformAdminGroups: {
    windowsAdmins: 'Windows_Admins'
    linuxAdmins: 'Linux_Admins'
    sourceDepartmentCode: first(items(sysAdminDepartment))!.value
  }

  shares: {
    root: {
      name: 'Shares'
      path: 'C:\\Shares'
    }
  }

  coreOuMapping: {
    users: 'Users'
    groups: 'Groups'
  }
}

module adForest 'modules/identity/ad-forest.bicep' = if (deployIdentity) {
  name: '${prefix}-ad-forest'
  scope: resourceGroup('${prefix}-rg-${primaryDc!.regionKey}')

  // The bootstrap command must run after the target Windows DC VM exists.
  // In staged workflows, run control before identity.
  dependsOn: [
    windowsVMs
  ]
  params: {
    dcVmName: primaryDc!.name
    domainName: domainName
    serverAdminPassword: serverAdminPassword
    reconciliationToken: reconciliationToken
  }
}

module replicaDcs 'modules/identity/ad-replicadc.bicep' = [
  for dc in replicaDcList: if (deployIdentity) {
    name: '${prefix}-replica-${dc.index + 1}'

    scope: resourceGroup('${prefix}-rg-${dc.regionKey}')

    dependsOn: [
      adForest
    ]

    params: {
      dcVmName: dc.name
      domainName: domainName
      serverAdminUsername: serverAdminUsername
      serverAdminPassword: serverAdminPassword
      reconciliationToken: reconciliationToken
    }
  }
]

module adPopulate 'modules/identity/ad-populate.bicep' = if (deployIdentity) {
  name: '${prefix}-ad-populate'

  scope: resourceGroup('${prefix}-rg-${primaryDc!.regionKey}')

  dependsOn: [
    adForest
    replicaDcs
  ]

  params: {
    dcVmName: primaryDc!.name
    domainName: domainName
    usersPerDepartment: usersPerDepartment
    sysAdminDepartment: sysAdminDepartment
    additionalDepartments: additionalDepartments
    clientAdminPassword: clientAdminPassword
    departmentCount: departmentCount
    directoryModel: string(directoryModel)
    reconciliationToken: reconciliationToken
  }
}

// ========================================
// DEPLOYMENT STAGE 7b: WINDOWS DOMAIN JOIN
// Joins Windows servers (srvwin) and clients (cliwin) to the AD domain.
// Runs after directory population. OU placement is driven by VM type via the directory model.
// Participates in the reconciliation model: existing domain membership is detected and skipped.
// ========================================

module domainJoinWindows 'modules/identity/domain-join.bicep' = [
  for vm in filter(activeWindowsVMs, vm => vm.type == 'srvwin' || vm.type == 'cliwin'): if (deployIdentity) {
    name: '${prefix}-domainjoin-${vm.name}'
    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      adPopulate
    ]

    params: {
      vmName: vm.name
      domainName: domainName
      directoryModel: string(directoryModel)
      vmType: vm.type
      serverAdminUsername: serverAdminUsername
      serverAdminPassword: serverAdminPassword
      reconciliationToken: reconciliationToken
    }
  }
]

// ========================================
// DEPLOYMENT STAGE 8: LINUX VMS
// ========================================

// Same ordering guarantee as Windows VMs: network pathing is established first.

var activeLinuxVMs = deployIdentityTargets
  ? linuxVMList
  : []

module linuxVMs 'modules/compute/vm-linux.bicep' = [
  for vm in activeLinuxVMs: {
    name: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      vnets
      routeTables
    ]

    params: {
      vmName: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'
      // Resolve compute sizing from the role map so each VM role can scale independently.
      vmSize: roleSizingMap[vm.type].vmSize

      adminUsername: vm.type == 'srvlin' ? serverAdminUsername : clientAdminUsername
      sshPublicKey: sshPublicKey

      // Role-to-subnet mapping for Linux VMs: srvlin→server subnet, clilin→client subnet.
      // Each role has a dedicated subnet enforcing network segmentation and security group policies.
      // BCP318 suppressions below are intentional: subnet output selection is conditional by VM type,
      // and the static analyser treats these indexed outputs as potentially nullable.
      subnetId: vm.type == 'srvlin'
        #disable-next-line BCP318
        ? vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.server.id
        #disable-next-line BCP318
        : vnets[indexOf(regionKeys, vm.regionKey)].outputs.subnets.client.id

      assignPublicIp: false

      tags: union(finalTags, {
        role: vm.type == 'srvlin' ? 'server' : 'client'
      })

      image: ubuntuImage
      // Resolve OS disk profile per role (SKU + capacity).
      osDisk: roleSizingMap[vm.type].osDisk

      vmAutoDeleteOptions: vmAutoDeleteOptions
    }
  }
]

var hasLinuxVMs = vmCounts.linuxServer > 0 || vmCounts.linuxClient > 0

var jumpboxLinuxSshKeyVMs = hasLinuxVMs ? filter(controlWindowsVMs, item => item.type == 'jmp') : []

module installJumpboxSshKey 'modules/identity/ssh-key.bicep' = [
  for vm in jumpboxLinuxSshKeyVMs: {
    name: '${prefix}-sshkey-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      windowsVMs
      linuxVMs
    ]

    params: {
      vmName: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

      adminUsername: jumpboxAdminUsername

      sshPrivateKey: sshPrivateKey

      reconciliationToken: reconciliationToken
    }
  }
]

// ========================================
// DEPLOYMENT STAGE 8b: LINUX DOMAIN JOIN
// Joins Linux servers (srvlin) and clients (clilin) to the AD domain using realmd/SSSD integration.
// Runs after directory population. OU placement is driven by VM type via the directory model.
// Participates in the reconciliation model: existing domain membership is detected and skipped.
// ========================================

module domainJoinLinux 'modules/identity/domain-join-linux.bicep' = [
  for vm in filter(activeLinuxVMs, vm => vm.type == 'srvlin' || vm.type == 'clilin'): if (deployIdentity) {
    name: '${prefix}-domainjoin-${vm.name}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      adPopulate
    ]

    params: {
      vmName: vm.name
      domainName: domainName
      directoryModel: string(directoryModel)
      vmType: vm.type
      serverAdminUsername: serverAdminUsername
      serverAdminPassword: serverAdminPassword
      reconciliationToken: reconciliationToken
    }
  }
]

// ========================================
// OUTPUTS: PLACEMENT, VALIDATION, CAPACITY, REGIONAL SUMMARY
// ========================================

// List of regions selected for this deployment (ordered by regionIndexMap) and assigned region
// This is the primary output used to verify distribution logic
output vmPlacement array = vmPlacements

// Validation message describing the first detected validation issue, or a success message when all checks pass.

output validationDebug object = validationEngine.outputs.validationFlags
output validationCapacityDebug object = {
  nonControlVmCount: validationEngine.outputs.nonControlVmCount
  totalWorkloadRegionCapacity: validationEngine.outputs.totalWorkloadRegionCapacity
}
output validationWorkloadCapacityDebug array = validationEngine.outputs.workloadCapacityDebug
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
