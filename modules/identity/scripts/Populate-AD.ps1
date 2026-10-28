<#
Populate AMRL AD objects (OU/group/user) on dc01.
Derived from Set-DummyAD and adapted for idempotent Run Command execution.

Consumes the serialized directory model, ordered department definitions, CSV name
content, user targets, and file-service setting. Requires AD administration on the
primary DC plus the AD/LAPS tooling used below; identity-stage orders population
after forest and replica provisioning and before GPO configuration.

Creates missing objects and repairs modeled DC HTTP SPNs, selected department,
manager, membership, and LAPS settings. Some group membership is authoritative and can remove stale members;
this is not general deletion or migration of all objects absent from input.
New accounts receive independent random passwords, not logged passwords. Retained
accounts are repaired rather than recreated or assigned newly generated passwords.

The helper order and final driver sequence are intentional: structure/groups must
exist before permissions, manager reconciliation, user repair, and missing-user creation.
Console/transcript summaries describe actions, not a complete directory health check.
The Bicep caller embeds Get-SelectedDepartments.ps1 at the helper marker; this source
file is a payload template, not a standalone script with guest-side helper dependencies.
#>

# 1. Validated caller inputs
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DomainName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DirectoryModel,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DomainControllerNamesJson,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$NamesCsvContent,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SysAdminDepartmentJson,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AdditionalDepartmentsJson,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 1000)]
    [int]$DepartmentCount,

    [Parameter(Mandatory = $true)]
    [ValidateRange(0, 10000)]
    [int]$UsersPerDepartment,

    [Parameter(Mandatory = $false)]
    [string]$ReconciliationToken,

    [Parameter(Mandatory = $false)]
    [string]$EnableFileServices
)

# 2. Status logging and AD/transcript initialization
$script:logCounts = @{
    Info = 0
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
    elseif ($Message -match '^\[(?<legacy>\+|=|i|INFO|WARN|ERROR|DEBUG|Cleanup)\]\s*(?<body>.*)$') {
        $legacy = $Matches.legacy
        $Message = $Matches.body
        switch ($legacy) {
            '+' {
                if ($Message -match '^Created\b') { $Status = 'Created' }
                elseif ($Message -match '^(Creating|Adding|Configuring)\b') { $Status = 'Info' }
                elseif ($Message -match '^Removed\b') { $Status = 'Removed' }
                else { $Status = 'Info' }
                break
            }
            '=' {
                if ($Message -match '^(Membership already exists|Windows LAPS schema already present)') { $Status = 'Verified' }
                else { $Status = 'Info' }
                break
            }
            'WARN' { $Status = 'Warning'; break }
            'ERROR' { $Status = 'Error'; break }
            'Cleanup' { $Status = 'Removed'; break }
            'DEBUG' { return }
            default { $Status = 'Info' }
        }
    }

    if ($script:logCounts.ContainsKey($Status)) {
        $script:logCounts[$Status]++
    }

    $formattedMessage = "[$Status] $Message"
    switch ($Status) {
        'Warning' { Microsoft.PowerShell.Utility\Write-Warning $formattedMessage }
        'Error' { Microsoft.PowerShell.Utility\Write-Error $formattedMessage }
        default { Microsoft.PowerShell.Utility\Write-Host $formattedMessage }
    }
}

Write-AmrlLog '[Info] Starting AMRL directory population.'
Write-AmrlLog "[Info] Target domain: $DomainName."

Import-Module ActiveDirectory -ErrorAction Stop

# Transcript logging.
# Captures all console output for troubleshooting
# brownfield remediation and user population issues.
# Treat transcripts as operational data: they include directory identities and paths.

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$logFile = "C:\Windows\Temp\populate-ad-$timestamp.log"

Start-Transcript `
    -Path $logFile `
    -Force

Write-AmrlLog "[Info] Transcript log: $logFile."

# 3. Directory lookup, creation, and membership helpers
# Ensure-* helpers generally avoid duplicate creation; repair and authoritative membership
# helpers deliberately mutate selected retained state. Function definitions do not imply execution order.

# Get-ManagedOU: Traverse nested OU hierarchy by path string (e.g., 'Computers/Servers')
function Get-ManagedOU {
    param(
        [string]$OuPath,
        [string]$RootOuDn
    )

    $segments = $OuPath -split '/'

    $searchBase = $RootOuDn
    $ou = $null

    foreach ($segment in $segments) {
        $ou = Get-ADOrganizationalUnit `
            -LDAPFilter "(ou=$segment)" `
            -SearchBase $searchBase `
            -SearchScope OneLevel `
            -ErrorAction Stop

        $searchBase = $ou.DistinguishedName
    }

    return $ou
}

# Ensure-OrganizationalUnit: Create OU if not exists; return existing OU if present (idempotent).
# Supports nested paths (e.g., path 'OU=Computers,DC=...' creates Computers OU within domain).
function Ensure-OrganizationalUnit {
    param(
        [string]$Name,
        [string]$Path,
        [bool]$ProtectedFromAccidentalDeletion = $false
    )

    $existingOu = Get-ADOrganizationalUnit `
        -LDAPFilter "(ou=$Name)" `
        -SearchBase $Path `
        -SearchScope OneLevel `
        -ErrorAction SilentlyContinue

    if ($existingOu) {
        Write-AmrlLog "[=] OU already exists: $Name"
        return $existingOu
    }

    Write-AmrlLog "[Info] Creating OU $Name."

    New-ADOrganizationalUnit `
        -Name $Name `
        -Path $Path `
        -ProtectedFromAccidentalDeletion $ProtectedFromAccidentalDeletion

    Write-AmrlLog "[Created] OU $Name."
    return Get-ADOrganizationalUnit `
        -LDAPFilter "(ou=$Name)" `
        -SearchBase $Path `
        -SearchScope OneLevel
}

