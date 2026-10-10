
<#
This script contains logic derived from and inspired by:

Set-DummyAD
https://github.com/BOAScripts/Set-DummyAD
Copyright (c) BOAScripts
Licensed under the MIT License.

Adapted and integrated for this project.
Forest creation logic separated from AD population logic.
#>

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
# IDEMPOTENCY CHECK: VERIFY FOREST DOES NOT ALREADY EXIST
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
# Azure VM Run Command handles reconnection and completion detection.
# ============================================================================

Write-Host "[Info] Starting Active Directory forest creation for $DomainName."

Install-ADDSForest `
    -DomainName $DomainName `
    -InstallDns `
    -SafeModeAdministratorPassword $DsrmPassword `
    -Force

Write-Host '[Info] Active Directory forest creation was initiated; the server will reboot to complete installation.'
