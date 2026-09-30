targetScope = 'resourceGroup'

param dcVmName string
param domainName string
param directoryModel string

param reconciliationToken string

var gpoTemplatesZip = loadFileAsBase64('./templates/gpo/TemplateExports.zip')

var importGpoTemplateScript = loadTextContent('./scripts/Import-GPO-Templates.ps1')

resource dcVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: dcVmName
}

resource configureGpo 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: dcVm
  name: 'configure-gpo'

  location: resourceGroup().location

  properties: {
    treatFailureAsDeploymentFailure: true

    source: {
      script: importGpoTemplateScript
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
      {
        name: 'GpoTemplatesZip'
        value: gpoTemplatesZip
      }
    ]
  }
}
