<#
.SYNOPSIS
Prepares AMRL prerequisites and Bicep configuration, with optional deployment.
Creates or reuses subscription-level identity/RBAC, Key Vault credentials, and
protection locks. Configures Bicep parameters and runs template preflight/what-if.
Normal preparation does not deploy the lab; existing subscriptions are supported.
.PARAMETER ParameterFile
Existing JSON parameter file. Omit to use the wizard with local or demo defaults.
.PARAMETER Plan
Inspects readiness without resource changes or saving interactive choices.
Temporary parameter files may be used for validate/what-if and are removed.
.PARAMETER Prepare
Configures subscription-level items and checks Bicep values with preflight and what-if; does not deploy lab resources.
.PARAMETER IncludeGitHub
Configures optional Entra OIDC identity/access and GitHub Actions deployment values.
In Plan mode, inspects those settings without changing them.
.PARAMETER ReportPath
Optional path for writing the final bootstrapper report as UTF-8 plain text.
.PARAMETER Deploy
Deploys main.bicep after preparation, what-if, and explicit DEPLOY confirmation.
.NOTES
Bicep inputs are evaluated by the AMRL validation engine and its enforcement gate. Retained inventory must be
declared by the operator; deployment success does not prove guest readiness.
#>

# 1. Invocation options and local parameter-file selection
[CmdletBinding()]
param(
    [string]$ParameterFile,
    [string]$ReportPath,
    [switch]$Plan,
    [switch]$Prepare,
    [switch]$IncludeGitHub,
    [switch]$Deploy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:InteractiveConfiguration = [string]::IsNullOrWhiteSpace($ParameterFile)
$script:ParameterFileWasExplicit = -not $script:InteractiveConfiguration
$script:PlanMode = $false
$script:PromptForPasswords = $false
$script:PasswordChoiceMade = $false
$script:BootstrapperPhase = 'Parameter initialization'
$script:DeploymentAttempted = $false
$script:FoundationSetupFailed = $false
$script:BootstrapperReport = $null
$script:DiagnosticDeadline = $null
if ([string]::IsNullOrWhiteSpace($ParameterFile)) {
    $script:ParameterFilePath = Join-Path $script:RepositoryRoot 'main.parameters.local.json'
}
elseif ([System.IO.Path]::IsPathRooted($ParameterFile)) {
    $script:ParameterFilePath = $ParameterFile
}
else {
    $script:ParameterFilePath = Join-Path $script:RepositoryRoot $ParameterFile
}

# 2. CLI execution and operational prerequisite checks

# AMRL platform defaults
$script:AMRLDefaultsPath = Join-Path $PSScriptRoot '..\config\amrl-defaults.json'
$script:AMRLDefaults = Get-Content -Raw -LiteralPath $script:AMRLDefaultsPath | ConvertFrom-Json

# Reject missing or placeholder values at the point a shared repository default is consumed.
function Get-AMRLDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $script:AMRLDefaults.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value) -or $property.Value -match '[<>]') {
        throw "AMRL defaults must define a concrete non-empty string for '$Name'."
    }
    return $property.Value
}

function Get-AMRLManagedSecretNames {
    return @(
        (Get-AMRLDefault 'jumpboxAdminPasswordSecretName')
        (Get-AMRLDefault 'labAdminPasswordSecretName')
        [string]$script:AMRLDefaults.directory.serviceAccounts.backup.passwordSecretName
        [string]$script:AMRLDefaults.directory.serviceAccounts.monitoring.passwordSecretName
        (Get-AMRLDefault 'sshPublicKeySecretName')
        (Get-AMRLDefault 'sshPrivateKeySecretName')
    )
}

function Get-AMRLPasswordSecretNames {
    return @(
        (Get-AMRLDefault 'jumpboxAdminPasswordSecretName')
        (Get-AMRLDefault 'labAdminPasswordSecretName')
        [string]$script:AMRLDefaults.directory.serviceAccounts.backup.passwordSecretName
        [string]$script:AMRLDefaults.directory.serviceAccounts.monitoring.passwordSecretName
    )
}

# Windows MSI installs expose Azure CLI through az.cmd; invoke its bundled Python directly
# so JSON output can be decoded as UTF-8 rather than the active Windows code page.
function Get-AMRLAzCliInvocation {
    $command = Get-Command az -ErrorAction Stop
    if ($command.CommandType -eq 'Application' -and [System.IO.Path]::GetFileName($command.Source) -ieq 'az.cmd') {
        $installationPath = Split-Path -Parent (Split-Path -Parent $command.Source)
        $pythonPath = Join-Path $installationPath 'python.exe'
        if (Test-Path -LiteralPath $pythonPath) {
            return [pscustomobject]@{ Command = $pythonPath; Prefix = @('-X', 'utf8', '-IBm', 'azure.cli'); Installer = 'MSI' }
        }
    }
    return [pscustomobject]@{ Command = 'az'; Prefix = @(); Installer = $null }
}

function Invoke-AMRLTimedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @(),
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 20
    )

    $application = Get-Command $Command -CommandType Application -ErrorAction Stop
    $argumentText = @($Arguments | ForEach-Object {
        '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }) -join ' '
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $application.Source
    $startInfo.Arguments = $argumentText
    if ([System.IO.Path]::GetExtension($application.Source) -ieq '.cmd') {
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = '/d /s /c ""' + $application.Source + '" ' + $argumentText + '"'
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F 2>&1 | Out-Null }
            catch { if (-not $process.HasExited) { $process.Kill() } }
            throw "Azure CLI diagnostic read timed out after $TimeoutSeconds seconds. Only the local query process was stopped; the Azure deployment was not cancelled."
        }
        return [pscustomobject]@{
            Output = $stdout.GetAwaiter().GetResult()
            ErrorOutput = $stderr.GetAwaiter().GetResult()
            ExitCode = $process.ExitCode
        }
    }
    finally { $process.Dispose() }
}

# Centralize Azure CLI invocation, exit-code handling, text decoding, and narrowly scoped
# retries so callers receive either complete output or a terminating, actionable error.
function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [ValidateRange(0, 600)][int]$TimeoutSeconds = 0
    )

    $operation = {
        $previousErrorActionPreference = $ErrorActionPreference
        $previousPythonEncoding = [System.Environment]::GetEnvironmentVariable('PYTHONIOENCODING', 'Process')
        $previousInstaller = [System.Environment]::GetEnvironmentVariable('AZ_INSTALLER', 'Process')
        $previousConsoleEncoding = [Console]::OutputEncoding
        try {
            $ErrorActionPreference = 'Continue'
            [System.Environment]::SetEnvironmentVariable('PYTHONIOENCODING', 'utf-8', 'Process')
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $invocation = Get-AMRLAzCliInvocation
            if ($null -ne $invocation.Installer) { [System.Environment]::SetEnvironmentVariable('AZ_INSTALLER', $invocation.Installer, 'Process') }
            $command = $invocation.Command
            $commandArguments = @($invocation.Prefix) + $Arguments
            if ($TimeoutSeconds -gt 0) {
                $response = Invoke-AMRLTimedProcess -Command $command -Arguments $commandArguments -TimeoutSeconds $TimeoutSeconds
                $exitCode = $response.ExitCode
                $text = $response.Output
                if ($exitCode -ne 0) { $text += [Environment]::NewLine + $response.ErrorOutput }
                elseif (-not [string]::IsNullOrWhiteSpace($response.ErrorOutput)) { Write-Verbose $response.ErrorOutput.Trim() }
            }
            else {
                $output = & $command @commandArguments 2>&1
                $exitCode = $LASTEXITCODE
                $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
            }
            if ($exitCode -ne 0) {
                throw "Azure CLI failed (exit $exitCode): az $($Arguments -join ' ')`n$text"
            }
            return $text.Trim()
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
            [Console]::OutputEncoding = $previousConsoleEncoding
            [System.Environment]::SetEnvironmentVariable('PYTHONIOENCODING', $previousPythonEncoding, 'Process')
            [System.Environment]::SetEnvironmentVariable('AZ_INSTALLER', $previousInstaller, 'Process')
        }
    }

    # Retry only eligible setup calls; Plan uses single-attempt, read-only checks.
    $commandPath = ($Arguments | Select-Object -First 3) -join ' '
    if (-not $script:PlanMode -and $commandPath -like 'keyvault secret *') {
        # Key Vault data-plane RBAC can lag management-plane assignment by several minutes.
        return Invoke-AMRLRbacRetry -Operation $operation -MaximumAttempts 23 -InitialDelaySeconds 5
    }
    if (-not $script:PlanMode -and ($commandPath -eq 'role assignment create' -or $commandPath -eq 'role assignment list')) {
        return Invoke-AMRLRbacRetry -Operation $operation
    }
    return (& $operation)
}

function Invoke-AMRLRbacRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [ValidateRange(1, 32)][int]$MaximumAttempts = 6,
        [ValidateRange(0, 30)][int]$InitialDelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try { return (& $Operation) }
        catch {
            $message = $_.Exception.Message
            $explicitDenyAssignment = $message -match '(?i)\bDenyAssignment(?:AuthorizationFailed|Denied|Blocked)\b' -or
                $message -match '(?i)\bDenyAssignmentId:\s*(?!null\b)[^\s]+'
            if ($message -match 'ForbiddenByFirewall|ForbiddenByConnection' -or $explicitDenyAssignment -or
                $message -notmatch 'ForbiddenByRbac|PrincipalNotFound|Cannot find user or service principal in graph database|RBAC.*propagat' -or
                $attempt -eq $MaximumAttempts) {
                throw
            }
            $delay = [int][Math]::Min(30, $InitialDelaySeconds * [Math]::Pow(2, $attempt - 1))
            Write-Warning "Waiting for RBAC propagation (attempt $attempt of $MaximumAttempts); retrying in $delay seconds."
            if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        }
    }
}

function Get-AMRLGitBranch {
    $branch = ([string](git -C $script:RepositoryRoot branch --show-current)).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
        throw 'Select an active Git branch before configuring GitHub OIDC.'
    }
    return $branch
}

# Foundation resources and the subscription-scope deployment use the lowest-index mapped region;
# this is separate from the operator's Azure CLI subscription context.
function Get-AMRLFoundationLocation {
    param([Parameter(Mandatory = $true)][object]$Parameters)

    $orderedRegions = @($Parameters.parameters.regionIndexMap.value.PSObject.Properties | Sort-Object { [int]$_.Value })
    if ($orderedRegions.Count -eq 0) { throw 'regionIndexMap is empty; cannot choose the foundation resource location.' }
    return [string]$orderedRegions[0].Name
}

function Assert-AMRLPrerequisites {
    param([switch]$IncludeGitHub)

    $issues = New-Object 'System.Collections.Generic.List[string]'
    $tools = @('az', 'ssh-keygen')
    if ($IncludeGitHub) { $tools += @('git', 'gh') }
    foreach ($tool in $tools) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $issues.Add("Install the required command: $tool") }
    }
    if (Get-Command az -ErrorAction SilentlyContinue) {
        try { Invoke-AzCli -Arguments @('bicep', 'version') | Out-Null }
        catch { $issues.Add('Bicep is unavailable. Install/configure Bicep for Azure CLI before setup.') }
    }
    if ($IncludeGitHub) {
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            try { Invoke-GhCli -Arguments @('auth', 'status') | Out-Null }
            catch { $issues.Add('GitHub CLI is not authenticated. Sign in directly using GitHub CLI before setup.') }
        }
        if (Get-Command git -ErrorAction SilentlyContinue) {
            try { Get-AMRLGitBranch | Out-Null }
            catch { $issues.Add($_.Exception.Message) }
        }
    }
    if ($issues.Count -gt 0) { throw "Bootstrap prerequisites are not ready:`n- $($issues -join "`n- ")" }
}

# Explicit parameter files must match the active CLI context; the interactive path lets the
# operator confirm, choose a saved subscription, or sign in before continuing.
function Get-AMRLAzureContext {
    param(
        [string]$ExpectedSubscriptionId,
        [string]$ExpectedTenantId,
        [switch]$RequireParameterFileContext
    )

    if ($RequireParameterFileContext) {
        foreach ($entry in @(@{ Name = 'subscription ID'; Value = $ExpectedSubscriptionId }, @{ Name = 'tenant ID'; Value = $ExpectedTenantId })) {
            if ([string]::IsNullOrWhiteSpace($entry.Value) -or $entry.Value -match '[<>]') {
                throw "The explicit parameter file must define a valid Azure $($entry.Name) in prefix.metadata.bootstrap."
            }
        }
        try { $context = Get-AzJson -Arguments @('account', 'show') }
        catch { throw "Could not read the Azure CLI context required by the explicit parameter file. Sign in and select the configured subscription. Details: $($_.Exception.Message)" }
        if ([string]$context.id -ine $ExpectedSubscriptionId -or [string]$context.tenantId -ine $ExpectedTenantId) {
            throw "The active Azure CLI context does not match the explicit parameter file (tenant '$ExpectedTenantId', subscription '$ExpectedSubscriptionId'). Run az login --tenant '$ExpectedTenantId' and az account set --subscription '$ExpectedSubscriptionId', then retry."
        }
        Write-Host "Azure account: $($context.user.name)"
        Write-Host "Tenant: $($context.tenantId) (parameter file)"
        Write-Host "Subscription: $($context.name) ($($context.id), parameter file)"
        Set-AMRLReportSource -Name 'Azure context' -Status 'Matched parameter file' -Summary "Tenant: $($context.tenantId); subscription: $($context.id)."
        if ($null -ne $script:BootstrapperReport) { $script:BootstrapperReport.Context = $context }
        return $context
    }

    $context = $null
    while ($true) {
        if ($null -eq $context) {
            try { $context = Get-AzJson -Arguments @('account', 'show') }
            catch {
                $context = $null
                Add-AMRLReportIssue -Phase 'Azure context' -Severity Warning -Message "Could not read the current Azure CLI context: $($_.Exception.Message)"
            }
        }

        if ($null -ne $context -and -not [string]::IsNullOrWhiteSpace([string]$context.id) -and -not [string]::IsNullOrWhiteSpace([string]$context.tenantId)) {
            Write-Host "Azure account: $($context.user.name)"
            Write-Host "Tenant: $($context.tenantId)"
            Write-Host "Subscription: $($context.name) ($($context.id))"
            $useCurrentContext = Read-RequiredValue -Prompt 'Use this tenant and subscription?' -Hint 'y/N' -DefaultValue 'yes' -IssuePhase 'Azure context' -Validator {
                param($Value) $Value -in @('yes', 'no', 'y', 'n')
            }
            if ($useCurrentContext -in @('yes', 'y')) {
                Set-AMRLReportSource -Name 'Azure context' -Status 'Confirmed' -Summary "Account: $($context.user.name); tenant: $($context.tenantId); subscription: $($context.id)."
                if ($null -ne $script:BootstrapperReport) { $script:BootstrapperReport.Context = $context }
                return $context
            }
        }
        else {
            Write-Host 'No active Azure tenant and subscription are available. Select a saved subscription or sign in.'
        }

        $accounts = @()
        try { $accounts = @(Get-AzJson -Arguments @('account', 'list', '--all')) }
        catch {
            Add-AMRLReportIssue -Phase 'Azure context' -Severity Warning -Message "Could not list saved Azure subscriptions: $($_.Exception.Message)"
        }

        if ($accounts.Count -gt 0) {
            Write-Host 'Available Azure subscriptions:'
            for ($index = 0; $index -lt $accounts.Count; $index++) {
                $account = $accounts[$index]
                $stateProperty = $account.PSObject.Properties['state']
                $state = if ($null -eq $stateProperty) { 'unknown' } else { [string]$stateProperty.Value }
                Write-Host ("  [{0}] {1} ({2}); tenant {3}; state {4}" -f ($index + 1), $account.name, $account.id, $account.tenantId, $state)
            }
            $choice = Read-RequiredValue -Prompt 'Select a subscription number or enter L to sign in' -Hint 'subscription number or L' -IssuePhase 'Azure context' -Validator {
                param($Value)
                if ([string]$Value -match '^[Ll]$') { return $true }
                $selectedIndex = 0
                [int]::TryParse([string]$Value, [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $accounts.Count
            }
            if ($choice -match '^[Ll]$') {
                $context = $null
                continue
            }

            $selectedIndex = [int]$choice - 1
            Invoke-AzCli -Arguments @('account', 'set', '--subscription', [string]$accounts[$selectedIndex].id) | Out-Null
            $context = $null
            continue
        }

        $tenant = Read-Host 'Tenant ID or verified domain for Azure sign-in (press Enter for default tenant)'
        if ([string]::IsNullOrWhiteSpace($tenant)) {
            Invoke-AzCli -Arguments @('login') | Out-Null
        }
        else {
            Invoke-AzCli -Arguments @('login', '--tenant', $tenant.Trim()) | Out-Null
        }
        $context = $null
    }
}

function Assert-AMRLGitHubRepositoryAccess {
    param([Parameter(Mandatory = $true)][string]$Repository)

    $permission = Invoke-GhCli -Arguments @('repo', 'view', $Repository, '--json', 'viewerPermission', '--jq', '.viewerPermission')
    if ($permission -notin @('ADMIN', 'MAINTAIN', 'WRITE')) {
        throw "GitHub repository '$Repository' requires write access to configure Actions secrets and variables."
    }
    Invoke-GhCli -Arguments @('secret', 'list', '--repo', $Repository, '--json', 'name') | Out-Null
    Invoke-GhCli -Arguments @('variable', 'list', '--repo', $Repository, '--json', 'name') | Out-Null
}

function Invoke-GhCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & gh @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "GitHub CLI failed (exit $exitCode): gh $($Arguments -join ' ')`n$text"
    }

    return $text.Trim()
}

function Get-AzJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $json = Invoke-AzCli -Arguments ($Arguments + @('--output', 'json'))
    if ([string]::IsNullOrWhiteSpace($json) -or $json -eq 'null') {
        return $null
    }
    return ($json | ConvertFrom-Json)
}

# Keep Azure CLI response formats explicit: use JSON for structured objects and TSV only for
# simple scalar checks such as existence and resource IDs.
function Get-AzTsv {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    return (Invoke-AzCli -Arguments ($Arguments + @('--output', 'tsv'))).Trim()
}

# 3. Saved Bicep findings and guest execution reporting
# These functions only shape and save results returned by Azure. They do not rerun VM scripts
# or infer success when deployment outputs or Run Command instance views are missing.
function Initialize-AMRLBootstrapperReport {
    param([string]$Mode)

    $script:DeploymentAttempted = $false
    $script:FoundationSetupFailed = $false
    $phases = New-Object 'System.Collections.Generic.List[object]'
    foreach ($phaseName in @(
        'Parameter configuration',
        'Azure readiness and foundation',
            'Plan prerequisite checks',
        'Bicep build and validation',
        'What-if preview',
        'Deployment',
        'AMRL validation engine outputs',
        'VM setup checks'
    )) {
        $phases.Add([pscustomobject]@{ Name = $phaseName; Status = 'Pending'; Summary = '' })
    }
    if ($Mode -ne 'Plan') {
        $planPhase = @($phases | Where-Object { $_.Name -eq 'Plan prerequisite checks' })[0]
        $planPhase.Status = 'Not applicable'
        $planPhase.Summary = 'This run did not use plan mode.'
    }
    $script:BootstrapperReport = [pscustomobject]@{
        StartedAt = Get-Date
        CompletedAt = $null
        Mode = $Mode
        Status = 'Running'
        Phases = $phases
        Issues = New-Object 'System.Collections.Generic.List[object]'
        Sources = [ordered]@{}
        Validation = $null
        GuestResults = @()
        AppliedChanges = @()
        DeploymentStages = @()
        DeploymentState = 'Unavailable'
        OperationSnapshots = @{}
        OperationSnapshotDeploymentName = ''
        FoundationChanges = New-Object 'System.Collections.Generic.List[object]'
        Context = $null
        Parameters = $null
        FoundationLocation = ''
        FoundationConfiguration = $null
        PublicIp = ''
    }
}

function Set-AMRLReportPhase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Summary
    )

    if ($null -eq $script:BootstrapperReport) { return }
    $phase = @($script:BootstrapperReport.Phases | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
    if ($phase.Count -eq 0) {
        $phase = [pscustomobject]@{ Name = $Name; Status = $Status; Summary = $Summary }
        $script:BootstrapperReport.Phases.Add($phase)
        return
    }
    $phase[0].Status = $Status
    if ($PSBoundParameters.ContainsKey('Summary')) { $phase[0].Summary = $Summary }
}

function Get-AMRLErrorSummary {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return 'An unspecified error occurred.' }

    $missingSecrets = New-Object 'System.Collections.Generic.List[string]'
    foreach ($match in [regex]::Matches($Message, "KeyVault parameter '([^']+)' cannot be retrieved", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $secretName = $match.Groups[1].Value
        if ($secretName -notin $missingSecrets) { $missingSecrets.Add($secretName) }
    }
    if ($missingSecrets.Count -gt 0) {
        return "Azure could not resolve Key Vault parameter secrets: $($missingSecrets -join ', ')."
    }

    if ($Message -match '(?i)ForbiddenByRbac' -and $Message -match '(?i)KeyVault|Microsoft\.KeyVault|keyvault') {
        $vaultMatch = [regex]::Match($Message, '(?im)^\s*Resource:\s*[^/\r\n]*/vaults/(?<name>[^/''"\s]+)')
        if (-not $vaultMatch.Success) { $vaultMatch = [regex]::Match($Message, '(?i)--vault-name\s+(?<name>[^\s]+)') }
        $vaultName = if ($vaultMatch.Success) { " '$($vaultMatch.Groups['name'].Value)'" } else { '' }
        return "Key Vault$vaultName denied secret access (ForbiddenByRbac). Verify the caller's Secrets Officer assignment at this vault scope; Azure RBAC may still be propagating."
    }

    if ($Message -match '(?i)QuotaExceeded') {
        $familyMatch = [regex]::Match($Message, '(?i)approved\s+(?<family>[A-Za-z0-9]+)\s+Cores quota')
        $locations = New-Object 'System.Collections.Generic.List[string]'
        foreach ($match in [regex]::Matches($Message, '(?i)Location:\s*(?<location>[^,]+),\s*Current Limit:\s*(?<limit>\d+),\s*Current Usage:\s*(?<usage>\d+),\s*Additional Required:\s*(?<required>\d+)')) {
            $location = $match.Groups['location'].Value.Trim()
            if ($location -notin $locations) { $locations.Add($location) }
        }
        if ($familyMatch.Success -and $locations.Count -gt 0) {
            return "VM quota exceeded: $($familyMatch.Groups['family'].Value) family has insufficient cores in $($locations -join ', ')."
        }
        return 'Azure VM quota was exceeded. Check the requested VM family and region quota.'
    }

    if ($Message -match '(?i)BCP091' -and $Message -match '(?i)names\.csv') {
        return 'Bicep could not read modules/identity/data/names.csv because another process has the file open. Close the process or sync operation and retry.'
    }

    $cleanLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($Message -split "`r?`n")) {
        $candidate = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($candidate) -or
            $candidate -match '^(?i:System\.Management\.Automation\.RemoteException|Azure CLI failed \(exit \d+\):|Inner Errors?:|Code:|Vault:|Caller:|Action:|Resource:|Assignment:|DenyAssignmentId:|DecisionReason:)') {
            continue
        }
        if ($candidate -match '^ERROR:\s*(?<error>.+)$') { $candidate = $Matches.error.Trim() }
        if ($candidate.StartsWith('{')) {
            try {
                $payload = $candidate | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $payload.error.message) { $candidate = [string]$payload.error.message }
                elseif ($null -ne $payload.message) { $candidate = [string]$payload.message }
            }
            catch { }
        }
        if ($candidate -notin $cleanLines) { $cleanLines.Add($candidate) }
    }
    if ($cleanLines.Count -eq 0) { return 'The operation failed. See the Azure operation record for details.' }
    $summary = $cleanLines[0]
    if ($summary.Length -gt 320) { $summary = $summary.Substring(0, 317) + '...' }
    return $summary
}

function Add-AMRLReportIssue {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Error', 'Warning', 'Info')][string]$Severity = 'Error',
        [string]$NextStep
    )

    if ($null -eq $script:BootstrapperReport) { return }
    $summary = Get-AMRLErrorSummary -Message $Message
    $duplicate = @($script:BootstrapperReport.Issues | Where-Object {
        $_.Severity -eq $Severity -and $_.Message -ceq $summary
    } | Select-Object -First 1)
    if ($duplicate.Count -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace($NextStep) -and [string]::IsNullOrWhiteSpace([string]$duplicate[0].NextStep)) {
            $duplicate[0].NextStep = $NextStep
        }
        return
    }
    $script:BootstrapperReport.Issues.Add([pscustomobject]@{
        Time = Get-Date
        Phase = $Phase
        Severity = $Severity
        Message = $summary
        NextStep = $NextStep
    })
}

function Set-AMRLReportSource {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Summary,
        [string]$Details
    )

    if ($null -eq $script:BootstrapperReport) { return }
    $script:BootstrapperReport.Sources[$Name] = [pscustomobject]@{
        Status = $Status
        Summary = $Summary
        Details = $Details
    }
}

function Initialize-AMRLRunPhase {
    param([Parameter(Mandatory = $true)][string]$Name)

    $script:BootstrapperPhase = $Name
    Set-AMRLReportPhase -Name $Name -Status 'Running'
}

function Complete-AMRLRunPhase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Summary = 'Completed.'
    )

    Set-AMRLReportPhase -Name $Name -Status 'Succeeded' -Summary $Summary
}

function Get-AMRLResourceDisplayName {
    param([Parameter(Mandatory = $true)][string]$ResourceId)

    $resourcePath = $ResourceId -replace '(?i)^.*?/providers/[^/]+/', '' -replace '(?i)^Microsoft\.[^/]+/', ''
    if ($resourcePath -eq $ResourceId -and $ResourceId -match '^/') { return ($ResourceId -split '/')[-1] }
    $segments = $resourcePath -split '/'
    $names = @(for ($segmentIndex = 1; $segmentIndex -lt $segments.Count; $segmentIndex += 2) { $segments[$segmentIndex] })
    if ($names.Count -eq 0) { return ($ResourceId -split '/')[-1] }
    return $names -join ' / '
}

function Get-AMRLResourceRegionLabel {
    param([Parameter(Mandatory = $true)][string]$ResourceId)

    if ($ResourceId -match '(?i)/resourceGroups/(?<Group>[^/]+)') { return $Matches.Group -replace '(?i)^.*-rg-', '' }
    return 'Subscription'
}

