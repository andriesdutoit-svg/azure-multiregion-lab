// Deploys a Linux VM with SSH key authentication and optional public IP.
// Owns the VM, its NIC, and optional Public IP; the current compute-stage caller keeps Linux workloads private.
// Image/disk settings and SSH administrator identity come from the caller, while domain join is separate.
// Associated-resource delete options apply to VM deletion, not retirement of resources omitted from templates.

// 1. Parameters
// Identity and role-selected compute configuration
param vmName string
param tags object = {}
param vmSize string
param image object
param osDisk object
param vmAutoDeleteOptions object

// Network attachment and SSH-only administrator access
param subnetId string
param assignPublicIp bool
param adminUsername string
param sshPublicKey string

// 2. Network interface
// References create the required NIC/Public IP/VM dependencies; textual order is not execution order.
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
// Password SSH authentication is disabled; the supplied public key provisions the local administrator.

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
              keyData: sshPublicKey
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
// Conditional creation alone does not retire an existing IP when assignPublicIp becomes false.

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
