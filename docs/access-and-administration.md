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

For a fresh install, the script downloads Microsoft's current WAC v2 EXE through `https://aka.ms/WACDownload`, verifies its Authenticode signature, and runs it silently. On fresh installs and brownfield reruns, the repair path reapplies Windows Authentication, configures WinRM over HTTP, sets domain-only WinRM trusted hosts, ensures `RSAT-AD-PowerShell` is installed, and restarts the WAC service. Existing WAC services are not reinstalled or automatically upgraded. AMRL does not configure inbound web access or automatically populate Shared Connections; operators can use WAC's Active Directory search and UI to add connections. Reachability depends on the selected host's network and guest-firewall rules; AMRL does not expose the listener to the Internet.

| WAC setting | Target value | How AMRL handles it |
|---|---|---|
| Installation status | `StandardInstalled` | Checked after installation. |
| Login mode | `WindowsAuthentication` | Set by `Set-WACLoginMode` and checked. |
| WinRM over HTTPS | `false` | Written to WAC `appsettings.json`; WAC uses WinRM over HTTP (TCP 5985) for managed servers in the current phase. |
| WinRM trusted hosts | Domain-only | Configured by `Set-WACWinRmTrustedHosts`; not independently read back by the script. |
| WAC gateway HTTPS listener | `443` | The script reconciles the URL ACL for the WAC `NetworkService` identity and gateway computer account. If the binding is absent or points to a different certificate, it calls WAC's `Register-WACHttpSys`, then requires the binding to match WAC's configured certificate. It also checks WAC's reported port and local TCP reachability. This is separate from WinRM transport to managed servers. |
| Service port range | `6601-6610` | Observed in the manual WAC installation; not currently set or verified by the script. |
| Software updates | `Automatic` | Observed in the manual WAC installation; not currently set or verified by the script. |
| Telemetry privacy | `Required` | Observed in the manual WAC installation; not currently set or verified by the script. |
| Runtime / operation mode | `Service` / `Production` | Observed in the manual WAC installation; not currently checked by the script. |

The installer-generated self-signed certificate is checked for presence, but its identity and trust chain are not validated. When the HTTP.SYS binding is missing or mismatched, the script uses WAC's supported `Register-WACHttpSys` cmdlet and fails if the expected binding is still absent afterward; it does not construct SSL bindings with raw `netsh` commands. For browser access, use `https://<wac-hostname>:443` after confirming the listener configuration and arrange certificate trust as required. The endpoint check extracts `EndpointFqdn` and rejects an empty value; it does not compare the value with the expected host FQDN.

### WAC Remote Management

WAC's browser connection to the gateway uses HTTPS; the current gateway-to-server WinRM transport uses HTTP on TCP 5985. The server and client NSGs allow TCP 5985 and 5986 from `10.0.0.0/8`. The Server Administration and Client Administration GPOs configure the WinRM service and allow both ports from that range on **all Windows firewall profiles**. A separate GPO grants the same all-profile TCP 5985 access to domain controllers. WinRM over HTTPS (5986) is not configured because the lab does not yet provision server-authentication certificates; it is deferred to the PKI/security phase. Identity-stage checks refresh and verify these GPO rules before removing legacy per-VM firewall rules.

Verify the target's network profile and effective policy as well as TCP reachability. A successful `Test-NetConnection` proves only that TCP connects, not that WinRM authentication or WAC delegation succeeds. In the reported v2.10 tests, cross-region WinRM and WAC management worked with explicit **Manage As** credentials after correcting the managed server's Windows Firewall rule. **Use my Windows account** still failed with `0x8009030e`; Kerberos delegation is the suspected cause and remains unresolved. Use explicit credentials as the current workaround. RBCD is a candidate for a future design, not an implemented capability.

Disabling WAC in a later deployment does not uninstall it from the host.

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
