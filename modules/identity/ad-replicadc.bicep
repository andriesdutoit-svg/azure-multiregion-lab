targetScope = 'resourceGroup'

param domainName string

param serverAdminUsername string
@secure()
param serverAdminPassword string

param dcVmName string

var promoteReplicaDcScript = loadTextContent('./scripts/Promote-ReplicaDC.ps1')

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
    ]
  }
}
