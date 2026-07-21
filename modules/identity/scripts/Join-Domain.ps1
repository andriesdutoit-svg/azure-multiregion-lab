param(
    [string]$DomainName,
    [string]$ServerAdminUsername,
    [string]$ServerAdminPassword,
    [string]$ComputerOuPath
)

Import-Module ActiveDirectory -ErrorAction Stop

Write-Host "Starting AMRL Domain Join"

Write-Host "DomainName = $DomainName"
Write-Host "ComputerOuPath = $ComputerOuPath"

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

$securePassword = ConvertTo-SecureString `
    $ServerAdminPassword `
    -AsPlainText `
    -Force

$netbiosName = $DomainName.Split('.')[0].ToUpper()

$credential = New-Object System.Management.Automation.PSCredential(
    "$netbiosName\$ServerAdminUsername",
    $securePassword
)

# Validate the domain name by resolving its DNS name

try {
    Resolve-DnsName $DomainName -ErrorAction Stop | Out-Null

    Write-Host "Successfully resolved domain DNS name."
}
catch {
    throw "Unable to resolve domain DNS name: $DomainName"
}

# Attempt to discover a domain controller for the specified domain

for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
        $domainController = Get-ADDomainController `
            -Discover `
            -DomainName $DomainName `
            -ErrorAction Stop

        Write-Host "Discovered domain controller: $($domainController.HostName)"

        break
    }
    catch {
        Write-Host "Attempt $attempt of 30: Domain controller not yet reachable."

        if ($attempt -eq 30) {
            throw "Unable to discover a domain controller for $DomainName"
        }

        Start-Sleep -Seconds 10
    }
}

# Domain join operation

Write-Host "Joining computer to domain $DomainName"

Add-Computer `
    -DomainName $DomainName `
    -Credential $credential `
    -OUPath $ComputerOuPath `
    -ErrorAction Stop

Write-Host "Domain join completed successfully."

Write-Host "Restarting computer to complete domain join."

Restart-Computer -Force