# Ensure-ADGroup: Create AGDLP group if not exists; return existing group if present (idempotent).
# GroupScope: DomainLocal (DLGS) for local resource permissions, Global (GGS) for distribution/membership.
# Follows AGDLP nesting: Global group contains users, DomainLocal group grants resource permissions.
function Ensure-ADGroup {
    param(
        [string]$Name,
        [string]$Path,
        [string]$GroupCategory,
        [string]$GroupScope
    )

    $existingGroup = Get-ADGroup `
        -LDAPFilter "(cn=$Name)" `
        -SearchBase $Path `
        -SearchScope OneLevel `
        -ErrorAction SilentlyContinue

    if ($existingGroup) {
        Write-AmrlLog "[=] Group already exists: $Name"
        return $existingGroup
    }

    Write-AmrlLog "[Info] Creating group $Name."

    New-ADGroup `
        -Name $Name `
        -GroupCategory $GroupCategory `
        -GroupScope $GroupScope `
        -Path $Path

    Write-AmrlLog "[Created] Group $Name."
    return Get-ADGroup `
        -LDAPFilter "(cn=$Name)" `
        -SearchBase $Path `
        -SearchScope OneLevel
}

function Ensure-ADGroupMember {
    param(
        [string]$GroupName,
        [string]$MemberName
    )

    $existingMember = Get-ADGroupMember `
        -Identity $GroupName `
        -ErrorAction SilentlyContinue |
        Where-Object Name -eq $MemberName

    if ($existingMember) {
        Write-AmrlLog "[=] Membership already exists: $MemberName -> $GroupName"
        return
    }

    Write-AmrlLog "[Info] Adding membership $MemberName -> $GroupName."

    Add-ADGroupMember `
        -Identity $GroupName `
        -Members $MemberName

    Write-AmrlLog "[Created] Membership $MemberName -> $GroupName."
}

# This helper removes direct members outside DesiredMembers before ensuring desired membership.
# It is stronger than the additive Ensure-* operations and must not be reordered around callers.
function Set-ADGroupMembersAuthoritative {
    param(
        [string]$GroupName,
        [string[]]$DesiredMembers
    )

    $currentMembers = Get-ADGroupMember `
        -Identity $GroupName `
        -ErrorAction SilentlyContinue

    foreach ($member in $currentMembers) {

        if ($member.Name -notin $DesiredMembers) {

            Write-AmrlLog (
                "[INFO] Removing stale membership: " +
                $member.Name +
                " -> " +
                $GroupName
            )

            Remove-ADGroupMember `
                -Identity $GroupName `
                -Members $member `
                -Confirm:$false `
                -ErrorAction SilentlyContinue
        }
    }

    foreach ($member in $DesiredMembers) {

        Ensure-ADGroupMember `
            -GroupName $GroupName `
            -MemberName $member
    }
}

function Ensure-ADPrincipalGroupMembership {
    param(
        [string]$GroupName,
        [string]$MemberName
    )

    $existingMember = Get-ADGroupMember `
        -Identity $GroupName `
        -Recursive `
        -ErrorAction SilentlyContinue |
        Where-Object SamAccountName -eq $MemberName

    if ($existingMember) {
        Write-AmrlLog "[=] Membership already exists: $MemberName -> $GroupName"
        return
    }

    Write-AmrlLog "[Info] Adding membership $MemberName -> $GroupName."

    Add-ADGroupMember `
        -Identity $GroupName `
        -Members $MemberName

    Write-AmrlLog "[Created] Membership $MemberName -> $GroupName."
}

# 4. User creation and selected-attribute repair helpers

# Generate an independent password for each newly created account.
function New-RandomPassword {
    param(
        [int]$Length = 24
    )

    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnopqrstuvwxyz'
    $numbers = '23456789'
    $special = '!@#$%^&*_-+=?'

    $allChars = ($upper + $lower + $numbers + $special).ToCharArray()

    $bytes = New-Object byte[] ($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)

    $passwordChars = for ($i = 0; $i -lt $Length; $i++) {
        $allChars[$bytes[$i] % $allChars.Length]
    }

    -join $passwordChars
}

function Ensure-ADUser {
    param(
        [string]$SamAccountName,
        [string]$Path,
        [string]$DisplayName,
        [string]$GivenName,
        [string]$Surname,
        [string]$UserPrincipalName,
        [string]$Department,
        [string]$Title,
        [string]$Manager
    )
    
    $existingUser = Get-ADUser `
        -LDAPFilter "(sAMAccountName=$SamAccountName)" `
        -ErrorAction SilentlyContinue

# Existing users are updated rather than recreated.
# Selected attributes such as Department and Title
# are reconciled during re-execution.
# Reporting lines are reconciled by Reconcile-DepartmentManagers()
# before existing users are repaired.

if ($existingUser) {

    $existingUserFull = Get-ADUser `
        -Identity $existingUser `
        -Properties Title,DistinguishedName

    $existingUserOU = (
        $existingUserFull.DistinguishedName -split ','
    )[1] -replace '^OU='

    $updateParams = @{
        Identity = $existingUser
    }

    if ($existingUserOU) {
        $updateParams.Department = $existingUserOU
    }
    elseif ($Department) {
        $updateParams.Department = $Department
    }

    if ($Title) {
        $updateParams.Title = $Title
    }

    Set-ADUser @updateParams

    # Reporting lines are reconciled by Reconcile-DepartmentManagers()
    # before this user-repair operation. Manager assignments are not
    # updated here.

    return (
        Get-ADUser `
            -Identity $existingUser `
            -Properties *
    )
}

Write-AmrlLog "[Info] Creating AD user account $SamAccountName."

$generatedPassword = New-RandomPassword

$securePassword = ConvertTo-SecureString `
    $generatedPassword `
    -AsPlainText `
    -Force

    $params = @{
        Name                  = $DisplayName
        DisplayName           = $DisplayName
        GivenName             = $GivenName
        Surname               = $Surname
        SamAccountName        = $SamAccountName
        UserPrincipalName     = $UserPrincipalName
        EmailAddress          = $UserPrincipalName
        Path                  = $Path
        AccountPassword       = $securePassword
        ChangePasswordAtLogon = $false
        PasswordNeverExpires  = $true
        Enabled               = $true
        Department            = $Department
    }

    if ($Title) {
        $params.Title = $Title
    }

    try {

        New-ADUser @params -ErrorAction Stop
    }
    catch {

        Write-AmrlLog -Status Error -Message 'Failed to create an AD user account.'

        throw
    }

    $newUser = Get-ADUser `
    -LDAPFilter "(sAMAccountName=$SamAccountName)" `
    -ErrorAction SilentlyContinue

        if (-not $newUser) {

            throw (
                "User creation failed. " +
                "SamAccountName='$SamAccountName'"
            )
        }

    if (-not $newUser) {

        throw (
            "User creation failed. " +
            "SamAccountName='$SamAccountName'"
        )
    }

    Write-AmrlLog '[Created] AD user account creation completed.'

    if ($Manager) {
        Set-ADUser `
            -Identity $newUser `
            -Manager $Manager
    }

    return (
        Get-ADUser `
            -Identity $newUser `
            -Properties *
    )
}

# 5. Department selection, source records, and OU/group construction helpers
# Department ordering and mandatory-selection rules live in the shared helper used by file services.
# Bicep replaces this marker with the shared helper after the caller parameter block.
# __AMRL_DEPARTMENT_SELECTION__

function Initialize-NamesCsvRecords {
    param(
        [string]$InputNamesCsvContent,
        [string]$CsvPath
    )

    Set-Content `
        -Path $CsvPath `
        -Value $InputNamesCsvContent `
        -Force

    return [System.Collections.ArrayList]@(
        Get-Content $CsvPath |
        ConvertFrom-Csv -Delimiter ';'
    )
}

