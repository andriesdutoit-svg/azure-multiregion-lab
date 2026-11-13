# Identity and Domain Join

[Back to README](../README.md)

## Identity Flow

The lab always includes Active Directory. Selecting `stage=identity` or `stage=all` runs this sequence; `network` and `compute` postpone AD automation without changing the lab's intended configuration:

```mermaid
flowchart TD
  A[Primary DC forest bootstrap] --> B[Replica DC promotion]
  B --> C[Directory population]
  C --> D[Group Policy provisioning]
  D --> E[Windows workload domain join]
  E --> F[Windows workload SPN reconciliation]
  D --> G[Linux server domain join]
  D --> H[Linux client desktop prerequisites, when modeled]
  H --> I[Linux client domain join]
  C --> J[Departmental share provisioning]
  E --> J
  D --> K[Windows Admin Center, when enabled]
  F --> K
```

| Step | Purpose and result |
|---|---|
| Primary forest | Turns the primary DC into the lab's AD forest and domain DNS anchor. |
| Replicas | Adds DCs to the same domain for additional directory/DNS endpoints. |
| Population | Creates the modeled departmental OUs, users, managers, and security groups. |
| Group Policy | Establishes Windows administrator and LAPS policies before workload joins. |
| Domain joins | Places Windows/Linux workloads in their role OUs and enables domain authentication. |
| Departmental shares | Always creates/reconciles share groups and provisions SMB shares during identity setup; share creation waits for Windows workload joins. |
| Linux client desktops | Installs desktop and RDP prerequisites only for modeled Linux client VMs, before those clients join the domain. |
| Windows Admin Center | Installs only when enabled; it waits for GPO, Windows join, and Windows HTTP SPN reconciliation. |

The primary DC and replica DCs must already exist before a standalone `identity` stage can complete. Missing workload VMs may be created during the identity stage so they are available for domain joining. Generated user passwords need a separate secure reset/delivery process before interactive user testing.

## Directory Model

The default hierarchy puts workload computers under `_ROOT/Computers/Servers` or `_ROOT/Computers/Clients`, groups under `_ROOT/Groups`, and departmental accounts under `_ROOT/Users`. Users enter department global security groups; those groups nest into domain-local permission groups for shares (AGDLP). This connects account population to actual resource access rather than creating unrelated sample objects.

The `directoryModel` object in `modules/stages/identity-stage.bicep` is passed as a JSON string to identity scripts that require directory structure, group naming, OU mapping, GPO names, or share configuration. It centralises those details so the scripts do not hardcode AD structure:

- `rootOuName` — top-level OU beneath the domain root (`_ROOT`).
- `customOus` — hierarchical OU structure for computers, groups, and users, including reserved OUs for disabled users.
- `computerOuMapping` — maps VM types to OU locations (e.g. `srvwin`/`srvlin` → `Computers/Servers`, `cliwin`/`clilin` → `Computers/Clients`).
- `groupOuMapping` — OUs for global security groups (`Groups/GGS`) and domain local security groups (`Groups/DLGS`).
- `groupNaming` — configurable prefixes: `globalSecurityPrefix` (`GGS`) for user-facing department groups, `domainLocalSecurityPrefix` (`DLGS`) for share permission groups.
- `platformAdminGroups` — names of the Windows/Linux platform admin groups and the department code they're sourced from.
- `serviceAccounts` — backup and monitoring account names, global security group suffixes, and Key Vault password secret names.
- `gpoNames` — display names for the Server Administration, Client Administration, Windows LAPS, and Domain Controller WinRM GPOs. The configurator creates and reconciles all four directly in Active Directory.
- `shares` — root share name/path (`C:\Shares`) and the current file server host (`fileServerName`).
- `coreOuMapping` — references to the core `Users`/`Groups` OUs used by scripts.

The directory model is not parameterised; it represents a stable architectural decision. Customisation requires editing `modules/stages/identity-stage.bicep` directly.

## Directory Population Rules

`Initialize-AD.ps1` enforces these rules on every run (greenfield and brownfield):

