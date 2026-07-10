targetScope = 'resourceGroup'

param dcVmName string
param domainName string

var populateAdScript = loadTextContent('./scripts/Populate-AD.ps1')
var namesCsvContent = loadTextContent('./data/names.csv')

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
        name: 'NamesCsvContent'
        value: namesCsvContent
      }
    ]
  }
}
