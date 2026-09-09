param(
    [string]$DirectoryModel,
    [string]$SysAdminDepartmentJson,
    [string]$AdditionalDepartmentsJson,
    [string]$DepartmentCount,
    [string]$ReconciliationToken
)

# ============================================================================
# INITIALIZATION
# ============================================================================

try {
    $model = $DirectoryModel | ConvertFrom-Json
}
catch {
    throw "DirectoryModel could not be parsed."
}

if (-not $model) {
    throw "DirectoryModel could not be parsed."
}

Write-Host "Starting AMRL Share Population"
Write-Host "DepartmentCount = $DepartmentCount"
Write-Host "ReconciliationToken = $ReconciliationToken"

# # Get-SelectedDepartments: Filter department lists to match InputDepartmentCount.
# # Always includes all sysAdminDepartments (mandatory); fills remaining slots with additionalDepartments.
# # Example: sysAdminDepartments=[IT], additionalDepartments=[Finance,HR], InputDepartmentCount=2
# #   → Returns [IT, Finance] (IT mandatory + 1 additional)
# # Validates that InputDepartmentCount >= length(sysAdminDepartments); throws if underconstrained.

function Get-SelectedDepartments {
    param(
        [string]$SysAdminDepartmentJson,
        [string]$AdditionalDepartmentsJson,
        [int]$InputDepartmentCount
    )

    $sysAdminDepartments = @(
        (
            $SysAdminDepartmentJson |
            ConvertFrom-Json
        ).PSObject.Properties
    )

    $additionalDepartments = @(
        (
            $AdditionalDepartmentsJson |
            ConvertFrom-Json
        ).PSObject.Properties
    )

    if ($InputDepartmentCount -lt $sysAdminDepartments.Count) {
        throw (
            "DepartmentCount ($InputDepartmentCount) is less than " +
            "the number of mandatory departments ($($sysAdminDepartments.Count))."
        )
    }

    $remainingDepartmentSlots =
        $InputDepartmentCount - $sysAdminDepartments.Count

    $selectedAdditionalDepartments =
        $additionalDepartments |
        Select-Object -First $remainingDepartmentSlots

    return @(
        $sysAdminDepartments +
        $selectedAdditionalDepartments
    )
}

function Initialize-DepartmentShares {
    param(
        [object[]]$SelectedDepartments,
        [object]$PopulationModel
    )

    Write-Host "[i] Root share creation starting"

    $dlgsPrefix = $PopulationModel.groupNaming.domainLocalSecurityPrefix

    $rootSharePath = $PopulationModel.shares.root.path

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
            -Path $PopulationModel.shares.root.path `
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

            Write-Host "[i] Department directory prepared: $($department.Name)"

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

    Write-Host "[i] SMB share configuration completed for: $($department.Name)"

        $dirACL = Get-Acl $departmentSharePath

        $acrw = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "${dlgsPrefix}_${code}_Share_RW",
            "Modify",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )

        $acro = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "${dlgsPrefix}_${code}_Share_RO",
            "ReadAndExecute",
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )

        Write-Host "[i] ACL objects created for: $code"

        $dirACL.SetAccessRule($acrw)
        $dirACL.SetAccessRule($acro)

        Write-Host "[i] ACL rules attached for: $code"

        Set-Acl `
            -Path $departmentSharePath `
            -AclObject $dirACL

        Write-Host "[+] Applied NTFS permissions: $($department.Name)"
    }

    Write-Host "[i] Department share generation completed"

}

$departments = Get-SelectedDepartments `
    -SysAdminDepartmentJson $SysAdminDepartmentJson `
    -AdditionalDepartmentsJson $AdditionalDepartmentsJson `
    -InputDepartmentCount $DepartmentCount

Write-Host "Departments selected: $($departments.Count)"

Initialize-DepartmentShares `
    -SelectedDepartments $departments `
    -PopulationModel $model

Write-Host "[i] Share population completed"