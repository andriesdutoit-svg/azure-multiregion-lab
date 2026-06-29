# Azure Multi-Region Lab (AMRL)

## Overview

This project implements a multi-region Azure lab environment using Bicep. It demonstrates a structured evolution from basic infrastructure deployment into a secure, modular, capacity-aware, and production-aligned platform.

The lab is designed to showcase real-world Infrastructure as Code practices, including:

- Deterministic and repeatable deployments  
- Modular architecture using reusable components  
- Secure-by-default design principles  
- Controlled workload distribution across multiple regions  
- Validation-first deployment to prevent configuration errors  

---

### Project Evolution

The solution was developed iteratively, with each phase introducing additional architectural capability:

- **v1.6 — Foundation Layer**  
  Multi-region networking, subnet segmentation, and DNS structure.

- **v1.7 — Security and Modularity**  
  Network Security Groups, role-based segmentation, and full mesh VNet peering.

- **v1.8 — Modular Architecture**  
  Separation of components into reusable modules and integration with Azure Key Vault.

- **v1.9 — Security Hardening and Identity**  
  Introduction of a jumpbox model, private-only workloads, and hardened authentication.

- **Current Version v1.10 — Placement and Validation Engine**  
  Deterministic VM placement, capacity-aware distribution, and pre-deployment validation.

---

### Design Principles

The design is based on the following principles:

- **Deterministic deployment**  
  The same inputs always produce the same infrastructure layout.

- **Separation of concerns**  
  Networking, compute, security, and placement logic are clearly separated.

- **Data-driven design**  
  Deployment behaviour is controlled through parameter configuration.

- **Validation before deployment**  
  Invalid configurations are detected and blocked early.

- **Balanced multi-region distribution**  
  Workloads are evenly distributed while respecting regional constraints.

- **Security-first approach**  
  Minimal exposure, controlled access paths, and secure credential handling.
``

---

## Architecture Overview

The deployment creates a consistent infrastructure footprint across multiple Azure regions.

### Regional Architecture

Each selected region contains:

- A dedicated Resource Group  
- A Virtual Network (VNet)  
- Segmented subnets:
  - Domain Controller (dc)
  - Server
  - Client
  - Jumpbox  
- Network Security Groups (NSGs) applied per subnet  
- Virtual Machines based on configured roles  

---

### Network Architecture

- Full mesh VNet peering between all regions  
- Private communication between all workloads  
- Controlled administrative access via jumpboxes  
- Subnet-level traffic segmentation using NSGs  

---

### Security Model

- Public access is restricted to jumpboxes only  
- All other VMs are private  
- Role-based NSG rules control traffic flow  
- Credentials are securely stored in Azure Key Vault  

---

### Workload Distribution

- Domain Controllers are placed first using deterministic rules  
- All other VMs are distributed using an offset-based round-robin model  
- Each region is constrained by a maximum VM limit to prevent over-allocation  

---

## File Structure

The project is structured to separate concerns and promote modular reuse.

---

### Root Files

- **main.bicep**  
  Entry point for the deployment. Defines orchestration, placement logic, validation, and module calls.

- **main.parameters.json**  
  Contains all configurable inputs such as regions, VM counts, and sizes.

---

### Modules

#### Networking

- **modules/networking/vnet.bicep**  
  Deploys VNets, integrates subnets, and configures DNS.

- **modules/networking/subnet.bicep**  
  Defines individual subnet resources.

- **modules/networking/nsg.bicep**  
  Deploys Network Security Groups with role-based rules.

---

#### Compute

- **modules/compute/vm-windows.bicep**  
  Deploys Windows virtual machines, including Domain Controllers, servers, clients, and jumpboxes.

- **modules/compute/vm-linux.bicep**  
  Deploys Linux virtual machines with SSH-based authentication.

---

#### Peering

- **modules/peering/peering.bicep**  
  Configures full mesh VNet peering across all regions.

---

### Supporting Logic in main.bicep

- **VM Model Construction**  
  Builds a unified list of all VM types and counts

- **Region Ordering Logic**  
  Converts region mappings into a deterministic ordered list

- **Placement Engine**  
  Assigns each VM to a region using offset-based round-robin logic

- **Validation Engine**  
  Ensures that configuration is valid before deployment begins

---

### Foundation Layer (External)

- Azure Key Vault (must exist before deployment)  
- Stores admin credentials securely  
- Referenced directly from the parameter file

---

# Start Guide

This section explains exactly how to configure and run the deployment. Each parameter is explained so that you understand what it does, why it matters, and how to change it safely.

---

## Step 1: Understand the Core Concept

This deployment spreads Virtual Machines across multiple Azure regions while ensuring:

- No region gets too many VMs
- Distribution is balanced
- Certain roles (like Domain Controllers) are placed intentionally

To control this behaviour, you configure a few key parameters in `main.parameters.json`.

---

## Step 2: Core Deployment Settings

```json
"prefix": { "value": "your-prefix" },
"regionCount": { "value": 5 },
"maxVmsPerRegion": { "value": 2 }
```

### 🔹 prefix
- Used to name all resources (e.g. `yourprefix-rg-westeurope`)
- Change this to something meaningful for your lab or project

### 🔹 regionCount
- How many regions will be used
- MUST be less than or equal to the number of regions in `regionIndexMap`

