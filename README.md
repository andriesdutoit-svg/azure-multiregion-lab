# Azure Multi-Region Lab (AMRL)

## Overview

This project deploys a modular, multi-region Azure infrastructure using Bicep.

Version: **v1.8**

This version introduces full modularisation of networking components, improving reusability, maintainability, and alignment with enterprise Infrastructure-as-Code practices.

---

## Key Features (v1.8)

- Multi-region deployment (5 regions)
- Resource group per region
- VNet per region
- Subnet modularisation (dc, server, client)
- NSG modularisation with role-based rule sets
- Full mesh VNet peering (loop-driven)
- Clean dependency handling to avoid Azure concurrency issues
- Loop-based orchestration for scalable deployments
- Secure credential storage using Azure Key Vault (foundation layer)

---

## Architecture

### Foundation Layer (Persistent)

This layer is NOT part of the main deployment and must exist before deploying the lab.

- Resource Group: `traininglab-rg-foundation`
- Key Vault: `traininglab-kv`
- Secrets:
  - adminPassword

This layer is stable and should not be deleted during greenfield redeployments.

---

### Regional Infrastructure Layer (Disposable)

Each region contains:

- Resource Group: `AMRL-rg-regionX`
- Virtual Network
- Subnets (modular):
  - dc
  - server
  - client
- Network Security Groups (modular):
  - nsg-dc
  - nsg-server
  - nsg-client
- Domain Controller VM
- Windows client VMs (optional)
- Linux VMs (optional)

---

## Module Structure

```
main.bicep
main.parameters.json
alt.parameters.json   # alternative region parameters
README.md
modules/
  networking/
    vnet.bicep        # composition layer
    subnet.bicep      # subnet resource module
    nsg.bicep         # NSG resource module
  compute/
    vm-windows.bicep
    vm-linux.bicep
  scripts/
    network-test.ps1
```

---

## Networking Design

Azure DNS fallback (168.63.129.16) is used alongside domain controllers for name resolution.

### Subnets

Subnets are deployed as independent resources via modules and attached to the VNet sequentially to avoid Azure concurrency issues.

### NSGs

NSGs are modular and rule-driven. Rules are grouped by role:

- dc rules (DNS, Kerberos, LDAP, RDP)
- server rules (SSH)
- client rules (RDP)

Inbound traffic restricted to:

```
10.0.0.0/8
```

---

## Outputs

The VNet module exposes structured outputs for reuse:

- vnetId
- vnetName
- subnets:
  - id
  - name

These outputs allow easy integration with future modules (e.g., domain join, monitoring, firewalls).

---

## Deployment

### Prerequisites

- Key Vault must exist in the foundation resource group
- Secret `adminPassword` must be present
- Key Vault must have `enabledForTemplateDeployment = true`

---

### Deploy

```powershell
az deployment sub create   --name v18   --location westeurope   --template-file main.bicep   --parameters "@main.parameters.json"
```

---

## Known Limitations

- NSG rules are simplified (not least-privilege)
- No Azure Firewall or advanced routing
- Public IPs enabled for simplicity
- Active Directory not yet configured

---

## Roadmap

### v1.9

- Active Directory deployment
- Domain join automation
- DNS forwarding improvements

### v2.0 (future)

- Firewall integration
- Route tables
- Private endpoints

---

## Version

Current version: **v1.8**
