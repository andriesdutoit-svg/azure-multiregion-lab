param location string
param nextHopIp string

// Server subnet inputs
param serverSubnetId string
param serverSubnetPrefix string
param serverNsgId string

// Client subnet inputs
param clientSubnetId string
param clientSubnetPrefix string
param clientNsgId string

//
// ========================================
// EXTRACT NAMES (from subnet IDs)
// ========================================
//

var vnetId = substring(serverSubnetId, 0, indexOf(serverSubnetId, '/subnets/'))
var vnetName = last(split(vnetId, '/virtualNetworks/'))

// Server
var serverSubnetName = last(split(serverSubnetId, '/subnets/'))

// Client
var clientSubnetName = last(split(clientSubnetId, '/subnets/'))

//
// ========================================
// EXISTING VNET REFERENCE
// ========================================
//

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

//
// ========================================
// ROUTE TABLES
// ========================================
//

// Server route table
resource rtServer 'Microsoft.Network/routeTables@2023-02-01' = {
  name: '${serverSubnetName}-rt'
  location: location
  properties: {
    routes: [
      {
        name: 'route-all-to-hub'
        properties: {
          addressPrefix: '10.0.0.0/8'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nextHopIp
        }
      }
    ]
  }
}

// Client route table
resource rtClient 'Microsoft.Network/routeTables@2023-02-01' = {
  name: '${clientSubnetName}-rt'
  location: location
  properties: {
    routes: [
      {
        name: 'route-all-to-hub'
        properties: {
          addressPrefix: '10.0.0.0/8'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nextHopIp
        }
      }
    ]
  }
}

//
// ========================================
// SUBNET UPDATES (ATTACH ROUTE TABLES)
// ========================================
//

// Server subnet update
resource serverSubnetUpdate 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' = {
  name: serverSubnetName
  parent: vnet
  properties: {
    addressPrefix: serverSubnetPrefix

    networkSecurityGroup: {
      id: serverNsgId
    }

    routeTable: {
      id: rtServer.id
    }
  }
}

// Client subnet update
resource clientSubnetUpdate 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' = {
  name: clientSubnetName
  parent: vnet
  properties: {
    addressPrefix: clientSubnetPrefix

    networkSecurityGroup: {
      id: clientNsgId
    }

    routeTable: {
      id: rtClient.id
    }
  }
}
