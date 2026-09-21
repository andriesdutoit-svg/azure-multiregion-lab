targetScope = 'resourceGroup'

param prefix string
param hubRegion string
param existingRegions array
param networkMode string
param executePeeringCleanup bool
@description('Resource ID of the User Assigned Managed Identity used by Deployment Scripts.')
param automationManagedIdentityResourceId string

resource cleanupScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${prefix}-topology-cleanup'
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
        name: 'EXECUTE_PEERING_CLEANUP'
        value: string(executePeeringCleanup)
      }
    ]

    scriptContent: loadTextContent('./scripts/topology-cleanup.ps1')

  }
}
