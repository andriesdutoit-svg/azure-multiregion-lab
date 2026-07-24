
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
Write-Host "DomainName = $DomainName"

if ([string]::IsNullOrWhiteSpace($ServerAdminPassword)) {
    throw "ServerAdminPassword was not supplied"
}

$DsrmPassword = ConvertTo-SecureString `
    $ServerAdminPassword `
    -AsPlainText `
    -Force

if ((Get-WindowsFeature AD-Domain-Services).Installed) {
    Write-Host "AD DS role already installed"
}
else {
    Install-WindowsFeature `
        AD-Domain-Services `
        -IncludeManagementTools

    Write-Host "AD DS role installation complete"
}

Import-Module ActiveDirectory -ErrorAction SilentlyContinue

Write-Host "Preparing Active Directory installation for: $DomainName"

# ============================================================================
# IDEMPOTENCY CHECK: VERIFY FOREST DOES NOT ALREADY EXIST
# ============================================================================

try {
    $CurrentDomain = Get-ADDomain -ErrorAction Stop

    Write-Host "Domain already exists: $($CurrentDomain.Forest)"
    exit 0
}
catch {
    Write-Host $_
    Write-Host "No Active Directory forest detected"
}

# ============================================================================
# CREATE ACTIVE DIRECTORY FOREST
# Forest creation triggers automatic VM reboot.
# Azure VM Run Command handles reconnection and completion detection.
# ============================================================================

Write-Host "Creating Active Directory forest: $DomainName"

Install-ADDSForest `
    -DomainName $DomainName `
    -InstallDns `
    -SafeModeAdministratorPassword $DsrmPassword `
    -Force

Write-Host "Active Directory forest creation initiated. The server will automatically reboot to complete installation."
