[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$ParameterFile,
    [string]$FoundationResourceGroup = 'amrl-foundation-rg',
    [string]$FoundationLocation,
    [string]$DeploymentLocation,
    [string]$KeyVaultName,
    [string]$AutomationIdentityName = 'amrl-deployment-mi',
    [string]$GitHubRepository = 'andriesdutoit-svg/azure-multiregion-lab',
    [string]$GitHubAppDisplayName = 'AMRL-github-actions',
    [string]$PublicIp,
    [switch]$IncludeGitHub,
    [switch]$Deploy,
    [switch]$PromptPasswords
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:WhatIfPending = $false
if ([string]::IsNullOrWhiteSpace($ParameterFile)) {
    $script:ParameterFilePath = Join-Path $script:RepositoryRoot 'main.parameters.local.json'
}
elseif ([System.IO.Path]::IsPathRooted($ParameterFile)) {
    $script:ParameterFilePath = $ParameterFile
}
else {
    $script:ParameterFilePath = Join-Path $script:RepositoryRoot $ParameterFile
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "Azure CLI failed (exit $exitCode): az $($Arguments -join ' ')`n$text"
    }

    return $text.Trim()
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

function Get-AzTsv {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    return (Invoke-AzCli -Arguments ($Arguments + @('--output', 'tsv'))).Trim()
}

function Get-AMRLOutputValue {
    param(
        [Parameter(Mandatory = $true)][object]$Outputs,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Outputs.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value.value
}

function Get-AMRLValidationReport {
    param([Parameter(Mandatory = $true)][object]$Deployment)

    $outputs = $Deployment.properties.outputs
    if ($null -eq $outputs) { return $null }

    $summary = Get-AMRLOutputValue -Outputs $outputs -Name 'validationSummary'
    if ([string]::IsNullOrWhiteSpace([string]$summary)) {
        $summary = Get-AMRLOutputValue -Outputs $outputs -Name 'validationMessage'
    }
    $blockingSummary = Get-AMRLOutputValue -Outputs $outputs -Name 'blockingValidationSummary'

    return [pscustomobject]@{
        DeploymentName = [string]$Deployment.name
        Summary = [string]$summary
        BlockingSummary = [string]$blockingSummary
        Flags = @(Get-AMRLOutputValue -Outputs $outputs -Name 'validationFlags')
        Blocking = @(Get-AMRLOutputValue -Outputs $outputs -Name 'blockingValidationDetails')
        Advisory = @(Get-AMRLOutputValue -Outputs $outputs -Name 'advisoryValidationDetails')
        Capacity = Get-AMRLOutputValue -Outputs $outputs -Name 'capacityCheck'
        Placements = @(Get-AMRLOutputValue -Outputs $outputs -Name 'vmPlacement')
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

function Write-AMRLValidationReport {
    param(
        [Parameter(Mandatory = $true)][object]$Deployment,
        [string]$Title = 'AMRL validation report'
    )

    $report = Get-AMRLValidationReport -Deployment $Deployment
    if ($null -eq $report) {
        Write-Warning "$Title is unavailable in this deployment record."
        return
    }

    Write-Host "`n$Title"
    Write-Host "Deployment: $($report.DeploymentName)"
    if (-not [string]::IsNullOrWhiteSpace($report.Summary)) { Write-Host "Summary: $($report.Summary)" }
    if (-not [string]::IsNullOrWhiteSpace($report.BlockingSummary)) { Write-Host "Blocking summary: $($report.BlockingSummary)" }

    foreach ($finding in $report.Blocking) {
        Write-Host "BLOCKING [$($finding.flag)] $($finding.message)" -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace([string]$finding.remediation)) { Write-Host "  Remediation: $($finding.remediation)" }
    }
    foreach ($finding in $report.Advisory) {
        Write-Host "ADVISORY [$($finding.flag)] $($finding.message)" -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace([string]$finding.remediation)) { Write-Host "  Remediation: $($finding.remediation)" }
    }

    if ($report.Flags.Count -gt 0) {
        Write-Host 'Validation flags:'
        $report.Flags | ConvertTo-Json -Depth 20 | Write-Host
    }
    if ($null -ne $report.Capacity) {
        Write-Host 'Capacity:'
        $report.Capacity | ConvertTo-Json -Depth 10 | Write-Host
    }
    if ($report.Placements.Count -gt 0) {
        Write-Host 'VM placements:'
        $report.Placements | Format-Table -Property name, type, regionKey, index -AutoSize | Out-Host
    }
}

function Show-AMRLValidationAfterFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$RootDeploymentName
    )

    try {
        $root = Get-AzJson -Arguments @('deployment', 'sub', 'show', '--name', $RootDeploymentName)
        $rootReport = Get-AMRLValidationReport -Deployment $root
        if ($null -ne $rootReport -and -not [string]::IsNullOrWhiteSpace($rootReport.Summary)) {
            Write-AMRLValidationReport -Deployment $root -Title 'Validation output from failed root deployment'
            return
        }
    }
    catch {
        Write-Warning 'Root deployment outputs were unavailable; checking the nested validation engine.'
    }

    $validationName = Get-AMRLValidationDeploymentName -Prefix $Prefix -RootDeploymentName $RootDeploymentName
    try {
        $validationDeployment = Get-AzJson -Arguments @('deployment', 'sub', 'show', '--name', $validationName)
        Write-AMRLValidationReport -Deployment $validationDeployment -Title 'Nested validation-engine output'
    }
    catch {
        Write-Warning "Could not retrieve nested validation deployment '$validationName': $($_.Exception.Message)"
    }
}

