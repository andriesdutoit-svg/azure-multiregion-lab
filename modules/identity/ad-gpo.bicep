targetScope = 'resourceGroup'

// Creates and reconciles the AMRL GPO definitions on the primary DC.
// Directory population must finish first so OUs, groups, and DC HTTP SPNs exist.
// Completion confirms configuration commands succeeded, not that every VM has applied policy.
// Windows handles guest policy processing normally; functional readiness is checked separately.

// 1. Existing primary DC, directory model, and rerun metadata
param dcVmName string
param domainName string
param directoryModel string
param reconciliationToken string

resource dcVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: dcVmName
}

// 2. Apply managed policy settings on both first-time deployments and brownfield reruns.
resource configureGpo 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: dcVm
  name: 'configure-gpo'
  location: resourceGroup().location
  properties: {
    asyncExecution: false
    treatFailureAsDeploymentFailure: true
    source: {
      script: loadTextContent('./scripts/Configure-GPOs.ps1')
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
