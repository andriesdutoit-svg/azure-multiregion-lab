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
    source: '10.0.0.0/8'
  }
  {
    name: 'Allow-Kerberos'
    port: '88'
    source: '10.0.0.0/8'
  }
  {
    name: 'Allow-LDAP'
    port: '389'
    source: '10.0.0.0/8'
  }
  {
    name: 'Allow-RDP'
    port: '3389'
    source: '10.0.0.0/8'
  }
]

var serverRules = [
  {
    name: 'Allow-SSH'
    port: '22'
    source: '10.0.0.0/8'
  }
]

var clientRules = [
  {
    name: 'Allow-RDP'
    port: '3389'
    source: '10.0.0.0/8'
  }
]

module nsgDc 'nsg.bicep' = {
  name: '${vnetName}-nsg-dc'
  params: {
    nsgName: '${vnetName}-nsg-dc'
    location: location
    tags: tags
    rules: dcRules
  }
}

module nsgServer 'nsg.bicep' = {
  name: '${vnetName}-nsg-server'
  params: {
    nsgName: '${vnetName}-nsg-server'
    location: location
    tags: tags
    rules: serverRules
  }
}

module nsgClient 'nsg.bicep' = {
  name: '${vnetName}-nsg-client'
  params: {
    nsgName: '${vnetName}-nsg-client'
    location: location
    tags: tags
    rules: clientRules
  }
}

module subnetDc 'subnet.bicep' = {
  name: '${vnetName}-subnet-dc'
  dependsOn: [
    vnet
  ]
  params: {
    vnetName: vnetName
    subnetName: '${vnetName}-subnet-dc'
    addressPrefix: subnetPrefix.dc
    nsgId: nsgDc.outputs.nsgId
  }
}

module subnetServer 'subnet.bicep' = {
  name: '${vnetName}-subnet-server'
  dependsOn: [
    subnetDc
  ]
  params: {
    vnetName: vnetName
    subnetName: '${vnetName}-subnet-server'
    addressPrefix: subnetPrefix.server
    nsgId: nsgServer.outputs.nsgId
  }
}

module subnetClient 'subnet.bicep' = {
  name: '${vnetName}-subnet-client'
  dependsOn: [
    subnetServer
  ]
  params: {
    vnetName: vnetName
    subnetName: '${vnetName}-subnet-client'
    addressPrefix: subnetPrefix.client
    nsgId: nsgClient.outputs.nsgId
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
  }
}

output vnetId string = vnet.id

output subnetIds object = {
  dc: subnetDc.outputs.subnetId
  server: subnetServer.outputs.subnetId
  client: subnetClient.outputs.subnetId
}
