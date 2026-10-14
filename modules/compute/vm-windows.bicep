// Deploys a Windows VM with Trusted Launch and optional public IP exposure.
// Owns the VM, its NIC, and optional Public IP using the caller's role-specific image/disk profile.
// The compute stage invokes this for missing VM identities; domain configuration is a separate stage.
// deleteOption settings govern associated-resource handling when the VM is deleted, not topology cleanup.

// 1. Parameters
// Identity and role-selected compute configuration
param vmName string
param tags object = {}
param vmSize string
param image object
param osDisk object
param vmAutoDeleteOptions object

// Network attachment and administrator credentials
param subnetId string
param assignPublicIp bool
param adminUsername string
@secure()
param adminPassword string

// 2. Network interface
// Resource references establish NIC/Public IP/VM dependencies regardless of declaration order.
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
          privateIPAllocationMethod: 'Dynamic'
          // Optional public IP attachment based on assignPublicIp.
          publicIPAddress: assignPublicIp ? {
            id: publicIp.id
          } : null
        }
      }
    ]
  }
}

// 3. Virtual machine
// System-assigned identity, Trusted Launch, and boot diagnostics enabled.

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
        deleteOption: vmAutoDeleteOptions.osDisk
        ? 'Delete'
        : 'Detach'
        // Role-specific OS disk capacity from main.bicep -> roleSizingMap -> osDisks.
        diskSizeGB: osDisk.diskSizeGB
        managedDisk: {
          storageAccountType: osDisk.storageAccountType
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: vmAutoDeleteOptions.nic
              ? 'Delete'
              : 'Detach'
          }
        }
      ]
    }
  }
}

// 4. Optional Public IP
// A false condition skips creation; it does not delete a previously deployed IP.

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-02-01' = if (assignPublicIp) {
  name: '${vmName}-pip'
  location: resourceGroup().location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    deleteOption: vmAutoDeleteOptions.publicIp
      ? 'Delete'
      : 'Detach'
  }
}