### 🔹 maxVmsPerRegion
- The **maximum number of VMs allowed in each region**
- This protects you from exceeding Azure CPU quotas

Example:
If each VM uses 2 vCPUs and quota is 4:
```
maxVmsPerRegion = 2
```

---

## Step 3: Region Mapping (VERY IMPORTANT)

For example:

```json
"regionIndexMap": {
  "value": {
    "southafricanorth": 1,
    "southindia": 2,
    "japanwest": 3,
    "israelcentral": 4,
    "koreasouth": 5
  }
}
```

### What this does

- Defines WHICH regions are available
- Defines the ORDER of regions

### Why order matters

The placement engine uses this order to distribute VMs.

### Rules

- Must start at `1`
- Must increase by `1` each time
- No gaps allowed

---

## Step 4: Subnet Mapping

```json
"subnetIndexMap": {
  "value": {
    "jumpbox": 1,
    "dc": 2,
    "server": 3,
    "client": 4
  }
}
```

### What this does

Defines how subnets are created and ordered within each region.

The numbering determines:
- The logical order of subnets
- The subnet index used when calculating IP address ranges

### Recommendation

Leave these values as-is unless redesigning networking.

---

## Step 5: VM Counts (Controls Scale)

```json
"vmCounts": {
  "value": {
    "dc": 2,
    "jumpbox": 2,
    "windowsServer": 2,
    "windowsClient": 1,
    "linuxServer": 2,
    "linuxClient": 1
  }
}
```

### What this does

Defines HOW MANY VMs of each type to create.

### Important behaviour

- Domain Controllers (dc) are placed first
- Jumpboxes are placed early in distribution
- Other VMs follow round-robin placement

### How to change safely

If you increase VM counts:

Ensure:
```
totalVMs ≤ regionCount × maxVmsPerRegion
```

---

## Step 6: VM Size (CRITICAL)

```json
"vmSize": { "value": "Standard_B2ls_v2" }
```

### What this does

Defines the size of every VM (CPU + RAM).

### Why this matters

Azure limits vCPU per region.

Example:

- VM size = 2 cores
- Region quota = 4 cores

Max safe:
```
2 VMs per region
```

---

## Step 7: Jumpbox Allowed Sources

```json
"jumpboxAllowedSources": {
  "value": [
    "198.51.100.25",
    "203.0.113.0/24"
  ]
}
```

### What this does

Defines the list of public IP addresses or ranges that are allowed to access the jumpboxes via RDP. These values are used to configure inbound Network Security Group (NSG) rules, restricting administrative access to only the specified sources.

---

### Important

- Replace these example IP addresses with your own public IP address(es) or range(s)
- If not configured correctly, you will not be able to access the jumpboxes
- Jumpboxes are the only entry point to access the rest of the virtual machines in the environment

---

## Step 8: Key Vault Setup (Required)

### Why Key Vault is needed

Passwords are NOT stored in the template.
They are securely stored in Azure Key Vault.

---

### Create Foundation Resource Group

```bash
az group create --name traininglab-rg-foundation --location westeurope
```

Ensure that the name of this resource group does not start with the prefix selected earlier, as it will also be deleted if a bulk resource group deletion command is used to cleanup the lab.

---

### Create Key Vault

```bash
az keyvault create   --name traininglab-kv   --resource-group traininglab-rg-foundation   --location westeurope   --enabled-for-template-deployment true
```

---

### Add Secrets

```bash
az keyvault secret set --vault-name traininglab-kv --name jumpboxAdminPassword --value <password>
az keyvault secret set --vault-name traininglab-kv --name serverAdminPassword --value <password>
az keyvault secret set --vault-name traininglab-kv --name clientAdminPassword --value <password>
```

---

### Link Key Vault in Parameters

```json
"jumpboxAdminPassword": {
  "reference": {
    "keyVault": {
      "id": "/subscriptions/<subId>/resourceGroups/traininglab-rg-foundation/providers/Microsoft.KeyVault/vaults/traininglab-kv"
    },
    "secretName": "jumpboxAdminPassword"
  }
}
```

Repeat for other passwords.

---

## Step 9: Deploy

```bash
az deployment sub create   --name amrl-deployment   --location westeurope   --template-file main.bicep   --parameters main.parameters.json
```

---

## Step 10: Validate Results

Check outputs:

- `vmPlacement` → where each VM was deployed
- `vmCountPerRegion` → confirms no region exceeded limits

---

# Final Tip

If deployment fails:

1. Check VM size vs quota
2. Check regionCount vs vmCounts
3. Check Key Vault configuration

---

# Placement Engine

## Rules

1. dc01 → primary region
2. remaining DCs → evenly distributed
3. all other VMs → offset-based round-robin

---

## Offset-Based Placement (IMPORTANT)

Round-robin is offset by number of DCs:

```
finalIndex = (nonDcIndex + dcCount) % regionCount
```

---

## Why this matters

Without offset:
- Regions pre-filled by DCs get extra VMs
- Regions overflow

With offset:
- Distribution starts in empty regions
- Balanced placement achieved
- No region exceeds limits

---

# Validation

Checks include:
- minimum VM counts
- region constraints
- capacity limits
- subnet validity

---

# Outputs

- vmPlacement
- vmCountPerRegion
- validationMessage
- capacityCheck

---