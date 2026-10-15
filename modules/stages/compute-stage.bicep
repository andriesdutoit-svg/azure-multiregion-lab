targetScope = 'subscription'

// Compute stage overview
// Responsibilities:
// - Create missing Windows and Linux VMs with role-specific sizing, images, and administrator access.
// - Keep new workloads private and assign Public IPs to new jumpboxes.
// - Install the shared Linux-administration private key on selected new and retained jumpboxes.
// Consumes:
// - New-VM collections and the full SSH-key jumpbox collection derived by main.bicep.
// - Stage flags, compute settings, credentials, and network-stage's region/role subnetMap.
// Provides:
// - VM deployment completion for identity-stage; there are no downstream output values.
// Boundaries:
// - Identity runs can create missing workloads but not missing control-plane VMs.
// - Retained VMs are excluded from creation loops; their NIC/Public IP configuration is not reconciled.

// 1. Parameters
// Resource metadata and guest-automation rerun token
param prefix string
param finalTags object
param reconciliationToken string

// Deployment control
param deployControl bool
param deployWorkload bool
param deployIdentity bool

// Placement results
param windowsVMList array
param linuxVMList array
param sshKeyJumpboxPlacements array
param hasLinuxVMs bool

// Network contract: [{ regionKey, subnets: { dc, jumpbox, server, client } }], with an id per role.
// The ordered network result is converted to a region-key lookup before role-specific selection.
// Entries must cover each activated VM region; this module does not discover missing networks.
param subnetMap array

// Compute configuration
param roleSizingMap object

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

// 2. Active VM collections and subnet selection
// Control-plane creation is separate from workload creation so identity runs can add
// missing workloads without redeploying DCs or jumpboxes.
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

// SSH-key targeting uses the full jumpbox inventory, not just newly created Windows VMs.
var jumpboxLinuxSshKeyVMs = (deployControl || deployWorkload || deployIdentity) && hasLinuxVMs
  ? sshKeyJumpboxPlacements
  : []

// Map ordered network outputs by region identity, then resolve each VM's role subnet.
var subnetMapByRegion = toObject(subnetMap, item => item.regionKey, item => item.subnets)

func getSubnetId(vm object) string =>
  vm.type == 'dc'
    ? subnetMapByRegion[vm.regionKey].dc.id
    : vm.type == 'jmp'
      ? subnetMapByRegion[vm.regionKey].jumpbox.id
      : vm.type == 'srvwin' || vm.type == 'srvlin'
        ? subnetMapByRegion[vm.regionKey].server.id
        : subnetMapByRegion[vm.regionKey].client.id

// 3. New Windows VMs
// New jumpboxes receive Public IPs; this loop does not mutate retained jumpbox NICs.

module windowsVMs '../compute/vm-windows.bicep' = [
  for (vm, i) in activeWindowsVMs: {
    name: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    // Dependency provided by stage orchestration through subnetMap.

    params: {
      vmName: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'
      tags: union(finalTags, {
        role: vm.type == 'dc'
          ? 'domain-controller'
          : vm.type == 'jmp'
            ? 'jumpbox'
            : vm.type == 'srvwin'
              ? 'server'
              : 'client'
      })

      vmSize: roleSizingMap[vm.type].vmSize
      image: vm.type == 'cliwin'
        ? windowsClientImage
        : windowsServerImage
      osDisk: roleSizingMap[vm.type].osDisk
      vmAutoDeleteOptions: vmAutoDeleteOptions

      subnetId: getSubnetId(vm)
      assignPublicIp: vm.type == 'jmp'

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
    }
  }
]

// 4. New Linux VMs
// Workloads remain private and use the configured local administrator's SSH public key.

module linuxVMs '../compute/vm-linux.bicep' = [
  for vm in activeLinuxVMs: {
    name: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    // Dependency provided by stage orchestration through subnetMap.

    params: {
      vmName: '${prefix}-${vm.type}${padLeft(string(vm.index + 1), 2, '0')}'
      tags: union(finalTags, {
        role: vm.type == 'srvlin' ? 'server' : 'client'
      })

      vmSize: roleSizingMap[vm.type].vmSize
      image: ubuntuImage
      osDisk: roleSizingMap[vm.type].osDisk
      vmAutoDeleteOptions: vmAutoDeleteOptions

      subnetId: getSubnetId(vm)
      assignPublicIp: false

      adminUsername: vm.type == 'srvlin' ? serverAdminUsername : clientAdminUsername
      sshPublicKey: sshPublicKey
    }
  }
]

// 5. Jumpbox SSH-key installation
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

// This stage has no outputs consumed by downstream modules.
// Identity-stage receives VM placement data from main.bicep and depends on
// compute-stage completion before running identity operations.