function Invoke-AMRLChange {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Operation
    )

    if ($PSCmdlet.ShouldProcess($Target, $Action)) {
        return (& $Operation)
    }
    $script:WhatIfPending = $true
    return $null
}

function Read-RequiredValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [string]$DefaultValue,

        [scriptblock]$Validator = { param($Value) -not [string]::IsNullOrWhiteSpace($Value) }
    )

    while ($true) {
        $suffix = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { '' } else { " [$DefaultValue]" }
        $value = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $DefaultValue
        }
        if (& $Validator $value) {
            return $value
        }
        Write-Warning 'That value is not valid. Try again.'
    }
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
        $temporary = $characters[$index]
        $characters[$index] = $characters[$swapIndex]
        $characters[$swapIndex] = $temporary
    }

    return (-join $characters.ToArray())
}

function Set-AMRLParameterReferences {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Parameters,

        [Parameter(Mandatory = $true)]
        [string]$KeyVaultId,

        [Parameter(Mandatory = $true)]
        [string]$IdentityId,

        [string]$PublicIp
    )

    foreach ($entry in $Parameters.parameters.PSObject.Properties) {
        $reference = $entry.Value.PSObject.Properties['reference']
        if ($null -ne $reference -and $null -ne $entry.Value.reference.keyVault) {
            $existingId = [string]$entry.Value.reference.keyVault.id
            if (-not [string]::IsNullOrWhiteSpace($existingId) -and
                $existingId -notmatch '[<>]' -and
                $existingId -ne $KeyVaultId) {
                throw "Parameter '$($entry.Name)' references a different Key Vault. Review the parameter file; it was not overwritten."
            }
            $entry.Value.reference.keyVault.id = $KeyVaultId
        }
    }

    $identityValue = [string]$Parameters.parameters.automationManagedIdentityResourceId.value
    if (-not [string]::IsNullOrWhiteSpace($identityValue) -and
        $identityValue -notmatch '[<>]' -and
        $identityValue -ne $IdentityId) {
        throw 'The parameter file references a different managed identity. Review the file; it was not overwritten.'
    }
    $Parameters.parameters.automationManagedIdentityResourceId.value = $IdentityId

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

function Get-GitHubSubject {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Branch
    )
    return "repo:${Repository}:ref:refs/heads/${Branch}"
}

