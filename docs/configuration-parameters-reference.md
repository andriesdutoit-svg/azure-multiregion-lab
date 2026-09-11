# Configuration Parameters Reference

[Back to README](../README.md)

All parameters are defined in parameter files (`main.parameters.demo.json`, `main.parameters.example.json`, `main.parameters.test.json`, or your local parameter file). This section provides a centralised reference for all tunable parameters used across deployment stages.

## Core Deployment Settings

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `prefix` | string | Resource naming prefix | `"AMRL"` |
| `stage` | string | Deployment stage: `network`, `control`, `identity`, `workload`, or `all`. See [Deployment Guide](deployment.md#stages). | `"all"` |
| `tags` | object | Resource tags for organisation and billing | `{"environment": "lab"}` |
| `regionCount` | integer | Number of regions to deploy across | `2` |
| `maxVmsPerRegion` | integer | Maximum VMs allowed per region | `2` |

## Region and Network Configuration

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `regionIndexMap` | object | Maps region names to index numbers. Must be contiguous and start at 1. See [Region Indexes](deployment.md#region-indexes). | `{"westeurope": 1, "northeurope": 2}` |
| `subnetIndexMap` | object | Defines subnet ordering within each region | `{"firewall": 0, "jumpbox": 1, "dc": 2, "server": 3, "client": 4}` |
| `existingRegions` | array | Regions with existing networking (brownfield reuse). See [Placement and Reconciliation](placement-and-reconciliation.md). | `["westeurope"]` |
| `existingVmPlacements` | array | Existing VM inventory used for brownfield reconciliation | `[{"type": "dc", "index": 0, "regionKey": "westeurope"}]` |

**Examples**:
- **Greenfield (all new)**: `"existingRegions": []`, `"existingVmPlacements": []`
- **Brownfield (mixed)**: `"existingRegions": ["westeurope"]` (reuses westeurope, creates additional regions)

## Virtual Machine Configuration

**VM Scale**:

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `vmCounts` | object | Number of each VM type to deploy: `dc`, `jumpbox`, `windowsServer`, `windowsClient`, `linuxServer`, `linuxClient` | `{"dc": 1, "jumpbox": 1, "windowsServer": 1, "windowsClient": 0, "linuxServer": 0, "linuxClient": 0}` |

**VM Sizing** (all role keys must be present):

```json
"vmSizes": {
  "value": {
    "dc": "Standard_B2ls_v2",
    "jumpbox": "Standard_B2ls_v2",
    "windowsServer": "Standard_E2s_v3",
    "windowsClient": "Standard_B2ls_v2",
    "linuxServer": "Standard_B2ls_v2",
    "linuxClient": "Standard_B2ls_v2"
  }
}
```

> Verify region availability with `az vm list-sizes --location <region> -o table`.

**OS Disk Configuration** (all role keys must be present):

```json
"osDisks": {
  "value": {
    "dc": { "storageAccountType": "Standard_LRS", "diskSizeGB": 128 },
    "jumpbox": { "storageAccountType": "Standard_LRS", "diskSizeGB": 64 },
    "windowsServer": { "storageAccountType": "Standard_LRS", "diskSizeGB": 128 },
    "windowsClient": { "storageAccountType": "Standard_LRS", "diskSizeGB": 64 },
    "linuxServer": { "storageAccountType": "Standard_LRS", "diskSizeGB": 128 },
    "linuxClient": { "storageAccountType": "Standard_LRS", "diskSizeGB": 64 }
  }
}
```

**Operating System Images**:

```json
"windowsServerImage": {
  "value": { "publisher": "MicrosoftWindowsServer", "offer": "WindowsServer", "sku": "2022-datacenter-g2", "version": "latest" }
},
"windowsClientImage": {
  "value": { "publisher": "MicrosoftWindowsDesktop", "offer": "windows-10", "sku": "win10-22h2-ent-g2", "version": "latest" }
},
"ubuntuImage": {
  "value": { "publisher": "Canonical", "offer": "0001-com-ubuntu-server-jammy", "sku": "22_04-lts-gen2", "version": "latest" }
}
```

**VM Lifecycle Options**:

```json
"vmAutoDeleteOptions": {
  "value": {
    "nic": true,
    "publicIp": true,
    "osDisk": true
  }
}
```

When set to `true`, dependent resources (NICs, public IPs, OS disks) are automatically deleted when their associated VMs are deleted.

## Security and Access

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `jumpboxAllowedSources` | array | IP addresses/ranges allowed to connect to jumpboxes via RDP | `["203.0.113.0/32", "198.51.100.0/16"]` |

Linux client SSH access from jumpboxes is always enabled and is not gated by a parameter. See [Access and Administration](access-and-administration.md).

**Important**: Jumpboxes are the only entry point to the lab. Ensure `jumpboxAllowedSources` includes your IP address.

## Credentials and Secrets

All credentials are stored in Azure Key Vault and referenced by name, not embedded in parameter files. See [Key Vault Setup](access-and-administration.md#key-vault-setup) for recreating the vault and secrets.

| Parameter | Type | Key Vault Secret | Purpose |
|---|---|---|---|
| `jumpboxAdminUsername` | string | N/A (local username) | Local admin account on jumpbox VMs |
| `jumpboxAdminPassword` | reference | `jumpboxAdminPassword` | Password for jumpbox local admin |
| `serverAdminUsername` | string | N/A (local username) | Local admin account on server VMs |
| `serverAdminPassword` | reference | `serverAdminPassword` | Password for server local admin |
| `clientAdminUsername` | string | N/A (local username) | Local admin account on client VMs |
| `clientAdminPassword` | reference | `clientAdminPassword` | Password for client local admin |
| `sshPublicKey` | reference | `sshPublicKey` | SSH public key for Linux VMs |
| `sshPrivateKey` | reference | `sshPrivateKey` | SSH private key (deployed to jumpboxes) |

**Example Parameter File Reference**:

```json
"jumpboxAdminPassword": {
  "reference": {
    "keyVault": {
      "id": "/subscriptions/<subscription-id>/resourceGroups/<foundation-rg>/providers/Microsoft.KeyVault/vaults/<key-vault-name>"
    },
    "secretName": "jumpboxAdminPassword"
  }
}
```

## Identity Configuration (Optional)

**Enable/Disable Identity**:

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `enableIdentity` | boolean | Enable Active Directory forest creation and domain join | `true` |
| `domainName` | string | AD domain name (e.g., FQDN) | `"amrl.lab"` |

**Department Configuration** (only when `enableIdentity=true`):

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `sysAdminDepartment` | object | System administration department (must be exactly 1 entry) | `{"Information Technology": "ICT"}` |
| `additionalDepartments` | object | Additional departments available for selection | `{"Finance": "FIN", "Human Resources": "HR"}` |
| `departmentCount` | integer | Total departments to provision, including `sysAdminDepartment` | `2` |
| `usersPerDepartment` | integer | Standard user accounts to create per department, excluding the department manager | `5` |

## File Server Configuration (Optional)

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `enableFileServices` | boolean | Create departmental share groups and memberships, then provision the `C:\Shares` directory, departmental SMB shares, and NTFS permissions during the identity stage. Requires `enableIdentity=true`. | `true` |
| `useDedicatedFileServer` | boolean | When file services are enabled, target the first `srvwin` VM in the final placement model instead of the primary DC. Requires `enableFileServices=true`, `enableIdentity=true`, and at least one `srvwin` VM. See [File Server Reassignment on Brownfield Expansion](placement-and-reconciliation.md#file-server-reassignment-on-brownfield-expansion). | `true` |

Supported combinations:

| `enableIdentity` | `enableFileServices` | `useDedicatedFileServer` | Result |
|---|---|---|---|
| `false` | `false` | `false` | Identity and file services are disabled. |
| `true` | `false` | `false` | AD is populated without share groups, SMB shares, or file-system permissions. |
| `true` | `true` | `false` | File services are provisioned on the primary DC. |
| `true` | `true` | `true` | File services are provisioned on the first `srvwin` VM. |

Other combinations produce validation flags. If dedicated mode has no `srvwin` placement, target selection falls back to the primary DC so template evaluation can continue, but `missingDedicatedFileServer` is reported and the configuration should be corrected. Changing the target does not move existing share data or remove shares from the former host.

[Back to README](../README.md)
