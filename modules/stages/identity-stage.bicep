targetScope = 'subscription'

// Identity stage overview
// Responsibilities:
// - Bootstrap the primary forest, promote replicas, populate AD, and provision Group Policy and file services.
// - Join Windows/Linux workloads and configure Linux client desktops.
// - Install optional Windows Admin Center after AD DNS is available.
// Consumes:
// - The root's primary/replica/file-server targets and combined retained/new VM placement model.
// - Domain, department, GPO, credential, and rerun-token configuration.
// Prerequisites and workflow:
// - main.bicep orders this stage after compute completion; identity-only runs require existing DCs.
// - Forest/replicas precede population; population precedes GPO; GPO precedes domain joins.
// - Linux joins also wait for desktop prerequisites; file services wait for Windows joins.
// Boundaries:
// - deployIdentity gates guest-automation modules. Scripts own supported existing-state repair.
// - No VMs are recreated here and no output values are exposed to downstream stages.

// 1. Parameters
// Naming and guest-automation rerun token
param prefix string
param reconciliationToken string

// Stage and optional WAC activation
param deployIdentity bool
param enableWindowsAdminCenter bool

// Targets from the combined retained/new placement model
param finalVmPlacements array
param primaryDc object

param replicaDcList array

param fileServerVm object

param fileServerName string
param wacHostVm object

// Directory structure and population settings

param domainName string

param gpoNames object

param sysAdminDepartment object

param additionalDepartments object

param departmentCount int
param usersPerDepartment int

// Domain administrator credentials

param labAdminUsername string

@secure()
param labAdminPassword string

// 2. Shared directory model
// Serialized for every identity script to keep OU, group, GPO, and share configuration aligned.
// Preserve customOus order: parent paths precede their child paths.
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
    'ServiceAccounts'
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
    sourceDepartmentCode: empty(items(sysAdminDepartment)) ? '' : first(items(sysAdminDepartment))!.value
  }

  gpoNames: {
    labAdministration: gpoNames.labAdministration
    clientAdministration: gpoNames.clientAdministration
    windowsLaps: gpoNames.windowsLaps
    domainControllerWinRM: gpoNames.domainControllerWinRM
  }


  shares: {
    root: {
      name: 'Shares'
      path: 'C:\\Shares'
      host: fileServerName
    }
  }

  coreOuMapping: {
    users: 'Users'
    groups: 'Groups'
  }
}

// 3. Guest-automation modules
// Explicit dependencies, not textual order, control execution. Targets include retained VMs.

// 3.1 Primary forest and replica promotion
module adForest '../identity/ad-forest.bicep' = if (deployIdentity) {
  name: '${prefix}-ad-forest'
  scope: resourceGroup('${prefix}-rg-${primaryDc!.regionKey}')

  // The root's compute dependency provides VM readiness; an identity-only run requires existing DCs.

  params: {
    dcVmName: primaryDc!.name
    domainName: domainName
    labAdminPassword: labAdminPassword
    reconciliationToken: reconciliationToken
  }
}

module replicaDcs '../identity/ad-replicadc.bicep' = [
  for dc in replicaDcList: if (deployIdentity) {
    name: '${prefix}-replica-${dc.index + 1}'

    scope: resourceGroup('${prefix}-rg-${dc.regionKey}')

    dependsOn: [
      adForest
    ]

    params: {
      dcVmName: dc.name
      domainName: domainName
      labAdminUsername: labAdminUsername
      labAdminPassword: labAdminPassword
      reconciliationToken: reconciliationToken
    }
  }
]

// 3.2 Directory population and Group Policy
// Group Policy configuration runs after group/OU and DC-SPN reconciliation.
// Domain joins wait for the GPO definitions; Windows processes those policies normally.
// Deployment success does not establish effective guest policy or authenticated WAC access.
module adPopulate '../identity/ad-populate.bicep' = if (deployIdentity) {
  name: '${prefix}-ad-populate'

  scope: resourceGroup('${prefix}-rg-${primaryDc!.regionKey}')

  dependsOn: [
    adForest
    replicaDcs
  ]

  params: {
    dcVmName: primaryDc!.name
    domainName: domainName
    directoryModel: string(directoryModel)
    domainControllerNames: map(filter(finalVmPlacements, vm => vm.type == 'dc'), dc => dc.name)
    sysAdminDepartment: sysAdminDepartment
    additionalDepartments: additionalDepartments
    departmentCount: departmentCount
    usersPerDepartment: usersPerDepartment
    reconciliationToken: reconciliationToken
  }
}

