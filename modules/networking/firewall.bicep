// Deploys hub firewall components: public IP, policy, firewall instance, and baseline east-west rules.
// Requires the hub VNet and dedicated firewall subnet. Policy deployment is encapsulated in a child module;
// the returned private IP becomes the next hop used by spoke route tables, whose associations are external.

// 1. Resource identities and location
param location string
param firewallName string
param vnetName string
param publicIpName string

// 2. Public IP and existing network dependencies
// The caller provisions the VNet and AzureFirewallSubnet before this module runs.

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-02-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetName
}

resource firewallSubnet 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' existing = {
  parent: vnet
  name: 'AzureFirewallSubnet'
}

// 3. Firewall policy
// Deploy policy resources through a nested module so Azure completes policy evaluation
// before the firewall instance references the policy.

module firewallPolicy 'firewall-policy.bicep' = {
  name: '${firewallName}-policy-deployment'
  params: {
    location: location
    firewallPolicyName: '${firewallName}-policy'
  }
}

// 4. Firewall instance
// The module output and Public IP reference establish deployment dependencies.

resource firewall 'Microsoft.Network/azureFirewalls@2023-02-01' = {
  name: firewallName
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }

    firewallPolicy: {
      id: firewallPolicy.outputs.firewallPolicyId
    }

    ipConfigurations: [
      {
        name: 'firewall-ipconfig'
        properties: {
          subnet: {
            id: firewallSubnet.id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// 5. Routing next hop
// This module declares one IP configuration; return its private address for spoke route tables.
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
