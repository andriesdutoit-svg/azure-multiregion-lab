param vnetName string
param location string
param addressPrefix string
param subnetPrefix object
param dnsServers array = []
param tags object = {}

var dcRules = [
  {
    name: 'Allow-DNS'
    port: '53'
  }
  {
    name: 'Allow-Kerberos'
    port: '88'
  }
  {
    name: 'Allow-LDAP'
    port: '389'
  }
  {
    name: 'Allow-RDP'
    port: '3389'
  }
]

var serverRules = [
  {
    name: 'Allow-SSH'
    port: '22'
  }
]

var clientRules = [
  {
    name: 'Allow-RDP'
    port: '3389'
  }
]

resource nsgDc 'Microsoft.Network/networkSecurityGroups@2022-09-01' = {
  name: '${vnetName}-nsg-dc'
  location: location
  tags: tags
  properties: {
    securityRules: [
      for (rule, index) in dcRules: {
        name: rule.name
        properties: {
          priority: 1000 + index
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: rule.port
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nsgServer 'Microsoft.Network/networkSecurityGroups@2022-09-01' = {
  name: '${vnetName}-nsg-server'
  location: location
  tags: tags
  properties: {
    securityRules: [
      for (rule, index) in serverRules: {
        name: rule.name
        properties: {
          priority: 1000 + index
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: rule.port
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nsgClient 'Microsoft.Network/networkSecurityGroups@2022-09-01' = {
  name: '${vnetName}-nsg-client'
  location: location
  tags: tags
  properties: {
    securityRules: [
      for (rule, index) in clientRules: {
        name: rule.name
        properties: {
          priority: 1000 + index
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: rule.port
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
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
            id: nsgDc.id
          }
        }
      }
      {
        name: '${vnetName}-subnet-server'
        properties: {
          addressPrefix: subnetPrefix.server
          networkSecurityGroup: {
            id: nsgServer.id
          }
        }
      }
      {
        name: '${vnetName}-subnet-client'
        properties: {
          addressPrefix: subnetPrefix.client
          networkSecurityGroup: {
            id: nsgClient.id
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
