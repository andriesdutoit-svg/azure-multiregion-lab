# Installs WAC on first use and reapplies the managed configuration on reruns.
# Browser-to-gateway traffic uses HTTPS; managed-server WinRM currently uses HTTP.
param(
    [string]$ReconciliationToken
)

$ErrorActionPreference = 'Stop'

$installerChannel = 'current'
$installerUri = 'https://aka.ms/WACDownload'
$downloadDirectory = 'C:\Temp\WAC'
$installerPath = Join-Path $downloadDirectory 'WindowsAdminCenter.exe'
$installLog = Join-Path $downloadDirectory 'WacInstall.log'

function Write-Log {
    param(
        [string]$Message
    )

    Write-Output "[WAC] $Message"
}

function Merge-WacUrlAclSddl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sddl,

        [Parameter(Mandatory = $true)]
        [string[]]$RequiredSids
    )

    $descriptor = [System.Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
    $acl = $descriptor.DiscretionaryAcl

    if ($null -eq $acl) {
        throw 'The WAC URL reservation has no discretionary access-control list.'
    }

    foreach ($sidText in $RequiredSids) {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($sidText)
        $hasListenPermission = $false

        foreach ($ace in $acl) {
            if ($ace -is [System.Security.AccessControl.QualifiedAce] -and
                $ace.AceQualifier -eq [System.Security.AccessControl.AceQualifier]::AccessAllowed -and
                $ace.SecurityIdentifier.Value -eq $sid.Value -and
                (($ace.AccessMask -band 0x20000000) -ne 0 -or ($ace.AccessMask -band 0x10000000) -ne 0)) {
                $hasListenPermission = $true
                break
            }
        }

        if (-not $hasListenPermission) {
            $ace = [System.Security.AccessControl.CommonAce]::new(
                [System.Security.AccessControl.AceFlags]::None,
                [System.Security.AccessControl.AceQualifier]::AccessAllowed,
                0x20000000,
                $sid,
                $false,
                $null
            )
            $acl.InsertAce($acl.Count, $ace)
        }
    }

    return $descriptor.GetSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
}

function Ensure-WacUrlReservation {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $url = "https://+:$Port/"
    $computerAccount = '{0}\{1}$' -f $env:USERDOMAIN, $env:COMPUTERNAME

    try {
        $computerSid = ([System.Security.Principal.NTAccount]::new($computerAccount)).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
    }
    catch {
        throw "Unable to resolve WAC gateway computer account '$computerAccount' to a SID: $($_.Exception.Message)"
    }

    $requiredSids = @(
        'S-1-5-20'
        $computerSid
    )

    $urlAclOutput = @(& netsh.exe http show urlacl "url=$url" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect the WAC URL reservation: $($urlAclOutput -join ' ')"
    }

    $urlAclText = $urlAclOutput -join [Environment]::NewLine
    $reservationExists = $urlAclText -match [regex]::Escape($url)
    $originalSddl = 'D:'

    if ($reservationExists) {
        $sddlLine = $urlAclOutput |
            Where-Object { $_ -match '^\s*SDDL\s*:' } |
            Select-Object -First 1

        if ([string]::IsNullOrWhiteSpace($sddlLine) -or
            $sddlLine -notmatch '^\s*SDDL\s*:\s*(?<Value>D:.*)$') {
            throw "Could not read the existing SDDL for WAC URL reservation '$url'."
        }

        $originalSddl = $Matches.Value.Trim()
    }

    $desiredSddl = Merge-WacUrlAclSddl `
        -Sddl $originalSddl `
        -RequiredSids $requiredSids

    if ($reservationExists -and $desiredSddl -eq $originalSddl) {
        Write-Log 'WAC HTTPS URL reservation already grants listen permission to NetworkService and the gateway computer account.'
        return
    }

    if ($reservationExists) {
        & netsh.exe http delete urlacl "url=$url" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to replace the existing WAC URL reservation for '$url'."
        }
    }

    & netsh.exe http add urlacl "url=$url" "sddl=$desiredSddl" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $addExitCode = $LASTEXITCODE

        if ($reservationExists) {
            & netsh.exe http add urlacl "url=$url" "sddl=$originalSddl" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Adding the WAC URL reservation failed with exit code $addExitCode, and restoring its previous ACL also failed."
            }
        }

        throw "Adding the WAC URL reservation failed with exit code $addExitCode."
    }

    Write-Log 'WAC HTTPS URL reservation grants listen permission to NetworkService and the gateway computer account.'
}

