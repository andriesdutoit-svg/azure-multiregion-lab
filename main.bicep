targetScope = 'subscription'
@description('Prefix for all resources')
param prefix string
param tags object

param adminUsername string
@secure()
param adminPassword string

param vmSize string
param osDisk object

param regions object

param dc01RegionKey string
param dc02RegionKey string
param dc03RegionKey string
param dc04RegionKey string
param dc05RegionKey string
param windowsClient01RegionKey string
param windowsClient02RegionKey string
param ubuntu01RegionKey string
param ubuntu02RegionKey string
param ubuntu03RegionKey string

param windowsServerImage object
param windowsClientImage object
param ubuntuImage object

param externalAccessPrefixes array = []
param dcIps object

var finalTags = union(tags, {
  project: prefix
})

var dcIpArray = [
  dcIps.dc01
  dcIps.dc02
  dcIps.dc03
  dcIps.dc04
  dcIps.dc05
]

//
// RESOURCE GROUPS
//

resource rgs 'Microsoft.Resources/resourceGroups@2022-09-01' = [
  for region in items(regions): {
    name: '${prefix}-rg-${region.key}'
    location: region.value.location
    tags: finalTags
  }
]

//
// VNets
//
module vnets 'modules/networking/vnet.bicep' = [
  for region in items(regions): {
    name: 'vnet-${region.key}'
    scope: resourceGroup('${prefix}-rg-${region.key}')
    dependsOn: [
      rgs
    ]
    params: {
      vnetName: '${prefix}-vnet-${region.key}'
      location: region.value.location
      addressPrefix: region.value.addressPrefix
      subnetPrefix: region.value.subnetPrefix
      dnsServers: []
      tags: finalTags
      externalAccessPrefixes: externalAccessPrefixes
    }
  }
]

//
// PEERING (explicit)
//

//FROM region1 TO ALL OTHER REGIONS

// region1 → region2
module peering_region1_region2 'modules/peering/peering.bicep' = {
  name: 'peering-region1-region2'
  scope: resourceGroup('${prefix}-rg-region1')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region1'
    remoteVnetName: '${prefix}-vnet-region2'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region2/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region2'
  }
}

// region1 → region3
module peering_region1_region3 'modules/peering/peering.bicep' = {
  name: 'peering-region1-region3'
  scope: resourceGroup('${prefix}-rg-region1')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region1'
    remoteVnetName: '${prefix}-vnet-region3'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region3/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region3'
  }
}

// region1 → region4
module peering_region1_region4 'modules/peering/peering.bicep' = {
  name: 'peering-region1-region4'
  scope: resourceGroup('${prefix}-rg-region1')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region1'
    remoteVnetName: '${prefix}-vnet-region4'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region4/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region4'
  }
}

// region1 → region 5
module peering_region1_region5 'modules/peering/peering.bicep' = {
  name: 'peering-region1-region5'
  scope: resourceGroup('${prefix}-rg-region1')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region1'
    remoteVnetName: '${prefix}-vnet-region5'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region5/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region5'
  }
}

//FROM region2 TO ALL OTHER REGIONS

// region2 → region1
module peering_region2_region1 'modules/peering/peering.bicep' = {
  name: 'peering-region2-region1'
  scope: resourceGroup('${prefix}-rg-region2')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region2'
    remoteVnetName: '${prefix}-vnet-region1'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region1/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region1'
  }
}

// region2 → region3
module peering_region2_region3 'modules/peering/peering.bicep' = {
  name: 'peering-region2-region3'
  scope: resourceGroup('${prefix}-rg-region2')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region2'
    remoteVnetName: '${prefix}-vnet-region3'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region3/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region3'
  }
}

// region2 → region4
module peering_region2_region4 'modules/peering/peering.bicep' = {
  name: 'peering-region2-region4'
  scope: resourceGroup('${prefix}-rg-region2')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region2'
    remoteVnetName: '${prefix}-vnet-region4'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region4/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region4'
  }
}

// region2 → region5
module peering_region2_region5 'modules/peering/peering.bicep' = {
  name: 'peering-region2-region5'
  scope: resourceGroup('${prefix}-rg-region2')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region2'
    remoteVnetName: '${prefix}-vnet-region5'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region5/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region5'
  }
}

//FROM region3 TO ALL OTHER REGIONS

// region3 → region1
module peering_region3_region1 'modules/peering/peering.bicep' = {
  name: 'peering-region3-region1'
  scope: resourceGroup('${prefix}-rg-region3')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region3'
    remoteVnetName: '${prefix}-vnet-region1'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region1/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region1'
  }
}

