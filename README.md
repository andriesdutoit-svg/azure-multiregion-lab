# Azure Multi-Region Lab (Bicep) – Lab v1.5.1

## Overview
This project deploys a multi-region Azure environment using Bicep, including:

- Multiple resource groups across regions
- Virtual networks with deterministic address spaces
- Full mesh VNet peering
- Windows and Linux virtual machines
- Static IP assignment for Domain Controllers
- Automated connectivity validation using Custom Script Extensions

---

## Key Features

### Deterministic Network Design
Each region is explicitly defined with its own address space and subnet:

```
region1 → 10.0.0.0/24  
region2 → 10.1.0.0/24  
region3 → 10.2.0.0/24  
region4 → 10.3.0.0/24  
region5 → 10.4.0.0/24  
```

- No dependency on loop ordering  
- Predictable addressing  
- Repeatable deployments  

---

### Static IP Assignment (Domain Controllers)
Domain Controllers are assigned fixed IP addresses:

```
dc01 → 10.0.0.10  
dc02 → 10.1.0.10  
dc03 → 10.2.0.10  
dc04 → 10.3.0.10  
dc05 → 10.4.0.10  
```

- Ensures consistent identity  
- Eliminates randomness  
- Supports reliable connectivity testing  

---

### Externalised Script Execution
Connectivity testing is implemented using an external PowerShell script:

```
scripts/network-test.ps1
```

Benefits:

- Avoids Bicep string escaping issues  
- Improves maintainability  
- Separates logic from infrastructure  
- Aligns with production practices  

---

### Automated Connectivity Validation
Each Domain Controller:

- Receives a list of all DC IPs  
- Tests TCP connectivity (Port 3389)  
- Logs results to:

```
C:\temp\network-test.txt
```

Non-DC VMs:

- Receive an empty target list  
- Exit immediately (no unnecessary execution)  

---

## Project Structure

```
azure-multiregion-lab/
│
├── main.bicep
├── main.parameters.json
├── test.parameters.json
│
├── modules/
│   ├── compute/
│   ├── networking/
│   └── peering/
│
└── scripts/
    └── network-test.ps1
```

---

## Deployment

### Prerequisites

- Azure CLI installed  
- Logged in to Azure (`az login`)  
- Sufficient subscription permissions  

---

### Deploy

```powershell
az deployment sub create `
  --name lab-deploy `
  --location westeurope `
  --template-file main.bicep `
  --parameters "@main.parameters.json"
```

---

## Validation

Log into any Domain Controller and run:

```powershell
type C:\temp\network-test.txt
```

Expected output:

```
Starting network test

ComputerName     : 10.x.x.x
TcpTestSucceeded : True
```

---

## Versioning

### v1.5
- Initial working version  
- Inline PowerShell in Bicep  
- Functional but fragile scripting  

### v1.5.1
- Moved connectivity test to external PowerShell script  
- Fixed Bicep string parsing and escaping issues  
- Improved reliability of Custom Script Extension  
- Implemented production-style script execution  

---

## Design Principles

- Infrastructure as Code (IaC)  
- Parameter-driven configuration  
- Deterministic networking  
- Separation of concerns (infrastructure vs scripts)  
- Reproducible deployments  

---

