// ========================================
// MODULE PURPOSE
// Creates route tables for DC, Jumpbox, Server, and Client subnets.
// Route table association is handled elsewhere.
// ========================================

// ========================================
// INPUTS
// Location, next hop, subnet identity/prefix, and NSG IDs for server and client paths.
// ========================================

param location string
param nextHopIp string

// DC subnet inputs
param dcSubnetId string

// Jumpbox subnet inputs
param jumpboxSubnetId string

// Server subnet inputs
param serverSubnetId string

// Client subnet inputs
param clientSubnetId string

// ========================================
// DERIVED IDENTIFIERS
// Parse VNet and subnet names from subnet ARM IDs.
// Assumes subnet IDs are valid full ARM resource IDs.
// ========================================
//

// Subnets

var dcSubnetName = last(split(dcSubnetId, '/subnets/'))

var jumpboxSubnetName = last(split(jumpboxSubnetId, '/subnets/'))

var serverSubnetName = last(split(serverSubnetId, '/subnets/'))

var clientSubnetName = last(split(clientSubnetId, '/subnets/'))

// ========================================
// RESOURCE CREATED: ROUTE TABLES
// One route table per subnet role.
// ========================================

resource rtDc 'Microsoft.Network/routeTables@2023-02-01' = {
  name: '${dcSubnetName}-rt'
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
      {
        name: 'route-internet-to-hub'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nextHopIp
        }
      }
    ]
  }
}

resource rtJumpbox 'Microsoft.Network/routeTables@2023-02-01' = {
  name: '${jumpboxSubnetName}-rt'
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

// Server route table
resource rtServer 'Microsoft.Network/routeTables@2023-02-01' = {
  name: '${serverSubnetName}-rt'
  location: location
  properties: {
    routes: [
      {
        name: 'route-all-to-hub'
        properties: {
          // 10.0.0.0/8 is the global internal address space (environment-wide constant).
          // All regions' VNets use /16 subnets within this range, so this single route
          // covers inter-region and intra-region traffic. Hardcoded to match environment topology.
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
          // 10.0.0.0/8 is the global internal address space (environment-wide constant).
          // All regions' VNets use /16 subnets within this range, so this single route
          // covers inter-region and intra-region traffic. Hardcoded to match environment topology.
          addressPrefix: '10.0.0.0/8'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nextHopIp
        }
      }
    ]
  }
}

output dcRouteTableId string = rtDc.id

output jumpboxRouteTableId string = rtJumpbox.id

output serverRouteTableId string = rtServer.id

output clientRouteTableId string = rtClient.id