function Get-AMRLPlannedChangeDetails {
    param([AllowEmptyCollection()][object[]]$Changes)

    $commandChanges = @($Changes | Where-Object { $_.resourceId -match '(?i)/virtualMachines/[^/]+/runCommands/[^/]+$' })
    foreach ($group in @($commandChanges | Group-Object { "$($_.changeType)|$($_.resourceId -replace '(?i)/runCommands/[^/]+$', '')" } | Sort-Object Name)) {
        $change = $group.Group[0]
        $vmId = $change.resourceId -replace '(?i)/runCommands/[^/]+$', ''
        $vmName = Get-AMRLResourceDisplayName -ResourceId $vmId
        $region = Get-AMRLResourceRegionLabel -ResourceId $change.resourceId
        $commands = @($group.Group | ForEach-Object { ($_.resourceId -split '/')[-1] } | Sort-Object -Unique) -join ', '
        $marker = if ($change.changeType -eq 'Delete') { 'DELETE' } else { $change.changeType }
        "${marker}: $vmName [$region] (VM Run Commands): $commands"
    }
    $otherChanges = @($Changes | Where-Object { $_.resourceId -notmatch '(?i)/virtualMachines/[^/]+/runCommands/[^/]+$' })
    foreach ($group in @($otherChanges | Group-Object {
        "$($_.changeType)|$(Get-AMRLResourceTypeLabel -ResourceId $_.resourceId)|$(Get-AMRLResourceRegionLabel -ResourceId $_.resourceId)"
    } | Sort-Object Name)) {
        $change = $group.Group[0]
        $resourceType = Get-AMRLResourceTypeLabel -ResourceId $change.resourceId
        $region = Get-AMRLResourceRegionLabel -ResourceId $change.resourceId
        $names = @($group.Group | ForEach-Object { Get-AMRLResourceDisplayName -ResourceId $_.resourceId }) -join ', '
        $marker = if ($change.changeType -eq 'Delete') { 'DELETE' } else { $change.changeType }
        "${marker}: $($group.Count) $resourceType [$region]: $names"
    }
}

function Get-AMRLResourceTypeLabel {
    param([Parameter(Mandatory = $true)][string]$ResourceId)

    $resourcePath = $ResourceId -replace '(?i)^.*?/providers/', ''
    $segments = $resourcePath -split '/'
    if ($resourcePath -eq $ResourceId -and $ResourceId -match '(?i)/resourceGroups/[^/]+$') { return 'Resource groups' }
    $resourceType = @($segments[0]) + @(for ($segmentIndex = 1; $segmentIndex -lt $segments.Count; $segmentIndex += 2) { $segments[$segmentIndex] })
    switch ($resourceType -join '/') {
        'Microsoft.Compute/virtualMachines/runCommands' { return 'VM Run Commands' }
        'Microsoft.Compute/virtualMachines' { return 'Virtual machines' }
        'Microsoft.Network/virtualNetworks' { return 'Virtual networks' }
        'Microsoft.Network/virtualNetworks/subnets' { return 'Subnets' }
        'Microsoft.Network/virtualNetworks/virtualNetworkPeerings' { return 'VNet peerings' }
        'Microsoft.Network/networkInterfaces' { return 'Network interfaces' }
        'Microsoft.Network/networkSecurityGroups' { return 'Network security groups' }
        'Microsoft.Network/publicIPAddresses' { return 'Public IP addresses' }
        'Microsoft.Network/routeTables' { return 'Route tables' }
        'Microsoft.Resources/deployments' { return 'Deployment records' }
        default { if ($resourceType.Count -gt 1) { return $resourceType[-1] }; return 'Resources' }
    }
}

function Invoke-AMRLObservedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    try {
        $output = Invoke-AzCli -Arguments $Arguments
        $outputText = [string]$output
        $summary = if ([string]::IsNullOrWhiteSpace($outputText)) { 'Completed successfully; Azure CLI returned no details.' } else { ($outputText -split "`r?`n" | Select-Object -First 4) -join ' ' }
        $details = ''
        if ($Name -eq 'Bicep build') { $summary = 'Bicep compilation succeeded.' }
        elseif ($Name -eq 'Bicep lint') { $summary = if ([string]::IsNullOrWhiteSpace($outputText)) { 'Bicep lint succeeded without diagnostics.' } else { 'Bicep lint completed; review diagnostics below.' } }
        elseif ($Name -eq 'Azure deployment validate') { $summary = 'Azure accepted the template and parameter validation request.' }
        if (-not [string]::IsNullOrWhiteSpace($outputText) -and $Name -ne 'Azure deployment what-if') {
            $details = ($outputText -split "`r?`n" | Select-Object -First 20) -join [Environment]::NewLine
        }
        if ($Name -eq 'Azure deployment what-if' -and -not [string]::IsNullOrWhiteSpace($outputText)) {
            try {
                $whatIf = $outputText | ConvertFrom-Json
                $changesProperty = $whatIf.PSObject.Properties['changes']
                if ($null -eq $changesProperty -and $null -ne $whatIf.properties) { $changesProperty = $whatIf.properties.PSObject.Properties['changes'] }
                $changes = if ($null -eq $changesProperty) { @() } else { @($changesProperty.Value | Where-Object { $_.changeType -in @('Create', 'Modify', 'Delete', 'Deploy') } | Sort-Object resourceId, changeType -Unique) }
                if ($changes.Count -gt 0) {
                    $counts = @($changes | Group-Object changeType | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ', '
                    $summary = "$($changes.Count) resource changes ($counts)."
                    $details = @(Get-AMRLPlannedChangeDetails -Changes $changes) -join [Environment]::NewLine
                    if (@($changes | Where-Object { $_.resourceId -notmatch '(?i)/virtualMachines/[^/]+/runCommands/[^/]+$' }).Count -eq 0) {
                        $details = 'All predicted changes are VM Run Commands; no VM or network resource creations/deletions predicted.' + [Environment]::NewLine + $details
                    }
                }
                else { $summary = 'Completed successfully; no resource changes were returned.' }
            }
            catch {
                $cleanLines = New-Object 'System.Collections.Generic.List[string]'
                foreach ($line in ($outputText -split "`r?`n")) {
                    if ($line -match '^\s*([+~!\-])\s+((?:/subscriptions/|Microsoft\.)\S+)') {
                        $operation = switch ($Matches[1]) { '+' { 'Create' } '~' { 'Modify' } '!' { 'Deploy' } '-' { 'Delete' } }
                        $resourcePath = Get-AMRLResourceDisplayName -ResourceId $Matches[2]
                        $entry = "${operation}: $resourcePath"
                        if ($entry -notin $cleanLines) { $cleanLines.Add($entry) }
                    }
                }
                $summary = if ($cleanLines.Count -gt 0) { "$($cleanLines.Count) predicted resource changes." } else { 'Azure returned text output; no changed resource headers could be extracted.' }
                $details = $cleanLines -join [Environment]::NewLine
            }
        }
        if ($summary.Length -gt 700) { $summary = $summary.Substring(0, 700) + '...' }
        if ($Name -ne 'Azure deployment what-if' -and $details.Length -gt 3000) { $details = $details.Substring(0, 3000) + '...' }
        Set-AMRLReportSource -Name $Name -Status 'Succeeded' -Summary $summary -Details $details
        return [pscustomobject]@{ Succeeded = $true; Output = [string]$output }
    }
    catch {
        $message = $_.Exception.Message
        Set-AMRLReportSource -Name $Name -Status 'Failed' -Summary 'Failed; see Warnings and errors below.'
        Add-AMRLReportIssue -Phase $script:BootstrapperPhase -Message $message
        Write-Verbose "$Name failed; details are consolidated in the final report."
        return [pscustomobject]@{ Succeeded = $false; Output = ''; Error = $message }
    }
}

function Get-AMRLDeploymentFailureSummary {
    param([Parameter(Mandatory = $true)][string]$Message)

    $correlationMatch = [regex]::Match($Message, '(?i)Correlation ID:\s*([0-9a-f-]{36})')
    $correlationSuffix = if ($correlationMatch.Success) { " (Correlation ID: $($correlationMatch.Groups[1].Value))" } else { '' }
    $jsonStart = $Message.IndexOf('{')
    if ($jsonStart -lt 0) {
        $plainMessage = (($Message -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) -replace '^\s*ERROR:\s*', '').Trim()
        if ([string]::IsNullOrWhiteSpace($plainMessage)) { $plainMessage = 'Azure deployment failed; inspect the deployment record for details.' }
        return ($plainMessage + $correlationSuffix)
    }

    $payload = $null
    try { $payload = $Message.Substring($jsonStart) | ConvertFrom-Json } catch { }
    $errorProperty = if ($null -eq $payload) { $null } else { $payload.PSObject.Properties['error'] }
    if ($null -eq $errorProperty -or $null -eq $errorProperty.Value) {
        $plainMessage = (($Message -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) -replace '^\s*ERROR:\s*', '').Trim()
        if ([string]::IsNullOrWhiteSpace($plainMessage) -or $plainMessage.StartsWith('{')) { $plainMessage = 'Azure deployment failed; inspect the deployment record for details.' }
        return ($plainMessage + $correlationSuffix)
    }

    $rootError = $errorProperty.Value
    $nodes = New-Object 'System.Collections.Generic.List[object]'
    $messages = New-Object 'System.Collections.Generic.List[string]'
    [void]$nodes.Add($rootError)
    for ($index = 0; $index -lt $nodes.Count; $index++) {
        $node = $nodes[$index]
        $messageProperty = $node.PSObject.Properties['message']
        if ($null -ne $messageProperty -and -not [string]::IsNullOrWhiteSpace([string]$messageProperty.Value)) {
            $messages.Add([string]$messageProperty.Value)
        }
        $detailsProperty = $node.PSObject.Properties['details']
        if ($null -ne $detailsProperty -and $null -ne $detailsProperty.Value) {
            foreach ($detail in @($detailsProperty.Value)) {
                if ($null -ne $detail) { [void]$nodes.Add($detail) }
            }
        }
    }

    $gateMessage = @($messages | Where-Object { $_ -match 'Deployment blocked by validation enforcement' } | Select-Object -First 1)
    if ($gateMessage.Count -gt 0) {
        $countMatch = [regex]::Match($gateMessage[0], '(\d+) blocking validation finding')
        $countText = if ($countMatch.Success) { "$($countMatch.Groups[1].Value) blocking validation findings were detected. " } else { '' }
        return ("Deployment blocked by the AMRL validation engine. ${countText}Review the Bicep validation findings above.$correlationSuffix")
    }

    $specificMessage = if ($messages.Count -gt 1) { $messages[$messages.Count - 1] } elseif ($messages.Count -eq 1) { $messages[0] } else { 'Azure deployment failed; inspect the deployment record for details.' }
    $rootCodeProperty = $rootError.PSObject.Properties['code']
    $errorCode = if ($null -eq $rootCodeProperty) { '' } else { [string]$rootCodeProperty.Value }
    $detailCode = ''
    for ($index = 1; $index -lt $nodes.Count; $index++) {
        $codeProperty = $nodes[$index].PSObject.Properties['code']
        if ($null -ne $codeProperty -and -not [string]::IsNullOrWhiteSpace([string]$codeProperty.Value)) { $detailCode = [string]$codeProperty.Value }
    }
    if (-not [string]::IsNullOrWhiteSpace($detailCode)) { $errorCode = $detailCode }
    if ([string]::IsNullOrWhiteSpace($errorCode)) { return ("Deployment failed: $specificMessage$correlationSuffix") }
    return ("Deployment failed ($errorCode): $specificMessage$correlationSuffix")
}

function Get-AMRLDeploymentOperationErrorSummary {
    param([Parameter(Mandatory = $false)][AllowNull()][object]$ErrorData)

    if ($null -eq $ErrorData) { return '' }
    if ($ErrorData -is [string]) {
        $text = $ErrorData.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return '' }
        try { $ErrorData = $text | ConvertFrom-Json -ErrorAction Stop }
        catch { return $text }
    }

    $nodes = New-Object 'System.Collections.Generic.List[object]'
    $messages = New-Object 'System.Collections.Generic.List[string]'
    $codes = New-Object 'System.Collections.Generic.List[string]'
    [void]$nodes.Add($ErrorData)
    for ($index = 0; $index -lt $nodes.Count; $index++) {
        $node = $nodes[$index]
        if ($null -eq $node) { continue }
        $codeProperty = $node.PSObject.Properties['code']
        if ($null -ne $codeProperty -and -not [string]::IsNullOrWhiteSpace([string]$codeProperty.Value)) {
            $codes.Add([string]$codeProperty.Value)
        }
        $messageProperty = $node.PSObject.Properties['message']
        if ($null -ne $messageProperty -and -not [string]::IsNullOrWhiteSpace([string]$messageProperty.Value)) {
            $messages.Add([string]$messageProperty.Value)
        }
        foreach ($childName in @('error', 'innererror', 'innerError')) {
            $childProperty = $node.PSObject.Properties[$childName]
            if ($null -ne $childProperty -and $null -ne $childProperty.Value) { [void]$nodes.Add($childProperty.Value) }
        }
        $detailsProperty = $node.PSObject.Properties['details']
        if ($null -ne $detailsProperty -and $null -ne $detailsProperty.Value) {
            foreach ($detail in @($detailsProperty.Value)) { if ($null -ne $detail) { [void]$nodes.Add($detail) } }
        }
    }

    $genericCodes = @('DeploymentFailed', 'ResourceDeploymentFailure', 'InvalidTemplateDeployment', 'OperationFailed')
    $specificCode = @($codes | Where-Object { $_ -notin $genericCodes } | Select-Object -Last 1)
    $specificMessages = @($messages | Where-Object {
        $_ -notmatch '(?i)At least one resource deployment operation failed|resource write operation failed to complete|template deployment .* is not valid according to the validation procedure|reported preflight validation errors|please list deployment operations for details'
    })
    $specificMessage = if ($specificMessages.Count -gt 0) { $specificMessages[-1].Trim() } else { 'Azure reported a resource deployment failure.' }

    if ($specificCode.Count -gt 0 -and $specificCode[0] -eq 'SkuNotAvailable' -and
        $specificMessage -match "(?<Sku>Standard_[A-Za-z0-9_]+).*?not available in location ['`]*(?<Location>[A-Za-z0-9]+)") {
        $specificMessage = "$($Matches.Sku) capacity is unavailable in $($Matches.Location). Choose another VM size or region."
    }

    $trackingReference = ''
    foreach ($message in $messages) {
        $trackingMatch = [regex]::Match($message, '(?i)(?:Tracking\s*ID|Tracking\s*id|Correlation\s*ID|Correlation\s*Id)(?:\s+is)?\s*:?\s*["'']?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
        if ($trackingMatch.Success) { $trackingReference = " (Tracking ID: $($trackingMatch.Groups[1].Value))" }
    }
    $codePrefix = if ($specificCode.Count -gt 0) { "$($specificCode[0]): " } else { '' }
    $summary = "$codePrefix$specificMessage$trackingReference"
    if ($summary.Length -gt 600) { $summary = $summary.Substring(0, 600) + '...' }
    return $summary
}

function Get-AMRLOutputValue {
    param(
        [Parameter(Mandatory = $true)][object]$Outputs,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Outputs.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return }
    $valueProperty = $property.Value.PSObject.Properties['value']
    if ($null -ne $valueProperty) { return $valueProperty.Value }
}

function Get-AMRLValidationReport {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Deployment)

    if ($null -eq $Deployment) { return $null }
    $properties = $Deployment.PSObject.Properties['properties']
    if ($null -eq $properties -or $null -eq $properties.Value) { return $null }
    $outputsProperty = $properties.Value.PSObject.Properties['outputs']
    if ($null -eq $outputsProperty) { return $null }
    $outputs = $outputsProperty.Value
    if ($null -eq $outputs) { return $null }

    $summary = Get-AMRLOutputValue -Outputs $outputs -Name 'validationSummary'
    if ([string]::IsNullOrWhiteSpace([string]$summary)) {
        $summary = Get-AMRLOutputValue -Outputs $outputs -Name 'validationMessage'
    }
    $blockingSummary = Get-AMRLOutputValue -Outputs $outputs -Name 'blockingValidationSummary'
    # Missing collections are unknown, not evidence that no findings were active.
    $findingsAvailable = $true
    foreach ($outputName in @('blockingValidationDetails', 'advisoryValidationDetails')) {
        $entry = $outputs.PSObject.Properties[$outputName]
        if ($null -eq $entry -or $null -eq $entry.Value -or
            $null -eq $entry.Value.PSObject.Properties['value'] -or $null -eq $entry.Value.value) {
            $findingsAvailable = $false
        }
    }
    $nameProperty = $Deployment.PSObject.Properties['name']

    return [pscustomobject]@{
        DeploymentName = if ($null -eq $nameProperty) { '(unknown)' } else { [string]$nameProperty.Value }
        Summary = [string]$summary
        BlockingSummary = [string]$blockingSummary
        FindingsAvailable = $findingsAvailable
        EnforcementEnabled = Get-AMRLOutputValue -Outputs $outputs -Name 'enforcementEnabled'
        HasBlockingFailures = Get-AMRLOutputValue -Outputs $outputs -Name 'hasBlockingValidationFailures'
        ShouldBlockDeployment = Get-AMRLOutputValue -Outputs $outputs -Name 'shouldBlockDeployment'
        DeploymentBlockMessage = Get-AMRLOutputValue -Outputs $outputs -Name 'deploymentBlockMessage'
        Flags = @(Get-AMRLOutputValue -Outputs $outputs -Name 'validationFlags' | Where-Object { $null -ne $_ })
        Blocking = @(Get-AMRLOutputValue -Outputs $outputs -Name 'blockingValidationDetails' | Where-Object { $null -ne $_ })
        Advisory = @(Get-AMRLOutputValue -Outputs $outputs -Name 'advisoryValidationDetails' | Where-Object { $null -ne $_ })
        Capacity = Get-AMRLOutputValue -Outputs $outputs -Name 'capacityCheck'
        Placements = @(Get-AMRLOutputValue -Outputs $outputs -Name 'vmPlacement' | Where-Object { $null -ne $_ })
    }
}

function Get-AMRLValidationDeploymentName {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$RootDeploymentName
    )

    $deploymentNamePrefix = $RootDeploymentName.Substring(0, [Math]::Min(20, $RootDeploymentName.Length))
    return "${Prefix}-validation-engine-${deploymentNamePrefix}"
}

function Get-AMRLValidationFindingValue {
    param(
        [Parameter(Mandatory = $true)][object]$Finding,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Finding.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    if ($Finding -is [System.Collections.IDictionary] -and $Finding.Contains($Name)) { return $Finding[$Name] }
    return ''
}

function Write-AMRLValidationReport {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Deployment,
        [string]$Title = 'AMRL validation report',
        [switch]$Quiet
    )

    $report = Get-AMRLValidationReport -Deployment $Deployment
    if ($null -eq $report) {
        Set-AMRLReportPhase -Name 'AMRL validation engine outputs' -Status 'Unavailable' -Summary 'Deployment record did not contain validation outputs.'
        Set-AMRLReportSource -Name 'AMRL validation engine' -Status 'Unavailable' -Summary 'No validation outputs were available.'
        Add-AMRLReportIssue -Phase 'AMRL validation engine outputs' -Severity Warning -Message 'The deployment record did not contain AMRL validation engine outputs; this is not a validation pass.'
        if (-not $Quiet) { Write-Warning "$Title is unavailable in this deployment record." }
        return
    }
    if ($null -ne $script:BootstrapperReport) {
        $script:BootstrapperReport.Validation = $report
        $validationStatus = if ($report.FindingsAvailable) { 'Available' } else { 'Incomplete' }
        $findingSummary = "Blocking: $($report.Blocking.Count); advisory: $($report.Advisory.Count); mode: $($report.EnforcementEnabled)"
        Set-AMRLReportPhase -Name 'AMRL validation engine outputs' -Status $validationStatus -Summary $findingSummary
        Set-AMRLReportSource -Name 'AMRL validation engine' -Status $validationStatus -Summary $report.Summary -Details $findingSummary
        if (-not $report.FindingsAvailable) {
            Add-AMRLReportIssue -Phase 'AMRL validation engine outputs' -Severity Warning -Message 'AMRL validation engine outputs were incomplete; missing findings are not treated as a clean result.'
        }
        $blockingSeverity = if ($report.EnforcementEnabled -and $report.ShouldBlockDeployment) { 'Error' } else { 'Warning' }
        foreach ($finding in $report.Blocking) {
            $flag = Get-AMRLValidationFindingValue -Finding $finding -Name 'flag'
            $message = Get-AMRLValidationFindingValue -Finding $finding -Name 'message'
            $nextStep = Get-AMRLValidationFindingValue -Finding $finding -Name 'remediation'
            Add-AMRLReportIssue -Phase 'AMRL validation engine' -Severity $blockingSeverity -Message "BLOCKING [$flag] $message" -NextStep $nextStep
        }
        foreach ($finding in $report.Advisory) {
            $flag = Get-AMRLValidationFindingValue -Finding $finding -Name 'flag'
            $message = Get-AMRLValidationFindingValue -Finding $finding -Name 'message'
            $nextStep = Get-AMRLValidationFindingValue -Finding $finding -Name 'remediation'
            Add-AMRLReportIssue -Phase 'AMRL validation engine' -Severity Warning -Message "ADVISORY [$flag] $message" -NextStep $nextStep
        }
    }

    if ($Quiet) { return }

    Write-Host "`n$Title"
    if (-not $report.FindingsAvailable) { Write-Warning 'AMRL validation findings are unavailable or incomplete; empty collections do not mean validation passed.' }
    $mode = if ($null -eq $report.EnforcementEnabled) { 'Unknown (output unavailable)' }
        elseif ($report.EnforcementEnabled) { 'enforce' } else { 'reportOnly' }
    $gate = if ($null -eq $report.ShouldBlockDeployment) { 'unavailable' } elseif ($report.ShouldBlockDeployment) { 'blocked' } else { 'not blocked' }
    Write-Host "Mode: $mode; blocking: $($report.Blocking.Count); advisory: $($report.Advisory.Count)"
    Write-Host "Deployment gate: $gate"
}

# An enforced gate can fail the root while leaving completed engine outputs available.
function Show-AMRLValidationAfterFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$RootDeploymentName,
        [switch]$Quiet
    )

    try {
        $root = Get-AzJson -Arguments @('deployment', 'sub', 'show', '--name', $RootDeploymentName)
        $rootReport = Get-AMRLValidationReport -Deployment $root
        if ($null -ne $rootReport -and $rootReport.FindingsAvailable -and -not [string]::IsNullOrWhiteSpace($rootReport.Summary)) {
            Write-AMRLValidationReport -Deployment $root -Title 'Validation output from failed root deployment' -Quiet:$Quiet
            return
        }
    }
    catch {
        if (-not $Quiet) { Write-Warning 'Root deployment outputs were unavailable; checking the nested AMRL validation engine.' }
    }

    $validationName = Get-AMRLValidationDeploymentName -Prefix $Prefix -RootDeploymentName $RootDeploymentName
    try {
        $validationDeployment = Get-AzJson -Arguments @('deployment', 'sub', 'show', '--name', $validationName)
        Write-AMRLValidationReport -Deployment $validationDeployment -Title 'Nested AMRL validation engine output' -Quiet:$Quiet
    }
    catch {
        $message = "Could not retrieve nested AMRL validation engine output: $($_.Exception.Message)"
        Add-AMRLReportIssue -Phase 'AMRL validation engine outputs' -Severity Warning -Message $message
        if (-not $Quiet) { Write-Warning $message }
    }
    $validationProperty = if ($null -eq $script:BootstrapperReport) { $null } else { $script:BootstrapperReport.PSObject.Properties['Validation'] }
    if ($null -eq $validationProperty -or $null -eq $validationProperty.Value) {
        Set-AMRLReportPhase -Name 'AMRL validation engine outputs' -Status 'Unavailable' -Summary 'Root and nested deployment validation outputs could not be retrieved.'
        Set-AMRLReportSource -Name 'AMRL validation engine' -Status 'Unavailable' -Summary 'Root and nested deployment validation outputs could not be retrieved.'
        Add-AMRLReportIssue -Phase 'AMRL validation engine outputs' -Severity Warning -Message 'No AMRL validation engine output was available from the failed deployment.'
    }
}

# Read saved instance views; do not rerun guest commands or print their script output.
function Get-AMRLGuestCommandResults {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Placements,
        [switch]$Quiet,
        [switch]$ShowProgress
    )

    foreach ($placement in $Placements) {
        if ($ShowProgress) { Write-Host "  Checking VM setup status: $($placement.name)" }
        $resourceGroup = "$Prefix-rg-$($placement.regionKey)"
        try {
            $commands = @(Get-AzJson -Arguments @('vm', 'run-command', 'list', '--resource-group', $resourceGroup, '--vm-name', $placement.name, '--query', '[].name'))
            if ($commands.Count -eq 0) {
                [pscustomobject]@{ VM = $placement.name; Command = '(none)'; ExecutionState = 'Unknown'; ExitCode = $null; Result = 'No commands found' }
            }
            foreach ($command in $commands) {
                $commandName = ([string]$command -split '/')[-1]
                try {
                    $view = Get-AzJson -Arguments @('vm', 'run-command', 'show', '--resource-group', $resourceGroup, '--vm-name', $placement.name, '--name', $commandName, '--instance-view', '--query', '{executionState:instanceView.executionState,exitCode:instanceView.exitCode}')
                    $stateProperty = if ($null -eq $view) { $null } else { $view.PSObject.Properties['executionState'] }
                    $codeProperty = if ($null -eq $view) { $null } else { $view.PSObject.Properties['exitCode'] }
                    $state = if ($null -eq $stateProperty -or [string]::IsNullOrWhiteSpace([string]$stateProperty.Value)) { 'Unknown' } else { [string]$stateProperty.Value }
                    $exitCode = if ($null -eq $codeProperty) { $null } else { $codeProperty.Value }
                    $result = if ($state -eq 'Succeeded' -and $null -ne $exitCode -and $exitCode -eq 0) { 'Passed' }
                        elseif ($state -in @('Failed', 'Canceled', 'TimedOut') -or ($null -ne $exitCode -and $exitCode -ne 0)) { 'Failed' }
                        else { 'Not verified' }
                    [pscustomobject]@{ VM = $placement.name; Command = $commandName; ExecutionState = $state; ExitCode = $exitCode; Result = $result }
                }
                catch {
                    if (-not $Quiet) { Write-Warning "Could not read Run Command '$commandName' on '$($placement.name)'. Inspect its instance view manually." }
                    [pscustomobject]@{ VM = $placement.name; Command = $commandName; ExecutionState = 'Unknown'; ExitCode = $null; Result = 'Read failed' }
                }
            }
        }
        catch {
            if (-not $Quiet) { Write-Warning "Could not list Run Commands on '$($placement.name)'. Check read permissions and VM existence." }
            [pscustomobject]@{ VM = $placement.name; Command = '(unknown)'; ExecutionState = 'Unknown'; ExitCode = $null; Result = 'Read failed' }
        }
    }
}

