param vnetName string
param location string
param addressPrefix string
param subnetPrefix string
param dnsServers array = []
param tags object = {}
param externalAccessPrefixes array = []

resource nsg 'Microsoft.Network/networkSecurityGroups@2022-07-01' = {
  name: '${vnetName}-subnet-default-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-AD-Internal-And-Parameter-External'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefixes: concat(
            ['10.0.0.0/8'],
            externalAccessPrefixes
          )

          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '53'
            '88'
            '389'
            '445'
            '135'
            '3389'
            '49152-65535'
          ]
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    dhcpOptions: {
      dnsServers: dnsServers
    }
    subnets: [
      {
        name: '${vnetName}-subnet-default'
        properties: {
          addressPrefix: subnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

output vnetId string = vnet.id

output subnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  vnet.name,
  '${vnetName}-subnet-default'
)