function Get-SamAccountName {
    param(
        [string]$FirstName,
        [string]$LastName
    )
    

    # Reject invalid CSV records.
    # Empty first or last names can generate invalid
    # sAMAccountNames and cause New-ADUser failures.
    if (
            [string]::IsNullOrWhiteSpace($FirstName) -or
            [string]::IsNullOrWhiteSpace($LastName)
        ) {
            throw (
                "Invalid CSV record. " +
                "FirstName='$FirstName', " +
                "LastName='$LastName'"
            )
        }

    $sam = (
        $FirstName +
        "." +
        ($LastName -replace '\s+', '')
    ).ToLower()

    # Active Directory sAMAccountName maximum:
    # 20 characters.
    if ($sam.Length -gt 20) {
        $sam = $sam.Substring(0, 20)
    }

    Write-AmrlLog (
        "[DEBUG] Generated sAMAccountName: " +
        $sam +
        " Length=" +
        $sam.Length
    )

    return $sam
}

function Ensure-DirectoryOuStructure {
    param(
        [object]$PopulationModel,
        [string]$DomainDn
    )

    Write-AmrlLog "[i] OU generation starting"

    $rootOU = Ensure-OrganizationalUnit `
        -Name $PopulationModel.rootOuName `
        -Path $DomainDn `
        -ProtectedFromAccidentalDeletion $PopulationModel.preventOuDeletion

    $rootOUdn = $rootOU.DistinguishedName

    foreach ($ouName in $PopulationModel.customOus) {

        if ($ouName -notlike "*/*") {

            Ensure-OrganizationalUnit `
                -Name $ouName `
                -Path $rootOUdn `
                -ProtectedFromAccidentalDeletion $PopulationModel.preventOuDeletion |
                Out-Null
        }
        else {

            $parentOU = $ouName.Split('/')[0]
            $childOU = $ouName.Split('/')[1]

            $parentOUObject = Get-ADOrganizationalUnit `
                -LDAPFilter "(ou=$parentOU)" `
                -SearchBase $rootOUdn `
                -ErrorAction Stop

            Ensure-OrganizationalUnit `
                -Name $childOU `
                -Path $parentOUObject.DistinguishedName `
                -ProtectedFromAccidentalDeletion $PopulationModel.preventOuDeletion |
                Out-Null
        }
    }

    Write-AmrlLog "[i] OU generation completed"

    return $rootOUdn
}

