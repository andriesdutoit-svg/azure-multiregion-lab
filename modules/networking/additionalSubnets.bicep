// Creates policy-neutral additional subnets declared through subnetIndexMap.
// Consumes canonical names/prefixes from the root's non-reserved subnet keys and a ready parent VNet.
// This loop does not infer role policy or delete existing subnets that disappear from the desired list.

// 1. Parent VNet and ordered subnet definitions
param vnetName string
param subnets array

// 2. Subnet updates
// Serialize writes to the shared VNet. Additional subnets receive no inferred NSG or route table.
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

// 3. Subnet IDs in the same order as the input collection
output subnetIds array = [
  for (subnet, i) in subnets: {
    name: subnet.name
    id: additionalSubnets[i].outputs.subnetId
  }
]