function Get-WacServices {
    # Treat a partial service set as an incomplete install so the main flow can report it.
    $serviceNames = @(
        'WindowsAdminCenter'
        'WindowsAdminCenterAccountManagement'
    )
    $foundServices = @()

    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            $foundServices += $service
        }
    }

        return $foundServices
}

function Start-AndVerifyWacServices {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Services
    )

    # Starting a service is asynchronous; wait for each service to report Running.
    foreach ($service in $Services) {
        if ($service.Status -ne 'Running') {
            Write-Log "Starting $($service.Name)."
            Start-Service -Name $service.Name -ErrorAction Stop
        }

        $service = Get-Service -Name $service.Name -ErrorAction Stop
        $service.WaitForStatus('Running', [TimeSpan]::FromMinutes(2))

        if ((Get-Service -Name $service.Name).Status -ne 'Running') {
            throw "$($service.Name) did not reach the Running state."
        }
    }
}

function Repair-WacConfiguration {
    # Repair only AMRL-owned settings; do not reinstall or automatically upgrade WAC.
    $configurationModule = Join-Path `
        $env:ProgramFiles `
        'WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration'

    Import-Module `
        -Name $configurationModule `
        -ErrorAction Stop

    Set-WACLoginMode `
        -Mode WindowsAuthentication `
        -ErrorAction Stop

    $appSettingsPath = Join-Path `
    $env:ProgramFiles `
    'WindowsAdminCenter\Service\appsettings.json'

    $appSettings = Get-Content `
        -LiteralPath $appSettingsPath `
        -Raw |
        ConvertFrom-Json

    # Use HTTP for gateway-to-server WinRM until the lab provisions server certificates.
    $appSettings.WindowsAdminCenter.FeatureParameters.Base.WinRmOverHttps = $false

    $appSettings |
        ConvertTo-Json -Depth 100 |
        Set-Content `
            -LiteralPath $appSettingsPath `
            -Encoding UTF8

    Set-WACWinRmTrustedHosts `
        -ErrorAction Stop

    $adTools = Get-WindowsFeature RSAT-AD-PowerShell

    if (-not $adTools.Installed) {
        Write-Log 'Installing RSAT-AD-PowerShell.'

        Install-WindowsFeature `
            RSAT-AD-PowerShell `
            -IncludeManagementTools
    }

    $httpsPorts = Get-WACHttpsPorts
    if ($null -eq $httpsPorts -or [int]$httpsPorts.WacPort -lt 1) {
        throw 'Windows Admin Center did not report a valid HTTPS listener port before repair.'
    }

    $wacPort = [int]$httpsPorts.WacPort
    $certificate = Get-WACSelfSignedCertificate
    if ($null -eq $certificate) {
        throw 'Windows Admin Center did not report its configured TLS certificate before repair.'
    }

    $expectedThumbprint = $certificate.Thumbprint -replace '\s', ''
    $bindingPattern = '(?im)^\s*Certificate Hash\s*:\s*' + [regex]::Escape($expectedThumbprint) + '\s*$'
    $sslBinding = @(& netsh.exe http show sslcert "ipport=0.0.0.0:$wacPort" 2>$null) -join [Environment]::NewLine
    if ($sslBinding -notmatch $bindingPattern) {
        Write-Log "HTTP.SYS certificate binding is absent on port $wacPort; asking WAC to register its HTTPS endpoint."

        # WAC's cmdlet emits a WriteErrorException for the expected missing-binding probe,
        # then continues to register the certificate. Keep that probe non-terminating;
        # do not catch it, because a catch can stop the cmdlet before its registration step.
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            Register-WACHttpSys `
                -Thumbprint $certificate.Thumbprint `
                -Port $wacPort `
                -Force `
                -Verbose `
                -ErrorAction Continue
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        $sslBinding = @(& netsh.exe http show sslcert "ipport=0.0.0.0:$wacPort" 2>$null) -join [Environment]::NewLine
        if ($sslBinding -notmatch $bindingPattern) {
            throw "WAC did not register the expected TLS certificate binding on port $wacPort."
        }

        Write-Log "WAC HTTP.SYS certificate binding matches the configured certificate on port $wacPort."
    }

    # Register-WACHttpSys can replace the URL ACL, so reconcile the required service
    # and gateway identities after its registration attempt as well as on ordinary reruns.
    Ensure-WacUrlReservation -Port $wacPort

    Restart-WACService

    $service = Get-Service WindowsAdminCenter -ErrorAction Stop
    $service.WaitForStatus('Running', [TimeSpan]::FromMinutes(2))

    if ($service.Status -ne 'Running') {
        throw 'Windows Admin Center service failed to remain running after restart.'
    }

    Write-Log 'Windows Admin Center service is running.'

}