function Show-AMRLGuestCommandResults {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Deployment,
        [switch]$Quiet,
        [switch]$ShowProgress
    )

    $report = Get-AMRLValidationReport -Deployment $Deployment
    if ($null -eq $report -or $report.Placements.Count -eq 0) {
        $deploymentProperties = if ($null -eq $Deployment) { $null } else { $Deployment.PSObject.Properties['properties'] }
        $deploymentState = if ($null -eq $deploymentProperties -or $null -eq $deploymentProperties.Value) { '' } else { [string]$deploymentProperties.Value.provisioningState }
        if ($deploymentState -in @('Failed', 'Canceled', 'Cancelled')) {
            Set-AMRLReportPhase -Name 'VM setup checks' -Status 'Skipped' -Summary 'Deployment failed before VM placement outputs were available.'
            Set-AMRLReportSource -Name 'VM setup checks' -Status 'Skipped' -Summary 'Guest checks were not run because deployment did not return VM placements.'
            if (-not $Quiet) { Write-Host 'VM setup checks skipped; deployment did not return VM placements.' }
            return
        }
        Set-AMRLReportPhase -Name 'VM setup checks' -Status 'Unavailable' -Summary 'VM placement outputs were unavailable.'
        Set-AMRLReportSource -Name 'VM setup checks' -Status 'Unavailable' -Summary 'No VM placements were available.'
        Add-AMRLReportIssue -Phase 'VM setup checks' -Severity Warning -Message 'VM setup checks could not be collected because VM placements were unavailable.'
        if (-not $Quiet) { Write-Warning 'VM placement outputs are unavailable; VM setup checks could not be collected.' }
        return
    }
    $results = @(Get-AMRLGuestCommandResults -Prefix $Prefix -Placements $report.Placements -Quiet:$Quiet -ShowProgress:$ShowProgress)
    if ($null -ne $script:BootstrapperReport) {
        $script:BootstrapperReport.GuestResults = $results
        $guestStatus = if (@($results | Where-Object { $_.Result -ne 'Passed' }).Count -eq 0) { 'Succeeded' } else { 'Issues found' }
        Set-AMRLReportPhase -Name 'VM setup checks' -Status $guestStatus -Summary "$(@($results | Where-Object { $_.Result -eq 'Passed' }).Count) passed; $(@($results | Where-Object { $_.Result -ne 'Passed' }).Count) failed or unverified."
        Set-AMRLReportSource -Name 'VM setup checks' -Status $guestStatus -Summary "$($results.Count) setup checks inspected."
        foreach ($result in @($results | Where-Object { $_.Result -ne 'Passed' })) {
            Add-AMRLReportIssue -Phase 'VM setup checks' -Severity Warning -Message "$($result.VM)/$($result.Command): $($result.Result) (execution state $($result.ExecutionState), exit code $($result.ExitCode))."
        }
    }
    if (-not $Quiet) {
        Write-Host 'VM setup checks (read-only status checks):'
        $results | Format-Table -Property VM, Command, ExecutionState, ExitCode, Result -AutoSize | Out-Host
    }
    $unverified = @($results | Where-Object { $_.Result -ne 'Passed' })
    if ($unverified.Count -gt 0 -and -not $Quiet) { Write-Warning "$($unverified.Count) Run Command results failed or remain unverified. Review guest checks before using the lab." }
}

# 4. Input, credential generation, and Bicep reference resolution helpers
# Keep wizard validation and parameter-file edits separate from Azure writes. Foundation writes
# are routed through Invoke-AMRLChange so Plan mode can remain read-only and report completed changes.
function Invoke-AMRLChange {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Operation
    )

    # This boundary executes writes; callers must route Plan before reaching it.
    $result = & $Operation
    if ($null -ne $script:BootstrapperReport -and $script:BootstrapperPhase -eq 'Azure readiness and foundation') {
        $script:BootstrapperReport.FoundationChanges.Add([pscustomobject]@{ Target = $Target; Action = $Action })
    }
    return $result
}

function Read-RequiredValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [string]$DefaultValue,

        [string]$Hint,

        [string]$IssuePhase = 'Parameter configuration',

        [scriptblock]$Validator = { param($Value) -not [string]::IsNullOrWhiteSpace($Value) }
    )

    while ($true) {
        $hintSuffix = if ([string]::IsNullOrWhiteSpace($Hint)) { '' } else { " (Allowed: $Hint)" }
        $suffix = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { '' } else { " [$DefaultValue]" }
        $value = Read-Host "$Prompt$hintSuffix$suffix"
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $DefaultValue
        }
        if (& $Validator $value) {
            return $value
        }
        Add-AMRLReportIssue -Phase $IssuePhase -Severity Warning -Message "$Prompt rejected an invalid answer; the prompt was repeated."
        Write-Warning 'That value is not valid. Try again.'
    }
}

function Confirm-AMRLDeployment {
    param([Parameter(Mandatory = $true)][string]$DeploymentName)

    while ($true) {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            if ($attempt -eq 1) {
                Write-Host 'Type ' -NoNewline
                Write-Host 'DEPLOY' -ForegroundColor Yellow -NoNewline
                Write-Host " to create subscription deployment '$DeploymentName'."
            }
            else {
                Write-Host 'Enter the exact word DEPLOY to proceed.'
            }

            if ((Read-Host 'Confirmation') -ceq 'DEPLOY') { return $true }
            if ($attempt -eq 1) { Write-Warning 'The confirmation must be exactly DEPLOY. Try once more.' }
        }

        $cancel = Read-RequiredValue -Prompt 'Cancel deployment?' -Hint 'y/N' -DefaultValue 'no' -IssuePhase 'Deployment' -Validator {
            param($Value) $Value -in @('yes', 'no', 'y', 'n')
        }
        if ($cancel -in @('yes', 'y')) { return $false }

        Write-Host 'Restarting confirmation. The deployment name and reviewed what-if preview are unchanged.'
    }
}

function ConvertTo-AMRLParameterJson {
    param([Parameter(Mandatory = $true)][object]$InputObject)

    $compactJson = ConvertTo-Json -InputObject $InputObject -Depth 100 -Compress
    $builder = New-Object System.Text.StringBuilder
    $indentLevel = 0
    $insideString = $false
    $escaped = $false

    for ($index = 0; $index -lt $compactJson.Length; $index++) {
        $character = $compactJson[$index]
        if ($insideString) {
            [void]$builder.Append($character)
            if ($escaped) { $escaped = $false }
            elseif ($character -eq '\') { $escaped = $true }
            elseif ($character -eq '"') { $insideString = $false }
            continue
        }

        if ($character -eq '"') {
            $insideString = $true
            [void]$builder.Append($character)
        }
        elseif ($character -eq '{' -or $character -eq '[') {
            [void]$builder.Append($character)
            $indentLevel++
            if ($index + 1 -lt $compactJson.Length -and $compactJson[$index + 1] -ne '}' -and $compactJson[$index + 1] -ne ']') {
                [void]$builder.AppendLine()
                [void]$builder.Append(' ' * ($indentLevel * 2))
            }
        }
        elseif ($character -eq '}' -or $character -eq ']') {
            $indentLevel--
            if ($compactJson[$index - 1] -ne '{' -and $compactJson[$index - 1] -ne '[') {
                [void]$builder.AppendLine()
                [void]$builder.Append(' ' * ($indentLevel * 2))
            }
            [void]$builder.Append($character)
        }
        elseif ($character -eq ',') {
            [void]$builder.Append(',')
            [void]$builder.AppendLine()
            [void]$builder.Append(' ' * ($indentLevel * 2))
        }
        elseif ($character -eq ':') {
            [void]$builder.Append(': ')
        }
        else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Read-NonNegativeInteger {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [string]$DefaultValue,

        [int]$Minimum = 0,

        [string]$Hint
    )

    if ([string]::IsNullOrWhiteSpace($Hint)) {
        $Hint = if ($Minimum -ge 1) { 'whole number, 1 or greater' } else { 'whole number, 0 or greater' }
    }
    $value = Read-RequiredValue -Prompt $Prompt -Hint $Hint -DefaultValue $DefaultValue -Validator {
        param($Candidate)
        $parsed = 0
        [int]::TryParse([string]$Candidate, [ref]$parsed) -and $parsed -ge $Minimum
    }
    return [int]$value
}

function Get-SecureRandomIndex {
    param([Parameter(Mandatory = $true)][int]$Count)

    $bytes = New-Object byte[] 1
    $limit = 256 - (256 % $Count)
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        do {
            $generator.GetBytes($bytes)
        } while ([int]$bytes[0] -ge $limit)
        return ([int]$bytes[0] % $Count)
    }
    finally {
        $generator.Dispose()
    }
}

# Generate passwords locally with a cryptographic random source; secret values are sent to Key Vault
# but are never added to the parameter file or bootstrapper report.
function New-AMRLPassword {
    param([int]$Length = 28)

    if ($Length -lt 16) {
        throw 'Generated administrator passwords must be at least 16 characters.'
    }

    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ'
        'abcdefghijkmnopqrstuvwxyz'
        '23456789'
        '!#$%&()*+,-./:;<=>?@[]^_{|}~'
    )
    $allCharacters = $sets -join ''
    $characters = New-Object 'System.Collections.Generic.List[char]'
    foreach ($set in $sets) {
        $characters.Add($set[(Get-SecureRandomIndex -Count $set.Length)])
    }
    while ($characters.Count -lt $Length) {
        $characters.Add($allCharacters[(Get-SecureRandomIndex -Count $allCharacters.Length)])
    }
    for ($index = $characters.Count - 1; $index -gt 0; $index--) {
        $swapIndex = Get-SecureRandomIndex -Count ($index + 1)
        $temporaryCharacter = $characters[$index]
        $characters[$index] = $characters[$swapIndex]
        $characters[$swapIndex] = $temporaryCharacter
    }
    return (-join $characters.ToArray())
}

function Set-AMRLParameterValues {
    param(
        [Parameter(Mandatory = $true)][object]$Parameters,
        [Parameter(Mandatory = $true)][string]$FoundationResourceGroup,
        [Parameter(Mandatory = $true)][string]$KeyVaultName,
        [string]$PublicIp
    )

    Assert-AMRLParameterDocumentCurrent -Parameters $Parameters
    $foundationResourceGroupParameter = $Parameters.parameters.PSObject.Properties['foundationResourceGroup']
    $keyVaultNameParameter = $Parameters.parameters.PSObject.Properties['keyVaultName']
    if ($null -eq $foundationResourceGroupParameter -or $null -eq $keyVaultNameParameter) {
        throw 'The current parameter contract requires top-level foundationResourceGroup and keyVaultName values.'
    }
    if ([string]::IsNullOrWhiteSpace($FoundationResourceGroup) -or [string]::IsNullOrWhiteSpace($KeyVaultName)) {
        throw 'Resolved foundationResourceGroup and keyVaultName values must not be empty.'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$foundationResourceGroupParameter.Value.value) -and
        [string]$foundationResourceGroupParameter.Value.value -notmatch '[<>]' -and
        [string]$foundationResourceGroupParameter.Value.value -ine $FoundationResourceGroup) {
        throw 'The parameter file foundationResourceGroup differs from the resolved foundation resource group.'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$keyVaultNameParameter.Value.value) -and
        [string]$keyVaultNameParameter.Value.value -notmatch '[<>]' -and
        [string]$keyVaultNameParameter.Value.value -ine $KeyVaultName) {
        throw 'The parameter file keyVaultName differs from the resolved Key Vault name.'
    }

    $foundationResourceGroupParameter.Value.value = $FoundationResourceGroup
    $keyVaultNameParameter.Value.value = $KeyVaultName

    if (-not [string]::IsNullOrWhiteSpace($PublicIp)) {
        $sources = @($Parameters.parameters.jumpboxAllowedSources.value)
        if ($sources.Count -eq 0 -or ($sources | Where-Object { [string]$_ -match '[<>]' })) {
            $updatedSources = New-Object 'System.Collections.Generic.List[string]'
            foreach ($source in $sources) {
                $candidate = if ([string]$source -match '[<>]') { "$PublicIp/32" } else { [string]$source }
                if ($candidate -notin $updatedSources) { $updatedSources.Add($candidate) }
            }
            $Parameters.parameters.jumpboxAllowedSources.value = @($updatedSources.ToArray())
        }
    }

    return $Parameters
}

function Get-AMRLParameterFilePublicIp {
    param([Parameter(Mandatory = $true)][object]$Parameters)

    $singleHostSources = @($Parameters.parameters.jumpboxAllowedSources.value | Where-Object { [string]$_ -match '^\d{1,3}(?:\.\d{1,3}){3}/32$' })
# Read the configured top-level foundation names, then verify or derive the exact Azure resource
# identities used later by Bicep. This is targeted lookup, not subscription-wide discovery.
    $parsedSources = @($singleHostSources | Where-Object {
        $candidateAddress = $null
        [System.Net.IPAddress]::TryParse(([string]$_ -replace '/32$', ''), [ref]$candidateAddress) -and $candidateAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
    })
    if ($parsedSources.Count -ne 1) {
        throw 'GitHub setup with -ParameterFile requires exactly one IPv4 /32 in jumpboxAllowedSources so YOUR_PUBLIC_IP can be read from the file.'
    }
    return ([string]$parsedSources[0] -replace '/32$', '')
}

# Resolve current foundation inputs before normal setup can create resources. Resource IDs are
# derived from the selected subscription and configured names; missing resources are tolerated
# only when the caller is explicitly preparing a foundation rebuild.
function Get-AMRLFoundationConfiguration {
    param(
        [Parameter(Mandatory = $true)][object]$Parameters,
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [switch]$AllowMissingFoundation
    )

    Assert-AMRLParameterDocumentCurrent -Parameters $Parameters
    $foundationResourceGroupParameter = $Parameters.parameters.PSObject.Properties['foundationResourceGroup']
    $keyVaultNameParameter = $Parameters.parameters.PSObject.Properties['keyVaultName']
    if ($null -eq $foundationResourceGroupParameter -or $null -eq $keyVaultNameParameter) {
        throw 'The current parameter contract requires top-level foundationResourceGroup and keyVaultName values.'
    }
    $defaultResourceGroup = [string]$foundationResourceGroupParameter.Value.value
    $configuredVaultName = [string]$keyVaultNameParameter.Value.value
    if ([string]::IsNullOrWhiteSpace($defaultResourceGroup) -or $defaultResourceGroup -match '[<>]') {
        throw 'Set a concrete top-level foundationResourceGroup value in the parameter file.'
    }
    if ($configuredVaultName -match '[<>]') { $configuredVaultName = '' }
    if ($script:ParameterFileWasExplicit -and [string]::IsNullOrWhiteSpace($configuredVaultName)) {
        throw 'Set a concrete top-level keyVaultName value in the explicit parameter file.'
    }
    $defaultIdentityName = Get-AMRLDefault 'automationManagedIdentityName'
    $result = [pscustomobject]@{
        ResourceGroup = $defaultResourceGroup
        IdentityResourceGroup = $defaultResourceGroup
        IdentityName = $defaultIdentityName
        IdentityId = ''
        VaultResourceGroup = $defaultResourceGroup
        VaultName = $configuredVaultName
        VaultId = ''
        RebuildFoundation = $false
        RecoveryConfirmed = $false
    }

    $result.IdentityName = $defaultIdentityName
    $result.IdentityResourceGroup = $defaultResourceGroup
    $result.IdentityId = "/subscriptions/$SubscriptionId/resourceGroups/$defaultResourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$defaultIdentityName"

    if (-not [string]::IsNullOrWhiteSpace($configuredVaultName)) {
        $result.VaultId = "/subscriptions/$SubscriptionId/resourceGroups/$defaultResourceGroup/providers/Microsoft.KeyVault/vaults/$configuredVaultName"
    }
    $canRebuildFoundation = $AllowMissingFoundation -and
        $result.ResourceGroup -eq $defaultResourceGroup -and
        $result.IdentityResourceGroup -eq $defaultResourceGroup -and
        $result.VaultResourceGroup -eq $defaultResourceGroup -and
        $result.IdentityName -eq $defaultIdentityName
    if ($canRebuildFoundation -and
        (Get-AzTsv -Arguments @('group', 'exists', '--name', $defaultResourceGroup)) -eq 'false') {
        $result.RebuildFoundation = $true
        return $result
    }
    if (-not [string]::IsNullOrWhiteSpace($result.IdentityId)) {
        $identity = $null
        Write-Host "Checking managed identity (AMRL default): $defaultIdentityName"
        try { $identity = Get-AzJson -Arguments @('identity', 'show', '--ids', $result.IdentityId) }
        catch {
            if (-not $canRebuildFoundation -or $_.Exception.Message -notmatch '\b(ResourceNotFound|ResourceGroupNotFound)\b') { throw }
        }
        if ($null -eq $identity -and $canRebuildFoundation) { $result.RebuildFoundation = $true }
        elseif ($null -eq $identity -or $identity.id -ne $result.IdentityId) { throw 'The explicitly referenced managed identity was not found. Restore it or review the parameter file.' }
    }
    if (-not [string]::IsNullOrWhiteSpace($result.VaultName)) {
        $vault = $null
        try { $vault = Get-AzJson -Arguments @('keyvault', 'show', '--name', $result.VaultName, '--resource-group', $result.VaultResourceGroup) }
        catch {
            if ($_.Exception.Message -notmatch '\b(ResourceNotFound|ResourceGroupNotFound)\b') { throw }
        }
        if ($null -eq $vault -and $canRebuildFoundation) { $result.RebuildFoundation = $true }
        elseif ($null -eq $vault) { $result.VaultId = '' }
        elseif ($vault.id -ne $result.VaultId) { throw 'The Key Vault name resolved to an unexpected resource ID.' }
    }
    return $result
}

function Set-AMRLFoundationResourceGroup {
    param(
        [Parameter(Mandatory = $true)][object]$Parameters,
        [Parameter(Mandatory = $true)][object]$Foundation,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$SubscriptionId
    )

    Assert-AMRLParameterDocumentCurrent -Parameters $Parameters
    $configuredVaultName = [string]$Parameters.parameters.keyVaultName.value
    $Foundation.ResourceGroup = $ResourceGroupName
    $Foundation.IdentityResourceGroup = $ResourceGroupName
    $Foundation.VaultResourceGroup = $ResourceGroupName
    $Foundation.IdentityId = ''
    $Foundation.VaultId = ''
    $Foundation.IdentityName = Get-AMRLDefault 'automationManagedIdentityName'
    $Foundation.RebuildFoundation = $true
    $Foundation.RecoveryConfirmed = $false

    $activeVaults = @()
    if ((Get-AzTsv -Arguments @('group', 'exists', '--name', $ResourceGroupName)) -eq 'true') {
        $activeVaults = @(Get-AzJson -Arguments @('keyvault', 'list', '--resource-group', $ResourceGroupName) | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.name) -and
            -not [string]::IsNullOrWhiteSpace([string]$_.id)
        })
    }
    $selectedVault = $null
    if ($activeVaults.Count -eq 1) {
        $candidate = $activeVaults[0]
        $reuseDefault = if ([string]$candidate.name -ieq $configuredVaultName) { 'yes' } else { 'no' }
        $reuseAnswer = Read-RequiredValue -Prompt "Reuse existing Key Vault '$($candidate.name)' in '$ResourceGroupName'?" -Hint 'y/N' -DefaultValue $reuseDefault -Validator {
            param($Value) $Value -in @('yes', 'no', 'y', 'n')
        }
        if ($reuseAnswer -in @('yes', 'y')) { $selectedVault = $candidate }
    }
    elseif ($activeVaults.Count -gt 1) {
        $vaultChoices = @($activeVaults | ForEach-Object { [string]$_.name }) + 'Create new Key Vault'
        $choiceDefault = if ($configuredVaultName -in $vaultChoices) { $configuredVaultName } else { '' }
        $selectedVaultName = Read-RequiredValue -Prompt "Choose an existing Key Vault in '$ResourceGroupName' or create a new one" -Hint ($vaultChoices -join ', ') -DefaultValue $choiceDefault -Validator {
            param($Value) $Value -in $vaultChoices
        }
        if ($selectedVaultName -ne 'Create new Key Vault') {
            $selectedVault = $activeVaults | Where-Object { $_.name -ceq $selectedVaultName } | Select-Object -First 1
        }
    }

    if ($null -ne $selectedVault) {
        $Foundation.VaultName = [string]$selectedVault.name
        $Foundation.VaultId = [string]$selectedVault.id
        Write-Host "Reusing Key Vault '$($Foundation.VaultName)' in '$ResourceGroupName'."
    }
    else {
        $escapedResourceGroup = [regex]::Escape($ResourceGroupName)
        $deletedVaults = @(Get-AzJson -Arguments @('keyvault', 'list-deleted', '--resource-type', 'vault', '--subscription', $SubscriptionId) | Where-Object {
            $deletedVaultId = [string]$_.properties.vaultId
            -not [string]::IsNullOrWhiteSpace([string]$_.name) -and
            $deletedVaultId -match "(?i)/resourceGroups/$escapedResourceGroup/providers/Microsoft\.KeyVault/vaults/[^/]+$"
        })
        $selectedDeletedVault = $null
        if ($deletedVaults.Count -eq 1) {
            $candidate = $deletedVaults[0]
            $recoverDefault = if ([string]$candidate.name -ieq $configuredVaultName) { 'yes' } else { 'no' }
            $recoverAnswer = Read-RequiredValue -Prompt "Recover soft-deleted Key Vault '$($candidate.name)' into '$ResourceGroupName' and preserve its secrets?" -Hint 'y/N' -DefaultValue $recoverDefault -Validator {
                param($Value) $Value -in @('yes', 'no', 'y', 'n')
            }
            if ($recoverAnswer -in @('yes', 'y')) { $selectedDeletedVault = $candidate }
        }
        elseif ($deletedVaults.Count -gt 1) {
            $deletedVaultChoices = @($deletedVaults | ForEach-Object { [string]$_.name }) + 'Create new Key Vault'
            $choiceDefault = if ($configuredVaultName -in $deletedVaultChoices) { $configuredVaultName } else { '' }
            $selectedDeletedName = Read-RequiredValue -Prompt "Choose a soft-deleted Key Vault in '$ResourceGroupName' or create a new one" -Hint ($deletedVaultChoices -join ', ') -DefaultValue $choiceDefault -Validator {
                param($Value) $Value -in $deletedVaultChoices
            }
            if ($selectedDeletedName -ne 'Create new Key Vault') {
                $candidate = $deletedVaults | Where-Object { $_.name -ceq $selectedDeletedName } | Select-Object -First 1
                $recoverAnswer = Read-RequiredValue -Prompt "Recover soft-deleted Key Vault '$selectedDeletedName' into '$ResourceGroupName' and preserve its secrets?" -Hint 'y/N' -DefaultValue 'no' -Validator {
                    param($Value) $Value -in @('yes', 'no', 'y', 'n')
                }
                if ($recoverAnswer -in @('yes', 'y')) { $selectedDeletedVault = $candidate }
            }
        }

        if ($null -ne $selectedDeletedVault) {
            $Foundation.VaultName = [string]$selectedDeletedVault.name
            $Foundation.VaultId = [string]$selectedDeletedVault.properties.vaultId
            $Foundation.RecoveryConfirmed = $true
            Write-Host "Selected soft-deleted Key Vault '$($Foundation.VaultName)' for recovery into '$ResourceGroupName'."
        }
        else {
            $Foundation.VaultName = Get-AMRLAvailableVaultName -SubscriptionId $SubscriptionId
        }
    }

    $foundationResourceGroupParameter = $Parameters.parameters.PSObject.Properties['foundationResourceGroup']
    $keyVaultNameParameter = $Parameters.parameters.PSObject.Properties['keyVaultName']
    if ($null -eq $foundationResourceGroupParameter -or $null -eq $keyVaultNameParameter) {
        throw 'Foundation replacement requires top-level foundationResourceGroup and keyVaultName parameters.'
    }
    $foundationResourceGroupParameter.Value.value = $ResourceGroupName
    $keyVaultNameParameter.Value.value = $Foundation.VaultName
}

function Read-AMRLFoundationResourceGroupName {
    param(
        [Parameter(Mandatory = $true)][string]$DefaultName,
        [string]$NameThatMustDiffer
    )

    return Read-RequiredValue -Prompt 'Foundation resource-group name' -Hint '1-90 characters, no spaces' -DefaultValue $DefaultName -IssuePhase 'Azure readiness and foundation' -Validator {
        param($Value)
        $candidate = [string]$Value
        $validName = $candidate.Length -le 90 -and $candidate -match '^[A-Za-z0-9._()-]+$' -and $candidate -notmatch '\.$'
        $isDifferent = [string]::IsNullOrWhiteSpace($NameThatMustDiffer) -or $candidate -ne $NameThatMustDiffer
        $nameIsAvailable = [string]::IsNullOrWhiteSpace($NameThatMustDiffer) -or
            (Get-AzTsv -Arguments @('group', 'exists', '--name', $candidate)) -eq 'false'
        $validName -and $isDifferent -and $nameIsAvailable
    }
}

function Restore-AMRLFoundationVault {
    param(
        [Parameter(Mandatory = $true)][string]$VaultName,
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$ExpectedVaultId,
        [switch]$RecoveryConfirmed
    )

    $deletedVault = Get-AzJson -Arguments @('keyvault', 'list-deleted', '--resource-type', 'vault', '--subscription', $SubscriptionId, '--query', "[?name=='$VaultName'] | [0]")
    if ($null -eq $deletedVault) { return }
    if ($deletedVault.properties.vaultId -ine $ExpectedVaultId) {
        throw "The soft-deleted vault '$VaultName' does not match the saved foundation vault ID. No vault was recovered or replaced."
    }
    $originalLocation = [string]$deletedVault.properties.location
    if ([string]::IsNullOrWhiteSpace($originalLocation)) { throw "The original location of soft-deleted vault '$VaultName' could not be determined. Recover it manually before retrying." }
    if (-not $RecoveryConfirmed -and (Read-Host "Recover soft-deleted Key Vault '$VaultName' in '$ResourceGroup' and preserve its secrets? [y/N]") -notmatch '^(y|yes)$') {
        throw 'Key Vault recovery was not confirmed. No replacement vault was created.'
    }
    $vault = Invoke-AMRLChange -Target "Key Vault $VaultName" -Action 'Recover soft-deleted foundation vault' -Operation {
        Get-AzJson -Arguments @('keyvault', 'recover', '--name', $VaultName, '--resource-group', $ResourceGroup, '--location', $originalLocation, '--subscription', $SubscriptionId)
    }
    if ($null -eq $vault -or $vault.id -ine $ExpectedVaultId) { throw 'Recovered Key Vault did not return the saved foundation resource ID. No replacement was selected.' }
    return $vault
}

# Availability checks never recover/purge deleted vaults or replace explicit references.
function Get-AMRLAvailableVaultName {
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)

    $baseName = 'amrl-kv-' + ($SubscriptionId -replace '-', '').Substring(0, 8)
    $requestPath = Join-Path $env:TEMP ('amrl-vault-name-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        for ($candidateIndex = 0; $candidateIndex -lt 10; $candidateIndex++) {
            $candidate = if ($candidateIndex -eq 0) { $baseName } else { "$baseName-$candidateIndex" }
            $body = @{ name = $candidate; type = 'Microsoft.KeyVault/vaults' } | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText($requestPath, $body, [System.Text.UTF8Encoding]::new($false))
            $availability = Get-AzJson -Arguments @('rest', '--method', 'post', '--url', "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.KeyVault/checkNameAvailability?api-version=2023-07-01", '--body', "@$requestPath")
            if ($null -ne $availability -and $availability.nameAvailable) { return $candidate }
            if ($null -eq $availability -or $availability.reason -ne 'AlreadyExists') { throw 'Key Vault name availability could not be established. Check naming policy and permissions before rerunning.' }
        }
        throw 'No available subscription-derived Key Vault name was found after 10 candidates. Review existing and soft-deleted vaults; none were purged.'
    }
    finally {
        if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
    }
}

