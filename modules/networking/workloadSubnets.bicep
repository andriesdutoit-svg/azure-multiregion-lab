targetScope = 'resourceGroup'

// ========================================
// MODULE PURPOSE
// Reconciles the DC, jumpbox, server, and client subnets for a spoke region and attaches their
// pre-created route tables so workload traffic is forced through the hub firewall.
// ========================================

param vnetName string
param subnetNames object
param subnetPrefixes object
param nsgIds object
param dcRouteTableId string
param jumpboxRouteTableId string
param serverRouteTableId string
param clientRouteTableId string

module subnetDc 'subnet.bicep' = {
  name: '${vnetName}-subnet-dc'
  params: {
    vnetName: vnetName
    subnetName: subnetNames.dc
    addressPrefix: subnetPrefixes.dc
    nsgId: nsgIds.dc
    routeTableId: dcRouteTableId
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
    addressPrefix: subnetPrefixes.jumpbox
    nsgId: nsgIds.jumpbox
    routeTableId: jumpboxRouteTableId
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
    addressPrefix: subnetPrefixes.server
    nsgId: nsgIds.server
    routeTableId: serverRouteTableId
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
    addressPrefix: subnetPrefixes.client
    nsgId: nsgIds.client
    routeTableId: clientRouteTableId
  }
}

output dcSubnetId string = subnetDc.outputs.subnetId
output jumpboxSubnetId string = subnetJumpbox.outputs.subnetId
output serverSubnetId string = subnetServer.outputs.subnetId

output clientSubnetId string = subnetClient.outputs.subnetId