- **Manager rule**: exactly one manager per department, identified by a title matching `*Manager*`. If multiple exist, the first is retained and others are demoted. If none exists, a new manager is created from an unused CSV record.
- **Reporting lines**: unmanaged users are assigned to their department's manager; users with invalid or cross-department reporting lines are reassigned.
- **User targets**: `usersPerDepartment` is enforced as a minimum for standard users (managers counted separately). Under-populated departments are topped up; over-populated departments are left as-is.
- **New user addition**: added round-robin across departments that still need users; username collisions are skipped, and population stops with a warning when unique CSV names are exhausted.
- **New account passwords**: each newly created manager or standard AD user receives an independent 24-character password generated with a cryptographic random-number generator. Existing users' passwords are not reset. Generated passwords are not written to Run Command output or retained for retrieval, so user onboarding needs a separate secure password-reset or delivery process.
- **Platform administrator groups**: Windows and Linux administrator groups are reconciled to the configured `platformAdminGroups.sourceDepartmentCode`; memberships from a previous source department are removed when the configuration changes.
- **Department removal**: removing a department from `additionalDepartments` does not delete its OU or users; the OU becomes unmanaged rather than deleted.

Reruns preserve object identities while repairing the selected attributes and memberships above. They are not a general directory teardown or exact-state replacement.

## Backup and Monitoring Service Accounts

The backup and monitoring accounts and their group suffixes are defined under `directory.serviceAccounts` in `config/amrl-defaults.json`. The bootstrapper keeps active Key Vault secrets unchanged and attempts to recover soft-deleted values for all managed password secrets, including these service-account secrets. If no active or recoverable value exists, it creates a replacement using the normal password generation or secure-entry flow. It does not check whether the corresponding AD account already exists or reconcile that account's password to a newly created or recovered secret.

During directory population, missing accounts are created with their Key Vault password. Existing accounts keep their current passwords, while membership in the configured backup or monitoring group is reconciled on every run. If a secret had to be replaced while its AD account already existed, the Key Vault and AD passwords may differ; align them separately if the service requires matching credentials.

## Windows LAPS Active Directory Configuration

During directory population, `Set-AmrlLapsConfiguration` checks for the `ms-LAPS-Password` schema attribute and extends the AD schema with `Update-LapsADSchema` only when it is missing. It grants computer self-update permission separately on the Servers and Clients OUs, then grants the configured Windows administrators group (default `GGS_Windows_Admins`) permission to read LAPS passwords on both OUs.

The linked Windows LAPS GPO supplies the policy side of this setup: it backs passwords up to Active Directory. `Set-GPOs.ps1` creates or reconciles its backup directory, password complexity, password length, password age, and authorized decryptor settings directly in the GPO. The decryptor is derived from the live NetBIOS domain and the Windows administrators group in `directoryModel`.

## Departmental File Services

Directory population creates each department's `Share_RW` and `Share_RO` domain-local groups and nests the manager and user groups into them as part of every identity-stage run. Share provisioning is handled separately on the selected file server.

Directory population and share provisioning embed the same `Get-SelectedDepartments.ps1` helper in their Run Command payloads. All mandatory system-administration departments are retained in input order; additional departments fill the remaining slots in their JSON-property order. Requests smaller than the mandatory set are rejected, keeping directory groups and shares aligned without duplicate selection implementations.

After Windows domain join completes, `Set-Shares.ps1` runs on the selected file server. It creates `C:\Shares`, creates one SMB share per selected department, and applies the domain-local groups as NTFS Modify and Read-and-Execute permissions. The script retains existing directories and SMB shares and reapplies the expected ACL rules on reconciliation.

