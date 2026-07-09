targetScope = 'resourceGroup'

param domainName string
@secure()
param serverAdminPassword string
param dcVmName string

var installForestScript = loadTextContent('./scripts/Install-Forest.ps1')

resource dcVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: dcVmName
}

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
    ]
  }
}
