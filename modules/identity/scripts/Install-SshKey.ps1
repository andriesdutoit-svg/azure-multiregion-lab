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
Write-Host "[INFO] First 50 chars:"
Write-Host $SshPrivateKey.Substring(0,50)

[System.IO.File]::WriteAllText(
    $keyPath,
    ($SshPrivateKey + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

icacls $sshFolder /inheritance:r | Out-Null
icacls $keyPath /inheritance:r | Out-Null

icacls $keyPath /remove:g "Users" | Out-Null

icacls $keyPath /grant:r "Administrators:(F)" | Out-Null
icacls $keyPath /grant:r "${AdminUsername}:(R)" | Out-Null

Write-Host "[INFO] SSH key installed to $keyPath"