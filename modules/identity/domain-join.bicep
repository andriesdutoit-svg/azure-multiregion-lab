targetScope = 'resourceGroup'

// Owns Windows domain membership and HTTP SPNs via Azure VM Run Command.
// The join script checks PartOfDomain before joining; this module does not recreate the VM.
// The caller waits for GPO definition provisioning, not guest policy application.
// vmType and the serialized directory model select OU placement;
// a new deployment token supports reruns but does not force an already joined machine to rejoin.
// New members restart to complete the join; retained members still receive SPN repair.
// Windows processes GPOs normally. This module does not gate deployment on effective guest policy.

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
var joinDomainScript = loadTextContent('./scripts/Join-Domain.ps1')

// 3. Existing target and Run Command
resource vm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: vmName
}

resource domainJoin 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: vm
  name: 'join-domain'

  location: resourceGroup().location

  properties: {
    asyncExecution: false
    treatFailureAsDeploymentFailure: true
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