With `useDedicatedFileServer=false`, the selected host is the primary DC. With `useDedicatedFileServer=true`, it is the first `srvwin` VM in the final placement model. See [File Server Reassignment on Brownfield Expansion](placement-and-reconciliation.md#file-server-reassignment-on-brownfield-expansion) before changing this setting in an existing environment.

## Reconciliation

Identity operations use Azure VM Run Command resources. A new deployment name changes the Run Command definition and causes the command to be reapplied. The scripts inspect the current state rather than relying on a persisted reconciliation token.

Examples:

- Forest bootstrap exits when an AD domain already exists.
- Replica promotion exits when the target server is already a DC.
- Windows domain join skips rejoining when `PartOfDomain` is true; a dependent post-join Run Command reconciles workload HTTP SPNs after the guest is ready.
- Linux domain join skips `realm join` when the VM is already joined.
- Directory population restores missing OUs, groups, users, and memberships.

## Windows Domain Join

Windows workload VMs are targeted from `finalVmPlacements` after Group Policy provisioning completes. The PowerShell script checks `Win32_ComputerSystem.PartOfDomain`; retained members skip the join. For a new join, it joins the configured domain and OU, verifies membership, and restarts the machine. Local Administrators membership is managed by Group Policy, not by this script.

Windows applies computer policy normally; deployment does not wait for policy processing.

### Windows Remote-Management Components

| Step | Bicep module / orchestration | Guest script | Responsibility |
|---|---|---|---|
| Domain join | `modules/stages/identity-stage.bicep` → `modules/identity/domain-join.bicep` | `modules/identity/scripts/Join-Domain.ps1` | Join a new workload to its domain/OU, verify membership, and restart it. Retained members skip rejoining. |
| Workload SPN reconciliation | `modules/stages/identity-stage.bicep` → `modules/identity/domain-join-spn.bicep` | `modules/identity/scripts/Reconcile-WinRMHttpSpns.ps1` | After the join command completes, wait for the machine secure channel and idempotently reconcile short-name and FQDN HTTP SPNs with bounded retries. |
| WAC gateway install/repair | `modules/stages/identity-stage.bicep` → `modules/identity/wac.bicep` | `modules/identity/scripts/Install-WAC.ps1` | Install or repair the selected gateway and its configuration. The stage waits for Windows join and SPN reconciliation; workgroup gateways receive explicit modeled target FQDNs in TrustedHosts. |

Directory population configures DC HTTP SPNs after forest and replica promotion. Deployment success does not guarantee that each VM has processed its policies or that guest access is ready.

## Group Policy Provisioning

Group Policy covers the main Windows administration needs:

- Server and Client Administration policies configure WinRM and allow TCP 5985/5986 from `10.0.0.0/8` on all firewall profiles.
- The Administration policies add the modeled Windows administrators group to local Administrators without replacing unrelated members.
- Windows LAPS backs local administrator passwords up to AD for Servers and Clients.
- A separate Domain Controller policy allows TCP 5985 from `10.0.0.0/8` on all profiles.

Settings managed by AMRL are reapplied during identity deployments; unmodeled GPO settings are preserved. Windows processes the policies normally, so verify effective settings and access separately after deployment. The 5986 allowance does not configure a WinRM HTTPS listener or certificate.

## Linux Domain Join

Linux workload VMs use `realmd`, `adcli`, Kerberos, and SSSD. The script:

1. Validates required inputs.
2. Checks existing realm membership.
3. Installs prerequisites when the VM still needs to join or requires healing.
4. Discovers the domain when a join is required.
5. Runs verbose `realm join` for an unjoined VM.
6. Configures SSSD, automatic home directories, realm access, and Linux administrator sudo rights.
7. Sets the VM hostname to its FQDN (`<hostname>.<domainName>`) and enables SSSD dynamic DNS so the VM registers its own A/PTR records, then triggers an immediate `adcli update` instead of waiting for the next refresh interval.
8. Validates the resulting realm state.

Already joined Linux VMs skip package installation, discovery, and joining but continue the SSSD, access, sudo, and validation steps. This preserves the healing path for partially configured machines.

### Linux Endpoint Administration Reconciliation

On every identity-stage run, the Linux script reconciles selected SSSD keys, restarts SSSD when one of those keys changes, ensures the `pam_mkhomedir.so` session module is present, and sets the realm login policy to `allow-realm-logins`. That realm policy allows all domain users to log in; administrative sudo is separately limited by the model-derived `GGS_Linux_Admins` sudoers rule. The script checks both the rule content and file mode (`0440`), writes changes to a temporary file, validates them with `visudo`, and then installs the file. This is selective reconciliation of those settings, not a replacement of the full SSSD or host configuration.

## Linux Client Desktop Installation

Before Linux clients (`clilin`) join the domain, `modules/compute/linux-desktop.bicep` runs a Run Command that installs `ubuntu-desktop-minimal` and `xrdp`, enabling RDP-based GUI access. It also configures a broad lab Polkit rule granting the modeled Linux administrator group desktop-action authorization in active, inactive, and other contexts. `domainJoinLinux` depends on this step so the desktop environment is present before the client is joined.

Bash scripts are stored with LF line endings through `.gitattributes`:

```gitattributes
*.sh text eol=lf
```

## Troubleshooting

Inspect the VM Run Command instance view when a job exists but a VM is not joined:

```powershell
az vm run-command show `
        --resource-group "<resource-group>" `
        --vm-name "<vm-name>" `
  --run-command-name join-domain-linux `
  --expand instanceView
```

A successful Run Command resource deployment does not necessarily mean that the guest script succeeded. Check `executionState`, `exitCode`, `error`, and `output`.

[Back to README](../README.md)
