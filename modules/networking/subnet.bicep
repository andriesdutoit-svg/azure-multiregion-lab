param vnetName string
param subnetName string
param addressPrefix string
param nsgId string

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' = {
  name: subnetName
  parent: vnet
  properties: {
    addressPrefix: addressPrefix
    networkSecurityGroup: empty(nsgId) ? null : {
      id: nsgId
    }
  }
}

output subnetId string = subnet.id
