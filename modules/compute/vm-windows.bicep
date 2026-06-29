param vmName string
param subnetId string
param vmSize string

param vmType string
param vmIndex int
param regionIndex int
param dcRegionalIndex int
param subnetIndex int
param privateIp string?
param assignPublicIp bool

param adminUsername string
@secure()
param adminPassword string
param tags object = {}
param image object
param osDisk object

resource nic 'Microsoft.Network/networkInterfaces@2022-07-01' = {
  name: '${vmName}-nic'
  location: resourceGroup().location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: vmType == 'dc'
            ? 'Static'
            : (empty(privateIp) ? 'Dynamic' : 'Static')

          privateIPAddress: vmType == 'dc'
            ? '10.${regionIndex}.${subnetIndex}.${4 + dcRegionalIndex}'
            : privateIp
          publicIPAddress: assignPublicIp ? {
            id: publicIp.id
          } : null
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2022-08-01' = {
  name: vmName
  location: resourceGroup().location
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
  properties: {
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: image
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: osDisk.storageAccountType
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-02-01' = if (assignPublicIp) {
  name: '${vmName}-pip'
  location: resourceGroup().location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}
