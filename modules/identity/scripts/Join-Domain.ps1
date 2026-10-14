<#
.SYNOPSIS
Joins a Windows workload VM to the declared AD domain and OU.
.DESCRIPTION
Consumes the serialized directory model and VM role to construct the computer OU.
Validates inputs, returns when any domain membership is already reported, prepares
domain credentials, waits for DNS, joins, verifies membership, and requests a reboot.
The caller orders this after directory population and GPO provisioning.
.NOTES
Administrator group membership is owned by Group Policy, not repaired by this script.
The early return does not verify the existing domain or move an already joined computer
to a newly requested OU. Passwords must not be logged. The rerun token is caller metadata.
#>

param(
    [string]$DomainName,
    [string]$DirectoryModel,
    [string]$VMType,
    [string]$ServerAdminUsername,
    [string]$ServerAdminPassword,
    [string]$ReconciliationToken
)

# ============================================================================
# INITIALIZATION
# ============================================================================

$model = $DirectoryModel | ConvertFrom-Json

$windowsAdminsGroup = (
    "$($model.groupNaming.globalSecurityPrefix)_$($model.platformAdminGroups.windowsAdmins)"
)

Write-Host '[Info] Starting Windows domain join.'

Write-Host "[Info] Target domain: $DomainName; VM type: $VMType."

# ============================================================================
# PHASE 1: VALIDATE OU MAPPING FOR VM TYPE
# ============================================================================

$computerOu = $model.computerOuMapping.$VMType

Write-Host "[Info] Target computer OU: $computerOu."

if ([string]::IsNullOrWhiteSpace($computerOu)) {
    throw "No OU mapping defined for VM type: $VMType"
}

$ouSegments = $computerOu -split '/'

[array]::Reverse($ouSegments)

$ouDn = ($ouSegments | ForEach-Object {
    "OU=$_"
}) -join ','

$domainDn = (($DomainName -split '\.') | ForEach-Object {
    "DC=$_"
}) -join ','

$fullOuPath = "$ouDn,OU=$($model.rootOuName),$domainDn"

Write-Host "[Info] Constructed target OU distinguished name for $VMType."

if ([string]::IsNullOrWhiteSpace($ServerAdminPassword)) {
    throw "ServerAdminPassword was not supplied"
}

Write-Host '[Info] Domain join inputs were parsed.'

# Return on existing domain membership before preparing credentials or issuing a new join.
# This preserves retained guest state; it does not prove membership in the requested domain.

$computerSystem = Get-CimInstance Win32_ComputerSystem

Write-Host "[Info] Current computer name: $($computerSystem.Name)."
Write-Host "[Info] Current domain-membership flag: $($computerSystem.PartOfDomain)."

if ($computerSystem.PartOfDomain) {
    Write-Host '[Info] Computer already reports domain membership; no join command will run.'
    return
}

# Domain credential to join the computer to the domain

# ============================================================================
# PHASE 2: PREPARE CREDENTIALS
# ============================================================================

$securePassword = ConvertTo-SecureString `
    $ServerAdminPassword `
    -AsPlainText `
    -Force

$netbiosName = $DomainName.Split('.')[0].ToUpper()

$credential = New-Object System.Management.Automation.PSCredential(
    "$netbiosName\$ServerAdminUsername",
    $securePassword
)

# ============================================================================
# PHASE 3: WAIT FOR DOMAIN DNS RESOLUTION
# Up to 30 attempts allow DNS/forest setup to settle; this checks name resolution, not all AD services.
# ============================================================================

$dnsResolved = $false

for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
        Resolve-DnsName $DomainName -ErrorAction Stop | Out-Null

        Write-Host "[Verified] Domain DNS name $DomainName resolved."

        $dnsResolved = $true
        break
    }
    catch {
        Write-Host "[Info] Domain DNS is not yet resolvable (attempt $attempt of 30)."

        Start-Sleep -Seconds 10
    }
}

if (-not $dnsResolved) {
    throw "Unable to resolve domain DNS name: $DomainName"
}

# ============================================================================
# PHASE 4: EXECUTE DOMAIN JOIN
# ============================================================================

Write-Host "[Info] Joining computer to domain $DomainName."

if ($null -ne $fullOuPath) {
    Add-Computer `
        -DomainName $DomainName `
        -Credential $credential `
        -OUPath $fullOuPath `
        -ErrorAction Stop
}
else {
    Add-Computer `
        -DomainName $DomainName `
        -Credential $credential `
        -ErrorAction Stop
}

Write-Host '[Info] Domain join command completed.'

# Verify domain membership

$computerSystem = Get-CimInstance Win32_ComputerSystem

if (-not $computerSystem.PartOfDomain) {
    throw "Domain join operation completed, but the computer is still not reporting domain membership."
}

Write-Host "[Verified] Computer reports domain membership after the join."

# ============================================================================
# PHASE 5: DEFER ADMINISTRATOR MEMBERSHIP TO GPO AND RESTART
# ============================================================================

Write-Host '[Info] Local administrator assignment is managed by Group Policy.'

$netbiosName = $DomainName.Split('.')[0].ToUpper()

Write-Host '[Info] Restarting computer to complete the domain join.'

Restart-Computer -Force
