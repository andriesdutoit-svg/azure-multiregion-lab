targetScope = 'resourceGroup'

// Populates the declared department and user model on the primary DC.
// Runs after forest/replica provisioning. The directory model aligns OU/group naming with GPO and joins;
// names.csv supplies population data, while the guest script owns existing-object handling.
// Optional file-service groups are controlled here, but share creation belongs to file-services.bicep.

// 1. Target and directory model
param dcVmName string
param domainName string
param directoryModel string

// Population settings and optional file-service groups
param sysAdminDepartment object
param additionalDepartments object
param departmentCount int
param usersPerDepartment int
param enableFileServices bool

param reconciliationToken string

// 2. Guest script and source names
// Structured department inputs are serialized below for the Run Command interface.

var populateAdScript = loadTextContent('./scripts/Populate-AD.ps1')
var namesCsvContent = loadTextContent('./data/names.csv')

// 3. Existing primary DC and Run Command

resource dcVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: dcVmName
}

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
        name: 'EnableFileServices'
        value: string(enableFileServices)
      }
      {
        name: 'ReconciliationToken'
        value: reconciliationToken
      }
    ]
  }
}
