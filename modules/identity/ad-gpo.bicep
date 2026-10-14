targetScope = 'resourceGroup'

// Provisions Group Policy from packaged backups on the primary DC.
// The guest script seeds missing policies rather than blindly overwriting existing ones.
// Directory population must run first so referenced OUs and groups exist. The packaged ZIP and
// serialized directory model are passed to the import script as one consistent provisioning contract.

// 1. Target, directory configuration, and rerun token
param dcVmName string
param domainName string
param directoryModel string

param reconciliationToken string

// 2. Packaged policy backups and import script
var gpoTemplatesZip = loadFileAsBase64('./templates/gpo/GpoTemplates.zip')

var importGpoTemplateScript = loadTextContent('./scripts/Import-GPO-Templates.ps1')

// 3. Existing primary DC and Run Command
// Failure is deployment-blocking because downstream domain joins depend on GPO provisioning.
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
