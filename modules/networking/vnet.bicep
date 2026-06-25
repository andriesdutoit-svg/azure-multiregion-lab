param vnetName string
param location string
param addressPrefix string
param subnetPrefix object
param dnsServers array = []
param jumpboxSubnets array
param jumpboxAllowedSources array
param enableClientSsh bool
param tags object = {}

var internalNetworkRange = '10.0.0.0/8'

var nsgRules = {
  dc: [
    {
      name: 'Allow-DNS'
      port: '53'
      access: 'Allow'
      source: [
        internalNetworkRange
      ]
    }
    {
      name: 'Allow-Kerberos'
      port: '88'
      access: 'Allow'
      source: [
        internalNetworkRange
      ]
    }
    {
      name: 'Allow-LDAP'
      port: '389'
      access: 'Allow'
      source: [
        internalNetworkRange
      ]
    }
    {
      name: 'Allow-LDAPS'
      port: '636'
      access: 'Allow'
      source: [
        internalNetworkRange
      ]
    }
    {
      name: 'Allow-RPC-Endpoint-Mapper'
      port: '135'
      access: 'Allow'
      source: [
        internalNetworkRange
      ]
    }
    {
      name: 'Allow-RPC-Dynamic'
      port: '49152-65535'
      access: 'Allow'
      source: [
        internalNetworkRange
      ]
    }
    {
      name: 'Allow-RDP-From-Jumpbox'
      port: '3389'
      access: 'Allow'
      source: jumpboxSubnets
    }
    {
      name: 'Deny-RDP-From-Others'
      port: '3389'
      access: 'Deny'
      source: [
        internalNetworkRange
      ]
    }
  ]
  jumpbox: [
    {
      name: 'Allow-RDP-From-Approved-Internet'
      port: '3389'
      access: 'Allow'
      source: jumpboxAllowedSources
    }
  ]
  // server includes Windows servers and Linux servers, need to allow SSH and RDP from jumpbox and DCs, but deny all other SSH and RDP traffic
  server: [
    {
      name: 'Allow-SSH-From-Jumpbox'
      port: '22'
      access: 'Allow'
      source: jumpboxSubnets
    }
    {
      name: 'Deny-SSH-From-Others'
      port: '22'
      access: 'Deny'
      source: [
        internalNetworkRange
      ]
    }
    {
      name: 'Allow-DNS'
      port: '53'
      access: 'Allow'
      source: [
        internalNetworkRange
      ]
    }
    {
      name: 'Allow-Kerberos'
      port: '88'
      access: 'Allow'
      source: [
        internalNetworkRange
      ]
    }
    {
      name: 'Allow-LDAP'
      port: '389'
      access: 'Allow'
      source: [
        internalNetworkRange
      ]
    }
    {
      name: 'Allow-RDP-From-Jumpbox'
      port: '3389'
      access: 'Allow'
      source: jumpboxSubnets
    }
    {
      name: 'Deny-RDP-From-Others'
      port: '3389'
      access: 'Deny'
      source: [
        internalNetworkRange
      ]
    }
  ]  
  client: concat(
    enableClientSsh ? [
      {
        name: 'Allow-SSH-From-Jumpbox'
        port: '22'
        access: 'Allow'
        source: jumpboxSubnets
      }
      {
        name: 'Deny-SSH-From-Others'
        port: '22'
        access: 'Deny'
        source: [
          internalNetworkRange
        ]
      }
    ] : [],
    [
      {
        name: 'Allow-RDP-From-Jumpbox'
        port: '3389'
        access: 'Allow'
        source: jumpboxSubnets
      }
      {
        name: 'Deny-RDP-From-Others'
        port: '3389'
        access: 'Deny'
        source: [
          internalNetworkRange
        ]
      }
    ]
  )
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
