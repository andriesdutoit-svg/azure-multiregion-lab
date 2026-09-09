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

## Windows

Connect to a jumpbox with RDP, then connect to Windows servers and clients using the local deployment administrator account. Workload VMs are not directly exposed to the Internet.

## Linux

Linux administration uses the `azureadmin` account and SSH key authentication. The private key is deployed to jumpboxes at:

```text
C:\ProgramData\ssh\ssh-key
```

From a jumpbox:

```powershell
ssh -i C:\ProgramData\ssh\ssh-key azureadmin@<linux-vm-private-ip>
```

Linux client SSH access from jumpboxes is always enabled and is not gated by a parameter.

### Future Enhancement Consideration

Direct SSH authentication using Active Directory credentials (e.g. `ssh user@amrl.lab@<ip>`) is not supported. Linux VMs are deployed with `disablePasswordAuthentication: true`, which intentionally keeps infrastructure administration (SSH keys via `azureadmin`) and user authentication (Active Directory credentials, via `su -` after SSH access) as separate security models.

### Linux Client GUI (RDP)

Linux client VMs (`clilin`) automatically install `ubuntu-desktop-minimal` and `xrdp` during the identity stage, exposing a desktop session over RDP through the jumpbox:

```text
Internet -> Jumpbox -> Linux client VM (RDP, GUI desktop)
```

Connect the same way as a Windows RDP session, targeting the Linux client's private IP or its FQDN (registered via dynamic DNS).

## Active Directory Access

After domain join, Windows and Linux systems can use AD credentials. Linux uses realmd, Kerberos, and SSSD. Members of the configured Linux administrator group receive sudo access through:

```text
/etc/sudoers.d/linux-admins
```

## Key Vault Setup

Parameter files reference admin passwords and SSH keys from Key Vault via `reference.keyVault.id` (see `main.parameters.*.json`). Run this once per subscription (for example, after moving the lab to a new subscription) to recreate the vault referenced by those parameter files.

Required secret names:

| Secret name | Purpose |
|---|---|
| `sshPublicKey` | Linux VM SSH public key |
| `sshPrivateKey` | Linux VM SSH private key, also deployed to jumpboxes |
| `jumpboxAdminPassword` | Local admin password for jumpboxes |
| `serverAdminPassword` | Local admin password for Windows/Linux servers |
| `clientAdminPassword` | Local admin password for Windows/Linux clients |

Register the resource provider (only needed once per subscription) and create the resource group and vault:

```powershell
az provider register --namespace Microsoft.KeyVault
az group create --name <foundation-rg> --location <region>
az keyvault create --name <key-vault-name> --resource-group <foundation-rg> --location <region> `
  --enable-rbac-authorization true --enabled-for-template-deployment true
```

`--enabled-for-template-deployment true` is required so ARM/Bicep deployments can resolve `reference.keyVault` secret values. Grant RBAC access to whoever creates secrets and to any principal that deploys the template (including the GitHub Actions service principal from [CI/CD Workflow and Local Checks](ci-cd-validation.md)):

```powershell
$kvId = az keyvault show --name <key-vault-name> --resource-group <foundation-rg> --query id -o tsv

az role assignment create --assignee <your-user-object-id> --role "Key Vault Secrets Officer" --scope $kvId
az role assignment create --assignee <github-actions-app-id> --role "Key Vault Secrets User" --scope $kvId
```

### SSH Key Setup

When Linux VMs are configured, place the public and private SSH keys in Key Vault using the names referenced by the parameter file:

```powershell
az keyvault secret set --vault-name <key-vault-name> --name sshPublicKey --value ((Get-Content "$HOME/.ssh/id_ed25519.pub" -Raw).Trim())
az keyvault secret set --vault-name <key-vault-name> --name sshPrivateKey --file "$HOME/.ssh/id_ed25519"
```

### Admin Password Setup

Set the three admin password secrets:

```powershell
az keyvault secret set --vault-name <key-vault-name> --name jumpboxAdminPassword --value "<password>"
az keyvault secret set --vault-name <key-vault-name> --name serverAdminPassword --value "<password>"
az keyvault secret set --vault-name <key-vault-name> --name clientAdminPassword --value "<password>"
```

After the vault and secrets are recreated, update every `reference.keyVault.id` in the parameter file to the new vault's resource ID.

[Back to README](../README.md)
