# Azure Multi-Region Lab (v1.6)

## Overview
This project implements a multi-region Azure infrastructure using Bicep. Version 1.6 focuses on building a stable, segmented, and DNS-enabled platform that is ready for Active Directory deployment.

## Key Features (v1.6)

- Multi-region deployment (5 regions)
- VNet per region
- Subnet segmentation per VNet:
  - Domain Controller subnet
  - Server subnet
  - Client subnet
- Loop-based VM deployment
- Role-based subnet assignment
- Public IP support
- DNS configuration with DC + Azure fallback (lab design)

## Architecture

Each region contains:

- VNet
- 3 Subnets (dc, server, client)
- Domain Controller VM
- Optional client and Linux VMs

## Next Steps (v1.7)

- NSG per subnet
- Role-based NSG rules
- Security segmentation improvements

## Repository Structure

- main.bicep
- modules/
  - networking/
  - compute/
  - peering/
- scripts/
- main.parameters.json

## Regional parameters

main.parameters.json and lab.parameters.json are identical except that they use different sets of regions. This allows more than one deployment per subscription (Azure free trials only allows 4 cores per region)

## Deployment

```powershell
az deployment sub create   --name v16-final   --location westeurope   --template-file main.bicep   --parameters "@main.parameters.json"
```

## Version

Current version: v1.6 (finalised)

