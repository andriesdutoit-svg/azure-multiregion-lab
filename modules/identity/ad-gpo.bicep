targetScope = 'resourceGroup'

// Creates and reconciles the AMRL Group Policy objects on the primary DC.
// Directory population must run first so referenced OUs and groups exist.

// 1. Target, directory configuration, and rerun token
param dcVmName string
param domainName string
param directoryModel string

param reconciliationToken string

// 2. Policy configuration script
var configureGpoScript = loadTextContent('./scripts/Configure-GPOs.ps1')

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
