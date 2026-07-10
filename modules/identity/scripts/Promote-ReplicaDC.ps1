<#
This script contains logic derived from and inspired by:

Set-DummyAD
https://github.com/BOAScripts/Set-DummyAD

Copyright (c) BOAScripts
Licensed under the MIT License.

Adapted and integrated for this project.
Replica DC promotion logic.
#>

param(
    [string]$DomainName,
    [string]$ServerAdminPassword
)

Write-Host "Preparing replica DC promotion for: $DomainName"

$SecurePassword = ConvertTo-SecureString `
    $ServerAdminPassword `
    -AsPlainText `
    -Force

$NetBiosName = $DomainName.Split('.')[0].ToUpper()

$DomainCredential = New-Object System.Management.Automation.PSCredential(
    "$NetBiosName\Administrator",
    $SecurePassword
)

Write-Host "Domain credential prepared for $NetBiosName\Administrator"

Import-Module ActiveDirectory -ErrorAction SilentlyContinue

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