param(
    [Parameter(Mandatory)]
    [string]$AdminUsername,

    [Parameter(Mandatory)]
    [string]$SshPrivateKey
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

Set-Content `
    -Path $keyPath `
    -Value $SshPrivateKey `
    -NoNewline

icacls $sshFolder /inheritance:r | Out-Null
icacls $keyPath /inheritance:r | Out-Null
icacls $keyPath /grant:r "Users:(R)" | Out-Null

Write-Host "[INFO] SSH key installed to $keyPath"