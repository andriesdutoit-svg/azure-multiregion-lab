
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
    [SecureString]$ServerAdminPassword
)

Write-Host "Installing AD DS Forest: $DomainName"