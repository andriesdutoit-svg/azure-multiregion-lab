targetScope = 'resourceGroup'

// Reconciles the standard role subnets for a spoke and attaches their route tables.
// Consumes the VNet module's role names, prefixes, and NSG IDs plus explicit routing IDs.
// Existing subnets receive the supplied configuration; this is not discovery, migration, or obsolete-subnet cleanup.

// 1. Parent VNet and role configuration
param vnetName string
param subnetNames object
param subnetPrefixes object
param nsgIds object

// Explicit route associations; empty IDs declare no route table in non-firewall modes.
param dcRouteTableId string
param jumpboxRouteTableId string
param serverRouteTableId string
param clientRouteTableId string

// 2. Serialized subnet updates
// Each dependency protects the shared parent VNet from concurrent child-subnet writes.
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

// 3. Resolved subnet identities by role
output dcSubnetId string = subnetDc.outputs.subnetId
output jumpboxSubnetId string = subnetJumpbox.outputs.subnetId
output serverSubnetId string = subnetServer.outputs.subnetId
output clientSubnetId string = subnetClient.outputs.subnetId
