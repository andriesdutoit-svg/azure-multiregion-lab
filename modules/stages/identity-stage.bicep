targetScope = 'subscription'

// ========================================
// IDENTITY STAGE
//
// Responsibilities:
// - AD Forest deployment
// - Replica DC deployment
// - AD population
// - Windows domain join
// - Linux domain join
// - File services
// - Linux desktop configuration
//
// Consumes:
// - Placement results
// - Compute-stage outputs
// - Identity configuration
//
// Provides:
// - Configured identity environment
// - Joined machines
// - File services (optional)
// ========================================

// Internal responsibilities:
//
// directoryModel
//
// adForest
// replicaDcs
// adPopulate
//
// domainJoinWindows
// domainJoinLinux
//
// fileServices
//
// linuxDesktop

// Dependencies:

// Placement outputs:
// - primaryDc
// - replicaDcList
// - fileServerVm
// - fileServerName
// - finalVmPlacements

// Compute-stage:
// - VM availability before domain-join and file-service commands run

// Inputs:
//
// prefix
//
// deployIdentity
//
// primaryDc
// replicaDcList
//
// fileServerVm
// fileServerName
//
// domainName
//
// usersPerDepartment
// departmentCount
//
// sysAdminDepartment
// additionalDepartments
//
// enableFileServices
//
// serverAdminUsername
// serverAdminPassword
//
// clientAdminPassword
//
// reconciliationToken

// ========================================
// IDENTITY STAGE OUTPUT CONTRACT
// ========================================
//
// This stage has no outputs consumed by downstream modules.
//
// Consumed by:
// - main.bicep

// ========================================
// STAGE CONTROL
// Identity resources and Run Commands are activated only when deployIdentity is true.
// ========================================

param prefix string

param deployIdentity bool

param reconciliationToken string

// ========================================
// PLACEMENT OUTPUTS
// ========================================

param primaryDc object

param replicaDcList array

param fileServerVm object

param fileServerName string

param finalVmPlacements array

// ========================================
// IDENTITY CONFIGURATION
// ========================================

param domainName string

param usersPerDepartment int

param departmentCount int

param sysAdminDepartment object

param additionalDepartments object

param enableFileServices bool

// ========================================
// CREDENTIALS
// ========================================

param serverAdminUsername string

@secure()
param serverAdminPassword string

@secure()
param clientAdminPassword string

// Directory shape passed (as a JSON string) to every identity Run Command script.
// It centralizes OU paths, group naming, and admin group names so scripts never hardcode AD structure.
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
      host: fileServerName
    }
  }

  coreOuMapping: {
    users: 'Users'
    groups: 'Groups'
  }
}

module adForest '../identity/ad-forest.bicep' = if (deployIdentity) {
  name: '${prefix}-ad-forest'
  scope: resourceGroup('${prefix}-rg-${primaryDc!.regionKey}')

  // The bootstrap command must run after the target Windows DC VM exists.
  // In staged workflows, run control before identity.
  // Dependency will be provided by stage orchestration
  // through compute-stage.

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
    usersPerDepartment: usersPerDepartment
    sysAdminDepartment: sysAdminDepartment
    additionalDepartments: additionalDepartments
    clientAdminPassword: clientAdminPassword
    departmentCount: departmentCount
    directoryModel: string(directoryModel)
    enableFileServices: enableFileServices
    reconciliationToken: reconciliationToken
  }
}

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

// ========================================
// DEPLOYMENT STAGE 7b: WINDOWS DOMAIN JOIN
// Joins Windows servers (srvwin) and clients (cliwin) to the AD domain.
// Runs after directory population. OU placement is driven by VM type via the directory model.
// Participates in the reconciliation model: existing domain membership is detected and skipped.
// ========================================

module domainJoinWindows '../identity/domain-join.bicep' = [
  for vm in filter(finalVmPlacements, vm => vm.type == 'srvwin' || vm.type == 'cliwin'): if (deployIdentity) {
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
// DEPLOYMENT STAGE 8b: LINUX DOMAIN JOIN
// Joins Linux servers (srvlin) and clients (clilin) to the AD domain using realmd/SSSD integration.
// Runs after directory population. OU placement is driven by VM type via the directory model.
// Participates in the reconciliation model: existing domain membership is detected and skipped.
// ========================================

module domainJoinLinux '../identity/domain-join-linux.bicep' = [
  for vm in filter(finalVmPlacements, vm => vm.type == 'srvlin' || vm.type == 'clilin'): if (deployIdentity) {
    name: '${prefix}-domainjoin-${vm.name}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    dependsOn: [
      adPopulate
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

module linuxDesktop '../compute/linux-desktop.bicep' = [
  for vm in filter(finalVmPlacements, vm => vm.type == 'clilin'): if (deployIdentity) {
    name: '${prefix}-desktop-${vm.name}'

    scope: resourceGroup('${prefix}-rg-${vm.regionKey}')

    // Dependency will be provided by stage orchestration
    // through compute-stage.

    params: {
      vmName: vm.name
      domainName: domainName
      directoryModel: string(directoryModel)
      reconciliationToken: reconciliationToken
    }
  }
]
