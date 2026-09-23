targetScope = 'resourceGroup'

param dcVmName string
param domainName string
param directoryModel string

param reconciliationToken string

var configureGpoScript = loadTextContent('./scripts/Configure-GPO.ps1')

resource dcVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: dcVmName
}

resource configureGpo 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: dcVm
  name: 'configure-gpo'

  location: resourceGroup().location

  properties: {
    source: {
      script: configureGpoScript
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
        name: 'ReconciliationToken'
        value: reconciliationToken
      }
    ]
  }
}
