targetScope = 'resourceGroup'

// ========================================
// MODULE PURPOSE
// Executes replica DC promotion via Azure VM Run Command
// ========================================

// ========================================
// CONFIGURATION INPUTS
// ========================================

param domainName string

param serverAdminUsername string
@secure()
param serverAdminPassword string

param dcVmName string

param reconciliationToken string

// ========================================
// CONFIGURATION VARIABLES
// ========================================

var promoteReplicaDcScript = loadTextContent('./scripts/Promote-ReplicaDC.ps1')

// ========================================
// RESOURCES
// ========================================

// ----
// Reference to replica DC VM
// ----

resource dcVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: dcVmName
}

// ----
// Replica promotion run command
// ----

resource replicaBootstrap 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: dcVm
  name: 'promote-replica'

  location: resourceGroup().location

  properties: {
    source: {
      script: promoteReplicaDcScript
    }

    parameters: [
      {
        name: 'DomainName'
        value: domainName
      }
      {
        name: 'ServerAdminUsername'
        value: serverAdminUsername
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
