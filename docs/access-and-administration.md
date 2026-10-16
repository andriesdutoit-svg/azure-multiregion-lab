# Access and Administration

[Back to README](../README.md)

## Access Model

Workload VMs are private. Administration uses regional jumpboxes:

```text
Internet -> Jumpbox -> Windows workload VMs (RDP)
Internet -> Jumpbox -> Linux workload VMs (SSH)
Internet -> Azure Bastion -> Jumpbox -> Workload VMs
```

New jumpboxes receive Public IPs regardless of `enableBastion`. Setting `enableBastion=true` adds hub-region Azure Bastion with its own Public IP; it does not replace public jumpbox access. `jumpboxAllowedSources` controls inbound RDP access to jumpboxes.

## Current Access Model

| Access method | Supported |
|---|---|
| Azure Bastion -> Jumpbox (RDP) | Yes, when enabled |
| Jumpbox -> Windows VM (RDP) | Yes |
| Jumpbox -> Linux VM (SSH key authentication) | Yes |
| Active Directory user logon on Linux (via SSSD, after SSH access) | Yes |
| Active Directory user logon on Windows | Yes |
| Linux sudo via the Linux admin group | Yes |
| Direct Internet -> Windows workload VM (RDP) | No |
| Direct Internet -> Linux workload VM (SSH) | No |
| Direct SSH logon using an Active Directory password | No |

All infrastructure administration is performed from jumpbox VMs. Workload VMs are never directly exposed to the Internet.

After domain join and DNS registration, use workload VMs' prefix-qualified FQDNs by default, such as `<prefix>-srvwin01.<domainName>`. Use private IP addresses when domain/DNS setup is not enabled or name resolution is unavailable. External access to a jumpbox uses its Public IP or an Azure Bastion session; AMRL does not configure a public DNS name for the jumpbox.

## Windows

Connect to the jumpbox using RDP through its Public IP or Azure Bastion, using `jumpboxAdminUsername` and its configured password. From the jumpbox, connect to a Windows workload by FQDN:

```powershell
$windowsVmFqdn = '<prefix>-srvwin01.<domainName>'
mstsc /v:$windowsVmFqdn
```

### Windows Admin Center

When `enableWindowsAdminCenter=true` and identity is enabled, AMRL installs the Windows Admin Center gateway during `stage=identity` or `stage=all`, after AD/GPO setup and Windows domain joins. The default host is the primary jumpbox; `useDedicatedWacHost=true` selects the first `srvwin` in the final placement model, falling back to the primary jumpbox if no Windows server is modeled.

For a fresh install, the script downloads Microsoft's current WAC v2 EXE through `https://aka.ms/WACDownload`, verifies its Authenticode signature, and runs it silently with its defaults. It then verifies service state and reports the installed status, HTTPS port, login mode, endpoint, WinRM-over-HTTPS, and TLS certificate. When both services already exist, reruns validate and leave that installation unchanged; there is no automatic upgrade. AMRL does not configure WAC-managed connections or add inbound web access. Reachability depends on the selected host's network and guest-firewall rules; AMRL does not expose the listener to the Internet.

From a network permitted to reach the selected host, browse to `https://<wac-hostname>:<configured-wac-port>` and trust/configure the installed certificate as required. Disabling WAC in a later deployment does not uninstall it from the host.

