targetScope = 'resourceGroup'

// ========================================
// MODULE PURPOSE
// Executes departmental share provisioning
// on the designated AMRL file server.
// ========================================

// ========================================
// CONFIGURATION INPUTS
// ========================================

param fileServerVmName string

param directoryModel string

param sysAdminDepartment object
param additionalDepartments object
param departmentCount int

param reconciliationToken string

// ========================================
// CONFIGURATION VARIABLES
// ========================================

var populateSharesScript = loadTextContent('./scripts/Populate-Shares.ps1')

// // ========================================
// // RESOURCES
// // ========================================

resource fileServerVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: fileServerVmName
}

resource populateShares 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: fileServerVm
  name: 'populate-shares'

  location: resourceGroup().location

  properties: {
    source: {
      script: populateSharesScript
    }

    parameters: [
      {
        name: 'DirectoryModel'
        value: directoryModel
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
        name: 'ReconciliationToken'
        value: reconciliationToken
      }
    ]
  }
}
