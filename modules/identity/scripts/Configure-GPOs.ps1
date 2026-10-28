<#
.SYNOPSIS
Creates or reconciles the four AMRL GPOs without importing policy backups.
.DESCRIPTION
Runs on the primary DC after directory population has created the target OUs and
Windows administrators group. Existing GPOs keep their identities; the helpers
reapply AMRL-owned settings rather than skipping all work when a GPO exists.

WAC needs several independent prerequisites: domain/SPN identity for Kerberos,
a WinRM service/listener on the target, and effective Windows Firewall policy.
This script owns the GPO definitions for the latter settings, plus local-admin
membership and LAPS policy. It does not configure WAC's browser HTTPS endpoint.
.NOTES
Writing/linking policy does not prove client processing. Windows applies computer
policy normally; deployment does not force a refresh or gate on guest application.
Validate functional management readiness separately after provisioning.
Unmodeled settings are retained; this is not a whole-GPO reset or domain teardown.
#>

param(
    [string]$DomainName,
    [string]$DirectoryModel,
    [string]$ReconciliationToken
)

$ErrorActionPreference = 'Stop'

Import-Module ActiveDirectory -ErrorAction Stop
Import-Module GroupPolicy -ErrorAction Stop
Import-Module NetSecurity -ErrorAction Stop

$model = $DirectoryModel | ConvertFrom-Json
$domain = Get-ADDomain -ErrorAction Stop
$domainDn = $domain.DistinguishedName
$netbiosDomainName = $domain.NetBIOSName

if ($domain.DNSRoot -ine $DomainName.TrimEnd('.')) {
    throw "The current domain '$($domain.DNSRoot)' does not match requested domain '$DomainName'."
}

if (-not $model.gpoNames -or
    [string]::IsNullOrWhiteSpace($model.gpoNames.serverAdministration) -or
    [string]::IsNullOrWhiteSpace($model.gpoNames.clientAdministration) -or
    [string]::IsNullOrWhiteSpace($model.gpoNames.windowsLaps) -or
    [string]::IsNullOrWhiteSpace($model.gpoNames.domainControllerWinRM)) {
    throw 'directoryModel.gpoNames must define serverAdministration, clientAdministration, windowsLaps, and domainControllerWinRM.'
}

if ([string]::IsNullOrWhiteSpace($model.rootOuName) -or
    [string]::IsNullOrWhiteSpace($model.groupNaming.globalSecurityPrefix) -or
    [string]::IsNullOrWhiteSpace($model.platformAdminGroups.windowsAdmins)) {
    throw 'DirectoryModel must define rootOuName and the Windows administrators group naming fields.'
}

$serversOuDn = "OU=Servers,OU=Computers,OU=$($model.rootOuName),$domainDn"
$clientsOuDn = "OU=Clients,OU=Computers,OU=$($model.rootOuName),$domainDn"
$domainControllersOuDn = "OU=Domain Controllers,$domainDn"
$serverAdministrationGpoName = $model.gpoNames.serverAdministration
$clientAdministrationGpoName = $model.gpoNames.clientAdministration
$windowsLapsGpoName = $model.gpoNames.windowsLaps
$domainControllerWinRmGpoName = $model.gpoNames.domainControllerWinRM
$windowsAdminsGroupName = "$($model.groupNaming.globalSecurityPrefix)_$($model.platformAdminGroups.windowsAdmins)"
$windowsAdminsGroup = Get-ADGroup -Identity $windowsAdminsGroupName -Properties SID -ErrorAction Stop

$script:logCounts = @{
    Created = 0
    Verified = 0
    Updated = 0
    Removed = 0
    Skipped = 0
    Warning = 0
    Error = 0
}

function Write-AmrlLog {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [string]$Status = 'Info'
    )

    if ($Message -match '^\[(Created|Verified|Updated|Removed|Skipped|Warning|Error|Info)\]\s*(.*)$') {
        $Status = $Matches[1]
        $Message = $Matches[2]
    }

    if ($script:logCounts.ContainsKey($Status)) {
        $script:logCounts[$Status]++
    }

    Microsoft.PowerShell.Utility\Write-Host "[$Status] $Message"
}

