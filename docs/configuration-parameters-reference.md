# Configuration Parameters Reference

[Back to README](../README.md)

All parameters are defined in parameter files (`main.parameters.demo.json`, `main.parameters.example.json`, `main.parameters.test.json`, or your local parameter file). This section provides a centralised reference for all tunable parameters used across deployment stages.

## Core Deployment Settings

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `prefix` | string | Resource naming prefix | `"AMRL"` |
| `stage` | string | Deployment stage: `network`, `compute`, `identity`, or `all`. See [Deployment Guide](deployment.md#stages). | `"all"` |
| `validationMode` | string | `reportOnly` reports findings without blocking stages; `enforce` fails the validation gate when blocking findings are active. | `"reportOnly"` |
| `networkMode` | string | Network topology: `hubSpokeFirewall`, `hubSpoke`, or `fullMesh`. See [Network Topology Modes](deployment.md#network-topology-modes). | `"hubSpokeFirewall"` |
| `enableBastion` | bool | Adds hub-region Bastion alongside public jumpbox access. See [access and retirement behavior](access-and-administration.md#bastion-and-retained-jumpboxes). | `true` |
| `bastionSku` | string | Azure Bastion SKU: `Basic`, `Standard`, or `Premium`. | `"Standard"` |
| `foundationResourceGroup` | string | Resource group containing the Key Vault and the deployment identity named by the shared defaults, in the deployment subscription. | `"amrl-foundation-rg"` |
| `keyVaultName` | string | Key Vault name; Bicep resolves required secret values directly with `getSecret()`. | `"amrl-kv-example"` |
| `tags` | object | Resource tags for organisation and billing | `{"environment": "lab"}` |
| `regionCount` | integer | Number of regions to deploy across | `2` |
| `maxVmsPerRegion` | integer | Maximum VMs allowed per region | `2` |

In JSON parameter files, `parameters.prefix.value` supplies the resource naming prefix to Bicep. The sibling `parameters.prefix.metadata.bootstrap` object stores bootstrapper settings for Azure context and optional GitHub integration; these are not additional Bicep parameters and do not change the prefix value. Foundation resource group and Key Vault name are top-level Bicep parameters. Bootstrapper foundation and subscription deployment locations are derived from `regionIndexMap`, not metadata. See [Using `-ParameterFile`](bootstrapper.md#using-parameterfile) and [Subscription-Level Setup Values](bootstrapper.md#subscription-level-setup-values) for field requirements and behavior.

## Shared AMRL Defaults

[config/amrl-defaults.json](../config/amrl-defaults.json) is the single source of truth for AMRL-owned names. Bicep reads it at compile time with `loadJsonContent()`; the bootstrapper reads it with `ConvertFrom-Json`. These values are not deployment parameters, bootstrap metadata, or GitHub Actions variables.

| Default Key | Value | Purpose |
|---|---|---|
| `jumpboxAdminUsername` | `jmpadmin` | Jumpbox administrator username |
| `labAdminUsername` | `labadmin` | Administrator username for non-jumpbox roles |
| `automationManagedIdentityName` | `amrl-deployment-mi` | Deployment-script identity in `foundationResourceGroup` |
| `githubAppDisplayName` | `AMRL-github-actions` | Fixed Entra app display name used by optional GitHub OIDC setup |
| `jumpboxAdminPasswordSecretName` | `jumpboxAdminPassword` | Jumpbox password secret |
| `labAdminPasswordSecretName` | `labAdminPassword` | Shared non-jumpbox administrator password secret |
| `sshPublicKeySecretName` | `sshPublicKey` | Linux public-key secret |
| `sshPrivateKeySecretName` | `sshPrivateKey` | Jumpbox private-key secret |

Only nonsecret configuration belongs in this file. Changing a name does not rename existing identities or secrets, or rotate credentials on retained VMs. Review existing resources and credentials before changing these repository-owned defaults.

## Region and Network Configuration

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `regionIndexMap` | object | Maps region names to index numbers. Must be contiguous and start at 1. See [Region Indexes](deployment.md#region-indexes). | `{"westeurope": 1, "northeurope": 2}` |
| `subnetIndexMap` | object | Address indexes for all six standard roles; other keys add policy-neutral subnets | `{"firewall": 0, "bastion": 1, "jumpbox": 2, "dc": 3, "server": 4, "client": 5}` |
| `existingRegions` | array | Regions with existing networking (brownfield reuse). See [Placement and Reconciliation](placement-and-reconciliation.md). | `["westeurope"]` |
| `existingVmPlacements` | array | Existing VM inventory used for brownfield reconciliation | `[{"type": "dc", "index": 0, "regionKey": "westeurope"}]` |

**Examples**:
- **Greenfield (all new)**: `"existingRegions": []`, `"existingVmPlacements": []`
- **Brownfield (mixed)**: `"existingRegions": ["westeurope"]` (reuses westeurope, creates additional regions)

### Network Topology Modes

| Value | Resources created | Connectivity |
|---|---|---|
| `hubSpokeFirewall` | Hub-spoke peerings, Azure Firewall, firewall policy, `AzureFirewallSubnet`, route tables, and UDRs | Cross-spoke traffic is routed through the firewall. |
| `hubSpoke` | Hub-spoke peerings | Hub-to-spoke only; VNet peering is non-transitive, so spoke-to-spoke traffic is unavailable. |
| `fullMesh` | Direct regional peerings | Every selected region is directly peered with every other selected region. |

`networkMode` changes connectivity and routing independently of VM placement and identity targeting. See [Brownfield Topology Simplification](deployment.md#brownfield-topology-simplification) before changing an existing environment.

## Virtual Machine Configuration

Reserved subnet keys have known platform roles. AMRL generates role-specific NSGs in every mode. In `hubSpokeFirewall`, it also generates internal route tables for spoke DCs and jumpboxes and firewall route tables for server and client subnets. Additional subnet keys are policy-neutral and receive no inferred NSG or route table.

**VM Scale**:

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `vmCounts` | object | Desired totals for DCs, jumpboxes, and Windows/Linux servers and clients. Keep at least one DC and one jumpbox. | `{"dc": 1, "jumpbox": 1, "windowsServer": 1, "windowsClient": 0, "linuxServer": 0, "linuxClient": 0}` |

`vmCounts.dc` must be at least `1` even when identity and file services are disabled. The template evaluates the primary DC and file-server target during validation, so `dc=0` is not a supported compute-only or network-only configuration.

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

For direct jumpbox access, ensure `jumpboxAllowedSources` includes your approved source IP. Optional Bastion provides another path to the jumpbox; it does not remove existing public access.

## Credentials and Secrets

Passwords and SSH keys are stored in Azure Key Vault during subscription-level setup. The root Bicep template retrieves them directly using `adminVault.getSecret(...)` and passes them to secure module parameters. Parameter files contain neither secret values nor per-secret Key Vault reference objects. See [Key Vault Setup](manual-preparation.md#key-vault-setup) for creating or reusing the vault and secrets.

AMRL owns the usernames and secret names; they are not configurable deployment parameters.

| VM Roles | Fixed Username | Password Secret |
|---|---|---|
| Jumpboxes | `jmpadmin` | `jumpboxAdminPassword` |
| All non-jumpbox roles | `labadmin` | `labAdminPassword` |

| Required Key Vault Secret | Purpose |
|---|---|
| `jumpboxAdminPassword` | Password for the jumpbox local administrator |
| `labAdminPassword` | Shared administrator password for non-jumpbox VMs and the domain-join credential |
| `sshPublicKey` | Public key for Linux VM creation |
| `sshPrivateKey` | Private key deployed to jumpboxes |

Use a matching SSH key pair. See [SSH Key Setup](manual-preparation.md#ssh-key-setup) for subscription-level upload instructions.

The required top-level `foundationResourceGroup` and `keyVaultName` parameters identify the vault in the target subscription. The vault must enable template deployment, and the deploying identity must have permission to retrieve secrets through template deployment.

**Vault Parameters** (excerpt from the parameter file):

```json
{
  "parameters": {
    "foundationResourceGroup": {
      "value": "amrl-foundation-rg"
    },
    "keyVaultName": {
      "value": "<KEYVAULT_NAME>"
    }
  }
}
```

The bootstrapper persists the resolved vault parameters after preparation or foundation recovery. It derives the deployment identity resource ID from the selected subscription, `foundationResourceGroup`, and shared identity-name default. It rejects retired identity parameters, metadata-based foundation/identity names, and per-secret reference parameters; no backward-compatibility migration is supported. Other bootstrap metadata remains in use for Azure context, locations, and optional GitHub configuration.

## Identity Configuration

This is always an AD lab. Select `stage=identity` or `stage=all` to run AD automation. To postpone identity setup, run `network` followed by `compute`, then run `identity` when ready. Remove the former `enableIdentity` parameter from existing parameter files; `all` now always includes identity automation.

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `domainName` | string | AD domain name (e.g., FQDN) | `"amrl.lab"` |

**Department Configuration** (provisioned during `identity` or `all`):

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `sysAdminDepartment` | object | System administration department (must be exactly 1 entry) | `{"Information Technology": "ICT"}` |
| `additionalDepartments` | object | Additional departments available for selection | `{"Finance": "FIN", "Human Resources": "HR"}` |
| `departmentCount` | integer | Total departments to provision, including `sysAdminDepartment` | `2` |
| `usersPerDepartment` | integer | Standard user accounts to create per department, excluding the department manager | `5` |

`departmentCount` must be at least the number of entries in `sysAdminDepartment` and no greater than the combined number of entries in `sysAdminDepartment` and `additionalDepartments`. The interactive wizard does not enforce these limits; the Bicep validation engine evaluates them during deployment.

## Windows Admin Center Configuration (Optional)

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `enableWindowsAdminCenter` | boolean | Install Windows Admin Center on the selected management host after AD/GPO setup during `identity` or `all`. The host needs outbound HTTPS and DNS for installer download. | `false` |
| `useDedicatedWacHost` | boolean | Prefer the first `srvwin` in the final placement model instead of the primary jumpbox. Requires `enableWindowsAdminCenter=true`; if no `srvwin` exists, the primary jumpbox is used and `missingDedicatedWacHost` is reported as advisory. | `false` |

`useDedicatedWacHost=true` while `enableWindowsAdminCenter=false` activates the blocking `invalidDedicatedWacHostConfiguration` finding.

If WAC is enabled for a stage that does not run identity, `windowsAdminCenterSkippedForStage` is advisory. AMRL uses Windows Authentication; the browser connects to the gateway over HTTPS and the gateway manages Windows VMs over WinRM HTTP. WinRM over HTTPS is deferred until PKI is available. See [Windows Admin Center access](access-and-administration.md#windows-admin-center) for connection instructions.

## File Server Configuration

File services are provisioned as part of every `identity` or `all` stage; they have no enable/disable parameter. `useDedicatedFileServer` chooses the target host:

| Parameter | Type | Purpose | Example |
|---|---|---|---|
| `useDedicatedFileServer` | boolean | Use the first `srvwin` VM in the final placement model instead of the primary DC. When true, a `srvwin` target is required. See [File Server Reassignment on Brownfield Expansion](placement-and-reconciliation.md#file-server-reassignment-on-brownfield-expansion). | `true` |

If dedicated mode has no `srvwin` placement, target selection falls back to the primary DC so template evaluation can continue, but `missingDedicatedFileServer` is reported and the configuration should be corrected. Changing the target does not move existing share data or remove shares from the former host.

[Back to README](../README.md)
