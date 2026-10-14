targetScope = 'resourceGroup'

// Promotes the designated replica DC; the caller orders this after primary-forest readiness.
// Consumes the domain, target VM, and domain-administrator credentials. Guest promotion and
// existing-role detection belong to the script; this module does not create the VM or change placement.

// 1. Target and domain
param dcVmName string
param domainName string

// Domain administrator credentials and guest-automation rerun token
param serverAdminUsername string
@secure()
param serverAdminPassword string

param reconciliationToken string

// 2. Script content

var promoteReplicaDcScript = loadTextContent('./scripts/Promote-ReplicaDC.ps1')

// 3. Existing replica DC and Run Command
// Referencing the VM does not redeploy its disks, NIC, or operating-system configuration.

resource dcVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: dcVmName
}

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