// region3 → region2
module peering_region3_region2 'modules/peering/peering.bicep' = {
  name: 'peering-region3-region2'
  scope: resourceGroup('${prefix}-rg-region3')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region3'
    remoteVnetName: '${prefix}-vnet-region2'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region2/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region2'
  }
}

// region3 → region4
module peering_region3_region4 'modules/peering/peering.bicep' = {
  name: 'peering-region3-region4'
  scope: resourceGroup('${prefix}-rg-region3')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region3'
    remoteVnetName: '${prefix}-vnet-region4'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region4/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region4'
  }
}

// region3 → region5
module peering_region3_region5 'modules/peering/peering.bicep' = {
  name: 'peering-region3-region5'
  scope: resourceGroup('${prefix}-rg-region3')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region3'
    remoteVnetName: '${prefix}-vnet-region5'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region5/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region5'
  }
}

//FROM region4 TO ALL OTHER REGIONS

// region4 → region1
module peering_region4_region1 'modules/peering/peering.bicep' = {
  name: 'peering-region4-region1'
  scope: resourceGroup('${prefix}-rg-region4')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region4'
    remoteVnetName: '${prefix}-vnet-region1'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region1/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region1'
  }
}

// region4 → region2
module peering_region4_region2 'modules/peering/peering.bicep' = {
  name: 'peering-region4-region2'
  scope: resourceGroup('${prefix}-rg-region4')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region4'
    remoteVnetName: '${prefix}-vnet-region2'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region2/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region2'
  }
}

// region4 → region3
module peering_region4_region3 'modules/peering/peering.bicep' = {
  name: 'peering-region4-region3'
  scope: resourceGroup('${prefix}-rg-region4')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region4'
    remoteVnetName: '${prefix}-vnet-region3'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region3/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region3'
  }
}

// region4 → region5
module peering_region4_region5 'modules/peering/peering.bicep' = {
  name: 'peering-region4-region5'
  scope: resourceGroup('${prefix}-rg-region4')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region4'
    remoteVnetName: '${prefix}-vnet-region5'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region5/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region5'
  }
}

//FROM region5 TO ALL OTHER REGIONS

// region5 → region1
module peering_region5_region1 'modules/peering/peering.bicep' = {
  name: 'peering-region5-region1'
  scope: resourceGroup('${prefix}-rg-region5')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region5'
    remoteVnetName: '${prefix}-vnet-region1'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region1/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region1'
  }
}

// region5 → region2
module peering_region5_region2 'modules/peering/peering.bicep' = {
  name: 'peering-region5-region2'
  scope: resourceGroup('${prefix}-rg-region5')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region5'
    remoteVnetName: '${prefix}-vnet-region2'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region2/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region2'
  }
}

// region5 → region3
module peering_region5_region3 'modules/peering/peering.bicep' = {
  name: 'peering-region5-region3'
  scope: resourceGroup('${prefix}-rg-region5')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region5'
    remoteVnetName: '${prefix}-vnet-region3'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region3/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region3'
  }
}

// region5 → region4
module peering_region5_region4 'modules/peering/peering.bicep' = {
  name: 'peering-region5-region4'
  scope: resourceGroup('${prefix}-rg-region5')

  dependsOn: [
    vnets
  ]

  params: {
    vnetName: '${prefix}-vnet-region5'
    remoteVnetName: '${prefix}-vnet-region4'
    remoteVnetId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${prefix}-rg-region4/providers/Microsoft.Network/virtualNetworks/${prefix}-vnet-region4'
  }
}
//
// DOMAIN CONTROLLERS
//
module dc01 'modules/compute/vm-windows.bicep' = {
  name: 'dc01'
  scope: resourceGroup('${prefix}-rg-${dc01RegionKey}')
  dependsOn: [
    vnets
  ]
  params: {
    vmName: '${prefix}-dc01'
    vnetName: '${prefix}-vnet-${dc01RegionKey}'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIp: dcIps.dc01
    testTargets: dcIpArray
    location: regions[dc01RegionKey].location
    tags: finalTags
   
    image: windowsServerImage     
    osDisk: osDisk                
  }
}

module dc02 'modules/compute/vm-windows.bicep' = {
  name: 'dc02'
  scope: resourceGroup('${prefix}-rg-${dc02RegionKey}')
  dependsOn: [
    vnets
  ]
  params: {
    vmName: '${prefix}-dc02'
    vnetName: '${prefix}-vnet-${dc02RegionKey}'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIp: dcIps.dc02
    testTargets: dcIpArray
    tags: finalTags
    location: regions[dc02RegionKey].location
    image: windowsServerImage     
    osDisk: osDisk                
  }
}