function Ensure-DepartmentOUs {
    param(
        [object[]]$SelectedDepartments,
        [string]$RootOuDn,
        [bool]$PreventOuDeletion,
        [object]$PopulationModel
    )

    Write-AmrlLog "[i] Department OU generation starting"

    $usersOU = Get-ManagedOU `
        -OuPath $PopulationModel.coreOuMapping.users `
        -RootOuDn $RootOuDn

    foreach ($department in $SelectedDepartments) {

        Ensure-OrganizationalUnit `
            -Name $department.Name `
            -Path $usersOU.DistinguishedName `
            -ProtectedFromAccidentalDeletion $PreventOuDeletion |
            Out-Null
    }

    Write-AmrlLog "[i] Department OU generation completed"

    return $usersOU
}

$fileServicesEnabled =
    [System.Convert]::ToBoolean($EnableFileServices)

Write-AmrlLog "EnableFileServices raw value = [$EnableFileServices]"
Write-AmrlLog "EnableFileServices converted value = [$fileServicesEnabled]"

function Ensure-DepartmentSecurityGroups {
    param(
        [object[]]$SelectedDepartments,
        [string]$RootOuDn,
        [object]$PopulationModel,
        [bool]$EnableFileServices
    )

    $ggsPrefix = $PopulationModel.groupNaming.globalSecurityPrefix
    $dlgsPrefix = $PopulationModel.groupNaming.domainLocalSecurityPrefix

    $windowsAdminsGroup = (
        "${ggsPrefix}_$($PopulationModel.platformAdminGroups.windowsAdmins)"
    )

    $linuxAdminsGroup = (
        "${ggsPrefix}_$($PopulationModel.platformAdminGroups.linuxAdmins)"
    )

    Write-AmrlLog "[i] Department security group generation starting"

    $ggsOU = Get-ManagedOU `
        -OuPath $PopulationModel.groupOuMapping.globalSecurity `
        -RootOuDn $RootOuDn

    $dlgsOU = Get-ManagedOU `
        -OuPath $PopulationModel.groupOuMapping.domainLocalSecurity `
        -RootOuDn $RootOuDn

    if (-not $ggsOU -or [string]::IsNullOrWhiteSpace($ggsOU.DistinguishedName)) {
        throw "Unable to resolve group OU: $($PopulationModel.groupOuMapping.globalSecurity)"
    }

    if (-not $dlgsOU -or [string]::IsNullOrWhiteSpace($dlgsOU.DistinguishedName)) {
        throw "Unable to resolve group OU: $($PopulationModel.groupOuMapping.domainLocalSecurity)"
    }

    Ensure-ADGroup `
        -Name $windowsAdminsGroup `
        -Path $ggsOU.DistinguishedName `
        -GroupCategory Security `
        -GroupScope Global

    Ensure-ADGroup `
        -Name $linuxAdminsGroup `
        -Path $ggsOU.DistinguishedName `
        -GroupCategory Security `
        -GroupScope Global

    foreach ($department in $SelectedDepartments) {

        $code = $department.Value

        Ensure-ADGroup `
            -Name "${ggsPrefix}_${code}_ALL" `
            -Path $ggsOU.DistinguishedName `
            -GroupCategory Security `
            -GroupScope Global

        Ensure-ADGroup `
            -Name "${ggsPrefix}_${code}_Managers" `
            -Path $ggsOU.DistinguishedName `
            -GroupCategory Security `
            -GroupScope Global

        Ensure-ADGroup `
            -Name "${ggsPrefix}_${code}_Users" `
            -Path $ggsOU.DistinguishedName `
            -GroupCategory Security `
            -GroupScope Global
           
        Write-AmrlLog "Department security group file-service setting = [$EnableFileServices]"

        if ($EnableFileServices) {

            # Share_RW/Share_RO are AD groups only; 
            # The file server (Populate-Shares.ps1) references them by name for NTFS ACLs.
            
            Ensure-ADGroup `
                -Name "${dlgsPrefix}_${code}_Share_RW" `
                -Path $dlgsOU.DistinguishedName `
                -GroupCategory Security `
                -GroupScope DomainLocal

            Ensure-ADGroup `
                -Name "${dlgsPrefix}_${code}_Share_RO" `
                -Path $dlgsOU.DistinguishedName `
                -GroupCategory Security `
                -GroupScope DomainLocal

        }
    }

    Write-AmrlLog "[i] Department security group generation completed"
}

function Ensure-DepartmentGroupNesting {
    param(
        [object[]]$SelectedDepartments,
        [object]$PopulationModel,
        [bool]$EnableFileServices
    )

    $ggsPrefix = $PopulationModel.groupNaming.globalSecurityPrefix
    $dlgsPrefix = $PopulationModel.groupNaming.domainLocalSecurityPrefix

    $windowsAdminsGroup = (
        "${ggsPrefix}_$($PopulationModel.platformAdminGroups.windowsAdmins)"
    )

    $linuxAdminsGroup = (
        "${ggsPrefix}_$($PopulationModel.platformAdminGroups.linuxAdmins)"
    )

    Write-AmrlLog "[i] Department group nesting starting"

    # Nests Managers/Users into Share_RW/Share_RO so the file server's ACLs (Populate-Shares.ps1) resolve correct membership.

    $platformAdminUsersGroup = (
        "${ggsPrefix}_" +
        "$($PopulationModel.platformAdminGroups.sourceDepartmentCode)" +
        "_ALL"
    )

    if (Get-ADGroup -Identity $platformAdminUsersGroup -ErrorAction SilentlyContinue) {

        Set-ADGroupMembersAuthoritative `
            -GroupName $windowsAdminsGroup `
            -DesiredMembers @(
                $platformAdminUsersGroup
            )

        Set-ADGroupMembersAuthoritative `
            -GroupName $linuxAdminsGroup `
            -DesiredMembers @(
                $platformAdminUsersGroup
            )
    }
    else {
        Write-AmrlLog -Status Warning -Message (
            "$platformAdminUsersGroup not found. " +
            "Skipping platform admin group nesting."
        )
    }

    Write-AmrlLog "Department group nesting file-service setting = [$EnableFileServices]"

    if ($EnableFileServices) {

        foreach ($department in $SelectedDepartments) {

            $code = $department.Value

            Ensure-ADGroupMember `
                -GroupName "${dlgsPrefix}_${code}_Share_RW" `
                -MemberName "${ggsPrefix}_${code}_Managers"

            Ensure-ADGroupMember `
                -GroupName "${dlgsPrefix}_${code}_Share_RO" `
                -MemberName "${ggsPrefix}_${code}_Users"
        }
    }

    Write-AmrlLog "[i] Department group nesting completed"
}

# Department manager reconciliation.
# 6. Department ownership, reporting lines, and target/repair helpers
# OU placement is the authoritative source of
# departmental ownership and reporting lines.
# Rules:
# - One manager per department is supported.
# - Additional manager accounts are demoted.
# - Standard-user reporting lines follow the available departmental manager.
# - Users reporting outside their department
#   are remediated.
# - When a departmental manager exists,
#   incorrect reporting lines are reassigned
#   to that manager.
# - When no departmental manager exists,
#   incorrect reporting lines are removed by
#   clearing the Manager attribute.
# Reconciliation includes:
# - Department attribute
# - Title
# - Manager assignments
# - Departmental ALL groups
# - Departmental Manager groups

function Reconcile-DepartmentManagers {
    param(
        [object[]]$SelectedDepartments,
        [object]$UsersOu,
        [System.Collections.ArrayList]$CsvNames,
        [string]$DomainName,
        [object]$PopulationModel
    )

    $ggsPrefix = $PopulationModel.groupNaming.globalSecurityPrefix

    $departmentInfo = @{}

    foreach ($department in $SelectedDepartments) {

        $departmentOU = Get-ADOrganizationalUnit `
            -LDAPFilter "(ou=$($department.Name))" `
            -SearchBase $UsersOu.DistinguishedName `
            -ErrorAction Stop

        $existingDepartmentManagers = @(
            Get-ADUser `
                -SearchBase $departmentOU.DistinguishedName `
                -Filter * `
                -Properties Title `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Title -like '*Manager*'
            }
        )

        # Brownfield remediation:
        # DummyAD supports one manager per department.
        # Keep the first manager found and demote the rest.
        if ($existingDepartmentManagers.Count -gt 1) {

            $primaryManager = $existingDepartmentManagers |
                Select-Object -First 1

            $duplicateManagers = $existingDepartmentManagers |
                Select-Object -Skip 1

            foreach ($duplicateManager in $duplicateManagers) {

                Write-AmrlLog (
                    "[INFO] Demoting duplicate manager: " +
                    $duplicateManager.SamAccountName
                )

                Set-ADUser `
                    -Identity $duplicateManager `
                    -Clear Title

                # Reporting lines are reconciled after duplicate managers
                # have been resolved.

                Remove-ADGroupMember `
                    -Identity "${ggsPrefix}_$($department.Value)_Managers" `
                    -Members $duplicateManager `
                    -Confirm:$false `
                    -ErrorAction SilentlyContinue

                Ensure-ADPrincipalGroupMembership `
                    -GroupName "${ggsPrefix}_$($department.Value)_Users" `
                    -MemberName $duplicateManager.SamAccountName
            }

            $existingDepartmentManagers = @($primaryManager)
        }

        if ($existingDepartmentManagers.Count -gt 0) {

            foreach ($managerObject in $existingDepartmentManagers) {

                Write-AmrlLog (
                    "[INFO] Reconciling manager: " +
                    $managerObject.SamAccountName +
                    " Department=" +
                    $department.Name
                )

                Set-ADUser `
                    -Identity $managerObject `
                    -Department $department.Name `
                    -Title "$($department.Name) Manager"

                Get-ADPrincipalGroupMembership $managerObject |
                Where-Object {
                    $_.Name -like "${ggsPrefix}_*_Users"
                } |
                ForEach-Object {

                    Write-AmrlLog (
                        "[INFO] Removing manager from user group: " +
                        $_.Name
                    )

                    Remove-ADGroupMember `
                        -Identity $_ `
                        -Members $managerObject `
                        -Confirm:$false `
                        -ErrorAction SilentlyContinue
                }

                Get-ADPrincipalGroupMembership $managerObject |
                Where-Object {
                    $_.Name -like "${ggsPrefix}_*_Managers" -and
                    $_.Name -ne "${ggsPrefix}_$($department.Value)_Managers"
                } |
                ForEach-Object {

                    Write-AmrlLog (
                        "[INFO] Removing manager from incorrect manager group: " +
                        $_.Name
                    )

                    Remove-ADGroupMember `
                        -Identity $_ `
                        -Members $managerObject `
                        -Confirm:$false `
                        -ErrorAction SilentlyContinue
                }

                Get-ADPrincipalGroupMembership $managerObject |
                Where-Object {
                    $_.Name -like "${ggsPrefix}_*_ALL" -and
                    $_.Name -ne "${ggsPrefix}_$($department.Value)_ALL"
                } |
                ForEach-Object {

                    Write-AmrlLog (
                        "[INFO] Removing manager from incorrect ALL group: " +
                        $_.Name
                    )

                    Remove-ADGroupMember `
                        -Identity $_ `
                        -Members $managerObject `
                        -Confirm:$false `
                        -ErrorAction SilentlyContinue
                }

                $managerSam = $managerObject.SamAccountName

                Ensure-ADPrincipalGroupMembership `
                    -GroupName "${ggsPrefix}_$($department.Value)_ALL" `
                    -MemberName $managerSam

                Ensure-ADPrincipalGroupMembership `
                    -GroupName "${ggsPrefix}_$($department.Value)_Managers" `
                    -MemberName $managerSam

                Write-AmrlLog (
                    "[INFO] Manager groups reconciled: " +
                    $managerSam
                )
            }
        }

# Bootstrap manager creation.
# Departments are expected to contain exactly
# one manager account. If no manager exists,
# a manager is created from the available
# CSV population source.

if ($existingDepartmentManagers.Count -eq 0) {

    Write-AmrlLog -Status Warning -Message (
        "No manager found in department: " +
        $department.Name +
        ". Creating manager."
    )

    if ($CSVNames.Count -eq 0) {
        throw "No more names available in names.csv"
    }

    $managerUser = $null
    $managerSam = $null

    while ($CSVNames.Count -gt 0) {

        $candidate = Get-Random -InputObject $CSVNames

        $candidateSam = Get-SamAccountName `
            -FirstName $candidate.FirstName `
            -LastName $candidate.LastName

        $candidateIndex = $CSVNames.IndexOf($candidate)

        if ($candidateIndex -ge 0) {
            $CSVNames.RemoveAt($candidateIndex)
        }

        $existingCandidate = Get-ADUser `
            -LDAPFilter "(sAMAccountName=$candidateSam)" `
            -ErrorAction SilentlyContinue

        if ($existingCandidate) {
            continue
        }

        $managerUser = $candidate
        $managerSam = $candidateSam
        break
    }

    if (-not $managerUser) {
        throw (
            "Unable to create manager for department " +
            $department.Name +
            ". No unique usernames remain."
        )
    }

    $managerUpn = "$managerSam@$DomainName"

    $managerObject = Ensure-ADUser `
        -SamAccountName $managerSam `
        -Path $departmentOU.DistinguishedName `
        -DisplayName "$($managerUser.FirstName) $($managerUser.LastName)" `
        -GivenName $managerUser.FirstName `
        -Surname $managerUser.LastName `
        -UserPrincipalName $managerUpn `
        -Department $department.Name `
        -Title "$($department.Name) Manager" `
        -Manager ""

    Ensure-ADPrincipalGroupMembership `
        -GroupName "${ggsPrefix}_$($department.Value)_ALL" `
        -MemberName $managerSam

    Ensure-ADPrincipalGroupMembership `
        -GroupName "${ggsPrefix}_$($department.Value)_Managers" `
        -MemberName $managerSam

    $existingDepartmentManagers = @($managerObject)

    $validatedManager = Get-ADUser `
        -Identity $managerObject `
        -Properties Department,Title,SamAccountName
    
    $managerGroupMember = Get-ADGroupMember `
        -Identity "${ggsPrefix}_$($department.Value)_Managers" `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.SamAccountName -eq $validatedManager.SamAccountName
    }

    if (
        $validatedManager.Department -ne $department.Name -or
        $validatedManager.Title -notlike '*Manager*' -or
        -not $managerGroupMember
    ) {
        throw (
            "Manager bootstrap validation failed. " +
            "Department=" + $department.Name +
            ", User=" + $validatedManager.SamAccountName +
            ", UserDepartment=" + $validatedManager.Department +
            ", Title=" + $validatedManager.Title
        )
    }

}

        # A departmental manager exists.
        # Remediate invalid reporting lines to the
        # department manager.

        $primaryManager = $existingDepartmentManagers |
            Select-Object -First 1

        Get-ADUser `
            -SearchBase $departmentOU.DistinguishedName `
            -Filter * `
            -Properties Title,Manager |
        Where-Object {
            $_.Title -notlike '*Manager*'
        } |
        ForEach-Object {

            # A departmental manager exists. Any user that is:
            # - unmanaged
            # - assigned to an invalid manager
            # - assigned to a manager in another department
            # should be assigned to the departmental manager.

            if (-not $_.Manager) {

                Write-AmrlLog (
                    "[INFO] Assigning departmental manager for " +
                    $_.SamAccountName +
                    " -> " +
                    $primaryManager.SamAccountName
                )

                Set-ADUser `
                    -Identity $_ `
                    -Manager $primaryManager.DistinguishedName
            }
            else {

                $currentManager = Get-ADUser `
                    -Identity $_.Manager `
                    -Properties Department `
                    -ErrorAction SilentlyContinue

                if (
                    -not $currentManager -or
                    $currentManager.Department -ne $department.Name
                ) {

                    Write-AmrlLog (
                        "[INFO] Reassigning manager for " +
                        $_.SamAccountName +
                        " -> " +
                        $primaryManager.SamAccountName
                    )

                    Set-ADUser `
                        -Identity $_ `
                        -Manager $primaryManager.DistinguishedName
                }
            }
        }

        $departmentInfo[$department.Name] = @{
            Department     = $department
            DepartmentOU   = $departmentOU
            ManagerObjects = $existingDepartmentManagers
        }
    }

