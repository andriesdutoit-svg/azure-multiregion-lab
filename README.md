# Azure Multi-Region Lab (AMRL)

## Overview

This project deploys a multi-region Azure infrastructure using Bicep.

Version: **v1.7**

This version introduces:
- Network security segmentation (NSGs)
- Full mesh VNet peering using loops
- Secure secret management using Azure Key Vault

---

## Key Features (v1.7)

- Multi-region deployment (5 regions)
- Resource group per region
- VNet per region
- Subnet segmentation:
  - Domain Controller (dc)
  - Server
  - Client
- NSG per subnet (role-based security)
- Full mesh VNet peering (loop-driven)
- Loop-based deployment logic
- Modular infrastructure design
- Secure credential storage using Key Vault

---

## Architecture

### Foundation Layer (Persistent)

This layer is NOT part of the main deployment and must exist beforehand.

- Resource Group: `traininglab-rg-foundation`
- Key Vault: `traininglab-kv`
- Contains:
  - adminPassword secret

This layer is independent and is not deleted during lab redeployments.

---

### Regional Infrastructure Layer (Disposable)

Each region contains:

- Resource Group: `AMRL-rg-regionX`
- VNet
- 3 subnets:
  - dc
  - server
  - client
- 3 Network Security Groups:
  - nsg-dc
  - nsg-server
  - nsg-client
- Domain Controller VM
- Optional Windows client and Linux VMs

---

## Networking

### VNet Peering

- Full mesh topology
- Automatically created using loops
- Each VNet peers with every other VNet
- All peerings are fully synchronized

---

## Security

### Network Security

NSG per subnet with role-based rules:

**DC subnet:**
- DNS (53)
- Kerberos (88)
- LDAP (389)
- RDP (3389)

**Server subnet:**
- SSH (22)

**Client subnet:**
- RDP (3389)

Inbound traffic restricted to:
```
10.0.0.0/8
```

---

### Secrets Management

- Admin password is stored in Azure Key Vault
- Retrieved at deployment time using secure reference
- No secrets are stored in code or parameter files

---

## Modules

| Module | Purpose |
|--------|--------|
| main.bicep | Subscription-level orchestration |
| vnet.bicep | VNets, subnets, NSGs |
| peering.bicep | VNet peering logic |
| vm-windows.bicep | Windows VM deployment |
| vm-linux.bicep | Linux VM deployment |

---

## Deployment

### Prerequisite (Foundation Setup)

Key Vault must exist before deployment.

### Then deploy:

```powershell
az deployment sub create   --name v17   --location westeurope   --template-file main.bicep   --parameters "@lab.parameters.json"
```

---

## Greenfield Deployment

To rebuild the lab:

1. Delete all regional resource groups:
   ```
   AMRL-rg-region1
   AMRL-rg-region2
   ...
   ```
2. DO NOT delete:
   ```
   traininglab-rg-foundation
   ```
3. Redeploy template

---

## Known Limitations

- NSG rules are not least-privilege (basic lab rules)
- No Azure Firewall or custom routing
- Public IPs enabled for simplicity
- No Active Directory configuration yet

---

## Roadmap

### v1.8

- Subnet module
- NSG module
- Improved modularisation

### v1.9+

- Active Directory deployment
- Domain join automation
- DNS forwarding improvements