function Test-WacConfiguration {
    # Validate the installed gateway through WAC's configuration API and its actual listener.
    $configurationModule = Join-Path $env:ProgramFiles 'WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration'
    if (-not (Test-Path -LiteralPath $configurationModule)) {
        throw "Windows Admin Center configuration module was not found at $configurationModule."
    }

    Import-Module -Name $configurationModule -ErrorAction Stop

    $installationStatus = [string](Get-WACInstallationStatus)
    if ($installationStatus -ne 'StandardInstalled') {
        throw "Unexpected Windows Admin Center installation status: $installationStatus."
    }

    # Validate WAC's own reported listener rather than assuming HTTP.SYS owns the port.
    $httpsPorts = Get-WACHttpsPorts

    if ($null -eq $httpsPorts -or [int]$httpsPorts.WacPort -lt 1) {
        throw 'Windows Admin Center did not report a valid HTTPS listener port.'
    }

    $listener = Test-NetConnection `
        -ComputerName localhost `
        -Port $httpsPorts.WacPort `
        -WarningAction SilentlyContinue

    if (-not $listener.TcpTestSucceeded) {
        throw "Windows Admin Center is not listening on TCP port $($httpsPorts.WacPort)."
    }

    $loginMode = [string](Get-WACLoginMode)

    # WAC returns endpoint configuration as an object; read the FQDN field explicitly.
    $endpointConfiguration = Get-WACEndpointFqdn
    $endpointFqdn = $endpointConfiguration['EndpointFqdn']
    Write-Log "Detected EndpointFqdn: $endpointFqdn"

    $winRmOverHttps = [bool](Get-WACWinRmOverHttps)
    # This verifies certificate presence only, not its hostname identity or trust chain.
    $certificate = Get-WACSelfSignedCertificate

    if ([string]::IsNullOrWhiteSpace($loginMode)) {
        throw 'Windows Admin Center did not report a login mode.'
    }
    if ([string]::IsNullOrWhiteSpace($endpointFqdn)) {
        throw 'Windows Admin Center did not report an endpoint FQDN.'
    }
    if ($null -eq $certificate) {
        throw 'Windows Admin Center did not report its configured TLS certificate.'
    }

    $adTools = Get-WindowsFeature RSAT-AD-PowerShell

    if (-not $adTools.Installed) {
        throw 'RSAT-AD-PowerShell is required for Windows Admin Center Active Directory discovery.'
    }

    Write-Log "Configuration verified: status=$installationStatus; port=$($httpsPorts.WacPort); login=$loginMode; endpoint=$endpointFqdn; ADToolsInstalled=$($adTools.Installed); WinRMOverHttps=$winRmOverHttps."
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [int]$MaximumAttempts = 5
    )

    # Retry transient DNS/network failures, but fail immediately on permanent HTTP 4xx errors.
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            & $Action
            return
        }
        catch {
            $statusCode = $null
            if ($null -ne $_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
            }

            if ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -notin @(408, 429)) {
                throw "$Operation failed with HTTP $statusCode. $($_.Exception.Message)"
            }

            if ($attempt -eq $MaximumAttempts) {
                throw "$Operation failed after $MaximumAttempts attempts. $($_.Exception.Message)"
            }

            $delaySeconds = [int][Math]::Min(30, 5 * [Math]::Pow(2, $attempt - 1))
            Write-Log "$Operation failed on attempt $attempt of $MaximumAttempts; retrying in $delaySeconds seconds. $($_.Exception.Message)"
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

Write-Log "Reconciliation token: $ReconciliationToken"

New-Item -Path $downloadDirectory -ItemType Directory -Force | Out-Null

Write-Log "Using Microsoft's $installerChannel WAC v2 download endpoint."
$existingServices = @(Get-WacServices)
# Existing services take the repair path; only a fresh install downloads the installer.
if ($existingServices.Count -gt 0) {
    Write-Log 'Windows Admin Center is already installed; skipping reinstall and upgrade.'

    Repair-WacConfiguration

    Start-AndVerifyWacServices -Services $existingServices

    Test-WacConfiguration

    Write-Log 'Existing Windows Admin Center installation validated.'

    return
}

$installerHost = ([System.Uri]$installerUri).Host
Invoke-WithRetry -Operation "DNS resolution for $installerHost" -Action {
    Resolve-DnsName -Name $installerHost -ErrorAction Stop | Out-Null
}

Invoke-WithRetry -Operation 'Current WAC installer download' -Action {
    Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest `
        -Uri $installerUri `
        -OutFile $installerPath `
        -UseBasicParsing `
        -TimeoutSec 180 `
        -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $installerPath) -or (Get-Item -LiteralPath $installerPath).Length -eq 0) {
        throw 'The WAC installer download is missing or empty.'
    }
}