# Validate that every department has exactly one
# manager before user population begins.

foreach ($departmentName in $departmentInfo.Keys) {

    $managerCount =
        $departmentInfo[$departmentName].ManagerObjects.Count

    if ($managerCount -ne 1) {

        throw (
            "Department manager validation failed. " +
            "Department=" + $departmentName +
            ", ManagerCount=" + $managerCount
        )
    }
}

    return $departmentInfo
}

function Get-DepartmentUserTargets {
    param(
        [hashtable]$DepartmentInfo,
        [int]$TargetUsersPerDepartment
    )

    $departmentTargets = @{}

    foreach ($departmentData in $DepartmentInfo.Values) {

        $department = $departmentData.Department
        $departmentOU = $departmentData.DepartmentOU
        $managerObjects = $departmentData.ManagerObjects

        # Managers are excluded from user counts.
        # UsersPerDepartment represents standard users
        # only and does not include manager accounts.

        $currentUserCount = (
            Get-ADUser `
                -Filter * `
                -SearchBase $departmentOU.DistinguishedName `
                -Properties Title `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Title -notlike '*Manager*'
            }
        ).Count

        $usersNeeded = [Math]::Max(
            0,
            ($TargetUsersPerDepartment - $currentUserCount)
        )

        Write-AmrlLog (
            "[i] Department $($department.Name): " +
            "$currentUserCount users present, " +
            "$usersNeeded users required"
        )

        $departmentTargets[$department.Name] = [PSCustomObject]@{
            Department     = $department
            DepartmentOU   = $departmentOU
            ManagerObjects = $managerObjects
            UsersNeeded    = $usersNeeded
        }
    }

    return $departmentTargets
}

