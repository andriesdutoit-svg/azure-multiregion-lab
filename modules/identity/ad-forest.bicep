targetScope = 'resourceGroup'

// Bootstraps the AD forest on the designated primary DC through guest automation.
// Requires an already provisioned Windows DC VM; forest detection and supported rerun behavior
// belong to Install-Forest.ps1. Referencing a VM alone does not verify AD service readiness.

// 1. Target, domain, credentials, and rerun token
param dcVmName string
param domainName string
@secure()
param serverAdminPassword string
param reconciliationToken string

// 2. Script content
// Existing forest detection and bootstrap readiness are handled by the guest script.

var installForestScript = loadTextContent('./scripts/Install-Forest.ps1')

// 3. Existing primary DC and Run Command

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
      {
        name: 'ReconciliationToken'
        value: reconciliationToken
      }
    ]
  }
}