module adGpo '../identity/ad-gpo.bicep' = if (deployIdentity) {
  name: '${prefix}-ad-gpo'
  scope: resourceGroup('${prefix}-rg-${primaryDc!.regionKey}')

  dependsOn: [
    adPopulate
  ]

  params: {
    dcVmName: primaryDc!.name
    domainName: domainName
    directoryModel: string(directoryModel)
    reconciliationToken: reconciliationToken
  }
}

// 3.3 File services are part of the identity platform.
// The forward domainJoinWindows dependency ensures a dedicated server joins before share ACL setup.
module fileServices '../identity/file-services.bicep' = if (deployIdentity) {
  name: '${prefix}-file-services'

  scope: resourceGroup('${prefix}-rg-${fileServerVm.regionKey}')

  dependsOn: [
    adPopulate
    domainJoinWindows
  ]

  params: {
    fileServerVmName: fileServerName
    directoryModel: string(directoryModel)
    sysAdminDepartment: sysAdminDepartment
    additionalDepartments: additionalDepartments
    departmentCount: departmentCount
    reconciliationToken: reconciliationToken
  }
}

// 3.4 Windows domain membership
// GPO provisioning precedes joins. Retained members skip the join but still receive SPN repair.

module domainJoinWindows '../identity/domain-join.bicep' = [
  for vm in filter(finalVmPlacements, vm => vm.type == 'srvwin' || vm.type == 'cliwin'): if (deployIdentity) {
    name: '${prefix}-domainjoin-${vm.name}'
    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      adGpo
    ]

    params: {
      vmName: vm.name
      domainName: domainName
      directoryModel: string(directoryModel)
      vmType: vm.type
      labAdminUsername: labAdminUsername
      labAdminPassword: labAdminPassword
      reconciliationToken: reconciliationToken
    }
  }
]

// 3.5 Reconcile HTTP SPNs only after each Windows join command has completed its reboot.
module domainJoinWindowsSpns '../identity/domain-join-spn.bicep' = [
  for vm in filter(finalVmPlacements, vm => vm.type == 'srvwin' || vm.type == 'cliwin'): if (deployIdentity) {
    name: '${prefix}-domainjoin-spn-${vm.name}'
    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      domainJoinWindows
    ]

    params: {
      vmName: vm.name
      domainName: domainName
      reconciliationToken: reconciliationToken
    }
  }
]

// 3.6 Windows Admin Center
// Wait for GPO configuration, Windows joins, and post-reboot HTTP SPN reconciliation.
// The VM agent installs WAC independently of the targets' current WinRM firewall state.
module windowsAdminCenter '../identity/wac.bicep' = if (deployIdentity && enableWindowsAdminCenter) {
  name: '${prefix}-wac-${wacHostVm.name}'

  scope: resourceGroup('${prefix}-rg-${wacHostVm.regionKey}')

  dependsOn: [
    adGpo
    domainJoinWindows
    domainJoinWindowsSpns
  ]

  params: {
    vmName: wacHostVm.name
    reconciliationToken: reconciliationToken
    targetFqdns: [
      for vm in filter(finalVmPlacements, vm => vm.type == 'dc' || vm.type == 'srvwin' || vm.type == 'cliwin'): '${vm.name}.${domainName}'
    ]
  }
}

// 3.6 Linux domain membership and supported guest repair
// Both GPO and Linux desktop prerequisites complete before these commands; the script
// owns realm detection and selected configuration repair on retained endpoints.

module domainJoinLinux '../identity/domain-join-linux.bicep' = [
  for vm in filter(finalVmPlacements, vm => vm.type == 'srvlin' || vm.type == 'clilin'): if (deployIdentity) {
    name: '${prefix}-domainjoin-${vm.name}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      adGpo
      linuxDesktop
    ]

    params: {
      vmName: vm.name
      domainName: domainName
      directoryModel: string(directoryModel)
      vmType: vm.type
      labAdminUsername: labAdminUsername
      labAdminPassword: labAdminPassword
      reconciliationToken: reconciliationToken
    }
  }
]

// 3.7 Linux client desktop prerequisites
// DomainJoinLinux references this collection even though it is declared later in the file.
module linuxDesktop '../compute/linux-desktop.bicep' = [
  for vm in filter(finalVmPlacements, vm => vm.type == 'clilin'): if (deployIdentity) {
    name: '${prefix}-desktop-${vm.name}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    // VM availability is provided by the root's compute-stage dependency.

    params: {
      vmName: vm.name
      domainName: domainName
      directoryModel: string(directoryModel)
      reconciliationToken: reconciliationToken
    }
  }
]
