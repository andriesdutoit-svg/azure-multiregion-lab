param(
    [string]$DomainName,
    [string]$ReconciliationToken
)

$ErrorActionPreference = 'Stop'

Write-Output "[DC-WinRM] Reconciling WinRM access on $env:COMPUTERNAME."

$computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
if (-not $computerSystem.PartOfDomain -or $computerSystem.Domain -ine $DomainName.TrimEnd('.')) {
    throw "This computer is not joined to the requested domain '$DomainName'."
}

$setSpnPath = Join-Path $env:SystemRoot 'System32\setspn.exe'
if (-not (Test-Path -LiteralPath $setSpnPath)) {
    throw "setspn.exe was not found at '$setSpnPath'."
}

$netbiosName = $DomainName.Split('.')[0].ToUpperInvariant()
$computerAccount = "$netbiosName\$($computerSystem.Name)`$"
$expectedSpns = @(
    "HTTP/$($computerSystem.Name)"
    "HTTP/$($computerSystem.Name).$($DomainName.TrimEnd('.'))"
)

$registeredOutput = & $setSpnPath -L $computerAccount 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Unable to list SPNs for '$computerAccount': $($registeredOutput -join ' ')"
}
$registeredSpns = @($registeredOutput | ForEach-Object { $_.ToString().Trim() })

foreach ($spn in $expectedSpns) {
    if ($registeredSpns -icontains $spn) {
        Write-Output "[DC-WinRM] WinRM HTTP SPN is already registered: $spn"
        continue
    }

    $registrationOutput = & $setSpnPath -S $spn $computerAccount 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to register WinRM HTTP SPN '$spn' on '$computerAccount': $($registrationOutput -join ' ')"
    }

    Write-Output "[DC-WinRM] Registered WinRM HTTP SPN: $spn"
}

$ruleName = 'AMRL-DC-WinRM-HTTP-Internal'
$gpupdatePath = Join-Path $env:SystemRoot 'System32\gpupdate.exe'
if (-not (Test-Path -LiteralPath $gpupdatePath)) {
    throw "gpupdate.exe was not found at '$gpupdatePath'."
}

$gpupdateOutput = & $gpupdatePath /target:computer /force /wait:120 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Computer Group Policy refresh failed: $($gpupdateOutput -join ' ')"
}

$activeRule = Get-NetFirewallRule `
    -PolicyStore ActiveStore `
    -Name $ruleName `
    -ErrorAction Stop
$portFilter = $activeRule | Get-NetFirewallPortFilter
$addressFilter = $activeRule | Get-NetFirewallAddressFilter
$configuredAddresses = @($addressFilter.RemoteAddress | ForEach-Object { [string]$_ })

if (-not $activeRule.Enabled -or
    $activeRule.PolicyStoreSourceType -ne 'GroupPolicy' -or
    [string]$activeRule.Profile -ne 'Any' -or
    $activeRule.Direction -ne 'Inbound' -or
    $activeRule.Action -ne 'Allow' -or
    [string]$portFilter.Protocol -notin @('TCP', '6') -or
    [string]$portFilter.LocalPort -ne '5985' -or
    @($configuredAddresses | Where-Object { $_ -in @('10.0.0.0/8', '10.0.0.0/255.0.0.0') }).Count -eq 0) {
    throw "The active DC WinRM GPO rule '$ruleName' does not match the required all-profile inbound TCP 5985 policy from 10.0.0.0/8."
}

$legacyRule = Get-NetFirewallRule `
    -PolicyStore PersistentStore `
    -Name $ruleName `
    -ErrorAction SilentlyContinue
if ($null -ne $legacyRule) {
    Remove-NetFirewallRule -InputObject $legacyRule -ErrorAction Stop
}

Write-Output '[DC-WinRM] Firewall policy is managed by the all-profile Domain Controllers GPO.'