# Existing-user repair.
# Responsibilities:
# - Department attribute remediation
# - Group membership remediation
# Reporting-line reconciliation is completed by
# Reconcile-DepartmentManagers() before this function runs.

function Repair-ExistingUsers {
    param(
        [hashtable]$DepartmentInfo,
        [object]$PopulationModel
    )

    $ggsPrefix = $PopulationModel.groupNaming.globalSecurityPrefix

    Write-AmrlLog "[i] Existing user remediation starting"

    foreach ($departmentData in $DepartmentInfo.Values) {

        $department = $departmentData.Department
        $departmentOU = $departmentData.DepartmentOU

        # Departments without managers are valid.

        Get-ADUser `
            -SearchBase $departmentOU.DistinguishedName `
            -Filter * `
            -Properties Title,Manager |

        ForEach-Object {

            $user = $_

            if ($user.Title -like '*Manager*') {

                Write-AmrlLog (
                    "[INFO] Skipping manager account: " +
                    $user.SamAccountName
                )
            }
            else {

                Write-AmrlLog (
                    "[INFO] Remediating user " +
                    $user.SamAccountName
                )

                # Department

                Set-ADUser `
                    -Identity $user `
                    -Department $department.Name

                # Remove bad *_Users groups

                Get-ADPrincipalGroupMembership $user |
                Where-Object {
                    $_.Name -like "${ggsPrefix}_*_Users" -and
                    $_.Name -ne "${ggsPrefix}_$($department.Value)_Users"
                } |
                ForEach-Object {

                    Remove-ADGroupMember `
                        -Identity $_ `
                        -Members $user `
                        -Confirm:$false `
                        -ErrorAction SilentlyContinue
                }

                # Remove bad *_Managers groups

                Get-ADPrincipalGroupMembership $user |
                Where-Object {
                    $_.Name -like "${ggsPrefix}_*_Managers"
                } |
                ForEach-Object {

                    Remove-ADGroupMember `
                        -Identity $_ `
                        -Members $user `
                        -Confirm:$false `
                        -ErrorAction SilentlyContinue
                }

                # Remove bad *_ALL groups

                Get-ADPrincipalGroupMembership $user |
                Where-Object {
                    $_.Name -like "${ggsPrefix}_*_ALL" -and
                    $_.Name -ne "${ggsPrefix}_$($department.Value)_ALL"
                } |
                ForEach-Object {

                    Remove-ADGroupMember `
                        -Identity $_ `
                        -Members $user `
                        -Confirm:$false `
                        -ErrorAction SilentlyContinue
                }

                # Add correct groups

                Ensure-ADPrincipalGroupMembership `
                    -GroupName "${ggsPrefix}_$($department.Value)_ALL" `
                    -MemberName $user.SamAccountName

                Ensure-ADPrincipalGroupMembership `
                    -GroupName "${ggsPrefix}_$($department.Value)_Users" `
                    -MemberName $user.SamAccountName
            }
        }
    }

    Write-AmrlLog "[i] Existing user remediation completed"
}

# Missing-user population.
# Each pass attempts to add one standard user to
# every department that has not yet reached its
# target population.
# Existing usernames are discarded and a new
# candidate is selected until a unique username
# is found or the CSV is exhausted.
# Population ends when:
# - All departments have reached target capacity.
# - No additional unique usernames are available.

function Populate-DepartmentUsers {
    param(
        [hashtable]$DepartmentTargets,
        [System.Collections.ArrayList]$CsvNames,
        [object]$ConnectedDomain,
        [object]$PopulationModel
    )

    $ggsPrefix = $PopulationModel.groupNaming.globalSecurityPrefix

    # Build an in-memory lookup of existing
    # sAMAccountNames to avoid repeated AD queries
    # during user generation.

    $existingSamAccounts = [System.Collections.Generic.HashSet[string]]::new()

    Get-ADUser -Filter * |
    Select-Object -ExpandProperty SamAccountName |
    ForEach-Object {
        $existingSamAccounts.Add($_.ToLower()) | Out-Null
    }

    foreach ($departmentData in $DepartmentTargets.Values) {

        Write-AmrlLog (
            "[i] " +
            $departmentData.Department.Name +
            ": UsersNeeded=" +
            $departmentData.UsersNeeded
        )
    }

    $stopPopulation = $false

    # Users are added round-robin across departments.
    # This allows balanced population when fewer
    # source names are available than requested.

    # Track successful user creation counts per
    # department. Progress is based on actual
    # accounts created rather than loop iterations.

    $createdUsers = @{}

    foreach ($departmentData in $DepartmentTargets.Values) {
        $createdUsers[$departmentData.Department.Name] = 0
    }

    while (-not $stopPopulation) {

        # Only process departments that have not
        # yet reached their target user count.

        $remainingDepartments = @(
            $DepartmentTargets.Values |
            Where-Object {
                $createdUsers[$_.Department.Name] -lt $_.UsersNeeded
            }
        )

        if ($remainingDepartments.Count -eq 0) {
            break
        }

        foreach ($departmentData in $remainingDepartments) {

            if ($CsvNames.Count -eq 0) {

                Write-AmrlLog -Status Warning -Message (
                    "No more names available in names.csv. " +
                    "User population stopped after available names were exhausted."
                )

                $stopPopulation = $true
                break
            }

            $department = $departmentData.Department
            $departmentOU = $departmentData.DepartmentOU
            $managerObjects = $departmentData.ManagerObjects

            # New users are assigned to the department's
            # primary manager if one exists.

            $managerObject = $managerObjects |
                Select-Object -First 1

            $managerDn = $null

            if ($managerObject) {
                $managerDn = $managerObject.DistinguishedName
            }

            $userRecord = $null
            $userSam = $null

            # Select a candidate username.
            # Existing usernames are discarded until
            # a unique username is found or the CSV
            # source is exhausted.

            while ($CsvNames.Count -gt 0) {

                $candidate = Get-Random -InputObject $CsvNames

                $candidateSam = Get-SamAccountName `
                    -FirstName $candidate.FirstName `
                    -LastName $candidate.LastName

                $null = $CsvNames.Remove($candidate)

                if ($existingSamAccounts.Contains($candidateSam)) {

                    continue
                }

                $userRecord = $candidate
                $userSam = $candidateSam
                break
            }

            if (-not $userRecord) {

                Write-AmrlLog -Status Warning -Message (
                    "No remaining unique usernames available."
                )

                $stopPopulation = $true
                break
            }

            $userUpn = "$userSam@$($ConnectedDomain.DNSRoot)"

            $userObject = Ensure-ADUser `
                -SamAccountName $userSam `
                -Path $departmentOU.DistinguishedName `
                -DisplayName "$($userRecord.FirstName) $($userRecord.LastName)" `
                -GivenName $userRecord.FirstName `
                -Surname $userRecord.LastName `
                -UserPrincipalName $userUpn `
                -Department $department.Name `
                -Manager $managerDn

            $existingSamAccounts.Add($userSam) | Out-Null

            $createdUsers[$department.Name]++

            $managerMembership = Get-ADPrincipalGroupMembership $userObject |
            Where-Object {
                $_.Name -like "${ggsPrefix}_*_Managers"
            }

            if ($managerMembership) {

                Write-AmrlLog (
                    "[INFO] User is already a department manager. " +
                    "Skipping user-group remediation: " +
                    $userObject.SamAccountName
                )

                continue
            }

            Ensure-ADPrincipalGroupMembership `
                -GroupName "${ggsPrefix}_$($department.Value)_ALL" `
                -MemberName $userSam

            Ensure-ADPrincipalGroupMembership `
                -GroupName "${ggsPrefix}_$($department.Value)_Users" `
                -MemberName $userSam

            Get-ADPrincipalGroupMembership $userObject |
            Where-Object {
                $_.Name -like "${ggsPrefix}_*_Users" -and
                $_.Name -ne "${ggsPrefix}_$($department.Value)_Users"
            } |
            ForEach-Object {

                Write-AmrlLog (
                    "[INFO] Removing user from incorrect user group: " +
                    $_.Name
                )

                Remove-ADGroupMember `
                    -Identity $_ `
                    -Members $userObject `
                    -Confirm:$false `
                    -ErrorAction SilentlyContinue
                    
            }
        }
    }
}

# 7. Windows LAPS directory prerequisites
# Extend schema if absent, then apply self/read permissions to the two modeled workload OUs.
# This requires schema/ACL permissions; it prepares AD rather than setting endpoint LAPS passwords.
function Ensure-LapsConfiguration {
    param(
        [object]$DirectoryModel
    )

    $windowsAdminsGroup = (
        "$($DirectoryModel.groupNaming.globalSecurityPrefix)_" +
        $DirectoryModel.platformAdminGroups.windowsAdmins
    )

    $lapsSchema = Get-ADObject `
        -SearchBase (Get-ADRootDSE).SchemaNamingContext `
        -LDAPFilter "(name=ms-LAPS-Password)" `
        -ErrorAction SilentlyContinue

    if (-not $lapsSchema) {

        Write-AmrlLog (
            "[+] Windows LAPS schema not detected. " +
            "Extending schema."
        )

        Update-LapsADSchema -Confirm:$false
    }
    else {

        Write-AmrlLog (
            "[=] Windows LAPS schema already present."
        )
    }

    $domain = Get-ADDomain

    $serversOuDn = (
        "OU=Servers," +
        "OU=Computers," +
        "OU=$($DirectoryModel.rootOuName)," +
        $domain.DistinguishedName
    )

    $clientsOuDn = (
        "OU=Clients," +
        "OU=Computers," +
        "OU=$($DirectoryModel.rootOuName)," +
        $domain.DistinguishedName
    )

    $qualifiedWindowsAdmins = (
        $domain.NetBIOSName +
        "\" +
        $windowsAdminsGroup
    )

    Write-AmrlLog (
        "[+] Configuring Windows LAPS self permissions: " +
        "Servers OU"
    )

    try {

        Set-LapsADComputerSelfPermission `
            -Identity $serversOuDn

    }
    catch {

        throw (
            "Failed to configure Windows LAPS self permissions " +
            "for Servers OU '$serversOuDn': " +
            "$($_.Exception.Message)"
        )

    }

    Write-AmrlLog (
        "[+] Configuring Windows LAPS self permissions: " +
        "Clients OU"
    )

    try {

        Set-LapsADComputerSelfPermission `
            -Identity $clientsOuDn

    }
    catch {

        throw (
            "Failed to configure Windows LAPS self permissions " +
            "for Clients OU '$clientsOuDn': " +
            "$($_.Exception.Message)"
        )

    }

    Write-AmrlLog (
        "[+] Configuring Windows LAPS read permissions: " +
        $qualifiedWindowsAdmins
    )

    try {

        Set-LapsADReadPasswordPermission `
            -Identity $serversOuDn `
            -AllowedPrincipals $qualifiedWindowsAdmins

    }
    catch {

        throw (
            "Failed to configure Windows LAPS read permissions " +
            "for Servers OU '$serversOuDn' and principal " +
            "'$qualifiedWindowsAdmins': " +
            "$($_.Exception.Message)"
        )

    }

    try {

        Set-LapsADReadPasswordPermission `
            -Identity $clientsOuDn `
            -AllowedPrincipals $qualifiedWindowsAdmins

    }
    catch {

        throw (
            "Failed to configure Windows LAPS read permissions " +
            "for Clients OU '$clientsOuDn' and principal " +
            "'$qualifiedWindowsAdmins': " +
            "$($_.Exception.Message)"
        )

    }
}

# 8. Execute the population workflow in dependency order
# The script is designed to be idempotent and
# may be executed repeatedly. Existing objects
# are reconciled where possible and missing
# objects are created.
# Execution order:
# 1. Validate AD connectivity
# 2. Ensure directory and department OUs
# 3. Ensure security groups, LAPS directory permissions, and group nesting
# 4. Reconcile department managers and calculate standard-user targets
# 5. Repair existing users without regenerating their passwords
# 6. Populate missing users, remove temporary CSV data, and summarize actions

Write-AmrlLog "[INFO] Waiting for Active Directory availability"

$currentDomain = $null

for ($attempt = 1; $attempt -le 30; $attempt++) {

    try {

        $currentDomain = Get-ADDomain -ErrorAction Stop

        Write-AmrlLog (
            "[INFO] Connected to domain: " +
            $currentDomain.DNSRoot
        )

        break
    }
    catch {

        Write-AmrlLog (
            "[INFO] Attempt $attempt of 30 - " +
            "Active Directory not ready yet"
        )

        Start-Sleep -Seconds 20
    }
}

if ($null -eq $currentDomain) {

    throw (
        "Active Directory did not become available " +
        "within the expected time."
    )
}

# Kerberos needs HTTP service identities for WAC/WinRM connections by short name or FQDN.
# Promotion creates the DC accounts first; population then repairs these account attributes
# on both fresh and retained DCs. This does not open a port or configure a WinRM listener.
function Ensure-DomainControllerHttpSpns {
    param([string[]]$ComputerNames)

    if ($currentDomain.DNSRoot -ine $DomainName.TrimEnd('.')) {
        throw "The current domain '$($currentDomain.DNSRoot)' does not match '$DomainName'."
    }

    $setSpnPath = Join-Path $env:SystemRoot 'System32\setspn.exe'
    if (-not (Test-Path -LiteralPath $setSpnPath)) {
        throw "setspn.exe was not found at '$setSpnPath'."
    }

    foreach ($computerName in $ComputerNames) {
        $computer = Get-ADComputer -Identity $computerName -Properties userAccountControl -ErrorAction Stop
        # SERVER_TRUST_ACCOUNT (0x2000) distinguishes DC accounts from ordinary members.
        if (($computer.userAccountControl -band 8192) -eq 0) {
            throw "Computer '$computerName' is not a domain controller."
        }

        # Use the live NetBIOS domain, which need not equal the first label of its DNS name.
        $computerAccount = "$($currentDomain.NetBIOSName)\$computerName`$"
        $registeredOutput = & $setSpnPath -L $computerAccount 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to list SPNs for '$computerAccount': $($registeredOutput -join ' ')"
        }
        $registeredSpns = @($registeredOutput | ForEach-Object { $_.ToString().Trim() })

        foreach ($spn in @("HTTP/$computerName", "HTTP/$computerName.$($currentDomain.DNSRoot)")) {
            if ($registeredSpns -icontains $spn) {
                Write-AmrlLog "[Verified] DC HTTP SPN is registered: $spn"
                continue
            }

            # -S checks for duplicate ownership; do not steal an SPN from another account.
            $registrationOutput = & $setSpnPath -S $spn $computerAccount 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to register DC HTTP SPN '$spn': $($registrationOutput -join ' ')"
            }
            Write-AmrlLog "[Updated] Registered DC HTTP SPN: $spn"
        }
    }
}

