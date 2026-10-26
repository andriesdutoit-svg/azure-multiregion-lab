targetScope = 'resourceGroup'

// Reconciles each domain controller's WinRM HTTP SPNs and verifies the linked firewall GPO.

param vmName string
param domainName string
param reconciliationToken string

var configureDcWinRmScript = loadTextContent('./scripts/Configure-DCWinRM.ps1')

resource vm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: vmName
}

resource configureDcWinRm 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: vm
  name: 'configure-dc-winrm'
  location: resourceGroup().location

  properties: {
    asyncExecution: false
    timeoutInSeconds: 600
    treatFailureAsDeploymentFailure: true

    source: {
      script: configureDcWinRmScript
    }

    parameters: [
      {
        name: 'DomainName'
        value: domainName
      }
      {
        name: 'ReconciliationToken'
        value: reconciliationToken
      }
    ]
  }
}
