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

param serverSubnetName string
param clientSubnetName string

// ========================================
// RESOURCE CREATED: ROUTE TABLES
// One route table per subnet role.
// ========================================

// Server route table
// Default outbound traffic is forced through the firewall next hop so workload subnets no longer use direct Internet egress.
resource rtServer 'Microsoft.Network/routeTables@2023-02-01' = {
  name: '${serverSubnetName}-rt'
  location: location
  properties: {
    routes: [
      {
        name: 'route-internal-to-hub'
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

// Client route table
// Default outbound traffic is forced through the firewall next hop so workload subnets no longer use direct Internet egress.
resource rtClient 'Microsoft.Network/routeTables@2023-02-01' = {
  name: '${clientSubnetName}-rt'
  location: location
  properties: {
    routes: [
      {
        name: 'route-internal-to-hub'
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

output serverRouteTableId string = rtServer.id

output clientRouteTableId string = rtClient.id