# The stage supplies modeled DCs only; this is not discovery or repair of unrelated AD hosts.
$domainControllerNames = $DomainControllerNamesJson | ConvertFrom-Json
Ensure-DomainControllerHttpSpns -ComputerNames $domainControllerNames

$model = $DirectoryModel | ConvertFrom-Json

$usersCsvPath = 'C:\Windows\Temp\names.csv'
$CSVNames = Initialize-NamesCsvRecords `
    -InputNamesCsvContent $NamesCsvContent `
    -CsvPath $usersCsvPath

Write-AmrlLog (
    "[INFO] CSV records loaded: " +
    $CSVNames.Count
)

if ($CSVNames.Count -eq 0) {
    throw "No records were loaded from NamesCsvContent."
}

$domainDN = (Get-ADRootDSE).rootDomainNamingContext

$departments = Get-SelectedDepartments `
    -SysAdminDepartmentJson $SysAdminDepartmentJson `
    -AdditionalDepartmentsJson $AdditionalDepartmentsJson `
    -InputDepartmentCount $DepartmentCount

$rootOUdn = Ensure-DirectoryOuStructure `
    -PopulationModel $model `
    -DomainDn $domainDN

$usersOU = Ensure-DepartmentOUs `
    -SelectedDepartments $departments `
    -RootOuDn $rootOUdn `
    -PreventOuDeletion $model.preventOuDeletion `
    -PopulationModel $model

Ensure-DepartmentSecurityGroups `
    -SelectedDepartments $departments `
    -RootOuDn $rootOUdn `
    -PopulationModel $model `
    -EnableFileServices $fileServicesEnabled

Ensure-LapsConfiguration `
    -DirectoryModel $model

