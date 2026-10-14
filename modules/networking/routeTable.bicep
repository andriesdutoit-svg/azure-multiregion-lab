// Creates route tables for spoke DC, jumpbox, server, and client subnets.
// roleSubnets.bicep owns subnet association; this module defines route-table contents only.
// Control-plane subnets receive internal-range routes; workload subnets also receive a default route.
// The firewall private IP is supplied by the caller. Disabling this module does not delete old route tables.

// 1. Location, firewall next hop, and role subnet names
param location string
param nextHopIp string

param dcSubnetName string
param jumpboxSubnetName string
param serverSubnetName string
param clientSubnetName string

// 2. Control-plane route tables

// Spoke DCs send private cross-spoke traffic through the hub firewall.
// No default Internet route is declared here; other network settings still govern egress.
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

// 3. Workload route tables
// Server and client default routes send outbound traffic to the firewall next hop.
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

// 4. Association IDs by role
output dcRouteTableId string = rtDc.id
output jumpboxRouteTableId string = rtJumpbox.id
output serverRouteTableId string = rtServer.id
output clientRouteTableId string = rtClient.id
