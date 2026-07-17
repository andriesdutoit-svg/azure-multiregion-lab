targetScope = 'resourceGroup'

param dcVmName string
param domainName string

param usersPerDepartment int
param departments object
param departmentCount int
@secure()
param clientAdminPassword string

var populateAdScript = loadTextContent('./scripts/Populate-AD.ps1')
var namesCsvContent = loadTextContent('./data/names.csv')

resource dcVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: dcVmName
}

resource populateDirectory 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: dcVm
  name: 'populate-directory-debug'

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
        name: 'NamesCsvContent'
        value: namesCsvContent
      }
      {
        name: 'ClientAdminPassword'
        value: clientAdminPassword
      }
      {
        name: 'DepartmentsJson'
        value: string(departments)
      }
      {
        name: 'DepartmentCount'
        value: string(departmentCount)
      }
      {
        name: 'UsersPerDepartment'
        value: string(usersPerDepartment)
      }
    ]
  }
}
