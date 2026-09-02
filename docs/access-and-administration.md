# Access and Administration

[Back to README](../README.md)

## Access Model

Workload VMs are private. Administration uses regional jumpboxes:

```text
Internet -> Jumpbox -> Windows workload VMs (RDP)
Internet -> Jumpbox -> Linux workload VMs (SSH)
```

Only jumpboxes receive public IP addresses. `jumpboxAllowedSources` controls inbound RDP access to them.

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

### Linux Client GUI (RDP)

Linux client VMs (`clilin`) automatically install `ubuntu-desktop-minimal` and `xrdp` during the identity stage, exposing a desktop session over RDP through the jumpbox:

```text
Internet -> Jumpbox -> Linux client VM (RDP, GUI desktop)
```

Connect the same way as a Windows RDP session, targeting the Linux client's private IP on port 3389.

## Active Directory Access

After domain join, Windows and Linux systems can use AD credentials. Linux uses realmd, Kerberos, and SSSD. Members of the configured Linux administrator group receive sudo access through:

```text
/etc/sudoers.d/linux-admins
```

## SSH Key Setup

When Linux VMs are configured, place the public and private SSH keys in Key Vault using the names referenced by the parameter file:

```powershell
az keyvault secret set --vault-name <key-vault-name> --name sshPublicKey --value ((Get-Content "$HOME/.ssh/id_ed25519.pub" -Raw).Trim())
az keyvault secret set --vault-name <key-vault-name> --name sshPrivateKey --file "$HOME/.ssh/id_ed25519"
```

[Back to README](../README.md)
