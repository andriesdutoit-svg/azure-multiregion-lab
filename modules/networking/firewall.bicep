// ========================================
// MODULE PURPOSE
// Deploys hub firewall components: public IP, policy, firewall instance, and baseline east-west rules.
// ========================================

// ========================================
// INPUTS
// ========================================

param location string
param firewallName string
param vnetName string
param publicIpName string

// ========================================
// RESOURCE CREATED: PUBLIC IP
// Required for Azure Firewall deployment in VNet mode.
// ========================================

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-02-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// ========================================
// EXISTING DEPENDENCIES
// VNet and AzureFirewallSubnet are expected to exist already.
// ========================================

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

resource firewallSubnet 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: vnet
  name: 'AzureFirewallSubnet'
}

// ========================================
// RESOURCE CREATED: FIREWALL POLICY
// Deploy policy resources through a nested module so Azure completes policy evaluation
// before the firewall instance references the policy.
// ========================================

module firewallPolicy 'firewall-policy.bicep' = {
  name: '${firewallName}-policy-deployment'
  params: {
    location: location
    firewallPolicyName: '${firewallName}-policy'
  }
}

// ========================================
// RESOURCE CREATED: FIREWALL INSTANCE
// Data plane attached to the policy above.
// ========================================

resource firewall 'Microsoft.Network/azureFirewalls@2023-02-01' = {
  name: firewallName
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }

    firewallPolicy: {
      id: firewallPolicy.outputs.firewallPolicyId
    }

    ipConfigurations: [
      {
        name: 'firewall-ipconfig'
        properties: {
          subnet: {
            id: firewallSubnet.id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// ========================================
// OUTPUTS
// ========================================

// NOTE: Azure Firewall has a single IP configuration by design
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
