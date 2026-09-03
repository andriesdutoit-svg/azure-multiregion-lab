targetScope = 'resourceGroup'

// ========================================
// MODULE PURPOSE
// Creates the server and client subnets for a spoke region and attaches their
// pre-created route tables so workload traffic is forced through the hub firewall.
// ========================================

param vnetName string
param subnetNames object
param subnetPrefixes object
param nsgIds object
param serverRouteTableId string
param clientRouteTableId string

module subnetServer 'subnet.bicep' = {
  name: '${vnetName}-subnet-server'

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

output serverSubnetId string = subnetServer.outputs.subnetId

output clientSubnetId string = subnetClient.outputs.subnetId