$signature = Get-AuthenticodeSignature -FilePath $installerPath
if ($signature.Status -ne 'Valid') {
    throw "WAC installer signature validation failed. Status: $($signature.Status)."
}

Write-Log "Installer signer: $($signature.SignerCertificate.Subject)"
Write-Log 'Installing Windows Admin Center.'

$process = Start-Process `
    -FilePath $installerPath `
    -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$installLog`"" `
    -PassThru

Write-Log "Installer launched with PID $($process.Id)."

# Preserve the installer exit code before checking that its services were registered.
$process.WaitForExit()

if ($process.ExitCode -ne 0) {
    throw "WAC installer failed with exit code $($process.ExitCode)."
}

Write-Log "Installer completed with exit code $($process.ExitCode)."

$deadline = (Get-Date).AddMinutes(15)

# The installer can exit before Windows reports both services; allow bounded time for registration.
do {
    Start-Sleep -Seconds 10

    $installedServices = @(Get-WacServices)

    if ($installedServices.Count -eq 2) {
        Write-Log 'Windows Admin Center services detected.'
        break
    }
}
while ((Get-Date) -lt $deadline)

if ($installedServices.Count -ne 2) {

    if (Test-Path -LiteralPath $installLog) {
        Get-Content -LiteralPath $installLog -Tail 20 | ForEach-Object { Write-Log $_ }
    }
    throw 'The installer exited successfully, but both WAC services were not found.'
}

Repair-WacConfiguration

Start-AndVerifyWacServices -Services $installedServices
Test-WacConfiguration

Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

Write-Log 'Windows Admin Center installer completed successfully.'