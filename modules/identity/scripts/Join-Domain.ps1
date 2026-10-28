<#
.SYNOPSIS
Joins a Windows workload VM to the declared AD domain and OU.
.DESCRIPTION
Consumes the serialized directory model and VM role to construct the computer OU.
Validates inputs and the reported domain, and reconciles HTTP SPNs for retained
members without rejoining. New members prepare domain credentials, wait for DNS,
join, verify membership, reconcile SPNs, and request a reboot. The caller orders
this after directory population and GPO definition provisioning.
.NOTES
Administrator group membership is owned by Group Policy, not repaired by this script.
Existing members must match the requested domain but are not moved to a newly
requested OU. Windows applies computer policy normally; neither this script nor
its module forces gpupdate or verifies effective guest policy before deployment
continues. Passwords must not be logged. The rerun token is caller metadata.
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

# These HTTP SPNs identify the member to Kerberos clients such as WAC. Domain membership
# alone did not guarantee their presence. Reconcile them on reruns as well as fresh joins;
# this is separate from the GPO-owned WinRM listener and firewall configuration.
function Ensure-WinRMHttpSpns {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedDomain
    )

    $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if (-not $computerSystem.PartOfDomain) {
        throw 'Cannot reconcile WinRM SPNs because this computer is not domain joined.'
    }
    if ($computerSystem.Domain -ine $ExpectedDomain.TrimEnd('.')) {
        throw "This computer is joined to '$($computerSystem.Domain)', not expected domain '$ExpectedDomain'."
    }

    $setSpnPath = Join-Path $env:SystemRoot 'System32\setspn.exe'
    if (-not (Test-Path -LiteralPath $setSpnPath)) {
        throw "setspn.exe was not found at '$setSpnPath'."
    }

    # Resolve the domain-qualified computer SID back to its canonical account name.
    # The NetBIOS domain need not match the first DNS label; this needs no AD PowerShell module.
    try {
        $dnsAccount = New-Object -TypeName System.Security.Principal.NTAccount `
            -ArgumentList "$($computerSystem.Domain)\$($computerSystem.Name)`$"
        $computerSid = $dnsAccount.Translate([System.Security.Principal.SecurityIdentifier])
        $computerAccount = $computerSid.Translate([System.Security.Principal.NTAccount]).Value
    }
    catch {
        throw "Unable to resolve the domain computer account for '$($computerSystem.Name)': $($_.Exception.Message)"
    }
    $expectedSpns = @(
        "HTTP/$($computerSystem.Name)"
        "HTTP/$($computerSystem.Name).$($ExpectedDomain.TrimEnd('.'))"
    )

    $registeredOutput = & $setSpnPath -L $computerAccount 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list SPNs for '$computerAccount': $($registeredOutput -join ' ')"
    }
    $registeredSpns = @($registeredOutput | ForEach-Object { $_.ToString().Trim() })

    foreach ($spn in $expectedSpns) {
        if ($registeredSpns -icontains $spn) {
            Write-Host "[Verified] WinRM HTTP SPN is registered: $spn"
            continue
        }

        $registrationOutput = & $setSpnPath -S $spn $computerAccount 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to register WinRM HTTP SPN '$spn' on '$computerAccount': $($registrationOutput -join ' ')"
        }

        Write-Host "[Updated] Registered WinRM HTTP SPN: $spn"
    }
}

# Existing members avoid credential preparation and another join, but must match the requested
# domain and still receive SPN repair. Windows handles subsequent computer-policy processing.

$computerSystem = Get-CimInstance Win32_ComputerSystem

Write-Host "[Info] Current computer name: $($computerSystem.Name)."
Write-Host "[Info] Current domain-membership flag: $($computerSystem.PartOfDomain)."

if ($computerSystem.PartOfDomain) {
    if ($computerSystem.Domain -ine $DomainName.TrimEnd('.')) {
        throw "Computer is already joined to '$($computerSystem.Domain)', not requested domain '$DomainName'."
    }

    Write-Host '[Info] Computer already reports domain membership; no join command will run.'
    Ensure-WinRMHttpSpns -ExpectedDomain $DomainName
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
Ensure-WinRMHttpSpns -ExpectedDomain $DomainName

# ============================================================================
# PHASE 5: DEFER ADMINISTRATOR MEMBERSHIP TO GPO AND RESTART
# ============================================================================

Write-Host '[Info] Local administrator assignment is managed by Group Policy.'

$netbiosName = $DomainName.Split('.')[0].ToUpper()

Write-Host '[Info] Restarting computer to complete the domain join.'

Restart-Computer -Force
