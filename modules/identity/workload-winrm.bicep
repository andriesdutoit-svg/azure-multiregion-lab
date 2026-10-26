targetScope = 'resourceGroup'

param vmName string
param reconciliationToken string

var configureWorkloadWinRmScript = loadTextContent('./scripts/Configure-WorkloadWinRM.ps1')

resource vm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: vmName
}

resource configureWorkloadWinRm 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: vm
  name: 'configure-workload-winrm-gpo'
  location: resourceGroup().location

  properties: {
    asyncExecution: false
    timeoutInSeconds: 600
    treatFailureAsDeploymentFailure: true

    source: {
      script: configureWorkloadWinRmScript
    }

    parameters: [
      {
        name: 'ReconciliationToken'
        value: reconciliationToken
      }
    ]
  }
}
