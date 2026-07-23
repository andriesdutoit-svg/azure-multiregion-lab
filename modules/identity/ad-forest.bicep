targetScope = 'resourceGroup'

// ========================================
// MODULE PURPOSE
// Executes AD forest bootstrap via Azure VM Run Command on primary DC
// ========================================

// ========================================
// CONFIGURATION INPUTS
// ========================================

param dcVmName string
param domainName string
@secure()
param serverAdminPassword string
param reconciliationToken string

// ========================================
// CONFIGURATION VARIABLES
// ========================================

var installForestScript = loadTextContent('./scripts/Install-Forest.ps1')

// ========================================
// RESOURCES
// ========================================

// ----
// Reference to primary DC VM
// ----

resource dcVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: dcVmName
}

// ----
// Forest bootstrap run command
// ----

resource forestBootstrap 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: dcVm
  name: 'install-forest'
  location: resourceGroup().location

  properties: {
    source: {
      script: installForestScript
    }

    parameters: [
      {
        name: 'DomainName'
        value: domainName
      }
      {
        name: 'ServerAdminPassword'
        value: serverAdminPassword
      }
      {
        name: 'ReconciliationToken'
        value: reconciliationToken
      }
    ]
  }
}
