<#
This script contains logic derived from and inspired by:

Set-DummyAD
https://github.com/BOAScripts/Set-DummyAD

Copyright (c) BOAScripts
Licensed under the MIT License.

Adapted and integrated for AMRL.

AMRL Deviations:
- Executed through Azure VM Run Command.
- Embedded via Bicep loadTextContent().
- names.csv delivered through Run Command parameters.
- Idempotent object creation implemented.
- Existing users are updated where appropriate.
- NTFS permission handling uses RemoveAccessRuleAll().
- Manager titles added for easier identification.

Directory population logic derived from Set-DummyAD.
#>

param(
    [string]$DomainName,
    [string]$NamesCsvContent,
    [string]$ClientAdminPassword,
    [string]$DepartmentsJson,
    [int]$DepartmentCount,
    [int]$UsersPerDepartment
)

Write-Host "Starting AMRL Directory Population"
Write-Host "DomainName = $DomainName"

Import-Module ActiveDirectory -ErrorAction Stop

# ------------------------------------------------------------
# Helper Functions
#
# AMRL uses Ensure-* helper functions to make directory
# population idempotent. Re-running stage=identity should
# repair missing objects and attributes rather than fail.
#
# This is an AMRL enhancement and not part of the original
# Set-DummyAD implementation.
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# User Management
#
# AMRL deviation from Set-DummyAD:
# Existing users are updated where practical to allow
# safe re-execution of stage=identity.
#
# Set-DummyAD primarily creates users.
# AMRL creates missing users and remediates selected
# attributes on existing users.
# ------------------------------------------------------------

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

        $updateParams = @{
            Identity   = $existingUser
            Department = $Department
        }

        if ($Title) {
            $updateParams.Title = $Title
        }

        Set-ADUser @updateParams

        if ($Manager) {
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

try {
    $currentDomain = Get-ADDomain -ErrorAction Stop

    Write-Host "Connected to domain: $($currentDomain.DNSRoot)"
}
catch {
    Write-Error "Unable to access Active Directory"
    throw
}

# ------------------------------------------------------------
# Directory Population Model
#
# Derived from the Set-DummyAD model.json structure.
#
# AMRL currently embeds the model directly into the script.
# Future releases may externalise configuration if needed.
# ------------------------------------------------------------

$model = @'
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
'@ | ConvertFrom-Json

# ------------------------------------------------------------
# User Name Source
#
# AMRL deviation from Set-DummyAD:
#
# The original project reads names.csv directly from disk.
#
# AMRL delivers names.csv through VM Run Command parameters,
# writes it locally, and then processes it using the original
# Set-DummyAD workflow.
#
# This avoids:
# - GitHub runtime downloads
# - Storage Accounts
# - SAS tokens
# - Custom Script Extensions
# ------------------------------------------------------------

$usersCsvPath = 'C:\Windows\Temp\names.csv'

Set-Content `
    -Path $usersCsvPath `
    -Value $NamesCsvContent `
    -Force

$CSVNames = [System.Collections.ArrayList]@(
    Get-Content $usersCsvPath |
    ConvertFrom-Csv -Delimiter ';'
)

$domainDN = (Get-ADRootDSE).rootDomainNamingContext

$allDepartments = (
    $DepartmentsJson |
    ConvertFrom-Json
).PSObject.Properties

$departments = $allDepartments |
    Select-Object -First $DepartmentCount

# ------------------------------------------------------------
# Phase 1
# Active Directory OU Structure
#
# Creates the baseline OU hierarchy:
#
# _ROOT
# ├─ Computers
# ├─ Groups
# └─ Users
#
# Derived from Set-DummyAD.
# ------------------------------------------------------------

Write-Host "[i] OU generation starting"

$rootOU = Ensure-OrganizationalUnit `
    -Name $model.RootOUName `
    -Path $domainDN `
    -ProtectedFromAccidentalDeletion $model.PreventOUDeletion

$rootOUdn = $rootOU.DistinguishedName

foreach ($ouName in $model.CustomOUs) {

    if ($ouName -notlike "*/*") {

        Ensure-OrganizationalUnit `
            -Name $ouName `
            -Path $rootOUdn `
            -ProtectedFromAccidentalDeletion $model.PreventOUDeletion
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
            -ProtectedFromAccidentalDeletion $model.PreventOUDeletion
    }
}

Write-Host "[i] OU generation completed"

# ------------------------------------------------------------
# Phase 2
# Department OUs
#
# Creates departmental OUs beneath:
#
# Users
#
# Derived from Set-DummyAD.
# ------------------------------------------------------------

Write-Host "[i] Department OU generation starting"

$usersOU = Get-ADOrganizationalUnit `
    -LDAPFilter "(ou=Users)" `
    -SearchBase $rootOUdn `
    -ErrorAction Stop

foreach ($department in $departments) {

    Ensure-OrganizationalUnit `
        -Name $department.Name `
        -Path $usersOU.DistinguishedName `
        -ProtectedFromAccidentalDeletion $model.PreventOUDeletion
}

Write-Host "[i] Department OU generation completed"

# ------------------------------------------------------------
# Phase 3
# Security Groups
#
# Creates:
#
# GGS_<Dept>_ALL
# GGS_<Dept>_Managers
# GGS_<Dept>_Users
#
# DLGS_<Dept>_Share_RW
# DLGS_<Dept>_Share_RO
#
# Derived from Set-DummyAD.
# ------------------------------------------------------------

Write-Host "[i] Department security group generation starting"

$groupsOU = Get-ADOrganizationalUnit `
    -LDAPFilter "(ou=Groups)" `
    -SearchBase $rootOUdn `
    -ErrorAction Stop

$ggsOU = Get-ADOrganizationalUnit `
    -LDAPFilter "(ou=GGS)" `
    -SearchBase $groupsOU.DistinguishedName `
    -ErrorAction Stop

$dlgsOU = Get-ADOrganizationalUnit `
    -LDAPFilter "(ou=DLGS)" `
    -SearchBase $groupsOU.DistinguishedName `
    -ErrorAction Stop

foreach ($department in $departments) {

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

# ------------------------------------------------------------
# Phase 4
# AGDLP Membership Nesting
#
# Accounts
#   ->
# Global Groups
#   ->
# Domain Local Groups
#   ->
# Permissions
#
# Derived from Set-DummyAD.
# ------------------------------------------------------------

Write-Host "[i] Department group nesting starting"

foreach ($department in $departments) {

    $code = $department.Value

    Ensure-ADGroupMember `
        -GroupName "DLGS_${code}_Share_RW" `
        -MemberName "GGS_${code}_Managers"

    Ensure-ADGroupMember `
        -GroupName "DLGS_${code}_Share_RO" `
        -MemberName "GGS_${code}_Users"
}

Write-Host "[i] Department group nesting completed"

# ------------------------------------------------------------
# Phase 5
# File Share Foundation
#
# Creates:
#   C:\Shares
#
# Derived from Set-DummyAD.
#
# AMRL currently hosts shares on dc01.
# Future releases may move file services to
# dedicated file server infrastructure.
# ------------------------------------------------------------

Write-Host "[i] Root share creation starting"

$rootSharePath = $model.RootSharePath

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

# AMRL deviation from Set-DummyAD:
#
# Original implementation used:
#
#   RemoveAccessRule()
#
# Testing identified inconsistent behaviour during
# permission cleanup.
#
# RemoveAccessRuleAll() was validated and adopted
# as the AMRL implementation.

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

foreach ($department in $departments) {

    $code = $department.Value

    $departmentSharePath = Join-Path `
        -Path $model.RootSharePath `
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

# ------------------------------------------------------------
# Phase 6
# User Population
#
# Creates:
# - 1 Manager per Department
# - UsersPerDept standard users per Department
#
# User names are sourced from names.csv.
#
# Derived from Set-DummyAD.
#
# AMRL deviations:
# - Manager titles.
# - Existing user remediation.
# - Manager attribute reconciliation.
# - Stable manager assignment across reruns.
#
# AMRL identity model:
#
# Department managers are assigned during the
# initial population process and retained on
# subsequent executions.
#
# Unlike the original Set-DummyAD behaviour,
# managers are not re-randomised during each
# execution.
#
# Re-execution is intended to:
# - create missing objects
# - repair selected user attributes
# - ensure required group memberships exist
#
# Re-execution is not intended to:
# - move users between OUs
# - remove existing users
# - remove existing groups
# - enforce exact directory state
# ------------------------------------------------------------

Write-Host "[i] User generation starting"

$password = ConvertTo-SecureString `
    $ClientAdminPassword `
    -AsPlainText `
    -Force

$departmentInfo = @{}

# ------------------------------------------------------------
# Capacity Check
#
# AMRL enhancement:
#
# Warn if the requested number of accounts exceeds
# the available names in names.csv.
#
# Population will continue and users will be
# distributed as evenly as possible across all
# departments.
# ------------------------------------------------------------

$requiredUsers =
    $DepartmentCount * ($UsersPerDepartment + 1)

if ($CSVNames.Count -lt $requiredUsers) {

    Write-Warning (
        "names.csv contains $($CSVNames.Count) names " +
        "but deployment requires $requiredUsers accounts. " +
        "Users will be distributed as evenly as possible."
    )
}

# ------------------------------------------------------------
# Phase 6
# Manager Population
#
# Creates or reuses one manager per department.
#
# Managers are stored for use during the
# round-robin user population phase.
# ------------------------------------------------------------

foreach ($department in $departments) {

    $departmentOU = Get-ADOrganizationalUnit `
        -LDAPFilter "(ou=$($department.Name))" `
        -SearchBase $usersOU.DistinguishedName `
        -ErrorAction Stop

    $existingDepartmentManager = Get-ADGroupMember `
        -Identity "GGS_$($department.Value)_Managers" `
        -ErrorAction SilentlyContinue |
        Where-Object ObjectClass -eq 'user' |
        Select-Object -First 1

    if ($existingDepartmentManager) {

        Write-Host (
            "[=] Existing manager found for " +
            "$($department.Name): " +
            "$($existingDepartmentManager.SamAccountName)"
        )

        $managerObject = Get-ADUser `
            -Identity $existingDepartmentManager.SamAccountName `
            -Properties *

        $managerSam = $managerObject.SamAccountName
    }
    else {

        if ($CSVNames.Count -eq 0) {
            throw "No more names available in names.csv"
        }

        $managerUser = Get-Random -InputObject $CSVNames
        $null = $CSVNames.Remove($managerUser)

        $managerSam = (
            $managerUser.FirstName +
            "." +
            $managerUser.LastName
        ).ToLower()

        $managerUpn = "$managerSam@$($currentDomain.DNSRoot)"

        $managerObject = Ensure-ADUser `
            -SamAccountName $managerSam `
            -Path $departmentOU.DistinguishedName `
            -DisplayName "$($managerUser.FirstName) $($managerUser.LastName)" `
            -GivenName $managerUser.FirstName `
            -Surname $managerUser.LastName `
            -UserPrincipalName $managerUpn `
            -Department $department.Name `
            -Title "$($department.Name) Manager" `
            -Password $password `
            -Manager ""
    }

    Ensure-ADPrincipalGroupMembership `
        -GroupName "GGS_$($department.Value)_ALL" `
        -MemberName $managerSam

    Ensure-ADPrincipalGroupMembership `
        -GroupName "GGS_$($department.Value)_Managers" `
        -MemberName $managerSam

    $departmentInfo[$department.Name] = @{
        Department    = $department
        DepartmentOU  = $departmentOU
        ManagerObject = $managerObject
    }
}

# ------------------------------------------------------------
# Phase 7
# Round-Robin User Population
#
# AMRL enhancement:
#
# Users are distributed evenly across departments.
#
# Rather than filling one department completely
# before moving to the next, each department
# receives one user per pass.
#
# This provides balanced population when
# names.csv contains fewer names than required.
# ------------------------------------------------------------

$stopPopulation = $false

for ($i = 0; $i -lt $UsersPerDepartment; $i++) {

    if ($stopPopulation) {
        break
    }

    foreach ($departmentData in $departmentInfo.Values) {

        if ($CSVNames.Count -eq 0) {

            Write-Warning (
                "No more names available in names.csv. " +
                "User population stopped after available names were exhausted."
            )

            $stopPopulation = $true
            break
        }

        $department = $departmentData.Department
        $departmentOU = $departmentData.DepartmentOU
        $managerObject = $departmentData.ManagerObject

        $userRecord = Get-Random -InputObject $CSVNames
        $null = $CSVNames.Remove($userRecord)

        $userSam = (
            $userRecord.FirstName +
            "." +
            $userRecord.LastName
        ).ToLower()

        $userUpn = "$userSam@$($currentDomain.DNSRoot)"

        Ensure-ADUser `
            -SamAccountName $userSam `
            -Path $departmentOU.DistinguishedName `
            -DisplayName "$($userRecord.FirstName) $($userRecord.LastName)" `
            -GivenName $userRecord.FirstName `
            -Surname $userRecord.LastName `
            -UserPrincipalName $userUpn `
            -Department $department.Name `
            -Password $password `
            -Manager $managerObject.DistinguishedName

        Ensure-ADPrincipalGroupMembership `
            -GroupName "GGS_$($department.Value)_ALL" `
            -MemberName $userSam

        Ensure-ADPrincipalGroupMembership `
            -GroupName "GGS_$($department.Value)_Users" `
            -MemberName $userSam
    }
}

Write-Host "[i] User generation completed"

Write-Host "Directory population completed"

# TODO:
# Future AMRL release:
# Move departmental shares to dedicated file servers
# rather than hosting on domain controllers.