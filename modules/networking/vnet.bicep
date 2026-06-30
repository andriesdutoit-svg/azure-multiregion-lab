// ========================================
// MODULE PURPOSE
// Creates a VNet and, optionally, NSGs/subnets for role-based segmentation.
// Supports greenfield (create) and brownfield (reuse existing) flows.
// ========================================

// ========================================
// INPUTS
// ========================================

param vnetName string
param location string
param deploySubnets bool
param addressPrefix string
param subnetPrefix object
param regionIndex int
param hubSubnetIndex int
param isHub bool
param dnsServers array
param jumpboxSubnets array
param jumpboxAllowedSources array
param enableClientSsh bool
param tags object = {}

// ========================================
// SECURITY RULE BUILDING BLOCKS
// Base rule arrays reused to build role-specific NSG rule sets.
// ========================================

var internalNetworkRange = '10.0.0.0/8'

var adRules = [
  {
    name: 'Allow-DNS'
    port: '53'
    access: 'Allow'
    source: [
      internalNetworkRange
    ]
  }
  {
    name: 'Allow-Kerberos'
    port: '88'
    access: 'Allow'
    source: [
      internalNetworkRange
    ]
  }
  {
    name: 'Allow-LDAP'
    port: '389'
    access: 'Allow'
    source: [
      internalNetworkRange
    ]
  }
]

var adAdvancedRules = [
  {
    name: 'Allow-LDAPS'
    port: '636'
    access: 'Allow'
    source: [
      internalNetworkRange
    ]
  }
  {
    name: 'Allow-RPC-Endpoint-Mapper'
    port: '135'
    access: 'Allow'
    source: [
      internalNetworkRange
    ]
  }
  {
    name: 'Allow-RPC-Dynamic'
    port: '49152-65535'
    access: 'Allow'
    source: [
      internalNetworkRange
    ]
  }
]

var rdpRules = [
  {
    name: 'Allow-RDP-From-Jumpbox'
    port: '3389'
    access: 'Allow'
    source: jumpboxSubnets
  }
  {
    name: 'Deny-RDP-From-Others'
    port: '3389'
    access: 'Deny'
    source: [
      internalNetworkRange
    ]
  }
]

var sshRules = [
  {
    name: 'Allow-SSH-From-Jumpbox'
    port: '22'
    access: 'Allow'
    source: jumpboxSubnets
  }
  {
    name: 'Deny-SSH-From-Others'
    port: '22'
    access: 'Deny'
    source: [
      internalNetworkRange
    ]
  }
]

// ========================================
// ROLE-BASED NSG RULE COMPOSITION
// Final NSG policy payloads per subnet role.
// ========================================

var nsgRules = {
  dc: concat(
    adRules,
    adAdvancedRules,
    rdpRules
  )
  jumpbox: [
    {
      name: 'Allow-RDP-From-Approved-Internet'
      port: '3389'
      access: 'Allow'
      source: jumpboxAllowedSources
    }
  ]
  server: concat(
    sshRules,
    rdpRules,
    adRules
  )  
  client: concat(
    enableClientSsh ? sshRules : [],
    rdpRules
  )
}

// ========================================
// NAMING MODEL
// Deterministic subnet names derived from vnetName.
// ========================================

var subnetNames = {
  dc: '${vnetName}-subnet-dc'
  server: '${vnetName}-subnet-server'
  client: '${vnetName}-subnet-client'
  jumpbox: '${vnetName}-subnet-jumpbox'
}

// ========================================
// CONDITIONAL MODULE DEPLOYMENTS (deploySubnets = true)
// 1) Optional hub firewall subnet
// 2) NSGs per role
// 3) Subnets per role with NSG association
// ========================================

module nsgDc 'nsg.bicep' = if (deploySubnets) {
  name: '${vnetName}-nsg-dc'
  params: {
    nsgName: '${vnetName}-nsg-dc'
    location: location
    tags: union(tags, {
      role: 'dc-nsg'
    })
    rules: nsgRules.dc
  }
}

module nsgJumpbox 'nsg.bicep' = if (deploySubnets) {
  name: '${vnetName}-nsg-jumpbox'
  params: {
    nsgName: '${vnetName}-nsg-jumpbox'
    location: location
    tags: union(tags, {
      role: 'jumpbox-nsg'
    })
    rules: nsgRules.jumpbox
  }
}

module nsgServer 'nsg.bicep' = if (deploySubnets) {
  name: '${vnetName}-nsg-server'
  params: {
    nsgName: '${vnetName}-nsg-server'
    location: location
    tags: union(tags, {
      role: 'server-nsg'
    })
    rules: nsgRules.server
  }
}

module nsgClient 'nsg.bicep' = if (deploySubnets) {
  name: '${vnetName}-nsg-client'
  params: {
    nsgName: '${vnetName}-nsg-client'
    location: location
    tags: union(tags, {
      role: 'client-nsg'
    })
    rules: nsgRules.client
  }
}

