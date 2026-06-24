param vnetName string
param location string
param addressPrefix string
param subnetPrefix object
param dnsServers array = []
param tags object = {}

var nsgRules = {
  dc: [
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
  jumpbox: [
    {
      name: 'Allow-RDP-From-Approved-Internet'
      port: '3389'
      source: [
        '168.210.156.0/24'
        '137.158.0.0/16'
        '197.239.0.0/16'
        '196.24.0.0/16'
        '196.42.0.0/16'
        '196.47.0.0/16'
      ]
    }
  ]
  server: [
    {
      name: 'Allow-SSH'
      port: '22'
      source: '10.0.0.0/8'
    }
  ]
  client: [
    {
      name: 'Allow-RDP'
      port: '3389'
      source: subnetPrefix.jumpbox
    }
  ]
}

var subnetNames = {
  dc: '${vnetName}-subnet-dc'
  server: '${vnetName}-subnet-server'
  client: '${vnetName}-subnet-client'
  jumpbox: '${vnetName}-subnet-jumpbox'
}

module nsgDc 'nsg.bicep' = {
  name: '${vnetName}-nsg-dc'
  params: {
    nsgName: '${vnetName}-nsg-dc'
    location: location
    tags: tags
    rules: nsgRules.dc
  }
}

module nsgJumpbox 'nsg.bicep' = {
  name: '${vnetName}-nsg-jumpbox'
  params: {
    nsgName: '${vnetName}-nsg-jumpbox'
    location: location
    tags: tags
    rules: nsgRules.jumpbox
  }
}

module nsgServer 'nsg.bicep' = {
  name: '${vnetName}-nsg-server'
  params: {
    nsgName: '${vnetName}-nsg-server'
    location: location
    tags: tags
    rules: nsgRules.server
  }
}

module nsgClient 'nsg.bicep' = {
  name: '${vnetName}-nsg-client'
  params: {
    nsgName: '${vnetName}-nsg-client'
    location: location
    tags: tags
    rules: nsgRules.client
  }
}

module subnetDc 'subnet.bicep' = {
  name: '${vnetName}-subnet-dc'
  dependsOn: [
    vnet
  ]
  params: {
    vnetName: vnetName
    subnetName: subnetNames.dc
    addressPrefix: subnetPrefix.dc
    nsgId: nsgDc.outputs.nsgId
  }
}

module subnetJumpbox 'subnet.bicep' = {
  name: '${vnetName}-subnet-jumpbox'
  dependsOn: [
    subnetDc
  ]
  params: {
    vnetName: vnetName
    subnetName: subnetNames.jumpbox
    addressPrefix: subnetPrefix.jumpbox
    nsgId: nsgJumpbox.outputs.nsgId
  }
}

module subnetServer 'subnet.bicep' = {
  name: '${vnetName}-subnet-server'
  dependsOn: [
    subnetJumpbox
  ]
  params: {
    vnetName: vnetName
    subnetName: subnetNames.server
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
    subnetName: subnetNames.client
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
output vnetName string = vnet.name

output subnets object = {
  dc: {
    id: subnetDc.outputs.subnetId
    name: subnetNames.dc
  }
  jumpbox: {
    id: subnetJumpbox.outputs.subnetId
    name: subnetNames.jumpbox
  }
  server: {
    id: subnetServer.outputs.subnetId
    name: subnetNames.server
  }
  client: {
    id: subnetClient.outputs.subnetId
    name: subnetNames.client
  }
}
