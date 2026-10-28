targetScope = 'resourceGroup'

// Provisions departmental shares on the designated primary DC or dedicated file server.
// Target selection belongs to main.bicep and identity-stage. The shared directory/department model
// determines share groups and permissions; this module does not migrate data between file servers.

// 1. Target and directory model
param fileServerVmName string

param directoryModel string

// Department configuration and guest-automation rerun token
param sysAdminDepartment object
param additionalDepartments object
param departmentCount int

param reconciliationToken string

// 2. Script content
// Share creation and permission reconciliation are owned by the guest script.
// Embed the same department selector as AD population to keep share and group targets aligned.

var populateSharesScript = replace(
  loadTextContent('./scripts/Populate-Shares.ps1'),
  '# __AMRL_DEPARTMENT_SELECTION__',
  loadTextContent('./scripts/Get-SelectedDepartments.ps1')
)

// 3. Existing file server and Run Command
// The caller ensures directory population and, for a dedicated server, domain join run first.

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
