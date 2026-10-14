targetScope = 'resourceGroup'

// Deploys the shared SSH private key onto a jumpbox via Azure VM Run Command,
// so admins can hop from the jumpbox to Linux VMs using SSH key authentication.
// The caller selects targets and waits for VM creation; this module only configures the target guest.
// Reapplying the private key here does not rotate authorized public keys on retained Linux workloads.

// 1. Parameters
param vmName string
param adminUsername string

@secure()
param sshPrivateKey string
param reconciliationToken string

// 2. Script content
// The token is forwarded to guest automation; the script owns key-file installation and repair.
var installSshKeyScript = loadTextContent('./scripts/Install-SshKey.ps1')

// 3. Existing target and Run Command
// This targets retained or newly created VMs without redeclaring their compute configuration.
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
