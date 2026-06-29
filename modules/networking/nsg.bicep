param nsgName string
param location string
param tags object = {}

@description('Array of NSG rules')
param rules array

resource nsg 'Microsoft.Network/networkSecurityGroups@2022-09-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      for (rule, index) in rules: {
        name: rule.name
        properties: {
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

output nsgId string = nsg.id
