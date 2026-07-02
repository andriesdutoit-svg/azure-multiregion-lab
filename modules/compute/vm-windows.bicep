// ========================================
// MODULE PURPOSE
// Deploys a Windows VM with Trusted Launch and optional public IP exposure.
// ========================================

// ========================================
// INPUTS
// VM identity, networking, image, disk, admin credentials, and access mode.
// ========================================

param vmName string
param subnetId string
param vmSize string
param assignPublicIp bool
param adminUsername string
@secure()
param adminPassword string
param tags object = {}
param image object
param osDisk object

// ========================================
// RESOURCE CREATED: NETWORK INTERFACE
// Always created; attaches VM to the target subnet.
// ========================================

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

// ========================================
// RESOURCE CREATED: WINDOWS VM
// System-assigned identity, Trusted Launch, and boot diagnostics enabled.
// ========================================

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
        }
      ]
    }
  }
}

// ========================================
// CONDITIONAL RESOURCE: PUBLIC IP
// Created only when assignPublicIp is true.
// ========================================

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
