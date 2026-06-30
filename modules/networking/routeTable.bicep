param routeTableName string
param location string
param nextHopIp string
param subnetId string

// Create route table
resource routeTable 'Microsoft.Network/routeTables@2023-02-01' = {
  name: routeTableName
  location: location
  properties: {
    routes: [
      {
        name: 'force-internal-through-hub'
        properties: {
          addressPrefix: '10.0.0.0/8'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nextHopIp
        }
      }
    ]
  }
}

// Extract names
var subnetName = last(split(subnetId, '/subnets/'))
var vnetId = substring(subnetId, 0, indexOf(subnetId, '/subnets/'))
var vnetName = last(split(vnetId, '/virtualNetworks/'))

// Reference existing VNet correctly (NO id here)
resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

// Attach route table to subnet
resource subnetUpdate 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' = {
  name: subnetName
  parent: vnet
  properties: {
    routeTable: {
      id: routeTable.id
    }
  }
}
