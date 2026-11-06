param(
    [string]$DomainName,
    [string]$ReconciliationToken
)

$ErrorActionPreference = 'Stop'

function Write-AmrlSpnLog {
    param([string]$Message)
    Write-Output "[SPN] $Message"
}

function Resolve-AmrlComputerAccountName {
    param([Parameter(Mandatory = $true)][object]$ComputerSystem)

    $dnsAccount = New-Object -TypeName System.Security.Principal.NTAccount `
        -ArgumentList "$($ComputerSystem.Domain)\$($ComputerSystem.Name)`$"
    $computerSid = $dnsAccount.Translate([System.Security.Principal.SecurityIdentifier])
    return $computerSid.Translate([System.Security.Principal.NTAccount]).Value
}

function Invoke-AmrlSetSpn {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $setSpnPath = Join-Path $env:SystemRoot 'System32\setspn.exe'
    if (-not (Test-Path -LiteralPath $setSpnPath)) { throw "setspn.exe was not found at '$setSpnPath'." }
    $output = & $setSpnPath @Arguments 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
    }
}

function Set-AmrlWinRMHttpSpns {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedDomain,
        [ValidateRange(1, 12)][int]$MaximumAttempts = 12,
        [ValidateRange(0, 60)][int]$RetryDelaySeconds = 15
    )

    $expectedDomain = $ExpectedDomain.TrimEnd('.')
    $computerName = $env:COMPUTERNAME
    $lastFailure = 'The machine secure channel is not ready.'
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $computerSystem = $null
        try { $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop }
        catch { $lastFailure = "Could not read local domain membership: $($_.Exception.Message)" }

        if ($null -ne $computerSystem -and $computerSystem.PartOfDomain -and
            $computerSystem.Domain -ine $expectedDomain) {
            throw "This computer is joined to '$($computerSystem.Domain)', not expected domain '$expectedDomain'."
        }

        if ($null -ne $computerSystem -and $computerSystem.PartOfDomain) {
            try {
                if (-not (Test-ComputerSecureChannel -ErrorAction Stop)) {
                    throw 'The domain secure channel is not ready.'
                }

                $computerAccount = Resolve-AmrlComputerAccountName -ComputerSystem $computerSystem
                $registered = Invoke-AmrlSetSpn -Arguments @('-L', $computerAccount)
                if ($registered.ExitCode -ne 0) {
                    throw "Unable to list SPNs for '$computerAccount': $($registered.Output -join ' ')"
                }
                $registeredSpns = @($registered.Output)
                $expectedSpns = @(
                    "HTTP/$($computerSystem.Name)"
                    "HTTP/$($computerSystem.Name).$expectedDomain"
                )

                foreach ($spn in $expectedSpns) {
                    if ($registeredSpns -icontains $spn) {
                        Write-AmrlSpnLog "Verified WinRM HTTP SPN: $spn"
                        continue
                    }
                    $registration = Invoke-AmrlSetSpn -Arguments @('-S', $spn, $computerAccount)
                    if ($registration.ExitCode -ne 0) {
                        throw "Unable to register WinRM HTTP SPN '$spn' on '$computerAccount': $($registration.Output -join ' ')"
                    }
                    Write-AmrlSpnLog "Registered WinRM HTTP SPN: $spn"
                }

                Write-AmrlSpnLog "Verified both WinRM HTTP SPNs for '$computerAccount'."
                return
            }
            catch { $lastFailure = $_.Exception.Message }
        }
        else {
            $lastFailure = 'The machine is not yet a member of the requested domain.'
        }

        if ($attempt -lt $MaximumAttempts) {
            Write-AmrlSpnLog "Attempt $attempt of $MaximumAttempts did not complete: $lastFailure Retrying in $RetryDelaySeconds seconds."
            if ($RetryDelaySeconds -gt 0) { Start-Sleep -Seconds $RetryDelaySeconds }
        }
    }

    throw "WinRM HTTP SPN reconciliation failed after $MaximumAttempts attempts: $lastFailure"
}

Write-AmrlSpnLog "Reconciliation token: $ReconciliationToken"
Set-AmrlWinRMHttpSpns -ExpectedDomain $DomainName