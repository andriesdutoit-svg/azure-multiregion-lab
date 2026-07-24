param(
    [Parameter(Mandatory)]
    [string]$KeyVaultName,

    [string]$SecretName = 'sshPrivateKey',

    [string]$KeyFileName = 'ssh-key'
)

$sshFolder = Join-Path $HOME '.ssh'
$keyPath = Join-Path $sshFolder $KeyFileName

Write-Host ''
Write-Host 'Retrieving Linux SSH private key from Key Vault...'

if (-not (Test-Path $sshFolder)) {
    New-Item `
        -ItemType Directory `
        -Path $sshFolder `
        -Force | Out-Null
}

$privateKey = az keyvault secret show `
    --vault-name $KeyVaultName `
    --name $SecretName `
    --query value `
    -o tsv

if (-not $privateKey) {
    throw (
        "Unable to retrieve secret '$SecretName' " +
        "from Key Vault '$KeyVaultName'."
    )
}

Set-Content `
    -Path $keyPath `
    -Value $privateKey `
    -NoNewline

# Restrict permissions to current user.
icacls $keyPath /inheritance:r | Out-Null
icacls $keyPath /grant:r "$($env:USERNAME):(R)" | Out-Null

param(
    [Parameter(Mandatory)]
    [string]$KeyVaultName,

    [string]$SecretName = 'sshPrivateKey',

    [string]$KeyFileName = 'ssh-key'
)

$sshFolder = Join-Path $HOME '.ssh'
$keyPath = Join-Path $sshFolder $KeyFileName

Write-Host ''
Write-Host 'Retrieving Linux SSH private key from Key Vault...'

if (-not (Test-Path $sshFolder)) {
    New-Item `
        -ItemType Directory `
        -Path $sshFolder `
        -Force | Out-Null
}

$privateKey = az keyvault secret show `
    --vault-name $KeyVaultName `
    --name $SecretName `
    --query value `
    -o tsv

if (-not $privateKey) {
    throw (
        "Unable to retrieve secret '$SecretName' " +
        "from Key Vault '$KeyVaultName'."
    )
}

Set-Content `
    -Path $keyPath `
    -Value $privateKey `
    -NoNewline

# Restrict permissions to current user.
icacls $keyPath /inheritance:r | Out-Null
icacls $keyPath /grant:r "$($env:USERNAME):(R)" | Out-Null

Write-Host ''
Write-Host 'Linux SSH private key restored successfully.'
Write-Host ''
Write-Host "Key file: $keyPath"
Write-Host ''
Write-Host 'SSH key restored successfully.'
Write-Host ''
Write-Host 'SSH example:'
Write-Host "ssh -i `"$keyPath`" <username>@<linux-ip>"
Write-Host ''