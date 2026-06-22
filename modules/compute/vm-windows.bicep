param vmName string
param vnetName string
param vmSize string
param adminUsername string
@secure()
param adminPassword string
param tags object = {}
param image object
param osDisk object
param privateIp string
param testTargets array
param location string

param forceUpdateTag string = utcNow()

resource nic 'Microsoft.Network/networkInterfaces@2022-07-01' = {
  name: '${vmName}-nic'
  location: resourceGroup().location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: empty(privateIp) ? 'Dynamic' : 'Static'
          privateIPAddress: empty(privateIp) ? null : privateIp
          subnet: {
            id: resourceId(
              'Microsoft.Network/virtualNetworks/subnets',
               vnetName,
                '${vnetName}-subnet-default')
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2022-08-01' = {
  name: vmName
  location: resourceGroup().location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
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

// Test network connectivity between DCs using Custom Script Extension

var targetList = join(testTargets, ',')

resource vmScript 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = if (length(testTargets) > 0) {
  name: '${vmName}/vmScript'
  location: location
  dependsOn: [
    vm
  ]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    
    settings: {
      fileUris: [
        'https://raw.githubusercontent.com/andriesdutoit-svg/Bicep/master/azure-multiregion-lab/scripts/network-test.ps1'
      ]
      commandToExecute: 'powershell -ExecutionPolicy Bypass -File network-test.ps1 -targets "${targetList}" -selfIp "${privateIp}"'
  }
    forceUpdateTag: forceUpdateTag
  }
}