For domain-joined workloads, use an authorized domain account for routine administration. Administration GPOs assign the modeled Windows administrators group. Where Windows LAPS applies, use [LAPS recovery](#windows-laps-break-glass-access) rather than assuming the original local password remains current.

## Linux

Linux administration uses SSH key authentication with the local account configured by `serverAdminUsername` for Linux servers (`srvlin`) or `clientAdminUsername` for Linux clients (`clilin`). When Linux VMs are requested during an active compute or identity stage, SSH-key deployment targets new and retained jumpboxes from the final placement model at:

```text
C:\ProgramData\ssh\ssh-key
```

Retained jumpboxes declared in `existingVmPlacements` participate in SSH-key deployment/reconciliation. Use a new deployment name to reapply the Run Command. This updates the jumpbox copy of the private key; it does not rotate authorized public keys on retained Linux VMs.

From a jumpbox, use the Linux VM's FQDN and replace `<configured-admin-username>` with the corresponding parameter value:

```powershell
$linuxAdminUsername = '<configured-admin-username>'
$linuxVmFqdn = '<prefix>-srvlin01.<domainName>'
ssh -i C:\ProgramData\ssh\ssh-key "${linuxAdminUsername}@${linuxVmFqdn}"
```

Linux client SSH access from jumpboxes is always enabled and is not gated by a parameter.

Direct SSH authentication using Active Directory credentials is not supported. Linux VMs are deployed with `disablePasswordAuthentication: true`, which intentionally keeps infrastructure administration (SSH keys via the configured local administrator account) and user authentication (Active Directory credentials, via `su -` after SSH access) as separate security models.

### Linux Client GUI (RDP)

Linux client VMs (`clilin`) automatically install `ubuntu-desktop-minimal` and `xrdp` during the identity stage, exposing a desktop session over RDP through the jumpbox:

```text
Internet -> Jumpbox -> Linux client VM (RDP, GUI desktop)
```

Connect through the jumpbox using the Linux client's FQDN, such as `<prefix>-clilin01.<domainName>`, as for Windows RDP.

## Active Directory Access

After domain join, Windows and Linux systems can use AD credentials. Linux uses realmd, Kerberos, and SSSD. Members of the configured Linux administrator group receive sudo access through:

```text
/etc/sudoers.d/linux-admins
```

### Windows LAPS Break-Glass Access

Windows LAPS rotates local administrator passwords on domain-joined Windows servers and clients. Members of `GGS_Windows_Admins` can retrieve a managed password when recovery access is needed; use normal domain accounts for routine administration.

From a Windows administration host with the LAPS PowerShell module, retrieve a password record:

```powershell
$laps = Get-LapsADPassword -Identity 'A14-srvwin01'
```

To display the password as clear text:

```powershell
[System.Net.NetworkCredential]::new('', $laps.Password).Password
```

Treat the displayed password as a secret; do not put it in scripts, transcripts, tickets, or chat. To request immediate password processing, run this on the target Windows machine as an administrator:

```powershell
Invoke-LapsPolicyProcessing
```

Check retrieval status and the authorized decryptor with:

```powershell
Get-LapsADPassword -Identity 'A14-srvwin01' |
  Format-List DecryptionStatus,AuthorizedDecryptor
```

For the default lab configuration, expect `DecryptionStatus: Success` and `AuthorizedDecryptor: AMRL\GGS_Windows_Admins`. If the NetBIOS domain or directory-model group names change, the expected decryptor changes accordingly.

### Bastion And Retained Jumpboxes

Bastion provides an additional path to jumpboxes. During `network` or `all`, disabling it triggers cleanup of the framework-owned host, Public IP, and subnet when the hub is in `existingRegions`. See [network reconciliation](deployment.md#brownfield-topology-simplification) for conditions and verification.

Retained jumpboxes keep their existing Public IP configuration: missing IPs are not added and existing IPs are not removed automatically. Verify replacement access before disabling Bastion, particularly for retained jumpboxes created without Public IPs.

## Key Vault Setup

Foundation credential provisioning is documented in [New Subscription Setup](new-subscription-setup.md#key-vault-setup). The links below retain direct access to setup and maintenance tasks without repeating the deployment walkthrough.

### Create Or Reuse Key Vault

Follow [Create Or Reuse Key Vault](new-subscription-setup.md#create-or-reuse-key-vault), preserving existing vaults and secrets.

### User Secret Access

Use [User Secret Access](new-subscription-setup.md#user-secret-access) to grant the administrator secret-management permission.

### GitHub Actions Secret Access

For optional CI automation, configure [GitHub Actions Secret Access](new-subscription-setup.md#github-actions-secret-access) after OIDC setup.

### Foundation Deletion Lock

See [Foundation Deletion Lock](new-subscription-setup.md#foundation-deletion-lock) for protection and intentional maintenance.

### SSH Key Setup

Follow [SSH Key Setup](new-subscription-setup.md#ssh-key-setup) for a dedicated lab key pair and secure upload. Updating the vault alone does not rotate retained Linux authorized keys.

### Admin Password Setup

Use [Admin Password Setup](new-subscription-setup.md#admin-password-setup) for masked entry and upload. Deployment passwords initialize local VM accounts, not generated AD users; exposed retained guest credentials must be rotated separately.

[Back to README](../README.md)
