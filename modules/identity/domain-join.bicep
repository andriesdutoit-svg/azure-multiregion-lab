targetScope = 'resourceGroup'

param vmName string
param domainName string
param serverAdminUsername string
@secure()
param serverAdminPassword string
param directoryModel string
param vmType string

param reconciliationToken string

var joinDomainScript = loadTextContent('./scripts/Join-Domain.ps1')

resource vm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: vmName
}

resource domainJoin 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: vm
  name: 'join-domain'

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
