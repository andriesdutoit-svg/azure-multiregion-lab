targetScope = 'resourceGroup'

// Installs the Linux client desktop through guest automation on an existing VM target.
// Identity-stage selects Linux clients and orders their domain joins after this prerequisite.
// Domain/directory-model inputs configure the guest script; VM and network lifecycle are outside this module.

// 1. Target, directory configuration, and rerun token
param vmName string
param domainName string
param directoryModel string

param reconciliationToken string

// 2. Script content
// Desktop packages and configuration are owned by the guest script, not by ARM resources.
var desktopInstallScript = loadTextContent('./scripts/Install-LinuxDesktop.sh')

// 3. Existing target and Run Command
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
