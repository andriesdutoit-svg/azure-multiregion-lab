targetScope = 'subscription'

// Identity stage overview
// Responsibilities:
// - Bootstrap the primary forest, promote replicas, populate AD, and provision Group Policy.
// - Join Windows/Linux workloads, configure Linux client desktops, and provision optional shares.
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

// Stage and optional service activation
param deployIdentity bool
param enableFileServices bool
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

param serverAdminUsername string

@secure()
param serverAdminPassword string

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

  gpoNames: {
    serverAdministration: gpoNames.serverAdministration
    clientAdministration: gpoNames.clientAdministration
    windowsLaps: gpoNames.windowsLaps
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
    serverAdminPassword: serverAdminPassword
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
      serverAdminUsername: serverAdminUsername
      serverAdminPassword: serverAdminPassword
      reconciliationToken: reconciliationToken
    }
  }
]

// 3.2 Directory population and Group Policy
// Group Policy runs after group/OU provisioning; domain joins depend on its completion.
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
    sysAdminDepartment: sysAdminDepartment
    additionalDepartments: additionalDepartments
    departmentCount: departmentCount
    usersPerDepartment: usersPerDepartment
    enableFileServices: enableFileServices
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

// 3.3 Optional file services
// The forward domainJoinWindows dependency ensures a dedicated server joins before share ACL setup.
module fileServices '../identity/file-services.bicep' = if (deployIdentity && enableFileServices) {
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
// GPO provisioning precedes joins. The script skips joining an already domain-joined machine.

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
      serverAdminUsername: serverAdminUsername
      serverAdminPassword: serverAdminPassword
      reconciliationToken: reconciliationToken
    }
  }
]

// 3.5 Windows Admin Center
// Wait for directory provisioning and Windows joins so the selected host has working domain DNS.
module windowsAdminCenter '../identity/wac.bicep' = if (deployIdentity && enableWindowsAdminCenter) {
  name: '${prefix}-wac-${wacHostVm.name}'

  scope: resourceGroup('${prefix}-rg-${wacHostVm.regionKey}')

  dependsOn: [
    adGpo
    domainJoinWindows
  ]

  params: {
    vmName: wacHostVm.name
    reconciliationToken: reconciliationToken
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
      serverAdminUsername: serverAdminUsername
      serverAdminPassword: serverAdminPassword
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
