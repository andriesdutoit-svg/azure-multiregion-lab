<#
This script contains logic derived from and inspired by:

Set-DummyAD
https://github.com/BOAScripts/Set-DummyAD

Copyright (c) BOAScripts
Licensed under the MIT License.

Adapted and integrated for this project.
Replica DC promotion logic.
#>

# ============================================================================
# REPLICA DC PROMOTION SCRIPT
# Promotes a Windows server to Replica Domain Controller.
# Idempotent: script detects existing DC status and exits if already promoted.
#
# NOTE: ServerAdminPassword is received as a string because Azure VM Run Command
# passes parameter values as strings. Converted to SecureString immediately.
# ============================================================================

param(
    [string]$DomainName,
    [string]$ServerAdminUsername,
    [string]$ServerAdminPassword,
    [string]$ReconciliationToken
)

Write-Host "Preparing replica DC promotion for: $DomainName"

# ============================================================================
# PHASE 1: INITIALIZE SECURE CREDENTIALS
# ============================================================================

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

# ============================================================================
# PHASE 2: IDEMPOTENCY CHECK - VERIFY NOT ALREADY A DC
# ============================================================================

try {
    $CurrentDomain = Get-ADDomain -ErrorAction Stop

    Write-Host "Server is already a Domain Controller in $($CurrentDomain.Forest)"
    exit 0
}
catch {
    Write-Host "Server is not yet a Domain Controller"
}

# ============================================================================
# PHASE 3: ENSURE AD DS ROLE IS INSTALLED
# ============================================================================

if ((Get-WindowsFeature AD-Domain-Services).Installed) {
    Write-Host "AD DS role already installed"
}
else {
    Install-WindowsFeature `
        AD-Domain-Services `
        -IncludeManagementTools

    Write-Host "AD DS role installation complete"
}

# ============================================================================
# PHASE 4: PROMOTE SERVER AS REPLICA DOMAIN CONTROLLER
# Promotion triggers automatic reboot; Azure VM Run Command handles reconnection.
# ============================================================================

Write-Host "Promoting server as replica Domain Controller in $DomainName"

Install-ADDSDomainController `
    -DomainName $DomainName `
    -Credential $DomainCredential `
    -InstallDns `
    -SafeModeAdministratorPassword $SecurePassword `
    -Force

Write-Host "Replica DC promotion initiated. The server will automatically reboot."