targetScope = 'resourceGroup'

// Populates the declared directory model and reconciles modeled DC HTTP SPNs on the primary DC.
// Runs after forest/replica provisioning. The directory model aligns OU/group naming with GPO and joins;
// names.csv supplies population data, while the guest script owns existing-object handling.
// Optional file-service groups are controlled here, but share creation belongs to file-services.bicep.
// DC HTTP SPNs are directory account state, so they are reconciled centrally after all DCs
// are promoted, not by VM creation or firewall policy. The full DC list includes retained DCs.

// 1. Target and directory model
param dcVmName string
param domainName string
param directoryModel string
param domainControllerNames array

// Population settings and optional file-service groups
param sysAdminDepartment object
param additionalDepartments object
param departmentCount int
param usersPerDepartment int
param enableFileServices bool

param reconciliationToken string

// 2. Guest script and source names
// Embed the same selection helper used by file services after the script's parameter block.
// The VM receives one self-contained script; no helper file or module must exist on the guest.

var populateAdScript = replace(
  loadTextContent('./scripts/Populate-AD.ps1'),
  '# __AMRL_DEPARTMENT_SELECTION__',
  loadTextContent('./scripts/Get-SelectedDepartments.ps1')
)
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
    treatFailureAsDeploymentFailure: true

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
        name: 'DomainControllerNamesJson'
        value: string(domainControllerNames)
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
