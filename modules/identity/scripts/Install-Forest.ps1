
# Forest bootstrap overview
# Creates the requested AD forest on a provisioned Windows DC VM using the supplied
# password as the DSRM password. An existing Get-ADDomain result ends the script early.
# The identity stage orders this before replica promotion and directory population.
# Promotion initiates a reboot; command completion alone is not an AD-readiness probe.
# ReconciliationToken participates in the caller's rerun contract, not forced forest recreation.

<#
This script contains logic derived from and inspired by:

Set-DummyAD
https://github.com/BOAScripts/Set-DummyAD
Copyright (c) BOAScripts
Licensed under the MIT License.

Adapted and integrated for this project.
Forest creation logic separated from AD population logic.
#>

# 1. Inputs and secure DSRM password preparation
param(
    [string]$DomainName,
    [string]$ServerAdminPassword,
    [string]$ReconciliationToken
)

# Logs are surfaced by VM Run Command output.
Write-Host "[Info] Requested Active Directory domain: $DomainName."

if ([string]::IsNullOrWhiteSpace($ServerAdminPassword)) {
    throw "ServerAdminPassword was not supplied"
}

$DsrmPassword = ConvertTo-SecureString `
    $ServerAdminPassword `
    -AsPlainText `
    -Force

# 2. Ensure the AD DS role is available before querying forest state
if ((Get-WindowsFeature AD-Domain-Services).Installed) {
    Write-Host '[Verified] Active Directory Domain Services role is installed.'
}
else {
    Install-WindowsFeature `
        AD-Domain-Services `
        -IncludeManagementTools

    Write-Host '[Info] Active Directory Domain Services role installation command completed.'
}

Import-Module ActiveDirectory -ErrorAction SilentlyContinue

Write-Host "[Info] Checking for an existing Active Directory forest before creating $DomainName."

# ============================================================================
# PHASE 3: CHECK FOR A DISCOVERABLE EXISTING DOMAIN
# A successful query exits without creating a new forest; query failures fall through.
# ============================================================================

try {
    $CurrentDomain = Get-ADDomain -ErrorAction Stop

    Write-Host "[Info] Existing Active Directory forest detected: $($CurrentDomain.Forest). No new forest will be created."
    exit 0
}
catch {
    Write-Host '[Info] No existing Active Directory forest was detected.'
}

# ============================================================================
# CREATE ACTIVE DIRECTORY FOREST
# Forest creation triggers automatic VM reboot.
# Verify post-reboot DC services separately rather than relying on Run Command completion alone.
# ============================================================================

Write-Host "[Info] Starting Active Directory forest creation for $DomainName."

Install-ADDSForest `
    -DomainName $DomainName `
    -InstallDns `
    -SafeModeAdministratorPassword $DsrmPassword `
    -Force

Write-Host '[Info] Active Directory forest creation was initiated; the server will reboot to complete installation.'
