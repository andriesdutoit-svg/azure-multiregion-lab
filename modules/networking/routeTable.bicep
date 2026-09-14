// ========================================
// MODULE PURPOSE
// Creates route tables for spoke DC, jumpbox, server, and client subnets.
// Route table association is handled elsewhere.
// ========================================

// ========================================
// INPUTS
// Location, firewall next hop, and managed spoke subnet names.
// ========================================

param location string
param nextHopIp string

param dcSubnetName string
param jumpboxSubnetName string
param serverSubnetName string
param clientSubnetName string

// ========================================
// RESOURCE CREATED: ROUTE TABLES
// One route table per subnet role.
// ========================================

// Spoke DCs send private cross-spoke traffic through the hub firewall.
// Internet traffic remains direct because this route table has no default route.
resource rtDc 'Microsoft.Network/routeTables@2023-02-01' = {
  name: '${dcSubnetName}-rt'
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
    ]
  }
}

// Spoke jumpboxes use the firewall only for internal cross-spoke traffic.
resource rtJumpbox 'Microsoft.Network/routeTables@2023-02-01' = {
  name: '${jumpboxSubnetName}-rt'
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
    ]
  }
}

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

output dcRouteTableId string = rtDc.id
output jumpboxRouteTableId string = rtJumpbox.id
output serverRouteTableId string = rtServer.id

output clientRouteTableId string = rtClient.id
