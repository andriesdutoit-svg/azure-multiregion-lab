param(
    [string]$ReconciliationToken
)

$ErrorActionPreference = 'Stop'

$displayName = 'Allow WinRM HTTP/HTTPS'
$gpupdatePath = Join-Path $env:SystemRoot 'System32\gpupdate.exe'
if (-not (Test-Path -LiteralPath $gpupdatePath)) {
    throw "gpupdate.exe was not found at '$gpupdatePath'."
}

$gpupdateOutput = & $gpupdatePath /target:computer /force /wait:120 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Computer Group Policy refresh failed: $($gpupdateOutput -join ' ')"
}

$activeRules = @(
    Get-NetFirewallRule `
        -PolicyStore ActiveStore `
        -DisplayName $displayName `
        -ErrorAction Stop |
        Where-Object {
            $_.PolicyStoreSourceType -eq 'GroupPolicy' -and
            [string]$_.Profile -eq 'Any'
        }
)
if ($activeRules.Count -ne 1 -or
    -not $activeRules[0].Enabled -or
    $activeRules[0].Direction -ne 'Inbound' -or
    $activeRules[0].Action -ne 'Allow') {
    throw "The all-profile workload WinRM GPO rule '$displayName' is not active."
}

$portFilter = $activeRules[0] | Get-NetFirewallPortFilter
$addressFilter = $activeRules[0] | Get-NetFirewallAddressFilter
$configuredPorts = @($portFilter.LocalPort | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() })
$configuredAddresses = @($addressFilter.RemoteAddress | ForEach-Object { [string]$_ })
if ([string]$portFilter.Protocol -notin @('TCP', '6') -or
    '5985' -notin $configuredPorts -or
    @($configuredAddresses | Where-Object { $_ -in @('10.0.0.0/8', '10.0.0.0/255.0.0.0') }).Count -eq 0) {
    throw "The active workload WinRM GPO rule '$displayName' has an unexpected port or source scope."
}

$legacyRule = Get-NetFirewallRule `
    -PolicyStore PersistentStore `
    -Name 'AMRL-WinRM-HTTP-Internal' `
    -ErrorAction SilentlyContinue
if ($null -ne $legacyRule) {
    Remove-NetFirewallRule -InputObject $legacyRule -ErrorAction Stop
}

Write-Output '[Verified] Workload WinRM firewall access is managed by the all-profile GPO.'