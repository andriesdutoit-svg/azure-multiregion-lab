param vnetName string
param location string
param addressPrefix string
param subnetPrefix object
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
            '22'
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
        name: '${vnetName}-subnet-dc'
        properties: {
          addressPrefix: subnetPrefix.dc
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: '${vnetName}-subnet-server'
        properties: {
          addressPrefix: subnetPrefix.server
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: '${vnetName}-subnet-client'
        properties: {
          addressPrefix: subnetPrefix.client
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

output vnetId string = vnet.id

output subnetIds object = {
  dc: resourceId(
    'Microsoft.Network/virtualNetworks/subnets',
    vnet.name,
    '${vnetName}-subnet-dc'
  )
  server: resourceId(
    'Microsoft.Network/virtualNetworks/subnets',
    vnet.name,
    '${vnetName}-subnet-server'
  )
  client: resourceId(
    'Microsoft.Network/virtualNetworks/subnets',
    vnet.name,
    '${vnetName}-subnet-client'
  )
}
