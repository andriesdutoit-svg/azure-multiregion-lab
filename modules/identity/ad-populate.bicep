targetScope = 'resourceGroup'

// ========================================
// MODULE PURPOSE
// Executes directory population via Azure VM Run Command on primary DC
// ========================================

// ========================================
// CONFIGURATION INPUTS
// ========================================

param dcVmName string
param domainName string

param usersPerDepartment int
param sysAdminDepartment object
param additionalDepartments object
param departmentCount int
@secure()
param clientAdminPassword string
param directoryModel string

param reconciliationToken string

// ========================================
// CONFIGURATION VARIABLES
// ========================================

var populateAdScript = loadTextContent('./scripts/Populate-AD.ps1')
var namesCsvContent = loadTextContent('./data/names.csv')

// ========================================
// RESOURCES
// ========================================

// ----
// Reference to primary DC VM
// ----

resource dcVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: dcVmName
}

// ----
// Directory population run command
// ----

resource populateDirectory 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: dcVm
  name: 'populate-directory'

  location: resourceGroup().location

  properties: {
    
    source: {
      script: populateAdScript
    }

    parameters: [
      {
        name: 'DomainName'
        value: domainName
      }
      {
        name: 'DirectoryModel'
        value: directoryModel
      }
      {
        name: 'NamesCsvContent'
        value: namesCsvContent
      }
      {
        name: 'ClientAdminPassword'
        value: clientAdminPassword
      }
      {
        name: 'SysAdminDepartmentJson'
        value: string(sysAdminDepartment)
      }
      {
        name: 'AdditionalDepartmentsJson'
        value: string(additionalDepartments)
      }
      {
        name: 'DepartmentCount'
        value: string(departmentCount)
      }
      {
        name: 'UsersPerDepartment'
        value: string(usersPerDepartment)
      }
      {
        name: 'ReconciliationToken'
        value: reconciliationToken
      }
    ]
  }
}
