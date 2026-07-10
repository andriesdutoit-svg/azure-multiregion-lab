<#
This script contains logic derived from and inspired by:

Set-DummyAD
https://github.com/BOAScripts/Set-DummyAD

Copyright (c) BOAScripts
Licensed under the MIT License.

Adapted and integrated for AMRL.

Directory population logic derived from Set-DummyAD.
#>

param(
    [string]$DomainName,
    [string]$NamesCsvContent
)

Write-Host "Starting AMRL Directory Population"
Write-Host "DomainName = $DomainName"

Import-Module ActiveDirectory -ErrorAction Stop

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

function Ensure-ADUser {
    param(
        [string]$SamAccountName,
        [string]$Path,
        [string]$DisplayName,
        [string]$GivenName,
        [string]$Surname,
        [string]$UserPrincipalName,
        [string]$Department,
        [SecureString]$Password,
        [string]$Manager
    )

    $existingUser = Get-ADUser `
        -LDAPFilter "(sAMAccountName=$SamAccountName)" `
        -ErrorAction SilentlyContinue

    if ($existingUser) {
        Write-Host "[=] User already exists: $SamAccountName"
        return $existingUser
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

    if ($Manager) {
        $params.Manager = $Manager
    }

    New-ADUser @params

    return Get-ADUser `
        -LDAPFilter "(sAMAccountName=$SamAccountName)"
}


try {
    $currentDomain = Get-ADDomain -ErrorAction Stop

    Write-Host "Connected to domain: $($currentDomain.DNSRoot)"
}
catch {
    Write-Error "Unable to access Active Directory"
    throw
}

$model = @'
{
    "PSW":"Test1234=",
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
    "RootSharePath":"C:\\Shares",
    "Depts": {
        "Consultants":"CON",
        "Finance":"FIN",
        "HR":"HR",
        "ICT":"ICT",
        "Sales":"SAL",
        "Engineering":"ENG",
        "Operation":"OPE"
    },
    "UsersPerDept":10
}
'@ | ConvertFrom-Json

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

Write-Host "[i] Department OU generation starting"

$usersOU = Get-ADOrganizationalUnit `
    -LDAPFilter "(ou=Users)" `
    -SearchBase $rootOUdn `
    -ErrorAction Stop

$departments = $model.Depts.PSObject.Properties

foreach ($department in $departments) {

    Ensure-OrganizationalUnit `
        -Name $department.Name `
        -Path $usersOU.DistinguishedName `
        -ProtectedFromAccidentalDeletion $model.PreventOUDeletion
}

Write-Host "[i] Department OU generation completed"

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

Write-Host "[i] User generation starting"

$password = ConvertTo-SecureString `
    $model.PSW `
    -AsPlainText `
    -Force

foreach ($department in $departments) {

    $departmentOU = Get-ADOrganizationalUnit `
        -LDAPFilter "(ou=$($department.Name))" `
        -SearchBase $usersOU.DistinguishedName `
        -ErrorAction Stop

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
        -Password $password `
        -Manager ""

    Ensure-ADPrincipalGroupMembership `
        -GroupName "GGS_$($department.Value)_ALL" `
        -MemberName $managerSam

    Ensure-ADPrincipalGroupMembership `
        -GroupName "GGS_$($department.Value)_Managers" `
        -MemberName $managerSam

    for ($i = 0; $i -lt $model.UsersPerDept; $i++) {

        if ($CSVNames.Count -eq 0) {
            throw "No more names available in names.csv"
        }

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