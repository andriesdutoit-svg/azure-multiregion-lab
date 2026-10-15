targetScope = 'resourceGroup'

// Installs Windows Admin Center on the selected management host.
// The host may be the first Windows server in the environment or,
// when no Windows server exists, the primary jumpbox.

// 1. Parameters

param vmName string
param reconciliationToken string

// 2. Script content
var installWacScript = loadTextContent('./scripts/Install-WAC.ps1')

// 3. Existing target VM
resource vm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: vmName
}

resource installWindowsAdminCenter 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: vm
  name: 'install-wac'

  location: resourceGroup().location

  properties: {
    asyncExecution: false

    source: {
      script: installWacScript
    }

    parameters: [
      {
        name: 'ReconciliationToken'
        value: reconciliationToken
      }
    ]
  }
}
