
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
    [string]$ServerAdminPassword
)

Write-Host "DomainName = $DomainName"

if (:IsNullOrWhiteSpace($ServerAdminPassword)) {
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

try {
    $CurrentDomain = Get-ADDomain -ErrorAction Stop

    Write-Host "Domain already exists: $($CurrentDomain.Forest)"
    exit 0
}
catch {
    Write-Host $_
    Write-Host "No Active Directory forest detected"
}

Write-Host "Creating Active Directory forest: $DomainName"

Install-ADDSForest `
    -DomainName $DomainName `
    -InstallDns `
    -SafeModeAdministratorPassword $DsrmPassword `
    -Force

Write-Host "Active Directory forest creation initiated. The server will automatically reboot to complete the installation."