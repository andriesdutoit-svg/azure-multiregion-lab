targetScope = 'resourceGroup'

// Reconciles the target computer's WinRM HTTP SPNs after domain join and reboot.
param vmName string
param domainName string
param reconciliationToken string

var reconciliationScript = loadTextContent('./scripts/Reconcile-WinRMHttpSpns.ps1')

resource vm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: vmName
}

resource reconcileWinRMSpns 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: vm
  name: 'reconcile-winrm-spns'
  location: resourceGroup().location

  properties: {
    asyncExecution: false
    timeoutInSeconds: 1200
    treatFailureAsDeploymentFailure: true
    source: {
      script: reconciliationScript
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
