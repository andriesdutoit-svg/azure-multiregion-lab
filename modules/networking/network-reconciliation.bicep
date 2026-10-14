targetScope = 'resourceGroup'

// Runs bounded cleanup against declared existing regions and framework-named Bastion resources.
// It does not discover arbitrary resources or reconcile retained jumpbox Public IPs.
// network-stage decides when this script is needed from desired topology/access and existing-region inputs.
// Environment variables pass that contract to PowerShell; missing targets are expected on safe reruns.
// Inspect script outputs/warnings for failed removals rather than treating deployment success as proof of cleanup.

// 1. Naming, inventory, desired state, and execution identity
param prefix string
param hubRegion string
param existingRegions array
param networkMode string
param enableBastion bool
@description('Resource ID of the User Assigned Managed Identity used by Deployment Scripts.')
param automationManagedIdentityResourceId string

// 2. Deployment script
// The caller gates script creation. The identity needs cleanup permissions even if no targets exist.
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
