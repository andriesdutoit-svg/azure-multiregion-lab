param(
    [string]$ReconciliationToken
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [string]$Message
    )

    Write-Output "[WAC] $Message"
}

function Test-WacInstalled {
    $service = Get-Service -Name 'ServerManagementGateway' -ErrorAction SilentlyContinue

    return $null -ne $service
}

Write-Log "Reconciliation token: $ReconciliationToken"

if (Test-WacInstalled) {
    Write-Log 'Windows Admin Center is already installed.'

    $service = Get-Service -Name 'ServerManagementGateway'

    if ($service.Status -ne 'Running') {
        Write-Log 'Starting ServerManagementGateway service.'
        Start-Service -Name 'ServerManagementGateway'
    }

    Write-Log 'Windows Admin Center validation successful.'
    exit 0
}

$downloadDirectory = 'C:\Temp\WAC'
$installerPath = Join-Path $downloadDirectory 'WindowsAdminCenter.msi'

if (-not (Test-Path $downloadDirectory)) {
    New-Item -Path $downloadDirectory -ItemType Directory -Force | Out-Null
}

Write-Log 'Downloading Windows Admin Center installer.'

Invoke-WebRequest `
    -Uri 'https://aka.ms/WACDownload' `
    -OutFile $installerPath `
    -UseBasicParsing

if (-not (Test-Path $installerPath)) {
    throw 'Windows Admin Center installer download failed.'
}

Write-Log 'Installing Windows Admin Center.'

$arguments = @(
    '/i'
    "`"$installerPath`""
    'SME_PORT=6516'
    'SSL_CERTIFICATE_OPTION=generate'
    '/qn'
    '/norestart'
)

$process = Start-Process `
    -FilePath 'msiexec.exe' `
    -ArgumentList $arguments `
    -Wait `
    -PassThru

if ($process.ExitCode -ne 0) {
    throw "Windows Admin Center installation failed. Exit code: $($process.ExitCode)"
}

Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

$service = Get-Service -Name 'ServerManagementGateway' -ErrorAction SilentlyContinue

if ($null -eq $service) {
    throw 'Windows Admin Center installation completed but ServerManagementGateway service was not found.'
}

if ($service.Status -ne 'Running') {
    Write-Log 'Starting ServerManagementGateway service.'
    Start-Service -Name 'ServerManagementGateway'
}

$service = Get-Service -Name 'ServerManagementGateway'

if ($service.Status -ne 'Running') {
    throw 'ServerManagementGateway service is not running.'
}

Write-Log 'Windows Admin Center installation completed successfully.'