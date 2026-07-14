<#
Populate AMRL AD objects (OU/group/share/user) on dc01.
Derived from Set-DummyAD and adapted for idempotent Run Command execution.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DomainName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$NamesCsvContent,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientAdminPassword,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DepartmentsJson,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 1000)]
    [int]$DepartmentCount,

    [Parameter(Mandatory = $true)]
    [ValidateRange(0, 10000)]
    [int]$UsersPerDepartment
)

Write-Host "Starting AMRL Directory Population"
Write-Host "DomainName = $DomainName"

Import-Module ActiveDirectory -ErrorAction Stop

# Helper functions: idempotent Ensure-* operations.

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
        Write-Host "[=] OU already exists: $Name"
        return $existingOu
    }

    Write-Host "[+] Creating OU: $Name"

    New-ADOrganizationalUnit `
        -Name $Name `
        -Path $Path `
        -ProtectedFromAccidentalDeletion $ProtectedFromAccidentalDeletion

    return Get-ADOrganizationalUnit `
        -LDAPFilter "(ou=$Name)" `
        -SearchBase $Path `
        -SearchScope OneLevel
}

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
        Write-Host "[=] Group already exists: $Name"
        return $existingGroup
    }

    Write-Host "[+] Creating Group: $Name"

    New-ADGroup `
        -Name $Name `
        -GroupCategory $GroupCategory `
        -GroupScope $GroupScope `
        -Path $Path

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
        Write-Host "[=] Membership already exists: $MemberName -> $GroupName"
        return
    }

    Write-Host "[+] Adding membership: $MemberName -> $GroupName"

    Add-ADGroupMember `
        -Identity $GroupName `
        -Members $MemberName
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
        Write-Host "[=] Membership already exists: $MemberName -> $GroupName"
        return
    }

    Write-Host "[+] Adding membership: $MemberName -> $GroupName"

    Add-ADGroupMember `
        -Identity $GroupName `
        -Members $MemberName
}

