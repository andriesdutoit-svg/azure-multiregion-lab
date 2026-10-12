# Access and Administration

[Back to README](../README.md)

## Access Model

Workload VMs are private. Administration uses regional jumpboxes:

```text
Internet -> Jumpbox -> Windows workload VMs (RDP)
Internet -> Jumpbox -> Linux workload VMs (SSH)
```

Only jumpboxes receive public IP addresses. `jumpboxAllowedSources` controls inbound RDP access to them.

## Current Access Model

| Access method | Supported |
|---|---|
| Jumpbox -> Windows VM (RDP) | Yes |
| Jumpbox -> Linux VM (SSH key authentication) | Yes |
| Active Directory user logon on Linux (via SSSD, after SSH access) | Yes |
| Active Directory user logon on Windows | Yes |
| Linux sudo via the Linux admin group | Yes |
| Direct Internet -> Windows workload VM (RDP) | No |
| Direct Internet -> Linux workload VM (SSH) | No |
| Direct SSH logon using an Active Directory password | No |

All infrastructure administration is performed from jumpbox VMs. Workload VMs are never directly exposed to the Internet.

After domain join and DNS registration, use workload VMs' prefix-qualified FQDNs by default, such as `<prefix>-srvwin01.<domainName>`. Use private IP addresses when domain/DNS setup is not enabled or name resolution is unavailable. External access to a jumpbox uses its public IP; AMRL does not configure a public DNS name for it.

## Windows

Connect to the jumpbox's public IP with RDP, then use the Windows workload VM's FQDN and configured administrator account. From the jumpbox:

```powershell
$windowsVmFqdn = '<prefix>-srvwin01.<domainName>'
mstsc /v:$windowsVmFqdn
```

## Linux

Linux administration uses SSH key authentication with the local account configured by `serverAdminUsername` for Linux servers (`srvlin`) or `clientAdminUsername` for Linux clients (`clilin`). When Linux VMs are requested during an active compute or identity stage, SSH-key deployment targets new and retained jumpboxes from the final placement model at:

```text
C:\ProgramData\ssh\ssh-key
```

Retained jumpboxes declared in `existingVmPlacements` now participate in SSH-key deployment/reconciliation. Use a new deployment name to reapply the Run Command. This updates the jumpbox copy of the private key; it does not rotate authorized public keys on retained Linux VMs.

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

## Key Vault Setup

Parameter files reference admin passwords and SSH keys from Key Vault via `reference.keyVault.id` (see `main.parameters.*.json`). Run this once per subscription (for example, after moving the lab to a new subscription) to recreate the vault referenced by those parameter files.

For the complete execution order, start with [New Subscription Setup](new-subscription-setup.md). The commands below use its initialized `$foundationRg`, `$foundationLocation`, and `$vaultName` values. Create the foundation resource group before the vault; use the same PowerShell session or reinitialize these variables.

Required secret names:

| Secret name | Purpose |
|---|---|
| `sshPublicKey` | Linux VM SSH public key |
| `sshPrivateKey` | Linux VM SSH private key, also deployed to jumpboxes |
| `jumpboxAdminPassword` | Local admin password for jumpboxes |
| `serverAdminPassword` | Local admin password for Windows/Linux servers |
| `clientAdminPassword` | Local admin password for Windows/Linux clients |

### Create Or Reuse Key Vault

Prerequisites: provider registration, the foundation group, and shared values from [Azure Context And Foundation](new-subscription-setup.md#azure-context-and-foundation). Inspect existing vaults and create the selected vault only if it does not already exist:

```powershell
az keyvault list --resource-group $foundationRg --query "[].{name:name,id:id}" -o table
az keyvault create --name $vaultName --resource-group $foundationRg --location $foundationLocation `
  --enable-rbac-authorization true --enabled-for-template-deployment true `
  --enable-purge-protection true --output none
if ($LASTEXITCODE -ne 0) { throw 'Key Vault creation failed.' }
```

`--enabled-for-template-deployment true` is required so ARM/Bicep deployments can resolve `reference.keyVault` secret values. Purge protection is irreversible: after `--enable-purge-protection true` is enabled, it cannot be disabled, and a deleted vault cannot be permanently purged until its soft-delete retention period expires. This protects the recovered secrets, keys, and certificates from immediate permanent deletion, but does not prevent the vault from being soft-deleted.

### User Secret Access

Prerequisite: the selected vault exists. Grant your signed-in user permission to create secrets in the vault's tenant and subscription:

```powershell
$kvId = az keyvault show --name $vaultName --resource-group $foundationRg --query id -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kvId)) {
  throw 'Could not resolve the Key Vault resource ID.'
}

$userObjectId = az ad signed-in-user show --query id -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($userObjectId)) {
  throw 'Could not resolve the signed-in user object ID.'
}

az role assignment create --assignee-object-id $userObjectId `
  --assignee-principal-type User --role "Key Vault Secrets Officer" --scope $kvId --output none
```

### GitHub Actions Secret Access

Optional for local-only deployment. Prerequisites: `$kvId` from [User Secret Access](#user-secret-access), and the app and service principal from [Bootstrapping OIDC](ci-cd-validation.md#bootstrapping-oidc-for-a-new-subscription-or-tenant). Use the app's **Application (client) ID**, not its app-registration Object ID. App registrations belong to a tenant; do not assume an ID from a previous tenant exists in the new one.

After OIDC setup, use the app returned there and resolve its service principal before assigning access. In a new session, first reload the app using the existing-app path in that guide:

```powershell
$githubActionsAppId = $app.appId
if ([string]::IsNullOrWhiteSpace($githubActionsAppId)) { throw 'Complete or reload OIDC app setup first.' }
$githubActionsSpObjectId = az ad sp show --id $githubActionsAppId --query id -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($githubActionsSpObjectId)) {
  throw 'GitHub Actions service principal not found in this tenant; complete OIDC setup first.'
}