module dc03 'modules/compute/vm-windows.bicep' = {
  name: 'dc03'
  scope: resourceGroup('${prefix}-rg-${dc03RegionKey}')
  dependsOn: [
    vnets
  ]
  params: {
    vmName: '${prefix}-dc03'
    vnetName: '${prefix}-vnet-${dc03RegionKey}'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIp: dcIps.dc03
    testTargets: dcIpArray
    location: regions[dc03RegionKey].location
    tags: finalTags

    image: windowsServerImage     
    osDisk: osDisk                
  }
}

module dc04 'modules/compute/vm-windows.bicep' = {
  name: 'dc04'
  scope: resourceGroup('${prefix}-rg-${dc04RegionKey}')
  dependsOn: [
    vnets
  ]
  params: {
    vmName: '${prefix}-dc04'
    vnetName: '${prefix}-vnet-${dc04RegionKey}'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIp: dcIps.dc04
    testTargets: dcIpArray
    location: regions[dc04RegionKey].location
    tags: finalTags

    image: windowsServerImage     
    osDisk: osDisk                
  }
}

module dc05 'modules/compute/vm-windows.bicep' = {
  name: 'dc05'
  scope: resourceGroup('${prefix}-rg-${dc05RegionKey}')
  dependsOn: [
    vnets
  ]
  params: {
    vmName: '${prefix}-dc05'
    vnetName: '${prefix}-vnet-${dc05RegionKey}'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIp: dcIps.dc05
    testTargets: dcIpArray
    location: regions[dc05RegionKey].location
    tags: finalTags

    image: windowsServerImage     
    osDisk: osDisk                
  }
}

//
// CLIENT
//
module win01 'modules/compute/vm-windows.bicep' = {
  name: 'win01'
  scope: resourceGroup('${prefix}-rg-${windowsClient01RegionKey}')
  dependsOn: [
    vnets
  ]
  params: {
    vmName: '${prefix}-win01'
    vnetName: '${prefix}-vnet-${windowsClient01RegionKey}'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIp: ''
    testTargets: []
    location: regions[windowsClient01RegionKey].location
    tags: finalTags

    image: windowsClientImage     
    osDisk: osDisk                
  }
}

module win02 'modules/compute/vm-windows.bicep' = {
  name: 'win02'
  scope: resourceGroup('${prefix}-rg-${windowsClient02RegionKey}')
  dependsOn: [
    vnets
  ]
  params: {
    vmName: '${prefix}-win02'
    vnetName: '${prefix}-vnet-${windowsClient02RegionKey}'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIp: ''
    testTargets: []
    location: regions[windowsClient02RegionKey].location
    tags: finalTags

    image: windowsClientImage     
    osDisk: osDisk                
  }
}


//
// LINUX VM
//
module ubu01 'modules/compute/vm-linux.bicep' = {
  name: 'ubu01'
  scope: resourceGroup('${prefix}-rg-${ubuntu01RegionKey}')
  dependsOn: [
    vnets
  ]
  params: {
    vmName: '${prefix}-ubu01'
    vnetName: '${prefix}-vnet-${ubuntu01RegionKey}'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIp: ''
    testTargets: []
    location: regions[ubuntu01RegionKey].location
    tags: finalTags

    image: ubuntuImage               
    osDisk: osDisk                 
  }
}

module ubu02 'modules/compute/vm-linux.bicep' = {
  name: 'ubu02'
  scope: resourceGroup('${prefix}-rg-${ubuntu02RegionKey}')
  dependsOn: [
    vnets
  ]
  params: {
    vmName: '${prefix}-ubu02'
    vnetName: '${prefix}-vnet-${ubuntu02RegionKey}'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIp: ''
    testTargets: []
    location: regions[ubuntu02RegionKey].location
    tags: finalTags

    image: ubuntuImage               
    osDisk: osDisk                 
  }
}

module ubu03 'modules/compute/vm-linux.bicep' = {
  name: 'ubu03'
  scope: resourceGroup('${prefix}-rg-${ubuntu03RegionKey}')
  dependsOn: [
    vnets
  ]
  params: {
    vmName: '${prefix}-ubu03'
    vnetName: '${prefix}-vnet-${ubuntu03RegionKey}'
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    privateIp: ''
    testTargets: []
    location: regions[ubuntu03RegionKey].location
    tags: finalTags

    image: ubuntuImage               
    osDisk: osDisk                 
  }
}
