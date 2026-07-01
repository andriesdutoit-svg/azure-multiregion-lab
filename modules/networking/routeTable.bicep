param location string
param nextHopIp string

// ========================================
// INPUTS
// Next hop + subnet identity/prefix + NSG IDs for server and client paths.
// ========================================

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
// MODULE PURPOSE
// Creates server/client route tables and attaches them to existing subnets.
// Routes internal traffic (10.0.0.0/8) to the hub firewall next hop.
// ========================================
//

// ========================================
// DERIVED IDENTIFIERS
// Parse VNet and subnet names from subnet ARM IDs.
// Assumes subnet IDs are valid full ARM resource IDs.
// ========================================
//

var vnetId = substring(serverSubnetId, 0, indexOf(serverSubnetId, '/subnets/'))
var vnetName = last(split(vnetId, '/virtualNetworks/'))

// Server subnet name from ARM ID
var serverSubnetName = last(split(serverSubnetId, '/subnets/'))

// Client subnet name from ARM ID
var clientSubnetName = last(split(clientSubnetId, '/subnets/'))

//
// ========================================
// EXISTING DEPENDENCY: TARGET VNET
// ========================================
//

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

//
// ========================================
// RESOURCE CREATED: ROUTE TABLES
// One route table per subnet role (server/client).
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
// SUBNET UPDATES
// Re-apply subnet prefix + NSG and attach route table association.
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
  dependsOn: [
    serverSubnetUpdate
  ]
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
