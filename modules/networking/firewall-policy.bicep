// Deploys the Azure Firewall policy and baseline east-west and outbound rules.

param location string
param firewallPolicyName string

var internalRange = '10.0.0.0/8'

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-02-01' = {
  name: firewallPolicyName
  location: location
  properties: {
    sku: {
      tier: 'Standard'
    }
    threatIntelMode: 'Alert'
  }
}

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
      {
        name: 'outbound-internet'
        priority: 200
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'allow-http-https-outbound'
            ipProtocols: [
              'TCP'
            ]
            sourceAddresses: [
              internalRange
            ]
            destinationAddresses: [
              '*'
            ]
            destinationPorts: [
              '80'
              '443'
            ]
          }
        ]
      }
    ]
  }
}

output firewallPolicyId string = firewallPolicy.id
