targetScope = 'subscription'

// ========================================
// COMPUTE STAGE
//
// Responsibilities:
// - Windows VM deployment
// - Linux VM deployment
// - Jumpbox SSH key deployment
//
// Consumes:
// - Placement results
// - Deployment-stage flags
// - Compute configuration
// - subnetMap (from network-stage)
//
// Provides:
// - VM infrastructure required by identity-stage
// ========================================

// Stage inputs:
//
// deployControl and deployWorkload select the VM groups created by the public compute stage.
// deployIdentity allows identity-stage runs to create workload VMs needed for domain join.
// deployIdentity
//
// windowsVMList
// linuxVMList
//
// roleSizingMap
//
// finalTags
//
// windowsServerImage
// windowsClientImage
// ubuntuImage
//
// vmAutoDeleteOptions
//
// jumpboxAdminUsername
// jumpboxAdminPassword
//
// serverAdminUsername
// serverAdminPassword
//
// clientAdminUsername
// clientAdminPassword
//
// sshPublicKey
// sshPrivateKey
//
// Network Contract:
//
// subnet IDs for:
// - dc
// - jumpbox
// - server
// - client

// Internal responsibilities:
//
// controlWindowsVMs
// workloadWindowsVMs
// deployIdentityTargets
// activeWindowsVMs
//
// activeLinuxVMs
//
// hasLinuxVMs
// jumpboxLinuxSshKeyVMs
//
// windowsVMs
// linuxVMs
// installJumpboxSshKey

//
// Networking contract:
// - dc subnet ID
// - jumpbox subnet ID
// - server subnet ID
// - client subnet ID

param prefix string

param reconciliationToken string

// Deployment control
param deployControl bool
param deployWorkload bool
param deployIdentity bool

// Placement results
param windowsVMList array
param linuxVMList array
param hasLinuxVMs bool

// Compute configuration
param roleSizingMap object
param finalTags object

param windowsServerImage object
param windowsClientImage object
param ubuntuImage object

param vmAutoDeleteOptions object

// Credentials
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

// Network contract
param subnetMap array

// subnetMap contract:
//
// [
//   {
//     regionKey: 'westeurope'
//
//     subnets: {
//       dc: {
//         id: '...'
//       }
//
//       jumpbox: {
//         id: '...'
//       }
//
//       server: {
//         id: '...'
//       }
//
//       client: {
//         id: '...'
//       }
//     }
//   }
// ]

var controlWindowsVMs = filter(windowsVMList, vm =>
  vm.type == 'dc' || vm.type == 'jmp'
)

var workloadWindowsVMs = filter(windowsVMList, vm =>
  vm.type == 'srvwin' || vm.type == 'cliwin'
)

var deployIdentityTargets = deployWorkload || deployIdentity

// Workload VMs must exist before identity automation can domain-join them. For that reason,
// an identity-stage deployment activates missing workload VMs even when compute ran earlier.
var activeWindowsVMs = concat(
  deployControl ? controlWindowsVMs : [],
  deployIdentityTargets ? workloadWindowsVMs : []
)

var activeLinuxVMs = deployIdentityTargets
  ? linuxVMList
  : []

var jumpboxLinuxSshKeyVMs = (deployControl || deployWorkload || deployIdentity) && hasLinuxVMs
  ? filter(controlWindowsVMs, item => item.type == 'jmp')
  : []

var subnetMapByRegion = toObject(subnetMap, item => item.regionKey, item => item.subnets)

func getSubnetId(vm object) string =>
  vm.type == 'dc'
    ? subnetMapByRegion[vm.regionKey].dc.id
    : vm.type == 'jmp'
      ? subnetMapByRegion[vm.regionKey].jumpbox.id
      : vm.type == 'srvwin' || vm.type == 'srvlin'
        ? subnetMapByRegion[vm.regionKey].server.id
        : subnetMapByRegion[vm.regionKey].client.id

// ------------------------------
// Windows VM deployment
// ------------------------------

module windowsVMs '../compute/vm-windows.bicep' = [
  for (vm, i) in activeWindowsVMs: {
    name: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    // Dependency provided by stage orchestration through subnetMap.

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

      subnetId: getSubnetId(vm)

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
// LINUX VM deployment
// ========================================

// Network-stage outputs establish subnet pathing before this stage provisions VMs.

module linuxVMs '../compute/vm-linux.bicep' = [
  for vm in activeLinuxVMs: {
    name: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    // Dependency provided by stage orchestration through subnetMap.

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

      subnetId: getSubnetId(vm)

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

// Deploys the SSH private key onto jumpboxes only, so admins can hop from a jumpbox to Linux VMs
// without distributing the private key to every workload VM.
module installJumpboxSshKey '../compute/ssh-key.bicep' = [
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
// COMPUTE STAGE OUTPUT CONTRACT
// ========================================
//
// This stage has no outputs consumed by downstream modules.
// Identity-stage receives VM placement data from main.bicep and depends on
// compute-stage completion before running identity operations.