module subnetDc 'subnet.bicep' = if (deploySubnets) {
  name: '${vnetName}-subnet-dc'
  dependsOn: [
    vnet
  ]
  params: {
    vnetName: vnetName
    subnetName: subnetNames.dc
    addressPrefix: subnetPrefix.dc
    nsgId: nsgDc!.outputs.nsgId
  }
}

module subnetJumpbox 'subnet.bicep' = if (deploySubnets) {
  name: '${vnetName}-subnet-jumpbox'
  dependsOn: [
    subnetDc
  ]
  params: {
    vnetName: vnetName
    subnetName: subnetNames.jumpbox
    addressPrefix: subnetPrefix.jumpbox
    nsgId: nsgJumpbox!.outputs.nsgId
  }
}

module subnetServer 'subnet.bicep' = if (deploySubnets) {
  name: '${vnetName}-subnet-server'
  dependsOn: [
    subnetJumpbox
  ]
  params: {
    vnetName: vnetName
    subnetName: subnetNames.server
    addressPrefix: subnetPrefix.server
    nsgId: nsgServer!.outputs.nsgId
  }
}

module subnetClient 'subnet.bicep' = if (deploySubnets) {
  name: '${vnetName}-subnet-client'
  dependsOn: [
    subnetServer
  ]
  params: {
    vnetName: vnetName
    subnetName: subnetNames.client
    addressPrefix: subnetPrefix.client
    nsgId: nsgClient!.outputs.nsgId
  }
}

module subnetHub 'subnet.bicep' = if (isHub && deploySubnets) {
  name: 'AzureFirewallSubnet'
  dependsOn: [
    subnetClient
  ]
  params: {
    vnetName: vnetName
    subnetName: 'AzureFirewallSubnet'
    addressPrefix: '10.${regionIndex}.${hubSubnetIndex}.0/24'
    nsgId: ''
  }
}

// ========================================
// CORE RESOURCE: VNET
// Always created by this module.
// ========================================

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    dhcpOptions: {
      dnsServers: dnsServers
    }
  }
}

// ========================================
// EXISTING RESOURCE REFERENCES
// Used for safe ID resolution and brownfield compatibility.
// Avoids module.outputs access in conditional-module paths.
// ========================================

resource subnetClientExisting 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: vnet
  name: '${vnetName}-subnet-client'
}

resource subnetDcExisting 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: vnet
  name: '${vnetName}-subnet-dc'
}

resource subnetJumpboxExisting 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: vnet
  name: '${vnetName}-subnet-jumpbox'
}

resource subnetServerExisting 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: vnet
  name: '${vnetName}-subnet-server'
}

resource nsgDcExisting 'Microsoft.Network/networkSecurityGroups@2022-07-01' existing = {
  name: '${vnetName}-nsg-dc'
}

resource nsgJumpboxExisting 'Microsoft.Network/networkSecurityGroups@2022-07-01' existing = {
  name: '${vnetName}-nsg-jumpbox'
}

resource nsgServerExisting 'Microsoft.Network/networkSecurityGroups@2022-07-01' existing = {
  name: '${vnetName}-nsg-server'
}

resource nsgClientExisting 'Microsoft.Network/networkSecurityGroups@2022-07-01' existing = {
  name: '${vnetName}-nsg-client'
}

// ========================================
// ID RESOLUTION
// Unified IDs for both create and reuse paths.
// ========================================

var clientSubnetId = subnetClientExisting.id
var dcSubnetId = subnetDcExisting.id
var jumpboxSubnetId = subnetJumpboxExisting.id
var serverSubnetId = subnetServerExisting.id

// ========================================
// NSG ID RESOLUTION (GREENFIELD + BROWNFIELD)
// ========================================

var serverNsgId = deploySubnets ? nsgServer!.outputs.nsgId : nsgServerExisting.id
var clientNsgId = deploySubnets ? nsgClient!.outputs.nsgId : nsgClientExisting.id
var dcNsgId = deploySubnets ? nsgDc!.outputs.nsgId : nsgDcExisting.id
var jumpboxNsgId = deploySubnets ? nsgJumpbox!.outputs.nsgId : nsgJumpboxExisting.id

// ========================================
// OUTPUTS
// VNet metadata plus normalized NSG/subnet objects for downstream modules.
// ========================================

output vnetId string = vnet.id
output vnetName string = vnet.name

output nsgs object = {
  server: serverNsgId
  client: clientNsgId
  dc: dcNsgId
  jumpbox: jumpboxNsgId
}

// ========================================
// SUBNET OUTPUTS
// ========================================
// Resolve subnet IDs using existing resource references.
// Avoids module.outputs access because subnet modules are conditional (module | null).
// Works for both new and existing deployments.


output subnets object = {
  client: {
    id: clientSubnetId
  }
  dc: {
    id: dcSubnetId
  }
  jumpbox: {
    id: jumpboxSubnetId
  }
  server: {
    id: serverSubnetId
  }
}
