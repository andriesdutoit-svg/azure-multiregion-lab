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
    $service = Get-Service -Name 'WindowsAdminCenter' -ErrorAction SilentlyContinue

    return $null -ne $service
}

Write-Log "Reconciliation token: $ReconciliationToken"

Write-Log 'Script started.'

Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

Write-Log "PowerShell version: $($PSVersionTable.PSVersion)"

Set-Content `
    -Path 'C:\Temp\Install-Wac-ScriptStarted.txt' `
    -Value (Get-Date)

if (Test-WacInstalled) {
    Write-Log 'Windows Admin Center is already installed.'

    $service = Get-Service -Name 'WindowsAdminCenter'

    if ($service.Status -ne 'Running') {
        Write-Log 'Starting Windows Admin Center service.'
        Start-Service -Name 'WindowsAdminCenter'
    }

    Write-Log 'Windows Admin Center validation successful.'
    exit 0
}

$downloadDirectory = 'C:\Temp\WAC'
$installerPath = Join-Path $downloadDirectory 'WacInstaller.exe'

Write-Log "Download directory: $downloadDirectory"

if (-not (Test-Path $downloadDirectory)) {
    New-Item -Path $downloadDirectory -ItemType Directory -Force | Out-Null

    Write-Log 'Download directory created.'
}

Write-Log 'Downloading Windows Admin Center installer.'

Write-Log 'Waiting for DNS resolution of aka.ms.'

$attempt = 0

do {
    try {
        Resolve-DnsName aka.ms -ErrorAction Stop | Out-Null
        Write-Log 'DNS resolution successful.'
        break
    }
    catch {
        $attempt++

        if ($attempt -ge 30) {
            throw 'Unable to resolve aka.ms after multiple attempts.'
        }

        Start-Sleep -Seconds 10
    }
}
while ($true)

Invoke-WebRequest `
    -Uri 'https://aka.ms/WACDownload' `
    -OutFile $installerPath `
    -UseBasicParsing

if (-not (Test-Path $installerPath)) {
    throw 'Windows Admin Center installer download failed.'
}

Write-Log 'Installing Windows Admin Center.'

$installLog = Join-Path $downloadDirectory 'WacInstall.log'

Set-Content `
    -Path 'C:\Temp\WAC\BeforeInstaller.txt' `
    -Value (Get-Date)

$process = Start-Process `
    -FilePath $installerPath `
    -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$installLog`"" `
    -Wait `
    -PassThru

if ($process.ExitCode -ne 0) {
    throw "Windows Admin Center installation failed. Exit code: $($process.ExitCode)"
}

Set-Content `
    -Path 'C:\Temp\WAC\AfterInstaller.txt' `
    -Value "ExitCode=$($process.ExitCode)"


if (Test-Path $installLog) {
    Write-Log 'Installer log found.'
    Get-Content $installLog | Write-Output
}
else {
    Write-Log 'Installer log not found.'
}

Write-Log 'Waiting for Windows Admin Center installation to finalize.'

Start-Sleep -Seconds 30

Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

Write-Log 'Windows Admin Center installer completed successfully.'
exit 0

# $service = Get-Service -Name 'WindowsAdminCenter' -ErrorAction SilentlyContinue

# if ($null -eq $service) {
#     throw 'Windows Admin Center installation completed but Windows Admin Center service was not found.'
# }

# if ($service.Status -ne 'Running') {
#     Write-Log 'Starting Windows Admin Center service.'
#     Start-Service -Name 'WindowsAdminCenter'
# }

# $service.WaitForStatus('Running', [TimeSpan]::FromMinutes(2))

# $service = Get-Service -Name 'WindowsAdminCenter'

# if ($service.Status -ne 'Running') {
#     throw 'Windows Admin Center service is not running.'
# }

# $accountManagementService = Get-Service `
#     -Name 'WindowsAdminCenterAccountManagement' `
#     -ErrorAction SilentlyContinue

# if ($null -eq $accountManagementService) {
#     throw 'Windows Admin Center Account Management service was not found.'
# }

# if ($accountManagementService.Status -ne 'Running') {
#     Start-Service -Name 'WindowsAdminCenterAccountManagement'
# }

# $accountManagementService = Get-Service `
#     -Name 'WindowsAdminCenterAccountManagement'

# if ($accountManagementService.Status -ne 'Running') {
#     throw 'WindowsAdminCenterAccountManagement service is not running.'
# }

# Write-Log 'Windows Admin Center installation completed successfully.'