# User management: create missing users and reconcile selected attributes.

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
        [SecureString]$Password,
        [string]$Manager
    )

    $existingUser = Get-ADUser `
        -LDAPFilter "(sAMAccountName=$SamAccountName)" `
        -ErrorAction SilentlyContinue

    # Existing users are updated rather than recreated.
    # Selected attributes such as Department, Title
    # and Manager are reconciled during re-execution.
    if ($existingUser) {

        Write-Host "[=] User already exists: $SamAccountName"

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

        if (
            $Manager -and
            $existingUserFull.Title -notlike '*Manager*'
        ) {
            Set-ADUser `
                -Identity $existingUser `
                -Manager $Manager
        }

        return (
            Get-ADUser `
                -Identity $existingUser `
                -Properties *
        )
    }

    Write-Host "[+] Creating User: $SamAccountName"

    $params = @{
        Name                  = $DisplayName
        DisplayName           = $DisplayName
        GivenName             = $GivenName
        Surname               = $Surname
        SamAccountName        = $SamAccountName
        UserPrincipalName     = $UserPrincipalName
        EmailAddress          = $UserPrincipalName
        Path                  = $Path
        AccountPassword       = $Password
        ChangePasswordAtLogon = $false
        PasswordNeverExpires  = $true
        Enabled               = $true
        Department            = $Department
    }

    if ($Title) {
        $params.Title = $Title
    }

    New-ADUser @params

    $newUser = Get-ADUser `
        -LDAPFilter "(sAMAccountName=$SamAccountName)"

    if ($Manager) {
        Set-ADUser `
            -Identity $newUser `
            -Manager $Manager
    }

    return (Get-ADUser `
        -Identity $newUser `
        -Properties *)
}

function Get-DirectoryPopulationModel {
    return (@'
{
    "PreventOUDeletion":false,
    "RootOUName":"_ROOT",
    "CustomOUs":[
        "Computers",
        "Computers/Servers",
        "Computers/Clients",
        "Groups",
        "Groups/GGS",
        "Groups/DLGS",
        "Users",
        "Users/Disabled"
    ],
    "RootShareName":"Shares",
    "RootSharePath":"C:\\Shares"
}
'@ | ConvertFrom-Json)
}

function Get-SelectedDepartments {
    param(
        [string]$InputDepartmentsJson,
        [int]$InputDepartmentCount
    )

    $allDepartments = (
        $InputDepartmentsJson |
        ConvertFrom-Json
    ).PSObject.Properties

    return ($allDepartments | Select-Object -First $InputDepartmentCount)
}

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

function Invoke-Phase1OuStructure {
    param(
        [object]$PopulationModel,
        [string]$DomainDn
    )

    Write-Host "[i] OU generation starting"

    $rootOU = Ensure-OrganizationalUnit `
        -Name $PopulationModel.RootOUName `
        -Path $DomainDn `
        -ProtectedFromAccidentalDeletion $PopulationModel.PreventOUDeletion

    $rootOUdn = $rootOU.DistinguishedName

    foreach ($ouName in $PopulationModel.CustomOUs) {

        if ($ouName -notlike "*/*") {

            Ensure-OrganizationalUnit `
                -Name $ouName `
                -Path $rootOUdn `
                -ProtectedFromAccidentalDeletion $PopulationModel.PreventOUDeletion |
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
                -ProtectedFromAccidentalDeletion $PopulationModel.PreventOUDeletion |
                Out-Null
        }
    }

    Write-Host "[i] OU generation completed"

    return $rootOUdn
}

function Invoke-Phase2DepartmentOus {
    param(
        [object[]]$SelectedDepartments,
        [string]$RootOuDn,
        [bool]$PreventOuDeletion
    )

    Write-Host "[i] Department OU generation starting"

    $usersOU = Get-ADOrganizationalUnit `
        -LDAPFilter "(ou=Users)" `
        -SearchBase $RootOuDn `
        -ErrorAction Stop

    foreach ($department in $SelectedDepartments) {

        Ensure-OrganizationalUnit `
            -Name $department.Name `
            -Path $usersOU.DistinguishedName `
            -ProtectedFromAccidentalDeletion $PreventOuDeletion |
            Out-Null
    }

    Write-Host "[i] Department OU generation completed"

    return $usersOU
}

function Invoke-Phase3DepartmentSecurityGroups {
    param(
        [object[]]$SelectedDepartments,
        [string]$RootOuDn
    )

    Write-Host "[i] Department security group generation starting"

    $groupsOU = Get-ADOrganizationalUnit `
        -LDAPFilter "(ou=Groups)" `
        -SearchBase $RootOuDn `
        -ErrorAction Stop

    $ggsOU = Get-ADOrganizationalUnit `
        -LDAPFilter "(ou=GGS)" `
        -SearchBase $groupsOU.DistinguishedName `
        -ErrorAction Stop

    $dlgsOU = Get-ADOrganizationalUnit `
        -LDAPFilter "(ou=DLGS)" `
        -SearchBase $groupsOU.DistinguishedName `
        -ErrorAction Stop

    if (-not $ggsOU -or [string]::IsNullOrWhiteSpace($ggsOU.DistinguishedName)) {
        throw "Unable to resolve GGS OU under $($groupsOU.DistinguishedName)."
    }

    if (-not $dlgsOU -or [string]::IsNullOrWhiteSpace($dlgsOU.DistinguishedName)) {
        throw "Unable to resolve DLGS OU under $($groupsOU.DistinguishedName)."
    }

    foreach ($department in $SelectedDepartments) {

        $code = $department.Value

        Ensure-ADGroup `
            -Name "GGS_${code}_ALL" `
            -Path $ggsOU.DistinguishedName `
            -GroupCategory Security `
            -GroupScope Global

        Ensure-ADGroup `
            -Name "GGS_${code}_Managers" `
            -Path $ggsOU.DistinguishedName `
            -GroupCategory Security `
            -GroupScope Global

        Ensure-ADGroup `
            -Name "GGS_${code}_Users" `
            -Path $ggsOU.DistinguishedName `
            -GroupCategory Security `
            -GroupScope Global

        Ensure-ADGroup `
            -Name "DLGS_${code}_Share_RW" `
            -Path $dlgsOU.DistinguishedName `
            -GroupCategory Security `
            -GroupScope DomainLocal

        Ensure-ADGroup `
            -Name "DLGS_${code}_Share_RO" `
            -Path $dlgsOU.DistinguishedName `
            -GroupCategory Security `
            -GroupScope DomainLocal
    }

    Write-Host "[i] Department security group generation completed"
}

function Invoke-Phase4DepartmentGroupNesting {
    param(
        [object[]]$SelectedDepartments
    )

    Write-Host "[i] Department group nesting starting"

    foreach ($department in $SelectedDepartments) {

        $code = $department.Value

        Ensure-ADGroupMember `
            -GroupName "DLGS_${code}_Share_RW" `
            -MemberName "GGS_${code}_Managers"

        Ensure-ADGroupMember `
            -GroupName "DLGS_${code}_Share_RO" `
            -MemberName "GGS_${code}_Users"
    }

    Write-Host "[i] Department group nesting completed"
}

function Invoke-Phase5DepartmentShares {
    param(
        [object[]]$SelectedDepartments,
        [object]$PopulationModel
    )

    Write-Host "[i] Root share creation starting"

    $rootSharePath = $PopulationModel.RootSharePath

    if (-not (Test-Path $rootSharePath)) {

        New-Item `
            -Path $rootSharePath `
            -ItemType Directory `
            -Force | Out-Null

        Write-Host "[+] Created $rootSharePath"
    }
    else {

        Write-Host "[=] Root share already exists: $rootSharePath"
    }

    Write-Host "[i] Root share creation completed"

    Write-Host "[i] Root share ACL configuration starting"

    icacls $rootSharePath /inheritance:d | Out-Null

    $fACLs = Get-Acl $rootSharePath

    foreach ($rule in $fACLs.Access) {

        if ($rule.IdentityReference -like "*Users") {

            $fACLs.RemoveAccessRuleAll($rule) | Out-Null
        }
    }

    Set-Acl `
        -Path $rootSharePath `
        -AclObject $fACLs

    Write-Host "[i] Root share ACL configuration completed"

    Write-Host "[i] Department share generation starting"

    foreach ($department in $SelectedDepartments) {

        $code = $department.Value

        $departmentSharePath = Join-Path `
            -Path $PopulationModel.RootSharePath `
            -ChildPath $department.Name

        if (-not (Test-Path $departmentSharePath)) {

            New-Item `
                -Path $departmentSharePath `
                -ItemType Directory `
                -Force | Out-Null

            Write-Host "[+] Created share directory: $departmentSharePath"
        }
        else {

            Write-Host "[=] Share directory already exists: $departmentSharePath"
        }

        if (-not (Get-SmbShare -Name $code -ErrorAction SilentlyContinue)) {

            New-SmbShare `
                -Name $code `
                -Path $departmentSharePath | Out-Null

            Grant-SmbShareAccess `
                -Name $code `
                -AccountName 'Everyone' `
                -AccessRight Full `
                -Force | Out-Null

            Write-Host "[+] Created SMB share: $code"
        }
        else {

            Write-Host "[=] SMB share already exists: $code"
        }

        $dirACL = Get-Acl $departmentSharePath

        $acrw = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "DLGS_${code}_Share_RW",
            "Modify",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )

        $acro = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "DLGS_${code}_Share_RO",
            "ReadAndExecute",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )

        $dirACL.SetAccessRule($acrw)
        $dirACL.SetAccessRule($acro)

        Set-Acl `
            -Path $departmentSharePath `
            -AclObject $dirACL

        Write-Host "[+] Applied NTFS permissions: $department.Name"
    }

    Write-Host "[i] Department share generation completed"
}

