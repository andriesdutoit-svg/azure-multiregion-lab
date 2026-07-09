targetScope = 'resourceGroup'

param domainName string
param serverAdminUsername string
@secure()
param serverAdminPassword string
param dcVmName string

resource dcVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: dcVmName
}

resource forestExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: dcVm
  name: 'ad-forest'

  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'

    settings: {
      commandToExecute: 'powershell.exe -Command "Write-Host Forest Placeholder"'
    }
  }
}