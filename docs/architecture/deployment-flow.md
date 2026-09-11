validation
     ↓

resource groups
     ↓

vnets
     ↓

peerings
     ↓

firewall
     ↓

route tables
     ↓

subnets

     ↓

windows VMs
linux VMs

     ↓

ad forest
     ↓

replica dcs
     ↓

ad populate

     ↓
domain join
     ↓

file services


V2.4 Design Finding

Networking and compute are coupled through subnet outputs.

Attempting to extract networking deployment modules first introduces
conditional module output (BCP318) challenges.

Consider prioritizing extraction of placement-engine logic and helper
variables before deployment resource extraction.