<#
.SYNOPSIS
Creates departmental SMB shares and applies the declared NTFS group permissions.
.DESCRIPTION
Consumes directory/department JSON on the selected primary DC or dedicated file server.
Mandatory departments are retained; remaining slots select additional departments in input order.
Missing directories/shares are created, root access is adjusted, and department RW/RO ACLs are applied.
.NOTES
Requires Windows SMB/ACL administration and resolvable AD groups; the caller waits for
population and Windows domain join. Existing share paths are not checked or migrated,
unrequested shares are not retired, and unrelated ACLs are not comprehensively reconciled.
The Bicep caller embeds Get-SelectedDepartments.ps1 at the helper marker; no external
helper file is required on the guest when the composed Run Command executes.
#>

# 1. Inputs and directory-model validation
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

# 2. Department selection helper
# All system-administration departments are mandatory; additional departments fill remaining
# slots in JSON property order. A request smaller than the mandatory set is rejected.

# Bicep replaces this marker with the shared helper after the caller parameter block.
# __AMRL_DEPARTMENT_SELECTION__

# 3. Share and ACL provisioning helper
# Preserve the sequence: root directory/ACLs, departmental directory/share, then department ACLs.
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

        # Existing share identity is checked by name only; its configured path is not repaired here.
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

# 4. Execute selection and provisioning
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