#
# Manager reconciliation phase.
#
# AMRL treats OU placement as the authoritative
# source of departmental ownership.
#
# Existing managers are remediated to match the
# OU in which they currently reside.
#
# Reconciliation includes:
# - Department attribute
# - Title
# - departmental ALL groups
# - departmental Manager groups
#
# A replacement manager is created only when a
# departmental OU contains no manager accounts.
#
function Get-DepartmentManagerInfo {
    param(
        [object[]]$SelectedDepartments,
        [object]$UsersOu,
        [System.Collections.ArrayList]$CsvNames,
        [object]$ConnectedDomain,
        [SecureString]$Password
    )

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

        $managerObject = $null

        if ($existingDepartmentManagers.Count -gt 0) {

            foreach ($managerObject in $existingDepartmentManagers) {

                Set-ADUser `
                    -Identity $managerObject `
                    -Department $department.Name `
                    -Title "$($department.Name) Manager"

                Get-ADPrincipalGroupMembership $managerObject |
                Where-Object {
                    $_.Name -like 'GGS_*_Users'
                } |
                ForEach-Object {

                    Write-Host (
                        "[INFO] Removing manager from user group: " +
                        $_.Name
                    )

                    Remove-ADGroupMember `
                        -Identity $_ `
                        -Members $managerObject `
                        -Confirm:$false
                }

                Get-ADPrincipalGroupMembership $managerObject |
                Where-Object {
                    $_.Name -like 'GGS_*_Managers' -and
                    $_.Name -ne "GGS_$($department.Value)_Managers"
                } |
                ForEach-Object {

                    Write-Host (
                        "[INFO] Removing manager from incorrect manager group: " +
                        $_.Name
                    )

                    Remove-ADGroupMember `
                        -Identity $_ `
                        -Members $managerObject `
                        -Confirm:$false
                }

                Get-ADPrincipalGroupMembership $managerObject |
                Where-Object {
                    $_.Name -like 'GGS_*_ALL' -and
                    $_.Name -ne "GGS_$($department.Value)_ALL"
                } |
                ForEach-Object {

                    Write-Host (
                        "[INFO] Removing manager from incorrect ALL group: " +
                        $_.Name
                    )

                    Remove-ADGroupMember `
                        -Identity $_ `
                        -Members $managerObject `
                        -Confirm:$false
                }

                $managerSam = $managerObject.SamAccountName

                Ensure-ADPrincipalGroupMembership `
                    -GroupName "GGS_$($department.Value)_ALL" `
                    -MemberName $managerSam

                Ensure-ADPrincipalGroupMembership `
                    -GroupName "GGS_$($department.Value)_Managers" `
                    -MemberName $managerSam
            }
        }

        #
        # Multiple managers per department are allowed.
        #
        # A replacement manager is created only when no
        # managers are present within the departmental OU.
        #

        if ($existingDepartmentManagers.Count -eq 0) {

            if ($CsvNames.Count -eq 0) {
                Write-Warning (
                    "No more names available in names.csv. " +
                    "Manager population stopped after available names were exhausted."
                )

                break
            }

            $managerUser = Get-Random -InputObject $CsvNames
            $null = $CsvNames.Remove($managerUser)

            $managerSam = (
                $managerUser.FirstName +
                "." +
                ($managerUser.LastName -replace '\s+', '')
            ).ToLower()

            $managerUpn = "$managerSam@$($ConnectedDomain.DNSRoot)"

            try {

                $managerObject = Ensure-ADUser `
                    -SamAccountName $managerSam `
                    -Path $departmentOU.DistinguishedName `
                    -DisplayName "$($managerUser.FirstName) $($managerUser.LastName)" `
                    -GivenName $managerUser.FirstName `
                    -Surname $managerUser.LastName `
                    -UserPrincipalName $managerUpn `
                    -Department $department.Name `
                    -Title "$($department.Name) Manager" `
                    -Password $Password `
                    -Manager ""

            }
            catch {
                Write-Host "[ERROR] Manager creation failed"
                Write-Host $_.Exception.Message
                throw
            }
        }

        if ($existingDepartmentManagers.Count -eq 0) {
            $existingDepartmentManagers = @($managerObject)
        }

        #
        # Reconcile manager assignments for standard users.
        #
        # AMRL treats departmental OU placement as the
        # authoritative source of reporting structure.
        #
        # All non-manager users within a departmental OU
        # are assigned to the first available manager
        # discovered in that department.
        #

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

            if ($_.Manager -ne $primaryManager.DistinguishedName) {

                Write-Host (
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

        $departmentInfo[$department.Name] = @{
            Department     = $department
            DepartmentOU   = $departmentOU
            ManagerObjects = $existingDepartmentManagers
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

        #
        # Managers are excluded from user counts.
        #
        # UsersPerDepartment represents standard users
        # only and does not include manager accounts.
        #

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

        Write-Host (
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

function Invoke-Phase7RoundRobinUserPopulation {
    param(
        [hashtable]$DepartmentTargets,
        [System.Collections.ArrayList]$CsvNames,
        [object]$ConnectedDomain,
        [SecureString]$Password
    )

    $maxUsersNeeded = (
        $DepartmentTargets.Values |
        Measure-Object UsersNeeded -Maximum
    ).Maximum

    Write-Host "[i] Maximum users required by a department: $maxUsersNeeded"

    foreach ($departmentData in $DepartmentTargets.Values) {

        Write-Host (
            "[i] " +
            $departmentData.Department.Name +
            ": UsersNeeded=" +
            $departmentData.UsersNeeded
        )
    }

    $stopPopulation = $false

    #
    # Users are added round-robin across departments.
    #
    # This allows balanced population when fewer
    # source names are available than requested.
    #

    for ($i = 0; $i -lt $maxUsersNeeded; $i++) {

        if ($stopPopulation) {
            break
        }

        foreach ($departmentData in $DepartmentTargets.Values) {

            if ($departmentData.UsersNeeded -le $i) {
                continue
            }

            if ($CsvNames.Count -eq 0) {

                Write-Warning (
                    "No more names available in names.csv. " +
                    "User population stopped after available names were exhausted."
                )

                $stopPopulation = $true
                break
            }

            $department = $departmentData.Department
            $departmentOU = $departmentData.DepartmentOU
            $managerObjects = $departmentData.ManagerObjects

            $managerObject = $managerObjects |
                Select-Object -First 1

            $userRecord = Get-Random -InputObject $CsvNames
            $null = $CsvNames.Remove($userRecord)

            $userSam = (
                $userRecord.FirstName +
                "." +
                ($userRecord.LastName -replace '\s+', '')
            ).ToLower()

            $userUpn = "$userSam@$($ConnectedDomain.DNSRoot)"

            $userObject = Ensure-ADUser `
                -SamAccountName $userSam `
                -Path $departmentOU.DistinguishedName `
                -DisplayName "$($userRecord.FirstName) $($userRecord.LastName)" `
                -GivenName $userRecord.FirstName `
                -Surname $userRecord.LastName `
                -UserPrincipalName $userUpn `
                -Department $department.Name `
                -Password $Password `
                -Manager $managerObject.DistinguishedName

            $managerMembership = Get-ADPrincipalGroupMembership $userObject |
            Where-Object {
                $_.Name -like 'GGS_*_Managers'
            }

            if ($managerMembership) {

                Write-Host (
                    "[INFO] User is already a department manager. " +
                    "Skipping user-group remediation: " +
                    $userObject.SamAccountName
                )

                continue
            }

            Ensure-ADPrincipalGroupMembership `
                -GroupName "GGS_$($department.Value)_ALL" `
                -MemberName $userSam

            Ensure-ADPrincipalGroupMembership `
                -GroupName "GGS_$($department.Value)_Users" `
                -MemberName $userSam

            Get-ADPrincipalGroupMembership $userObject |
            Where-Object {
                $_.Name -like 'GGS_*_Users' -and
                $_.Name -ne "GGS_$($department.Value)_Users"
            } |
            ForEach-Object {

                Write-Host (
                    "[INFO] Removing user from incorrect user group: " +
                    $_.Name
                )

                Remove-ADGroupMember `
                    -Identity $_ `
                    -Members $userObject `
                    -Confirm:$false
            }
        }
    }
}

try {
    $currentDomain = Get-ADDomain -ErrorAction Stop

    Write-Host "Connected to domain: $($currentDomain.DNSRoot)"
}
catch {
    Write-Error "Unable to access Active Directory"
    throw
}

$model = Get-DirectoryPopulationModel
$usersCsvPath = 'C:\Windows\Temp\names.csv'
$CSVNames = Initialize-NamesCsvRecords `
    -InputNamesCsvContent $NamesCsvContent `
    -CsvPath $usersCsvPath

$domainDN = (Get-ADRootDSE).rootDomainNamingContext
$departments = Get-SelectedDepartments `
    -InputDepartmentsJson $DepartmentsJson `
    -InputDepartmentCount $DepartmentCount

$rootOUdn = Invoke-Phase1OuStructure `
    -PopulationModel $model `
    -DomainDn $domainDN

$usersOU = Invoke-Phase2DepartmentOus `
    -SelectedDepartments $departments `
    -RootOuDn $rootOUdn `
    -PreventOuDeletion $model.PreventOUDeletion

Invoke-Phase3DepartmentSecurityGroups `
    -SelectedDepartments $departments `
    -RootOuDn $rootOUdn

Invoke-Phase4DepartmentGroupNesting `
    -SelectedDepartments $departments

Invoke-Phase5DepartmentShares `
    -SelectedDepartments $departments `
    -PopulationModel $model

Write-Host "[i] User generation starting"

$password = ConvertTo-SecureString `
    $ClientAdminPassword `
    -AsPlainText `
    -Force

$requiredUsers =
    $DepartmentCount * ($UsersPerDepartment + 1)

if ($CSVNames.Count -lt $requiredUsers) {

    Write-Warning (
        "names.csv contains $($CSVNames.Count) names " +
        "but deployment requires $requiredUsers accounts. " +
        "Users will be distributed as evenly as possible."
    )
}

$departmentInfo = Get-DepartmentManagerInfo `
    -SelectedDepartments $departments `
    -UsersOu $usersOU `
    -CsvNames $CSVNames `
    -ConnectedDomain $currentDomain `
    -Password $password

$departmentTargets = Get-DepartmentUserTargets `
    -DepartmentInfo $departmentInfo `
    -TargetUsersPerDepartment $UsersPerDepartment

Invoke-Phase7RoundRobinUserPopulation `
    -DepartmentTargets $departmentTargets `
    -CsvNames $CSVNames `
    -ConnectedDomain $currentDomain `
    -Password $password

Write-Host "[i] User generation completed"

Write-Host "Directory population completed"

# TODO:
# Future AMRL release:
# Move departmental shares to dedicated file servers
# rather than hosting on domain controllers.