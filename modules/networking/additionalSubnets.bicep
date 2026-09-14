// Creates policy-neutral additional subnets declared through subnetIndexMap.

param vnetName string
param subnets array

@batchSize(1)
module additionalSubnets 'subnet.bicep' = [
  for subnet in subnets: {
    name: subnet.name
    params: {
      vnetName: vnetName
      subnetName: subnet.name
      addressPrefix: subnet.addressPrefix
      nsgId: ''
    }
  }
]

output subnetIds array = [
  for (subnet, i) in subnets: {
    name: subnet.name
    id: additionalSubnets[i].outputs.subnetId
  }
]
