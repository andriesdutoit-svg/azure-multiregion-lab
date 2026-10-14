<#
.SYNOPSIS
Installs the shared Linux-administration SSH private key on a Windows jumpbox.
.DESCRIPTION
Writes C:\ProgramData\ssh\ssh-key and applies administrator/account ACLs so
operators can hop to Linux workloads without placing the private key on each VM.
The caller supplies the key and selects new or retained jumpboxes. This does not
rotate public keys in retained Linux authorized_keys files.
.NOTES
Runs through Azure VM Run Command with local filesystem/ACL permissions.
Key material must not be logged. ReconciliationToken is accepted for the caller's
rerun contract; the script reapplies the file and ACL commands on each invocation.
#>

# 1. Caller inputs
param(
    [Parameter(Mandatory)]
    [string]$AdminUsername,

    [Parameter(Mandatory)]
    [string]$SshPrivateKey,

    [string]$ReconciliationToken
)

# 2. Canonical guest paths
$sshFolder = "C:\ProgramData\ssh"
$keyPath = Join-Path $sshFolder 'ssh-key'

Write-Host '[Info] Installing the jumpbox SSH private key.'

# 3. Write the key as UTF-8 without a BOM and retain the terminating newline
if (-not (Test-Path $sshFolder)) {
    New-Item `
        -ItemType Directory `
        -Path $sshFolder `
        -Force | Out-Null
}

[System.IO.File]::WriteAllText(
    $keyPath,
    ($SshPrivateKey + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

# 4. Restrict inherited and explicit access
# Preserve command order: create the file before modifying its ACLs.
icacls $sshFolder /inheritance:r | Out-Null
icacls $keyPath /inheritance:r | Out-Null

# Remove the default "Users" group access, then grant only Administrators (full control)
# and the jumpbox admin account (read-only), matching OpenSSH's private key permission requirements.
icacls $keyPath /remove:g "Users" | Out-Null

icacls $keyPath /grant:r "Administrators:(F)" | Out-Null
icacls $keyPath /grant:r "${AdminUsername}:(R)" | Out-Null

Write-Host "[Info] SSH key file and ACL commands completed for $keyPath."