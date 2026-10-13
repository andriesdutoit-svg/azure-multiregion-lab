targetScope = 'resourceGroup'

param prefix string
param hubRegion string
param existingRegions array
param networkMode string
@description('Resource ID of the User Assigned Managed Identity used by Deployment Scripts.')
param automationManagedIdentityResourceId string
param enableBastion bool

resource reconciliationScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${prefix}-network-reconciliation'
  location: resourceGroup().location
  kind: 'AzurePowerShell'

identity: {
  type: 'UserAssigned'
  userAssignedIdentities: {
    '${automationManagedIdentityResourceId}': {}
  }
}

  properties: {
    azPowerShellVersion: '14.0'
    retentionInterval: 'P1D'

    environmentVariables: [
      {
        name: 'NETWORK_MODE'
        value: networkMode
      }
      {
        name: 'HUB_REGION'
        value: hubRegion
      }
      {
        name: 'EXISTING_REGIONS'
        value: join(existingRegions, ',')
      }
      {
        name: 'PREFIX'
        value: prefix
      }
      {
        name: 'ENABLE_BASTION'
        value: string(enableBastion)
      }
    ]

    scriptContent: loadTextContent('./scripts/network-reconciliation.ps1')

  }
}
