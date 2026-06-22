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
      linuxConfiguration: {
        disablePasswordAuthentication: false
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

// Extension to test network connectivity to other VMs

resource networkTestLinux 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = {
  name: '${vmName}/networkTest'
  location: location
  dependsOn: [
    vm
  ]
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    settings: {
      commandToExecute: 'bash -c "sleep 60 && mkdir -p /tmp/network-test && echo Starting network test > /tmp/network-test/network-test.txt && for t in ${join(testTargets, ' ')}; do if [ $t != ${privateIp} ]; then nc -zvw3 $t 3389 >> /tmp/network-test/network-test.txt 2>&1; fi; done"'


    }
    forceUpdateTag: forceUpdateTag
  }
}