function Ensure-GpoExists {
    param([Parameter(Mandatory)][string]$GpoName)

    $gpo = Get-GPO -Name $GpoName -Domain $DomainName -ErrorAction SilentlyContinue
    if ($null -eq $gpo) {
        $gpo = New-GPO -Name $GpoName -Domain $DomainName -ErrorAction Stop
        Write-AmrlLog "[Created] GPO '$GpoName'."
    }
    else {
        Write-AmrlLog "[Verified] GPO '$GpoName' exists."
    }

    return $gpo
}

function Ensure-GpoLink {
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory)][string]$TargetDn
    )

    try {
        $inheritance = Get-GPInheritance -Target $TargetDn -ErrorAction Stop
    }
    catch {
        throw "Cannot link '$GpoName'. Target OU '$TargetDn' was not found: $($_.Exception.Message)"
    }

    $existingLink = @($inheritance.GpoLinks | Where-Object DisplayName -eq $GpoName)
    if ($existingLink.Count -eq 0) {
        New-GPLink -Name $GpoName -Target $TargetDn -LinkEnabled Yes -ErrorAction Stop | Out-Null
        Write-AmrlLog "[Created] Link '$GpoName' to '$TargetDn'."
    }
    elseif (-not $existingLink[0].Enabled) {
        Set-GPLink -Name $GpoName -Target $TargetDn -LinkEnabled Yes -ErrorAction Stop
        Write-AmrlLog "[Updated] Enabled link '$GpoName' on '$TargetDn'."
    }
    elseif ($existingLink[0].Enforced) {
        Set-GPLink -Name $GpoName -Target $TargetDn -Enforced No -ErrorAction Stop
        Write-AmrlLog "[Updated] Removed enforcement from '$GpoName' on '$TargetDn'."
    }
    else {
        Write-AmrlLog "[Verified] Link '$GpoName' is enabled on '$TargetDn'."
    }
}

