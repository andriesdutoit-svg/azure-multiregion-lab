targetScope = 'resourceGroup'

param vmName string
param adminUsername string

@secure()
param sshPrivateKey string
param reconciliationToken string

var installSshKeyScript = loadTextContent('./scripts/Install-SshKey.ps1')

resource vm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: vmName
}

resource installSshKey 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: vm
  name: 'install-ssh-key'

  location: resourceGroup().location

  properties: {

    asyncExecution: false

    source: {
      script: installSshKeyScript
    }

    parameters: [
      {
        name: 'AdminUsername'
        value: adminUsername
      }
      {
        name: 'SshPrivateKey'
        value: sshPrivateKey
      }
      {
        name: 'ReconciliationToken'
        value: reconciliationToken
      }
    ]
  }
}
