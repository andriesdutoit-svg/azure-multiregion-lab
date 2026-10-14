// Creates an NSG and expands simplified inbound rule definitions into security rules.
// Expected rule fields: name, port, access, source.
// The caller owns policy composition. This module assigns priorities from input order and
// expands the custom rules; Azure default NSG rules still apply alongside those definitions.

// 1. NSG identity and ordered rules
param nsgName string
param location string
param tags object = {}

@description('Array of NSG rules')
param rules array

// 2. Network security group
// Preserve input rule order: it determines priority and therefore matching precedence.

resource nsg 'Microsoft.Network/networkSecurityGroups@2022-09-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      for (rule, index) in rules: {
        name: rule.name
        properties: {
          // Deterministic rule ordering: starts at 1000 and increments by 1 per rule.
          priority: 1000 + index
          access: rule.access
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: rule.port
          sourceAddressPrefixes: rule.source
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// 3. Association identity

output nsgId string = nsg.id
