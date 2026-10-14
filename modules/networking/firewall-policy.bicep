// Deploys the Azure Firewall policy and baseline east-west and outbound rules.
// The firewall module attaches the returned policy ID; subnet routing is configured elsewhere.
// This is a lab baseline for the managed 10.0.0.0/8 range, not a general-purpose least-privilege policy.

// 1. Policy identity and location
param location string
param firewallPolicyName string

// 2. Managed internal address range
var internalRange = '10.0.0.0/8'

// 3. Policy and ordered rule collections
// Internal traffic is allowed broadly; outbound Internet access is limited here to TCP 80/443.
// Preserve rule collection priorities and contents when adjusting the surrounding structure.
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

// 4. Policy identity for the firewall module
output firewallPolicyId string = firewallPolicy.id
