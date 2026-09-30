# NOTE:
# The direct Group Policy Preferences generation approach has been
# superseded by the GPO Template Framework.
#
# Investigation retained temporarily until template import
# implementation is complete and validated.

param(
    [string]$DomainName,
    [string]$DirectoryModel,
    [string]$ReconciliationToken
)

Write-Host "AMRL GPO Configuration"

$model = $DirectoryModel | ConvertFrom-Json

$domainDn = (($DomainName -split '\.') | ForEach-Object {
    "DC=$_"
}) -join ','

$serversOuDn =
    "OU=Servers,OU=Computers,OU=$($model.rootOuName),$domainDn"

$clientsOuDn =
    "OU=Clients,OU=Computers,OU=$($model.rootOuName),$domainDn"


try {
    Import-Module GroupPolicy -ErrorAction Stop

    Write-Host "GroupPolicy module loaded successfully"
}
catch {
    throw "Unable to load GroupPolicy module. $_"
}

try {
    Import-Module ActiveDirectory -ErrorAction Stop

    Write-Host "ActiveDirectory module loaded successfully"
}
catch {
    throw "Unable to load ActiveDirectory module. $_"
}

function Register-LugsExtension {
    param(
        [string]$GpoName
    )

    $gpo = Get-GPO $GpoName

    $currentValue = (
        Get-ADObject `
            -Identity $gpo.Path `
            -Properties gPCMachineExtensionNames
    ).gPCMachineExtensionNames

    $lugsExtension =
        '[{00000000-0000-0000-0000-000000000000}{79F92669-4224-476C-9C5C-6EFB4D87DF4A}]' +
        '[{17D89FEC-5C44-4972-B12D-241CAEF74509}{79F92669-4224-476C-9C5C-6EFB4D87DF4A}]'

    if ($currentValue -notmatch '79F92669-4224-476C-9C5C-6EFB4D87DF4A') {

        Set-ADObject `
            -Identity $gpo.Path `
            -Replace @{
                gPCMachineExtensionNames =
                    ($currentValue + $lugsExtension)
            }
    }
}

