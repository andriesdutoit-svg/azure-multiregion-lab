# GPO templates are imported only when missing.
#
# Existing GPOs are intentionally preserved to
# align with AMRL's reconciliation model and
# avoid destructive policy replacement.

param(
    [string]$DomainName,
    [string]$DirectoryModel,
    
    [string]$ServerAdministrationBackupXml,
    [string]$ServerAdministrationReportXml,
    [string]$ServerAdministrationGroupsXml,

    [string]$ClientAdministrationBackupXml,
    [string]$ClientAdministrationReportXml,
    [string]$ClientAdministrationGroupsXml,

    [string]$ReconciliationToken
)

Write-Host "Template files received successfully"

Write-Host "AMRL GPO Template Import"

Import-Module GroupPolicy -ErrorAction Stop

$templateRoot = 'C:\Temp\GpoTemplates'

$model = $DirectoryModel | ConvertFrom-Json

$domainDn = (($DomainName -split '\.') | ForEach-Object {
    "DC=$_"
}) -join ','

$serversOuDn =
    "OU=Servers,OU=Computers,OU=$($model.rootOuName),$domainDn"

$clientsOuDn =
    "OU=Clients,OU=Computers,OU=$($model.rootOuName),$domainDn"

$gpoTemplateRepositoryPath = $templateRoot

Write-Host "Template Root = $templateRoot"

function Write-TemplateFile {
    param(
        [string]$FilePath,
        [string]$Content
    )

    $parentFolder = Split-Path `
        -Path $FilePath `
        -Parent

    if (-not (Test-Path $parentFolder)) {

        New-Item `
            -ItemType Directory `
            -Path $parentFolder `
            -Force |
            Out-Null

    }

    Set-Content `
        -Path $FilePath `
        -Value $Content `
        -Encoding UTF8
}

function Write-GpoTemplate {
    param(
        [string]$TemplateName,

        [string]$BackupXml,
        [string]$ReportXml,
        [string]$GroupsXml
    )

    $templatePath =
        Join-Path `
            $templateRoot `
            $TemplateName

    Write-TemplateFile `
        -FilePath "$templatePath\Backup.xml" `
        -Content $BackupXml

    Write-TemplateFile `
        -FilePath "$templatePath\gpreport.xml" `
        -Content $ReportXml

    Write-TemplateFile `
        -FilePath "$templatePath\DomainSysvol\GPO\Machine\Preferences\Groups\Groups.xml" `
        -Content $GroupsXml

    Write-Host (
        "[Template Created] $TemplateName"
    )
}

Write-Host "GroupPolicy module loaded successfully"

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

        New-GPLink `
            -Name $GpoName `
            -Target $TargetDn `
            -LinkEnabled Yes `
            -ErrorAction Stop |
            Out-Null

        Write-Host "[Link] $GpoName"
    }
    else {

        Write-Host "[Exists] Link $GpoName"

    }
}

function Ensure-GpoFromTemplate {
    param(
        [string]$GpoName,
        [string]$TemplatePath
    )

    $existing = Get-GPO `
        -Name $GpoName `
        -ErrorAction SilentlyContinue

    if ($null -eq $existing) {

        Write-Host (
            "[Create] $GpoName from template"
        )
        
        Write-Host (
            "[Import] Using template path: $TemplatePath"
        )

        Write-Host (
            "[Validate] Template path exists: $TemplatePath"
        )

        Get-ChildItem `
            $TemplatePath `
            -Recurse |
            Select-Object FullName |
            Out-Host

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

        Write-Host "[Validate] Matched backup: $($matchingBackup.FullName)"

        Import-GPO `
            -BackupGpoName $GpoName `
            -Path $TemplatePath `
            -TargetName $GpoName `
            -CreateIfNeeded `
            -ErrorAction Stop |
            Out-Null

        Write-Host (
            "[Success] Imported $GpoName"
        )

        $importedGpo = Get-GPO `
            -Name $GpoName `
            -ErrorAction Stop

        Write-Host "[Validate] Imported GPO exists: $($importedGpo.DisplayName) ($($importedGpo.Id))"

    }
    else {

        Write-Host (
            "[Exists] $GpoName"
        )

    }
}

Write-GpoTemplate `
    -TemplateName '{B2F4D556-0972-4279-A56B-72971037BEEB}' `
    -BackupXml $ServerAdministrationBackupXml `
    -ReportXml $ServerAdministrationReportXml `
    -GroupsXml $ServerAdministrationGroupsXml

Write-GpoTemplate `
    -TemplateName '{BAE14512-0FC9-4990-90C1-58FB81F7D4E7}' `
    -BackupXml $ClientAdministrationBackupXml `
    -ReportXml $ClientAdministrationReportXml `
    -GroupsXml $ClientAdministrationGroupsXml

Ensure-GpoFromTemplate `
    -GpoName 'Server Administration' `
    -TemplatePath $gpoTemplateRepositoryPath

Ensure-GpoFromTemplate `
    -GpoName 'Client Administration' `
    -TemplatePath $gpoTemplateRepositoryPath

Ensure-GpoLink `
    -GpoName 'Server Administration' `
    -TargetDn $serversOuDn

Ensure-GpoLink `
    -GpoName 'Client Administration' `
    -TargetDn $clientsOuDn

Get-ChildItem `
    $templateRoot `
    -Recurse |
    Select-Object FullName |
    Out-File `
        "$templateRoot\TemplateInventory.txt"

Write-Host "AMRL GPO Template Import Completed"