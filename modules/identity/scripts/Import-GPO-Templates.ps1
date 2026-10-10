# AMRL GPO provisioning from exported GPMC backups.
#
# Transport:   the backup set ships as a base64 zip parameter and is expanded
#              fresh on the DC each run (packaged by ad-gpo.bicep).
# Creation:    a GPO is imported only when it does not already exist.
# Reconcile:   the Windows admins reference inside Groups.xml is rewritten on
#              every run so the exported SID and NetBIOS name match this domain.
#
# Idempotency limitation: because import is skipped once the GPO exists,
# editing GpoTemplates.zip does NOT update an already-created GPO. Remove
# the GPO, or rename it via the directory model, to pick up template changes.

param(
    [string]$DomainName,
    [string]$DirectoryModel,
    [string]$GpoTemplatesZip,

    [string]$ReconciliationToken
)

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
    elseif ($Message -match '^\[(?<legacy>Link|Enable|Unenforce|Exists|Create|Import|Validate|Success|Reference Updated|Reference Verified|Reconciled|Cleanup|=)\]\s*(?<body>.*)$') {
        $legacy = $Matches.legacy
        $Message = $Matches.body
        switch -Exact ($legacy) {
            Link { $Status = 'Created' }
            Enable { $Status = 'Updated' }
            Unenforce { $Status = 'Updated' }
            Exists {
                if ($Message -match '^Link\b') { $Status = 'Verified' }
                else { $Status = 'Info' }
                break
            }
            Validate {
                if ($Message -match '^Imported GPO exists') { $Status = 'Verified' }
                else { $Status = 'Info' }
                break
            }
            Success {
                if ($Message -match '^Imported\b') { $Status = 'Created' }
                else { $Status = 'Info' }
                break
            }
            'Reference Updated' { $Status = 'Updated' }
            'Reference Verified' { $Status = 'Verified' }
            Reconciled { $Status = 'Updated' }
            Cleanup {
                if ($Message -match '^Removed\b') { $Status = 'Removed' }
                elseif ($Message -match 'already absent') { $Status = 'Verified' }
                else { $Status = 'Info' }
                break
            }
            '=' {
                if ($Message -match '^LAPS authorized decryptor is current') { $Status = 'Verified' }
                else { $Status = 'Info' }
                break
            }
            default { $Status = 'Info' }
        }
    }

    if ($script:logCounts.ContainsKey($Status)) {
        $script:logCounts[$Status]++
    }

    Microsoft.PowerShell.Utility\Write-Host "[$Status] $Message"
}

Write-AmrlLog '[Info] GPO template files were received.'
Write-AmrlLog '[Info] GPO template import and reconciliation started.'

Import-Module GroupPolicy -ErrorAction Stop

$templateRoot = 'C:\Temp\GpoTemplates'

$gpoTemplateRepositoryPath = $templateRoot

$zipPath =
    'C:\Temp\GpoTemplates.zip'

if ([string]::IsNullOrWhiteSpace($GpoTemplatesZip)) {
    throw "GpoTemplatesZip is empty. Confirm templates/gpo/GpoTemplates.zip exists and is committed."
}

# Run Command parameters are strings, so the zip crosses as base64.
try {
    [System.IO.File]::WriteAllBytes(
        $zipPath,
        [Convert]::FromBase64String($GpoTemplatesZip)
    )
}
catch {
    throw "GpoTemplatesZip is not valid base64 content: $($_.Exception.Message)"
}

# Discard the previous extraction so a changed zip cannot leave stale backups behind.
Remove-Item `
    $templateRoot `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue

Expand-Archive `
    -LiteralPath $zipPath `
    -DestinationPath 'C:\Temp\' `
    -Force `
    -ErrorAction Stop

# Expand-Archive writes into C:\Temp\GpoTemplates, so the zip must contain a GpoTemplates root folder.
if (-not (Test-Path -LiteralPath $templateRoot)) {
    throw "Expanded archive does not contain the expected 'C:\Temp\GpoTemplates' folder."
}

$model = $DirectoryModel | ConvertFrom-Json

if (-not $model.gpoNames -or
    [string]::IsNullOrWhiteSpace($model.gpoNames.serverAdministration) -or
    [string]::IsNullOrWhiteSpace($model.gpoNames.clientAdministration) -or
    [string]::IsNullOrWhiteSpace($model.gpoNames.windowsLaps)) {
    throw "directoryModel.gpoNames must define serverAdministration, clientAdministration, and windowsLaps."
}

$domainDn = (($DomainName -split '\.') | ForEach-Object {
    "DC=$_"
}) -join ','

$serversOuDn =
    "OU=Servers,OU=Computers,OU=$($model.rootOuName),$domainDn"

$clientsOuDn =
    "OU=Clients,OU=Computers,OU=$($model.rootOuName),$domainDn"

$serverAdministrationGpoName =
    $model.gpoNames.serverAdministration

$clientAdministrationGpoName =
    $model.gpoNames.clientAdministration

$windowsLapsGpoName =
    $model.gpoNames.windowsLaps

Write-AmrlLog "Template Root = $templateRoot"

function Ensure-GpoLink {
    param(
        [string]$GpoName,
        [string]$TargetDn
    )

    # Surfaces a missing OU as a configuration problem rather than a raw cmdlet error.
    try {
        $inheritance = Get-GPInheritance `
            -Target $TargetDn `
            -ErrorAction Stop
    }
    catch {
        throw (
            "Cannot link '$GpoName'. Target OU '$TargetDn' " +
            "was not found; confirm directory population completed: " +
            "$($_.Exception.Message)"
        )
    }

    $existingLink = $inheritance.GpoLinks |
        Where-Object DisplayName -eq $GpoName

    if ($null -eq $existingLink) {

        New-GPLink `
            -Name $GpoName `
            -Target $TargetDn `
            -LinkEnabled Yes `
            -ErrorAction Stop |
            Out-Null

        Write-AmrlLog "[Link] $GpoName"
    }
    elseif (-not $existingLink.Enabled) {

        Set-GPLink `
            -Name $GpoName `
            -Target $TargetDn `
            -LinkEnabled Yes `
            -ErrorAction Stop

        Write-AmrlLog "[Enable] Link $GpoName"
    }
    elseif ($existingLink.Enforced) {

        Set-GPLink `
            -Name $GpoName `
            -Target $TargetDn `
            -Enforced No `
            -ErrorAction Stop

        Write-AmrlLog "[Unenforce] Link $GpoName"
    }
    else {

        Write-AmrlLog "[Exists] Link $GpoName"

    }
}

# Imports a GPO from the backup set, skipping GPOs that already exist.
function Ensure-GpoFromTemplate {
    param(
        [string]$GpoName,
        [string]$TemplatePath
    )

    $existing = Get-GPO `
        -Name $GpoName `
        -ErrorAction SilentlyContinue

    if ($null -eq $existing) {

        Write-AmrlLog (
            "[Create] $GpoName from template"
        )
        
        Write-AmrlLog (
            "[Import] Using template path: $TemplatePath"
        )

        Write-AmrlLog (
            "[Import] Template path exists: $TemplatePath"
        )

        # Import-GPO matches a backup by the DisplayName recorded inside its
        # Backup.xml, so the directory model's gpoNames must equal the exported
        # names. Resolving it here fails fast with a clearer message than the
        # cmdlet's own "backup not found" error.
        $backupXmlFiles = Get-ChildItem `
            -LiteralPath $TemplatePath `
            -Filter 'Backup.xml' `
            -File `
            -Recurse `
            -ErrorAction Stop

        $matchingBackup = $null

        foreach ($backupXmlFile in $backupXmlFiles) {
            [xml]$backupDocument = Get-Content `
                -LiteralPath $backupXmlFile.FullName `
                -Raw `
                -ErrorAction Stop

            $displayNameNode = $backupDocument.SelectSingleNode(
                "//*[local-name()='DisplayName']"
            )

            if ($null -ne $displayNameNode -and $displayNameNode.InnerText -eq $GpoName) {
                $matchingBackup = $backupXmlFile
                break
            }
        }

        if ($null -eq $matchingBackup) {
            throw "No Backup.xml for '$GpoName' was found under '$TemplatePath'"
        }

        Write-AmrlLog "[Validate] Matched backup: $($matchingBackup.FullName)"

        # -Path is the backup root holding the GUID folders, not the matched
        # folder itself; -BackupGpoName selects which backup inside it to use.
        Import-GPO `
            -BackupGpoName $GpoName `
            -Path $TemplatePath `
            -TargetName $GpoName `
            -CreateIfNeeded `
            -ErrorAction Stop |
            Out-Null

        Write-AmrlLog (
            "[Success] Imported $GpoName"
        )

        $importedGpo = Get-GPO `
            -Name $GpoName `
            -ErrorAction Stop

        Write-AmrlLog "[Validate] Imported GPO exists: $($importedGpo.DisplayName) ($($importedGpo.Id))"

    }
    else {

        Write-AmrlLog (
            "[Exists] $GpoName"
        )

    }
}