function Get-ParameterDocument {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
    }

    $demoPath = Join-Path $script:RepositoryRoot 'main.parameters.demo.json'
    if (-not (Test-Path -LiteralPath $demoPath)) {
        throw "Demo parameter file not found: $demoPath"
    }

    $document = Get-Content -Raw -LiteralPath $demoPath | ConvertFrom-Json
    $document.parameters.prefix.value = Read-RequiredValue -Prompt 'Lab prefix' -DefaultValue ([string]$document.parameters.prefix.value) -Validator {
        param($Value) [string]$Value -match '^[A-Za-z0-9-]{1,10}$'
    }
    $availableRegions = @($document.parameters.regionIndexMap.value.PSObject.Properties | Sort-Object { [int]$_.Value })
    Write-Host "Available regions: $((@($availableRegions | ForEach-Object { $_.Name })) -join ', ')"
    $defaultRegions = @($availableRegions | Select-Object -First ([int]$document.parameters.regionCount.value) | ForEach-Object { $_.Name })
    $regionText = Read-RequiredValue -Prompt 'Selected region names, comma-separated' -DefaultValue ($defaultRegions -join ',') -Validator {
        param($Value)
        $selected = @(([string]$Value -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $allowed = @($availableRegions | ForEach-Object { $_.Name })
        $selected.Count -ge 1 -and $selected.Count -eq (@($selected | Select-Object -Unique)).Count -and
            @($selected | Where-Object { $_ -notin $allowed }).Count -eq 0
    }
    $selectedRegions = @($regionText -split ',' | ForEach-Object { $_.Trim() })
    $regionMap = [ordered]@{}
    $index = 1
    foreach ($selectedRegion in $selectedRegions) {
        $regionMap[$selectedRegion] = $index
        $index++
    }
    $document.parameters.regionIndexMap.value = [pscustomobject]$regionMap
    $document.parameters.regionCount.value = $selectedRegions.Count

    $networkModes = @('fullMesh', 'hubSpoke', 'hubSpokeFirewall')
    $document.parameters.networkMode.value = Read-RequiredValue -Prompt "Network mode ($($networkModes -join ', '))" -DefaultValue ([string]$document.parameters.networkMode.value) -Validator {
        param($Value) $Value -in $networkModes
    }

    foreach ($countName in @('dc', 'jumpbox', 'windowsServer', 'windowsClient', 'linuxServer', 'linuxClient')) {
        $defaultCount = [int]$document.parameters.vmCounts.value.$countName
        $valueText = Read-RequiredValue -Prompt "VM count for $countName" -DefaultValue ([string]$defaultCount) -Validator {
            param($Value)
            $parsed = 0
            [int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -ge 0
        }
        $parsedCount = 0
        [void][int]::TryParse($valueText, [ref]$parsedCount)
        $document.parameters.vmCounts.value.$countName = $parsedCount
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Create local Bicep parameter file from demo')) {
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $json = $document | ConvertTo-Json -Depth 100
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    }
    else {
        $script:WhatIfPending = $true
    }

    return $document
}

function Set-AMRLRoleAssignmentIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$AssigneeObjectId,
        [Parameter(Mandatory = $true)][string]$PrincipalType,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$Scope
    )

    $existingId = Get-AzTsv -Arguments @(
        'role', 'assignment', 'list', '--scope', $Scope,
        '--assignee', $AssigneeObjectId, '--all',
        '--query', "[?roleDefinitionName=='$Role' && scope=='$Scope'].id"
    )
    if (-not [string]::IsNullOrWhiteSpace($existingId)) {
        Write-Host "Role assignment exists: $Role on $Scope"
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

function Set-AMRLSecretIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$VaultName,
        [Parameter(Mandatory = $true)][string]$SecretName,
        [switch]$Password,
        [switch]$Prompt
    )

    $exists = Get-AzTsv -Arguments @(
        'keyvault', 'secret', 'list', '--vault-name', $VaultName,
        '--query', "[?name=='$SecretName'].name"
    )
    if (-not [string]::IsNullOrWhiteSpace($exists)) {
        Write-Host "Key Vault secret exists; keeping it unchanged: $SecretName"
        return
    }

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
    }) | Out-Null
}

function Set-AMRLKeySecretsIfMissing {
    param([Parameter(Mandatory = $true)][string]$VaultName)

    $keyPath = Join-Path $HOME '.ssh/amrl_ed25519'
    $publicPath = "$keyPath.pub"
    $privateExists = Test-Path -LiteralPath $keyPath
    $publicExists = Test-Path -LiteralPath $publicPath

    if ($privateExists -xor $publicExists) {
        throw "SSH key pair is incomplete at '$keyPath'. Restore both files or resolve the pair manually; the script will not overwrite it."
    }
    if (-not $privateExists) {
        [void](Invoke-AMRLChange -Target $keyPath -Action 'Generate dedicated Ed25519 SSH key pair' -Operation {
            New-Item -ItemType Directory -Path (Split-Path $keyPath -Parent) -Force | Out-Null
            & ssh-keygen -t ed25519 -f $keyPath
            if ($LASTEXITCODE -ne 0) { throw 'SSH key generation failed.' }
        })
        if (-not (Test-Path -LiteralPath $keyPath) -or -not (Test-Path -LiteralPath $publicPath)) {
            Write-Host 'SSH key generation is pending because -WhatIf prevented file creation.'
            return
        }
    }

    $publicKey = (Get-Content -Raw -LiteralPath $publicPath).Trim()
    $derivedPublicKey = (& ssh-keygen -y -f $keyPath 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or (($derivedPublicKey -split '\s+')[0..1] -join ' ') -ne (($publicKey -split '\s+')[0..1] -join ' ')) {
        throw 'The public and private SSH keys do not match. The script will not upload either key.'
    }

    $secretNames = @(Get-AzJson -Arguments @('keyvault', 'secret', 'list', '--vault-name', $VaultName, '--query', '[].name'))
    $hasPublicKey = 'sshPublicKey' -in $secretNames
    $hasPrivateKey = 'sshPrivateKey' -in $secretNames
    if (-not $hasPublicKey -and -not $hasPrivateKey) {
        [void](Invoke-AMRLChange -Target "SSH key secrets in $VaultName" -Action 'Write dedicated SSH key pair to Key Vault' -Operation {
            Invoke-AzCli -Arguments @('keyvault', 'secret', 'set', '--vault-name', $VaultName, '--name', 'sshPublicKey', '--value', $publicKey, '--output', 'none') | Out-Null
            Invoke-AzCli -Arguments @('keyvault', 'secret', 'set', '--vault-name', $VaultName, '--name', 'sshPrivateKey', '--file', $keyPath, '--output', 'none') | Out-Null
        }) | Out-Null
    }
    elseif (-not $hasPublicKey -or -not $hasPrivateKey) {
        throw 'Only one SSH key secret exists in Key Vault. Resolve the pair manually; the script will not rotate or replace it.'
    }
    elseif ((Get-AzTsv -Arguments @('keyvault', 'secret', 'show', '--vault-name', $VaultName, '--name', 'sshPublicKey', '--query', 'value')).Trim() -ne $publicKey) {
        throw 'The Key Vault SSH public key differs from the local key pair. Resolve key rotation manually.'
    }
}

function New-AMRLFederatedCredentialIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$AppObjectId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Subject,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $credentials = Get-AzJson -Arguments @('ad', 'app', 'federated-credential', 'list', '--id', $AppObjectId)
    $bySubject = @($credentials | Where-Object { $_.subject -eq $Subject })
    if ($bySubject.Count -gt 0) {
        Write-Host "Federated credential exists: $Subject"
        return
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

    New-AMRLFederatedCredentialIfMissing -AppObjectId $app.id -Name 'github-actions-main' -Subject (Get-GitHubSubject -Repository $Repository -Branch 'main') -Description 'GitHub Actions - main branch'
    $branch = (git -C $script:RepositoryRoot branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
        throw 'Unable to determine the active Git branch for the GitHub credential.'
    }
    if ($branch -ne 'main') {
        $branchSuffix = ($branch -replace '[^A-Za-z0-9_-]', '-')
        if ($branchSuffix.Length -gt 75) { $branchSuffix = $branchSuffix.Substring(0, 75) }
        New-AMRLFederatedCredentialIfMissing -AppObjectId $app.id -Name "github-actions-$branchSuffix" -Subject (Get-GitHubSubject -Repository $Repository -Branch $branch) -Description "GitHub Actions - $branch"
    }
    New-AMRLFederatedCredentialIfMissing -AppObjectId $app.id -Name 'github-actions-pull-request' -Subject "repo:${Repository}:pull_request" -Description 'GitHub Actions - pull requests'

    [void](Invoke-AMRLChange -Target "GitHub Actions secrets in $Repository" -Action 'Set Azure OIDC repository secrets' -Operation {
        Invoke-GhCli -Arguments @('secret', 'set', 'AZURE_CLIENT_ID', '--body', $app.appId, '--repo', $Repository) | Out-Null
        Invoke-GhCli -Arguments @('secret', 'set', 'AZURE_TENANT_ID', '--body', $TenantId, '--repo', $Repository) | Out-Null
        Invoke-GhCli -Arguments @('secret', 'set', 'AZURE_SUBSCRIPTION_ID', '--body', $SubscriptionId, '--repo', $Repository) | Out-Null
    }) | Out-Null

    [void](Invoke-AMRLChange -Target "GitHub Actions variables in $Repository" -Action 'Set AMRL repository variables' -Operation {
        Invoke-GhCli -Arguments @('variable', 'set', 'KEYVAULT_ID', '--body', $VaultId, '--repo', $Repository) | Out-Null
        Invoke-GhCli -Arguments @('variable', 'set', 'AUTOMATION_MANAGED_IDENTITY_RESOURCE_ID', '--body', $IdentityId, '--repo', $Repository) | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($PublicIp)) {
            Invoke-GhCli -Arguments @('variable', 'set', 'YOUR_PUBLIC_IP', '--body', $PublicIp, '--repo', $Repository) | Out-Null
        }
    }) | Out-Null
}

