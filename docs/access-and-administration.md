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

When `enableWindowsAdminCenter=true`, AMRL installs the gateway during `stage=identity` or `stage=all`, after AD and Windows domain join. The default host is the primary jumpbox; `useDedicatedWacHost=true` selects the first `srvwin`, falling back to the jumpbox if none is modeled. The gateway needs working DNS and outbound HTTPS.

Open `https://<wac-hostname>` from a network that can reach the gateway, and trust its certificate if prompted. In WAC, choose **All connections > Add** and search Active Directory to find domain-joined VMs, or add one by its FQDN (for example, `<prefix>-srvwin01.<domainName>`). For the connection, choose **Manage As** and enter an authorized domain account in `user@domain` format, such as `admin@example.com`. **Use my Windows account** is not supported because AMRL does not configure credential delegation.

The browser-to-gateway connection uses HTTPS; the gateway connects to Windows VMs with WinRM over HTTP/TCP 5985. WinRM HTTPS/TCP 5986 is not configured; its NSG/GPO allowance alone does not provide a listener or certificate. AMRL does not expose the WAC UI to the Internet. See [WAC and WinRM checks](validation-and-troubleshooting.md#wac-and-winrm-checks) if a target cannot be reached.

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

## Credentials and Keys

Credential, Key Vault, and SSH-key provisioning are covered in [New Subscription Setup](new-subscription-setup.md). Updating a Key Vault secret does not by itself rotate credentials already installed on retained VMs.

[Back to README](../README.md)