az role assignment create --assignee-object-id $githubActionsSpObjectId `
  --assignee-principal-type ServicePrincipal --role "Key Vault Secrets User" --scope $kvId --output none
```

PowerShell variables are session-local; an unset variable produces the CLI error `argument --id: expected one argument`. If vault access has not propagated yet, retry after RBAC propagation rather than recreating the vault or granting broader roles.

### Foundation Deletion Lock

After creating the foundation resources and restoring their RBAC assignments, protect the resource group from accidental deletion:

```powershell
az lock create `
  --name protect-foundation `
  --lock-type CanNotDelete `
  --resource-group $foundationRg --output none
```

The `CanNotDelete` lock applies to the resource group and its contained Azure resources, blocking control-plane delete operations against the group, Key Vault, and deployment managed identity. It still permits reads, updates, secret operations, and creation of additional resources. It does not block Key Vault data-plane deletion of individual secrets; soft delete and purge protection govern recovery and permanent purge instead.

Remove the lock only for an intentional foundation-resource deletion, then recreate it after maintenance:

```powershell
az lock delete --name protect-foundation --resource-group $foundationRg --output none
```

### SSH Key Setup

When Linux VMs are configured, place the public and private SSH keys in Key Vault using the names referenced by the parameter file:

Use a dedicated lab key, not a personal GitHub or production key. If you do not already have one, generate it at a new path without overwriting an existing key:

```powershell
$sshKeyPath = Join-Path $HOME '.ssh/amrl_ed25519'
if (-not (Test-Path -LiteralPath $sshKeyPath)) {
  New-Item -ItemType Directory -Path (Split-Path $sshKeyPath -Parent) -Force | Out-Null
  ssh-keygen -t ed25519 -f $sshKeyPath
  if ($LASTEXITCODE -ne 0) { throw 'SSH key generation failed.' }
}
az keyvault secret set --vault-name $vaultName --name sshPublicKey `
  --value ((Get-Content "$sshKeyPath.pub" -Raw).Trim()) --output none
if ($LASTEXITCODE -ne 0) { throw 'SSH public-key upload failed.' }
az keyvault secret set --vault-name $vaultName --name sshPrivateKey --file $sshKeyPath --output none
if ($LASTEXITCODE -ne 0) { throw 'SSH private-key upload failed.' }
```

Run key generation interactively and keep any passphrase out of scripts and chat. A passphrase-protected key requires unlocking when SSH uses it; AMRL does not distribute the passphrase. `--output none` prevents Key Vault's response from printing the private key. Do not rerun these commands with default JSON output.
AMRL installs the configured SSH keys; it does not provide automatic key rotation or SSH configuration remediation.

### Admin Password Setup

Set distinct, strong passwords using masked prompts rather than literal values in shell history. Run this interactively; the CLI receives temporary plaintext in process memory/arguments, so protect the administration workstation and avoid transcripts or diagnostic tracing:

```powershell
foreach ($secretName in @('jumpboxAdminPassword', 'serverAdminPassword', 'clientAdminPassword')) {
  $securePassword = Read-Host "Password for $secretName" -AsSecureString
  try {
    $passwordValue = [System.Net.NetworkCredential]::new('', $securePassword).Password
    az keyvault secret set --vault-name $vaultName --name $secretName --value $passwordValue --output none
    if ($LASTEXITCODE -ne 0) { throw "Password secret upload failed: $secretName" }
  }
  finally {
    $passwordValue = $null
    $securePassword.Dispose()
  }
}
az keyvault secret list --vault-name $vaultName --query "[].{name:name,enabled:attributes.enabled}" -o table
```

If a private key or password has appeared in terminal output that was shared, treat it as compromised. Replace the SSH key pair and all exposed passwords; also update existing VM authorized keys and account passwords where those credentials were used. Updating a Key Vault secret alone does not rotate credentials on retained VMs.

These Key Vault passwords remain deployment credentials, not passwords for generated AD users. In particular, `clientAdminPassword` remains wired through the compute stage to initialize the local client VM account; it is not passed to directory population. `Populate-AD.ps1` creates an independent random password for each new AD user and does not expose or retain it, so arrange a separate secure password-reset or delivery process for users.

After the vault and secrets are recreated, follow [Configure Deployment Parameters](new-subscription-setup.md#configure-deployment-parameters) to update every Key Vault reference and the managed-identity resource ID.

[Back to README](../README.md)