function Get-GitHubSubject {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Branch
    )
    return "repo:${Repository}:ref:refs/heads/${Branch}"
}

# Reject retired parameter names, metadata fields, and secret-reference shapes before Azure writes begin.
function Assert-AMRLParameterDocumentCurrent {
    param([Parameter(Mandatory = $true)][object]$Parameters)

    $bootstrap = $null
    $prefixProperty = $Parameters.parameters.PSObject.Properties['prefix']
    if ($null -ne $prefixProperty) {
        $metadataProperty = $prefixProperty.Value.PSObject.Properties['metadata']
        if ($null -ne $metadataProperty) {
            $bootstrapProperty = $metadataProperty.Value.PSObject.Properties['bootstrap']
            if ($null -ne $bootstrapProperty) { $bootstrap = $bootstrapProperty.Value }
        }
    }
    if ($null -ne $bootstrap -and $null -ne $bootstrap.PSObject.Properties['foundationResourceGroup']) {
        throw 'This parameter file uses the retired metadata foundationResourceGroup field. Set top-level foundationResourceGroup and remove the metadata field.'
    }
    if ($null -ne $bootstrap -and $null -ne $bootstrap.PSObject.Properties['automationManagedIdentityName']) {
        throw 'Remove automationManagedIdentityName from bootstrap metadata; its value is owned by config/amrl-defaults.json.'
    }
    if ($null -ne $bootstrap -and $null -ne $bootstrap.PSObject.Properties['githubAppDisplayName']) {
        throw 'Remove githubAppDisplayName from bootstrap metadata; its value is owned by config/amrl-defaults.json.'
    }
    if ($null -ne $bootstrap -and $null -ne $bootstrap.PSObject.Properties['deploymentLocation']) {
        throw 'Remove deploymentLocation from bootstrap metadata; the bootstrapper derives it from the first regionIndexMap entry.'
    }
    foreach ($identityParameterName in @('automationManagedIdentityName', 'automationManagedIdentityResourceId')) {
        if ($null -ne $Parameters.parameters.PSObject.Properties[$identityParameterName]) {
            throw "Remove retired parameter '$identityParameterName'; identity naming is owned by config/amrl-defaults.json."
        }
    }
    foreach ($obsoleteName in @('jumpboxAdminPassword', 'labAdminPassword', 'sshPublicKey', 'sshPrivateKey')) {
        if ($null -ne $Parameters.parameters.PSObject.Properties[$obsoleteName]) {
            throw "This parameter file contains retired per-secret parameter '$obsoleteName'. Use the current parameter templates with top-level Key Vault settings."
        }
    }
    foreach ($entry in $Parameters.parameters.PSObject.Properties) {
        if ($null -ne $entry.Value.PSObject.Properties['reference']) {
            throw "Parameter '$($entry.Name)' uses a retired Key Vault reference object. The current contract uses Bicep getSecret() and value parameters only."
        }
    }
    foreach ($parameterName in @('foundationResourceGroup', 'keyVaultName')) {
        $parameter = $Parameters.parameters.PSObject.Properties[$parameterName]
        if ($null -eq $parameter -or $null -eq $parameter.Value.PSObject.Properties['value']) {
            throw "The current parameter contract requires a value for '$parameterName'. Use main.parameters.example.json as the schema."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Parameters.parameters.foundationResourceGroup.value) -or
        [string]$Parameters.parameters.foundationResourceGroup.value -match '[<>]') {
        throw 'Set a concrete top-level foundationResourceGroup value in the parameter file.'
    }
}

# Compare the supplied file with the checked-in complete parameter schema; GitHub settings remain
# client metadata and are not extra Bicep parameters.
function Assert-AMRLParameterDocumentComplete {
    param([Parameter(Mandatory = $true)][object]$Parameters)

    $templatePath = Join-Path $script:RepositoryRoot 'main.parameters.demo.json'
    $template = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $template.parameters.PSObject.Properties) {
        $provided = $Parameters.parameters.PSObject.Properties[$entry.Name]
        if ($null -eq $provided -or $null -eq $provided.Value.PSObject.Properties['value']) {
            $missing.Add($entry.Name)
        }
    }
    if ($missing.Count -gt 0) {
        throw "The parameter file is missing required Bicep parameter values: $($missing -join ', '). Add them from main.parameters.example.json before running the bootstrapper."
    }
    Assert-AMRLParameterDocumentCurrent -Parameters $Parameters
}

# Load an explicit file or local/demo defaults, apply only the prompts relevant to the selected
# stage, and save wizard changes unless this is the read-only Plan mode.
function Get-ParameterDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$IncludeGitHub
    )

    $script:PromptForPasswords = $false
    $script:PasswordChoiceMade = $false
    if (Test-Path -LiteralPath $Path) {
        $document = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
    else {
        if ($script:ParameterFileWasExplicit) {
            throw "The specified parameter file does not exist: $Path"
        }

        $demoPath = Join-Path $script:RepositoryRoot 'main.parameters.demo.json'
        if (-not (Test-Path -LiteralPath $demoPath)) {
            throw "Demo parameter file not found: $demoPath"
        }
        $document = Get-Content -Raw -LiteralPath $demoPath | ConvertFrom-Json
    }

    if ($null -eq $document.parameters.PSObject.Properties['stage']) {
        $document.parameters | Add-Member -NotePropertyName stage -NotePropertyValue ([pscustomobject]@{ value = 'all' })
    }
    if ($script:InteractiveConfiguration) {
        $stageChoices = @('all', 'network', 'compute', 'identity')
        $stageAnswer = Read-RequiredValue -Prompt 'Deployment stage' -Hint ($stageChoices -join ', ') -DefaultValue ([string]$document.parameters.stage.value) -Validator {
            param($Value) $Value -in @('all', 'network', 'compute', 'identity')
        }
        $document.parameters.stage.value = $stageAnswer.ToLowerInvariant()
    }
    $selectedStage = [string]$document.parameters.stage.value
    Assert-AMRLParameterDocumentCurrent -Parameters $document

    $templatePath = Join-Path $script:RepositoryRoot 'main.parameters.demo.json'
    $templateDocument = if ($Path -eq $templatePath) {
        $document
    }
    else {
        Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json
    }
    $bootstrapDefaults = $templateDocument.parameters.prefix.metadata.bootstrap
    $prefixMetadataProperty = $document.parameters.prefix.PSObject.Properties['metadata']
    if ($null -eq $prefixMetadataProperty) {
        $document.parameters.prefix | Add-Member -NotePropertyName metadata -NotePropertyValue ([pscustomobject]@{})
    }
    $bootstrapMetadataProperty = $document.parameters.prefix.metadata.PSObject.Properties['bootstrap']
    if ($null -eq $bootstrapMetadataProperty) {
        $document.parameters.prefix.metadata | Add-Member -NotePropertyName bootstrap -NotePropertyValue ([pscustomobject]@{})
    }
    if ($IncludeGitHub -and -not $script:InteractiveConfiguration) {
        foreach ($setting in @('githubRepository')) {
            $settingProperty = $document.parameters.prefix.metadata.bootstrap.PSObject.Properties[$setting]
            if ($null -eq $settingProperty -or [string]::IsNullOrWhiteSpace([string]$settingProperty.Value)) {
                throw "The explicit parameter file must define prefix.metadata.bootstrap.$setting when -IncludeGitHub is used."
            }
        }
    }
    $bootstrapSettings = @('githubRepository')
    if ($script:InteractiveConfiguration) { $bootstrapSettings += @('azureTenantId', 'azureSubscriptionId') }
    foreach ($setting in $bootstrapSettings) {
        $defaultProperty = $bootstrapDefaults.PSObject.Properties[$setting]
        $defaultValue = if ($null -eq $defaultProperty) { '' } else { [string]$defaultProperty.Value }
        $settingProperty = $document.parameters.prefix.metadata.bootstrap.PSObject.Properties[$setting]
        $currentValue = if ($null -eq $settingProperty) { '' } else { [string]$settingProperty.Value }
        if ([string]::IsNullOrWhiteSpace($currentValue)) {
            $document.parameters.prefix.metadata.bootstrap | Add-Member -NotePropertyName $setting -NotePropertyValue $defaultValue -Force
        }
    }
    if ($IncludeGitHub -and $script:InteractiveConfiguration) {
        $document.parameters.prefix.metadata.bootstrap.githubRepository = Read-RequiredValue -Prompt 'GitHub repository' -Hint 'exact full repository name' -DefaultValue ([string]$document.parameters.prefix.metadata.bootstrap.githubRepository)
    }

    Get-AMRLFoundationLocation -Parameters $document | Out-Null

    if (-not $script:InteractiveConfiguration) {
        return $document
    }

    $document.parameters.prefix.value = Read-RequiredValue -Prompt 'Lab prefix' -DefaultValue ([string]$document.parameters.prefix.value)

    $availableRegions = @($document.parameters.regionIndexMap.value.PSObject.Properties | Sort-Object { [int]$_.Value })
    $regionCount = Read-NonNegativeInteger -Prompt 'Region count' -Minimum 1 -Hint "whole number, 1 or greater; maximum $($availableRegions.Count) mapped regions" -DefaultValue ([string]$document.parameters.regionCount.value)
    $document.parameters.regionCount.value = $regionCount

    if ($selectedStage -in @('all', 'network')) {
        $networkModes = @('fullMesh', 'hubSpoke', 'hubSpokeFirewall')
        $document.parameters.networkMode.value = Read-RequiredValue -Prompt 'Network mode' -Hint ($networkModes -join ', ') -DefaultValue ([string]$document.parameters.networkMode.value)
    }

    $validationModes = @('reportOnly', 'enforce')
    $document.parameters.validationMode.value = Read-RequiredValue -Prompt 'Validation mode' -Hint ($validationModes -join ', ') -DefaultValue ([string]$document.parameters.validationMode.value)

    $document.parameters.maxVmsPerRegion.value = Read-NonNegativeInteger -Prompt 'maxVmsPerRegion' -Minimum 1 -DefaultValue ([string]$document.parameters.maxVmsPerRegion.value)
    if ($selectedStage -in @('all', 'identity')) {
        $minimumDepartmentCount = @($document.parameters.sysAdminDepartment.value.PSObject.Properties).Count
        $maximumDepartmentCount = @($document.parameters.sysAdminDepartment.value.PSObject.Properties).Count + @($document.parameters.additionalDepartments.value.PSObject.Properties).Count
        $document.parameters.departmentCount.value = Read-NonNegativeInteger -Prompt 'departmentCount' -Minimum $minimumDepartmentCount -Hint "whole number, $minimumDepartmentCount or greater; maximum $maximumDepartmentCount defined departments" -DefaultValue ([string]$document.parameters.departmentCount.value)
        $document.parameters.usersPerDepartment.value = Read-NonNegativeInteger -Prompt 'usersPerDepartment' -Minimum 1 -DefaultValue ([string]$document.parameters.usersPerDepartment.value)
    }

    foreach ($countName in @('dc', 'jumpbox', 'windowsServer', 'windowsClient', 'linuxServer', 'linuxClient')) {
        $defaultCount = [string]$document.parameters.vmCounts.value.$countName
        $hint = if ($countName -in @('dc', 'jumpbox')) { 'whole number, minimum 1' } else { 'whole number, 0 or greater' }
        $document.parameters.vmCounts.value.$countName = Read-NonNegativeInteger -Prompt "VM count for $countName" -Hint $hint -DefaultValue $defaultCount
    }

    $stageFeatureSettings = if ($selectedStage -in @('all', 'identity')) { @('useDedicatedFileServer', 'enableWindowsAdminCenter', 'useDedicatedWacHost') } else { @() }
    foreach ($setting in $stageFeatureSettings) {
        $defaultAnswer = if ($document.parameters.$setting.value) { 'yes' } else { 'no' }
        $answer = Read-RequiredValue -Prompt $setting -Hint 'y/N' -DefaultValue $defaultAnswer -Validator {
            param($Value) $Value -in @('yes', 'no', 'y', 'n', 'true', 'false')
        }
        $document.parameters.$setting.value = $answer -in @('yes', 'y', 'true')
    }

    if ($script:PlanMode) {
        Write-Host "Plan: Would save interactive lab settings to $Path."
    }
    else {
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $json = ConvertTo-AMRLParameterJson -InputObject $document
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    }

    return $document
}

# 5. Subscription-level setup: role assignments and Key Vault credentials
# These operations prepare resources outside the Bicep lab deployment. Existing settings are
# preserved where possible; replacing a missing secret does not rotate a password on an existing guest.
# Query the exact principal/role/scope tuple before creating a role assignment. Filtering by object ID
# avoids Azure CLI's Entra Graph lookup for newly created service principals.
function Set-AMRLRoleAssignmentIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$AssigneeObjectId,
        [Parameter(Mandatory = $true)][string]$PrincipalType,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$Scope
    )

    $existingId = Get-AzTsv -Arguments @(
        'role', 'assignment', 'list', '--scope', $Scope,
        '--query', "[?principalId=='$AssigneeObjectId' && roleDefinitionName=='$Role' && scope=='$Scope'].id"
    )
    if (-not [string]::IsNullOrWhiteSpace($existingId)) {
        $scopeLabel = if ($Scope -match '^/subscriptions/[^/]+$') { 'subscription' }
        elseif ($Scope -match '(?i)/providers/Microsoft\.KeyVault/vaults/([^/]+)$') { "Key Vault '$($Matches[1])'" }
        else { $Scope }
        Write-Host "Role assignment exists: $Role on $scopeLabel"
        return
    }

    [void](Invoke-AMRLChange -Target "$Role on $Scope for $AssigneeObjectId" -Action 'Create role assignment' -Operation {
        Invoke-AzCli -Arguments @(
            'role', 'assignment', 'create', '--assignee-object-id', $AssigneeObjectId,
            '--assignee-principal-type', $PrincipalType, '--role', $Role,
            '--scope', $Scope, '--output', 'none'
        )
    })
}

# Password-secret lifecycle: preserve active values, recover a soft-deleted value when present,
# and otherwise create a replacement. This manages Key Vault only; it does not rotate guest accounts.
function Set-AMRLSecretIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$VaultName,
        [Parameter(Mandatory = $true)][string]$SecretName,
        [switch]$Password,
        [switch]$Prompt
    )

    Write-Host "Checking Key Vault secret: $SecretName"
    $exists = Get-AzTsv -Arguments @(
        'keyvault', 'secret', 'list', '--vault-name', $VaultName,
        '--query', "[?name=='$SecretName'].name"
    )
    if (-not [string]::IsNullOrWhiteSpace($exists)) {
        Write-Host "Key Vault secret exists; keeping it unchanged: $SecretName"
        return
    }

    # A soft-deleted password name must be recovered before the bootstrapper can reuse it.
    if ($Password) {
        $deletedSecret = Get-AzTsv -Arguments @(
            'keyvault', 'secret', 'list-deleted', '--vault-name', $VaultName,
            '--query', "[?name=='$SecretName'].name"
        )
        if (-not [string]::IsNullOrWhiteSpace($deletedSecret)) {
            [void](Invoke-AMRLChange -Target "Deleted Key Vault secret $SecretName in $VaultName" -Action 'Recover deleted password secret' -Operation {
                Invoke-AzCli -Arguments @('keyvault', 'secret', 'recover', '--vault-name', $VaultName, '--name', $SecretName, '--output', 'none') | Out-Null
            })
            return
        }
    }

    if ($Password -and $script:InteractiveConfiguration -and -not $script:PasswordChoiceMade) {
        $passwordGenerationChoice = Read-RequiredValue -Prompt 'Randomly generate missing passwords?' -Hint 'y/N' -DefaultValue 'yes' -Validator {
            param($Value) $Value -in @('yes', 'no', 'y', 'n')
        }
        $script:PromptForPasswords = $passwordGenerationChoice -in @('no', 'n')
        $script:PasswordChoiceMade = $true
        $Prompt = $script:PromptForPasswords
    }

    Write-Host "Creating missing Key Vault secret: $SecretName"
    [void](Invoke-AMRLChange -Target "Key Vault secret $SecretName in $VaultName" -Action 'Create secret' -Operation {
        $secretValue = $null
        $secureValue = $null
        if ($Password -and $Prompt) {
            $secureValue = Read-Host "Password for $SecretName" -AsSecureString
            $confirmValue = Read-Host "Confirm password for $SecretName" -AsSecureString
            $secretValue = [System.Net.NetworkCredential]::new('', $secureValue).Password
            $confirmText = [System.Net.NetworkCredential]::new('', $confirmValue).Password
            if ($secretValue -ne $confirmText -or $secretValue.Length -lt 16) {
                $secureValue.Dispose()
                $confirmValue.Dispose()
                throw 'Passwords must match and contain at least 16 characters.'
            }
            $confirmValue.Dispose()
        }
        elseif ($Password) {
            $secretValue = New-AMRLPassword
        }
        else {
            throw "Secret '$SecretName' is missing and must be supplied by its dedicated setup path."
        }

        $secretFile = Join-Path $env:TEMP ('amrl-secret-' + [guid]::NewGuid().ToString('N') + '.txt')
        try {
            [System.IO.File]::WriteAllText($secretFile, $secretValue, (New-Object System.Text.UTF8Encoding($false)))
            Invoke-AzCli -Arguments @('keyvault', 'secret', 'set', '--vault-name', $VaultName, '--name', $SecretName, '--file', $secretFile, '--output', 'none') | Out-Null
        }
        finally {
            if (Test-Path -LiteralPath $secretFile) {
                Remove-Item -LiteralPath $secretFile -Force
            }
            $secretValue = $null
            if ($null -ne $secureValue) { $secureValue.Dispose() }
        }
    })
    Write-Host "Key Vault secret created: $SecretName"
}

# Reuse the dedicated local/vault pair; mismatches require intentional operator repair.
# Keep the public/private SSH keys as a matched pair; do not silently replace one half of an existing pair.
function Invoke-AMRLSSHKeygen {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments)

    $command = Get-Command 'ssh-keygen' -CommandType Application -ErrorAction Stop
    $result = Invoke-AMRLTimedProcess -Command $command.Source -Arguments $Arguments -TimeoutSeconds 30
    if ($result.ExitCode -ne 0) {
        $details = if ([string]::IsNullOrWhiteSpace($result.ErrorOutput)) { $result.Output.Trim() } else { $result.ErrorOutput.Trim() }
        throw "SSH key operation failed (exit $($result.ExitCode)): $details"
    }
    return $result.Output.Trim()
}

function Get-AMRLSSHKeyPublicText {
    param([Parameter(Mandatory = $true)][string]$PrivateKeyPath)

    return Invoke-AMRLSSHKeygen -Arguments @('-y', '-P', '', '-f', $PrivateKeyPath)
}

