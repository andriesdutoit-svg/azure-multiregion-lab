// ========================================
// MODULE PURPOSE
// Creates server/client route tables and attaches them to existing subnets.
// Routes internal traffic (10.0.0.0/8) to the hub firewall next hop.
// ========================================

// ========================================
// INPUTS
// Location, next hop, subnet identity/prefix, and NSG IDs for server and client paths.
// ========================================

param location string
param nextHopIp string

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

var vnetId = substring(serverSubnetId, 0, indexOf(serverSubnetId, '/subnets/'))

// Server subnet name from ARM ID
var serverSubnetName = last(split(serverSubnetId, '/subnets/'))

// Client subnet name from ARM ID
var clientSubnetName = last(split(clientSubnetId, '/subnets/'))

// ========================================
// RESOURCE CREATED: ROUTE TABLES
// One route table per subnet role (server/client).
// ========================================

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
