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

function Get-WacServices {
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

    Restart-WACService
}

function Test-WacConfiguration {
    $configurationModule = Join-Path $env:ProgramFiles 'WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration'
    if (-not (Test-Path -LiteralPath $configurationModule)) {
        throw "Windows Admin Center configuration module was not found at $configurationModule."
    }

    Import-Module -Name $configurationModule -ErrorAction Stop

    $installationStatus = [string](Get-WACInstallationStatus)
    if ($installationStatus -ne 'StandardInstalled') {
        throw "Unexpected Windows Admin Center installation status: $installationStatus."
    }

    $httpsPorts = Get-WACHttpsPorts

    $listener = Test-NetConnection `
        -ComputerName localhost `
        -Port $httpsPorts.WacPort `
        -WarningAction SilentlyContinue

    if (-not $listener.TcpTestSucceeded) {
        throw "Windows Admin Center is not listening on TCP port $($httpsPorts.WacPort)."
    }

    $loginMode = [string](Get-WACLoginMode)

    $endpointConfiguration = Get-WACEndpointFqdn
    $endpointFqdn = $endpointConfiguration['EndpointFqdn']
    Write-Log "Detected EndpointFqdn: $endpointFqdn"

    $winRmOverHttps = [bool](Get-WACWinRmOverHttps)
    $certificate = Get-WACSelfSignedCertificate

    if ($null -eq $httpsPorts -or [int]$httpsPorts.WacPort -lt 1) {
        throw 'Windows Admin Center did not report a valid HTTPS listener port.'
    }
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

$deadline = (Get-Date).AddMinutes(15)

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