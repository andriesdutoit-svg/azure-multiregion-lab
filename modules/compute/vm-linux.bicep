// ========================================
// MODULE PURPOSE
// Deploys a Linux VM with SSH key authentication and optional public IP.
// ========================================

// ========================================
// INPUTS
// VM identity, networking, image, disk, and access mode.
// ========================================

param vmName string
param subnetId string
param vmSize string
param adminUsername string
param adminPublicKey string
param tags object = {}
param image object
param osDisk object
param assignPublicIp bool

// ========================================
// RESOURCE CREATED: NETWORK INTERFACE
// Always created; attaches to target subnet.
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
// RESOURCE CREATED: LINUX VM
// System-assigned identity + Trusted Launch + SSH-only authentication.
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
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
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
