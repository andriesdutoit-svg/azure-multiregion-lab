<#
This script contains logic derived from and inspired by:

Set-DummyAD
https://github.com/BOAScripts/Set-DummyAD

Copyright (c) BOAScripts
Licensed under the MIT License.

Adapted and integrated for this project.
Replica DC promotion logic.
#>

# NOTE:
# ServerAdminPassword is received as a string because Azure VM Run Command
# passes parameter values as strings. The value is converted to a SecureString
# immediately and is not logged or written to output.

param(
    [string]$DomainName,
    [string]$ServerAdminUsername,
    [string]$ServerAdminPassword,
    [string]$ReconciliationToken
)

Write-Host "Preparing replica DC promotion for: $DomainName"

# Convert plain-text password parameter to SecureString immediately.
# VM Run Command passes all parameters as strings; password is not logged to output.
$SecurePassword = ConvertTo-SecureString `
    $ServerAdminPassword `
    -AsPlainText `
    -Force

# Extract NETBIOS domain name from FQDN (e.g., 'contoso.com' → 'CONTOSO').
# Used for credential context: credentials must reference the domain in NETBIOS\username format.
$NetBiosName = $DomainName.Split('.')[0].ToUpper()

# Build domain credential using NETBIOS\username format for authentication context.
# Required for Install-ADDSDomainController -Credential to work correctly.
$DomainCredential = New-Object System.Management.Automation.PSCredential(
    "$NetBiosName\$ServerAdminUsername",
    $SecurePassword
)

Write-Host "Using credential $NetBiosName\$ServerAdminUsername"

Import-Module ActiveDirectory -ErrorAction SilentlyContinue

# Idempotency check: if server is already a DC, exit 0 without re-promoting.
# Get-ADDomain will fail (caught) if this server is not yet a DC.
try {
    $CurrentDomain = Get-ADDomain -ErrorAction Stop

    Write-Host "Server is already a Domain Controller in $($CurrentDomain.Forest)"
    exit 0
}
catch {
    Write-Host "Server is not yet a Domain Controller"
}

if ((Get-WindowsFeature AD-Domain-Services).Installed) {
    Write-Host "AD DS role already installed"
}
else {
    Install-WindowsFeature `
        AD-Domain-Services `
        -IncludeManagementTools

    Write-Host "AD DS role installation complete"
}

Write-Host "Promoting server as replica Domain Controller in $DomainName"

Install-ADDSDomainController `
    -DomainName $DomainName `
    -Credential $DomainCredential `
    -InstallDns `
    -SafeModeAdministratorPassword $SecurePassword `
    -Force

Write-Host "Replica DC promotion initiated. The server will automatically reboot."