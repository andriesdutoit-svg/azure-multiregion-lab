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
// DERIVED VALUES
// ========================================

// Internal address space used by lab VNets and firewall east-west allow rule.
var internalRange = '10.0.0.0/8'

//
// ========================================
// RESOURCE CREATED: PUBLIC IP
// Required for Azure Firewall deployment in VNet mode.
// ========================================
//

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

//
// ========================================
// EXISTING DEPENDENCIES
// VNet and AzureFirewallSubnet are expected to exist already.
// ========================================
//

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

//
// ========================================
// RESOURCE CREATED: FIREWALL POLICY
// Modern control plane for firewall rules.
// ========================================
//

resource firewallSubnet 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: vnet
  name: 'AzureFirewallSubnet'
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-02-01' = {
  name: '${firewallName}-policy'
  location: location
  properties: {
    sku: {
      tier: 'Standard'
    }
  }
}

//
// ========================================
// RESOURCE CREATED: FIREWALL INSTANCE
// Data plane attached to the policy above.
// ========================================
//

resource firewall 'Microsoft.Network/azureFirewalls@2023-02-01' = {
  name: firewallName
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }

    firewallPolicy: {
      id: firewallPolicy.id
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

//
// ========================================
// POLICY RULES
// Allow east-west internal traffic across 10.0.0.0/8.
// ========================================
//

resource policyRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-02-01' = {
  name: 'default-network-rules'
  parent: firewallPolicy
  properties: {
    priority: 100
    ruleCollections: [
      {
        name: 'allow-internal-traffic'
        priority: 100
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'allow-all-internal'
            ipProtocols: [
              'Any'
            ]
            sourceAddresses: [
              internalRange
            ]
            destinationAddresses: [
              internalRange
            ]
            destinationPorts: [
              '*'
            ]
          }
        ]
      }
    ]
  }
}

//
// ========================================
// OUTPUTS
// ========================================
//

// NOTE: Azure Firewall has a single IP configuration by design
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
