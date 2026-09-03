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
param addressPrefix string
param subnetPrefix object
param isHub bool
param dnsServers array
param jumpboxSubnets array
param existingRegions array = []
param jumpboxAllowedSources array
param tags object = {}

// ========================================
// SECURITY RULE BUILDING BLOCKS
// Base rule arrays reused to build role-specific NSG rule sets.
// ========================================

var isExistingRegion = contains(existingRegions, location)

var createSubnets = !isExistingRegion

var internalNetworkRange = '10.0.0.0/8'

// ========================================
// SECURITY RULE BUILDING BLOCKS
// Rule arrays are composed by role-specific NSG to enforce segmentation:
// - adRules: Core AD services (DNS, Kerberos, LDAP) for domain join
// - adAdvancedRules: Advanced AD services (NTP, Global Catalog, LDAPS, RPC)
// - jumpboxRules: SSH inbound + AD client access (for domain join)
// - serverRules: Workload services (WinRM, SSH) + AD access
// - clientRules: AD access only (for domain join)
// - firewallRules: Internal + VPN routing
// Each role-specific NSG combines the applicable rule sets.
// ========================================

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
    name: 'Allow-NTP'
    port: '123'
    access: 'Allow'
    source: [
      internalNetworkRange
    ]
  }
  {
    name: 'Allow-Kerberos-Password-Change'
    port: '464'
    access: 'Allow'
    source: [
      internalNetworkRange
    ]
  }
  {
    name: 'Allow-SMB'
    port: '445'
    access: 'Allow'
    source: [
      internalNetworkRange
    ]
  }
  {
    name: 'Allow-Global-Catalog'
    port: '3268'
    access: 'Allow'
    source: [
      internalNetworkRange
    ]
  }
  {
    name: 'Allow-Global-Catalog-SSL'
    port: '3269'
    access: 'Allow'
    source: [
      internalNetworkRange
    ]
  }
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
    sshRules,
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
// CORE RESOURCE: VNET
// Always created by this module.
// ========================================

resource existingVnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = if (isExistingRegion) {
  name: vnetName
}

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' = if (!isExistingRegion) {
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
// CONDITIONAL MODULE DEPLOYMENTS (createSubnets = true)
// 1) Optional hub firewall subnet
// 2) NSGs per role
// 3) Subnets per role with NSG association
// ========================================

module nsgDc 'nsg.bicep' = if (createSubnets) {
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

module nsgJumpbox 'nsg.bicep' = if (createSubnets) {
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

module nsgServer 'nsg.bicep' = if (createSubnets) {
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

module nsgClient 'nsg.bicep' = if (createSubnets) {
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

module subnetDc 'subnet.bicep' = if (createSubnets) {
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

module subnetJumpbox 'subnet.bicep' = if (createSubnets) {
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

// Server and client subnet creation moved to main.bicep

module subnetHub 'subnet.bicep' = if (isHub && createSubnets) {
  name: 'AzureFirewallSubnet'
  dependsOn: [
    subnetJumpbox
  ]
  params: {
    vnetName: vnetName
    subnetName: 'AzureFirewallSubnet'
    addressPrefix: subnetPrefix.firewall
    nsgId: ''
  }
}

// ========================================
// EXISTING RESOURCE REFERENCES
// In brownfield deployments (isExistingRegion=true), networking resources are not created by this module.
// Existing resource references allow safe ID resolution without module.outputs access,
// avoiding null-reference errors in conditional-module paths.
// ========================================


resource subnetClientExisting 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: existingVnet
  name: '${vnetName}-subnet-client'
}

resource subnetDcExisting 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: existingVnet
  name: '${vnetName}-subnet-dc'
}

resource subnetJumpboxExisting 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: existingVnet
  name: '${vnetName}-subnet-jumpbox'
}

resource subnetServerExisting 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: existingVnet
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
// NSG ID RESOLUTION
// Greenfield (create new) or brownfield (reuse existing) NSG ID selection.
// ========================================


var serverNsgId = createSubnets ? nsgServer!.outputs.nsgId : nsgServerExisting.id
var clientNsgId = createSubnets ? nsgClient!.outputs.nsgId : nsgClientExisting.id
var dcNsgId = createSubnets ? nsgDc!.outputs.nsgId : nsgDcExisting.id
var jumpboxNsgId = createSubnets ? nsgJumpbox!.outputs.nsgId : nsgJumpboxExisting.id

// ========================================
// OUTPUTS
// VNet metadata plus normalised NSG/subnet objects for downstream modules.
// ========================================

output vnetId string = isExistingRegion
  ? existingVnet.id
  : vnet.id

output vnetName string = isExistingRegion
  ? existingVnet.name
  : vnet.name

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
// Resolves to newly-created subnets from modules (greenfield) or existing subnets (brownfield).

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

output isExistingRegion bool = isExistingRegion
output subnetNames object = subnetNames
output subnetPrefixes object = subnetPrefix
output createSubnets bool = createSubnets

output nsgIds object = {
  dc: dcNsgId
  jumpbox: jumpboxNsgId
  server: serverNsgId
  client: clientNsgId
}

output isHub bool = isHub
