targetScope = 'resourceGroup'

param vmName string
param domainName string
param directoryModel string

param reconciliationToken string

var desktopInstallScript = loadTextContent('./scripts/Install-LinuxDesktop.sh')

resource vm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: vmName
}

resource installDesktop 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: vm
  name: 'install-linux-desktop'

  location: resourceGroup().location

  properties: {
    source: {
      script: desktopInstallScript
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
        name: 'ReconciliationToken'
        value: reconciliationToken
      }
    ]
  }
}
