<#
Installs the shared SSH private key on a jumpbox so admins can SSH from the
jumpbox into Linux workload VMs without distributing the key more widely.
#>

param(
    [Parameter(Mandatory)]
    [string]$AdminUsername,

    [Parameter(Mandatory)]
    [string]$SshPrivateKey,

    [string]$ReconciliationToken
)

$sshFolder = "C:\ProgramData\ssh"
$keyPath = Join-Path $sshFolder 'ssh-key'

Write-Host '[INFO] Installing SSH private key'

if (-not (Test-Path $sshFolder)) {
    New-Item `
        -ItemType Directory `
        -Path $sshFolder `
        -Force | Out-Null
}

Write-Host "[INFO] Key length = $($SshPrivateKey.Length)"

[System.IO.File]::WriteAllText(
    $keyPath,
    ($SshPrivateKey + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

icacls $sshFolder /inheritance:r | Out-Null
icacls $keyPath /inheritance:r | Out-Null

# Remove the default "Users" group access, then grant only Administrators (full control)
# and the jumpbox admin account (read-only), matching OpenSSH's private key permission requirements.
icacls $keyPath /remove:g "Users" | Out-Null

icacls $keyPath /grant:r "Administrators:(F)" | Out-Null
icacls $keyPath /grant:r "${AdminUsername}:(R)" | Out-Null

Write-Host "[INFO] SSH key installed to $keyPath"