# Policy files written directly to SYSVOL also need their client-side extension
# registered in AD; the GUID pairs identify the Windows policy processors to invoke.
function Ensure-GpoMachineExtensionPair {
    param(
        [Parameter(Mandatory)][Microsoft.GroupPolicy.Gpo]$Gpo,
        [Parameter(Mandatory)][guid]$ClientExtensionId,
        [Parameter(Mandatory)][guid]$ToolExtensionId
    )

    $gpoGuid = ([guid]$Gpo.Id).ToString('B')
    $gpoDn = "CN=$gpoGuid,CN=Policies,CN=System,$domainDn"
    $gpoObject = Get-ADObject -Identity $gpoDn -Properties gPCMachineExtensionNames -ErrorAction Stop
    $pair = "[$($ClientExtensionId.ToString('B'))$($ToolExtensionId.ToString('B'))]"
    $currentPairs = [string]$gpoObject.gPCMachineExtensionNames

    if (-not $currentPairs.Contains($pair)) {
        Set-ADObject `
            -Identity $gpoObject.DistinguishedName `
            -Replace @{ gPCMachineExtensionNames = "$currentPairs$pair" } `
            -ErrorAction Stop
        Write-AmrlLog "[Updated] Registered policy extension for '$($Gpo.DisplayName)'."
    }
}

function Set-GpoRegistryValue {
    param(
        [Parameter(Mandatory)][Microsoft.GroupPolicy.Gpo]$Gpo,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$ValueName,
        [Parameter(Mandatory)][ValidateSet('DWord', 'String')][string]$Type,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $typedValue = if ($Type -eq 'DWord') { [int]$Value } else { $Value }
    Set-GPRegistryValue `
        -Guid $Gpo.Id `
        -Key $Key `
        -ValueName $ValueName `
        -Type $Type `
        -Value $typedValue `
        -ErrorAction Stop |
        Out-Null

    Write-AmrlLog "[Updated] $($Gpo.DisplayName): $Key\$ValueName."
}

# System Services policy is stored in the security template, not an ordinary registry value.
# The native WinRM service entry uses startup mode 2 (Automatic); retain other service entries.
function Ensure-WinRmServiceStartup {
    param([Parameter(Mandatory)][Microsoft.GroupPolicy.Gpo]$Gpo)

    $gpoGuid = ([guid]$Gpo.Id).ToString('B')
    $securityDirectory = "\\$DomainName\SYSVOL\$DomainName\Policies\$gpoGuid\Machine\microsoft\windows nt\SecEdit"
    $templatePath = Join-Path $securityDirectory 'GptTmpl.inf'
    if (-not (Test-Path -LiteralPath $securityDirectory)) {
        New-Item -Path $securityDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    if (Test-Path -LiteralPath $templatePath) {
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in (Get-Content -LiteralPath $templatePath -Encoding Unicode -ErrorAction Stop)) {
            $lines.Add([string]$line)
        }
    }
    else {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('[Unicode]')
        $lines.Add('Unicode=yes')
        $lines.Add('[Version]')
        $lines.Add('signature="$CHICAGO$"')
        $lines.Add('Revision=1')
    }

    $sectionIndex = $lines.IndexOf('[Service General Setting]')
    if ($sectionIndex -lt 0) {
        $lines.Add('[Service General Setting]')
        $lines.Add('"WinRM",2,""')
    }
    else {
        $serviceIndex = -1
        $sectionEnd = $lines.Count
        for ($index = $sectionIndex + 1; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^\s*\[') {
                $sectionEnd = $index
                break
            }
            if ($lines[$index] -match '^\s*"WinRM"\s*,') {
                $serviceIndex = $index
            }
        }

        if ($serviceIndex -ge 0) {
            $lines[$serviceIndex] = '"WinRM",2,""'
        }
        else {
            $lines.Insert($sectionEnd, '"WinRM",2,""')
        }
    }

    Set-Content -LiteralPath $templatePath -Value ($lines -join "`r`n") -Encoding Unicode -ErrorAction Stop
    Ensure-GpoMachineExtensionPair `
        -Gpo $Gpo `
        -ClientExtensionId '827D319E-6EAC-11D2-A4EA-00C04F79F83A' `
        -ToolExtensionId '803E14A0-B4FB-11D0-A0D0-00A0C90F574B'
    Write-AmrlLog "[Updated] $($Gpo.DisplayName): WinRM service startup is Automatic."
}

# An Update preference adds the modeled admin group without replacing Administrators membership.
# SIDs select the built-in group independently of localization and resolve the current domain group.
function Ensure-GpoLocalAdminPreference {
    param([Parameter(Mandatory)][Microsoft.GroupPolicy.Gpo]$Gpo)

    $gpoGuid = ([guid]$Gpo.Id).ToString('B')
    $groupsDirectory = "\\$DomainName\SYSVOL\$DomainName\Policies\$gpoGuid\Machine\Preferences\Groups"
    $groupsXmlPath = Join-Path $groupsDirectory 'Groups.xml'
    if (-not (Test-Path -LiteralPath $groupsDirectory)) {
        New-Item -Path $groupsDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    if (Test-Path -LiteralPath $groupsXmlPath) {
        [xml]$xml = Get-Content -LiteralPath $groupsXmlPath -Raw -ErrorAction Stop
        $root = $xml.DocumentElement
        if ($root.LocalName -ne 'Groups') {
            throw "Unexpected Local Users and Groups preference document at '$groupsXmlPath'."
        }
    }
    else {
        $xml = New-Object System.Xml.XmlDocument
        $xml.AppendChild($xml.CreateXmlDeclaration('1.0', 'utf-8', $null)) | Out-Null
        $root = $xml.CreateElement('Groups')
        $root.SetAttribute('clsid', '{3125E937-EB16-4b4c-9934-544FC6D24D26}')
        $xml.AppendChild($root) | Out-Null
    }

    $groupSid = 'S-1-5-32-544'
    $adminGroupName = [string]$windowsAdminsGroup.SamAccountName
    $adminGroupSid = [string]$windowsAdminsGroup.SID.Value
    $qualifiedName = "$netbiosDomainName\$adminGroupName"
    # GPP stores the target SID on Properties, not Group; reuse that entry on reruns.
    $groupNode = $root.SelectSingleNode("Group[Properties/@groupSid='$groupSid']")
    $changed = $false

    if ($null -eq $groupNode) {
        $groupNode = $xml.CreateElement('Group')
        $groupNode.SetAttribute('clsid', '{6D4A79E4-529C-4481-ABD0-F5BD7EA93BA7}')
        $groupNode.SetAttribute('name', 'Administrators (built-in)')
        $groupNode.SetAttribute('image', '2')
        $groupNode.SetAttribute('changed', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        $groupNode.SetAttribute('uid', "{$([guid]::NewGuid().ToString().ToUpperInvariant())}")
        $root.AppendChild($groupNode) | Out-Null
        $changed = $true
    }

    $settingOrder = $groupNode.SelectSingleNode('GPOSettingOrder')
    if ($null -eq $settingOrder) {
        $existingOrders = @($root.SelectNodes('Group/GPOSettingOrder') | ForEach-Object { [int]$_.InnerText })
        $nextOrder = 1
        if ($existingOrders.Count -gt 0) {
            $nextOrder = ([int]($existingOrders | Measure-Object -Maximum).Maximum) + 1
        }

        $settingOrder = $xml.CreateElement('GPOSettingOrder')
        $settingOrder.InnerText = [string]$nextOrder
        $groupNode.PrependChild($settingOrder) | Out-Null
        $changed = $true
    }

    $properties = $groupNode.SelectSingleNode('Properties')
    if ($null -eq $properties) {
        $properties = $xml.CreateElement('Properties')
        $groupNode.AppendChild($properties) | Out-Null
        $changed = $true
    }

    foreach ($attribute in @{
            action = 'U'; newName = ''; description = ''; deleteAllUsers = '0'
            deleteAllGroups = '0'; removeAccounts = '0'; groupSid = $groupSid
            groupName = 'Administrators (built-in)'
        }.GetEnumerator()) {
        if ($properties.GetAttribute($attribute.Key) -cne [string]$attribute.Value) {
            $properties.SetAttribute($attribute.Key, [string]$attribute.Value)
            $changed = $true
        }
    }

    $filters = $groupNode.SelectSingleNode('Filters')
    if ($null -eq $filters) {
        $filters = $xml.CreateElement('Filters')
        $groupNode.AppendChild($filters) | Out-Null
        $changed = $true
    }

    $members = $properties.SelectSingleNode('Members')
    if ($null -eq $members) {
        $members = $xml.CreateElement('Members')
        $properties.AppendChild($members) | Out-Null
        $changed = $true
    }

    $matchingMembers = @($members.SelectNodes('Member') | Where-Object {
        $memberName = [string]$_.GetAttribute('name')
        $memberShortName = ($memberName -split '\\')[-1]
        $memberShortName -ieq $adminGroupName
    })
    $memberNode = $matchingMembers | Select-Object -First 1
    foreach ($duplicate in @($matchingMembers | Select-Object -Skip 1)) {
        $members.RemoveChild($duplicate) | Out-Null
        $changed = $true
    }

    if ($null -eq $memberNode) {
        $memberNode = $xml.CreateElement('Member')
        $memberNode.SetAttribute('action', 'ADD')
        $members.AppendChild($memberNode) | Out-Null
        $changed = $true
    }
    if ($memberNode.GetAttribute('name') -cne $qualifiedName -or
        $memberNode.GetAttribute('sid') -cne $adminGroupSid -or
        $memberNode.GetAttribute('action') -cne 'ADD') {
        $memberNode.SetAttribute('name', $qualifiedName)
        $memberNode.SetAttribute('sid', $adminGroupSid)
        $memberNode.SetAttribute('action', 'ADD')
        $changed = $true
    }

    if ($changed) {
        $groupNode.SetAttribute('changed', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        $xml.Save($groupsXmlPath)
        Write-AmrlLog "[Updated] $($Gpo.DisplayName): added $qualifiedName to built-in Administrators without removing other members."
    }
    else {
        Write-AmrlLog "[Verified] $($Gpo.DisplayName): $qualifiedName is an add-only Administrators member."
    }

    Ensure-GpoMachineExtensionPair `
        -Gpo $Gpo `
        -ClientExtensionId '17D89FEC-5C44-4972-B12D-241CAEF74509' `
        -ToolExtensionId '79F92669-4224-476C-9C5C-6EFB4D87DF4A'
}

# Edit the domain GPO store here, not this DC's local firewall. Windows applies it to guests
# through normal policy processing. Profile Any handles Public/Private detection at startup;
# the internal source range remains a separate restriction and is not changed to Any.
function Ensure-GpoWinRMFirewallRule {
    param(
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][string[]]$LocalPorts
    )

    $policyStore = "$DomainName\$GpoName"
    $rules = @(
        Get-NetFirewallRule -PolicyStore $policyStore -DisplayName $DisplayName -ErrorAction SilentlyContinue
    )
    if ($rules.Count -gt 1) {
        throw "GPO '$GpoName' contains multiple firewall rules named '$DisplayName'."
    }

    if ($rules.Count -eq 0) {
        New-NetFirewallRule `
            -PolicyStore $policyStore `
            -Name $RuleName `
            -DisplayName $DisplayName `
            -Description 'Allows AMRL internal IPv4 networks to manage Windows computers over WinRM HTTP.' `
            -Enabled True `
            -Profile Any `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $LocalPorts `
            -RemoteAddress '10.0.0.0/8' `
            -ErrorAction Stop |
            Out-Null
    }
    else {
        Set-NetFirewallRule `
            -PolicyStore $policyStore `
            -Name $rules[0].Name `
            -Enabled True `
            -Profile Any `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $LocalPorts `
            -RemoteAddress '10.0.0.0/8' `
            -ErrorAction Stop |
            Out-Null
    }

    # Read back the stored domain GPO rule to catch a failed configuration write.
    # This is not a target VM's ActiveStore check and does not wait for policy application.
    $verifiedRule = @(Get-NetFirewallRule -PolicyStore $policyStore -DisplayName $DisplayName -ErrorAction Stop)
    if ($verifiedRule.Count -ne 1 -or
        -not $verifiedRule[0].Enabled -or
        [string]$verifiedRule[0].Profile -ne 'Any' -or
        $verifiedRule[0].Direction -ne 'Inbound' -or
        $verifiedRule[0].Action -ne 'Allow') {
        throw "GPO '$GpoName' did not retain the required all-profile inbound rule '$DisplayName'."
    }

    $portFilter = $verifiedRule[0] | Get-NetFirewallPortFilter
    $addressFilter = $verifiedRule[0] | Get-NetFirewallAddressFilter
    $configuredPorts = @($portFilter.LocalPort | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() })
    $configuredAddresses = @($addressFilter.RemoteAddress | ForEach-Object { [string]$_ })
    if ([string]$portFilter.Protocol -notin @('TCP', '6') -or
        @($LocalPorts | Where-Object { $_ -notin $configuredPorts }).Count -gt 0 -or
        @($configuredAddresses | Where-Object { $_ -in @('10.0.0.0/8', '10.0.0.0/255.0.0.0') }).Count -eq 0) {
        throw "GPO '$GpoName' firewall rule '$DisplayName' does not match the required TCP ports and internal source range."
    }

    Write-AmrlLog "[Updated] ${GpoName}: $DisplayName applies on all profiles."
}

# 1. Preserve existing policy identities, then reapply the settings owned by this script.
$serverAdministrationGpo = Ensure-GpoExists -GpoName $serverAdministrationGpoName
$clientAdministrationGpo = Ensure-GpoExists -GpoName $clientAdministrationGpoName
$windowsLapsGpo = Ensure-GpoExists -GpoName $windowsLapsGpoName
$domainControllerWinRmGpo = Ensure-GpoExists -GpoName $domainControllerWinRmGpoName

# 2. Members need both service startup and listener policy; a firewall allowance alone
# cannot provide a WSMan endpoint. IPv6 listening also covers WAC reaching its own host
# by FQDN when Windows resolves that name to a local IPv6 address. Listener filters select
# local listening addresses, not permitted remote clients; firewall scope is configured below.
$winRmRegistryKey = 'HKLM\Software\Policies\Microsoft\Windows\WinRM\Service'
foreach ($gpo in @($serverAdministrationGpo, $clientAdministrationGpo)) {
    Ensure-WinRmServiceStartup -Gpo $gpo
    Set-GpoRegistryValue -Gpo $gpo -Key $winRmRegistryKey -ValueName 'AllowAutoConfig' -Type DWord -Value '1'
    Set-GpoRegistryValue -Gpo $gpo -Key $winRmRegistryKey -ValueName 'IPv4Filter' -Type String -Value '*'
    Set-GpoRegistryValue -Gpo $gpo -Key $winRmRegistryKey -ValueName 'IPv6Filter' -Type String -Value '*'
    Ensure-GpoLocalAdminPreference -Gpo $gpo
}

# 3. WAC currently uses HTTP/5985 to manage targets. Allowing 5986 here does not provision
# an HTTPS listener or certificate. The gateway's browser-facing HTTPS/443 is separate.
Ensure-GpoWinRMFirewallRule `
    -GpoName $serverAdministrationGpoName `
    -DisplayName 'Allow WinRM HTTP/HTTPS' `
    -RuleName 'AMRL-Server-WinRM-HTTP-HTTPS' `
    -LocalPorts @('5985', '5986')

Ensure-GpoWinRMFirewallRule `
    -GpoName $clientAdministrationGpoName `
    -DisplayName 'Allow WinRM HTTP/HTTPS' `
    -RuleName 'AMRL-Client-WinRM-HTTP-HTTPS' `
    -LocalPorts @('5985', '5986')

# 4. LAPS policy backs passwords up to AD; directory population owns schema/OU permissions.
# The decryptor setting matters when password encryption is enabled; it does not enable it.
$lapsPolicyKey = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'
Set-GpoRegistryValue -Gpo $windowsLapsGpo -Key $lapsPolicyKey -ValueName 'BackupDirectory' -Type DWord -Value '2'
Set-GpoRegistryValue -Gpo $windowsLapsGpo -Key $lapsPolicyKey -ValueName 'PasswordComplexity' -Type DWord -Value '4'
Set-GpoRegistryValue -Gpo $windowsLapsGpo -Key $lapsPolicyKey -ValueName 'PasswordLength' -Type DWord -Value '16'
Set-GpoRegistryValue -Gpo $windowsLapsGpo -Key $lapsPolicyKey -ValueName 'PasswordAgeDays' -Type DWord -Value '30'
Set-GpoRegistryValue `
    -Gpo $windowsLapsGpo `
    -Key $lapsPolicyKey `
    -ValueName 'ADPasswordEncryptionPrincipal' `
    -Type String `
    -Value "$netbiosDomainName\$($windowsAdminsGroup.SamAccountName)"

# 5. DCs get a narrow, separate rule, not the workload local-Administrators preference.
# This policy manages their firewall only; it does not create DC WinRM service/listener policy.
Ensure-GpoWinRMFirewallRule `
    -GpoName $domainControllerWinRmGpoName `
    -DisplayName 'AMRL DC WinRM HTTP from internal networks' `
    -RuleName 'AMRL-DC-WinRM-HTTP-Internal' `
    -LocalPorts @('5985')

# 6. Link policies only to their intended computer OUs; endpoint processing is a later step.
Ensure-GpoLink -GpoName $serverAdministrationGpoName -TargetDn $serversOuDn
Ensure-GpoLink -GpoName $clientAdministrationGpoName -TargetDn $clientsOuDn
Ensure-GpoLink -GpoName $windowsLapsGpoName -TargetDn $serversOuDn
Ensure-GpoLink -GpoName $windowsLapsGpoName -TargetDn $clientsOuDn
Ensure-GpoLink -GpoName $domainControllerWinRmGpoName -TargetDn $domainControllersOuDn

Write-AmrlLog (
    "[Info] GPO configuration summary: Created=$($script:logCounts.Created); Verified=$($script:logCounts.Verified); Updated=$($script:logCounts.Updated); Removed=$($script:logCounts.Removed); Skipped=$($script:logCounts.Skipped); Warnings=$($script:logCounts.Warning); Errors=$($script:logCounts.Error)."
)