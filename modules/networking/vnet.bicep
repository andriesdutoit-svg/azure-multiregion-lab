// Regional VNet assembly overview
// Responsibilities:
// - Create a new regional VNet or resolve a declared existing VNet without replacing its properties.
// - Compose and deploy role-specific NSGs, create new hub role subnets, and manage optional hub subnets.
// Create/reuse contract:
// - existingRegions selects the path; it is operator inventory rather than live resource discovery.
// - New VNets receive the declared address space and DNS. Reused VNet address space and DNS are unchanged.
// - NSGs remain managed in both paths. Spoke role-subnet updates belong to roleSubnets.bicep.
// - AzureFirewallSubnet and AzureBastionSubnet can be created/updated on existing hubs when enabled.
// Provides:
// - VNet identity, create/reuse flags, and normalized subnet/NSG objects for network-stage consumers.
// - Stable resource IDs do not themselves confirm that every referenced subnet is already present.

// 1. Parameters
// Resource metadata and declared region state
param vnetName string
param location string
param tags object = {}
param isHub bool
param existingRegions array = []

// Addressing and administrator access
param addressPrefix string
param subnetPrefix object
param dnsServers array
param jumpboxSubnets array
param jumpboxAllowedSources array

// Optional hub infrastructure
param deployAzureFirewallSubnet bool
param enableBastion bool
param bastionSubnetPrefix string

// 2. Create/reuse decisions and policy data
// Declared inventory selects reuse; it is not a live check for VNet existence.
var isExistingRegion = contains(existingRegions, location)

var createSubnets = !isExistingRegion

var internalNetworkRange = '10.0.0.0/8'

// 2.1 Shared service and administrator-access rules
// Building blocks:
// - adRules: DNS, Kerberos, and LDAP from the internal range.
// - adAdvancedRules: NTP, password changes, SMB, Global Catalog, LDAPS, and RPC services.
// - rdpRules/sshRules: allow jumpbox subnet sources before denying other internal sources.
// NSG priority derives from array position. Keep rule and concatenation order unchanged:
// approved jumpbox access rules precede the matching internal deny rules.

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

// 2.2 Role policies
// DCs combine basic/advanced AD services and RDP rules. Servers combine SSH, RDP, and
// basic AD rules; clients combine SSH and RDP rules. Jumpboxes receive the approved-source RDP rule.
// These are managed custom inbound rules, not a complete description of Azure's default NSG rules.
// Bastion enablement does not replace the jumpbox rule or alter retained jumpbox Public IPs.

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

// 2.3 Canonical names and output ID selection

var subnetNames = {
  dc: '${vnetName}-subnet-dc'
  server: '${vnetName}-subnet-server'
  client: '${vnetName}-subnet-client'
  jumpbox: '${vnetName}-subnet-jumpbox'
}

// Existing resource references below supply stable subnet IDs without dereferencing conditional
// subnet-module outputs. NSG selection uses new module outputs on create paths and canonical
// resource IDs on reuse paths, while the NSG modules still manage policy in both paths.
var clientSubnetId = subnetClientExisting.id
var dcSubnetId = subnetDcExisting.id
var jumpboxSubnetId = subnetJumpboxExisting.id
var serverSubnetId = subnetServerExisting.id

var serverNsgId = createSubnets ? nsgServer!.outputs.nsgId : nsgServerExisting.id
var clientNsgId = createSubnets ? nsgClient!.outputs.nsgId : nsgClientExisting.id
var dcNsgId = createSubnets ? nsgDc!.outputs.nsgId : nsgDcExisting.id
var jumpboxNsgId = createSubnets ? nsgJumpbox!.outputs.nsgId : nsgJumpboxExisting.id

// 3. VNet create/reuse paths
// Only the greenfield branch declares VNet properties; existing paths resolve identity only.

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

// 4. Role NSGs and hub subnets
// NSGs are managed in both create and reuse paths. Hub standard subnets are created
// only for new VNets; spoke subnet creation/reconciliation belongs to roleSubnets.bicep.
// Explicit subnet dependencies serialize related VNet writes. The optional firewall/Bastion
// subnet conditions are independent of createSubnets so supported hub additions work in brownfield.

module nsgDc 'nsg.bicep' = {
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

module nsgJumpbox 'nsg.bicep' = {
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

module nsgServer 'nsg.bicep' = {
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

module nsgClient 'nsg.bicep' = {
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

module subnetDc 'subnet.bicep' = if (createSubnets && isHub) {
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

module subnetJumpbox 'subnet.bicep' = if (createSubnets && isHub) {
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

// Spoke standard subnet reconciliation is handled by roleSubnets.bicep.

// AzureFirewallSubnet is created independently of createSubnets to support brownfield
// transitions from hubSpoke to hubSpokeFirewall.
module subnetHub 'subnet.bicep' = if (isHub && deployAzureFirewallSubnet) {
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

// Bastion subnet reconciliation also runs for an existing hub when enabled.
module subnetBastion 'subnet.bicep' = if (isHub && enableBastion) {
  name: 'AzureBastionSubnet'
  dependsOn: [
    subnetJumpbox
  ]
  params: {
    vnetName: vnetName
    subnetName: 'AzureBastionSubnet'
    addressPrefix: bastionSubnetPrefix
    nsgId: ''
  }
}

// 5. Stable subnet and NSG references
// These declarations resolve IDs for create and reuse paths; they do not provision or repair resources.
// They avoid using conditional standard-subnet outputs for ID selection. The network-stage
// orchestration is responsible for creating or reconciling the referenced spoke subnets.

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

// 6. Output contract
// Preserve both NSG object shapes: downstream callers use their existing property names.
// subnetNames, subnetPrefixes, and nsgIds feed spoke role-subnet updates; subnets supplies
// the role ID shape later exposed as network-stage.subnetMap. IDs describe intended resource
// identities, not discovery results or guest/network readiness checks.

// 6.1 VNet identity and create/reuse state
output vnetId string = isExistingRegion
  ? existingVnet.id
  : vnet.id

output vnetName string = isExistingRegion
  ? existingVnet.name
  : vnet.name

output isExistingRegion bool = isExistingRegion
output isHub bool = isHub
output createSubnets bool = createSubnets

// 6.2 Standard subnet configuration and identities
// Subnet IDs are stable references, not evidence that every role subnet has already been created.

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

output subnetNames object = subnetNames
output subnetPrefixes object = subnetPrefix

// 6.3 Role NSG identities and compatibility aliases
output nsgs object = {
  server: serverNsgId
  client: clientNsgId
  dc: dcNsgId
  jumpbox: jumpboxNsgId
}

output nsgIds object = {
  dc: dcNsgId
  jumpbox: jumpboxNsgId
  server: serverNsgId
  client: clientNsgId
}