function Invoke-AMRLSubscriptionSetup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param()
    $script:WhatIfPending = $false
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) is required. Install it and sign in before running this script.'
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is required to determine the active branch for optional GitHub OIDC setup.'
    }

    $context = Get-AzJson -Arguments @('account', 'show')
    if ($null -eq $context -or [string]::IsNullOrWhiteSpace($context.id) -or [string]::IsNullOrWhiteSpace($context.tenantId)) {
        throw 'Azure CLI has no selected subscription. Sign in and select the intended subscription, then rerun.'
    }
    Write-Host "Azure account: $($context.user.name)"
    Write-Host "Tenant: $($context.tenantId)"
    Write-Host "Subscription: $($context.name) ($($context.id))"
    if ((Read-Host 'Continue with this tenant and subscription? [y/N]') -notmatch '^(y|yes)$') {
        throw 'Stopped before making changes because Azure context was not confirmed.'
    }

    if ([string]::IsNullOrWhiteSpace($FoundationLocation)) {
        $FoundationLocation = Read-RequiredValue -Prompt 'Foundation resource location' -DefaultValue 'westeurope'
    }
    if ([string]::IsNullOrWhiteSpace($DeploymentLocation)) {
        $DeploymentLocation = Read-RequiredValue -Prompt 'Subscription deployment metadata location' -DefaultValue $FoundationLocation
    }

    $parameterDocument = Get-ParameterDocument -Path $script:ParameterFilePath -WhatIf:$WhatIfPreference
    if ($script:WhatIfPending) {
        Write-Host 'WhatIf or declined confirmation stopped before Azure changes because the local parameter file was not created.'
        return
    }
    $needsPublicIp = @($parameterDocument.parameters.jumpboxAllowedSources.value | Where-Object { [string]$_ -match '[<>]' }).Count -gt 0
    if (($needsPublicIp -or $IncludeGitHub) -and [string]::IsNullOrWhiteSpace($PublicIp)) {
        try {
            $discoveredIp = ([string](Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10)).Trim()
        }
        catch {
            $discoveredIp = ''
        }
        if (-not [string]::IsNullOrWhiteSpace($discoveredIp)) {
            Write-Host "Detected public IPv4: $discoveredIp"
            if ((Read-Host 'Use this address for jumpbox access? [y/N]') -match '^(y|yes)$') { $PublicIp = $discoveredIp }
        }
        if ([string]::IsNullOrWhiteSpace($PublicIp)) {
            $PublicIp = Read-RequiredValue -Prompt 'Approved public IPv4 address (without CIDR)' -Validator {
                param($Value)
                $address = $null
                [System.Net.IPAddress]::TryParse([string]$Value, [ref]$address) -and $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
            }
        }
    }

    $parsedIp = $null
    if (-not [string]::IsNullOrWhiteSpace($PublicIp) -and
        (-not [System.Net.IPAddress]::TryParse($PublicIp, [ref]$parsedIp) -or $parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork)) {
        throw 'PublicIp must be a valid IPv4 address without a CIDR suffix.'
    }

    foreach ($namespace in @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.ManagedIdentity', 'Microsoft.Storage', 'Microsoft.ContainerInstance')) {
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
    }
    if ($script:WhatIfPending) {
        Write-Host 'WhatIf or declined confirmation stopped before foundation creation because providers remain unregistered.'
        return
    }

    $groupExists = Get-AzTsv -Arguments @('group', 'exists', '--name', $FoundationResourceGroup)
    if ($groupExists -eq 'true') {
        $group = Get-AzJson -Arguments @('group', 'show', '--name', $FoundationResourceGroup)
        if (-not [string]::IsNullOrWhiteSpace($FoundationLocation) -and $group.location -ne $FoundationLocation) {
            Write-Host "Reusing existing foundation group location: $($group.location)"
            $FoundationLocation = $group.location
        }
    }
    else {
        $group = Invoke-AMRLChange -Target "Resource group $FoundationResourceGroup" -Action "Create in $FoundationLocation" -Operation {
            Get-AzJson -Arguments @('group', 'create', '--name', $FoundationResourceGroup, '--location', $FoundationLocation)
        }
        if ($null -eq $group) {
            Write-Host 'WhatIf stopped before foundation creation; rerun without -WhatIf to continue.'
            return
        }
    }

    $identity = Get-AzJson -Arguments @('identity', 'list', '--resource-group', $FoundationResourceGroup, '--query', "[?name=='$AutomationIdentityName'] | [0]")
    if ($null -eq $identity) {
        $identity = Invoke-AMRLChange -Target "Managed identity $AutomationIdentityName" -Action 'Create user-assigned managed identity' -Operation {
            Get-AzJson -Arguments @('identity', 'create', '--name', $AutomationIdentityName, '--resource-group', $FoundationResourceGroup, '--location', $FoundationLocation)
        }
        if ($null -eq $identity) {
            Write-Host 'WhatIf stopped before identity creation; rerun without -WhatIf to continue.'
            return
        }
    }
    Set-AMRLRoleAssignmentIfMissing -AssigneeObjectId $identity.principalId -PrincipalType ServicePrincipal -Role 'Network Contributor' -Scope "/subscriptions/$($context.id)"
    if ($script:WhatIfPending) {
        Write-Host 'WhatIf or declined confirmation stopped before dependent foundation setup; no resources were changed.'
        return
    }

    if ([string]::IsNullOrWhiteSpace($KeyVaultName)) {
        $knownVaults = @(Get-AzJson -Arguments @('keyvault', 'list', '--resource-group', $FoundationResourceGroup))
        if ($knownVaults.Count -eq 1) {
            $KeyVaultName = [string]$knownVaults[0].name
            Write-Host "Reusing the Key Vault in the foundation group: $KeyVaultName"
        }
        elseif ($knownVaults.Count -gt 1) {
            $choices = @($knownVaults | ForEach-Object { [string]$_.name })
            Write-Host "Key Vaults in the foundation group: $($choices -join ', ')"
            $KeyVaultName = Read-RequiredValue -Prompt 'Choose an existing Key Vault name' -Validator {
                param($Value) $Value -in $choices
            }
        }
        else {
            $subscriptionSuffix = ($context.id -replace '-', '').Substring(0, 8)
            $candidate = "amrl-kv-$subscriptionSuffix"
            $KeyVaultName = Read-RequiredValue -Prompt 'Globally unique Key Vault name' -DefaultValue $candidate -Validator {
                param($Value) $Value -match '^[A-Za-z][A-Za-z0-9-]{2,23}$'
            }
        }
    }

    $vault = Get-AzJson -Arguments @('keyvault', 'list', '--resource-group', $FoundationResourceGroup, '--query', "[?name=='$KeyVaultName'] | [0]")
    if ($null -eq $vault) {
        $nameCheck = Get-AzJson -Arguments @('keyvault', 'check-name', '--name', $KeyVaultName)
        if (-not $nameCheck.nameAvailable) { throw "Key Vault name '$KeyVaultName' is not globally available." }
        $vault = Invoke-AMRLChange -Target "Key Vault $KeyVaultName" -Action 'Create RBAC-enabled vault with purge protection' -Operation {
            Get-AzJson -Arguments @(
                'keyvault', 'create', '--name', $KeyVaultName,
                '--resource-group', $FoundationResourceGroup, '--location', $FoundationLocation,
                '--enable-rbac-authorization', 'true', '--enabled-for-template-deployment', 'true',
                '--enable-purge-protection', 'true'
            )
        }
        if ($null -eq $vault) {
            Write-Host 'WhatIf stopped before Key Vault creation; rerun without -WhatIf to continue.'
            return
        }
    }
    else {
        $vault = Get-AzJson -Arguments @('keyvault', 'show', '--name', $KeyVaultName, '--resource-group', $FoundationResourceGroup)
        if (-not $vault.properties.enableRbacAuthorization -or
            -not $vault.properties.enabledForTemplateDeployment -or
            -not $vault.properties.enablePurgeProtection) {
            throw 'The existing Key Vault does not meet the required RBAC, template-deployment, and purge-protection settings. Review it manually; the script will not weaken or modify its protections.'
        }
    }
    $vaultId = [string]$vault.id

    $userId = Get-AzTsv -Arguments @('ad', 'signed-in-user', 'show', '--query', 'id')
    if ([string]::IsNullOrWhiteSpace($userId)) { throw 'Could not resolve the signed-in Entra user.' }
    Set-AMRLRoleAssignmentIfMissing -AssigneeObjectId $userId -PrincipalType User -Role 'Key Vault Secrets Officer' -Scope $vaultId
    if ($script:WhatIfPending) {
        Write-Host 'WhatIf or declined confirmation stopped before Key Vault writes; no secrets were changed.'
        return
    }

    Set-AMRLSecretIfMissing -VaultName $KeyVaultName -SecretName 'jumpboxAdminPassword' -Password -Prompt:$PromptPasswords
    if ($script:WhatIfPending) { Write-Host 'WhatIf or declined confirmation stopped at the first missing secret; no dependent writes were attempted.'; return }
    Set-AMRLSecretIfMissing -VaultName $KeyVaultName -SecretName 'serverAdminPassword' -Password -Prompt:$PromptPasswords
    if ($script:WhatIfPending) { Write-Host 'WhatIf or declined confirmation stopped at the first missing secret; no dependent writes were attempted.'; return }
    Set-AMRLSecretIfMissing -VaultName $KeyVaultName -SecretName 'clientAdminPassword' -Password -Prompt:$PromptPasswords
    if ($script:WhatIfPending) { Write-Host 'WhatIf or declined confirmation stopped at the first missing secret; no dependent writes were attempted.'; return }
    Set-AMRLKeySecretsIfMissing -VaultName $KeyVaultName
    if ($script:WhatIfPending) { Write-Host 'WhatIf or declined confirmation stopped at SSH key provisioning; no dependent writes were attempted.'; return }

    $lock = Get-AzJson -Arguments @('lock', 'list', '--resource-group', $FoundationResourceGroup, '--query', "[?name=='protect-foundation'] | [0]")
    if ($null -ne $lock -and $lock.level -ne 'CanNotDelete') {
        throw "Lock 'protect-foundation' exists with level '$($lock.level)' instead of CanNotDelete. Resolve it manually."
    }
    if ($null -eq $lock) {
        [void](Invoke-AMRLChange -Target "Resource group $FoundationResourceGroup" -Action 'Apply CanNotDelete foundation lock' -Operation {
            Invoke-AzCli -Arguments @('lock', 'create', '--name', 'protect-foundation', '--lock-type', 'CanNotDelete', '--resource-group', $FoundationResourceGroup, '--output', 'none')
        })
    }
    if ($script:WhatIfPending) {
        Write-Host 'WhatIf or declined confirmation stopped before local parameter and deployment preparation because the foundation lock is unapplied.'
        return
    }

    $updatedParameters = Set-AMRLParameterReferences -Parameters $parameterDocument -KeyVaultId $vaultId -IdentityId $identity.id -PublicIp $PublicIp
    if ($PSCmdlet.ShouldProcess($script:ParameterFilePath, 'Write validated local Bicep parameters')) {
        $json = $updatedParameters | ConvertTo-Json -Depth 100
        [System.IO.File]::WriteAllText($script:ParameterFilePath, $json, [System.Text.UTF8Encoding]::new($false))
    }
    else {
        $script:WhatIfPending = $true
    }

    $parameterFileForPreflight = $script:ParameterFilePath
    $temporaryParameterFile = $null
    if (-not (Test-Path -LiteralPath $parameterFileForPreflight)) {
        if (-not $WhatIfPreference) {
            throw "Parameter file was not created: $parameterFileForPreflight"
        }
        $temporaryParameterFile = Join-Path $env:TEMP ('amrl-parameters-' + [guid]::NewGuid().ToString('N') + '.json')
        $parameterFileForPreflight = $temporaryParameterFile
        $json = $updatedParameters | ConvertTo-Json -Depth 100
        [System.IO.File]::WriteAllText($temporaryParameterFile, $json, [System.Text.UTF8Encoding]::new($false))
    }

    if ($IncludeGitHub) {
        Set-AMRLGitHubConfiguration -TenantId $context.tenantId -SubscriptionId $context.id -VaultId $vaultId -IdentityId $identity.id -Repository $GitHubRepository -AppDisplayName $GitHubAppDisplayName -PublicIp $PublicIp
    }
    if ($script:WhatIfPending) {
        Write-Host 'WhatIf or declined confirmation stopped before deployment preflight because bootstrap changes remain unapplied.'
        return
    }

    $mainTemplate = Join-Path $script:RepositoryRoot 'main.bicep'
    Invoke-AzCli -Arguments @('bicep', 'build', '--file', $mainTemplate) | Out-Null
    Invoke-AzCli -Arguments @('bicep', 'lint', '--file', $mainTemplate) | Out-Null
    Invoke-AzCli -Arguments @('deployment', 'sub', 'validate', '--location', $DeploymentLocation, '--template-file', $mainTemplate, '--parameters', $parameterFileForPreflight) | Out-Null

    $deploymentName = 'amrl-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $regions = @($updatedParameters.parameters.regionIndexMap.value.PSObject.Properties | Sort-Object { [int]$_.Value } | Select-Object -First ([int]$updatedParameters.parameters.regionCount.value) | ForEach-Object { $_.Name })
    $roleParameters = @(
        @{ Count = 'dc'; Size = 'dc'; Image = $null }
        @{ Count = 'jumpbox'; Size = 'jumpbox'; Image = $null }
        @{ Count = 'windowsServer'; Size = 'windowsServer'; Image = 'windowsServerImage' }
        @{ Count = 'windowsClient'; Size = 'windowsClient'; Image = 'windowsClientImage' }
        @{ Count = 'linuxServer'; Size = 'linuxServer'; Image = 'ubuntuImage' }
        @{ Count = 'linuxClient'; Size = 'linuxClient'; Image = 'ubuntuImage' }
    )
    $requestedSizes = @(
        foreach ($role in $roleParameters) {
            if ([int]$updatedParameters.parameters.vmCounts.value.($role.Count) -gt 0) {
                [string]$updatedParameters.parameters.vmSizes.value.($role.Size)
            }
        }
    ) | Select-Object -Unique

    foreach ($region in $regions) {
        Write-Host "Regional capacity preflight: $region"
        $availableSizes = Get-AzJson -Arguments @('vm', 'list-sizes', '--location', $region)
        $availableNames = @($availableSizes | ForEach-Object { [string]$_.name })
        foreach ($size in $requestedSizes) {
            if ($size -notin $availableNames) {
                throw "Requested VM size '$size' is not listed as available in region '$region'."
            }
        }
        Write-Host "Requested sizes available in ${region}: $($requestedSizes -join ', ')"

        foreach ($role in $roleParameters) {
            if ([int]$updatedParameters.parameters.vmCounts.value.($role.Count) -le 0 -or [string]::IsNullOrWhiteSpace($role.Image)) { continue }
            $image = $updatedParameters.parameters.($role.Image).value
            $urn = '{0}:{1}:{2}:{3}' -f $image.publisher, $image.offer, $image.sku, $image.version
            $imageId = Get-AzTsv -Arguments @('vm', 'image', 'show', '--location', $region, '--urn', $urn, '--query', 'id')
            if ([string]::IsNullOrWhiteSpace($imageId)) {
                throw "Image '$urn' is not available in region '$region'."
            }
        }

        $usage = Invoke-AzCli -Arguments @('vm', 'list-usage', '--location', $region, '--output', 'table')
        Write-Host $usage
        Write-Host 'Review regional usage above; the script does not infer quota sufficiency from family-specific limits.'
    }

    Invoke-AzCli -Arguments @('deployment', 'sub', 'what-if', '--name', $deploymentName, '--location', $DeploymentLocation, '--template-file', $mainTemplate, '--parameters', $parameterFileForPreflight)
    if ($WhatIfPreference -and $null -ne $temporaryParameterFile -and (Test-Path -LiteralPath $temporaryParameterFile)) {
        Remove-Item -LiteralPath $temporaryParameterFile -Force
    }
    if ($WhatIfPreference) {
        Write-Host '-WhatIf prevented all resource and secret writes; no deployment was started.'
        return
    }
    if (-not $Deploy) {
        Write-Host "Preview complete. No deployment was started. To deploy after reviewing the preview, rerun with -Deploy."
        return
    }
    if ((Read-Host "Type DEPLOY to create subscription deployment '$deploymentName'") -cne 'DEPLOY') {
        Write-Host 'Deployment skipped.'
        return
    }

    try {
        [void](Invoke-AMRLChange -Target "Subscription deployment $deploymentName" -Action 'Create AMRL resources from main.bicep' -Operation {
            Invoke-AzCli -Arguments @('deployment', 'sub', 'create', '--name', $deploymentName, '--location', $DeploymentLocation, '--template-file', $mainTemplate, '--parameters', $parameterFileForPreflight, '--output', 'json') | Out-Null
        })
    }
    catch {
        $deploymentError = $_
        Write-Warning "Subscription deployment failed: $($deploymentError.Exception.Message)"
        Show-AMRLValidationAfterFailure -Prefix ([string]$updatedParameters.parameters.prefix.value) -RootDeploymentName $deploymentName
        throw
    }

    $result = Get-AzJson -Arguments @('deployment', 'sub', 'show', '--name', $deploymentName)
    Write-AMRLValidationReport -Deployment $result -Title 'Post-deployment validation summary'
    $operations = Get-AzJson -Arguments @('deployment', 'operation', 'sub', 'list', '--name', $deploymentName, '--query', "[?properties.targetResource.resourceType=='Microsoft.Compute/virtualMachines/runCommands'].{resource:properties.targetResource.resourceName,state:properties.provisioningState}")
    Write-Host 'Run Command operations reported by the subscription deployment:'
    $operations | Format-Table -AutoSize
    Write-Host 'Control-plane completion is not proof of guest readiness; use the documented post-deployment checks.'
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AMRLSubscriptionSetup -WhatIf:$WhatIfPreference
}