Ensure-DepartmentGroupNesting `
    -SelectedDepartments $departments `
    -PopulationModel $model `
    -EnableFileServices $fileServicesEnabled

Write-AmrlLog "[i] User generation starting"

if ([string]::IsNullOrWhiteSpace($NamesCsvContent)) {
    throw "NamesCsvContent parameter is empty."
}

$requiredUsers =
    $DepartmentCount * ($UsersPerDepartment + 1)

if ($CSVNames.Count -lt $requiredUsers) {

    Write-AmrlLog -Status Warning -Message (
        "names.csv contains $($CSVNames.Count) names " +
        "but deployment requires $requiredUsers accounts. " +
        "Users will be distributed as evenly as possible."
    )
}

$departmentInfo = Reconcile-DepartmentManagers `
    -SelectedDepartments $departments `
    -UsersOu $usersOU `
    -CsvNames $CSVNames `
    -DomainName $DomainName `
    -PopulationModel $model

$departmentTargets = Get-DepartmentUserTargets `
    -DepartmentInfo $departmentInfo `
    -TargetUsersPerDepartment $UsersPerDepartment

Repair-ExistingUsers `
    -DepartmentInfo $departmentInfo `
    -PopulationModel $model

Populate-DepartmentUsers `
    -DepartmentTargets $departmentTargets `
    -CsvNames $CSVNames `
    -ConnectedDomain $currentDomain `
    -PopulationModel $model

Remove-Item `
    $usersCsvPath `
    -Force `
    -ErrorAction SilentlyContinue

Write-AmrlLog '[Info] Temporary names.csv cleanup was requested.'
Write-AmrlLog (
    "[Info] Directory population summary: Info=$($script:logCounts.Info); Created=$($script:logCounts.Created); Verified=$($script:logCounts.Verified); Updated=$($script:logCounts.Updated); Removed=$($script:logCounts.Removed); Skipped=$($script:logCounts.Skipped); Warnings=$($script:logCounts.Warning); Errors=$($script:logCounts.Error)."
)
Write-AmrlLog '[Info] Directory population completed.'

Stop-Transcript