function Ensure-Gpo {
    param(
        [string]$Name,
        [string]$Description
    )

    $existing = Get-GPO `
        -Name $Name `
        -ErrorAction SilentlyContinue

    if ($null -eq $existing) {
        Write-Host "[Create] GPO $Name"

        New-GPO `
            -Name $Name `
            -Comment $Description `
            -ErrorAction Stop |
            Out-Null
    }
    else {
        Write-Host "[Exists] GPO $Name"
    }
}

function Ensure-GpoLink {
    param(
        [string]$GpoName,
        [string]$TargetDn
    )

    $inheritance = Get-GPInheritance `
        -Target $TargetDn `
        -ErrorAction Stop

    $existingLink = $inheritance.GpoLinks |
        Where-Object DisplayName -eq $GpoName

    if ($null -eq $existingLink) {
        Write-Host "[Link] $GpoName -> $TargetDn"

        New-GPLink `
            -Name $GpoName `
            -Target $TargetDn `
            -LinkEnabled Yes `
            -ErrorAction Stop |
            Out-Null
    }
    else {
        Write-Host "[Exists] Link $GpoName -> $TargetDn"
    }
}

function Ensure-ServerAdministrationPolicies {
    param(
        [psobject]$Model
    )

    Write-Host "[Update] Server Administration policies"

    Set-GPPrefRegistryValue `
        -Name $Model.gpoNames.serverAdministration `
        -Context Computer `
        -Action Update `
        -Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' `
        -ValueName 'EnableScriptBlockLogging' `
        -Type DWord `
        -Value 1
}

function Get-GpoPolicyPath {
    param(
        [string]$GpoName
    )

    $gpo = Get-GPO `
        -Name $GpoName `
        -ErrorAction Stop

    return @{
        Gpo = $gpo
        PolicyPath = "\\$DomainName\SYSVOL\$DomainName\Policies\{$($gpo.Id)}"
    }
}

function Ensure-Folder {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        New-Item `
            -ItemType Directory `
            -Path $Path `
            -Force |
            Out-Null
    }
}

# Local administrator assignment is implemented
# through Group Policy Preferences (Local Users and Groups).
#
# XML is written directly to SYSVOL and a subsequent
# Update-GpoVersion() call is required to trigger
# DSVersion, SysvolVersion and GPT.INI updates.

function Ensure-ServerAdministrationMembership {
    param(
        [psobject]$Model,
        [string]$DomainName
    )

    $windowsAdminsGroup =
        "$($Model.groupNaming.globalSecurityPrefix)_$($Model.platformAdminGroups.windowsAdmins)"

    $netbiosName = $DomainName.Split('.')[0].ToUpper()

    $group = Get-ADGroup `
        -Identity $windowsAdminsGroup `
        -Properties SID `
        -ErrorAction Stop

    $gpoInfo = Get-GpoPolicyPath `
        -GpoName $Model.gpoNames.serverAdministration

    $groupsFolder =
        "$($gpoInfo.PolicyPath)\Machine\Preferences\Groups"

    Ensure-Folder `
        -Path $groupsFolder

    $groupsFile =
        "$groupsFolder\Groups.xml"

    $guid = [guid]::NewGuid().ToString().ToUpper()

    $changedTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<Groups clsid="{3125E937-EB16-4b4c-9934-544FC6D24D26}">
  <Group clsid="{6D4A79E4-529C-4481-ABD0-F5BD7EA93BA7}"
         name="Administrators (built-in)"
         image="2"
         uid="{$guid}"
         changed="$changedTimestamp">
    <Properties action="U"
                newName=""
                description=""
                deleteAllUsers="0"
                deleteAllGroups="0"
                removeAccounts="0"
                groupSid="S-1-5-32-544"
                groupName="Administrators (built-in)">
      <Members>
        <Member name="$netbiosName\$windowsAdminsGroup"
                action="ADD"
                sid="$($group.SID.Value)"/>
      </Members>
        </Properties>
    </Group>
</Groups>
"@

        Write-Host (
            "[Update] Writing $groupsFile"
        )

        Set-Content `
                -Path $groupsFile `
                -Value $xml `
                -Encoding UTF8

        Register-LugsExtension `
            -GpoName $Model.gpoNames.serverAdministration

        Write-Host (
            "[Success] $windowsAdminsGroup configured"
        )        
}

function Ensure-ClientAdministrationMembership {
    param(
        [psobject]$Model,
        [string]$DomainName
    )

    $windowsAdminsGroup =
        "$($Model.groupNaming.globalSecurityPrefix)_$($Model.platformAdminGroups.windowsAdmins)"

    $netbiosName = $DomainName.Split('.')[0].ToUpper()

    $group = Get-ADGroup `
        -Identity $windowsAdminsGroup `
        -Properties SID `
        -ErrorAction Stop

    $gpoInfo = Get-GpoPolicyPath `
        -GpoName $Model.gpoNames.clientAdministration

    $groupsFolder =
        "$($gpoInfo.PolicyPath)\Machine\Preferences\Groups"

    Ensure-Folder `
        -Path $groupsFolder

    $groupsFile =
        "$groupsFolder\Groups.xml"

    $guid = [guid]::NewGuid().ToString().ToUpper()

    $changedTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # Group Policy Preferences Local Users and Groups items
    # require a valid changed timestamp attribute.
    #
    # Without the changed attribute the preference may
    # appear correctly in GPMC but will not be applied
    # reliably to client computers.

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<Groups clsid="{3125E937-EB16-4b4c-9934-544FC6D24D26}">
  <Group clsid="{6D4A79E4-529C-4481-ABD0-F5BD7EA93BA7}"
         name="Administrators (built-in)"
         image="2"
         uid="{$guid}"
         changed="$changedTimestamp">
    <Properties action="U"
                newName=""
                description=""
                deleteAllUsers="0"
                deleteAllGroups="0"
                removeAccounts="0"
                groupSid="S-1-5-32-544"
                groupName="Administrators (built-in)">
      <Members>
        <Member name="$netbiosName\$windowsAdminsGroup"
                action="ADD"
                                sid="$($group.SID.Value)"/>
            </Members>
                </Properties>
        </Group>
</Groups>
"@

        Write-Host (
            "[Update] Writing $groupsFile"
        )

        Set-Content `
                -Path $groupsFile `
                -Value $xml `
                -Encoding UTF8

        Register-LugsExtension `
            -GpoName $Model.gpoNames.clientAdministration

        Write-Host (
            "[Success] $windowsAdminsGroup configured"
        ) 
}

function Ensure-ClientAdministrationPolicies {
    param(
        [psobject]$Model
    )

    Write-Host "[Update] Client Administration policies"

    Set-GPPrefRegistryValue `
        -Name $Model.gpoNames.clientAdministration `
        -Context Computer `
        -Action Update `
        -Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' `
        -ValueName 'EnableScriptBlockLogging' `
        -Type DWord `
        -Value 1
}

# Trigger supported GPO version increment.
# Required after writing Local Users and Groups
# preference XML directly into SYSVOL.
#
# Updates:
# - AD versionNumber
# - DSVersion
# - SysvolVersion
# - GPT.INI Version

function Update-GpoVersion {
    param(
        [string]$GpoName
    )

    Write-Host "[Update] Incrementing version for $GpoName"

    # Trigger supported GPO version increment.
    # Required after writing Local Users and Groups
    # preference XML directly into SYSVOL.
    #
    # Set-GPPrefRegistryValue updates:
    # - AD versionNumber
    # - DSVersion
    # - SysvolVersion
    # - GPT.INI Version
    #
    # Without this step, Group Policy clients do not
    # detect changes to the generated Groups.xml file.

    Set-GPPrefRegistryValue `
        -Name $GpoName `
        -Context Computer `
        -Action Update `
        -Key 'HKLM\SOFTWARE\AMRL\GpoVersion' `
        -ValueName 'VersionRefresh' `
        -Type String `
        -Value (Get-Date -Format 'yyyyMMddHHmmss')
}

function Show-GpoVersion {
    param(
        [string]$Name
    )

    $gpo = Get-GPO $Name

    Write-Host ""
    Write-Host "GPO: $Name"
    Write-Host "DSVersion     = $($gpo.Computer.DSVersion)"
    Write-Host "SysvolVersion = $($gpo.Computer.SysvolVersion)"
}

Ensure-Gpo `
    -Name $model.gpoNames.serverAdministration `
    -Description 'Administrative policy for AMRL member servers'

Show-GpoVersion `
    -Name $model.gpoNames.serverAdministration

Ensure-Gpo `
    -Name $model.gpoNames.clientAdministration `
    -Description 'Administrative policy for AMRL client workstations'

Ensure-GpoLink -GpoName $model.gpoNames.serverAdministration -TargetDn $serversOuDn
Ensure-GpoLink -GpoName $model.gpoNames.clientAdministration -TargetDn $clientsOuDn

Ensure-ClientAdministrationPolicies `
    -Model $model

Ensure-ServerAdministrationPolicies `
    -Model $model

Show-GpoVersion `
    -Name $model.gpoNames.serverAdministration

Ensure-ServerAdministrationMembership `
    -Model $model `
    -DomainName $DomainName

Show-GpoVersion `
    -Name $model.gpoNames.serverAdministration

Update-GpoVersion `
    -GpoName $model.gpoNames.serverAdministration

Show-GpoVersion `
    -Name $model.gpoNames.serverAdministration

Update-GpoVersion `
    -GpoName $model.gpoNames.serverAdministration

Show-GpoVersion `
    -Name $model.gpoNames.serverAdministration

Ensure-ClientAdministrationMembership `
    -Model $model `
    -DomainName $DomainName

Update-GpoVersion `
    -GpoName $model.gpoNames.clientAdministration

Update-GpoVersion `
    -GpoName $model.gpoNames.clientAdministration

Write-Host "AMRL GPO Configuration Completed"