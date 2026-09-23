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

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<Groups clsid="{3125E937-EB16-4b4c-9934-544FC6D24D26}">
  <Group clsid="{6D4A79E4-529C-4481-ABD0-F5BD7EA93BA7}"
         name="Administrators (built-in)"
         image="2"
         uid="{$guid}">
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

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<Groups clsid="{3125E937-EB16-4b4c-9934-544FC6D24D26}">
  <Group clsid="{6D4A79E4-529C-4481-ABD0-F5BD7EA93BA7}"
         name="Administrators (built-in)"
         image="2"
         uid="{$guid}">
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

Ensure-Gpo `
    -Name $model.gpoNames.serverAdministration `
    -Description 'Administrative policy for AMRL member servers'

Ensure-Gpo `
    -Name $model.gpoNames.clientAdministration `
    -Description 'Administrative policy for AMRL client workstations'

Ensure-GpoLink -GpoName $model.gpoNames.serverAdministration -TargetDn $serversOuDn
Ensure-GpoLink -GpoName $model.gpoNames.clientAdministration -TargetDn $clientsOuDn

Ensure-ClientAdministrationPolicies `
    -Model $model

Ensure-ServerAdministrationPolicies `
    -Model $model

Ensure-ServerAdministrationMembership `
    -Model $model `
    -DomainName $DomainName

Ensure-ClientAdministrationMembership `
    -Model $model `
    -DomainName $DomainName

Write-Host "AMRL GPO Configuration Completed"