# Re-points the exported admins reference at this domain. The zip carries the
# SID and NetBIOS name of whichever domain it was exported from, so both are
# rewritten here rather than being trusted from the template.
#
# Unlike the import, this runs on every execution. It edits Groups.xml directly
# in SYSVOL without incrementing the GPO version, so clients may not reprocess
# the preference until the version changes.
function Update-GpoGroupReference {
    param(
        [string]$GpoName
    )

    $gpo = Get-GPO `
        -Name $GpoName `
        -ErrorAction Stop

    $groupsXmlPath =
        "\\$DomainName\SYSVOL\$DomainName\Policies\{$($gpo.Id)}\Machine\Preferences\Groups\Groups.xml"

    if (-not (Test-Path $groupsXmlPath)) {
        throw "Groups.xml not found: $groupsXmlPath"
    }

    $windowsAdminsGroupName = (
        "$($model.groupNaming.globalSecurityPrefix)_" +
        "$($model.platformAdminGroups.windowsAdmins)"
    )

    $windowsAdminsGroup = Get-ADGroup `
        -Identity $windowsAdminsGroupName `
        -Properties SID `
        -ErrorAction Stop

    $currentSid =
        $windowsAdminsGroup.SID.Value

    $netbiosDomainName =
        (Get-ADDomain).NetBIOSName

    [xml]$xml =
        Get-Content `
            $groupsXmlPath `
            -Raw

    $member =
        $xml.Groups.Group.Properties.Members.Member

    # The exported preference carries exactly one admins member; more than one
    # means the template changed shape and the rewrite below would be ambiguous.
    if ($null -eq $member) {
        throw "No Member entry remains in '$groupsXmlPath' for '$GpoName'."
    }

    if (@($member).Count -gt 1) {
        throw "Expected a single Member entry in '$groupsXmlPath' for '$GpoName', found $(@($member).Count)."
    }

    $desiredName =
        "$netbiosDomainName\$windowsAdminsGroupName"

    $needsUpdate =
        ($member.sid -ne $currentSid) -or
        ($member.name -ne $desiredName)

    if ($needsUpdate) {

        $member.sid =
            $currentSid

        $member.name =
            $desiredName

        $xml.Groups.Group.changed =
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

        try {

            $xml.Save($groupsXmlPath)

        }
        catch {

            throw (
                "Failed to update Groups.xml for '$GpoName' " +
                "at '$groupsXmlPath': " +
                "$($_.Exception.Message)"
            )

        }

        Write-AmrlLog (
            "[Reference Updated] $GpoName administrators member is $($member.name)."
        )
    }
    else {

        Write-AmrlLog (
            "[Reference Verified] $GpoName administrators member is $desiredName."
        )
    }
}

# Keep the LAPS GPO's AD password decryptor aligned with the live domain and directory model.
function Update-LapsGpoDecryptor {
    param(
        [string]$GpoName,
        [object]$DirectoryModel
    )

    $gpo = Get-GPO `
        -Name $GpoName `
        -ErrorAction Stop

    $domain = Get-ADDomain -ErrorAction Stop

    $windowsAdminsGroupName = (
        "$($DirectoryModel.groupNaming.globalSecurityPrefix)_" +
        $DirectoryModel.platformAdminGroups.windowsAdmins
    )

    $windowsAdminsGroup = Get-ADGroup `
        -Identity $windowsAdminsGroupName `
        -ErrorAction Stop

    $expectedDecryptor = (
        $domain.NetBIOSName + "\" + $windowsAdminsGroup.SamAccountName
    )

    $lapsPolicyKey = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'
    $decryptorValueName = 'ADPasswordEncryptionPrincipal'

    $currentSetting = Get-GPRegistryValue `
        -Guid $gpo.Id `
        -Key $lapsPolicyKey `
        -ValueName $decryptorValueName `
        -ErrorAction SilentlyContinue

    if ($null -ne $currentSetting -and $currentSetting.Value -eq $expectedDecryptor) {
        Write-AmrlLog "[=] LAPS authorized decryptor is current: $expectedDecryptor"
        return
    }

    Set-GPRegistryValue `
        -Guid $gpo.Id `
        -Key $lapsPolicyKey `
        -ValueName $decryptorValueName `
        -Type String `
        -Value $expectedDecryptor `
        -ErrorAction Stop |
        Out-Null

    Write-AmrlLog "[Reconciled] LAPS authorized decryptor: $expectedDecryptor"
}

Ensure-GpoFromTemplate `
    -GpoName $serverAdministrationGpoName `
    -TemplatePath $gpoTemplateRepositoryPath

Update-GpoGroupReference `
    -GpoName $serverAdministrationGpoName

Ensure-GpoFromTemplate `
    -GpoName $clientAdministrationGpoName `
    -TemplatePath $gpoTemplateRepositoryPath

Update-GpoGroupReference `
    -GpoName $clientAdministrationGpoName

Ensure-GpoFromTemplate `
    -GpoName $windowsLapsGpoName `
    -TemplatePath $gpoTemplateRepositoryPath

Update-LapsGpoDecryptor `
    -GpoName $windowsLapsGpoName `
    -DirectoryModel $model

Ensure-GpoLink `
    -GpoName $serverAdministrationGpoName `
    -TargetDn $serversOuDn

Ensure-GpoLink `
    -GpoName $clientAdministrationGpoName `
    -TargetDn $clientsOuDn

Ensure-GpoLink `
    -GpoName $windowsLapsGpoName `
    -TargetDn $serversOuDn

Ensure-GpoLink `
    -GpoName $windowsLapsGpoName `
    -TargetDn $clientsOuDn

if (Test-Path $templateRoot) {

    Remove-Item `
        $templateRoot `
        -Recurse `
        -Force `
        -ErrorAction Stop

    Write-AmrlLog "[Cleanup] Removed extracted GPO templates"

}
else {

    Write-AmrlLog "[Cleanup] GPO template folder already absent"

}

if (Test-Path $zipPath) {

    Remove-Item `
        $zipPath `
        -Force `
        -ErrorAction Stop

    Write-AmrlLog "[Cleanup] Removed GPO template archive"

}
else {

    Write-AmrlLog "[Cleanup] GPO template archive already absent"

}

Write-AmrlLog (
    "[Info] GPO reconciliation summary: Created=$($script:logCounts.Created); Verified=$($script:logCounts.Verified); Updated=$($script:logCounts.Updated); Removed=$($script:logCounts.Removed); Skipped=$($script:logCounts.Skipped); Warnings=$($script:logCounts.Warning); Errors=$($script:logCounts.Error)."
)
Write-AmrlLog '[Info] GPO template import and reconciliation completed.'