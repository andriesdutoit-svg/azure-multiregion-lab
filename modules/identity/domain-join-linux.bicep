targetScope = 'resourceGroup'

// Joins and configures a Linux workload VM using the declared directory model.
// The guest script owns realm detection and supported configuration repair on reruns.
// Identity-stage orders this after GPO and Linux desktop prerequisites. vmType selects directory placement;
// retained endpoints can be targeted without redeploying their VM, NIC, or OS disk configuration.

// 1. Target and directory placement
param vmName string
param domainName string
param directoryModel string
param vmType string

// Domain administrator credentials and rerun token
param serverAdminUsername string
@secure()
param serverAdminPassword string
param reconciliationToken string

// 2. Script content
var joinDomainScript = loadTextContent('scripts/Join-Domain-Linux.sh')

// 3. Existing target and Run Command
resource vm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: vmName
}

resource domainJoin 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: vm
  name: 'join-domain-linux'

  location: resourceGroup().location

  properties: {
    source: {
      script: joinDomainScript
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
        name: 'VmType'
        value: vmType
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