function Set-AMRLKeySecretsIfMissing {
    param([Parameter(Mandatory = $true)][string]$VaultName)

    $publicKeySecretName = Get-AMRLDefault 'sshPublicKeySecretName'
    $privateKeySecretName = Get-AMRLDefault 'sshPrivateKeySecretName'
    $keyPath = Join-Path $HOME '.ssh/amrl_ed25519'
    $publicPath = "$keyPath.pub"
    $privateExists = Test-Path -LiteralPath $keyPath
    $publicExists = Test-Path -LiteralPath $publicPath

    Write-Host "Checking Key Vault SSH secrets: $publicKeySecretName, $privateKeySecretName"
    $secretNames = @(Get-AzJson -Arguments @('keyvault', 'secret', 'list', '--vault-name', $VaultName, '--query', '[].name') | ForEach-Object {
        if ($_ -is [string]) { $_ } elseif ($null -ne $_.PSObject.Properties['name']) { [string]$_.name }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $hasPublicKey = $publicKeySecretName -in $secretNames
    $hasPrivateKey = $privateKeySecretName -in $secretNames
    $hasVaultPair = $hasPublicKey -and $hasPrivateKey

    if (-not $hasVaultPair) {
        $deletedSecretNames = @(Get-AzJson -Arguments @('keyvault', 'secret', 'list-deleted', '--vault-name', $VaultName, '--query', '[].name') | ForEach-Object {
            if ($_ -is [string]) { $_ } elseif ($null -ne $_.PSObject.Properties['name']) { [string]$_.name }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $hasDeletedPublicKey = $publicKeySecretName -in $deletedSecretNames
        $hasDeletedPrivateKey = $privateKeySecretName -in $deletedSecretNames
        $publicAvailable = $hasPublicKey -or $hasDeletedPublicKey
        $privateAvailable = $hasPrivateKey -or $hasDeletedPrivateKey

        if ($publicAvailable -xor $privateAvailable) {
            throw 'The SSH key pair in Key Vault is incomplete: only one public/private key secret is active or recoverable. Restore both matching secrets or resolve the pair manually; no key was replaced.'
        }

        if ($publicAvailable -and $privateAvailable) {
            foreach ($secretName in @($publicKeySecretName, $privateKeySecretName)) {
                if ($secretName -notin $secretNames) {
                    [void](Invoke-AMRLChange -Target "Deleted Key Vault SSH secret $secretName in $VaultName" -Action 'Recover deleted SSH key secret' -Operation {
                        Invoke-AzCli -Arguments @('keyvault', 'secret', 'recover', '--vault-name', $VaultName, '--name', $secretName, '--output', 'none') | Out-Null
                    })
                    $secretNames += $secretName
                }
            }
            $hasVaultPair = $true
        }
    }

    if ($hasVaultPair) {
        if ($privateExists -and $publicExists) {
            $publicKey = (Get-Content -Raw -LiteralPath $publicPath).Trim()
            $derivedPublicKey = Get-AMRLSSHKeyPublicText -PrivateKeyPath $keyPath
            $localPublicIdentity = @($publicKey -split '\s+' | Select-Object -First 2)
            $derivedPublicIdentity = @($derivedPublicKey -split '\s+' | Select-Object -First 2)
            if ($localPublicIdentity.Count -lt 2 -or $derivedPublicIdentity.Count -lt 2 -or
                (($derivedPublicIdentity -join ' ') -ne ($localPublicIdentity -join ' '))) {
                throw 'The local public and private SSH keys do not match. The script will not overwrite the valid Key Vault pair.'
            }
            $vaultPublicKey = (Get-AzTsv -Arguments @('keyvault', 'secret', 'show', '--vault-name', $VaultName, '--name', $publicKeySecretName, '--query', 'value')).Trim()
            $vaultPublicIdentity = @($vaultPublicKey -split '\s+' | Select-Object -First 2)
            if ($vaultPublicIdentity.Count -lt 2 -or (($vaultPublicIdentity -join ' ') -ne ($localPublicIdentity -join ' '))) {
                throw 'The Key Vault SSH public key differs from the local key pair. Resolve key rotation manually; the script will not overwrite either pair.'
            }
        }
        elseif ($privateExists -xor $publicExists) {
            Write-Warning "The Key Vault SSH pair is intact, but the local pair at '$keyPath' is incomplete. Keeping Key Vault unchanged; repair the local copy separately if needed."
        }
        else {
            Write-Host 'Key Vault SSH pair exists; keeping it unchanged and not generating a conflicting local pair.'
        }
        return
    }

    if ($privateExists -xor $publicExists) {
        throw "Local SSH key pair is incomplete at '$keyPath' and no complete Key Vault pair is available. Restore the pair or resolve it manually; the script will not overwrite either key."
    }
    if (-not $privateExists) {
        [void](Invoke-AMRLChange -Target $keyPath -Action 'Generate dedicated Ed25519 SSH key pair' -Operation {
            New-Item -ItemType Directory -Path (Split-Path $keyPath -Parent) -Force | Out-Null
            Invoke-AMRLSSHKeygen -Arguments @('-t', 'ed25519', '-f', $keyPath, '-N', '', '-q') | Out-Null
        })
        if (-not (Test-Path -LiteralPath $keyPath) -or -not (Test-Path -LiteralPath $publicPath)) {
            throw 'SSH key generation completed without producing both key files.'
        }
    }

    $publicKey = (Get-Content -Raw -LiteralPath $publicPath).Trim()
    $derivedPublicKey = Get-AMRLSSHKeyPublicText -PrivateKeyPath $keyPath
    $localPublicIdentity = @($publicKey -split '\s+' | Select-Object -First 2)
    $derivedPublicIdentity = @($derivedPublicKey -split '\s+' | Select-Object -First 2)
    if ($localPublicIdentity.Count -lt 2 -or $derivedPublicIdentity.Count -lt 2 -or
        (($derivedPublicIdentity -join ' ') -ne ($localPublicIdentity -join ' '))) {
        throw 'The public and private SSH keys do not match. The script will not upload either key.'
    }

    if (-not $hasPublicKey -and -not $hasPrivateKey) {
        [void](Invoke-AMRLChange -Target "SSH key secrets in $VaultName" -Action 'Write dedicated SSH key pair to Key Vault' -Operation {
            Write-Host "Creating missing Key Vault secret: $publicKeySecretName"
            Invoke-AzCli -Arguments @('keyvault', 'secret', 'set', '--vault-name', $VaultName, '--name', $publicKeySecretName, '--value', $publicKey, '--output', 'none') | Out-Null
            Write-Host "Key Vault secret created: $publicKeySecretName"
            Write-Host "Creating missing Key Vault secret: $privateKeySecretName"
            Invoke-AzCli -Arguments @('keyvault', 'secret', 'set', '--vault-name', $VaultName, '--name', $privateKeySecretName, '--file', $keyPath, '--output', 'none') | Out-Null
            Write-Host "Key Vault secret created: $privateKeySecretName"
        })
    }
}

# 6. Optional GitHub setup: OIDC identity/access and Actions deployment values
# Federated credentials bind repository/branch or pull-request subjects to Entra tokens;
# readiness checks inspect names and trust configuration without exposing stored secret values.
function Test-AMRLFederatedCredential {
    param([Parameter(Mandatory = $true)][object]$TrustRecord)

    $issuer = $TrustRecord.PSObject.Properties['issuer']
    $audiences = $TrustRecord.PSObject.Properties['audiences']
    return ($null -ne $issuer -and $issuer.Value -ceq 'https://token.actions.githubusercontent.com' -and
        $null -ne $audiences -and @($audiences.Value).Count -eq 1 -and
        @($audiences.Value)[0] -ceq 'api://AzureADTokenExchange')
}

# Secret names can be verified; GitHub does not expose their stored values for read-back.
function Get-AMRLGitHubReadiness {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$AppDisplayName,
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [string]$VaultId,
        [string]$VaultName,
        [string]$IdentityId,
        [string]$PublicIp
    )

    $actions = New-Object 'System.Collections.Generic.List[string]'
    $blockers = New-Object 'System.Collections.Generic.List[string]'
    try {
        Assert-AMRLGitHubRepositoryAccess -Repository $Repository
        $apps = @(Get-AzJson -Arguments @('ad', 'app', 'list', '--display-name', $AppDisplayName))
        if ($apps.Count -gt 1) { throw "Multiple Entra apps are named '$AppDisplayName'; select a unique app name in the GitHub settings." }
        if ($apps.Count -eq 0) {
            $actions.Add("Create Entra app '$AppDisplayName', its service principal, RBAC assignments, and GitHub federated credentials")
        }
        else {
            $app = $apps[0]
            $principals = @(Get-AzJson -Arguments @('ad', 'sp', 'list', '--filter', "appId eq '$($app.appId)'"))
            if ($principals.Count -eq 0) { $actions.Add("Create the service principal for '$AppDisplayName' and assign its required roles") }
            else {
                $roleScopes = @(@{ Role = 'Contributor'; Scope = "/subscriptions/$SubscriptionId" })
                if (-not [string]::IsNullOrWhiteSpace($VaultId)) { $roleScopes += @{ Role = 'Key Vault Secrets User'; Scope = $VaultId } }
                foreach ($roleScope in $roleScopes) {
                    $assignment = Get-AzTsv -Arguments @('role', 'assignment', 'list', '--scope', $roleScope.Scope, '--assignee', $principals[0].id, '--query', "[?roleDefinitionName=='$($roleScope.Role)' && scope=='$($roleScope.Scope)'].id")
                    if ([string]::IsNullOrWhiteSpace($assignment)) { $actions.Add("Assign $($roleScope.Role) to the GitHub service principal on $($roleScope.Scope)") }
                }
            }
            $branch = Get-AMRLGitBranch
            $subjects = @((Get-GitHubSubject -Repository $Repository -Branch 'main'), "repo:${Repository}:pull_request")
            if ($branch -cne 'main') { $subjects += Get-GitHubSubject -Repository $Repository -Branch $branch }
            $credentials = @(Get-AzJson -Arguments @('ad', 'app', 'federated-credential', 'list', '--id', $app.id))
            foreach ($subject in $subjects) {
                $matching = @($credentials | Where-Object { $_.subject -ceq $subject })
                if ($matching.Count -eq 0) { $actions.Add("Create federated credential for $subject") }
                elseif ($matching.Count -ne 1 -or -not (Test-AMRLFederatedCredential -TrustRecord $matching[0])) {
                    $blockers.Add("Federated credential for $subject has conflicting issuer/audience settings; review it manually.")
                }
            }
        }
        $secretJson = Invoke-GhCli -Arguments @('secret', 'list', '--repo', $Repository, '--json', 'name')
        $secrets = $secretJson | ConvertFrom-Json
        $secretNames = @($secrets | ForEach-Object { $_.name })
        foreach ($secretName in @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID')) {
            if ($secretName -cnotin $secretNames) { $actions.Add("Set GitHub Actions secret $secretName in $Repository") }
        }
        $variableJson = Invoke-GhCli -Arguments @('variable', 'list', '--repo', $Repository, '--json', 'name,value')
        $variables = $variableJson | ConvertFrom-Json
        $expectedVariables = @{ KEYVAULT_NAME = $VaultName; YOUR_PUBLIC_IP = $PublicIp }
        foreach ($variableName in $expectedVariables.Keys) {
            $matching = @($variables | Where-Object { $_.name -ceq $variableName })
            if ($matching.Count -ne 1 -or
                (-not [string]::IsNullOrWhiteSpace($expectedVariables[$variableName]) -and $matching[0].value -cne $expectedVariables[$variableName])) {
                $actions.Add("Set GitHub Actions variable $variableName in $Repository to match this setup")
            }
        }
    }
    catch { $blockers.Add("Could not verify GitHub setup: $($_.Exception.Message)") }
    return [pscustomobject]@{ Actions = @($actions.ToArray()); Blockers = @($blockers.ToArray()) }
}

function New-AMRLFederatedCredentialIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$AppObjectId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Subject,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $credentials = Get-AzJson -Arguments @('ad', 'app', 'federated-credential', 'list', '--id', $AppObjectId)
    $bySubject = @($credentials | Where-Object { $_.subject -ceq $Subject })
    if ($bySubject.Count -gt 0) {
        if ($bySubject.Count -ne 1 -or -not (Test-AMRLFederatedCredential -TrustRecord $bySubject[0])) {
            throw "Federated credential for '$Subject' has conflicting issuer/audience settings. Resolve it manually."
        }
        Write-Host "Federated credential exists: $Subject"
        return [pscustomobject]@{ Status = 'Already existed'; Name = $bySubject[0].name; Subject = $Subject }
    }

    $byName = @($credentials | Where-Object { $_.name -eq $Name })
    if ($byName.Count -gt 0) {
        throw "Federated credential name '$Name' already exists with a different subject. Resolve it manually."
    }

    $credential = @{
        name = $Name
        issuer = 'https://token.actions.githubusercontent.com'
        subject = $Subject
        description = $Description
        audiences = @('api://AzureADTokenExchange')
    }
    $path = Join-Path $env:TEMP ('amrl-federated-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $json = $credential | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
        [void](Invoke-AMRLChange -Target "Federated credential $Name on app $AppObjectId" -Action 'Create GitHub OIDC credential' -Operation {
            Invoke-AzCli -Arguments @('ad', 'app', 'federated-credential', 'create', '--id', $AppObjectId, '--parameters', $path, '--output', 'none') | Out-Null
        })
        Write-Host "Federated credential created: $Subject"
        return [pscustomobject]@{ Status = 'Created'; Name = $Name; Subject = $Subject }
    }
    finally {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

function Set-AMRLGitHubConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$VaultId,
        [Parameter(Mandatory = $true)][string]$VaultName,
        [Parameter(Mandatory = $true)][string]$IdentityId,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$AppDisplayName,
        [string]$PublicIp
    )

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is required when -IncludeGitHub is used.'
    }
    Invoke-GhCli -Arguments @('auth', 'status') | Out-Null

    $apps = @(Get-AzJson -Arguments @('ad', 'app', 'list', '--display-name', $AppDisplayName))
    if ($apps.Count -gt 1) {
        throw "More than one app registration is named '$AppDisplayName'. Resolve the duplicate manually."
    }
    if ($apps.Count -eq 0) {
        $app = Invoke-AMRLChange -Target "Entra app $AppDisplayName" -Action 'Create app registration' -Operation {
            Get-AzJson -Arguments @('ad', 'app', 'create', '--display-name', $AppDisplayName)
        }
        if ($null -eq $app) { return }
    }
    else {
        $app = $apps[0]
    }

    $servicePrincipals = @(Get-AzJson -Arguments @('ad', 'sp', 'list', '--filter', "appId eq '$($app.appId)'"))
    if ($servicePrincipals.Count -eq 0) {
        $servicePrincipal = Invoke-AMRLChange -Target "Service principal for $AppDisplayName" -Action 'Create service principal' -Operation {
            Get-AzJson -Arguments @('ad', 'sp', 'create', '--id', $app.appId)
        }
        if ($null -eq $servicePrincipal) { return }
    }
    else {
        $servicePrincipal = $servicePrincipals[0]
    }

    Set-AMRLRoleAssignmentIfMissing -AssigneeObjectId $servicePrincipal.id -PrincipalType ServicePrincipal -Role 'Contributor' -Scope "/subscriptions/$SubscriptionId"
    Set-AMRLRoleAssignmentIfMissing -AssigneeObjectId $servicePrincipal.id -PrincipalType ServicePrincipal -Role 'Key Vault Secrets User' -Scope $VaultId

    $federatedCredentialResults = New-Object 'System.Collections.Generic.List[object]'
    $federatedCredentialResults.Add((New-AMRLFederatedCredentialIfMissing -AppObjectId $app.id -Name 'github-actions-main' -Subject (Get-GitHubSubject -Repository $Repository -Branch 'main') -Description 'GitHub Actions - main branch'))
    $branch = Get-AMRLGitBranch
    if ($branch -cne 'main') {
        $branchSuffix = ($branch -replace '[^A-Za-z0-9_-]', '-')
        if ($branchSuffix.Length -gt 75) { $branchSuffix = $branchSuffix.Substring(0, 75) }
        $federatedCredentialResults.Add((New-AMRLFederatedCredentialIfMissing -AppObjectId $app.id -Name "github-actions-$branchSuffix" -Subject (Get-GitHubSubject -Repository $Repository -Branch $branch) -Description "GitHub Actions - $branch"))
    }
    $federatedCredentialResults.Add((New-AMRLFederatedCredentialIfMissing -AppObjectId $app.id -Name 'github-actions-pull-request' -Subject "repo:${Repository}:pull_request" -Description 'GitHub Actions - pull requests'))

    [void](Invoke-AMRLChange -Target "GitHub Actions secrets in $Repository" -Action 'Set Azure OIDC repository secrets' -Operation {
        Invoke-GhCli -Arguments @('secret', 'set', 'AZURE_CLIENT_ID', '--body', $app.appId, '--repo', $Repository) | Out-Null
        Invoke-GhCli -Arguments @('secret', 'set', 'AZURE_TENANT_ID', '--body', $TenantId, '--repo', $Repository) | Out-Null
        Invoke-GhCli -Arguments @('secret', 'set', 'AZURE_SUBSCRIPTION_ID', '--body', $SubscriptionId, '--repo', $Repository) | Out-Null
    })

    [void](Invoke-AMRLChange -Target "GitHub Actions variables in $Repository" -Action 'Set AMRL repository variables' -Operation {
        Invoke-GhCli -Arguments @('variable', 'set', 'KEYVAULT_NAME', '--body', $VaultName, '--repo', $Repository) | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($PublicIp)) {
            Invoke-GhCli -Arguments @('variable', 'set', 'YOUR_PUBLIC_IP', '--body', $PublicIp, '--repo', $Repository) | Out-Null
        }
    })
    $readiness = Get-AMRLGitHubReadiness -Repository $Repository -AppDisplayName $AppDisplayName -SubscriptionId $SubscriptionId -VaultId $VaultId -VaultName $VaultName -IdentityId $IdentityId -PublicIp $PublicIp
    if ($readiness.Actions.Count -gt 0 -or $readiness.Blockers.Count -gt 0) {
        throw "GitHub setup read-back found unresolved settings:`n$((@($readiness.Actions) + @($readiness.Blockers)) -join "`n")"
    }
    Write-Host 'GitHub OIDC, role assignments, Actions variables, and secret names verified. Secret values cannot be read back.'
    return [pscustomobject]@{ FederatedCredentials = @($federatedCredentialResults.ToArray()) }
}

# 7. Read-only readiness and template preflight; no saved engine findings are produced
# Plan validates tools, prerequisites, Bicep inputs, and the Azure what-if preview. The AMRL
# validation engine's saved findings are produced only by an actual Bicep deployment.
function Invoke-AMRLPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Parameters,
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$FoundationLocation,
        [Parameter(Mandatory = $true)][string]$IdentityName,
        [Parameter(Mandatory = $true)][string]$DeploymentLocation,
        [string]$VaultResourceGroup = $ResourceGroup,
        [string]$IdentityResourceGroup = $ResourceGroup,
        [string]$VaultName,
        [string]$PublicIp,
        [string]$Repository,
        [string]$AppDisplayName,
        [switch]$IncludeGitHub,
        [switch]$DiagnosticOnly
    )

    $actions = New-Object 'System.Collections.Generic.List[string]'
    $blockers = New-Object 'System.Collections.Generic.List[string]'
    $diagnosticDeploymentStatus = if ($DiagnosticOnly) { 'Skipped' } else { 'Not requested' }
    $diagnosticDeploymentSummary = if ($DiagnosticOnly) { 'No deployment was started; this was a read-only diagnostic fallback.' } else { 'Plan mode never deploys resources.' }
    $requiredProviders = @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.ManagedIdentity', 'Microsoft.Storage', 'Microsoft.ContainerInstance')
    Initialize-AMRLRunPhase -Name 'Plan prerequisite checks'

    Write-Host 'Read-only plan: checking Azure resource providers and foundation resources...'
    foreach ($namespace in $requiredProviders) {
        $state = Get-AzTsv -Arguments @('provider', 'show', '--namespace', $namespace, '--query', 'registrationState')
        if ($state -ne 'Registered') {
            $actions.Add("Register resource provider $namespace")
            $blockers.Add("Provider $namespace is not registered (state: $state).")
        }
    }

    $resourceGroupExists = Get-AzTsv -Arguments @('group', 'exists', '--name', $ResourceGroup)
    if ($resourceGroupExists -ne 'true') {
        $actions.Add("Create resource group $ResourceGroup in $FoundationLocation")
        $blockers.Add("Foundation resource group '$ResourceGroup' does not exist.")
    }

    $identity = $null
    $vaults = @()
    $keyVaultWasExplicit = -not [string]::IsNullOrWhiteSpace($VaultName)
    Write-Host "Read-only plan: checking managed identity '$IdentityName' and Key Vault."
    if ((Get-AzTsv -Arguments @('group', 'exists', '--name', $IdentityResourceGroup)) -eq 'true') {
        $identity = Get-AzJson -Arguments @('identity', 'list', '--resource-group', $IdentityResourceGroup, '--query', "[?name=='$IdentityName'] | [0]")
        if ($null -eq $identity) {
            $actions.Add("Create user-assigned managed identity $IdentityName")
            $blockers.Add("Managed identity '$IdentityName' does not exist in '$ResourceGroup'.")
        }

    }
    $vaultGroupExists = (Get-AzTsv -Arguments @('group', 'exists', '--name', $VaultResourceGroup)) -eq 'true'
    if ($vaultGroupExists) { $vaults = @(Get-AzJson -Arguments @('keyvault', 'list', '--resource-group', $VaultResourceGroup)) }

    if ([string]::IsNullOrWhiteSpace($VaultName)) {
        if ($vaults.Count -eq 1) {
            $VaultName = [string]$vaults[0].name
        }
        elseif ($vaults.Count -gt 1) {
            $blockers.Add('Multiple Key Vaults exist in the foundation group; set top-level keyVaultName to select the intended vault.')
        }
        else {
            $VaultName = Get-AMRLAvailableVaultName -SubscriptionId $Context.id
            $actions.Add("Create RBAC-enabled Key Vault $VaultName with template deployment and purge protection")
            $blockers.Add("Key Vault '$VaultName' does not exist in the foundation group.")
        }
    }

    if ($null -ne $script:BootstrapperReport -and $null -ne $script:BootstrapperReport.FoundationConfiguration) {
        $script:BootstrapperReport.FoundationConfiguration.VaultName = $VaultName
    }
    $vault = $null
    if (-not [string]::IsNullOrWhiteSpace($VaultName) -and $vaultGroupExists) {
        $vault = Get-AzJson -Arguments @('keyvault', 'list', '--resource-group', $VaultResourceGroup, '--query', "[?name=='$VaultName'] | [0]")
        if ($null -ne $vault) {
            $vault = Get-AzJson -Arguments @('keyvault', 'show', '--name', $VaultName, '--resource-group', $VaultResourceGroup)
            if (-not $vault.properties.enableRbacAuthorization -or
                -not $vault.properties.enabledForTemplateDeployment -or
                -not $vault.properties.enablePurgeProtection) {
                $blockers.Add("Key Vault '$VaultName' is missing required RBAC, template-deployment, or purge-protection settings.")
            }
        }
        elseif ($vaults.Count -gt 0 -or $keyVaultWasExplicit) {
            $actions.Add("Create Key Vault $VaultName with RBAC, template deployment, and purge protection")
            $blockers.Add("Selected Key Vault '$VaultName' does not exist in '$ResourceGroup'.")
        }
    }

    if ($null -ne $identity) {
        $roleId = Get-AzTsv -Arguments @(
            'role', 'assignment', 'list', '--scope', "/subscriptions/$($Context.id)",
            '--assignee', $identity.principalId,
            '--query', "[?roleDefinitionName=='Network Contributor' && scope=='/subscriptions/$($Context.id)'].id"
        )
        if ([string]::IsNullOrWhiteSpace($roleId)) {
            $actions.Add('Assign Network Contributor to the managed identity at subscription scope')
            $blockers.Add('The managed identity is missing its subscription-scope Network Contributor assignment.')
        }
    }

    $existingSecrets = @()
    $userId = Get-AzTsv -Arguments @('ad', 'signed-in-user', 'show', '--query', 'id')
    if ($null -ne $vault -and -not [string]::IsNullOrWhiteSpace($userId)) {
        Write-Host 'Read-only plan: checking Key Vault access and required secret names.'
        $userRoleId = Get-AzTsv -Arguments @(
            'role', 'assignment', 'list', '--scope', $vault.id,
            '--assignee', $userId,
            '--query', "[?roleDefinitionName=='Key Vault Secrets Officer' && scope=='$($vault.id)'].id"
        )
        if ([string]::IsNullOrWhiteSpace($userRoleId)) {
            $actions.Add("Assign Key Vault Secrets Officer to the signed-in user on $VaultName")
            $blockers.Add('The signed-in user is missing Key Vault Secrets Officer on the selected vault.')
        }

        try {
            $existingSecrets = @(Get-AzJson -Arguments @('keyvault', 'secret', 'list', '--vault-name', $VaultName, '--query', '[].name'))
            foreach ($secretName in (Get-AMRLManagedSecretNames)) {
                Write-Host "Read-only plan: checking Key Vault secret: $secretName"
                if ($secretName -notin $existingSecrets) {
                    $actions.Add("Create Key Vault secret $secretName")
                    $blockers.Add("Required Key Vault secret '$secretName' is missing.")
                }
                else { Write-Host "Key Vault secret exists; keeping it unchanged: $secretName" }
            }
        }
        catch {
            $blockers.Add("Could not inspect required Key Vault secrets: $($_.Exception.Message)")
        }
    }

    $localPrivateKey = Join-Path $HOME '.ssh/amrl_ed25519'
    $localPublicKey = "$localPrivateKey.pub"
    Write-Host 'Read-only plan: checking the local SSH key pair and foundation protection locks.'
    $hasLocalPrivateKey = Test-Path -LiteralPath $localPrivateKey
    $hasLocalPublicKey = Test-Path -LiteralPath $localPublicKey
    if ($hasLocalPrivateKey -xor $hasLocalPublicKey) {
        $blockers.Add('The local SSH key pair is incomplete; restore or reconcile both key files.')
    }
    elseif (-not $hasLocalPrivateKey) {
        $actions.Add("Generate a dedicated Ed25519 SSH key pair at $localPrivateKey")
        $blockers.Add('The local SSH key pair is missing and must be generated before setup can reconcile its Key Vault copy.')
    }
    elseif ($null -ne $vault) {
        $localPublicText = (Get-Content -Raw -LiteralPath $localPublicKey).Trim()
        try {
            $derivedPublicText = Get-AMRLSSHKeyPublicText -PrivateKeyPath $localPrivateKey
            if ((@($derivedPublicText -split '\s+' | Select-Object -First 2) -join ' ') -ne (@($localPublicText -split '\s+' | Select-Object -First 2) -join ' ')) {
                $blockers.Add('The local SSH public/private key files do not match.')
            }
            else {
                if ((Get-AMRLDefault 'sshPublicKeySecretName') -in $existingSecrets) {
                    $vaultPublicText = Get-AzTsv -Arguments @('keyvault', 'secret', 'show', '--vault-name', $VaultName, '--name', (Get-AMRLDefault 'sshPublicKeySecretName'), '--query', 'value')
                    if (-not [string]::IsNullOrWhiteSpace($vaultPublicText) -and $vaultPublicText.Trim() -ne $localPublicText) {
                        $blockers.Add('The local SSH public key differs from the Key Vault copy; resolve the mismatch manually.')
                    }
                }
            }
        }
        catch {
            $blockers.Add("The local SSH private key could not be opened with the configured blank passphrase: $($_.Exception.Message)")
        }
    }

    foreach ($lockGroup in (@($IdentityResourceGroup, $VaultResourceGroup) | Select-Object -Unique)) {
        if ((Get-AzTsv -Arguments @('group', 'exists', '--name', $lockGroup)) -eq 'true') {
            $lock = Get-AzJson -Arguments @('lock', 'list', '--resource-group', $lockGroup, '--query', "[?name=='protect-foundation'] | [0]")
            if ($null -eq $lock) {
                $actions.Add("Apply CanNotDelete lock protect-foundation to $lockGroup")
            }
            elseif ($lock.level -ne 'CanNotDelete') {
                $blockers.Add("Lock 'protect-foundation' in '$lockGroup' exists at level '$($lock.level)', not CanNotDelete.")
            }
        }
    }

    if ($IncludeGitHub) {
        Write-Host 'Read-only plan: checking GitHub OIDC readiness.'
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            $blockers.Add('GitHub CLI (gh) is required for -IncludeGitHub.')
        }
        else {
            try { Invoke-GhCli -Arguments @('auth', 'status') | Out-Null }
            catch { $blockers.Add("GitHub CLI is not authenticated: $($_.Exception.Message)") }
            $vaultIdForGitHub = if ($null -eq $vault) { '' } else { [string]$vault.id }
            $identityIdForGitHub = if ($null -eq $identity) { '' } else { [string]$identity.id }
            $readiness = Get-AMRLGitHubReadiness -Repository $Repository -AppDisplayName $AppDisplayName -SubscriptionId $Context.id -VaultId $vaultIdForGitHub -VaultName $VaultName -IdentityId $identityIdForGitHub -PublicIp $PublicIp
            foreach ($action in $readiness.Actions) { $actions.Add($action) }
            foreach ($blocker in $readiness.Blockers) { $blockers.Add($blocker) }
        }
    }

    Write-Host 'Read-only AMRL bootstrap plan'
    Write-Host "Subscription: $($Context.name) ($($Context.id)); tenant: $($Context.tenantId)"
    if ($actions.Count -gt 0) {
        Write-Host 'Bootstrap actions required:'
        foreach ($action in $actions) { Write-Host "  - $action" }
    }
    else {
        Write-Host 'No missing foundation actions detected.'
    }
    if ($blockers.Count -gt 0) {
        Write-Host 'Plan blockers:'
        foreach ($blocker in ($blockers | Select-Object -Unique)) { Write-Host "  - $blocker" }
        foreach ($blocker in ($blockers | Select-Object -Unique)) { Add-AMRLReportIssue -Phase 'Plan prerequisite checks' -Severity Warning -Message $blocker }
        Set-AMRLReportSource -Name 'Read-only prerequisite plan' -Status 'Blockers found' -Summary "$($blockers.Count) prerequisite blockers found." -Details (($blockers | Select-Object -Unique) -join [Environment]::NewLine)
        Set-AMRLReportPhase -Name 'Plan prerequisite checks' -Status 'Issues found' -Summary "$($blockers.Count) required prerequisites need attention."
        Initialize-AMRLRunPhase -Name 'Bicep build and validation'
        $mainTemplate = Join-Path $script:RepositoryRoot 'main.bicep'
        $buildResult = Invoke-AMRLObservedCommand -Name 'Bicep build' -Arguments @('bicep', 'build', '--file', $mainTemplate)
        $lintResult = Invoke-AMRLObservedCommand -Name 'Bicep lint' -Arguments @('bicep', 'lint', '--file', $mainTemplate)
        if ($buildResult.Succeeded -and $lintResult.Succeeded) {
            Complete-AMRLRunPhase -Name 'Bicep build and validation' -Summary 'Static build and lint succeeded; Azure validation requires missing prerequisites.'
        }
        else {
            Set-AMRLReportPhase -Name 'Bicep build and validation' -Status 'Failed' -Summary 'One or more static Bicep checks failed.'
        }
        Set-AMRLReportPhase -Name 'What-if preview' -Status 'Skipped' -Summary 'What-if requires resolved prerequisite configuration.'
        Set-AMRLReportPhase -Name 'Deployment' -Status $diagnosticDeploymentStatus -Summary $diagnosticDeploymentSummary
        Set-AMRLReportPhase -Name 'AMRL validation engine outputs' -Status 'Not available' -Summary 'No deployment was started.'
        Set-AMRLReportPhase -Name 'VM setup checks' -Status 'Not available' -Summary 'No VM setup checks were collected.'
        Write-Host 'Azure validate/what-if was skipped because required parameter and foundation inputs are unresolved.'
        return
    }
    Complete-AMRLRunPhase -Name 'Plan prerequisite checks' -Summary 'Required foundation and identity checks passed.'
    Set-AMRLReportSource -Name 'Read-only prerequisite plan' -Status 'Ready' -Summary 'No blocking prerequisites found.'

    $updatedParameters = Set-AMRLParameterValues -Parameters $Parameters -FoundationResourceGroup $ResourceGroup -KeyVaultName $VaultName -PublicIp $PublicIp
    $temporaryParameterFile = Join-Path $env:TEMP ('amrl-plan-parameters-' + [guid]::NewGuid().ToString('N') + '.json')
    $temporaryBicepFile = Join-Path $env:TEMP ('amrl-plan-bicep-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $parameterJson = $updatedParameters | ConvertTo-Json -Depth 100
        [System.IO.File]::WriteAllText($temporaryParameterFile, $parameterJson, [System.Text.UTF8Encoding]::new($false))
        $mainTemplate = Join-Path $script:RepositoryRoot 'main.bicep'
        Write-Host 'Prepare and Plan check the template and preview Azure changes; AMRL validation engine findings are produced only during deployment.'
        Write-Host 'Running template preflight: compilation, validation, and what-if...'
        Initialize-AMRLRunPhase -Name 'Bicep build and validation'
        $buildResult = Invoke-AMRLObservedCommand -Name 'Bicep build' -Arguments @('bicep', 'build', '--file', $mainTemplate, '--outfile', $temporaryBicepFile)
        $lintResult = Invoke-AMRLObservedCommand -Name 'Bicep lint' -Arguments @('bicep', 'lint', '--file', $mainTemplate)
        $validateResult = Invoke-AMRLObservedCommand -Name 'Azure deployment validate' -Arguments @('deployment', 'sub', 'validate', '--location', $DeploymentLocation, '--template-file', $mainTemplate, '--parameters', $temporaryParameterFile, '--output', 'json')
        if ($buildResult.Succeeded -and $lintResult.Succeeded -and $validateResult.Succeeded) {
            Complete-AMRLRunPhase -Name 'Bicep build and validation' -Summary 'Bicep build, lint, and Azure deployment validate succeeded.'
        }
        else {
            Set-AMRLReportPhase -Name 'Bicep build and validation' -Status 'Failed' -Summary 'One or more build, lint, or Azure validation checks failed.'
        }
        Initialize-AMRLRunPhase -Name 'What-if preview'
        $whatIfResult = Invoke-AMRLObservedCommand -Name 'Azure deployment what-if' -Arguments @('deployment', 'sub', 'what-if', '--name', ('amrl-plan-' + (Get-Date -Format 'yyyyMMdd-HHmmss')), '--location', $DeploymentLocation, '--template-file', $mainTemplate, '--parameters', $temporaryParameterFile, '--no-pretty-print', '--output', 'json')
        if ($whatIfResult.Succeeded) { Complete-AMRLRunPhase -Name 'What-if preview' -Summary 'Azure returned a deployment change preview.' }
        else { Set-AMRLReportPhase -Name 'What-if preview' -Status 'Failed' -Summary 'What-if failed; inspect the captured Azure CLI error.' }
        Set-AMRLReportPhase -Name 'Deployment' -Status $diagnosticDeploymentStatus -Summary $diagnosticDeploymentSummary
        Set-AMRLReportPhase -Name 'AMRL validation engine outputs' -Status 'Not available' -Summary 'The AMRL validation engine runs during deployment, not what-if.'
        Set-AMRLReportPhase -Name 'VM setup checks' -Status 'Not available' -Summary 'No VM setup checks were collected.'
        Write-Host 'Template preflight completed. No deployment was started; AMRL validation findings and guest readiness remain unverified.'
    }
    finally {
        if (Test-Path -LiteralPath $temporaryParameterFile) { Remove-Item -LiteralPath $temporaryParameterFile -Force }
        if (Test-Path -LiteralPath $temporaryBicepFile) { Remove-Item -LiteralPath $temporaryBicepFile -Force }
    }
}

# Submit the subscription deployment asynchronously, poll its ARM state, and retain operation
# snapshots for readable progress and failure reporting. A terminal ARM state is not guest readiness.
function Invoke-AMRLDeploymentWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$DeploymentName,
        [Parameter(Mandatory = $true)][string]$DeploymentLocation,
        [Parameter(Mandatory = $true)][string]$TemplateFile,
        [Parameter(Mandatory = $true)][string]$ParameterFile,
        [ValidateRange(1, 60)][int]$PollIntervalSeconds = 5
    )

    [void](Invoke-AzCli -Arguments @(
        'deployment', 'sub', 'create', '--no-wait', '--name', $DeploymentName,
        '--location', $DeploymentLocation, '--template-file', $TemplateFile,
        '--parameters', $ParameterFile, '--output', 'none'
    ))
    Write-Host "Deployment submitted. Following Azure stage and resource operations every $PollIntervalSeconds seconds..."

    $reportedOperations = New-Object 'System.Collections.Generic.HashSet[string]'
    $operationSnapshots = @{}
    if ($null -ne $script:BootstrapperReport) {
        $script:BootstrapperReport.OperationSnapshots = $operationSnapshots
        $script:BootstrapperReport.OperationSnapshotDeploymentName = $DeploymentName
    }
    $lastDeploymentState = ''
    $consecutiveReadFailures = 0
    while ($true) {
        try {
            $deployment = Get-AzJson -Arguments @('deployment', 'sub', 'show', '--name', $DeploymentName)
            $consecutiveReadFailures = 0
        }
        catch {
            $consecutiveReadFailures++
            if ($consecutiveReadFailures -ge 5) { throw }
            Write-Verbose "Waiting for deployment '$DeploymentName' to become visible: $($_.Exception.Message)"
            Start-Sleep -Seconds $PollIntervalSeconds
            continue
        }

        $state = [string]$deployment.properties.provisioningState
        if (-not [string]::IsNullOrWhiteSpace($state) -and $state -ne $lastDeploymentState) {
            Write-Host "Azure deployment status: $state"
            $lastDeploymentState = $state
        }

        if ($state -in @('Succeeded', 'Failed', 'Canceled', 'Cancelled')) {
            if ($state -ne 'Succeeded') {
                $errorProperty = $deployment.properties.PSObject.Properties['error']
                $errorJson = if ($null -eq $errorProperty -or $null -eq $errorProperty.Value) { '' } else { $errorProperty.Value | ConvertTo-Json -Depth 40 -Compress }
                if ([string]::IsNullOrWhiteSpace($errorJson)) { throw "Azure deployment finished with state '$state'." }
                throw "ERROR: $errorJson"
            }
            return $deployment
        }

        $pendingDeployments = New-Object 'System.Collections.Generic.Queue[object]'
        $visitedDeployments = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $pendingDeployments.Enqueue([pscustomobject]@{
            Id = $DeploymentName
            Arguments = @('deployment', 'operation', 'sub', 'list', '--name', $DeploymentName, '--query', '[].{properties:properties}')
            Stage = 'Deployment'
            Depth = 0
            State = $state
        })
        while ($pendingDeployments.Count -gt 0) {
            $currentDeployment = $pendingDeployments.Dequeue()
            if (-not $visitedDeployments.Add($currentDeployment.Id)) { continue }
            try {
                $cached = $operationSnapshots[$currentDeployment.Id]
                if ($null -ne $cached -and $cached.State -eq 'Succeeded') {
                    $operations = $cached.Operations
                }
                else {
                    $operationList = Get-AzJson -Arguments $currentDeployment.Arguments
                    $operations = @($operationList)
                    $operationSnapshots[$currentDeployment.Id] = [pscustomobject]@{
                        State = $currentDeployment.State
                        Operations = $operations
                        Stage = $currentDeployment.Stage
                        Depth = $currentDeployment.Depth
                    }
                }
            }
            catch {
                Write-Verbose "Could not read the current operation list for '$($currentDeployment.Id)': $($_.Exception.Message)"
                continue
            }
            foreach ($operation in $operations) {
                $propertiesProperty = $operation.PSObject.Properties['properties']
                if ($null -eq $propertiesProperty -or $null -eq $propertiesProperty.Value) { continue }
                $properties = $propertiesProperty.Value
                $operationType = [string]$properties.provisioningOperation
                if ([string]::IsNullOrWhiteSpace($operationType) -or $operationType -in @('Read', 'ReadData')) { continue }
                $targetProperty = $properties.PSObject.Properties['targetResource']
                if ($null -eq $targetProperty -or $null -eq $targetProperty.Value) { continue }
                $resourceId = [string]$targetProperty.Value.id
                if ([string]::IsNullOrWhiteSpace($resourceId)) { continue }
                $operationState = [string]$properties.provisioningState
                if ([string]::IsNullOrWhiteSpace($operationState)) { $operationState = 'In progress' }
                $stage = if ($resourceId -match '(?i)-network-stage-') { 'Network stage' }
                    elseif ($resourceId -match '(?i)-compute-stage-') { 'Compute stage' }
                    elseif ($resourceId -match '(?i)-identity-stage-') { 'Identity stage' }
                    elseif ($resourceId -match '(?i)-validation-(engine|gate)-') { 'AMRL validation' }
                    else { $currentDeployment.Stage }
                if ($resourceId -match '(?i)^/subscriptions/(?<Subscription>[^/]+)(?:/resourceGroups/(?<ResourceGroup>[^/]+))?/providers/Microsoft.Resources/deployments/(?<Deployment>[^/]+)$') {
                    $childArguments = if ([string]::IsNullOrWhiteSpace($Matches['ResourceGroup'])) {
                        @('deployment', 'operation', 'sub', 'list')
                    }
                    else {
                        @('deployment', 'operation', 'group', 'list', '--resource-group', $Matches.ResourceGroup)
                    }
                    $childArguments += @('--subscription', $Matches.Subscription, '--name', $Matches.Deployment, '--query', '[].{properties:properties}')
                    $pendingDeployments.Enqueue([pscustomobject]@{
                        Id = $resourceId
                        Arguments = $childArguments
                        Stage = $stage
                        Depth = $currentDeployment.Depth + 1
                        State = $operationState
                    })
                }

                $signature = "$stage|$resourceId|$operationType|$operationState"
                if (-not $reportedOperations.Add($signature)) { continue }
                $resourceName = Get-AMRLResourceDisplayName -ResourceId $resourceId
                $indent = '  ' * ($currentDeployment.Depth + 1)
                Write-Host ("{0}[{1}] {2}: {3} {4}" -f $indent, $stage, $resourceName, $operationType, $operationState)
            }
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

# 8. Main workflow: subscription-level prerequisites, then Bicep setup/deployment
# The entry point validates the selected mode before initializing a report, then sequences
# parameter loading, Azure setup, preflight, optional deployment, and read-only result collection.
function Invoke-AMRLSubscriptionSetup {
    param(
        [switch]$Plan,
        [switch]$Prepare,
        [switch]$Deploy
    )
    $script:PlanMode = [bool]$Plan
    Initialize-AMRLRunPhase -Name 'Azure readiness and foundation'
    if ($Plan -and $Deploy) {
        throw 'Use -Plan without -Deploy. Plan mode is read-only and cannot deploy resources.'
    }
    if (($Plan -and $Prepare) -or ($Prepare -and $Deploy)) {
        throw 'Specify only one run mode: -Plan, -Prepare, or -Deploy.'
    }
    $FoundationResourceGroup = 'amrl-foundation-rg'
    $FoundationLocation = $null
    $DeploymentLocation = ''
    $KeyVaultName = $null
    $AutomationIdentityName = Get-AMRLDefault 'automationManagedIdentityName'
    $PublicIp = $null
    $githubRepositoryReady = $true

    # 8.1 Verify tools/authentication, load inputs, and resolve the selected Azure context.
    Assert-AMRLPrerequisites
    Initialize-AMRLRunPhase -Name 'Parameter configuration'
    $parameterDocument = Get-ParameterDocument -Path $script:ParameterFilePath -IncludeGitHub:$IncludeGitHub
    if (-not $script:InteractiveConfiguration) { Assert-AMRLParameterDocumentComplete -Parameters $parameterDocument }
    Write-Host "Using AMRL default jumpbox administrator username: $(Get-AMRLDefault 'jumpboxAdminUsername')"
    Write-Host "Using AMRL default lab administrator username: $(Get-AMRLDefault 'labAdminUsername')"
    if ($null -ne $script:BootstrapperReport) { $script:BootstrapperReport.Parameters = $parameterDocument }
    $parameterSourceSummary = if ($script:InteractiveConfiguration) { 'Interactive wizard; local values or demo defaults were used.' } else { "Explicit parameter file: $script:ParameterFilePath" }
    Set-AMRLReportSource -Name 'Parameter input' -Status 'Loaded' -Summary $parameterSourceSummary
    Complete-AMRLRunPhase -Name 'Parameter configuration' -Summary 'Parameter file loaded; interactive choices and retries recorded.'
    $bootstrap = $parameterDocument.parameters.prefix.metadata.bootstrap
    if ($script:InteractiveConfiguration) {
        $context = Get-AMRLAzureContext
        $bootstrap.azureTenantId = [string]$context.tenantId
        $bootstrap.azureSubscriptionId = [string]$context.id
        if (-not $PlanMode) {
            [System.IO.File]::WriteAllText($script:ParameterFilePath, (ConvertTo-AMRLParameterJson -InputObject $parameterDocument), [System.Text.UTF8Encoding]::new($false))
        }
    }
    else {
        $subscriptionIdProperty = $bootstrap.PSObject.Properties['azureSubscriptionId']
        $tenantIdProperty = $bootstrap.PSObject.Properties['azureTenantId']
        $context = Get-AMRLAzureContext `
            -ExpectedSubscriptionId $(if ($null -eq $subscriptionIdProperty) { '' } else { [string]$subscriptionIdProperty.Value }) `
            -ExpectedTenantId $(if ($null -eq $tenantIdProperty) { '' } else { [string]$tenantIdProperty.Value }) `
            -RequireParameterFileContext
    }
    $foundationResourceGroupParameter = $parameterDocument.parameters.PSObject.Properties['foundationResourceGroup']

    $FoundationResourceGroup = if ($null -eq $foundationResourceGroupParameter) { '' } else { [string]$foundationResourceGroupParameter.Value.value }

    if ([string]::IsNullOrWhiteSpace($FoundationResourceGroup)) {
        throw 'Set top-level foundationResourceGroup in the parameter file.'
    }

    # 8.2 Collect Bicep choices and resolve prerequisite IDs before Azure resource writes.
    Initialize-AMRLRunPhase -Name 'Azure readiness and foundation'
    $FoundationLocation = Get-AMRLFoundationLocation -Parameters $parameterDocument
    $DeploymentLocation = $FoundationLocation
    Write-Host "Using first regionIndexMap entry by index for foundation resources and subscription deployment: $FoundationLocation"
    if ($null -ne $script:BootstrapperReport) { $script:BootstrapperReport.FoundationLocation = $FoundationLocation }
    if ($IncludeGitHub) {
        try {
            Assert-AMRLGitHubRepositoryAccess -Repository $parameterDocument.parameters.prefix.metadata.bootstrap.githubRepository
            Set-AMRLReportSource -Name 'GitHub repository access' -Status 'Ready' -Summary 'Repository write access and Actions metadata access were verified.'
        }
        catch {
            $githubRepositoryReady = $false
            $message = "GitHub repository access check failed: $($_.Exception.Message)"
            Add-AMRLReportIssue -Phase 'GitHub OIDC setup' -Severity Warning -Message $message
            Set-AMRLReportSource -Name 'GitHub repository access' -Status 'Failed' -Summary $message
            Write-Warning 'GitHub repository access failed; continuing with independent Azure setup.'
        }
    }
    $foundation = Get-AMRLFoundationConfiguration -Parameters $parameterDocument -SubscriptionId $context.id -AllowMissingFoundation
    if ($null -ne $script:BootstrapperReport) { $script:BootstrapperReport.FoundationConfiguration = $foundation }
    $FoundationResourceGroup = $foundation.ResourceGroup
    $AutomationIdentityName = $foundation.IdentityName
    $KeyVaultName = $foundation.VaultName

    # Existing resource groups keep their location; new resources use the first mapped region.
    if (-not $script:InteractiveConfiguration -and -not $Plan -and
        $foundation.RebuildFoundation -and -not [string]::IsNullOrWhiteSpace($foundation.VaultId)) {
        $deletedVault = Get-AzJson -Arguments @('keyvault', 'list-deleted', '--resource-type', 'vault', '--subscription', $context.id, '--query', "[?name=='$($foundation.VaultName)'] | [0]")
        if ($null -ne $deletedVault) {
            if ($deletedVault.properties.vaultId -ine $foundation.VaultId) {
                throw "The soft-deleted vault '$($foundation.VaultName)' does not match the saved parameter-file vault ID. No vault was recovered or replaced."
            }
            $foundation.RecoveryConfirmed = $true
            Set-AMRLReportSource -Name 'Key Vault recovery' -Status 'Matched parameter file' -Summary "Recovering soft-deleted vault '$($foundation.VaultName)' using its exact saved resource ID and original location."
        }
    }
    if ($script:InteractiveConfiguration) {
        $configuredFoundationGroup = $FoundationResourceGroup
        $FoundationResourceGroup = Read-AMRLFoundationResourceGroupName -DefaultName $configuredFoundationGroup
        if ($FoundationResourceGroup -ne $configuredFoundationGroup) {
            Set-AMRLFoundationResourceGroup -Parameters $parameterDocument -Foundation $foundation -ResourceGroupName $FoundationResourceGroup -SubscriptionId $context.id
        }

        if ($FoundationResourceGroup -eq $configuredFoundationGroup -and $foundation.RebuildFoundation -and -not $Plan -and -not [string]::IsNullOrWhiteSpace($foundation.VaultId)) {
            $deletedVault = Get-AzJson -Arguments @('keyvault', 'list-deleted', '--resource-type', 'vault', '--subscription', $context.id, '--query', "[?name=='$($foundation.VaultName)'] | [0]")
            if ($null -ne $deletedVault) {
                if ($deletedVault.properties.vaultId -ine $foundation.VaultId) {
                    throw "The soft-deleted vault '$($foundation.VaultName)' does not match the saved foundation vault ID. No vault was recovered or replaced."
                }
                $recoveryAnswer = Read-Host "Recover soft-deleted Key Vault '$($foundation.VaultName)' and preserve its secrets? [y/N]"
                if ($recoveryAnswer -match '^(y|yes)$') {
                    $foundation.RecoveryConfirmed = $true
                }
                else {
                    $newGroupDefault = "$FoundationResourceGroup-recreated"
                    if ($newGroupDefault.Length -gt 90) { $newGroupDefault = $newGroupDefault.Substring(0, 90).TrimEnd('.', '-', '_', '(', ')') }
                    $FoundationResourceGroup = Read-AMRLFoundationResourceGroupName -DefaultName $newGroupDefault -NameThatMustDiffer $FoundationResourceGroup
                    Set-AMRLFoundationResourceGroup -Parameters $parameterDocument -Foundation $foundation -ResourceGroupName $FoundationResourceGroup -SubscriptionId $context.id
                }
            }
        }

        $FoundationResourceGroup = $foundation.ResourceGroup
        $AutomationIdentityName = $foundation.IdentityName
        $KeyVaultName = $foundation.VaultName
        if (-not $PlanMode) {
            [System.IO.File]::WriteAllText($script:ParameterFilePath, (ConvertTo-AMRLParameterJson -InputObject $parameterDocument), [System.Text.UTF8Encoding]::new($false))
        }
        if ($null -ne $script:BootstrapperReport) { $script:BootstrapperReport.FoundationConfiguration = $foundation }
    }
    $existingIdentity = $null
    if ([string]::IsNullOrWhiteSpace($foundation.IdentityId) -and
        (Get-AzTsv -Arguments @('group', 'exists', '--name', $foundation.IdentityResourceGroup)) -eq 'true') {
        $existingIdentity = Get-AzJson -Arguments @('identity', 'list', '--resource-group', $foundation.IdentityResourceGroup, '--query', "[?name=='$AutomationIdentityName'] | [0]")
    }
    $existingVaults = @()
    if ([string]::IsNullOrWhiteSpace($foundation.VaultId) -and
        (Get-AzTsv -Arguments @('group', 'exists', '--name', $foundation.VaultResourceGroup)) -eq 'true') {
        $existingVaults = @(Get-AzJson -Arguments @('keyvault', 'list', '--resource-group', $foundation.VaultResourceGroup))
    }
    $needsIdentity = $foundation.RebuildFoundation -or ([string]::IsNullOrWhiteSpace($foundation.IdentityId) -and $null -eq $existingIdentity)
    $needsVault = $foundation.RebuildFoundation -or ([string]::IsNullOrWhiteSpace($foundation.VaultId) -and $existingVaults.Count -eq 0)
    Initialize-AMRLRunPhase -Name 'Azure readiness and foundation'
    $needsPublicIp = @($parameterDocument.parameters.jumpboxAllowedSources.value | Where-Object { [string]$_ -match '[<>]' }).Count -gt 0
    if (-not $script:InteractiveConfiguration) {
        if ($needsPublicIp) {
            throw 'The explicit parameter file contains an unresolved jumpbox IP placeholder. Replace it with an approved CIDR before running with -ParameterFile.'
        }
        if ($IncludeGitHub) {
            $PublicIp = Get-AMRLParameterFilePublicIp -Parameters $parameterDocument
        }
    }
    if ($script:InteractiveConfiguration -and ($needsPublicIp -or $IncludeGitHub) -and [string]::IsNullOrWhiteSpace($PublicIp)) {
        try {
            $discoveredIp = ([string](Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10)).Trim()
        }
        catch {
            $discoveredIp = ''
        }
        if (-not [string]::IsNullOrWhiteSpace($discoveredIp)) {
            Write-Host "Detected public IPv4: $discoveredIp"
            $useDetectedIp = Read-RequiredValue -Prompt 'Use this address for jumpbox access?' -Hint 'y/n' -DefaultValue 'yes' -Validator {
                param($Value) $Value -in @('yes', 'no', 'y', 'n')
            }
            if ($useDetectedIp -in @('yes', 'y')) { $PublicIp = $discoveredIp }
        }
        if ([string]::IsNullOrWhiteSpace($PublicIp)) {
            $PublicIp = Read-RequiredValue -Prompt 'Approved public IPv4 address' -Hint 'IPv4 address without CIDR suffix' -Validator {
                param($Value)
                $address = $null
                [System.Net.IPAddress]::TryParse([string]$Value, [ref]$address) -and $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
            }
        }
    }
    if ($null -ne $script:BootstrapperReport) { $script:BootstrapperReport.PublicIp = [string]$PublicIp }

    $parsedIp = $null
    if (-not [string]::IsNullOrWhiteSpace($PublicIp) -and
        (-not [System.Net.IPAddress]::TryParse($PublicIp, [ref]$parsedIp) -or $parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork)) {
        throw 'PublicIp must be a valid IPv4 address without a CIDR suffix.'
    }
    Write-Host 'Checking Azure foundation readiness and permissions...'

    # 8.3 Plan exits here, before subscription-level resource/credential preparation.
    if ($Plan) {
        Complete-AMRLRunPhase -Name 'Azure readiness and foundation' -Summary 'Read-only readiness checks completed; no resources were changed.'
        Invoke-AMRLPlan `
            -Context $context `
            -Parameters $parameterDocument `
            -ResourceGroup $FoundationResourceGroup `
            -FoundationLocation $FoundationLocation `
            -IdentityName $AutomationIdentityName `
            -IdentityResourceGroup $foundation.IdentityResourceGroup `
            -VaultResourceGroup $foundation.VaultResourceGroup `
            -DeploymentLocation $DeploymentLocation `
            -VaultName $KeyVaultName `
            -PublicIp $PublicIp `
            -Repository $parameterDocument.parameters.prefix.metadata.bootstrap.githubRepository `
            -AppDisplayName (Get-AMRLDefault 'githubAppDisplayName') `
            -IncludeGitHub:$IncludeGitHub
        return
    }

    # 8.4 Subscription-level setup: providers, groups, identity/RBAC, vault, and credentials.
    $foundationErrors = New-Object 'System.Collections.Generic.List[string]'
    Write-Host 'Azure foundation setup: checking resource providers and preparing the resource group, identity, and Key Vault.'
    foreach ($namespace in @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.ManagedIdentity', 'Microsoft.Storage', 'Microsoft.ContainerInstance')) {
        try {
            $state = Get-AzTsv -Arguments @('provider', 'show', '--namespace', $namespace, '--query', 'registrationState')
            if ($state -ne 'Registered') {
                $registration = Invoke-AMRLChange -Target "Provider $namespace" -Action 'Register resource provider' -Operation {
                    Invoke-AzCli -Arguments @('provider', 'register', '--namespace', $namespace, '--wait', '--output', 'none')
                }
                if ($null -ne $registration) {
                    $state = Get-AzTsv -Arguments @('provider', 'show', '--namespace', $namespace, '--query', 'registrationState')
                    if ($state -ne 'Registered') {
                        throw "Provider $namespace did not reach Registered state; current state is '$state'."
                    }
                }
            }
            Set-AMRLReportSource -Name "Resource provider: $namespace" -Status 'Ready' -Summary 'Provider is registered.'
        }
        catch {
            $message = "Provider $namespace setup failed: $($_.Exception.Message)"
            $foundationErrors.Add($message)
            Add-AMRLReportIssue -Phase 'Azure readiness and foundation' -Message $message
            Set-AMRLReportSource -Name "Resource provider: $namespace" -Status 'Failed' -Summary $message
            Write-Warning "Provider $namespace failed; checking the remaining independent prerequisites."
        }
    }
    try {
        $groupExists = Get-AzTsv -Arguments @('group', 'exists', '--name', $FoundationResourceGroup)
        if ($groupExists -eq 'true') {
            $group = Get-AzJson -Arguments @('group', 'show', '--name', $FoundationResourceGroup)
            if ($group.location -ne $FoundationLocation) {
                if ($needsIdentity -or $needsVault) {
                    Write-Host "Reusing foundation resource group in $($group.location); new resources will use the selected location $FoundationLocation."
                }
                else {
                    Write-Host "Reusing foundation resource group in $($group.location); existing resources will not be moved."
                }
            }
        }
        else {
            $group = Invoke-AMRLChange -Target "Resource group $FoundationResourceGroup" -Action "Create in $FoundationLocation" -Operation {
                Get-AzJson -Arguments @('group', 'create', '--name', $FoundationResourceGroup, '--location', $FoundationLocation)
            }
            if ($null -eq $group) { throw 'Resource group creation returned no result.' }
        }
        Set-AMRLReportSource -Name "Resource group: $FoundationResourceGroup" -Status 'Ready' -Summary 'Foundation resource group is available.'
    }
    catch {
        $message = "Foundation resource group '$FoundationResourceGroup' setup failed: $($_.Exception.Message)"
        $foundationErrors.Add($message)
        Add-AMRLReportIssue -Phase 'Azure readiness and foundation' -Message $message
        Set-AMRLReportSource -Name "Resource group: $FoundationResourceGroup" -Status 'Failed' -Summary $message
        Write-Warning 'Foundation resource-group setup failed; attempting independent identity and vault checks where possible.'
    }

    $identity = $null
    try {
        Write-Host "Checking managed identity (AMRL default): $AutomationIdentityName"
        $identity = Get-AzJson -Arguments @('identity', 'list', '--resource-group', $foundation.IdentityResourceGroup, '--query', "[?name=='$AutomationIdentityName'] | [0]")
        if ($null -eq $identity) {
            if (-not [string]::IsNullOrWhiteSpace($foundation.IdentityId) -and -not $foundation.RebuildFoundation) { throw 'The referenced managed identity disappeared during setup. No replacement was created.' }
            try {
                Write-Host "Creating missing managed identity: $AutomationIdentityName"
                $identity = Invoke-AMRLChange -Target "Managed identity $AutomationIdentityName" -Action 'Create user-assigned managed identity' -Operation {
                    Get-AzJson -Arguments @('identity', 'create', '--name', $AutomationIdentityName, '--resource-group', $foundation.IdentityResourceGroup, '--location', $FoundationLocation)
                }
            }
            catch {
                if ($_.Exception.Message -match 'RequestDisallowedByAzure|locationineligible|not accepting new customers') {
                    throw "Azure rejected managed identity creation in foundation resource location '$FoundationLocation', derived from regionIndexMap. Verify subscription eligibility for that region. Use manual preparation if prerequisite resources need a different location; retain existing lab region indexes. Details: $($_.Exception.Message)"
                }
                throw
            }
            if ($null -eq $identity) { throw 'Managed identity creation returned no result.' }
            Write-Host "Managed identity created: $AutomationIdentityName"
        }
        else { Write-Host "Managed identity exists; keeping it unchanged: $AutomationIdentityName" }
        Set-AMRLReportSource -Name 'Managed identity' -Status 'Ready' -Summary "Identity '$AutomationIdentityName' is available in '$($foundation.IdentityResourceGroup)'."
    }
    catch {
        $message = "Managed identity setup failed: $($_.Exception.Message)"
        $foundationErrors.Add($message)
        Add-AMRLReportIssue -Phase 'Azure readiness and foundation' -Message $message
        Set-AMRLReportSource -Name 'Managed identity' -Status 'Failed' -Summary $message
        Write-Warning 'Managed identity setup failed; continuing with independent Key Vault checks.'
        $identity = $null
    }
    if ($null -ne $identity) {
        Write-Host "Azure foundation setup: checking/configuring permissions for managed identity '$AutomationIdentityName'."
        try {
            Set-AMRLRoleAssignmentIfMissing -AssigneeObjectId $identity.principalId -PrincipalType ServicePrincipal -Role 'Network Contributor' -Scope "/subscriptions/$($context.id)"
            Set-AMRLReportSource -Name 'Automation identity RBAC' -Status 'Ready' -Summary 'Network Contributor assignment was confirmed.'
        }
        catch {
            $message = "Automation identity RBAC setup failed: $($_.Exception.Message)"
            $foundationErrors.Add($message)
            Add-AMRLReportIssue -Phase 'Azure readiness and foundation' -Message $message
            Set-AMRLReportSource -Name 'Automation identity RBAC' -Status 'Failed' -Summary $message
            Write-Warning 'Automation identity RBAC setup failed; continuing with independent Key Vault checks.'
        }
    }
    else {
        Set-AMRLReportSource -Name 'Automation identity RBAC' -Status 'Skipped' -Summary 'Managed identity is unavailable.'
    }

    $vault = $null
    $vaultId = ''
    try {
        if ([string]::IsNullOrWhiteSpace($KeyVaultName)) {
            $knownVaults = @(Get-AzJson -Arguments @('keyvault', 'list', '--resource-group', $foundation.VaultResourceGroup))
            if ($knownVaults.Count -eq 1) {
                $KeyVaultName = [string]$knownVaults[0].name
                Write-Host "Reusing the Key Vault in the foundation group: $KeyVaultName"
            }
            elseif ($knownVaults.Count -gt 1) {
                $choices = @($knownVaults | ForEach-Object { [string]$_.name })
                Write-Host "Key Vaults in the foundation group: $($choices -join ', ')"
                $KeyVaultName = Read-RequiredValue -Prompt 'Choose an existing Key Vault name' -Hint ($choices -join ', ') -Validator {
                    param($Value) $Value -in $choices
                }
            }
            else {
                $KeyVaultName = Get-AMRLAvailableVaultName -SubscriptionId $context.id
                Write-Host "Using subscription-derived Key Vault name: $KeyVaultName"
            }
        }

        $foundation.VaultName = $KeyVaultName
        $vault = Get-AzJson -Arguments @('keyvault', 'list', '--resource-group', $foundation.VaultResourceGroup, '--query', "[?name=='$KeyVaultName'] | [0]")
        if ($null -eq $vault -and $foundation.RebuildFoundation -and -not [string]::IsNullOrWhiteSpace($foundation.VaultId)) {
            $vault = Restore-AMRLFoundationVault -VaultName $KeyVaultName -ResourceGroup $foundation.VaultResourceGroup -SubscriptionId $context.id -ExpectedVaultId $foundation.VaultId -RecoveryConfirmed:$foundation.RecoveryConfirmed
        }
        if ($null -eq $vault) {
            if (-not [string]::IsNullOrWhiteSpace($foundation.VaultId) -and -not $foundation.RebuildFoundation) { throw 'The referenced Key Vault disappeared during setup. No replacement was created.' }
            if ((Read-Host "Create Key Vault '$KeyVaultName' with irreversible purge protection? [y/N]") -notmatch '^(y|yes)$') {
                throw 'Key Vault creation was not confirmed.'
            }
            try {
                $vault = Invoke-AMRLChange -Target "Key Vault $KeyVaultName" -Action 'Create RBAC-enabled vault with purge protection' -Operation {
                    Get-AzJson -Arguments @(
                        'keyvault', 'create', '--name', $KeyVaultName,
                        '--resource-group', $foundation.VaultResourceGroup, '--location', $FoundationLocation,
                        '--enable-rbac-authorization', 'true', '--enabled-for-template-deployment', 'true',
                        '--enable-purge-protection', 'true'
                    )
                }
            }
            catch {
                if ($_.Exception.Message -match 'RequestDisallowedByAzure|locationineligible|not accepting new customers') {
                    throw "Azure rejected Key Vault creation in foundation resource location '$FoundationLocation', derived from regionIndexMap. Verify subscription eligibility for that region. Use manual preparation if prerequisite resources need a different location; retain existing lab region indexes. Details: $($_.Exception.Message)"
                }
                throw
            }
            if ($null -eq $vault) { throw 'Key Vault creation returned no result.' }
        }
        else {
            $vault = Get-AzJson -Arguments @('keyvault', 'show', '--name', $KeyVaultName, '--resource-group', $foundation.VaultResourceGroup)
            if (-not $vault.properties.enableRbacAuthorization -or
                -not $vault.properties.enabledForTemplateDeployment -or
                -not $vault.properties.enablePurgeProtection) {
                throw 'The existing Key Vault does not meet the required RBAC, template-deployment, and purge-protection settings. Review it manually; the script will not weaken or modify its protections.'
            }
        }
        $vaultId = [string]$vault.id
        Set-AMRLReportSource -Name 'Key Vault' -Status 'Ready' -Summary "Vault '$KeyVaultName' is available in '$($foundation.VaultResourceGroup)'."
    }
    catch {
        $message = "Key Vault setup failed: $($_.Exception.Message)"
        $foundationErrors.Add($message)
        Add-AMRLReportIssue -Phase 'Azure readiness and foundation' -Message $message
        Set-AMRLReportSource -Name 'Key Vault' -Status 'Failed' -Summary $message
        Write-Warning 'Key Vault setup failed; continuing with independent foundation checks.'
        $vault = $null
        $vaultId = ''
    }

    if ($null -ne $vault) {
        Write-Host 'Azure foundation setup: checking Key Vault permissions and preparing required secrets.'
        $keyVaultAccessReady = $false
        try {
            $userId = Get-AzTsv -Arguments @('ad', 'signed-in-user', 'show', '--query', 'id')
            if ([string]::IsNullOrWhiteSpace($userId)) { throw 'Could not resolve the signed-in Entra user.' }
            Set-AMRLRoleAssignmentIfMissing -AssigneeObjectId $userId -PrincipalType User -Role 'Key Vault Secrets Officer' -Scope $vaultId
            [void](Get-AzTsv -Arguments @('keyvault', 'secret', 'list', '--vault-name', $KeyVaultName, '--query', '[].name'))
            $keyVaultAccessReady = $true
            Set-AMRLReportSource -Name 'Key Vault access' -Status 'Ready' -Summary 'Signed-in user has Key Vault Secrets Officer access; secret-list access was verified.'
        }
        catch {
            $message = "Key Vault secret access is not ready: $($_.Exception.Message)"
            $foundationErrors.Add($message)
            Add-AMRLReportIssue -Phase 'Azure readiness and foundation' -Message $message
            Set-AMRLReportSource -Name 'Key Vault access' -Status 'Failed' -Summary 'Secret data-plane access was not verified; see Warnings and errors.'
            Write-Warning 'Key Vault secret access was not verified; skipping secret setup.'
        }

        $secretSetupFailed = $false
        if ($keyVaultAccessReady) {
            foreach ($secretName in (Get-AMRLPasswordSecretNames)) {
                try {
                    Set-AMRLSecretIfMissing -VaultName $KeyVaultName -SecretName $secretName -Password -Prompt:$script:PromptForPasswords
                }
                catch {
                    $message = "Key Vault secret '$secretName' setup failed: $($_.Exception.Message)"
                    $foundationErrors.Add($message)
                    Add-AMRLReportIssue -Phase 'Azure readiness and foundation' -Message $message
                    $secretSetupFailed = $true
                }
            }
            try { Set-AMRLKeySecretsIfMissing -VaultName $KeyVaultName }
            catch {
                $message = "SSH key secrets setup failed: $($_.Exception.Message)"
                $foundationErrors.Add($message)
                Add-AMRLReportIssue -Phase 'Azure readiness and foundation' -Message $message
                $secretSetupFailed = $true
            }
        }
        $secretStatus = if (-not $keyVaultAccessReady) { 'Skipped' } elseif ($secretSetupFailed) { 'Issues found' } else { 'Ready' }
        $secretSummary = if (-not $keyVaultAccessReady) { 'Secret setup was skipped because Key Vault data access was not verified.' } elseif ($secretSetupFailed) { 'One or more required secrets could not be prepared.' } else { 'Password and SSH key secrets are ready.' }
        Set-AMRLReportSource -Name 'Key Vault secrets' -Status $secretStatus -Summary $secretSummary
    }
    else {
        Set-AMRLReportSource -Name 'Key Vault access' -Status 'Skipped' -Summary 'Key Vault is unavailable.'
        Set-AMRLReportSource -Name 'Key Vault secrets' -Status 'Skipped' -Summary 'Key Vault is unavailable.'
    }

    foreach ($lockGroup in (@($foundation.IdentityResourceGroup, $foundation.VaultResourceGroup) | Select-Object -Unique)) {
        Write-Host "Azure foundation setup: checking protection lock on '$lockGroup'."
        try {
            $lock = Get-AzJson -Arguments @('lock', 'list', '--resource-group', $lockGroup, '--query', "[?name=='protect-foundation'] | [0]")
            if ($null -ne $lock -and $lock.level -ne 'CanNotDelete') {
                throw "Lock 'protect-foundation' in '$lockGroup' exists with level '$($lock.level)' instead of CanNotDelete. Resolve it manually."
            }
            if ($null -eq $lock) {
                [void](Invoke-AMRLChange -Target "Resource group $lockGroup" -Action 'Apply CanNotDelete foundation lock' -Operation {
                    Invoke-AzCli -Arguments @('lock', 'create', '--name', 'protect-foundation', '--lock-type', 'CanNotDelete', '--resource-group', $lockGroup, '--output', 'none')
                })
            }
            Set-AMRLReportSource -Name "Foundation lock: $lockGroup" -Status 'Ready' -Summary 'CanNotDelete protection is present.'
        }
        catch {
            $message = "Foundation lock setup failed for '$lockGroup': $($_.Exception.Message)"
            $foundationErrors.Add($message)
            Add-AMRLReportIssue -Phase 'Azure readiness and foundation' -Message $message
            Set-AMRLReportSource -Name "Foundation lock: $lockGroup" -Status 'Failed' -Summary $message
        }
    }
    $script:FoundationSetupFailed = $foundationErrors.Count -gt 0
    if ($null -eq $identity -or $null -eq $vault) {
        Set-AMRLReportPhase -Name 'Azure readiness and foundation' -Status 'Failed' -Summary 'Identity or Key Vault is unavailable; parameterized Bicep checks depend on both.'
        $foundationFailure = if ($foundationErrors.Count -gt 0) { $foundationErrors[0] } else { 'Required foundation prerequisites are unavailable; Bicep parameter resolution was skipped.' }
        throw $foundationFailure
    }
    if ($script:FoundationSetupFailed) {
        Set-AMRLReportPhase -Name 'Azure readiness and foundation' -Status 'Issues found' -Summary "$($foundationErrors.Count) prerequisite issues recorded; read-only Bicep checks can continue, deployment will be skipped."
        Set-AMRLReportSource -Name 'Foundation prerequisites' -Status 'Issues found' -Summary "$($foundationErrors.Count) issue(s) found; see Warnings and errors."
    }
    else {
        Complete-AMRLRunPhase -Name 'Azure readiness and foundation' -Summary 'Foundation resources, credentials, RBAC, and locks are ready.'
        Set-AMRLReportSource -Name 'Foundation prerequisites' -Status 'Ready' -Summary 'Identity, Key Vault, credentials, RBAC, and locks are ready.'
    }
    # 8.5 Bicep setup: persist resolved references and optionally configure GitHub Actions.
    Initialize-AMRLRunPhase -Name 'Bicep build and validation'
    $updatedParameters = Set-AMRLParameterValues -Parameters $parameterDocument -FoundationResourceGroup $foundation.ResourceGroup -KeyVaultName $KeyVaultName -PublicIp $PublicIp
    if ($null -ne $script:BootstrapperReport) { $script:BootstrapperReport.Parameters = $updatedParameters }
    $json = ConvertTo-AMRLParameterJson -InputObject $updatedParameters
    [System.IO.File]::WriteAllText($script:ParameterFilePath, $json, [System.Text.UTF8Encoding]::new($false))

    $parameterFileForPreflight = $script:ParameterFilePath

    if ($IncludeGitHub -and $githubRepositoryReady) {
        try {
            $githubSetupResult = Set-AMRLGitHubConfiguration -TenantId $context.tenantId -SubscriptionId $context.id -VaultId $vaultId -VaultName $KeyVaultName -IdentityId $identity.id -Repository $updatedParameters.parameters.prefix.metadata.bootstrap.githubRepository -AppDisplayName (Get-AMRLDefault 'githubAppDisplayName') -PublicIp $PublicIp
            $createdCredentials = @($githubSetupResult.FederatedCredentials | Where-Object { $_.Status -eq 'Created' })
            $existingCredentials = @($githubSetupResult.FederatedCredentials | Where-Object { $_.Status -eq 'Already existed' })
            $credentialDetails = @($githubSetupResult.FederatedCredentials | ForEach-Object { "$($_.Status): $($_.Subject)" }) -join [Environment]::NewLine
            $githubSummary = "Repository secrets and variables verified; federated credentials: $($createdCredentials.Count) created, $($existingCredentials.Count) already existed."
            Set-AMRLReportSource -Name 'GitHub OIDC setup' -Status 'Succeeded' -Summary $githubSummary -Details $credentialDetails
        }
        catch {
            $message = $_.Exception.Message
            Set-AMRLReportSource -Name 'GitHub OIDC setup' -Status 'Failed' -Summary 'Optional GitHub integration failed; Bicep preparation can continue.' -Details $message
            Add-AMRLReportIssue -Phase 'GitHub OIDC setup' -Severity Warning -Message $message
            Write-Warning 'GitHub OIDC setup failed; continuing with independent Bicep preparation. Details will appear in the final report.'
        }
    }
    elseif ($IncludeGitHub) {
        Set-AMRLReportSource -Name 'GitHub OIDC setup' -Status 'Skipped' -Summary 'Repository access checks failed; GitHub configuration was skipped.'
    }
    $mainTemplate = Join-Path $script:RepositoryRoot 'main.bicep'
    # 8.6 Independent read-only checks are all attempted to collect complete evidence.
    Initialize-AMRLRunPhase -Name 'Bicep build and validation'
    if ($Deploy) {
        Write-Host 'Preflight checks validate the template and preview Azure changes before deployment.'
    }
    else {
        Write-Host 'Prepare and Plan check the template and preview Azure changes; AMRL validation engine findings are produced only during deployment.'
    }
    Write-Host 'Running template preflight: compilation and Azure validation...'
    $buildResult = Invoke-AMRLObservedCommand -Name 'Bicep build' -Arguments @('bicep', 'build', '--file', $mainTemplate)
    $lintResult = Invoke-AMRLObservedCommand -Name 'Bicep lint' -Arguments @('bicep', 'lint', '--file', $mainTemplate)
    $validateResult = Invoke-AMRLObservedCommand -Name 'Azure deployment validate' -Arguments @('deployment', 'sub', 'validate', '--location', $DeploymentLocation, '--template-file', $mainTemplate, '--parameters', $parameterFileForPreflight, '--output', 'json')
    $preflightFailed = -not ($buildResult.Succeeded -and $lintResult.Succeeded -and $validateResult.Succeeded)
    if ($preflightFailed) {
        Set-AMRLReportPhase -Name 'Bicep build and validation' -Status 'Failed' -Summary 'One or more build, lint, or Azure validation checks failed; independent checks were still attempted.'
    }
    else {
        Complete-AMRLRunPhase -Name 'Bicep build and validation' -Summary 'Bicep build, lint, and Azure deployment validate succeeded.'
    }

    $deploymentName = 'amrl-{0}-{1}' -f $updatedParameters.parameters.prefix.value, (Get-Date -Format 'yyyyMMdd-HHmmss')
    if ($Deploy) {
        $deploymentName = Read-RequiredValue -Prompt 'Azure deployment name' -Hint 'Start with a letter or number; no spaces' -DefaultValue $deploymentName -Validator {
            param($Value)
            $candidate = [string]$Value
            $candidate.Length -le 64 -and $candidate -match '^[A-Za-z0-9][A-Za-z0-9_.()-]{0,63}$' -and $candidate -notmatch '\.$'
        }
        Set-AMRLReportSource -Name 'Azure deployment name' -Status 'Selected' -Summary $deploymentName
    }

    Initialize-AMRLRunPhase -Name 'What-if preview'
    $whatIfResult = Invoke-AMRLObservedCommand -Name 'Azure deployment what-if' -Arguments @('deployment', 'sub', 'what-if', '--name', $deploymentName, '--location', $DeploymentLocation, '--template-file', $mainTemplate, '--parameters', $parameterFileForPreflight, '--no-pretty-print', '--output', 'json')
    if ($whatIfResult.Succeeded) {
        Complete-AMRLRunPhase -Name 'What-if preview' -Summary 'Azure returned a deployment change preview.'
    }
    else {
        Set-AMRLReportPhase -Name 'What-if preview' -Status 'Failed' -Summary 'What-if failed; deployment cannot safely continue.'
        $preflightFailed = $true
    }

    if ($preflightFailed) {
        Set-AMRLReportPhase -Name 'Deployment' -Status 'Skipped' -Summary 'Deployment skipped because preflight reported errors.'
        Set-AMRLReportPhase -Name 'AMRL validation engine outputs' -Status 'Skipped' -Summary 'No deployment ran, so AMRL validation engine outputs were not produced.'
        Set-AMRLReportPhase -Name 'VM setup checks' -Status 'Skipped' -Summary 'No deployment ran, so VM setup checks were not collected.'
        return
    }
    if ($script:FoundationSetupFailed) {
        Set-AMRLReportPhase -Name 'Deployment' -Status 'Skipped' -Summary 'Deployment skipped because one or more foundation prerequisites failed.'
        Set-AMRLReportPhase -Name 'AMRL validation engine outputs' -Status 'Not available' -Summary 'No deployment ran.'
        Set-AMRLReportPhase -Name 'VM setup checks' -Status 'Not available' -Summary 'No deployment ran.'
        return
    }
    if (-not $Deploy) {
        Set-AMRLReportPhase -Name 'Deployment' -Status 'Not requested' -Summary 'Prepare/preview mode completed without deployment.'
        Set-AMRLReportPhase -Name 'AMRL validation engine outputs' -Status 'Not run' -Summary 'AMRL validation engine outputs are produced by deployment, not what-if.'
        Set-AMRLReportPhase -Name 'VM setup checks' -Status 'Not run' -Summary 'No VM setup checks were collected because deployment was not requested.'
        Write-Host "Azure deployment what-if complete. No lab deployment was started. To deploy after reviewing the plan, rerun with -Deploy."
        Write-Host 'AMRL validation findings and guest readiness remain unverified.'
        return
    }
    # 8.7 Deployment is separate from preparation and requires the literal confirmation.
    if (-not (Confirm-AMRLDeployment -DeploymentName $deploymentName)) {
        Set-AMRLReportPhase -Name 'Deployment' -Status 'Cancelled' -Summary 'Deployment was not confirmed.'
        Set-AMRLReportPhase -Name 'AMRL validation engine outputs' -Status 'Not run' -Summary 'No deployment was started.'
        Set-AMRLReportPhase -Name 'VM setup checks' -Status 'Not run' -Summary 'No VM setup checks were collected.'
        Write-Host 'Deployment cancelled.'
        return
    }

    try {
        Initialize-AMRLRunPhase -Name 'Deployment'
        $script:DeploymentAttempted = $true
        Write-Host "Azure deployment: starting '$deploymentName'. The AMRL validation engine will evaluate the configuration and apply the selected enforcement mode. Findings and the gate result will appear in the final report when deployment outputs are available."
        [void](Invoke-AMRLChange -Target "Subscription deployment $deploymentName" -Action 'Create AMRL resources from main.bicep' -Operation {
            Invoke-AMRLDeploymentWithProgress -DeploymentName $deploymentName -DeploymentLocation $DeploymentLocation -TemplateFile $mainTemplate -ParameterFile $parameterFileForPreflight | Out-Null
        })
    }
    catch {
        # Best-effort diagnostics must not replace the original deployment failure.
        $deploymentError = $_
        Set-AMRLReportPhase -Name 'Deployment' -Status 'Failed' -Summary 'Deployment failed; collecting final diagnostics.'
        Write-Host 'Azure deployment failed. Collecting final diagnostics; results will appear in the report.'
        Write-Host '  Collecting AMRL validation outputs...'
        try {
            Show-AMRLValidationAfterFailure -Prefix ([string]$updatedParameters.parameters.prefix.value) -RootDeploymentName $deploymentName -Quiet
        }
        catch {
            Add-AMRLReportIssue -Phase 'AMRL validation engine outputs' -Severity Warning -Message "Could not collect validation diagnostics: $($_.Exception.Message)"
        }
        Write-Host '  Summarizing deployment resource operations from progress snapshots...'
        Set-AMRLDeploymentOperationReport -DeploymentName $deploymentName -ShowProgress -UseOperationSnapshots -DeploymentState 'Failed' -FailureMessage $deploymentError.Exception.Message
        if ($deploymentError.Exception.Message -match '(?i)DeploymentScriptACIProvisioningTimeout|AMRL-network-reconciliation') {
            Set-AMRLReportPhase -Name 'VM setup checks' -Status 'Skipped' -Summary 'Network reconciliation failed before compute and identity guest setup.'
            Set-AMRLReportSource -Name 'VM setup checks' -Status 'Skipped' -Summary 'Guest commands were not checked because network reconciliation failed before compute and identity stages.'
            Write-Host '  Skipping VM setup queries; the network-stage failure occurred before compute and identity guest commands.'
        }
        else {
            Write-Host '  Collecting VM setup status where placement outputs are available...'
            try {
                $failedDeployment = Get-AzJson -Arguments @('deployment', 'sub', 'show', '--name', $deploymentName)
                Show-AMRLGuestCommandResults -Prefix ([string]$updatedParameters.parameters.prefix.value) -Deployment $failedDeployment -Quiet -ShowProgress
            }
            catch {
                $message = "VM setup checks could not be collected after deployment failure: $($_.Exception.Message)"
                Add-AMRLReportIssue -Phase 'VM setup checks' -Severity Warning -Message $message
                Set-AMRLReportPhase -Name 'VM setup checks' -Status 'Unavailable' -Summary $message
                Set-AMRLReportSource -Name 'VM setup checks' -Status 'Unavailable' -Summary $message
                Write-Verbose 'VM setup checks could not be collected after the failed deployment; details will appear in the final report.'
            }
        }
        Set-AMRLReportPhase -Name 'Deployment' -Status 'Failed' -Summary 'Deployment failed; see Warnings and errors below.'
        Write-Host 'Diagnostic collection finished. Preparing the final report...'
        throw $deploymentError
    }
    Complete-AMRLRunPhase -Name 'Deployment' -Summary 'Subscription deployment completed.'
    Write-Host 'Collecting final deployment resource operations...'
    Set-AMRLDeploymentOperationReport -DeploymentName $deploymentName -ShowProgress

    # 8.8 Keep ARM completion, AMRL validation findings, and VM setup checks distinct.
    Initialize-AMRLRunPhase -Name 'AMRL validation engine outputs'
    $result = Get-AzJson -Arguments @('deployment', 'sub', 'show', '--name', $deploymentName)
    Write-Host 'Azure deployment: succeeded. Guest readiness is not implied by this status.'
    Write-AMRLValidationReport -Deployment $result -Quiet
    Initialize-AMRLRunPhase -Name 'VM setup checks'
    Write-Host 'Collecting VM setup status for the final report...'
    Show-AMRLGuestCommandResults -Prefix ([string]$updatedParameters.parameters.prefix.value) -Deployment $result -Quiet -ShowProgress
    Write-Host 'Control-plane completion is not proof of guest readiness; use the documented post-deployment checks.'
}

# Print the resolved operator-facing configuration, omitting secret values and verbose ARM identifiers.
function Write-AMRLConfigurationSummary {
    $document = $script:BootstrapperReport.Parameters
    if ($null -eq $document -or $null -eq $document.parameters) {
        Write-Host 'Configuration values: unavailable; parameter input was not loaded.'
        return
    }

    $parameters = $document.parameters
    $regionProperties = @($parameters.regionIndexMap.value.PSObject.Properties | Sort-Object { [int]$_.Value })
    $regionCount = [int]$parameters.regionCount.value
    $activeRegionCount = [Math]::Min([Math]::Max(0, $regionCount), $regionProperties.Count)
    $activeRegions = @($regionProperties | Select-Object -First $activeRegionCount | ForEach-Object { $_.Name })
    $vmCounts = $parameters.vmCounts.value
    $vmCountSummary = @(
        "DC $($vmCounts.dc)", "jumpbox $($vmCounts.jumpbox)",
        "Windows server $($vmCounts.windowsServer)", "Windows client $($vmCounts.windowsClient)",
        "Linux server $($vmCounts.linuxServer)", "Linux client $($vmCounts.linuxClient)"
    ) -join '; '
    $booleanSummary = @(
        'File services on (identity stage)',
        "Dedicated file server $(if ($parameters.useDedicatedFileServer.value) { 'on' } else { 'off' })",
        "Windows Admin Center $(if ($parameters.enableWindowsAdminCenter.value) { 'on' } else { 'off' })",
        "Dedicated WAC host $(if ($parameters.useDedicatedWacHost.value) { 'on' } else { 'off' })"
    ) -join '; '

    Write-Host 'Configuration used:'
    $context = $script:BootstrapperReport.Context
    if ($null -ne $context) {
        Write-Host "  Azure account: $($context.user.name)"
        Write-Host "  Tenant: $($context.tenantId)"
        Write-Host "  Subscription: $($context.name) ($($context.id))"
    }
    $foundation = $script:BootstrapperReport.FoundationConfiguration
    if ($null -ne $foundation) {
        Write-Host "  Foundation resource group: $($foundation.ResourceGroup)"
        Write-Host "  Managed identity: $($foundation.IdentityName)"
        if ($foundation.IdentityResourceGroup -ne $foundation.ResourceGroup) {
            Write-Host "  Managed identity resource group: $($foundation.IdentityResourceGroup)"
        }
        $vaultName = if ([string]::IsNullOrWhiteSpace($foundation.VaultName)) { 'Not resolved' } else { $foundation.VaultName }
        Write-Host "  Key Vault: $vaultName"
        if ($foundation.VaultResourceGroup -ne $foundation.ResourceGroup) {
            Write-Host "  Key Vault resource group: $($foundation.VaultResourceGroup)"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:BootstrapperReport.FoundationLocation)) {
        Write-Host "  Foundation location: $($script:BootstrapperReport.FoundationLocation)"
    }
    Write-Host "  Jumpbox allowed sources: $(@($parameters.jumpboxAllowedSources.value) -join ', ')"
    if ($IncludeGitHub) {
        Write-Host "  GitHub repository: $($parameters.prefix.metadata.bootstrap.githubRepository)"
        Write-Host "  GitHub Entra app (AMRL default): $(Get-AMRLDefault 'githubAppDisplayName')"
    }
    Write-Host "  Prefix: $($parameters.prefix.value)"
    Write-Host "  Stage: $($parameters.stage.value)"
    Write-Host "  Regions ($regionCount): $($activeRegions -join ', ')"
    Write-Host "  Network mode: $($parameters.networkMode.value)"
    Write-Host "  Validation mode: $($parameters.validationMode.value)"
    Write-Host "  Maximum VMs per region: $($parameters.maxVmsPerRegion.value)"
    Write-Host "  VM counts: $vmCountSummary"
    Write-Host "  Departments: $($parameters.departmentCount.value); users per department: $($parameters.usersPerDepartment.value)"
    Write-Host "  Features: $booleanSummary"
    Write-Host "  Missing administrator passwords: $(if ($script:PromptForPasswords) { 'prompt securely' } else { 'generate automatically' })"
}

# Render the accumulated phases, evidence, changes, and warnings once; callers control when this final
# summary is emitted so progress output does not duplicate detailed results.
function Write-AMRLBootstrapperReport {
    if ($null -eq $script:BootstrapperReport) { return }

    $script:BootstrapperReport.CompletedAt = Get-Date
    foreach ($phase in $script:BootstrapperReport.Phases) {
        if ($phase.Status -eq 'Running') {
            $phase.Status = 'Incomplete'
            if ([string]::IsNullOrWhiteSpace($phase.Summary)) { $phase.Summary = 'The phase did not report completion.' }
            Add-AMRLReportIssue -Phase $phase.Name -Message $phase.Summary
        }
    }
    $hasErrors = @($script:BootstrapperReport.Issues | Where-Object { $_.Severity -eq 'Error' }).Count -gt 0
    $hasWarnings = @($script:BootstrapperReport.Issues | Where-Object { $_.Severity -eq 'Warning' }).Count -gt 0
    $wasCancelled = @($script:BootstrapperReport.Phases | Where-Object { $_.Status -eq 'Cancelled' }).Count -gt 0
    $script:BootstrapperReport.Status = if ($hasErrors) { 'Failed' } elseif ($wasCancelled) { 'Cancelled' } elseif ($hasWarnings) { 'Completed with warnings' } else { 'Succeeded' }

    Write-Host ''
    Write-Host 'AMRL BOOTSTRAPPER REPORT'
    Write-Host '========================'
    Write-Host "Overall result: $($script:BootstrapperReport.Status)"
    Write-Host "Run mode: $($script:BootstrapperReport.Mode)"
    Write-Host "Started: $($script:BootstrapperReport.StartedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
    Write-Host "Finished: $($script:BootstrapperReport.CompletedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))"

    Write-Host ''
    Write-AMRLConfigurationSummary

    Write-Host ''
    Write-Host 'Checks:'
    foreach ($phase in $script:BootstrapperReport.Phases) {
        if ($phase.Status -eq 'Pending') {
            if ($phase.Name -eq 'Plan prerequisite checks' -and $script:BootstrapperReport.Mode -ne 'Plan') {
                $phase.Status = 'Not applicable'
                $phase.Summary = 'This run did not use plan mode.'
            }
            else {
                $phase.Status = 'Skipped'
                $failedPhase = @($script:BootstrapperReport.Phases | Where-Object { $_.Status -eq 'Failed' } | Select-Object -First 1)
                $phase.Summary = if ($failedPhase.Count -gt 0) { "Not run because '$($failedPhase[0].Name)' failed or its prerequisites were unavailable." } else { 'Not applicable or not requested in this run.' }
            }
        }

        $statusLabel = switch -Exact ([string]$phase.Status) {
            'Succeeded' { 'PASS' }
            'Failed' { 'FAIL' }
            'Issues found' { 'WARN' }
            'Completed with warnings' { 'WARN' }
            'Skipped' { 'SKIPPED' }
            'Not checked' { 'NOT CHECKED' }
            'Not available' { 'NOT AVAILABLE' }
            'Not run' { 'NOT RUN' }
            'Not requested' { 'NOT REQUESTED' }
            'Not applicable' { 'N/A' }
            'Cancelled' { 'CANCELLED' }
            'Partial' { 'PARTIAL' }
            default { ([string]$phase.Status).ToUpperInvariant() }
        }
        Write-Host "  [$statusLabel] $($phase.Name): $($phase.Summary)"
    }

    Write-Host ''
    Write-Host 'Azure foundation setup (before Bicep deployment):'
    Write-Host '  Completed changes:'
    if ($script:BootstrapperReport.FoundationChanges.Count -gt 0) {
        foreach ($change in $script:BootstrapperReport.FoundationChanges) {
            Write-Host "    $($change.Action): $($change.Target)"
        }
    }
    else { Write-Host '    No completed foundation changes were recorded.' }
    $foundationSources = @($script:BootstrapperReport.Sources.Keys | Where-Object {
        $_ -match '^(Resource provider:|Resource group:|Foundation lock:)' -or
        $_ -in @('Managed identity', 'Automation identity RBAC', 'Key Vault', 'Key Vault access', 'Key Vault secrets', 'Foundation prerequisites', 'Read-only prerequisite plan')
    })
    Write-Host '  Prerequisite checks:'
    if ($foundationSources.Count -gt 0) {
        foreach ($sourceName in $foundationSources) {
            $source = $script:BootstrapperReport.Sources[$sourceName]
            Write-Host "    [$($source.Status)] $($sourceName): $($source.Summary)"
            if (-not [string]::IsNullOrWhiteSpace($source.Details)) {
                foreach ($line in ($source.Details -split "`r?`n")) { Write-Host "      $line" }
            }
        }
    }
    else { Write-Host '    No foundation check results were recorded.' }

    $dedicatedSources = @('Azure deployment what-if', 'Applied resource changes', 'AMRL validation engine', 'VM setup checks') + $foundationSources
    $supportingSources = @($script:BootstrapperReport.Sources.Keys | Where-Object { $_ -notin $dedicatedSources })
    if ($supportingSources.Count -gt 0) {
        Write-Host ''
        Write-Host 'Supporting checks:'
        foreach ($sourceName in $supportingSources) {
            $source = $script:BootstrapperReport.Sources[$sourceName]
            Write-Host "  [$($source.Status)] $($sourceName): $($source.Summary)"
            if ($sourceName -eq 'GitHub OIDC setup' -and -not [string]::IsNullOrWhiteSpace($source.Details)) {
                foreach ($line in ($source.Details -split "`r?`n")) { Write-Host "    $line" }
            }
        }
    }

    Write-Host ''
    Write-Host 'Planned resource changes (what-if):'
    $plannedChanges = $script:BootstrapperReport.Sources['Azure deployment what-if']
    if ($null -eq $plannedChanges) {
        Write-Host '  No what-if preview was produced.'
    }
    else {
        Write-Host '  Comparison: current Azure resources against the template and current parameter values, not changes since the previous wizard run.'
        Write-Host "  [$($plannedChanges.Status)] $($plannedChanges.Summary)"
        if (-not [string]::IsNullOrWhiteSpace($plannedChanges.Details)) {
            foreach ($line in ($plannedChanges.Details -split "`r?`n")) { Write-Host "  $line" }
        }
    }

    Write-Host ''
    Write-Host 'Bicep deployment results:'
    $appliedChanges = $script:BootstrapperReport.Sources['Applied resource changes']
    if ($null -eq $appliedChanges) {
        if ($script:DeploymentAttempted) { Write-Host '  Deployment operations were not available.' }
        else { Write-Host '  No Bicep deployment was run; foundation setup is reported above.' }
    }
    else {
        Write-Host "  Overall: $($script:BootstrapperReport.DeploymentState)"
        Write-Host "  [$($appliedChanges.Status)] $($appliedChanges.Summary)"
        Write-Host '  Stage outcomes:'
        if ($script:BootstrapperReport.DeploymentStages.Count -gt 0) {
            foreach ($stage in @($script:BootstrapperReport.DeploymentStages | Group-Object Stage | Sort-Object Name)) {
                $statuses = @($stage.Group.Status | Sort-Object -Unique) -join ', '
                Write-Host "    $($stage.Name): $statuses"
            }
        }
        else { Write-Host '    Not available.' }
        Write-Host '  Resource operations (Azure provisioning, not guest execution):'
        foreach ($stage in @($script:BootstrapperReport.AppliedChanges | Group-Object Stage | Sort-Object Name)) {
            Write-Host "    $($stage.Name):"
            foreach ($group in @($stage.Group | Group-Object Region, ResourceType, Operation, Status | Sort-Object Name)) {
                $resource = $group.Group[0]
                Write-Host "      $($group.Count) $($resource.ResourceType) [$($resource.Region)]: $($resource.Operation) [$($resource.Status)]"
            }
        }
        if ($script:BootstrapperReport.AppliedChanges.Count -eq 0) { Write-Host '    No resource results collected.' }
        Write-Host '  Failed or incomplete operations:'
        $incompleteResources = @($script:BootstrapperReport.AppliedChanges | Where-Object { $_.Status -ne 'Succeeded' })
        $incompleteDeployments = @($script:BootstrapperReport.DeploymentStages | Where-Object { $_.Status -ne 'Succeeded' })
        foreach ($resource in $incompleteResources) { Write-Host "    [$($resource.Stage)] $($resource.Name): $($resource.Operation) [$($resource.Status)]" }
        foreach ($deployment in $incompleteDeployments) { Write-Host "    [$($deployment.Stage)] $($deployment.Name): $($deployment.Status)" }
        if ($incompleteResources.Count -eq 0 -and $incompleteDeployments.Count -eq 0) {
            if ($appliedChanges.Status -eq 'Available') { Write-Host '    None reported.' }
            else { Write-Host '    Unknown; operation collection was incomplete.' }
        }
        Write-Host '  Operation labels are not a planned-versus-applied reconciliation; Create can also update an existing resource.'
    }

    Write-Host ''
    Write-Host 'Bicep validation findings:'
    if ($null -ne $script:BootstrapperReport.Validation) {
        $validation = $script:BootstrapperReport.Validation
        if ($validation.FindingsAvailable) {
            $validationMode = if ($validation.EnforcementEnabled) { 'enforce' } else { 'reportOnly' }
            Write-Host "  Mode: $validationMode; blocking: $($validation.Blocking.Count); advisory: $($validation.Advisory.Count)"
            if ($null -ne $validation.ShouldBlockDeployment) { Write-Host "  Deployment gate: $(if ($validation.ShouldBlockDeployment) { 'blocked' } else { 'not blocked' })" }
        }
        else { Write-Host '  Outputs were incomplete; inspect the saved deployment record.' }
    }
    elseif ($script:DeploymentAttempted) {
        Write-Host '  Deployment diagnostics were queried when available; see issues below.'
    }
    else {
        Write-Host '  Not available; no deployment reached the validation engine.'
    }

    Write-Host ''
    Write-Host 'VM setup checks:'
    if ($script:BootstrapperReport.GuestResults.Count -gt 0) {
        $script:BootstrapperReport.GuestResults | Format-Table -Property VM, Command, ExecutionState, ExitCode, Result -AutoSize | Out-Host
    }
    else { Write-Host '  No guest command results were collected.' }

    Write-Host ''
    Write-Host 'Warnings and errors:'
    if ($script:BootstrapperReport.Issues.Count -gt 0) {
        foreach ($issue in $script:BootstrapperReport.Issues) {
            Write-Host "  [$($issue.Severity)] $($issue.Phase): $($issue.Message)"
            if (-not [string]::IsNullOrWhiteSpace([string]$issue.NextStep)) {
                Write-Host "    Next step: $($issue.NextStep)"
            }
        }
    }
    else { Write-Host '  None.' }
}

# Read nested ARM operation records or captured progress snapshots and reduce them to stage/resource results.
function Set-AMRLDeploymentOperationReport {
    param(
        [Parameter(Mandatory = $true)][string]$DeploymentName,
        [switch]$ShowProgress,
        [switch]$UseOperationSnapshots,
        [ValidateSet('Succeeded', 'Failed', 'Canceled', 'Cancelled')][string]$DeploymentState,
        [string]$FailureMessage = ''
    )

    try {
        $changesById = @{}
        $stageResults = New-Object 'System.Collections.Generic.List[object]'
        $reportedOperationErrors = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $pending = New-Object 'System.Collections.Generic.Queue[object]'
        $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $unreadableCount = 0
        if ($UseOperationSnapshots) {
            if ($null -eq $script:BootstrapperReport -or
                $script:BootstrapperReport.OperationSnapshotDeploymentName -ne $DeploymentName -or
                $script:BootstrapperReport.OperationSnapshots.Count -eq 0) {
                throw 'No deployment operation snapshots are available for the failed deployment.'
            }
            foreach ($entry in $script:BootstrapperReport.OperationSnapshots.GetEnumerator()) {
                $snapshot = $entry.Value
                $pending.Enqueue([pscustomobject]@{
                    Id = $entry.Key
                    Stage = $snapshot.Stage
                    Depth = $snapshot.Depth
                    State = $snapshot.State
                    Arguments = @()
                    Operations = $snapshot.Operations
                })
            }
            $unreadableCount++
        }
        else {
            $pending.Enqueue([pscustomobject]@{
                Id = $DeploymentName
                Stage = 'Deployment'
                Depth = 0
                Arguments = @('deployment', 'operation', 'sub', 'list', '--name', $DeploymentName, '--query', '[].{properties:properties}')
                Operations = $null
            })
        }
        while ($pending.Count -gt 0) {
            $current = $pending.Dequeue()
            if (-not $visited.Add($current.Id)) { continue }
            if ($ShowProgress -and ($visited.Count -eq 1 -or $visited.Count % 10 -eq 0)) {
                $label = Get-AMRLResourceDisplayName -ResourceId $current.Id
                Write-Host "  Reading deployment operations: $label ($($visited.Count) deployment records visited; $($pending.Count) queued)."
            }
            try {
                if ($null -ne $current.Operations) {
                    $operations = @($current.Operations)
                }
                else {
                    $operationList = Get-AzJson -Arguments $current.Arguments
                    $operations = @($operationList)
                }
            }
            catch {
                if ($current.Depth -eq 0) { throw }
                $unreadableCount++
                $label = Get-AMRLResourceDisplayName -ResourceId $current.Id
                Add-AMRLReportIssue -Phase 'Deployment operations' -Severity Warning -Message "Operations for '$label' could not be read; the resource summary is incomplete."
                Write-Verbose $_.Exception.Message
                continue
            }
            foreach ($operation in $operations) {
                $properties = $operation.PSObject.Properties['properties']
                if ($null -eq $properties -or $null -eq $properties.Value) { continue }
                $operationType = [string]$properties.Value.provisioningOperation
                $targetProperty = $properties.Value.PSObject.Properties['targetResource']
                if ([string]::IsNullOrWhiteSpace($operationType) -or $operationType -in @('Read', 'ReadData') -or $null -eq $targetProperty -or $null -eq $targetProperty.Value) { continue }
                $resourceId = [string]$targetProperty.Value.id
                if ([string]::IsNullOrWhiteSpace($resourceId)) { continue }
                $status = [string]$properties.Value.provisioningState
                if ([string]::IsNullOrWhiteSpace($status)) { $status = 'Unknown' }
                $stage = if ($resourceId -match '(?i)-network-stage-') { 'Network' }
                    elseif ($resourceId -match '(?i)-compute-stage-') { 'Compute' }
                    elseif ($resourceId -match '(?i)-identity-stage-') { 'Identity' }
                    elseif ($resourceId -match '(?i)-validation-(engine|gate)-') { 'Validation' }
                    else { $current.Stage }
                if ($resourceId -match '(?i)^/subscriptions/(?<Subscription>[^/]+)(?:/resourceGroups/(?<ResourceGroup>[^/]+))?/providers/Microsoft.Resources/deployments/(?<Deployment>[^/]+)$') {
                    $arguments = if ([string]::IsNullOrWhiteSpace($Matches['ResourceGroup'])) {
                        @('deployment', 'operation', 'sub', 'list')
                    }
                    else { @('deployment', 'operation', 'group', 'list', '--resource-group', $Matches.ResourceGroup) }
                    $arguments += @('--subscription', $Matches.Subscription, '--name', $Matches.Deployment, '--query', '[].{properties:properties}')
                    if (-not $UseOperationSnapshots) {
                        $pending.Enqueue([pscustomobject]@{ Id = $resourceId; Stage = $stage; Depth = $current.Depth + 1; Arguments = $arguments; Operations = $null })
                    }
                    if ($current.Depth -eq 0 -or $status -ne 'Succeeded') {
                        $stageResults.Add([pscustomobject]@{ Stage = $stage; Status = $status; Name = Get-AMRLResourceDisplayName -ResourceId $resourceId })
                    }
                    continue
                }
                $errorProperty = $properties.Value.PSObject.Properties['statusMessage']
                $operationError = if ($null -eq $errorProperty) { $null } else { $errorProperty.Value }
                $errorDetails = if ($status -ne 'Succeeded' -and $null -ne $operationError) {
                    Get-AMRLDeploymentOperationErrorSummary -ErrorData $operationError
                }
                else { '' }
                if ($status -in @('Failed', 'Canceled', 'Cancelled', 'TimedOut') -or -not [string]::IsNullOrWhiteSpace($errorDetails)) {
                    $resourceName = Get-AMRLResourceDisplayName -ResourceId $resourceId
                    if ([string]::IsNullOrWhiteSpace($errorDetails)) { $errorDetails = "$resourceName ended in state $status." }
                    $issueKey = "$resourceName|$status|$errorDetails"
                    if ($reportedOperationErrors.Add($issueKey)) {
                        $severity = if ($status -in @('Failed', 'Canceled', 'Cancelled', 'TimedOut')) { 'Error' } else { 'Warning' }
                        Add-AMRLReportIssue -Phase 'Deployment operations' -Severity $severity -Message $errorDetails
                    }
                }
                $region = Get-AMRLResourceRegionLabel -ResourceId $resourceId
                $timestampProperty = $properties.Value.PSObject.Properties['timestamp']
                $recordedAt = [datetimeoffset]::MinValue
                if ($null -ne $timestampProperty) { [void][datetimeoffset]::TryParse([string]$timestampProperty.Value, [ref]$recordedAt) }
                $key = "$stage|$resourceId"
                if ($changesById.ContainsKey($key) -and $changesById[$key].RecordedAt -gt $recordedAt) { continue }
                $changesById[$key] = [pscustomobject]@{
                    Stage = $stage
                    Region = $region
                    Operation = $operationType
                    Status = $status
                    ResourceType = Get-AMRLResourceTypeLabel -ResourceId $resourceId
                    ResourceId = $resourceId
                    Name = Get-AMRLResourceDisplayName -ResourceId $resourceId
                    ErrorDetails = $errorDetails
                    RecordedAt = $recordedAt
                }
            }
        }
        $changes = @($changesById.Values | Sort-Object Stage, Region, ResourceType, Name)
        if ($null -ne $script:BootstrapperReport) {
            $script:BootstrapperReport.AppliedChanges = $changes
            $finalStages = @($stageResults.ToArray())
            if ($UseOperationSnapshots -and $FailureMessage -match '(?i)(?<Name>AMRL-(?:network|compute|identity)-stage-[A-Za-z0-9_.-]+)') {
                $failedStageName = $Matches.Name
                $failedStage = if ($failedStageName -match '(?i)-network-stage-') { 'Network stage' }
                    elseif ($failedStageName -match '(?i)-compute-stage-') { 'Compute stage' }
                    else { 'Identity stage' }
                $finalStages = @($finalStages | Where-Object { $_.Name -ne $failedStageName })
                $finalStages += [pscustomobject]@{ Stage = $failedStage; Status = 'Failed'; Name = $failedStageName }
            }
            $script:BootstrapperReport.DeploymentStages = $finalStages
            if ($UseOperationSnapshots) {
                $script:BootstrapperReport.DeploymentState = $DeploymentState
            }
            else {
                try {
                    $deployment = Get-AzJson -Arguments @('deployment', 'sub', 'show', '--name', $DeploymentName)
                    $script:BootstrapperReport.DeploymentState = [string]$deployment.properties.provisioningState
                }
                catch { Write-Verbose "Deployment status was unavailable: $($_.Exception.Message)" }
            }
        }
        $details = @($changes | ForEach-Object { "$($_.Operation) [$($_.Status)]: $($_.Name)" }) -join [Environment]::NewLine
        $collectionStatus = if ($unreadableCount -gt 0) { 'Partial' } else { 'Available' }
        $summary = "$($changes.Count) resource results collected; deployment records excluded."
        if ($UseOperationSnapshots) {
            $collectionStatus = 'Partial'
            $summary += ' Based on the last in-progress snapshots; final operation states may be missing.'
        }
        elseif ($unreadableCount -gt 0) { $summary += " $unreadableCount nested deployment operation list(s) unavailable." }
        Set-AMRLReportSource -Name 'Applied resource changes' -Status $collectionStatus -Summary $summary -Details $details
        if ($ShowProgress) { Write-Host "  Resource operation collection finished: $($changes.Count) resource results; $collectionStatus." }
    }
    catch {
        $message = "Could not retrieve deployment operations for '$DeploymentName': $($_.Exception.Message)"
        Add-AMRLReportIssue -Phase 'Deployment operations' -Severity Warning -Message $message
        Set-AMRLReportSource -Name 'Applied resource changes' -Status 'Unavailable' -Summary $message
    }
}

# Validate mode selection first, then initialize the report and invoke the shared setup/deploy workflow.
function Invoke-AMRLBootstrapper {
    param(
        [switch]$Plan,
        [switch]$Prepare,
        [switch]$Deploy,
        [string]$ReportPath
    )

    $selectedModeCount = @(@($Plan, $Prepare, $Deploy) | Where-Object { $_ }).Count
    if ($selectedModeCount -eq 0) {
        throw 'Select a run mode: -Plan, -Prepare, or -Deploy.'
    }
    if ($selectedModeCount -gt 1) {
        throw 'Run modes are mutually exclusive. Select only one of -Plan, -Prepare, or -Deploy.'
    }

    $mode = if ($Plan) { 'Plan' } elseif ($Prepare) { 'Prepare' } else { 'Deploy' }
    Initialize-AMRLBootstrapperReport -Mode $mode
    $failure = $null
    $reportOutputFailed = $false
    try {
        Invoke-AMRLSubscriptionSetup -Plan:$Plan -Configure:$Prepare -Deploy:$Deploy
    }
    catch {
        $failure = $_
        $failedPhase = $script:BootstrapperPhase
        $failureSummary = if ($failedPhase -eq 'Deployment') { Get-AMRLDeploymentFailureSummary -Message $failure.Exception.Message } else { $failure.Exception.Message }
        Write-Verbose "Bootstrapper phase '$failedPhase' failed; collecting independent diagnostics for the final report."
        $phaseIssueAlreadyRecorded = @($script:BootstrapperReport.Issues | Where-Object { $_.Phase -eq $failedPhase -and $_.Severity -eq 'Error' }).Count -gt 0
        if (-not $phaseIssueAlreadyRecorded) {
            Add-AMRLReportIssue -Phase $failedPhase -Message $failureSummary
        }
        $phaseSummary = if ($failedPhase -eq 'Deployment') { 'Deployment failed; see Warnings and errors below.' }
            elseif ($phaseIssueAlreadyRecorded) { 'Foundation setup failed; see Warnings and errors below.' }
            else { $failureSummary }
        Set-AMRLReportPhase -Name $failedPhase -Status 'Failed' -Summary $phaseSummary
        if ($script:BootstrapperReport.Mode -ne 'Plan' -and $null -ne $script:BootstrapperReport.Context -and $null -ne $script:BootstrapperReport.Parameters -and -not $script:BootstrapperReport.Sources.Contains('Bicep build')) {
            try {
                $foundation = Get-AMRLFoundationConfiguration -Parameters $script:BootstrapperReport.Parameters -SubscriptionId $script:BootstrapperReport.Context.id -AllowMissingFoundation
                Invoke-AMRLPlan `
                    -Context $script:BootstrapperReport.Context `
                    -Parameters $script:BootstrapperReport.Parameters `
                    -ResourceGroup $foundation.ResourceGroup `
                    -FoundationLocation $script:BootstrapperReport.FoundationLocation `
                    -IdentityName $foundation.IdentityName `
                    -IdentityResourceGroup $foundation.IdentityResourceGroup `
                    -VaultResourceGroup $foundation.VaultResourceGroup `
                    -DeploymentLocation (Get-AMRLFoundationLocation -Parameters $script:BootstrapperReport.Parameters) `
                    -VaultName $foundation.VaultName `
                    -PublicIp $script:BootstrapperReport.PublicIp `
                    -Repository $script:BootstrapperReport.Parameters.parameters.prefix.metadata.bootstrap.githubRepository `
                    -AppDisplayName (Get-AMRLDefault 'githubAppDisplayName') `
                    -IncludeGitHub:$IncludeGitHub `
                    -DiagnosticOnly
            }
            catch {
                $diagnosticMessage = "Fallback read-only readiness checks failed: $($_.Exception.Message)"
                Add-AMRLReportIssue -Phase 'Fallback diagnostics' -Severity Warning -Message $diagnosticMessage
                Set-AMRLReportSource -Name 'Fallback readiness checks' -Status 'Failed' -Summary $diagnosticMessage
            }
        }
        if (-not $script:BootstrapperReport.Sources.Contains('Bicep build')) {
            $script:BootstrapperPhase = 'Bicep build and validation'
            $template = Join-Path $script:RepositoryRoot 'main.bicep'
            $build = Invoke-AMRLObservedCommand -Name 'Bicep build' -Arguments @('bicep', 'build', '--file', $template)
            $lint = Invoke-AMRLObservedCommand -Name 'Bicep lint' -Arguments @('bicep', 'lint', '--file', $template)
            if ($build.Succeeded -and $lint.Succeeded) {
                Set-AMRLReportPhase -Name 'Bicep build and validation' -Status 'Partial' -Summary 'Independent static checks succeeded after an earlier phase failed; parameterized Azure checks were skipped.'
            }
            else {
                Set-AMRLReportPhase -Name 'Bicep build and validation' -Status 'Failed' -Summary 'Fallback static Bicep checks also encountered errors.'
            }
            Set-AMRLReportSource -Name 'Azure deployment validate' -Status 'Skipped' -Summary 'Requires a resolved parameter file and completed foundation setup.'
            Set-AMRLReportPhase -Name 'What-if preview' -Status 'Skipped' -Summary 'Requires completed parameter resolution and Azure validation.'
            Set-AMRLReportPhase -Name 'Deployment' -Status 'Skipped' -Summary 'Deployment prerequisites did not complete.'
            Set-AMRLReportPhase -Name 'AMRL validation engine outputs' -Status 'Not available' -Summary 'No deployment ran.'
            Set-AMRLReportPhase -Name 'VM setup checks' -Status 'Not available' -Summary 'No deployment ran.'
        }
    }
    finally {
        try {
            if ([string]::IsNullOrWhiteSpace($ReportPath)) {
                Write-AMRLBootstrapperReport
            }
            else {
                $reportOutput = @(Write-AMRLBootstrapperReport 6>&1)
                $reportLines = @($reportOutput | ForEach-Object {
                    if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData }
                    else { [string]$_ }
                })
                foreach ($line in $reportLines) { Write-Host $line }
                try {
                    $resolvedReportPath = [System.IO.Path]::GetFullPath($ReportPath)
                    [System.IO.File]::WriteAllLines($resolvedReportPath, $reportLines, [System.Text.UTF8Encoding]::new($false))
                    Write-Host "Report saved to: $resolvedReportPath"
                }
                catch {
                    $reportOutputFailed = $true
                    Write-Warning "Could not write the bootstrapper report to '$ReportPath': $($_.Exception.Message)"
                }
            }
        }
        catch {
            $reportOutputFailed = $true
            Write-Warning "Could not complete the bootstrapper report: $($_.Exception.Message)"
        }
    }
    if ($null -ne $failure -or $script:BootstrapperReport.Status -eq 'Failed' -or $reportOutputFailed) {
        $global:LASTEXITCODE = 1
        Write-Warning 'Bootstrapper finished with errors; see the completed report above.'
        return
    }
}

# Dot-sourcing loads helpers for local tests without starting setup.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AMRLBootstrapper -Plan:$Plan -Prepare:$Prepare -Deploy:$Deploy -ReportPath $ReportPath
}
