# Shared by directory population and share provisioning; their Bicep modules embed this helper.
# Mandatory departments retain their input order; additional departments fill the remaining slots.
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