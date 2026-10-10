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

Write-Host '[Info] Starting share population.'
Write-Host "[Info] Requested department count: $DepartmentCount."

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

    Write-Host '[Info] Checking the root share directory.'

    $dlgsPrefix = $PopulationModel.groupNaming.domainLocalSecurityPrefix

    $rootSharePath = $PopulationModel.shares.root.path

    if (-not (Test-Path $rootSharePath)) {

        New-Item `
            -Path $rootSharePath `
            -ItemType Directory `
            -Force | Out-Null

        Write-Host "[Created] Root share directory $rootSharePath."
    }
    else {

        Write-Host "[Verified] Root share directory $rootSharePath exists."
    }

    Write-Host '[Info] Root share directory check completed.'

    Write-Host '[Info] Applying root share ACL configuration.'

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

    Write-Host '[Info] Root share ACL configuration commands completed.'

    Write-Host '[Info] Processing departmental shares.'

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

            Write-Host "[Created] Department share directory $departmentSharePath."
        }
        else {

            Write-Host "[Verified] Department share directory $departmentSharePath exists."
        }

            Write-Host "[Info] Processing share configuration for $($department.Name)."

        if (-not (Get-SmbShare -Name $code -ErrorAction SilentlyContinue)) {

            New-SmbShare `
                -Name $code `
                -Path $departmentSharePath | Out-Null

            Grant-SmbShareAccess `
                -Name $code `
                -AccountName 'Everyone' `
                -AccessRight Full `
                -Force | Out-Null

            Write-Host "[Created] SMB share $code."
        }
        else {

            Write-Host "[Info] SMB share $code exists; its configured path is not checked."
        }

    Write-Host "[Info] Share configuration commands completed for $($department.Name)."

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

        Write-Host "[Info] Desired NTFS ACL entries prepared for $code."

        $dirACL.SetAccessRule($acrw)
        $dirACL.SetAccessRule($acro)

        Write-Host "[Info] Desired NTFS ACL entries applied for $code."

        Set-Acl `
            -Path $departmentSharePath `
            -AclObject $dirACL

        Write-Host "[Info] NTFS permission command completed for $($department.Name)."
    }

    Write-Host '[Info] Department share processing completed.'

}

$departments = Get-SelectedDepartments `
    -SysAdminDepartmentJson $SysAdminDepartmentJson `
    -AdditionalDepartmentsJson $AdditionalDepartmentsJson `
    -InputDepartmentCount $DepartmentCount

Write-Host "[Info] Selected $($departments.Count) departments for share population."

Initialize-DepartmentShares `
    -SelectedDepartments $departments `
    -PopulationModel $model

Write-Host "[Info] Share population summary: processed $($departments.Count) departments."
Write-Host '[Info] Share population completed.'