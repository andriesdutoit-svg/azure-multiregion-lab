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

Write-Host "Starting AMRL Domain Join"

Write-Host "DomainName = $DomainName"
Write-Host "VMType = $VMType"

# ============================================================================
# PHASE 1: VALIDATE OU MAPPING FOR VM TYPE
# ============================================================================

$computerOu = $model.computerOuMapping.$VMType

Write-Host "ComputerOu = $computerOu"

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

Write-Host "Full OU Path = $fullOuPath"

if ([string]::IsNullOrWhiteSpace($ServerAdminPassword)) {
    throw "ServerAdminPassword was not supplied"
}

Write-Host "Domain join script loaded successfully"

# Check if the computer is already joined to a domain

$computerSystem = Get-CimInstance Win32_ComputerSystem

Write-Host "Computer Name: $($computerSystem.Name)"
Write-Host "Part Of Domain: $($computerSystem.PartOfDomain)"

if ($computerSystem.PartOfDomain) {
    Write-Host "Computer is already joined to a domain."
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
# ============================================================================

$dnsResolved = $false

for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
        Resolve-DnsName $DomainName -ErrorAction Stop | Out-Null

        Write-Host "Successfully resolved domain DNS name."

        $dnsResolved = $true
        break
    }
    catch {
        Write-Host "Attempt $attempt of 30: Unable to resolve $DomainName"

        Start-Sleep -Seconds 10
    }
}

if (-not $dnsResolved) {
    throw "Unable to resolve domain DNS name: $DomainName"
}

# ============================================================================
# PHASE 4: EXECUTE DOMAIN JOIN
# ============================================================================

Write-Host "Joining computer to domain $DomainName"

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

Write-Host "Domain join completed successfully."

# Verify domain membership

$computerSystem = Get-CimInstance Win32_ComputerSystem

if (-not $computerSystem.PartOfDomain) {
    throw "Domain join operation completed, but the computer is still not reporting domain membership."
}

Write-Host "Domain membership verified."

# ============================================================================
# PHASE 5: CONFIGURE LOCAL ADMINISTRATOR ACCESS
# ============================================================================

Write-Host "Configuring local administrator access"

$netbiosName = $DomainName.Split('.')[0].ToUpper()

try {
    Add-LocalGroupMember `
        -Group "Administrators" `
        -Member "$netbiosName\$windowsAdminsGroup" `
        -ErrorAction Stop

    Write-Host (
        "Added $netbiosName\$windowsAdminsGroup " +
        "to local Administrators"
    )
}
catch {
    Write-Warning (
        "Unable to add $netbiosName\$windowsAdminsGroup " +
        "to local Administrators. $_"
    )
}

Write-Host "Restarting computer to complete domain join."

Restart-Computer -Force
