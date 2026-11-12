$ErrorActionPreference = 'Stop'

# This is a mock-based regression suite, not a live Azure test. Dot-sourcing loads the
# bootstrapper helpers; each scenario replaces external commands with deterministic fakes,
# checks observable calls/results, and restores script state or removes temporary files.
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$scriptPath = Join-Path $repoRoot 'scripts/Initialize-Lab.ps1'
. $scriptPath
$originalInvokeAzCli = (Get-Command Invoke-AzCli).ScriptBlock

$scriptTokens = $null
$scriptParseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$scriptTokens, [ref]$scriptParseErrors)
if ($scriptParseErrors.Count -gt 0) { throw 'Bootstrapper script did not parse.' }
$publicParameters = @($scriptAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$supportsShouldProcess = @($scriptAst.ParamBlock.Attributes | Where-Object {
    $_.TypeName.Name -eq 'CmdletBinding' -and $_.Extent.Text -match 'SupportsShouldProcess\s*=\s*\$true'
})

$checks = 0
function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
    $script:checks++
}

# Deployment confirmation must accept only the literal token and keep cancellation in the report.
& {
    $script:confirmationAnswers = [System.Collections.Generic.Queue[string]]::new()
    $script:confirmationPrompts = New-Object 'System.Collections.Generic.List[string]'
    $script:confirmationMessages = New-Object 'System.Collections.Generic.List[string]'
    function Read-Host {
        param([string]$Prompt)
        $script:confirmationPrompts.Add($Prompt)
        if ($script:confirmationAnswers.Count -eq 0) { throw "Unexpected confirmation prompt: $Prompt" }
        return $script:confirmationAnswers.Dequeue()
    }
    function Write-Host {
        param([object]$Object, [switch]$NoNewline, [ConsoleColor]$ForegroundColor)
        $script:confirmationMessages.Add([string]$Object)
    }
    function Write-Warning { param([object]$Message) }
    function Set-ConfirmationAnswers {
        param([string[]]$Answers)
        $script:confirmationAnswers = [System.Collections.Generic.Queue[string]]::new($Answers)
        $script:confirmationPrompts.Clear()
        $script:confirmationMessages.Clear()
    }

    $previousReport = $script:BootstrapperReport
    Initialize-AMRLBootstrapperReport -Mode 'Deployment confirmation tests'

    Set-ConfirmationAnswers -Answers @('DEPLOY')
    Assert-Test (Confirm-AMRLDeployment -DeploymentName 'amrl-test') 'Exact DEPLOY was not accepted immediately.'
    Assert-Test (@($script:confirmationPrompts | Where-Object { $_ -eq 'Confirmation' }).Count -eq 1) 'Correct first confirmation prompted unnecessarily.'

    Set-ConfirmationAnswers -Answers @('deploy', 'DEPLOY')
    Assert-Test (Confirm-AMRLDeployment -DeploymentName 'amrl-test') 'The second exact DEPLOY attempt was not accepted.'
    Assert-Test (@($script:confirmationPrompts | Where-Object { $_ -eq 'Confirmation' }).Count -eq 2) 'An incorrect first confirmation was not retried exactly once.'

    Set-ConfirmationAnswers -Answers @('wrong', 'still wrong', 'y')
    Assert-Test (-not (Confirm-AMRLDeployment -DeploymentName 'amrl-test')) 'Choosing Yes to cancel did not cancel deployment.'
    Assert-Test (@($script:confirmationPrompts | Where-Object { $_ -eq 'Confirmation' }).Count -eq 2 -and @($script:confirmationPrompts | Where-Object { $_ -like 'Cancel deployment?*' }).Count -eq 1) 'Cancel choice was not offered after two incorrect DEPLOY attempts.'

    Set-ConfirmationAnswers -Answers @('wrong', 'wrong', 'n', 'DEPLOY')
    Assert-Test (Confirm-AMRLDeployment -DeploymentName 'amrl-test') 'Choosing No to cancel did not restart confirmation.'
    Assert-Test (@($script:confirmationPrompts | Where-Object { $_ -eq 'Confirmation' }).Count -eq 3) 'Confirmation did not restart from its first attempt after No.'

    Set-ConfirmationAnswers -Answers @('wrong', 'wrong', 'maybe', 'no', 'DEPLOY')
    Assert-Test (Confirm-AMRLDeployment -DeploymentName 'amrl-test') 'Invalid cancel response was not retried before restarting confirmation.'
    Assert-Test (@($script:confirmationPrompts | Where-Object { $_ -like 'Cancel deployment?*' }).Count -eq 2) 'Invalid y/N response did not repeat the cancel prompt.'

    Initialize-AMRLBootstrapperReport -Mode 'Cancelled report status test'
    Set-AMRLReportPhase -Name 'Deployment' -Status 'Cancelled' -Summary 'Deployment was not confirmed.'
    Write-AMRLBootstrapperReport
    Assert-Test ($script:BootstrapperReport.Status -eq 'Cancelled' -and $script:confirmationMessages -contains 'Overall result: Cancelled') 'Cancelled deployment was presented as successful.'
    $script:BootstrapperReport = $previousReport
}

# Lock down the public command-line contract and the complete parameter-file schema before
# exercising individual helpers. These checks also ensure service-account secrets stay inventoried.
Assert-Test ($publicParameters -contains 'Plan') 'Plan switch is missing from the public interface.'
Assert-Test ($publicParameters -contains 'Prepare') 'Prepare switch is missing from the public interface.'
Assert-Test ('Configure' -notin $publicParameters) 'The old Configure switch remains in the public interface.'
Assert-Test ($publicParameters -contains 'Deploy') 'Deploy switch is missing from the public interface.'
Assert-Test ('Stage' -notin $publicParameters) 'Stage should be a wizard question, not a command-line parameter.'
Assert-Test ('PromptPasswords' -notin $publicParameters) 'PromptPasswords should be a wizard choice, not a command-line switch.'
Assert-Test ('GitHubRepository' -notin $publicParameters) 'GitHubRepository must not be a public command-line parameter.'
Assert-Test ('GitHubAppDisplayName' -notin $publicParameters) 'GitHubAppDisplayName must not be a public command-line parameter.'
Assert-Test ('Preview' -notin $publicParameters) 'The obsolete Preview switch remains in the public interface.'
Assert-Test ('WhatIf' -notin $publicParameters -and 'Confirm' -notin $publicParameters) 'The ambiguous PowerShell common switches remain exposed.'
Assert-Test ('ConfirmBootstrap' -notin $publicParameters) 'The removed ConfirmBootstrap switch remains in the public interface.'
Assert-Test ($supportsShouldProcess.Count -eq 0) 'SupportsShouldProcess would reintroduce automatic -WhatIf/-Confirm switches.'
$serviceAccountPasswordSecretNames = @(
    [string]$script:AMRLDefaults.directory.serviceAccounts.backup.passwordSecretName
    [string]$script:AMRLDefaults.directory.serviceAccounts.monitoring.passwordSecretName
)
foreach ($secretName in $serviceAccountPasswordSecretNames) {
    Assert-Test ($secretName -in (Get-AMRLManagedSecretNames)) "Service-account secret '$secretName' is missing from the required Key Vault inventory."
    Assert-Test ($secretName -in (Get-AMRLPasswordSecretNames)) "Service-account secret '$secretName' is missing from the bootstrapper password-creation inventory."
}
$wacModule = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'modules/identity/wac.bicep')
Assert-Test ($wacModule -match '(?m)^\s*treatFailureAsDeploymentFailure:\s*false\s*$') 'WAC Run Command errors must be reported without failing the overall deployment.'
$scriptSource = Get-Content -Raw -LiteralPath $scriptPath
Assert-Test ($scriptSource.IndexOf('function Set-AMRLDeploymentOperationReport') -lt $scriptSource.IndexOf('# Dot-sourcing loads helpers for local tests without starting setup.')) 'Deployment operation reporting is defined after the script entry point.'
$setupAst = $scriptAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-AMRLSubscriptionSetup' }, $true)
$collectionCalls = @($setupAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -in @('Write-AMRLValidationReport', 'Show-AMRLValidationAfterFailure', 'Show-AMRLGuestCommandResults')
}, $true))
Assert-Test ($collectionCalls.Count -eq 4) 'Expected success and failure diagnostic collection calls were not found.'
foreach ($collectionCall in $collectionCalls) {
    $quietParameters = @($collectionCall.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Quiet'
    })
    Assert-Test ($quietParameters.Count -eq 1) 'Post-deployment diagnostics must be collected quietly for the final report only.'
}
$requiredBicepParameters = @([regex]::Matches((Get-Content -Raw (Join-Path $repoRoot 'main.bicep')), '(?m)^param\s+(\w+)\s+\w+') | ForEach-Object { $_.Groups[1].Value })
foreach ($templatePath in @('main.parameters.example.json', 'main.parameters.demo.json')) {
    $template = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $templatePath) | ConvertFrom-Json
    foreach ($parameterName in $requiredBicepParameters) {
        $parameter = $template.parameters.PSObject.Properties[$parameterName]
        Assert-Test ($null -ne $parameter -and ($null -ne $parameter.Value.PSObject.Properties['value'] -or $null -ne $parameter.Value.PSObject.Properties['reference'])) "$templatePath omits a Bicep parameter value for '$parameterName'."
    }
    foreach ($metadataName in @('azureTenantId', 'azureSubscriptionId', 'githubRepository')) {
        Assert-Test ($null -ne $template.parameters.prefix.metadata.bootstrap.PSObject.Properties[$metadataName]) "$templatePath omits bootstrap metadata '$metadataName'."
    }
}
$exampleTemplate = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'main.parameters.example.json') | ConvertFrom-Json
Assert-Test (@($exampleTemplate.parameters.jumpboxAllowedSources.value) -contains '<YOUR_PUBLIC_IP>/32') 'Example parameter file does not define the replaceable jumpbox IPv4 source.'
$incompleteParametersRejected = $false
try { Assert-AMRLParameterDocumentComplete -Parameters ([pscustomobject]@{ parameters = [pscustomobject]@{ prefix = [pscustomobject]@{ value = 'incomplete' } } }) }
catch { $incompleteParametersRejected = $_.Exception.Message -like '*missing required Bicep parameter values*' }
Assert-Test $incompleteParametersRejected 'An incomplete explicit parameter file was not rejected before setup.'
Assert-AMRLParameterDocumentComplete -Parameters $exampleTemplate
Assert-Test $true 'Complete example parameter file was unexpectedly rejected.'
$gateDeploymentError = @'
ERROR:
{"status":"Failed","error":{"code":"DeploymentFailed","message":"At least one resource deployment operation failed. Correlation ID: 5bbc21d0-354d-443b-a95a-1ce93515a843","details":[{"code":"DeploymentOutputEvaluationFailed","message":"The template output 'gatePassed' is not valid: Deployment blocked by validation enforcement. 4 blocking validation finding(s) detected. Review blockingValidationDetails for full diagnostics."}]}}
'@
$gateDeploymentSummary = Get-AMRLDeploymentFailureSummary -Message $gateDeploymentError
Assert-Test ($gateDeploymentSummary -match '^Deployment blocked by the AMRL validation engine\. 4 blocking validation findings were detected\.') 'Gate failure was not translated into a concise AMRL validation message.'
Assert-Test ($gateDeploymentSummary -match 'Correlation ID: 5bbc21d0-354d-443b-a95a-1ce93515a843' -and $gateDeploymentSummary -notmatch '\{"status"|DeploymentOutputEvaluationFailed') 'Gate failure summary lost its correlation ID or retained raw JSON.'
$resourceDeploymentError = @'
ERROR:
{"status":"Failed","error":{"code":"DeploymentFailed","message":"Deployment operation failed. Correlation ID: 11111111-2222-3333-4444-555555555555","details":[{"code":"QuotaExceeded","message":"The requested VM family quota is unavailable."}]}}
'@
$resourceDeploymentSummary = Get-AMRLDeploymentFailureSummary -Message $resourceDeploymentError
Assert-Test ($resourceDeploymentSummary -eq 'Deployment failed (QuotaExceeded): The requested VM family quota is unavailable. (Correlation ID: 11111111-2222-3333-4444-555555555555)') 'Non-gate ARM failure summary omitted the useful error code, message, or correlation ID.'
$skuOperationError = @'
{"status":"Failed","error":{"code":"InvalidTemplateDeployment","message":"The template deployment 'AMRL-dc02' is not valid. Tracking id is '6f9f8bcd-49e6-44f4-919b-152315888599'. See inner errors.","details":[{"code":"SkuNotAvailable","message":"The requested VM size 'Standard_B2ls_v2' is currently not available in location 'australiasoutheast' due to capacity restrictions. Try another size."}]}}
'@ | ConvertFrom-Json
$skuOperationSummary = Get-AMRLDeploymentOperationErrorSummary -ErrorData $skuOperationError
Assert-Test ($skuOperationSummary -match '^SkuNotAvailable: Standard_B2ls_v2 capacity is unavailable in australiasoutheast\.' -and $skuOperationSummary -match 'Tracking ID: 6f9f8bcd-49e6-44f4-919b-152315888599') 'Nested resource error summary omitted its actionable SKU failure or tracking ID.'
Assert-Test ($skuOperationSummary -notmatch '\{"status"|InvalidTemplateDeployment|inner errors') 'Nested resource error summary retained wrapper JSON.'
foreach ($internalValue in @('FoundationResourceGroup', 'FoundationLocation', 'DeploymentLocation', 'KeyVaultName', 'AutomationIdentityName', 'PublicIp')) {
    Assert-Test ($internalValue -notin $publicParameters) "$internalValue should be resolved from configuration or Azure state, not passed as a bootstrap command parameter."
}

$planDeployRejected = $false
try {
    Invoke-AMRLSubscriptionSetup -Plan -Deploy
}
catch {
    $planDeployRejected = $_.Exception.Message -like '*Plan mode is read-only*'
}
Assert-Test $planDeployRejected 'Plan mode did not reject a conflicting Deploy switch.'

$missingModeRejected = $false
try { Invoke-AMRLBootstrapper }
catch { $missingModeRejected = $_.Exception.Message -like '*Select a run mode*' }
Assert-Test ($missingModeRejected -and $null -eq $script:BootstrapperReport) 'Bootstrapper ran without a mode or initialized a report before rejecting it.'
$conflictingModesRejected = $false
try { Invoke-AMRLBootstrapper -Prepare -Deploy }
catch { $conflictingModesRejected = $_.Exception.Message -like '*mutually exclusive*' }
Assert-Test ($conflictingModesRejected -and $null -eq $script:BootstrapperReport) 'Bootstrapper accepted multiple modes or initialized a report before rejecting them.'

for ($iteration = 0; $iteration -lt 100; $iteration++) {
    $password = New-AMRLPassword
    Assert-Test ($password.Length -eq 28) 'Generated password has an unexpected length.'
    Assert-Test ($password -cmatch '[A-Z]') 'Generated password has no uppercase character.'
    Assert-Test ($password -cmatch '[a-z]') 'Generated password has no lowercase character.'
    Assert-Test ($password -match '[0-9]') 'Generated password has no digit.'
    Assert-Test ($password -match '[^A-Za-z0-9]') 'Generated password has no symbol.'
}

$subject = Get-GitHubSubject `
    -Repository 'andriesdutoit-svg/azure-multiregion-lab' `
    -Branch 'feature/v2.12-subscription-setup-automation'
Assert-Test (
    $subject -eq 'repo:andriesdutoit-svg/azure-multiregion-lab:ref:refs/heads/feature/v2.12-subscription-setup-automation'
) 'GitHub branch subject is not exact.'

$parameterJson = @'
{
  "parameters": {
        "prefix": {
            "value": "AMRL",
            "metadata": {
                "bootstrap": {
                    "azureTenantId": "tenant",
                    "azureSubscriptionId": "sub",
                    "githubRepository": "owner/repository"
                }
            }
        },
        "regionIndexMap": { "value": { "southafricanorth": 1 } },
        "foundationResourceGroup": { "value": "rg" },
        "keyVaultName": { "value": "amrl-kv-test" },
        "jumpboxAllowedSources": { "value": ["<YOUR_PUBLIC_IP>/32"] }
  }
}
'@
$parameters = $parameterJson | ConvertFrom-Json
$updated = Set-AMRLParameterValues `
    -Parameters $parameters `
    -FoundationResourceGroup 'rg' `
    -KeyVaultName 'amrl-kv-test' `
    -PublicIp '203.0.113.12'

Assert-Test ($updated.parameters.foundationResourceGroup.value -eq 'rg') 'foundationResourceGroup was not updated.'
Assert-Test ($updated.parameters.keyVaultName.value -eq 'amrl-kv-test') 'keyVaultName was not updated.'
Assert-Test ($updated.parameters.jumpboxAllowedSources.value[0] -eq '203.0.113.12/32') 'Public IP placeholder was not replaced.'

$explicitParameters = $parameterJson | ConvertFrom-Json
$explicitParameters.parameters.jumpboxAllowedSources.value = @('<YOUR_PUBLIC_IP>/32', '198.51.100.27/32', '192.0.2.0/24')
$preserved = Set-AMRLParameterValues `
    -Parameters $explicitParameters `
    -FoundationResourceGroup 'rg' `
    -KeyVaultName 'amrl-kv-test' `
    -PublicIp '203.0.113.12'
Assert-Test ($preserved.parameters.jumpboxAllowedSources.value.Count -eq 3) 'Placeholder replacement dropped or merged explicit source ranges.'
Assert-Test ($preserved.parameters.jumpboxAllowedSources.value[0] -eq '203.0.113.12/32') 'Public IP placeholder was not replaced in place.'
Assert-Test ($preserved.parameters.jumpboxAllowedSources.value[1] -eq '198.51.100.27/32') 'Existing source range changed.'

$promptHost = Get-Command Read-Host -CommandType Function -ErrorAction SilentlyContinue
$script:promptCount = 0
$script:promptMessages = New-Object 'System.Collections.Generic.List[string]'
$script:useGitHubPromptValues = $false
$script:wizardAnswers = @{}
# Exercise wizard defaults, stage-specific prompts, invalid-answer retries, explicit-file behavior,
# and JSON round-tripping without opening an interactive console or writing Azure resources.
function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    $script:promptCount++
    $script:promptMessages.Add($Prompt)
    foreach ($promptPrefix in $script:wizardAnswers.Keys) {
        if ($Prompt.StartsWith($promptPrefix) -and $script:wizardAnswers[$promptPrefix].Count -gt 0) {
            return $script:wizardAnswers[$promptPrefix].Dequeue()
        }
    }
    if ($script:useGitHubPromptValues -and $Prompt -like 'GitHub repository*') { return 'owner/repository' }
    if ($script:useGitHubPromptValues -and $Prompt -like 'Entra app display name for GitHub OIDC*') { return 'AMRL-test-github' }
    return ''
}
function Get-AMRLFoundationLocationChoices { return @('westeurope', 'southafricanorth', 'eastus') }
$planParameterPath = Join-Path ([System.IO.Path]::GetTempPath()) ('amrl-plan-' + [guid]::NewGuid().ToString('N') + '.json')
$explicitParameterPath = Join-Path ([System.IO.Path]::GetTempPath()) ('amrl-explicit-' + [guid]::NewGuid().ToString('N') + '.json')
$oldPlanMode = $script:PlanMode
$oldInteractiveConfiguration = $script:InteractiveConfiguration
$script:PlanMode = $true
$script:InteractiveConfiguration = $true
try {
    $planDocument = Get-ParameterDocument -Path $planParameterPath
    Assert-Test ($script:promptCount -eq 17) 'Parameter wizard did not prompt for the selected settings and six individual VM counts.'
    $formattedParameterJson = ConvertTo-AMRLParameterJson -InputObject $planDocument
    $formattedLines = $formattedParameterJson -split "`r?`n"
    Assert-Test (@($formattedLines | Where-Object { (($_.Length - $_.TrimStart().Length) % 2) -ne 0 }).Count -eq 0) 'Parameter JSON indentation is not consistently two-space based.'
    Assert-Test ($formattedParameterJson -notmatch '":  ') 'Parameter JSON contains excessive spacing after property separators.'
    $formattedDocument = $formattedParameterJson | ConvertFrom-Json
    $expectedCanonical = ConvertTo-Json -InputObject $planDocument -Depth 100 -Compress
    $actualCanonical = ConvertTo-Json -InputObject $formattedDocument -Depth 100 -Compress
    Assert-Test ($actualCanonical -ceq $expectedCanonical) 'Parameter JSON formatting changed its values or types.'
    Assert-Test ((@(Get-AMRLFoundationLocationChoices) -join ',') -eq 'westeurope,southafricanorth,eastus') 'Wizard did not retain the Azure-listed foundation location choices.'
    Assert-Test (@($script:promptMessages | Where-Object { $_ -like '*foundation location*' }).Count -eq 0) 'Parameter-document parsing prompted for Azure location before resource state was inspected.'
    $integerPromptCount = @($script:promptMessages | Where-Object { $_ -match '^(Region count|maxVmsPerRegion|departmentCount|usersPerDepartment|VM count for )' }).Count
    Assert-Test ($integerPromptCount -eq 10) 'Numeric prompts were not all presented.'
    $maximumMappedRegions = @($planDocument.parameters.regionIndexMap.value.PSObject.Properties).Count
    $maximumDefinedDepartments = @($planDocument.parameters.sysAdminDepartment.value.PSObject.Properties).Count + @($planDocument.parameters.additionalDepartments.value.PSObject.Properties).Count
    Assert-Test (@($script:promptMessages | Where-Object { $_ -like "Region count (Allowed: whole number, 1 or greater; maximum $maximumMappedRegions mapped regions)*" }).Count -eq 1) 'Region-count prompt did not show its minimum and mapped-region maximum.'
    Assert-Test (@($script:promptMessages | Where-Object { $_ -like 'maxVmsPerRegion (Allowed: whole number, 1 or greater)*' }).Count -eq 1) 'maxVmsPerRegion prompt did not show its minimum.'
    Assert-Test (@($script:promptMessages | Where-Object { $_ -like 'usersPerDepartment (Allowed: whole number, 1 or greater)*' }).Count -eq 1) 'usersPerDepartment prompt did not show its minimum.'
    Assert-Test (@($script:promptMessages | Where-Object { $_ -like "departmentCount (Allowed: *maximum $maximumDefinedDepartments defined departments)*" }).Count -eq 1) 'Department-count prompt did not show the defined-department maximum.'
    Assert-Test (@($script:promptMessages | Where-Object { $_ -like 'Network mode (Allowed: fullMesh, hubSpoke, hubSpokeFirewall)*' }).Count -eq 1) 'Network-mode prompt did not show its options.'
    Assert-Test (@($script:promptMessages | Where-Object { $_ -like 'Validation mode (Allowed: reportOnly, enforce)*' }).Count -eq 1) 'Validation-mode prompt did not show its options.'
    Assert-Test (@($script:promptMessages | Where-Object { $_ -like 'Randomly generate missing administrator passwords?*' }).Count -eq 0) 'Parameter wizard asked about passwords before inspecting Key Vault.'
    Assert-Test (-not $script:PromptForPasswords) 'Default password mode should generate missing passwords automatically.'
    foreach ($role in @('dc', 'jumpbox')) {
        Assert-Test (@($script:promptMessages | Where-Object { $_ -like "VM count for $role (Allowed: whole number, minimum 1)*" }).Count -eq 1) "$role prompt did not indicate a minimum of 1."
    }
    Assert-Test (@($script:promptMessages | Where-Object { $_ -like '*Regions selected from regionIndexMap*' }).Count -eq 0) 'Wizard listed parameter-file regions before foundation location setup.'
    Assert-Test (@($script:promptMessages | Where-Object { $_ -like '*(Allowed: y/N)*' }).Count -eq 3) 'Boolean prompts did not use the concise y/N hint.'
    Assert-Test (-not (Test-Path -LiteralPath $planParameterPath)) 'Plan mode wrote the local parameter file.'
    Assert-Test ($planDocument.parameters.prefix.value -eq 'AMRL') 'Demo prefix default was changed.'
    Assert-Test ($planDocument.parameters.regionCount.value -eq 3) 'Demo region count was changed.'
    Assert-Test ($planDocument.parameters.networkMode.value -eq 'fullMesh') 'Demo network mode was changed.'
    Assert-Test ($planDocument.parameters.vmCounts.value.dc -eq 1) 'Demo VM counts were changed.'
    $firstMappedRegion = [string](@($planDocument.parameters.regionIndexMap.value.PSObject.Properties | Sort-Object { [int]$_.Value })[0].Name)
    Assert-Test ((Get-AMRLFoundationLocation -Parameters $planDocument) -eq $firstMappedRegion) 'Foundation location was not derived from the first regionIndexMap entry.'
    Assert-Test ($null -eq $planDocument.parameters.prefix.metadata.bootstrap.PSObject.Properties['foundationLocation']) 'Derived foundation location was persisted in bootstrap metadata.'
    foreach ($setting in @('maxVmsPerRegion', 'validationMode', 'departmentCount', 'usersPerDepartment', 'useDedicatedFileServer', 'enableWindowsAdminCenter', 'useDedicatedWacHost')) {
        $demoDocument = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'main.parameters.demo.json') | ConvertFrom-Json
        Assert-Test ($planDocument.parameters.$setting.value -ceq $demoDocument.parameters.$setting.value) "Accepting the default changed $setting."
    }
    $selectedRegionIndexes = @($planDocument.parameters.regionIndexMap.value.PSObject.Properties | Sort-Object { [int]$_.Value } | Select-Object -First 3 | ForEach-Object { [int]$_.Value })
    Assert-Test (($selectedRegionIndexes -join ',') -eq '1,2,3') 'Interactive region-count selection changed address indexes.'

    [System.IO.File]::WriteAllText($explicitParameterPath, $parameterJson, [System.Text.UTF8Encoding]::new($false))
    $script:InteractiveConfiguration = $false
    $promptsBeforeExplicitFile = $script:promptCount
    $explicitDocument = Get-ParameterDocument -Path $explicitParameterPath
    Assert-Test ($script:promptCount -eq $promptsBeforeExplicitFile) 'An explicit parameter file unexpectedly launched topology prompts.'
    Assert-Test ($explicitDocument.parameters.jumpboxAllowedSources.value[0] -eq '<YOUR_PUBLIC_IP>/32') 'Explicit parameter file values were not preserved.'
    Assert-Test ((Get-AMRLFoundationLocation -Parameters $explicitDocument) -eq $firstMappedRegion) 'An explicit parameter file without a location override did not use the first regionIndexMap entry.'

    $explicitDocument.parameters.prefix.metadata.bootstrap.PSObject.Properties.Remove('githubRepository')
    [System.IO.File]::WriteAllText($explicitParameterPath, (ConvertTo-AMRLParameterJson -InputObject $explicitDocument))
    $promptsBeforeMissingGitHubValues = $script:promptCount
    $missingGitHubValuesRejected = $false
    try { Get-ParameterDocument -Path $explicitParameterPath -IncludeGitHub | Out-Null }
    catch { $missingGitHubValuesRejected = $_.Exception.Message -like '*must define prefix.metadata.bootstrap.githubRepository*' }
    Assert-Test $missingGitHubValuesRejected 'Explicit GitHub setup silently replaced missing parameter-file values.'
    Assert-Test ($script:promptCount -eq $promptsBeforeMissingGitHubValues) 'Missing explicit GitHub values triggered an interactive prompt.'

    $explicitDocument.parameters.prefix.metadata.bootstrap | Add-Member -NotePropertyName githubRepository -NotePropertyValue 'file-owner/file-repository' -Force
    $explicitDocument.parameters.prefix.metadata.bootstrap.githubRepository = 'file-owner/file-repository'
    [System.IO.File]::WriteAllText($explicitParameterPath, (ConvertTo-AMRLParameterJson -InputObject $explicitDocument))
    $promptsBeforeExplicitGitHub = $script:promptCount
    $explicitGitHubDocument = Get-ParameterDocument -Path $explicitParameterPath -IncludeGitHub
    Assert-Test ($script:promptCount -eq $promptsBeforeExplicitGitHub) 'GitHub settings were prompted despite an explicit parameter file.'
    Assert-Test ($explicitGitHubDocument.parameters.prefix.metadata.bootstrap.githubRepository -eq 'file-owner/file-repository') 'Explicit GitHub repository value was not taken from the parameter file.'
    Assert-Test ($null -eq $explicitGitHubDocument.parameters.prefix.metadata.bootstrap.PSObject.Properties['githubAppDisplayName']) 'GitHub app display name was persisted in bootstrap metadata.'

    Assert-Test ((Get-AMRLFoundationLocation -Parameters $explicitGitHubDocument) -eq $firstMappedRegion) 'Foundation location did not remain derived from regionIndexMap.'

    $script:InteractiveConfiguration = $true
    $promptsBeforeGitHub = $script:promptCount
    $githubDocument = Get-ParameterDocument -Path $planParameterPath -IncludeGitHub
    Assert-Test ($script:promptCount -eq ($promptsBeforeGitHub + 18)) 'GitHub settings were not prompted only when -IncludeGitHub was specified.'
    Assert-Test (@($script:promptMessages | Where-Object { $_ -like 'GitHub repository (Allowed: exact full repository name)*' }).Count -gt 0) 'GitHub repository prompt did not use the concise exact-name hint.'
    Assert-Test ($null -eq $githubDocument.PSObject.Properties['metadata']) 'Bootstrap metadata was added as an unsupported root property.'
    Assert-Test ($githubDocument.parameters.prefix.metadata.bootstrap.githubRepository -eq 'andriesdutoit-svg/azure-multiregion-lab') 'GitHub repository did not default from the parameter template.'
    Assert-Test ($null -eq $githubDocument.parameters.prefix.metadata.bootstrap.PSObject.Properties['githubAppDisplayName']) 'GitHub app display name was persisted in bootstrap metadata.'
    Assert-Test ((Get-AMRLDefault 'githubAppDisplayName') -eq 'AMRL-github-actions') 'GitHub app display name did not come from AMRL defaults.'

    $script:useGitHubPromptValues = $true
    $promptsBeforeGitHubOverride = $script:promptCount
    $githubOverrideDocument = Get-ParameterDocument -Path $planParameterPath -IncludeGitHub
    Assert-Test ($script:promptCount -eq ($promptsBeforeGitHubOverride + 18)) 'GitHub wizard did not ask for its repository setting.'
    Assert-Test ($githubOverrideDocument.parameters.prefix.metadata.bootstrap.githubRepository -eq 'owner/repository') 'Wizard repository choice did not override the template default.'
    Assert-Test ((Get-AMRLDefault 'githubAppDisplayName') -eq 'AMRL-github-actions') 'GitHub app display name did not remain sourced from AMRL defaults.'

    $script:PlanMode = $false
    $script:useGitHubPromptValues = $false
    $savedGitHubDocument = Get-ParameterDocument -Path $planParameterPath -IncludeGitHub
    $savedGitHubDocument = Get-Content -Raw -LiteralPath $planParameterPath | ConvertFrom-Json
    Assert-Test ($savedGitHubDocument.parameters.prefix.metadata.bootstrap.githubRepository -eq 'andriesdutoit-svg/azure-multiregion-lab') 'Template GitHub repository default was not saved to the local file.'
    Assert-Test ($null -eq $savedGitHubDocument.parameters.prefix.metadata.bootstrap.PSObject.Properties['githubAppDisplayName']) 'GitHub app display name was saved in bootstrap metadata.'

    $script:wizardAnswers = @{
        'Validation mode' = [System.Collections.Generic.Queue[string]]::new([string[]]@('invalid'))
        'Region count' = [System.Collections.Generic.Queue[string]]::new([string[]]@('-1', '0', '3'))
        'maxVmsPerRegion ' = [System.Collections.Generic.Queue[string]]::new([string[]]@('four', '-1', '0', '4'))
        'departmentCount ' = [System.Collections.Generic.Queue[string]]::new([string[]]@('-1', '12'))
        'usersPerDepartment ' = [System.Collections.Generic.Queue[string]]::new([string[]]@('-5', '0', '5'))
        'VM count for dc' = [System.Collections.Generic.Queue[string]]::new([string[]]@('-2', '1'))
        'useDedicatedFileServer ' = [System.Collections.Generic.Queue[string]]::new([string[]]@('N'))
        'enableWindowsAdminCenter ' = [System.Collections.Generic.Queue[string]]::new([string[]]@('y'))
        'useDedicatedWacHost ' = [System.Collections.Generic.Queue[string]]::new([string[]]@('yes'))
    }
    $promptsBeforeInvalidValues = $script:promptCount
    $customDocument = Get-ParameterDocument -Path $planParameterPath
    $savedDocument = Get-Content -Raw -LiteralPath $planParameterPath | ConvertFrom-Json
    Assert-Test ($customDocument.parameters.departmentCount.value -eq 12) 'Wizard output object did not retain the accepted department count.'
    Assert-Test ($script:promptCount -eq ($promptsBeforeInvalidValues + 26)) 'Invalid numeric or boolean input did not repeat the prompt until an accepted value was entered.'
    Assert-Test ($savedDocument.parameters.regionCount.value -eq 3) 'Wizard did not retry a negative region count.'
    Assert-Test ($savedDocument.parameters.validationMode.value -ceq 'invalid') 'Wizard did not defer validation of the selected validation mode.'
    foreach ($setting in @('maxVmsPerRegion', 'departmentCount', 'usersPerDepartment')) {
        $expectedCount = @{ maxVmsPerRegion = 4; departmentCount = 12; usersPerDepartment = 5 }[$setting]
        Assert-Test ($savedDocument.parameters.$setting.value -eq $expectedCount) "Wizard did not save the selected $setting after retrying invalid input."
        Assert-Test ($savedDocument.parameters.$setting.value -is [int]) "Wizard saved $setting as a non-integer."
    }
    Assert-Test ($savedDocument.parameters.vmCounts.value.dc -eq 1) 'Wizard did not retry a negative VM count.'
    Assert-Test (-not $script:PasswordChoiceMade) 'Parameter parsing chose password handling before checking existing secrets.'
    Assert-Test ($savedDocument.parameters.useDedicatedFileServer.value -eq $false) 'Wizard did not accept N as a boolean answer.'
    foreach ($setting in @('enableWindowsAdminCenter', 'useDedicatedWacHost')) {
        Assert-Test ($savedDocument.parameters.$setting.value -is [bool] -and $savedDocument.parameters.$setting.value) "Wizard did not save $setting as boolean true."
    }
    $script:wizardAnswers = @{}
    $retainedDocument = Get-ParameterDocument -Path $planParameterPath
    Assert-Test ($retainedDocument.parameters.departmentCount.value -eq 12) 'Wizard did not reuse the existing department count as a default.'
    Assert-Test ($retainedDocument.parameters.useDedicatedWacHost.value -eq $true) 'Wizard did not reuse the existing boolean as a default.'
}
finally {
    $script:wizardAnswers = @{}
    $script:useGitHubPromptValues = $false
    $script:PlanMode = $oldPlanMode
    $script:InteractiveConfiguration = $oldInteractiveConfiguration
    Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    if ($null -ne $promptHost) {
        Set-Item Function:\Read-Host -Value $promptHost.ScriptBlock
    }
    if (Test-Path -LiteralPath $planParameterPath) {
        Remove-Item -LiteralPath $planParameterPath -Force
    }
    if (Test-Path -LiteralPath $explicitParameterPath) {
        Remove-Item -LiteralPath $explicitParameterPath -Force
    }
}

$mismatchRejected = $false
try {
    Set-AMRLParameterValues `
        -Parameters $explicitParameters `
        -FoundationResourceGroup 'rg' `
        -KeyVaultName 'other-kv' `
        -IdentityId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/amrl-mi' `
        -PublicIp '203.0.113.12' | Out-Null
}
catch {
    $mismatchRejected = $true
}
Assert-Test $mismatchRejected 'A mismatched existing Key Vault reference was not rejected.'

# Mock Azure/GitHub calls for subscription planning and OIDC setup. The assertions verify the exact
# operations and trust subjects while ensuring read-only readiness never creates credentials.
$script:cliCalls = New-Object 'System.Collections.Generic.List[object]'
$script:tsvCalls = New-Object 'System.Collections.Generic.List[object]'
$script:roleAssignmentState = 'missing'
$script:mockMode = 'default'
$script:federatedCredentialState = @()
$script:createdCredential = $null

function Get-AzTsv {
    param([string[]]$Arguments)
    $script:tsvCalls.Add(@($Arguments))
    if ($script:mockMode -eq 'plan') {
        if ($Arguments[0] -eq 'provider') { return 'NotRegistered' }
        if ($Arguments[0] -eq 'group') { return 'false' }
        if ($Arguments[0] -eq 'ad') { return 'test-user' }
    }
    if ($script:roleAssignmentState -eq 'present') { return '/subscriptions/test/providers/Microsoft.Authorization/roleAssignments/existing' }
    return ''
}

function Get-AzJson {
    param([string[]]$Arguments)
    if ($Arguments[0] -eq 'rest') { return [pscustomobject]@{ nameAvailable = $true } }
    if ($script:mockMode -eq 'github') {
        if ($Arguments -contains 'federated-credential') { return $script:federatedCredentialState }
        if ($Arguments -contains 'app') { return [pscustomobject]@{ id = 'app-object-id'; appId = 'app-client-id' } }
        if ($Arguments -contains 'sp') { return [pscustomobject]@{ id = 'service-principal-id' } }
        throw "Unexpected GitHub setup lookup: $($Arguments -join ' ')"
    }
    return $script:federatedCredentialState
}

function Invoke-AzCli {
    param([string[]]$Arguments)
    $script:cliCalls.Add(@($Arguments))
    if ($Arguments -contains 'federated-credential' -and $Arguments -contains 'create') {
        $credentialPath = $Arguments[$Arguments.IndexOf('--parameters') + 1]
        $script:createdCredential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
        if ($script:mockMode -eq 'github') {
            $script:federatedCredentialState += $script:createdCredential
        }
    }
    return ''
}

$script:mockMode = 'plan'
$planParameters = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'main.parameters.demo.json') | ConvertFrom-Json
Invoke-AMRLPlan `
    -Context ([pscustomobject]@{ id = 'dbdbac44-21b7-4f4c-9c9d-c5082377d80f'; tenantId = 'tenant-id'; name = 'Test subscription' }) `
    -Parameters $planParameters `
    -ResourceGroup 'amrl-foundation-rg' `
    -FoundationLocation 'westeurope' `
    -IdentityName 'amrl-deployment-mi' `
    -DeploymentLocation 'westeurope' | Out-Null
Assert-Test (@($script:cliCalls | Where-Object { $_[0] -ne 'bicep' -or $_[1] -notin @('build', 'lint') }).Count -eq 0) 'Plan with missing prerequisites invoked a mutating Azure CLI command.'
$script:cliCalls.Clear()
$script:mockMode = 'default'

Set-AMRLRoleAssignmentIfMissing `
    -AssigneeObjectId '11111111-1111-1111-1111-111111111111' `
    -PrincipalType ServicePrincipal `
    -Role 'Network Contributor' `
    -Scope '/subscriptions/test' | Out-Null
Assert-Test ($script:cliCalls.Count -eq 1) 'A missing role assignment was not created.'
Assert-Test (($script:cliCalls[0] -join ' ') -match 'role assignment create') 'Unexpected Azure CLI call for role assignment.'
 $roleLookup = @($script:tsvCalls | Where-Object { $_[0] -eq 'role' -and $_[1] -eq 'assignment' -and $_[2] -eq 'list' })[-1]
Assert-Test ($roleLookup -notcontains '--assignee' -and ($roleLookup -join ' ') -match "principalId=='11111111-1111-1111-1111-111111111111'") 'Role assignment lookup still depends on Entra Graph assignee resolution.'
Assert-Test (@($script:tsvCalls | Where-Object { $_[0] -eq 'role' -and $_[1] -eq 'assignment' -and $_[2] -eq 'list' -and $_ -contains '--all' }).Count -eq 0) 'Scoped role-assignment lookup combined --scope with incompatible --all.'

$script:cliCalls.Clear()
$script:roleAssignmentState = 'present'
Set-AMRLRoleAssignmentIfMissing `
    -AssigneeObjectId '11111111-1111-1111-1111-111111111111' `
    -PrincipalType ServicePrincipal `
    -Role 'Network Contributor' `
    -Scope '/subscriptions/test' | Out-Null
Assert-Test ($script:cliCalls.Count -eq 0) 'An existing role assignment was duplicated.'

$script:roleAssignmentState = 'missing'
New-AMRLFederatedCredentialIfMissing `
    -AppObjectId '22222222-2222-2222-2222-222222222222' `
    -Name 'github-actions-test-branch' `
    -Subject 'repo:owner/repository:ref:refs/heads/feature/test' `
    -Description 'Test branch' | Out-Null
Assert-Test ($script:cliCalls.Count -eq 1) 'Missing federated credential was not created.'
Assert-Test ($script:createdCredential.name -eq 'github-actions-test-branch') 'Federated credential name changed.'
Assert-Test ($script:createdCredential.issuer -eq 'https://token.actions.githubusercontent.com') 'Federated credential issuer is incorrect.'
Assert-Test ($script:createdCredential.subject -eq 'repo:owner/repository:ref:refs/heads/feature/test') 'Federated credential subject is incorrect.'
Assert-Test ($script:createdCredential.audiences[0] -eq 'api://AzureADTokenExchange') 'Federated credential audience is incorrect.'

$script:cliCalls.Clear()
$script:federatedCredentialState = @($script:createdCredential)
New-AMRLFederatedCredentialIfMissing `
    -AppObjectId '22222222-2222-2222-2222-222222222222' `
    -Name 'github-actions-test-branch' `
    -Subject 'repo:owner/repository:ref:refs/heads/feature/test' `
    -Description 'Test branch' | Out-Null
Assert-Test ($script:cliCalls.Count -eq 0) 'An existing federated credential was duplicated.'

$originalGit = Get-Command git -CommandType Function -ErrorAction SilentlyContinue
$originalGh = Get-Command gh -CommandType Function -ErrorAction SilentlyContinue
$originalInvokeGhCli = (Get-Command Invoke-GhCli).ScriptBlock
$script:mockGitBranch = 'feature/test'
$script:githubVariableSetCalls = New-Object 'System.Collections.Generic.List[object]'
function git {
    $global:LASTEXITCODE = 0
    return $script:mockGitBranch
}
function gh { }
function Invoke-GhCli {
    param([string[]]$Arguments)
    if ($Arguments[0] -eq 'variable' -and $Arguments[1] -eq 'set') { $script:githubVariableSetCalls.Add(@($Arguments)) }
    if ($Arguments[0] -eq 'repo') { return 'ADMIN' }
    if ($Arguments[1] -eq 'list') {
        if ($Arguments[0] -eq 'secret') {
            return (@('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID') | ForEach-Object { @{ name = $_ } } | ConvertTo-Json -Compress)
        }
        return (@(
            @{ name = 'KEYVAULT_NAME'; value = $githubSetupArguments.VaultName }
            @{ name = 'YOUR_PUBLIC_IP'; value = '203.0.113.12' }
        ) | ConvertTo-Json -Compress)
    }
    return ''
}
$githubSetupArguments = @{
    TenantId = 'tenant-id'
    SubscriptionId = 'subscription-id'
    VaultId = '/subscriptions/test/resourceGroups/foundation/providers/Microsoft.KeyVault/vaults/test'
    VaultName = 'test'
    IdentityId = '/subscriptions/test/resourceGroups/foundation/providers/Microsoft.ManagedIdentity/userAssignedIdentities/test'
    Repository = 'owner/repository'
    AppDisplayName = 'AMRL-test-github'
}
$githubSetupArguments.PublicIp = Get-AMRLParameterFilePublicIp -Parameters ([pscustomobject]@{ parameters = [pscustomobject]@{ jumpboxAllowedSources = [pscustomobject]@{ value = @('203.0.113.12/32') } } })
Assert-Test ($githubSetupArguments.PublicIp -eq '203.0.113.12') 'GitHub public IP was not derived from jumpboxAllowedSources in the parameter file.'
$script:mockMode = 'github'
$script:roleAssignmentState = 'present'
$script:federatedCredentialState = @()
$script:cliCalls.Clear()
try {
    Set-AMRLGitHubConfiguration @githubSetupArguments
    Assert-Test (@($script:githubVariableSetCalls | Where-Object { $_[2] -eq 'YOUR_PUBLIC_IP' -and $_[4] -eq '203.0.113.12' }).Count -eq 1) 'GitHub setup did not set its missing IP variable from the parameter-file /32.'
    Assert-Test (@($script:githubVariableSetCalls | Where-Object { $_[2] -eq 'KEYVAULT_NAME' -and $_[4] -eq 'test' }).Count -eq 1) 'GitHub setup did not set the Key Vault name variable.'
    $expectedSubjects = @(
        'repo:owner/repository:ref:refs/heads/main'
        'repo:owner/repository:ref:refs/heads/feature/test'
        'repo:owner/repository:pull_request'
    )
    Assert-Test ($script:federatedCredentialState.Count -eq 3) 'GitHub setup did not create all three documented federated credentials.'
    foreach ($expectedSubject in $expectedSubjects) {
        $matchingCredentials = @($script:federatedCredentialState | Where-Object { $_.subject -ceq $expectedSubject })
        Assert-Test ($matchingCredentials.Count -eq 1) "GitHub setup did not create exactly one credential for $expectedSubject."
        Assert-Test ($matchingCredentials[0].issuer -eq 'https://token.actions.githubusercontent.com') 'GitHub setup used the wrong OIDC issuer.'
        Assert-Test (($matchingCredentials[0].audiences -join ',') -eq 'api://AzureADTokenExchange') 'GitHub setup used the wrong OIDC audience.'
    }

    $script:cliCalls.Clear()
    Set-AMRLGitHubConfiguration @githubSetupArguments
    Assert-Test ($script:cliCalls.Count -eq 0) 'Repeating GitHub setup recreated existing federated credentials.'

    $script:mockGitBranch = 'main'
    $script:federatedCredentialState = @()
    Set-AMRLGitHubConfiguration @githubSetupArguments
    Assert-Test ($script:federatedCredentialState.Count -eq 2) 'GitHub setup on main did not create exactly the main and pull-request credentials.'
    Assert-Test (@($script:federatedCredentialState | Where-Object { $_.subject -ceq $expectedSubjects[0] }).Count -eq 1) 'GitHub setup duplicated or omitted the main credential when the active branch was main.'
    Assert-Test (@($script:federatedCredentialState | Where-Object { $_.subject -ceq $expectedSubjects[2] }).Count -eq 1) 'GitHub setup on main omitted the pull-request credential.'
    $script:federatedCredentialState[0].issuer = 'https://untrusted.example'
    $readiness = Get-AMRLGitHubReadiness -Repository $githubSetupArguments.Repository -AppDisplayName $githubSetupArguments.AppDisplayName -SubscriptionId $githubSetupArguments.SubscriptionId -VaultId $githubSetupArguments.VaultId -IdentityId $githubSetupArguments.IdentityId
    Assert-Test ($readiness.Blockers.Count -eq 1 -and $readiness.Blockers[0] -like '*issuer/audience*') 'GitHub readiness did not reject a conflicting credential issuer.'
    $conflictingCredentialRejected = $false
    try { New-AMRLFederatedCredentialIfMissing -AppObjectId 'app-object-id' -Name 'github-actions-main' -Subject $expectedSubjects[0] -Description 'Main' }
    catch { $conflictingCredentialRejected = $_.Exception.Message -like '*issuer/audience*' }
    Assert-Test $conflictingCredentialRejected 'GitHub setup silently reused a conflicting credential.'
    $script:federatedCredentialState = @()
    $script:cliCalls.Clear()
    $readiness = Get-AMRLGitHubReadiness -Repository $githubSetupArguments.Repository -AppDisplayName $githubSetupArguments.AppDisplayName -SubscriptionId $githubSetupArguments.SubscriptionId
    Assert-Test ($readiness.Actions.Count -eq 2 -and $script:cliCalls.Count -eq 0) 'Read-only GitHub readiness did not report both missing credentials without creating them.'
    function Invoke-GhCli {
        param([string[]]$Arguments)
        if ($Arguments[0] -eq 'repo') { return 'ADMIN' }
        if ($Arguments[1] -eq 'list') { return '[]' }
        return ''
    }
    $readiness = Get-AMRLGitHubReadiness -Repository $githubSetupArguments.Repository -AppDisplayName $githubSetupArguments.AppDisplayName -SubscriptionId $githubSetupArguments.SubscriptionId
    Assert-Test (@($readiness.Actions | Where-Object { $_ -like '*Actions secret*' }).Count -eq 3) 'GitHub readiness did not identify missing secret names.'
    Assert-Test (@($readiness.Actions | Where-Object { $_ -like '*Actions variable*' }).Count -eq 2) 'GitHub readiness did not identify the missing Key Vault name and public IP variables.'
}
finally {
    $script:mockMode = 'default'
    Remove-Item Function:\git, Function:\gh
    if ($null -ne $originalGit) { Set-Item Function:\git -Value $originalGit.ScriptBlock }
    if ($null -ne $originalGh) { Set-Item Function:\gh -Value $originalGh.ScriptBlock }
    Set-Item Function:\Invoke-GhCli -Value $originalInvokeGhCli
}

# Validate extraction and display of root/nested validation outputs, including incomplete outputs,
# report-only versus enforce decisions, and the rule that missing findings are not a clean pass.
$sampleDeployment = [pscustomobject]@{
    name = 'amrl-20261028-120000'
    properties = [pscustomobject]@{
        outputs = [pscustomobject]@{
            validationSummary = [pscustomobject]@{ value = 'All validation checks passed.' }
            blockingValidationSummary = [pscustomobject]@{ value = 'No blocking findings.' }
            enforcementEnabled = [pscustomobject]@{ value = $false }
            hasBlockingValidationFailures = [pscustomobject]@{ value = $false }
            shouldBlockDeployment = [pscustomobject]@{ value = $false }
            deploymentBlockMessage = [pscustomobject]@{ value = 'Deployment not blocked.' }
            validationFlags = [pscustomobject]@{ value = [pscustomobject]@{ hasNoJumpboxes = $false } }
            blockingValidationDetails = [pscustomobject]@{ value = @() }
            advisoryValidationDetails = [pscustomobject]@{ value = @([pscustomobject]@{ flag = 'windowsAdminCenterSkippedForStage'; message = 'WAC is skipped.'; remediation = 'Run identity.' }) }
            capacityCheck = [pscustomobject]@{ value = [pscustomobject]@{ totalVMs = 2; capacity = 6; withinLimit = $true } }
            vmPlacement = [pscustomobject]@{ value = @([pscustomobject]@{ name = 'AMRL-dc01'; type = 'dc'; regionKey = 'westeurope'; index = 0 }) }
        }
    }
}
$report = Get-AMRLValidationReport -Deployment $sampleDeployment
Assert-Test ($report.Summary -eq 'All validation checks passed.') 'Root deployment validation summary was not extracted.'
Assert-Test ($report.Blocking.Count -eq 0) 'Unexpected blocking validation results were extracted.'
Assert-Test ($report.Advisory.Count -eq 1) 'Advisory validation results were not extracted.'
Assert-Test ($report.Capacity.withinLimit) 'Capacity output was not extracted.'
Assert-Test ($report.Placements[0].name -eq 'AMRL-dc01') 'Placement output was not extracted.'
Assert-Test ($report.FindingsAvailable) 'Complete findings were marked unavailable.'
Assert-Test ($report.EnforcementEnabled -eq $false -and $report.ShouldBlockDeployment -eq $false) 'Report-only enforcement outputs were lost.'

foreach ($missingDeployment in @($null, [pscustomobject]@{}, [pscustomobject]@{ properties = [pscustomobject]@{} }, [pscustomobject]@{ properties = [pscustomobject]@{ outputs = $null } })) {
    Assert-Test ($null -eq (Get-AMRLValidationReport -Deployment $missingDeployment)) 'An absent output envelope was treated as a validation report.'
}
$partialDeployment = [pscustomobject]@{ name = 'partial'; properties = [pscustomobject]@{ outputs = [pscustomobject]@{ validationSummary = [pscustomobject]@{ value = 'Partial summary' } } } }
$partialReport = Get-AMRLValidationReport -Deployment $partialDeployment
Assert-Test (-not $partialReport.FindingsAvailable) 'Partial outputs were treated as complete findings.'
Assert-Test ($partialReport.Blocking.Count -eq 0 -and $partialReport.Advisory.Count -eq 0 -and $partialReport.Placements.Count -eq 0) 'Missing collections were represented by null entries.'
$partialWarnings = @()
Write-AMRLValidationReport -Deployment $partialDeployment -WarningVariable partialWarnings -WarningAction SilentlyContinue
Assert-Test (@($partialWarnings | Where-Object { $_ -like '*unavailable or incomplete*' }).Count -eq 1) 'Partial reporting did not warn that findings were unavailable.'

$nestedDeployment = [pscustomobject]@{
    name = 'AMRL-validation-engine-amrl-20261028-12'
    properties = [pscustomobject]@{
        outputs = [pscustomobject]@{
            validationMessage = [pscustomobject]@{ value = 'Deployment blocked by validation enforcement.' }
            enforcementEnabled = [pscustomobject]@{ value = $true }
            hasBlockingValidationFailures = [pscustomobject]@{ value = $true }
            shouldBlockDeployment = [pscustomobject]@{ value = $true }
            deploymentBlockMessage = [pscustomobject]@{ value = 'Deployment blocked by validation enforcement.' }
            blockingValidationDetails = [pscustomobject]@{ value = @([pscustomobject]@{ flag = 'hasNoJumpboxes'; message = 'No jumpbox.'; remediation = 'Request a jumpbox.' }) }
            advisoryValidationDetails = [pscustomobject]@{ value = @() }
        }
    }
}
$nestedReport = Get-AMRLValidationReport -Deployment $nestedDeployment
Assert-Test ($nestedReport.Summary -eq 'Deployment blocked by validation enforcement.') 'Nested validation message was not used as the report summary.'
Assert-Test ($nestedReport.Blocking[0].flag -eq 'hasNoJumpboxes') 'Nested blocking details were not extracted.'
Assert-Test ($nestedReport.EnforcementEnabled -and $nestedReport.HasBlockingFailures -and $nestedReport.ShouldBlockDeployment) 'Enforcement decision outputs were not extracted.'
Assert-Test ($nestedReport.DeploymentBlockMessage -eq 'Deployment blocked by validation enforcement.') 'Enforcement block message was not extracted.'
$reportOnlyDeployment = $nestedDeployment | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$reportOnlyDeployment.properties.outputs.enforcementEnabled.value = $false
$reportOnlyDeployment.properties.outputs.shouldBlockDeployment.value = $false
$reportOnlyDeployment.properties.outputs.deploymentBlockMessage.value = 'Deployment not blocked.'
$reportOnlyReport = Get-AMRLValidationReport -Deployment $reportOnlyDeployment
Assert-Test ($reportOnlyReport.HasBlockingFailures -and -not $reportOnlyReport.ShouldBlockDeployment) 'Report-only mode lost the distinction between blocking findings and enforcement.'
Write-AMRLValidationReport -Deployment $reportOnlyDeployment
$reportOnlyText = (Write-AMRLValidationReport -Deployment $reportOnlyDeployment 6>&1 | Out-String)
Assert-Test ($reportOnlyText -match 'Mode: reportOnly; blocking: 1; advisory: 0' -and $reportOnlyText -match 'Deployment gate: not blocked') 'Report-only summary obscured the enforcement decision.'
$enforcedText = (Write-AMRLValidationReport -Deployment $nestedDeployment 6>&1 | Out-String)
Assert-Test ($enforcedText -match 'Mode: enforce; blocking: 1; advisory: 0' -and $enforcedText -match 'Deployment gate: blocked') 'Enforced summary omitted the deployment gate result.'
Assert-Test ($enforcedText -notmatch 'BLOCKING \[hasNoJumpboxes\]') 'Detailed validation findings were duplicated outside the consolidated warnings/errors section.'
$previousBootstrapperReport = $script:BootstrapperReport
Initialize-AMRLBootstrapperReport -Mode 'Validation finding duplication test'
Write-AMRLValidationReport -Deployment $nestedDeployment | Out-Null
$blockingIssues = @($script:BootstrapperReport.Issues | Where-Object { $_.Phase -eq 'AMRL validation engine' })
Assert-Test ($blockingIssues.Count -eq 1 -and $blockingIssues[0].Severity -eq 'Error') 'An enforced blocking finding was not added to the warnings/errors section as an error.'
Assert-Test ($blockingIssues[0].Message -eq 'BLOCKING [hasNoJumpboxes] No jumpbox.' -and $blockingIssues[0].NextStep -eq 'Request a jumpbox.') 'The consolidated blocking error omitted its remediation next step.'
$script:BootstrapperReport = $previousBootstrapperReport
$reportOnlyWithAdvisory = $reportOnlyDeployment | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$reportOnlyWithAdvisory.properties.outputs.advisoryValidationDetails.value = @([pscustomobject]@{ flag = 'invalidDepartmentCount'; message = 'Department count exceeds definitions.'; remediation = 'Reduce the department count.' })
Initialize-AMRLBootstrapperReport -Mode 'Report-only finding severity test'
Write-AMRLValidationReport -Deployment $reportOnlyWithAdvisory | Out-Null
$reportOnlyIssues = @($script:BootstrapperReport.Issues | Where-Object { $_.Phase -eq 'AMRL validation engine' })
Assert-Test ($reportOnlyIssues.Count -eq 2 -and @($reportOnlyIssues | Where-Object { $_.Severity -ne 'Warning' }).Count -eq 0) 'Report-only findings were not classified as warnings.'
Assert-Test (@($reportOnlyIssues | Where-Object { $_.Message -eq 'ADVISORY [invalidDepartmentCount] Department count exceeds definitions.' -and $_.NextStep -eq 'Reduce the department count.' }).Count -eq 1) 'Advisory next step was not carried into the consolidated warnings/errors section.'
$script:BootstrapperReport = $previousBootstrapperReport
$emptyFindings = [pscustomobject]@{ name = 'empty-findings'; properties = [pscustomobject]@{ outputs = [pscustomobject]@{
    blockingValidationDetails = [pscustomobject]@{ value = @() }
    advisoryValidationDetails = [pscustomobject]@{ value = @() }
} } }
$emptyFindingsReport = Get-AMRLValidationReport -Deployment $emptyFindings
Assert-Test ($emptyFindingsReport.FindingsAvailable -and $emptyFindingsReport.Blocking.Count -eq 0 -and $emptyFindingsReport.Advisory.Count -eq 0) 'Present empty collections were confused with unavailable findings.'
Write-AMRLValidationReport -Deployment $null -WarningAction SilentlyContinue
Show-AMRLGuestCommandResults -Prefix 'AMRL' -Deployment $null -WarningAction SilentlyContinue
$failedWithoutPlacements = [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Failed'; outputs = [pscustomobject]@{} } }
Initialize-AMRLBootstrapperReport -Mode 'Failed without placements test'
Show-AMRLGuestCommandResults -Prefix 'AMRL' -Deployment $failedWithoutPlacements -Quiet
Assert-Test (@($script:BootstrapperReport.Phases | Where-Object { $_.Name -eq 'VM setup checks' -and $_.Status -eq 'Skipped' }).Count -eq 1) 'Failed deployment without placements was not marked as skipped guest checks.'
Assert-Test (@($script:BootstrapperReport.Issues | Where-Object { $_.Phase -eq 'VM setup checks' }).Count -eq 0) 'Missing placements after deployment failure produced a redundant warning.'
Assert-Test ((Get-AMRLValidationDeploymentName -Prefix 'AMRL' -RootDeploymentName 'amrl-20261028-120000') -eq 'AMRL-validation-engine-amrl-20261028-120000') 'Nested validation deployment name does not match main.bicep naming.'

$script:validationLookupCalls = New-Object 'System.Collections.Generic.List[string]'
$script:validationRoot = [pscustomobject]@{
    name = 'amrl-test-deployment'
    properties = [pscustomobject]@{ outputs = [pscustomobject]@{} }
}
$script:validationNested = $nestedDeployment
function Get-AzJson {
    param([string[]]$Arguments)
    $nameIndex = [Array]::IndexOf($Arguments, '--name')
    $deploymentName = $Arguments[$nameIndex + 1]
    $script:validationLookupCalls.Add($deploymentName)
    if ($deploymentName -eq 'amrl-test-deployment') { return $script:validationRoot }
    if ($deploymentName -eq 'AMRL-validation-engine-amrl-test-deployment') { return $script:validationNested }
    throw "Unexpected deployment lookup: $deploymentName"
}
Show-AMRLValidationAfterFailure -Prefix 'AMRL' -RootDeploymentName 'amrl-test-deployment'
Assert-Test ($script:validationLookupCalls.Count -eq 2) 'Failure reporting did not query root then nested validation deployments.'
Assert-Test ($script:validationLookupCalls[1] -eq 'AMRL-validation-engine-amrl-test-deployment') 'Failure reporting queried the wrong nested validation deployment.'
$script:validationRoot = $partialDeployment
$script:validationLookupCalls.Clear()
Show-AMRLValidationAfterFailure -Prefix 'AMRL' -RootDeploymentName 'amrl-test-deployment'
Assert-Test ($script:validationLookupCalls.Count -eq 2) 'A partial root summary prevented fallback to complete nested findings.'
$script:validationRoot = [pscustomobject]@{ name = 'amrl-test-deployment'; properties = [pscustomobject]@{} }
$script:validationLookupCalls.Clear()
Show-AMRLValidationAfterFailure -Prefix 'AMRL' -RootDeploymentName 'amrl-test-deployment'
Assert-Test ($script:validationLookupCalls.Count -eq 2) 'Missing root outputs prevented nested validation recovery.'

# Verify foundation IDs are derived from the parameter file and subscription, and vault-name
# collisions are handled deterministically without purging or silently replacing explicit references.
& {
    $foundationParameters = $parameterJson | ConvertFrom-Json
    $script:expectedIdentityId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/amrl-deployment-mi'
    $script:expectedVaultId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/amrl-kv-test'
    function Get-AzJson {
        param([string[]]$Arguments)
        if ($Arguments[0] -eq 'identity') { return [pscustomobject]@{ id = $script:expectedIdentityId; principalId = 'identity-principal' } }
        if ($Arguments[0] -eq 'keyvault') { return [pscustomobject]@{ id = $script:expectedVaultId; name = 'amrl-kv-test' } }
        throw "Unexpected foundation lookup: $($Arguments -join ' ')"
    }
    $foundation = Get-AMRLFoundationConfiguration -Parameters $foundationParameters -SubscriptionId 'sub'
    Assert-Test ($foundation.ResourceGroup -eq 'rg') 'Foundation resource group was not taken from the top-level parameter.'
    Assert-Test ($foundation.IdentityName -eq (Get-AMRLDefault 'automationManagedIdentityName')) 'Managed identity name did not come from AMRL defaults.'
    Assert-Test ($foundation.IdentityId -eq $script:expectedIdentityId -and $foundation.IdentityResourceGroup -eq 'rg') 'Managed identity resource ID was not derived from subscription and foundation group.'
    Assert-Test ($foundation.VaultName -eq 'amrl-kv-test' -and $foundation.VaultId -eq $script:expectedVaultId -and $foundation.VaultResourceGroup -eq 'rg') 'Key Vault identity was not derived from top-level parameter values.'
    $script:nameChecks = 0
    function Get-AzJson {
        param([string[]]$Arguments)
        $script:nameChecks++
        return [pscustomobject]@{ nameAvailable = ($script:nameChecks -eq 3); reason = 'AlreadyExists' }
    }
    $availableName = Get-AMRLAvailableVaultName -SubscriptionId '12345678-0000-0000-0000-000000000000'
    Assert-Test ($availableName -eq 'amrl-kv-12345678-2' -and $script:nameChecks -eq 3) 'Vault name collision handling did not select the next deterministic candidate.'
    $script:nameChecks = 0
    function Get-AzJson {
        param([string[]]$Arguments)
        $script:nameChecks++
        return [pscustomobject]@{ nameAvailable = $false; reason = 'AlreadyExists' }
    }
    $exhausted = $false
    try { Get-AMRLAvailableVaultName -SubscriptionId '12345678-0000-0000-0000-000000000000' | Out-Null }
    catch { $exhausted = $_.Exception.Message -like '*after 10 candidates*' }
    Assert-Test ($exhausted -and $script:nameChecks -eq 10) 'Vault name collision checks were not bounded.'
    function Get-AzJson { param([string[]]$Arguments) return [pscustomobject]@{ nameAvailable = $false; reason = 'AccountNameInvalid' } }
    $invalidNameRejected = $false
    try { Get-AMRLAvailableVaultName -SubscriptionId '12345678-0000-0000-0000-000000000000' | Out-Null }
    catch { $invalidNameRejected = $_.Exception.Message -like '*naming policy and permissions*' }
    Assert-Test $invalidNameRejected 'Vault naming policy failures were treated as ordinary collisions.'
}

# Retry and prerequisite tests allow only transient RBAC propagation failures; firewall and other
# permanent errors stop immediately. Missing tool checks are collected into one actionable error.
& {
    $script:retryCalls = 0
    $retryResult = Invoke-AMRLRbacRetry -InitialDelaySeconds 0 -Operation {
        $script:retryCalls++
        if ($script:retryCalls -lt 3) { throw 'ForbiddenByRbac: assignment is propagating' }
        return 'ready'
    }
    Assert-Test ($retryResult -eq 'ready' -and $script:retryCalls -eq 3) 'RBAC retry did not recover from propagation errors.'
    $script:retryCalls = 0
    $retryResult = Invoke-AMRLRbacRetry -InitialDelaySeconds 0 -Operation {
        $script:retryCalls++
        if ($script:retryCalls -lt 3) { throw "Cannot find user or service principal in graph database for 'managed-identity-principal-id'." }
        return 'ready'
    }
    Assert-Test ($retryResult -eq 'ready' -and $script:retryCalls -eq 3) 'Managed identity graph propagation was not retried.'
    foreach ($failure in @('ForbiddenByFirewall', 'DenyAssignment', 'AuthenticationFailed', 'ResourceNotFound')) {
        $script:retryCalls = 0
        try {
            Invoke-AMRLRbacRetry -InitialDelaySeconds 0 -Operation { $script:retryCalls++; throw $failure } | Out-Null
        }
        catch { Assert-Test ($_.Exception.Message -eq $failure) 'Retry obscured the original non-transient error.' }
        Assert-Test ($script:retryCalls -eq 1) "Retry repeated permanent error $failure."
    }
    $script:retryCalls = 0
    try { Invoke-AMRLRbacRetry -MaximumAttempts 3 -InitialDelaySeconds 0 -Operation { $script:retryCalls++; throw 'PrincipalNotFound' } }
    catch { Assert-Test ($script:retryCalls -eq 3) 'RBAC retries did not stop at the attempt limit.' }

    function Get-Command { param([string]$Name, $ErrorAction) return $null }
    $missingToolsRejected = $false
    try { Assert-AMRLPrerequisites -IncludeGitHub }
    catch { $missingToolsRejected = $_.Exception.Message -match 'az' -and $_.Exception.Message -match 'ssh-keygen' -and $_.Exception.Message -match 'git' -and $_.Exception.Message -match 'gh' }
    Assert-Test $missingToolsRejected 'Prerequisites did not aggregate all missing commands.'
}

# Guest-result tests distinguish a successful Run Command resource from a successful guest script,
# and confirm collection is read-only and quiet when results are destined for the final report.
& {
    $script:guestCalls = New-Object 'System.Collections.Generic.List[object]'
    function Get-AzJson {
        param([string[]]$Arguments)
        $script:guestCalls.Add(@($Arguments))
        if ($Arguments -contains 'list') { return @('install-good', 'install-failed', 'install-running', 'install-unavailable') }
        $commandName = $Arguments[[Array]::IndexOf($Arguments, '--name') + 1]
        switch ($commandName) {
            'install-good' { return [pscustomobject]@{ executionState = 'Succeeded'; exitCode = 0 } }
            'install-failed' { return [pscustomobject]@{ executionState = 'Succeeded'; exitCode = 5 } }
            'install-running' { return [pscustomobject]@{ executionState = 'Running'; exitCode = $null } }
            default { throw 'Read denied' }
        }
    }
    $guestResults = @(Get-AMRLGuestCommandResults -Prefix 'AMRL' -Placements @([pscustomobject]@{ name = 'AMRL-dc01'; regionKey = 'westeurope' }))
    Assert-Test ($guestResults.Count -eq 4) 'Guest collector did not inspect all VM Run Commands.'
    Assert-Test ($guestResults[0].Result -eq 'Passed') 'Guest collector did not recognize a successful zero exit code.'
    Assert-Test ($guestResults[1].Result -eq 'Failed') 'Guest collector trusted success despite a nonzero script exit code.'
    Assert-Test ($guestResults[2].Result -eq 'Not verified') 'Guest collector reported an in-progress command as successful.'
    Assert-Test ($guestResults[3].Result -eq 'Read failed') 'Guest collector did not preserve an unreadable command result.'
    Assert-Test (($script:guestCalls[0] -join ' ') -like '*AMRL-rg-westeurope*') 'Guest collector used the wrong regional resource group.'
    Assert-Test (@($script:guestCalls | Where-Object { $_ -contains 'create' -or $_ -contains 'invoke' -or $_ -contains 'update' }).Count -eq 0) 'Guest collector ran a mutating command.'
    $previousReport = $script:BootstrapperReport
    Initialize-AMRLBootstrapperReport -Mode 'Quiet diagnostic collection test'
    $quietDeployment = $nestedDeployment | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $quietDeployment.properties.outputs | Add-Member -NotePropertyName vmPlacement -NotePropertyValue ([pscustomobject]@{
        value = @([pscustomobject]@{ name = 'AMRL-dc01'; regionKey = 'westeurope' })
    }) -Force
    $validationOutput = @(Write-AMRLValidationReport -Deployment $quietDeployment -Quiet *>&1)
    $guestOutput = @(Show-AMRLGuestCommandResults -Prefix 'AMRL' -Deployment $quietDeployment -Quiet *>&1)
    Assert-Test ($validationOutput.Count -eq 0 -and $guestOutput.Count -eq 0) 'Quiet diagnostic collection printed duplicate results or warnings.'
    Assert-Test ($null -ne $script:BootstrapperReport.Validation -and $script:BootstrapperReport.Validation.ShouldBlockDeployment) 'Quiet validation collection lost the enforcement result.'
    Assert-Test ($script:BootstrapperReport.GuestResults.Count -eq 4) 'Quiet guest collection lost VM result rows.'
    Assert-Test ($script:BootstrapperReport.GuestResults[0].Result -eq 'Passed' -and $script:BootstrapperReport.GuestResults[3].Result -eq 'Read failed') 'Quiet collection lost passed or unreadable results.'
    Assert-Test (@($script:BootstrapperReport.Issues | Where-Object { $_.Phase -eq 'VM setup checks' }).Count -eq 3) 'Quiet guest collection lost failed and unverified warnings from the final report.'
    Assert-Test (@($script:BootstrapperReport.Issues | Where-Object { $_.Phase -eq 'AMRL validation engine' }).Count -eq 1) 'Quiet validation collection lost the consolidated finding.'
    $guestProgress = (Show-AMRLGuestCommandResults -Prefix 'AMRL' -Deployment $quietDeployment -Quiet -ShowProgress 6>&1 | Out-String)
    Assert-Test ($guestProgress -match 'Checking VM setup status: AMRL-dc01' -and $guestProgress -notmatch 'ExecutionState|read-only status checks|install-good') 'Guest progress was missing or duplicated detailed result rows before the report.'
    $script:BootstrapperReport = $previousReport
    function Get-AzJson { param([string[]]$Arguments) return @() }
    $emptyResults = @(Get-AMRLGuestCommandResults -Prefix 'AMRL' -Placements @([pscustomobject]@{ name = 'AMRL-dc01'; regionKey = 'westeurope' }))
    Assert-Test ($emptyResults.Count -eq 1 -and $emptyResults[0].Result -eq 'No commands found') 'A VM with no Run Commands was silently treated as verified.'
}

# Windows MSI Azure CLI selects its bundled Python when available and otherwise uses the normal CLI.
& {
    function Get-Command {
        param($Name, $ErrorAction)
        [pscustomobject]@{ CommandType = 'Application'; Source = 'C:\mock-cli\wbin\az.cmd' }
    }
    function Test-Path { param($LiteralPath) return $LiteralPath -eq 'C:\mock-cli\python.exe' }
    $msiInvocation = Get-AMRLAzCliInvocation
    Assert-Test ($msiInvocation.Command -eq 'C:\mock-cli\python.exe' -and ($msiInvocation.Prefix -join ' ') -eq '-X utf8 -IBm azure.cli' -and $msiInvocation.Installer -eq 'MSI') 'MSI invocation did not explicitly enable UTF-8 while preserving isolated mode.'
    function Test-Path { param($LiteralPath) return $false }
    $fallbackInvocation = Get-AMRLAzCliInvocation
    Assert-Test ($fallbackInvocation.Command -eq 'az' -and $fallbackInvocation.Prefix.Count -eq 0) 'Missing bundled Python did not preserve the normal Azure CLI path.'
}

# Exercise native Azure CLI UTF-8 setup/restoration on success, nonzero exit, and invocation errors.
& {
    $previousPythonEncoding = [System.Environment]::GetEnvironmentVariable('PYTHONIOENCODING', 'Process')
    $previousConsoleEncoding = [Console]::OutputEncoding
    $script:encodingProbeFailure = ''
    $script:encodingProbeExitCode = 0
    function az {
        Assert-Test ($env:PYTHONIOENCODING -eq 'utf-8' -and [Console]::OutputEncoding.CodePage -eq 65001) 'Azure CLI did not receive matching UTF-8 output settings.'
        if ($script:encodingProbeFailure) { throw $script:encodingProbeFailure }
        $global:LASTEXITCODE = $script:encodingProbeExitCode
        return ('{"message":"' + [char]0x2713 + '"}')
    }
    try {
        [System.Environment]::SetEnvironmentVariable('PYTHONIOENCODING', 'cp1252', 'Process')
        [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(1252)
        $result = & $originalInvokeAzCli -Arguments @('deployment', 'sub', 'what-if')
        Assert-Test (($result | ConvertFrom-Json).message -eq [string][char]0x2713) 'Unicode CLI JSON was not preserved.'
        Assert-Test ($env:PYTHONIOENCODING -eq 'cp1252' -and [Console]::OutputEncoding.CodePage -eq 1252) 'CLI success did not restore the caller encoding.'
        $script:encodingProbeExitCode = 7
        $exitFailure = $false
        try { & $originalInvokeAzCli -Arguments @('deployment', 'sub', 'what-if') | Out-Null }
        catch { $exitFailure = $_.Exception.Message -like '*Azure CLI failed (exit 7)*' }
        Assert-Test $exitFailure 'UTF-8 handling suppressed a genuine CLI failure.'
        Assert-Test ($env:PYTHONIOENCODING -eq 'cp1252' -and [Console]::OutputEncoding.CodePage -eq 1252) 'CLI failure did not restore the caller encoding.'
        $script:encodingProbeFailure = 'Mock native invocation failure'
        $invocationFailed = $false
        try { & $originalInvokeAzCli -Arguments @('deployment', 'sub', 'what-if') | Out-Null }
        catch { $invocationFailed = $_.Exception.Message -eq 'Mock native invocation failure' }
        Assert-Test ($invocationFailed -and $env:PYTHONIOENCODING -eq 'cp1252' -and [Console]::OutputEncoding.CodePage -eq 1252) 'Invocation exception was lost or encoding was not restored.'
        [System.Environment]::SetEnvironmentVariable('PYTHONIOENCODING', $null, 'Process')
        $script:encodingProbeFailure = ''
        $script:encodingProbeExitCode = 0
        & $originalInvokeAzCli -Arguments @('version') | Out-Null
        Assert-Test ($null -eq [System.Environment]::GetEnvironmentVariable('PYTHONIOENCODING', 'Process')) 'Previously absent Python encoding was left set after the CLI call.'
    }
    finally {
        [Console]::OutputEncoding = $previousConsoleEncoding
        [System.Environment]::SetEnvironmentVariable('PYTHONIOENCODING', $previousPythonEncoding, 'Process')
    }
}

# Verify the Azure CLI wrapper retries eligible Key Vault/role-assignment RBAC propagation failures,
# but does not retry firewall denials or change Plan's single-attempt behavior.
& {
    $script:cliProbeCalls = 0
    $script:cliProbeFailure = 'ForbiddenByRbac'
    $retryImplementation = (Get-Command Invoke-AMRLRbacRetry).ScriptBlock
    function Invoke-AMRLRbacRetry {
        param([scriptblock]$Operation)
        return (& $retryImplementation -Operation $Operation -InitialDelaySeconds 0)
    }
    function az {
        $script:cliProbeCalls++
        if ($script:cliProbeCalls -lt 3) {
            $global:LASTEXITCODE = 1
            return $script:cliProbeFailure
        }
        $global:LASTEXITCODE = 0
        return 'existing-secret'
    }
    $oldPlanMode = $script:PlanMode
    $script:PlanMode = $false
    try {
        $cliResult = & $originalInvokeAzCli -Arguments @('keyvault', 'secret', 'list', '--vault-name', 'mock-vault')
        Assert-Test ($cliResult -eq 'existing-secret' -and $script:cliProbeCalls -eq 3) 'Azure CLI wrapper did not retry Key Vault RBAC propagation.'
        $script:cliProbeCalls = 0
        $script:cliProbeFailure = "Cannot find user or service principal in graph database for 'managed-identity-principal-id'."
        $cliResult = & $originalInvokeAzCli -Arguments @('role', 'assignment', 'list', '--scope', '/subscriptions/mock', '--assignee', 'managed-identity-principal-id')
        Assert-Test ($cliResult -eq 'existing-secret' -and $script:cliProbeCalls -eq 3) 'Azure CLI wrapper did not retry managed identity graph propagation during role lookup.'
        $script:cliProbeCalls = 0
        $script:cliProbeFailure = 'ForbiddenByFirewall'
        $firewallRejected = $false
        try { & $originalInvokeAzCli -Arguments @('keyvault', 'secret', 'list', '--vault-name', 'mock-vault') | Out-Null }
        catch { $firewallRejected = $_.Exception.Message -like '*ForbiddenByFirewall*' }
        Assert-Test ($firewallRejected -and $script:cliProbeCalls -eq 1) 'Azure CLI wrapper retried a firewall denial.'
    }
    finally { $script:PlanMode = $oldPlanMode }
}

# Existing-foundation orchestration uses mocked Azure/GitHub/host commands to cover Plan's no-write
# guarantee, what-if gating, explicit confirmation, and preservation of the original deployment error.
& {
    $script:setupCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:setupPromptMessages = New-Object 'System.Collections.Generic.List[string]'
    $script:setupHostMessages = New-Object 'System.Collections.Generic.List[string]'
    $script:setupColoredHostMessages = New-Object 'System.Collections.Generic.List[object]'
    $script:setupWarningMessages = New-Object 'System.Collections.Generic.List[string]'
    $script:setupDeploymentNamePrompts = New-Object 'System.Collections.Generic.List[string]'
    $script:setupDeploymentNameAnswers = [System.Collections.Generic.Queue[string]]::new()
    $script:setupSubscription = '12345678-0000-0000-0000-000000000000'
    $script:failWhatIf = $false
    $script:setupIdentityId = "/subscriptions/$script:setupSubscription/resourceGroups/custom-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/amrl-deployment-mi"
    $script:setupVaultId = "/subscriptions/$script:setupSubscription/resourceGroups/custom-rg/providers/Microsoft.KeyVault/vaults/custom-vault"
    $fixturePath = Join-Path $env:TEMP ('amrl-setup-test-' + [guid]::NewGuid().ToString('N') + '.json')
    $fixture = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'main.parameters.demo.json') | ConvertFrom-Json
    $fixture.parameters.foundationResourceGroup.value = 'custom-rg'
    $fixture.parameters.keyVaultName.value = 'custom-vault'
    $fixture.parameters.prefix.metadata.bootstrap.azureSubscriptionId = $script:setupSubscription
    $fixture.parameters.prefix.metadata.bootstrap.azureTenantId = 'tenant'
    $fixture.parameters.jumpboxAllowedSources.value = @('203.0.113.12/32')
    [System.IO.File]::WriteAllText($fixturePath, ($fixture | ConvertTo-Json -Depth 100))
    $originalParameterPath = $script:ParameterFilePath
    $originalInteractive = $script:InteractiveConfiguration
    $originalPlanMode = $script:PlanMode
    $script:ParameterFilePath = $fixturePath
    $script:InteractiveConfiguration = $false
    function Assert-AMRLPrerequisites { param([switch]$IncludeGitHub) }
    function Read-Host {
        param([string]$Prompt)
        $script:setupPromptMessages.Add($Prompt)
        if ($Prompt -eq 'Confirmation') { return 'DEPLOY' }
        if ($Prompt -like 'Azure deployment name*') {
            $script:setupDeploymentNamePrompts.Add($Prompt)
            if ($script:setupDeploymentNameAnswers.Count -gt 0) { return $script:setupDeploymentNameAnswers.Dequeue() }
            return ''
        }
        return 'yes'
    }
    function Write-Host {
        param([object]$Object, [switch]$NoNewline, [ConsoleColor]$ForegroundColor)
        $script:setupHostMessages.Add([string]$Object)
        if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
            $script:setupColoredHostMessages.Add([pscustomobject]@{ Text = [string]$Object; Color = $ForegroundColor })
        }
    }
    function Write-Warning {
        param([object]$Message)
        $script:setupWarningMessages.Add([string]$Message)
    }
    function Get-AzTsv {
        param([string[]]$Arguments)
        if ($Arguments[0] -eq 'provider') { return 'Registered' }
        if ($Arguments[0] -eq 'group') { return 'true' }
        if ($Arguments[0] -eq 'keyvault' -and $Arguments -contains 'show') { return 'ssh-ed25519 test-public-key' }
        return 'existing'
    }
    function Get-AzJson {
        param([string[]]$Arguments)
        $script:setupCalls.Add(@($Arguments))
        if ($Arguments[0] -eq 'account') { return [pscustomobject]@{ id = $script:setupSubscription; tenantId = 'tenant'; name = 'Test'; user = @{ name = 'test-user' } } }
        if ($Arguments[0] -eq 'identity') {
            if ($Arguments -contains 'create') { return [pscustomobject]@{ id = $script:setupIdentityId; principalId = 'principal'; location = 'southafricanorth' } }
            return [pscustomobject]@{ id = $script:setupIdentityId; principalId = 'principal' }
        }
        if ($Arguments[0] -eq 'keyvault') {
            if ($Arguments -contains 'secret') { return @(Get-AMRLManagedSecretNames) }
            return [pscustomobject]@{ id = $script:setupVaultId; name = 'custom-vault'; properties = @{ enableRbacAuthorization = $true; enabledForTemplateDeployment = $true; enablePurgeProtection = $true } }
        }
        if ($Arguments[0] -eq 'group') { return [pscustomobject]@{ location = 'westeurope' } }
        if ($Arguments[0] -eq 'lock') { return [pscustomobject]@{ level = 'CanNotDelete' } }
        throw "Unexpected setup lookup: $($Arguments -join ' ')"
    }
    function Invoke-AzCli {
        param([string[]]$Arguments)
        $script:setupCalls.Add(@($Arguments))
        if ($script:failWhatIf -and $Arguments -contains 'what-if') { throw 'PROBE: what-if failed' }
        if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'create') { throw 'PROBE: original deployment failure' }
        return ''
    }
    function Test-Path {
        param([string]$LiteralPath)
        if ($LiteralPath -like '*amrl_ed25519*') { return $true }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
    }
    function Get-Content {
        param([switch]$Raw, [string]$LiteralPath)
        if ($LiteralPath -like '*amrl_ed25519*') { return 'ssh-ed25519 test-public-key' }
        return Microsoft.PowerShell.Management\Get-Content -Raw -LiteralPath $LiteralPath
    }
    function Invoke-TestSshKeygen { $global:LASTEXITCODE = 0; return 'ssh-ed25519 test-public-key' }
    Set-Alias -Name ssh-keygen -Value Invoke-TestSshKeygen -Scope Local
    try {
        $explicitInput = Microsoft.PowerShell.Management\Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json
        $explicitInput.parameters.jumpboxAllowedSources.value = @('<YOUR_PUBLIC_IP>/32')
        [System.IO.File]::WriteAllText($fixturePath, (ConvertTo-AMRLParameterJson -InputObject $explicitInput))
        $script:setupPromptMessages.Clear()
        $unresolvedExplicitIpRejected = $false
        try { Invoke-AMRLSubscriptionSetup -Configure }
        catch { $unresolvedExplicitIpRejected = $_.Exception.Message -like '*explicit parameter file contains an unresolved jumpbox IP placeholder*' }
        Assert-Test $unresolvedExplicitIpRejected 'Explicit parameter-file IP placeholder did not produce an actionable error.'
        Assert-Test (@($script:setupPromptMessages | Where-Object { $_ -match 'Detected public IPv4|Use this address|Approved public IPv4' }).Count -eq 0) 'Explicit parameter-file setup prompted for a detected or approved public IP.'
        $explicitInput.parameters.jumpboxAllowedSources.value = @('203.0.113.12/32')
        [System.IO.File]::WriteAllText($fixturePath, (ConvertTo-AMRLParameterJson -InputObject $explicitInput))

        Invoke-AMRLBootstrapper -Prepare
        Assert-Test (@($script:setupHostMessages | Where-Object { $_ -eq 'Prepare and Plan check the template and preview Azure changes; AMRL validation engine findings are produced only during deployment.' }).Count -eq 1) 'Prepare did not explain when AMRL validation engine findings are produced.'
        Assert-Test ($script:BootstrapperReport.Status -eq 'Succeeded') 'Successful preparation did not produce a successful final report.'
        Assert-Test ($script:BootstrapperReport.Sources.Contains('Azure deployment validate') -and $script:BootstrapperReport.Sources.Contains('Azure deployment what-if')) 'Successful preparation omitted validation or what-if evidence from its report.'
        Assert-Test (-not $script:BootstrapperReport.Sources.Contains('Region readiness')) 'Report still includes the removed region readiness source.'
        Assert-Test (@($script:setupCalls | Where-Object { $_ -contains 'what-if' }).Count -eq 1) 'Normal setup did not reach what-if with explicit foundation references.'
        Assert-Test (-not $script:BootstrapperReport.Sources.Contains('Capacity availability')) 'Report still includes the removed capacity availability source.'
        Assert-Test ($script:BootstrapperReport.FoundationConfiguration.ResourceGroup -eq 'custom-rg' -and $script:BootstrapperReport.FoundationConfiguration.IdentityName -eq 'amrl-deployment-mi' -and $script:BootstrapperReport.FoundationConfiguration.VaultName -eq 'custom-vault' -and $script:BootstrapperReport.FoundationConfiguration.VaultResourceGroup -eq 'custom-rg') 'Preparation did not capture defaults-derived identity and top-level foundation configuration.'
        Assert-Test (@($script:setupCalls | Where-Object { $_[0] -eq 'vm' -and $_[1] -in @('list-skus', 'list-sizes', 'list-usage') }).Count -eq 0) 'Bootstrapper queried or displayed VM SKU/quota availability.'
        Assert-Test (@($script:setupCalls | Where-Object { $_[0] -eq 'vm' -or ($_[0] -eq 'vm' -and $_[1] -eq 'image') }).Count -eq 0) 'Bootstrapper queried regional VM or image availability.'
        Assert-Test (@($script:setupPromptMessages | Where-Object { $_ -like 'Azure deployment name*' }).Count -eq 0) 'Non-deploy preparation unexpectedly prompted for a deployment name.'
        Assert-Test (-not $script:BootstrapperReport.Sources.Contains('Azure deployment name')) 'Non-deploy preparation reported an unrequested deployment name.'
        Assert-Test (@($script:setupPromptMessages | Where-Object { $_ -like '*location*' }).Count -eq 0) 'Setup prompted for a foundation location although the group, identity, and vault already exist.'
        Assert-Test (@($script:setupCalls | Where-Object { $_ -contains 'create' -or $_ -contains 'set' -or $_ -contains 'register' }).Count -eq 0) 'Normal setup recreated existing foundation resources or secrets.'
        Assert-Test (@($script:setupCalls | Where-Object { $_ -contains 'custom-rg' -and $_[0] -eq 'lock' }).Count -eq 1) 'Setup did not inspect the foundation resource group protection.'
        $stagedParameters = Microsoft.PowerShell.Management\Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json
        $stagedParameters.parameters.stage.value = 'compute'
        [System.IO.File]::WriteAllText($fixturePath, (ConvertTo-AMRLParameterJson -InputObject $stagedParameters))
        Invoke-AMRLBootstrapper -Prepare
        $stagedParameters = Microsoft.PowerShell.Management\Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json
        Assert-Test ($stagedParameters.parameters.stage.value -eq 'compute') 'Preparation did not persist the requested compute stage.'
        $beforePlan = Microsoft.PowerShell.Management\Get-Content -Raw -LiteralPath $fixturePath
        $script:setupCalls.Clear()
        Invoke-AMRLSubscriptionSetup -Plan
        Assert-Test (@($script:setupHostMessages | Where-Object { $_ -eq 'Prepare and Plan check the template and preview Azure changes; AMRL validation engine findings are produced only during deployment.' }).Count -ge 2) 'Plan did not explain when AMRL validation engine findings are produced.'
        Assert-Test ($script:BootstrapperReport.Parameters.parameters.stage.value -eq 'compute') 'Plan did not use the parameter-file stage.'
        $afterPlan = Microsoft.PowerShell.Management\Get-Content -Raw -LiteralPath $fixturePath
        Assert-Test ($beforePlan -ceq $afterPlan) 'Plan changed the supplied parameter file.'
        Assert-Test (@($script:setupCalls | Where-Object { $_ -contains 'what-if' }).Count -eq 1) 'Ready Plan did not reach what-if.'
        $planBuildCall = @($script:setupCalls | Where-Object { $_[0] -eq 'bicep' -and $_[1] -eq 'build' })[0]
        Assert-Test ($planBuildCall -contains '--outfile' -and $planBuildCall -notcontains '--stdout') 'Plan Bicep build did not use a file output to avoid Windows console encoding failures.'
        $planBuildOutputPath = $planBuildCall[[Array]::IndexOf($planBuildCall, '--outfile') + 1]
        Assert-Test (-not (Test-Path -LiteralPath $planBuildOutputPath)) 'Plan Bicep build did not remove its temporary output file.'
        Assert-Test (@($script:setupCalls | Where-Object { $_ -contains 'create' -or $_ -contains 'set' -or $_ -contains 'register' }).Count -eq 0) 'Plan made mutating resource calls.'
        $script:setupCalls.Clear()
        $script:failWhatIf = $true
        $script:setupDeploymentNameAnswers = [System.Collections.Generic.Queue[string]]::new([string[]]@('invalid/name', 'amrl-whatif-custom'))
        $script:setupDeploymentNamePrompts.Clear()
        $stagedParameters.parameters.stage.value = 'identity'
        [System.IO.File]::WriteAllText($fixturePath, (ConvertTo-AMRLParameterJson -InputObject $stagedParameters))
        try { Invoke-AMRLBootstrapper -Deploy } catch { }
        Assert-Test ($script:BootstrapperReport.Parameters.parameters.stage.value -eq 'identity') 'Deploy preparation did not use the parameter-file stage.'
        Assert-Test (@($script:BootstrapperReport.Phases | Where-Object { $_.Name -eq 'What-if preview' -and $_.Status -eq 'Failed' }).Count -eq 1) 'What-if failure was not represented in the final report.'
        Assert-Test (@($script:BootstrapperReport.Phases | Where-Object { $_.Name -eq 'Deployment' -and $_.Status -eq 'Skipped' }).Count -eq 1) 'Deployment was not marked skipped after what-if failure.'
        Assert-Test (@($script:setupCalls | Where-Object { $_[0] -eq 'deployment' -and $_[2] -eq 'create' }).Count -eq 0) 'Deployment was attempted after what-if failed.'
        Assert-Test ($script:setupDeploymentNamePrompts.Count -eq 2) 'Invalid deployment name did not repeat the name prompt.'
        $whatIfCall = @($script:setupCalls | Where-Object { $_[0] -eq 'deployment' -and $_[2] -eq 'what-if' })[0]
        $whatIfNameIndex = [Array]::IndexOf($whatIfCall, '--name')
        Assert-Test ($whatIfCall[$whatIfNameIndex + 1] -eq 'amrl-whatif-custom') 'What-if did not use the selected custom deployment name.'
        $script:failWhatIf = $false
        $script:setupCalls.Clear()
        $script:setupWarningMessages.Clear()
        $script:setupDeploymentNameAnswers = [System.Collections.Generic.Queue[string]]::new([string[]]@(''))
        $originalFailurePreserved = $false
        try { Invoke-AMRLSubscriptionSetup -Deploy }
        catch { $originalFailurePreserved = $_.Exception.Message -eq 'PROBE: original deployment failure' }
        Assert-Test ($script:setupWarningMessages.Count -eq 0) 'Deployment failure diagnostics emitted duplicate warnings before the final report.'
        Assert-Test (@($script:setupHostMessages | Where-Object { $_ -like "Azure deployment: starting '*The AMRL validation engine will evaluate the configuration and apply the selected enforcement mode.*Findings and the gate result will appear in the final report when deployment outputs are available." }).Count -eq 1) 'Deploy did not explain AMRL validation engine execution and reporting.'
        Assert-Test $originalFailurePreserved 'Validation/guest diagnostic failures masked the original deployment error.'
        Assert-Test (@($script:setupHostMessages | Where-Object { $_ -eq 'Azure deployment failed. Collecting final diagnostics; results will appear in the report.' }).Count -eq 1) 'Failure recovery did not announce diagnostic collection.'
        Assert-Test (@($script:setupHostMessages | Where-Object { $_ -eq '  Summarizing deployment resource operations from progress snapshots...' }).Count -eq 1) 'Failure recovery did not identify snapshot-based resource-operation collection.'
        Assert-Test (@($script:setupHostMessages | Where-Object { $_ -eq 'Diagnostic collection finished. Preparing the final report...' }).Count -eq 1) 'Failure recovery did not announce completion before rethrowing the original error.'
        $createCall = @($script:setupCalls | Where-Object { $_[0] -eq 'deployment' -and $_[2] -eq 'create' })[0]
        $createNameIndex = [Array]::IndexOf($createCall, '--name')
        $defaultDeploymentName = $createCall[$createNameIndex + 1]
        $defaultPrefix = (Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json).parameters.prefix.value
        Assert-Test ($defaultDeploymentName -match ('^amrl-' + [regex]::Escape($defaultPrefix) + '-\d{8}-\d{6}$')) 'Blank deployment-name input did not accept the generated prefix/timestamp default.'
        Assert-Test (@($script:setupPromptMessages | Where-Object { $_ -eq 'Confirmation' }).Count -ge 1) 'Deployment confirmation prompt was not shown.'
        Assert-Test (@($script:setupColoredHostMessages | Where-Object { $_.Text -eq 'DEPLOY' -and $_.Color -eq [ConsoleColor]::Yellow }).Count -ge 1) 'DEPLOY confirmation keyword was not displayed in yellow.'
        Assert-Test ($script:setupHostMessages -contains " to create subscription deployment '$defaultDeploymentName'.") 'Deployment confirmation instruction did not show the selected name.'
        Assert-Test (@($script:setupDeploymentNamePrompts | Where-Object { $_.StartsWith('Azure deployment name (Allowed: Start with a letter or number; no spaces) [') }).Count -ge 1) 'Deployment name prompt did not use the requested concise hint.'

        $script:setupCalls.Clear()
        $script:setupDeploymentNameAnswers = [System.Collections.Generic.Queue[string]]::new([string[]]@('amrl-custom-run'))
        try { Invoke-AMRLSubscriptionSetup -Deploy } catch { }
        $customCreateCall = @($script:setupCalls | Where-Object { $_[0] -eq 'deployment' -and $_[2] -eq 'create' })[0]
        $customCreateNameIndex = [Array]::IndexOf($customCreateCall, '--name')
        Assert-Test ($customCreateCall[$customCreateNameIndex + 1] -eq 'amrl-custom-run') 'Deployment create did not use the selected custom name.'
    }
    finally {
        $script:ParameterFilePath = $originalParameterPath
        $script:InteractiveConfiguration = $originalInteractive
        $script:PlanMode = $originalPlanMode
        Remove-Item -LiteralPath $fixturePath -Force
    }
}

# Greenfield setup covers collision-free vault naming, generated password handling, temporary-file
# cleanup, derived foundation location, and the no-purge rule.
& {
    $script:freshCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:freshSecretPaths = New-Object 'System.Collections.Generic.List[string]'
    $script:freshNameChecks = 0
    $script:freshVaultConfirmed = $false
    $script:rejectFoundationLocation = $false
    $script:freshFoundationGroupExists = $false
    $script:freshKeyVaultAccessDenied = $false
    $script:freshKeyVaultSecretListCalls = 0
    $script:freshPrompts = New-Object 'System.Collections.Generic.List[string]'
    $script:freshHostMessages = New-Object 'System.Collections.Generic.List[string]'
    $script:freshSubscription = '12345678-0000-0000-0000-000000000000'
    $fixturePath = Join-Path $env:TEMP ('amrl-greenfield-test-' + [guid]::NewGuid().ToString('N') + '.json')
    $originalParameterPath = $script:ParameterFilePath
    $originalInteractive = $script:InteractiveConfiguration
    $originalPlanMode = $script:PlanMode
    $originalExplicit = $script:ParameterFileWasExplicit
    $script:ParameterFilePath = $fixturePath
    $script:InteractiveConfiguration = $true
    $script:ParameterFileWasExplicit = $false
    function Assert-AMRLPrerequisites { param([switch]$IncludeGitHub) }
    function Read-Host {
        param([string]$Prompt)
        $script:freshPrompts.Add($Prompt)
        if ($Prompt -like 'Use this tenant and subscription*') { return 'yes' }
        if ($Prompt -like 'Foundation resource-group name*') { return '' }
        if ($Prompt -like 'Location for new prerequisite resources*') { return 'southafricanorth' }
        if ($Prompt -like 'Foundation resource-group location*') {
            if ($script:freshFoundationGroupExists) { throw 'An existing foundation group should not prompt for its location.' }
            return 'southafricanorth'
        }
        if ($Prompt -like 'Create Key Vault*') { $script:freshVaultConfirmed = $true; return 'yes' }
        if ($Prompt -like 'Use this address*') { return '' }
        return ''
    }
    function Invoke-RestMethod { param($Uri, $TimeoutSec) return '203.0.113.12' }
    function Write-Host {
        param([object]$Object)
        $script:freshHostMessages.Add([string]$Object)
    }
    function Set-AMRLKeySecretsIfMissing { param([string]$VaultName) Assert-Test ($VaultName -eq 'amrl-kv-12345678-1') 'SSH setup did not receive the selected collision-free vault.' }
    function Get-AzTsv {
        param([string[]]$Arguments)
        if ($Arguments[0] -eq 'provider') { return 'Registered' }
        if ($Arguments[0] -eq 'group') { return ([string]$script:freshFoundationGroupExists).ToLowerInvariant() }
        if ($Arguments[0] -eq 'ad') { return 'operator-id' }
        if ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'secret' -and $Arguments[2] -eq 'list') {
            $script:freshKeyVaultSecretListCalls++
            if ($script:freshKeyVaultAccessDenied) { throw 'ForbiddenByRbac: access is still propagating.' }
            return ''
        }
        if ($Arguments[0] -eq 'vm') { return 'image-id' }
        return ''
    }
    function Get-AzJson {
        param([string[]]$Arguments)
        $script:freshCalls.Add(@($Arguments))
        if ($Arguments[0] -eq 'account') { return [pscustomobject]@{ id = $script:freshSubscription; tenantId = 'tenant'; name = 'Fresh'; user = @{ name = 'operator' } } }
        if ($Arguments[0] -eq 'rest') {
            $script:freshNameChecks++
            return [pscustomobject]@{ nameAvailable = ($script:freshNameChecks -eq 2); reason = 'AlreadyExists' }
        }
        if ($Arguments[0] -eq 'group' -and $Arguments -contains 'create') {
            $script:freshFoundationGroupExists = $true
            return [pscustomobject]@{ name = 'amrl-foundation-rg'; location = 'southafricanorth' }
        }
        if ($Arguments[0] -eq 'group' -and $Arguments -contains 'show') { return [pscustomobject]@{ location = 'westeurope' } }
        if ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'list-deleted') { return $null }
        if ($Arguments[0] -eq 'keyvault' -and $Arguments -contains 'show') { return [pscustomobject]@{ id = "/subscriptions/$script:freshSubscription/resourceGroups/amrl-foundation-rg/providers/Microsoft.KeyVault/vaults/amrl-kv-12345678-1"; properties = @{ enableRbacAuthorization = $true; enabledForTemplateDeployment = $true; enablePurgeProtection = $true } } }
        if ($Arguments[0] -eq 'identity' -and $Arguments -contains 'list') { return $null }
        if ($Arguments[0] -eq 'identity' -and $Arguments -contains 'show') { return $null }
        if ($Arguments[0] -eq 'lock') { return $null }
        if ($Arguments[1] -eq 'create') {
            switch ($Arguments[0]) {
                'identity' {
                    Assert-Test ($Arguments[$Arguments.IndexOf('--location') + 1] -eq 'southafricanorth') 'New identity did not use the selected resource location independently of the existing group location.'
                    if ($script:rejectFoundationLocation) { throw 'RequestDisallowedByAzure: locationineligible; selected region not accepting new customers.' }
                    return [pscustomobject]@{ id = "/subscriptions/$script:freshSubscription/resourceGroups/amrl-foundation-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/amrl-deployment-mi"; principalId = 'principal'; location = 'southafricanorth' }
                }
                'keyvault' {
                    Assert-Test $script:freshVaultConfirmed 'New vault was created before protection/name confirmation.'
                    Assert-Test ($Arguments[$Arguments.IndexOf('--location') + 1] -eq 'southafricanorth') 'New vault did not use the selected resource location.'
                    return [pscustomobject]@{ id = "/subscriptions/$script:freshSubscription/resourceGroups/amrl-foundation-rg/providers/Microsoft.KeyVault/vaults/amrl-kv-12345678-1" }
                }
            }
        }
        if ($Arguments[0] -eq 'keyvault' -and $Arguments -contains 'list') { return @() }
        throw "Unexpected greenfield lookup: $($Arguments -join ' ')"
    }
    function Invoke-AzCli {
        param([string[]]$Arguments)
        $script:freshCalls.Add(@($Arguments))
        if ($Arguments[0] -eq 'keyvault' -and $Arguments -contains '--file') {
            $secretPath = $Arguments[[Array]::IndexOf($Arguments, '--file') + 1]
            $script:freshSecretPaths.Add($secretPath)
            Assert-Test ((Get-Content -Raw -LiteralPath $secretPath).Length -eq 28) 'Greenfield secret creation did not use a generated password file.'
        }
        return ''
    }
    try {
        Invoke-AMRLSubscriptionSetup
        $saved = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json
        Assert-Test ($saved.parameters.foundationResourceGroup.value -eq 'amrl-foundation-rg') 'Wizard did not save the selected foundation resource-group name.'
        Assert-Test (@($script:freshPrompts | Where-Object { $_ -eq 'Foundation resource-group name (Allowed: 1-90 characters, no spaces) [amrl-foundation-rg]' }).Count -eq 1) 'A missing foundation resource group did not prompt with the requested label, hint, and default.'
        Assert-Test (@($script:freshCalls | Where-Object { $_[0] -eq 'group' -and $_ -contains 'create' }).Count -eq 1) 'Selected foundation resource group was not created.'
        Assert-Test ($saved.parameters.jumpboxAllowedSources.value[0] -eq '203.0.113.12/32') 'Pressing Enter did not accept the detected public IP as the default.'
        Assert-Test (@($script:freshPrompts | Where-Object { $_ -match '^Use this address for jumpbox access\? \(Allowed: y/n\) \[yes\]$' }).Count -eq 1) 'Jumpbox public-IP prompt did not display yes as the default.'
        Assert-Test ((Get-AMRLFoundationLocation -Parameters $saved) -eq 'southafricanorth') 'Foundation location was not derived from the first regionIndexMap entry.'
        Assert-Test ($null -eq $saved.parameters.prefix.metadata.bootstrap.PSObject.Properties['foundationLocation']) 'Derived foundation location was persisted in bootstrap metadata.'
        Assert-Test (@($script:freshPrompts | Where-Object { $_ -like '*location*' }).Count -eq 0) 'Foundation setup prompted for a location instead of using regionIndexMap.'
        Assert-Test (@($script:freshHostMessages | Where-Object { $_ -like '*Azure-listed physical locations*' -or $_ -eq 'westeurope, southafricanorth, eastus' }).Count -eq 0) 'Foundation setup printed the available-region list.'
        Assert-Test ($saved.parameters.keyVaultName.value -eq 'amrl-kv-12345678-1') 'Collision-free Key Vault name was not persisted to parameters.'
        Assert-Test ($script:freshSecretPaths.Count -eq (Get-AMRLPasswordSecretNames).Count) 'Greenfield setup did not create all managed password secrets.'
        foreach ($secretPath in $script:freshSecretPaths) { Assert-Test (-not (Test-Path -LiteralPath $secretPath)) 'A temporary password file was not removed.' }
        Assert-Test (@($script:freshCalls | Where-Object { $_ -contains 'what-if' }).Count -eq 1) 'Greenfield setup did not reach what-if.'
        Assert-Test (@($script:freshCalls | Where-Object { $_[0] -eq 'group' -and $_ -contains 'create' }).Count -eq 1) 'Rerunning after foundation creation attempted to recreate its resource group.'
        Assert-Test (@($script:freshCalls | Where-Object { $_ -contains 'purge' -or $_ -contains 'delete' }).Count -eq 0) 'Greenfield collision handling performed destructive recovery.'

        $script:freshKeyVaultAccessDenied = $true
        $script:freshKeyVaultSecretListCalls = 0
        $script:freshCalls.Clear()
        try { Invoke-AMRLSubscriptionSetup } catch { }
        Assert-Test ($script:freshKeyVaultSecretListCalls -eq 1) 'Secret setup continued after the Key Vault access probe failed.'
        Assert-Test ($script:BootstrapperReport.Sources['Key Vault access'].Status -eq 'Failed' -and $script:BootstrapperReport.Sources['Key Vault secrets'].Status -eq 'Skipped') 'The report marked Key Vault secret access ready after an authorization failure.'
        Assert-Test (@($script:freshCalls | Where-Object { $_[0] -eq 'keyvault' -and $_[1] -eq 'secret' -and $_[2] -eq 'set' }).Count -eq 0) 'Secret writes ran without verified Key Vault data access.'
        $script:freshKeyVaultAccessDenied = $false

        $script:rejectFoundationLocation = $true
        $eligibilityError = ''
        try { Invoke-AMRLSubscriptionSetup }
        catch { $eligibilityError = $_.Exception.Message }
        Assert-Test ($eligibilityError -like "*foundation resource location 'southafricanorth'*" -and $eligibilityError -like '*Use manual preparation*') "Location-ineligibility error did not explain how to recover using the saved configuration. Actual: $eligibilityError"
    }
    finally {
        $script:ParameterFilePath = $originalParameterPath
        $script:InteractiveConfiguration = $originalInteractive
        $script:PlanMode = $originalPlanMode
        $script:ParameterFileWasExplicit = $originalExplicit
        if (Test-Path -LiteralPath $fixturePath) { Remove-Item -LiteralPath $fixturePath -Force }
    }
}

# Brownfield foundation recovery covers Plan, exact vault-ID matching, interactive recovery/decline,
# resumable partial rebuilds, and the distinction between missing resources and permission failures.
& {
    $previousParameterPath = $script:ParameterFilePath
    $previousInteractive = $script:InteractiveConfiguration
    $previousPlanMode = $script:PlanMode
    $previousExplicit = $script:ParameterFileWasExplicit
    $fixturePath = Join-Path $env:TEMP ('amrl-rebuild-test-' + [guid]::NewGuid().ToString('N') + '.json')
    $script:rebuildCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:rebuildPrompts = New-Object 'System.Collections.Generic.List[string]'
    $script:rebuildEvents = New-Object 'System.Collections.Generic.List[string]'
    $script:rebuildSubscription = '12345678-0000-0000-0000-000000000000'
    $script:rebuildIdentityId = "/subscriptions/$script:rebuildSubscription/resourceGroups/amrl-foundation-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/amrl-deployment-mi"
    $script:rebuildVaultId = "/subscriptions/$script:rebuildSubscription/resourceGroups/amrl-foundation-rg/providers/Microsoft.KeyVault/vaults/amrl-kv-rebuild"
    $script:deletedVaultId = $script:rebuildVaultId
    $script:rebuildGroupExists = $false
    $script:rebuildNewFoundationGroupName = 'amrl-foundation-rg-recreated'
    $script:rebuildNewGroupExists = $false
    $script:rebuildIdentityResourceGroup = 'amrl-foundation-rg'
    $script:rebuildVaultResourceGroup = 'amrl-foundation-rg'
    $script:rebuildIdentityExists = $false
    $script:rebuildVaultExists = $false
    $script:deletedVaultPresent = $true
    $script:recoveryAnswer = 'yes'
    $script:chooseNewFoundationGroup = $false
    $script:foundationGroupNameAnswers = [System.Collections.Generic.Queue[string]]::new()
    $script:identityLookupError = 'ResourceNotFound'
    $fixture = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'main.parameters.demo.json') | ConvertFrom-Json
    $fixture.parameters.foundationResourceGroup.value = 'amrl-foundation-rg'
    $fixture.parameters.keyVaultName.value = 'amrl-kv-rebuild'
    $fixture.parameters.prefix.metadata.bootstrap.azureSubscriptionId = $script:rebuildSubscription
    $fixture.parameters.prefix.metadata.bootstrap.azureTenantId = 'rebuild-tenant'
    $fixture.parameters.jumpboxAllowedSources.value = @('203.0.113.12/32')
    [System.IO.File]::WriteAllText($fixturePath, (ConvertTo-AMRLParameterJson -InputObject $fixture))
    $script:ParameterFilePath = $fixturePath
    $script:InteractiveConfiguration = $false
    $script:ParameterFileWasExplicit = $true
    function Assert-AMRLPrerequisites { }
    function Write-Host { param([object]$Object, [switch]$NoNewline, [ConsoleColor]$ForegroundColor) }
    function Read-Host {
        param([string]$Prompt)
        $script:rebuildPrompts.Add($Prompt)
        if ($Prompt -like 'Recover soft-deleted Key Vault*') {
            $script:rebuildEvents.Add("Prompt:$Prompt")
            return $script:recoveryAnswer
        }
        if ($Prompt -like 'Foundation resource-group name*') {
            $script:rebuildEvents.Add("Prompt:$Prompt")
            if ($script:foundationGroupNameAnswers.Count -gt 0) { return $script:foundationGroupNameAnswers.Dequeue() }
            if ($script:chooseNewFoundationGroup) { return $script:rebuildNewFoundationGroupName }
            return ''
        }
        if ($Prompt -like 'Use this tenant and subscription*') { return 'yes' }
        if ($Prompt -like 'Deployment stage*' -or $Prompt -like 'Lab prefix*' -or $Prompt -like 'Region count*' -or
            $Prompt -like 'Network mode*' -or $Prompt -like 'Validation mode*' -or $Prompt -like 'maxVmsPerRegion*' -or
            $Prompt -like 'departmentCount*' -or $Prompt -like 'usersPerDepartment*' -or $Prompt -like 'VM count for *' -or
            $Prompt -like 'useDedicatedFileServer*' -or
            $Prompt -like 'enableWindowsAdminCenter*' -or $Prompt -like 'useDedicatedWacHost*') { return '' }
        if ($Prompt -like 'Foundation resource-group location*' -or $Prompt -like 'Location for new prerequisite resources*') { return 'southafricanorth' }
        if ($Prompt -like 'Randomly generate missing administrator passwords*') { return '' }
        if ($Prompt -like 'useDedicatedFileServer*' -or $Prompt -like 'enableWindowsAdminCenter*' -or $Prompt -like 'useDedicatedWacHost*') { return '' }
        if ($Prompt -like 'Create Key Vault*') { return 'yes' }
        if ($Prompt -eq 'Confirmation') { return 'DEPLOY' }
        if ($Prompt -like 'Azure deployment name*') { return '' }
        throw "Unexpected foundation rebuild prompt: $Prompt"
    }
    function Set-AMRLKeySecretsIfMissing { param([string]$VaultName) }
    function Get-AzTsv {
        param([string[]]$Arguments)
        $script:rebuildCalls.Add(@($Arguments))
        if ($Arguments[0] -eq 'group') {
            $groupName = $Arguments[[Array]::IndexOf($Arguments, '--name') + 1]
            if ($groupName -eq 'amrl-foundation-rg') { return ([string]$script:rebuildGroupExists).ToLowerInvariant() }
            if ($groupName -eq $script:rebuildNewFoundationGroupName) { return ([string]$script:rebuildNewGroupExists).ToLowerInvariant() }
            return 'false'
        }
        if ($Arguments[0] -eq 'provider') { return 'Registered' }
        if ($Arguments[0] -eq 'ad') { return 'operator-id' }
        if ($Arguments[0] -eq 'keyvault') { return 'existing-secret' }
        return ''
    }
    function Get-AzJson {
        param([string[]]$Arguments)
        $script:rebuildCalls.Add(@($Arguments))
        if ($Arguments[0] -eq 'rest') { return [pscustomobject]@{ nameAvailable = $true } }
        if ($Arguments[0] -eq 'account') { return [pscustomobject]@{ id = $script:rebuildSubscription; tenantId = 'rebuild-tenant'; name = 'Rebuild subscription'; user = @{ name = 'operator' } } }
        if ($Arguments[0] -eq 'group') {
            if ($Arguments[1] -eq 'create') {
                $groupName = $Arguments[[Array]::IndexOf($Arguments, '--name') + 1]
                if ($groupName -eq $script:rebuildNewFoundationGroupName) { $script:rebuildNewGroupExists = $true }
                else { $script:rebuildGroupExists = $true }
                $script:rebuildEvents.Add("CreateGroup:$groupName")
            }
            return [pscustomobject]@{ location = 'southafricanorth' }
        }
        if ($Arguments[0] -eq 'identity') {
            if ($Arguments[1] -eq 'create') {
                $script:rebuildIdentityExists = $true
                $script:rebuildIdentityResourceGroup = $Arguments[[Array]::IndexOf($Arguments, '--resource-group') + 1]
                $script:rebuildIdentityId = "/subscriptions/$script:rebuildSubscription/resourceGroups/$script:rebuildIdentityResourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/amrl-deployment-mi"
                $script:rebuildEvents.Add("CreateIdentity:$script:rebuildIdentityResourceGroup")
            }
            if ($Arguments[1] -eq 'show') {
                if ($script:rebuildIdentityExists -and $script:rebuildIdentityId -eq $Arguments[[Array]::IndexOf($Arguments, '--ids') + 1]) { return [pscustomobject]@{ id = $script:rebuildIdentityId; principalId = 'new-identity-principal' } }
                throw $script:identityLookupError
            }
            $identityGroup = $Arguments[[Array]::IndexOf($Arguments, '--resource-group') + 1]
            if ($script:rebuildIdentityExists -and $identityGroup -eq $script:rebuildIdentityResourceGroup) { return [pscustomobject]@{ id = $script:rebuildIdentityId; principalId = 'new-identity-principal' } }
            if ($Arguments[1] -eq 'show') { throw $script:identityLookupError }
            return $null
        }
        if ($Arguments[0] -eq 'keyvault') {
            if ($Arguments[1] -eq 'list-deleted') {
                if (-not $script:deletedVaultPresent) { return $null }
                return [pscustomobject]@{ name = 'amrl-kv-rebuild'; properties = @{ vaultId = $script:deletedVaultId; location = 'westeurope' } }
            }
            if ($Arguments[1] -eq 'recover') {
                $script:rebuildVaultExists = $true
                $script:rebuildVaultResourceGroup = $Arguments[[Array]::IndexOf($Arguments, '--resource-group') + 1]
                $script:rebuildVaultId = "/subscriptions/$script:rebuildSubscription/resourceGroups/$script:rebuildVaultResourceGroup/providers/Microsoft.KeyVault/vaults/amrl-kv-rebuild"
            }
            elseif ($Arguments[1] -eq 'create') {
                $script:rebuildVaultExists = $true
                $script:rebuildVaultResourceGroup = $Arguments[[Array]::IndexOf($Arguments, '--resource-group') + 1]
                $vaultName = $Arguments[[Array]::IndexOf($Arguments, '--name') + 1]
                $script:rebuildVaultId = "/subscriptions/$script:rebuildSubscription/resourceGroups/$script:rebuildVaultResourceGroup/providers/Microsoft.KeyVault/vaults/$vaultName"
                $script:rebuildEvents.Add("CreateVault:$script:rebuildVaultResourceGroup")
            }
            elseif ($Arguments[1] -eq 'show') {
                if ($script:rebuildVaultExists) { return [pscustomobject]@{ id = $script:rebuildVaultId; name = 'amrl-kv-rebuild'; properties = @{ enableRbacAuthorization = $true; enabledForTemplateDeployment = $true; enablePurgeProtection = $true } } }
                throw 'ResourceNotFound'
            }
            elseif ($Arguments[1] -eq 'list') {
                $vaultGroup = $Arguments[[Array]::IndexOf($Arguments, '--resource-group') + 1]
                if ($script:rebuildVaultExists -and $vaultGroup -eq $script:rebuildVaultResourceGroup) { return @([pscustomobject]@{ id = $script:rebuildVaultId; name = ($script:rebuildVaultId -split '/')[-1] }) }
                return @()
            }
            if ($script:rebuildVaultExists) { return [pscustomobject]@{ id = $script:rebuildVaultId; name = ($script:rebuildVaultId -split '/')[-1]; properties = @{ enableRbacAuthorization = $true; enabledForTemplateDeployment = $true; enablePurgeProtection = $true } } }
            return $null
        }
        if ($Arguments[0] -eq 'lock') { return $null }
        if ($Arguments[0] -eq 'deployment') {
            if ($Arguments[1] -eq 'operation') { return @() }
            return [pscustomobject]@{ name = 'rebuild-deployment'; properties = @{ outputs = [pscustomobject]@{} } }
        }
        throw "Unexpected foundation rebuild lookup: $($Arguments -join ' ')"
    }
    function Invoke-AzCli {
        param([string[]]$Arguments)
        $script:rebuildCalls.Add(@($Arguments))
        return ''
    }
    try {
        $beforePlan = Get-Content -Raw -LiteralPath $fixturePath
        Invoke-AMRLBootstrapper -Plan
        Assert-Test (@($script:rebuildCalls | Where-Object { $_ -contains 'create' -or $_ -contains 'recover' -or $_ -contains 'set' }).Count -eq 0) 'Plan changed Azure while the configured foundation group was missing.'
        Assert-Test ((Get-Content -Raw -LiteralPath $fixturePath) -ceq $beforePlan) 'Plan changed saved references for a missing foundation.'
        Assert-Test ($script:BootstrapperReport.Sources.Contains('Read-only prerequisite plan')) 'Plan failed before reporting missing configured foundation prerequisites.'

        $script:rebuildCalls.Clear()
        Invoke-AMRLBootstrapper -Deploy
        Assert-Test (@($script:rebuildCalls | Where-Object { $_[0] -eq 'group' -and $_[1] -eq 'create' }).Count -eq 1) 'Deploy did not recreate the deleted configured foundation group.'
        Assert-Test (@($script:rebuildCalls | Where-Object { $_[0] -eq 'identity' -and $_[1] -eq 'create' }).Count -eq 1) 'Deploy did not recreate the configured managed identity.'
        $recoveryCalls = @($script:rebuildCalls | Where-Object { $_[0] -eq 'keyvault' -and $_[1] -eq 'recover' })
        Assert-Test ($recoveryCalls.Count -eq 1 -and $recoveryCalls[0][[Array]::IndexOf($recoveryCalls[0], '--location') + 1] -eq 'westeurope') 'Deploy did not recover the same vault in its original location.'
        Assert-Test (@($script:rebuildPrompts | Where-Object { $_ -like 'Recover soft-deleted Key Vault*' }).Count -eq 0) 'Explicit parameter-file recovery unexpectedly prompted for confirmation.'
        Assert-Test (@($script:rebuildCalls | Where-Object { $_[0] -eq 'deployment' -and $_ -contains 'create' }).Count -eq 1) 'Rebuilt foundation did not reach lab deployment.'
        Assert-Test (@($script:BootstrapperReport.FoundationChanges | Where-Object { $_.Action -eq 'Recover soft-deleted foundation vault' }).Count -eq 1) 'Report omitted completed foundation vault recovery.'
        $saved = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json
        Assert-Test ($saved.parameters.foundationResourceGroup.value -eq 'amrl-foundation-rg' -and $saved.parameters.keyVaultName.value -eq 'amrl-kv-rebuild') 'Foundation rebuild changed the top-level foundation resource group or Key Vault name.'

        $script:rebuildGroupExists = $true
        $script:rebuildIdentityExists = $true
        $script:rebuildIdentityResourceGroup = 'amrl-foundation-rg'
        $script:rebuildIdentityId = "/subscriptions/$script:rebuildSubscription/resourceGroups/$script:rebuildIdentityResourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$(Get-AMRLDefault 'automationManagedIdentityName')"
        $script:rebuildVaultExists = $false
        $script:rebuildVaultResourceGroup = 'amrl-foundation-rg'
        $script:rebuildVaultId = "/subscriptions/$script:rebuildSubscription/resourceGroups/$script:rebuildVaultResourceGroup/providers/Microsoft.KeyVault/vaults/$($saved.parameters.keyVaultName.value)"
        $script:deletedVaultPresent = $true
        $script:deletedVaultId = $script:rebuildVaultId
        $script:recoveryAnswer = 'no'
        $script:chooseNewFoundationGroup = $false
        $script:foundationGroupNameAnswers = [System.Collections.Generic.Queue[string]]::new([string[]]@('amrl-foundation-rg', $script:rebuildNewFoundationGroupName))
        $script:rebuildEvents.Clear()
        $script:rebuildPrompts.Clear()
        $script:rebuildCalls.Clear()
        $script:InteractiveConfiguration = $true
        $script:ParameterFileWasExplicit = $false
        [System.IO.File]::WriteAllText($fixturePath, (ConvertTo-AMRLParameterJson -InputObject $saved))
        Invoke-AMRLBootstrapper -Prepare
        $replacementParameters = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json
        Assert-Test ($replacementParameters.parameters.foundationResourceGroup.value -eq $script:rebuildNewFoundationGroupName) 'Declining vault recovery did not save the selected top-level foundation group.'
        Assert-Test ($replacementParameters.parameters.keyVaultName.value -like 'amrl-kv-*') 'Replacement group was selected without saving the replacement Key Vault name.'
        Assert-Test (@($script:rebuildPrompts | Where-Object { $_ -like 'Recover soft-deleted Key Vault*' }).Count -eq 1 -and @($script:rebuildPrompts | Where-Object { $_ -like 'Foundation resource-group name*' }).Count -eq 2) 'The foundation group was not asked initially and again after recovery was declined.'
        $replacementNamePromptIndex = $script:rebuildEvents.FindLastIndex([Predicate[string]]{ param($eventText) $eventText -like 'Prompt:Foundation resource-group name*' })
        $replacementCreateIndex = $script:rebuildEvents.FindIndex([Predicate[string]]{ param($eventText) $eventText -like 'CreateGroup:*' })
        Assert-Test ($replacementNamePromptIndex -ge 0 -and $replacementCreateIndex -ge 0 -and $replacementNamePromptIndex -lt $replacementCreateIndex) 'Replacement foundation name was not chosen before any Azure resource creation.'
        Assert-Test (@($script:rebuildCalls | Where-Object { $_[0] -eq 'keyvault' -and $_[1] -eq 'recover' }).Count -eq 0) 'Declining old-vault recovery still recovered the old vault.'

        [System.IO.File]::WriteAllText($fixturePath, (ConvertTo-AMRLParameterJson -InputObject $saved))
        $script:InteractiveConfiguration = $false
        $script:ParameterFileWasExplicit = $true
        $script:rebuildGroupExists = $true
        $script:rebuildIdentityExists = $false
        $script:rebuildIdentityResourceGroup = 'amrl-foundation-rg'
        $script:rebuildIdentityId = "/subscriptions/$script:rebuildSubscription/resourceGroups/$script:rebuildIdentityResourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$(Get-AMRLDefault 'automationManagedIdentityName')"
        $script:rebuildVaultExists = $false
        $script:rebuildVaultResourceGroup = 'amrl-foundation-rg'
        $script:rebuildVaultId = "/subscriptions/$script:rebuildSubscription/resourceGroups/$script:rebuildVaultResourceGroup/providers/Microsoft.KeyVault/vaults/$($saved.parameters.keyVaultName.value)"
        $script:deletedVaultPresent = $true
        $script:deletedVaultId = $script:rebuildVaultId
        $script:recoveryAnswer = 'yes'
        $script:rebuildCalls.Clear()

        $script:rebuildCalls.Clear()
        $script:recoveryAnswer = 'no'
        $declined = $false
        try { Restore-AMRLFoundationVault -VaultName 'amrl-kv-rebuild' -ResourceGroup 'amrl-foundation-rg' -SubscriptionId $script:rebuildSubscription -ExpectedVaultId $script:rebuildVaultId | Out-Null }
        catch { $declined = $_.Exception.Message -like '*recovery was not confirmed*' }
        Assert-Test ($declined -and @($script:rebuildCalls | Where-Object { $_ -contains 'recover' }).Count -eq 0) 'Declined vault recovery still changed Azure.'
        $script:recoveryAnswer = 'yes'
        $script:deletedVaultId = '/subscriptions/other/resourceGroups/other/providers/Microsoft.KeyVault/vaults/amrl-kv-rebuild'
        $mismatchedVaultRejected = $false
        try { Restore-AMRLFoundationVault -VaultName 'amrl-kv-rebuild' -ResourceGroup 'amrl-foundation-rg' -SubscriptionId $script:rebuildSubscription -ExpectedVaultId $script:rebuildVaultId | Out-Null }
        catch { $mismatchedVaultRejected = $_.Exception.Message -like '*does not match the saved foundation vault ID*' }
        Assert-Test $mismatchedVaultRejected 'Recovery accepted a soft-deleted vault from another resource group or subscription.'
        $script:deletedVaultId = $script:rebuildVaultId

        $script:rebuildIdentityExists = $false
        $script:rebuildVaultExists = $false
        $script:rebuildCalls.Clear()
        Invoke-AMRLBootstrapper -Prepare
        Assert-Test (@($script:rebuildCalls | Where-Object { $_[0] -eq 'group' -and $_[1] -eq 'create' }).Count -eq 0 -and $script:rebuildIdentityExists -and $script:rebuildVaultExists) 'A partially rebuilt foundation could not resume without recreating the existing group.'
        $script:rebuildIdentityExists = $false
        $script:identityLookupError = 'AuthorizationFailed'
        $permissionFailureRejected = $false
        try { Get-AMRLFoundationConfiguration -Parameters $saved -SubscriptionId $script:rebuildSubscription -AllowMissingFoundation | Out-Null }
        catch { $permissionFailureRejected = $_.Exception.Message -eq 'AuthorizationFailed' }
        Assert-Test $permissionFailureRejected 'A permission error was treated as a missing foundation resource.'
        $script:identityLookupError = 'ResourceNotFound'
        $script:deletedVaultPresent = $false
        $script:rebuildVaultExists = $false
        $script:rebuildCalls.Clear()
        Invoke-AMRLBootstrapper -Prepare
        Assert-Test (@($script:rebuildCalls | Where-Object { $_[0] -eq 'keyvault' -and $_[1] -eq 'create' }).Count -eq 1) 'A configured foundation vault that is not soft-deleted was not recreated with the same name.'
        Assert-Test (@($script:rebuildCalls | Where-Object { $_[0] -eq 'keyvault' -and $_[1] -eq 'recover' }).Count -eq 0) 'Foundation setup attempted recovery when no soft-deleted vault exists.'
        Assert-Test (@($script:rebuildCalls | Where-Object { $_ -contains 'purge' -or $_ -contains 'delete' }).Count -eq 0) 'Foundation recovery performed destructive cleanup.'
    }
    finally {
        $script:ParameterFilePath = $previousParameterPath
        $script:InteractiveConfiguration = $previousInteractive
        $script:PlanMode = $previousPlanMode
        $script:ParameterFileWasExplicit = $previousExplicit
        Remove-Item -LiteralPath $fixturePath -Force
    }
}

# Final-report tests ensure early failures, foundation changes, what-if results, and read-only checks
# remain distinguishable without replacing the original failure.
& {
    $script:failureReportLines = New-Object 'System.Collections.Generic.List[string]'
    $oldPhase = $script:BootstrapperPhase
    $oldDeploymentAttempted = $script:DeploymentAttempted
    $script:failureReportCliCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:BootstrapperPhase = 'Foundation resource-group region'
    $script:DeploymentAttempted = $false
    $script:simulateBootstrapperFailure = $true
    $script:simulateDuplicateFoundationFailure = $false
    $script:failureReportCliOutput = ''
    $script:failureReportCliError = $false
    function Invoke-AMRLSubscriptionSetup {
        if ($script:simulateDuplicateFoundationFailure) {
            $script:BootstrapperPhase = 'Azure readiness and foundation'
            Add-AMRLReportIssue -Phase $script:BootstrapperPhase -Message 'Key Vault setup failed: Key Vault recovery was not confirmed. No replacement vault was created.'
            throw 'Required foundation prerequisites are unavailable; Bicep parameter resolution was skipped. Key Vault setup failed: Key Vault recovery was not confirmed. No replacement vault was created.'
        }
        if ($script:simulateBootstrapperFailure) {
            $script:BootstrapperPhase = 'Foundation resource-group region'
            throw 'PROBE: foundation resource-group location rejected'
        }
        $script:BootstrapperPhase = 'Parameter configuration'
        Set-AMRLReportPhase -Name 'Parameter configuration' -Status 'Succeeded' -Summary 'Probe setup succeeded.'
    }
    function Invoke-AzCli {
        param([string[]]$Arguments)
        $script:failureReportCliCalls.Add(@($Arguments))
        if ($script:failureReportCliError) { throw 'PROBE: read-only validation command failure' }
        return $script:failureReportCliOutput
    }
    function Write-Host {
        param([object]$Object)
        $script:failureReportLines.Add([string]$Object)
    }
    try {
        $script:LASTEXITCODE = 0
        Invoke-AMRLBootstrapper -Prepare
        Assert-Test ($script:BootstrapperReport.Status -eq 'Failed' -and $global:LASTEXITCODE -eq 1) 'Bootstrapper did not signal failure after completing the final report.'
        Assert-Test ($script:failureReportLines -contains 'AMRL BOOTSTRAPPER REPORT') 'A bootstrapper failure did not enter the final report phase.'
        Assert-Test (@($script:failureReportLines | Where-Object { $_ -match '^  \[FAIL\] Foundation resource-group region:' }).Count -eq 1) 'Failure report did not identify the failing phase.'
        Assert-Test (@($script:failureReportLines | Where-Object { $_ -match '\[Error\] Foundation resource-group region: PROBE: foundation resource-group location rejected' }).Count -eq 1) 'Failure report did not include the underlying error details.'
        Assert-Test (@($script:failureReportLines | Where-Object { $_ -like '  Not available; no deployment reached the validation engine.' }).Count -eq 1) 'Failure report did not distinguish an early failure from engine findings.'
        Assert-Test ($script:failureReportCliCalls.Count -eq 2 -and @($script:failureReportCliCalls | Where-Object { $_[0] -ne 'bicep' -or $_[1] -notin @('build', 'lint') }).Count -eq 0) 'Early failure did not run only the independent static Bicep fallback checks.'
        $script:failureReportLines.Clear()
        $script:simulateBootstrapperFailure = $false
        $script:simulateDuplicateFoundationFailure = $true
        Invoke-AMRLBootstrapper -Deploy
        $foundationFailureLines = @($script:failureReportLines | Where-Object { $_ -like '*Key Vault setup failed:*' })
        Assert-Test ($foundationFailureLines.Count -eq 1) 'Specific Key Vault recovery error was duplicated by the prerequisite wrapper.'
        Assert-Test (@($script:failureReportLines | Where-Object { $_ -eq '  [FAIL] Azure readiness and foundation: Foundation setup failed; see Warnings and errors below.' }).Count -eq 1) 'Foundation failure check did not refer to the specific consolidated error.'
        $script:simulateDuplicateFoundationFailure = $false
        $script:failureReportLines.Clear()
        Invoke-AMRLBootstrapper -Prepare
        Assert-Test ($script:failureReportLines -contains 'AMRL BOOTSTRAPPER REPORT') 'A successful bootstrapper run did not produce a final report.'
        Assert-Test ($script:failureReportLines -contains 'Overall result: Succeeded') 'Successful bootstrapper report did not show success.'

        Initialize-AMRLBootstrapperReport -Mode 'Probe'
        $script:BootstrapperPhase = 'What-if preview'
        $script:failureReportCliOutput = '{"changes":[{"changeType":"Create","resourceId":"/subscriptions/test/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1"},{"changeType":"Modify","resourceId":"/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet1"},{"changeType":"NoChange","resourceId":"unchanged-resource"},{"changeType":"Ignore","resourceId":"ignored-resource"}]}'
        $whatIfCapture = Invoke-AMRLObservedCommand -Name 'Azure deployment what-if' -Arguments @('deployment', 'sub', 'what-if')
        $whatIfSource = $script:BootstrapperReport.Sources['Azure deployment what-if']
        Assert-Test $whatIfCapture.Succeeded 'Successful what-if output was treated as a failure.'
        Assert-Test ($whatIfSource.Summary -eq '2 resource changes (Create: 1, Modify: 1).') 'What-if changes were not summarized by resource operation.'
        Assert-Test ($whatIfSource.Details -match 'Create: 1 Virtual machines \[' -and $whatIfSource.Details -match ': vm1') 'What-if report omitted the readable resource name.'
        Assert-Test ($whatIfSource.Details -notmatch '/subscriptions/[^/]+/resourceGroups/') 'JSON what-if report retained the subscription/resourceGroups prefix.'
        Assert-Test ($whatIfSource.Details -notmatch 'unchanged-resource|ignored-resource') 'What-if report included unchanged or ignored resources.'

        Initialize-AMRLBootstrapperReport -Mode 'Probe'
        $script:BootstrapperPhase = 'What-if preview'
        $script:failureReportCliOutput = "Note: The result may contain false positive predictions (noise).`nYou can help us improve the accuracy of the result by opening an issue here: https://aka.ms/WhatIfIssues`nThe deployment will update the following scopes:`n+ /subscriptions/test/resourceGroups/example [2025-01-01]`n  + location: westus`n~ Microsoft.Network/virtualNetworks/vnet1 [2025-01-01]`n- Microsoft.Compute/virtualMachines/old-vm [2025-01-01]`n= Microsoft.Network/virtualNetworks/unchanged [2025-01-01]"
        $textWhatIfCapture = Invoke-AMRLObservedCommand -Name 'Azure deployment what-if' -Arguments @('deployment', 'sub', 'what-if')
        $textWhatIfSource = $script:BootstrapperReport.Sources['Azure deployment what-if']
        $whatIfText = $textWhatIfSource.Summary + [Environment]::NewLine + $textWhatIfSource.Details
        Assert-Test $textWhatIfCapture.Succeeded 'Text what-if output was treated as a failure.'
        Assert-Test ($whatIfText -notmatch 'false positive predictions|location:|unchanged|2025-01-01') 'What-if report included notices, property diffs, unchanged resources, or API versions.'
        Assert-Test ($textWhatIfSource.Details -like '*Create: example*') 'Text what-if report omitted the proposed resource change.'
        Assert-Test ($textWhatIfSource.Details -notmatch '/subscriptions/[^/]+/resourceGroups/') 'Text what-if report retained the subscription/resourceGroups prefix.'
        Assert-Test ($whatIfText -notmatch 'WhatIfIssues|You can help us improve') 'What-if report retained the Azure feedback solicitation.'
        Assert-Test ($textWhatIfSource.Details -match 'Modify: vnet1' -and $textWhatIfSource.Details -match 'Delete: old-vm') 'Compact what-if report omitted updated or deleted resources.'

        $script:BootstrapperPhase = 'Azure readiness and foundation'
        $changeResult = Invoke-AMRLChange -Target 'Managed identity example-mi' -Action 'Create user-assigned managed identity' -Operation { 'created' }
        Assert-Test ($changeResult -eq 'created') 'Foundation change recording altered the operation result.'
        Assert-Test ($script:BootstrapperReport.FoundationChanges.Count -eq 1) 'A completed foundation change was not recorded.'
        try { Invoke-AMRLChange -Target 'Key Vault failed-vault' -Action 'Create vault' -Operation { throw 'PROBE: foundation write failed' } }
        catch { }
        Assert-Test ($script:BootstrapperReport.FoundationChanges.Count -eq 1) 'A failed foundation change was reported as completed.'
        Set-AMRLReportSource -Name 'Managed identity' -Status 'Ready' -Summary 'Identity example-mi is available.'
        $script:failureReportLines.Clear()
        Write-AMRLBootstrapperReport
        Assert-Test ($script:failureReportLines -contains 'Azure foundation setup (before Bicep deployment):') 'Report omitted the dedicated foundation setup section.'
        Assert-Test ($script:failureReportLines -contains '    Create user-assigned managed identity: Managed identity example-mi') 'Report omitted the completed foundation resource creation.'
        Assert-Test ($script:failureReportLines -contains '    [Ready] Managed identity: Identity example-mi is available.') 'Report omitted the foundation prerequisite check.'
        Assert-Test ($script:failureReportLines -contains '  No Bicep deployment was run; foundation setup is reported above.') 'Report confused foundation changes with Bicep deployment changes.'

        $script:failureReportCliError = $true
        $validateCapture = Invoke-AMRLObservedCommand -Name 'Azure deployment validate' -Arguments @('deployment', 'sub', 'validate')
        Assert-Test (-not $validateCapture.Succeeded) 'Azure validation command failure was not captured.'
        Assert-Test ($script:BootstrapperReport.Sources['Azure deployment validate'].Status -eq 'Failed') 'Azure validation failure was not added to report evidence.'
        Assert-Test (@($script:BootstrapperReport.Issues | Where-Object { $_.Message -like '*PROBE: read-only validation command failure*' }).Count -eq 1) 'Azure validation command error was not retained for the final report.'
    }
    finally {
        $script:BootstrapperPhase = $oldPhase
        $script:DeploymentAttempted = $oldDeploymentAttempted
    }
}

# Azure-context tests cover accepting the active subscription, selecting another saved subscription,
# enforcing explicit parameter-file context, and signing into a tenant when no context is available.
& {
    $script:contextSelectionCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:contextSelectionSubscription = 'subscription-one'
    $script:contextSelectionPromptMessages = New-Object 'System.Collections.Generic.List[string]'
    $script:contextSelectionAnswers = [System.Collections.Generic.Queue[string]]::new([string[]]@(''))
    Initialize-AMRLBootstrapperReport -Mode 'Context selection test'
    function Read-Host {
        param([string]$Prompt)
        $script:contextSelectionPromptMessages.Add($Prompt)
        if ($script:contextSelectionAnswers.Count -gt 0) { return $script:contextSelectionAnswers.Dequeue() }
        throw "Unexpected context prompt: $Prompt"
    }
    function Get-AzJson {
        param([string[]]$Arguments)
        if ($Arguments[0] -eq 'account' -and $Arguments[1] -eq 'show') {
            $subName = if ($script:contextSelectionSubscription -eq 'subscription-two') { 'Second subscription' } else { 'First subscription' }
            return [pscustomobject]@{ id = $script:contextSelectionSubscription; tenantId = 'tenant'; name = $subName; user = @{ name = 'operator' } }
        }
        if ($Arguments[0] -eq 'account' -and $Arguments[1] -eq 'list') {
            return @(
                [pscustomobject]@{ id = 'subscription-one'; tenantId = 'tenant'; name = 'First subscription'; state = 'Enabled' }
                [pscustomobject]@{ id = 'subscription-two'; tenantId = 'tenant-two'; name = 'Second subscription'; state = 'Enabled' }
            )
        }
        throw "Unexpected context lookup: $($Arguments -join ' ')"
    }
    function Invoke-AzCli {
        param([string[]]$Arguments)
        $script:contextSelectionCalls.Add(@($Arguments))
        if ($Arguments[0] -eq 'account' -and $Arguments[1] -eq 'set') { $script:contextSelectionSubscription = $Arguments[3] }
        return ''
    }

    $selectedContext = Get-AMRLAzureContext
    Assert-Test ($selectedContext.id -eq 'subscription-one') 'Blank context confirmation did not accept the current subscription default.'
    Assert-Test (@($script:contextSelectionPromptMessages | Where-Object { $_ -eq 'Use this tenant and subscription? (Allowed: y/N) [yes]' }).Count -eq 1) 'Context prompt did not display yes as the default.'
    Assert-Test (@($script:contextSelectionCalls | Where-Object { $_[0] -eq 'account' -and $_[1] -eq 'list' }).Count -eq 0) 'Default context confirmation unnecessarily opened the subscription chooser.'

    $script:contextSelectionCalls.Clear()
    $script:contextSelectionSubscription = 'subscription-one'
    $script:contextSelectionAnswers = [System.Collections.Generic.Queue[string]]::new([string[]]@('no', '2', 'yes'))
    Initialize-AMRLBootstrapperReport -Mode 'Context selection test'
    $selectedContext = Get-AMRLAzureContext
    Assert-Test ($selectedContext.id -eq 'subscription-two') 'Azure context chooser did not switch to the selected saved subscription.'
    Assert-Test (@($script:contextSelectionCalls | Where-Object { $_[0] -eq 'account' -and $_[1] -eq 'set' -and $_[3] -eq 'subscription-two' }).Count -eq 1) 'Azure context chooser did not call account set for the selected subscription.'
    Assert-Test ($script:BootstrapperReport.Sources['Azure context'].Status -eq 'Confirmed') 'Selected Azure context was not recorded in the report.'

    $script:contextSelectionPromptMessages.Clear()
    $fileContext = Get-AMRLAzureContext -ExpectedSubscriptionId 'subscription-two' -ExpectedTenantId 'tenant' -RequireParameterFileContext
    Assert-Test ($fileContext.id -eq 'subscription-two' -and $script:contextSelectionPromptMessages.Count -eq 0) 'Matching parameter-file Azure context prompted for confirmation.'
    $contextMismatchRejected = $false
    try { Get-AMRLAzureContext -ExpectedSubscriptionId 'subscription-one' -ExpectedTenantId 'other-tenant' -RequireParameterFileContext }
    catch { $contextMismatchRejected = $_.Exception.Message -like '*does not match the explicit parameter file*' }
    Assert-Test ($contextMismatchRejected -and $script:contextSelectionPromptMessages.Count -eq 0) 'Mismatched parameter-file Azure context prompted instead of failing clearly.'
}

# The login fallback is tested separately from subscription selection: no current or saved context
# triggers az login, after which the normal context confirmation resumes.
& {
    $script:loginContextReady = $false
    $script:loginCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:loginAnswers = [System.Collections.Generic.Queue[string]]::new([string[]]@('new-tenant.example', 'yes'))
    Initialize-AMRLBootstrapperReport -Mode 'Login test'
    function Read-Host {
        param([string]$Prompt)
        if ($script:loginAnswers.Count -gt 0) { return $script:loginAnswers.Dequeue() }
        throw "Unexpected login prompt: $Prompt"
    }
    function Get-AzJson {
        param([string[]]$Arguments)
        if ($Arguments[0] -eq 'account' -and $Arguments[1] -eq 'show') {
            if (-not $script:loginContextReady) { throw 'Please run az login.' }
            return [pscustomobject]@{ id = 'logged-in-subscription'; tenantId = 'logged-in-tenant'; name = 'Signed-in subscription'; user = @{ name = 'operator' } }
        }
        if ($Arguments[0] -eq 'account' -and $Arguments[1] -eq 'list') { return @() }
        throw "Unexpected login lookup: $($Arguments -join ' ')"
    }
    function Invoke-AzCli {
        param([string[]]$Arguments)
        $script:loginCalls.Add(@($Arguments))
        if ($Arguments[0] -eq 'login') { $script:loginContextReady = $true }
        return ''
    }

    $loggedInContext = Get-AMRLAzureContext
    Assert-Test ($loggedInContext.id -eq 'logged-in-subscription') 'Context chooser did not continue after a new Azure login.'
    Assert-Test (@($script:loginCalls | Where-Object { $_[0] -eq 'login' -and $_[1] -eq '--tenant' -and $_[2] -eq 'new-tenant.example' }).Count -eq 1) 'Context chooser did not sign in to the supplied tenant.'
}

# Password-secret tests cover active-secret preservation, soft-delete recovery, random generation,
# secure entry, and noninteractive creation when no active or recoverable value exists.
& {
    $previousInteractive = $script:InteractiveConfiguration
    $previousPasswordChoiceMade = $script:PasswordChoiceMade
    $previousPromptForPasswords = $script:PromptForPasswords
    $script:passwordChoicePrompts = New-Object 'System.Collections.Generic.List[string]'
    $script:passwordSecretsExist = $true
    $script:passwordChoiceAnswer = ''
    $script:deletedPasswordSecrets = @()
    $script:securePasswordPromptCount = 0
    $script:passwordSecretWrites = 0
    $script:secretRecoveryCalls = 0
    $passwordSecretNames = @(Get-AMRLPasswordSecretNames)
    $adminPasswordSecretNames = @(
        (Get-AMRLDefault 'jumpboxAdminPasswordSecretName')
        (Get-AMRLDefault 'labAdminPasswordSecretName')
    )
    function Get-AzTsv {
        param([string[]]$Arguments)
        if ($Arguments -contains 'list-deleted') {
            $query = $Arguments[[Array]::IndexOf($Arguments, '--query') + 1]
            $deletedName = [regex]::Match($query, "\[\?name=='([^']+)'\]").Groups[1].Value
            if ($deletedName -in $script:deletedPasswordSecrets) { return $deletedName }
            return ''
        }
        if ($script:passwordSecretsExist) { return 'existing-secret' }
        return ''
    }
    function Invoke-AzCli {
        param([string[]]$Arguments)
        if ($Arguments -contains 'recover') { $script:secretRecoveryCalls++ }
        else { $script:passwordSecretWrites++ }
        return ''
    }
    function Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        if ($AsSecureString) {
            $script:securePasswordPromptCount++
            $securePassword = New-Object System.Security.SecureString
            foreach ($character in 'Test-only-password-123!'.ToCharArray()) {
                $securePassword.AppendChar($character)
            }
            return $securePassword
        }
        $script:passwordChoicePrompts.Add($Prompt)
        return $script:passwordChoiceAnswer
    }
    try {
        $script:InteractiveConfiguration = $true
        $script:PasswordChoiceMade = $false
        $script:PromptForPasswords = $false
        foreach ($secretName in $passwordSecretNames) {
            Set-AMRLSecretIfMissing -VaultName 'test-vault' -SecretName $secretName -Password
        }
        Assert-Test ($script:passwordChoicePrompts.Count -eq 0 -and $script:passwordSecretWrites -eq 0) 'Existing password secrets triggered a generation question or secret write.'

        $script:passwordSecretsExist = $false
        foreach ($secretName in $passwordSecretNames) {
            Set-AMRLSecretIfMissing -VaultName 'test-vault' -SecretName $secretName -Password -Prompt:$script:PromptForPasswords
        }
        Assert-Test ($script:passwordChoicePrompts.Count -eq 1) 'Missing passwords did not trigger exactly one generation question.'
        Assert-Test ($script:passwordChoicePrompts[0] -eq 'Randomly generate missing passwords? (Allowed: y/N) [yes]') 'Password generation question did not default to Yes.'
        Assert-Test ($script:passwordSecretWrites -eq $passwordSecretNames.Count -and $script:securePasswordPromptCount -eq 0) 'Default password handling did not generate missing passwords without secure prompts.'

        $script:PasswordChoiceMade = $false
        $script:passwordChoiceAnswer = 'no'
        foreach ($secretName in $passwordSecretNames) {
            Set-AMRLSecretIfMissing -VaultName 'test-vault' -SecretName $secretName -Password -Prompt:$script:PromptForPasswords
        }
        Assert-Test ($script:passwordChoicePrompts.Count -eq 2 -and $script:PromptForPasswords) 'Selecting No did not enable secure entry with a single question.'
        Assert-Test ($script:securePasswordPromptCount -eq 2 * $passwordSecretNames.Count) 'Secure password entry and confirmation were not used for each missing password.'

        $writesBeforeMissingServiceSecret = $script:passwordSecretWrites
        Set-AMRLSecretIfMissing -VaultName 'test-vault' -SecretName $serviceAccountPasswordSecretNames[0] -Password
        Assert-Test ($script:passwordSecretWrites -eq $writesBeforeMissingServiceSecret + 1) 'A missing service-account secret was not created when no deleted value was available.'

        $script:deletedPasswordSecrets = $adminPasswordSecretNames
        $recoveriesBeforeAdmin = $script:secretRecoveryCalls
        $writesBeforeAdminRecovery = $script:passwordSecretWrites
        foreach ($secretName in $adminPasswordSecretNames) {
            Set-AMRLSecretIfMissing -VaultName 'test-vault' -SecretName $secretName -Password
        }
        Assert-Test ($script:secretRecoveryCalls -eq $recoveriesBeforeAdmin + $adminPasswordSecretNames.Count -and $script:passwordSecretWrites -eq $writesBeforeAdminRecovery) 'Soft-deleted admin password secrets were not recovered instead of replaced.'

        $script:deletedPasswordSecrets = @($serviceAccountPasswordSecretNames[0])
        $recoveriesBefore = $script:secretRecoveryCalls
        Set-AMRLSecretIfMissing -VaultName 'test-vault' -SecretName $serviceAccountPasswordSecretNames[0] -Password
        Assert-Test ($script:secretRecoveryCalls -eq $recoveriesBefore + 1) 'A soft-deleted service-account secret was not recovered before creating a replacement.'

        $script:InteractiveConfiguration = $false
        $script:PasswordChoiceMade = $false
        $script:PromptForPasswords = $false
        $script:deletedPasswordSecrets = @()
        $promptsBeforeNoninteractive = $script:passwordChoicePrompts.Count
        $securePromptsBeforeNoninteractive = $script:securePasswordPromptCount
        $writesBeforeNoninteractive = $script:passwordSecretWrites
        Set-AMRLSecretIfMissing -VaultName 'test-vault' -SecretName $serviceAccountPasswordSecretNames[0] -Password
        Assert-Test ($script:passwordChoicePrompts.Count -eq $promptsBeforeNoninteractive -and $script:securePasswordPromptCount -eq $securePromptsBeforeNoninteractive -and $script:passwordSecretWrites -eq $writesBeforeNoninteractive + 1) 'Noninteractive setup did not create a missing service-account secret without prompting.'
    }
    finally {
        $script:InteractiveConfiguration = $previousInteractive
        $script:PasswordChoiceMade = $previousPasswordChoiceMade
        $script:PromptForPasswords = $previousPromptForPasswords
    }
}

# SSH key tests verify Key Vault pair precedence, pairwise soft-delete recovery, safe handling of
# incomplete pairs, and local pair generation only when Key Vault has neither key.
& {
    $script:sshPublicName = Get-AMRLDefault 'sshPublicKeySecretName'
    $script:sshPrivateName = Get-AMRLDefault 'sshPrivateKeySecretName'
    $script:sshActiveNames = @()
    $script:sshDeletedNames = @()
    $script:sshRecoveries = New-Object 'System.Collections.Generic.List[string]'
    $script:sshWrites = New-Object 'System.Collections.Generic.List[string]'
    $script:sshPrivateExists = $false
    $script:sshPublicExists = $false
    $script:sshDirectoryExists = $false
    $script:sshLocalPublic = 'ssh-ed25519 test-public-key'
    $script:sshDerivedPublic = 'ssh-ed25519 test-public-key'
    $script:sshVaultPublic = 'ssh-ed25519 test-public-key'
    $script:sshKeygenCalls = 0
    $script:sshWarnings = New-Object 'System.Collections.Generic.List[string]'

    function Get-AzJson {
        param([string[]]$Arguments)
        if ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'secret' -and $Arguments[2] -eq 'list-deleted') { return @($script:sshDeletedNames) }
        if ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'secret' -and $Arguments[2] -eq 'list') { return @($script:sshActiveNames) }
        throw "Unexpected SSH-key lookup: $($Arguments -join ' ')"
    }
    function Get-AzTsv {
        param([string[]]$Arguments)
        if ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'secret' -and $Arguments[2] -eq 'show') { return $script:sshVaultPublic }
        throw "Unexpected SSH-key scalar lookup: $($Arguments -join ' ')"
    }
    function Invoke-AzCli {
        param([string[]]$Arguments)
        $secretName = $Arguments[[Array]::IndexOf($Arguments, '--name') + 1]
        if ($Arguments -contains 'recover') {
            $script:sshRecoveries.Add($secretName)
            $script:sshActiveNames += $secretName
            $script:sshDeletedNames = @($script:sshDeletedNames | Where-Object { $_ -ne $secretName })
            return ''
        }
        if ($Arguments -contains 'set') {
            $script:sshWrites.Add($secretName)
            $script:sshActiveNames += $secretName
            return ''
        }
        throw "Unexpected SSH-key write: $($Arguments -join ' ')"
    }
    function Test-Path {
        param([string]$LiteralPath)
        if ($LiteralPath -eq (Join-Path $HOME '.ssh/amrl_ed25519')) { return $script:sshPrivateExists }
        if ($LiteralPath -eq (Join-Path $HOME '.ssh/amrl_ed25519.pub')) { return $script:sshPublicExists }
        if ($LiteralPath -eq (Join-Path $HOME '.ssh')) { return $script:sshDirectoryExists }
        return $false
    }
    function Get-Content {
        param([switch]$Raw, [string]$LiteralPath)
        if ($LiteralPath -eq (Join-Path $HOME '.ssh/amrl_ed25519.pub')) { return $script:sshLocalPublic }
        throw "Unexpected SSH-key file read: $LiteralPath"
    }
    function New-Item {
        param($ItemType, $Path, [switch]$Force)
        $script:sshDirectoryExists = $true
    }
    function Write-Warning {
        param([string]$Message)
        $script:sshWarnings.Add($Message)
    }
    function Invoke-AMRLTimedProcess {
        param([string]$Command, [string[]]$Arguments, [int]$TimeoutSeconds)
        $passphraseIndex = [Array]::IndexOf($Arguments, '-N') + 1
        Assert-Test ($passphraseIndex -gt 0 -and $Arguments[$passphraseIndex] -ceq '') 'Fresh SSH key generation did not pass an explicit empty passphrase through the quoted process path.'
        Assert-Test ($TimeoutSeconds -eq 30) 'Fresh SSH key generation did not use a bounded process timeout.'
        $script:sshKeygenCalls++
        $script:sshPrivateExists = $true
        $script:sshPublicExists = $true
        return [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = '' }
    }
    function Invoke-TestSshKeygen {
        $arguments = @($args | ForEach-Object { [string]$_ })
        $script:sshKeygenCalls++
        $global:LASTEXITCODE = 0
        if ($arguments -contains '-y') { return $script:sshDerivedPublic }
        $script:sshPrivateExists = $true
        $script:sshPublicExists = $true
        return ''
    }
    Set-Alias -Name ssh-keygen -Value Invoke-TestSshKeygen -Scope Local

    $sshVaultName = 'test-vault'
    $sshSecretNames = @($script:sshPublicName, $script:sshPrivateName)

    $script:sshActiveNames = @($sshSecretNames)
    Set-AMRLKeySecretsIfMissing -VaultName $sshVaultName
    Assert-Test ($script:sshWrites.Count -eq 0 -and $script:sshRecoveries.Count -eq 0 -and $script:sshKeygenCalls -eq 0) 'An existing Key Vault pair without local files was replaced or caused a new pair to be generated.'

    $script:sshPrivateExists = $true
    $script:sshPublicExists = $false
    $script:sshWarnings.Clear()
    Set-AMRLKeySecretsIfMissing -VaultName $sshVaultName
    Assert-Test ($script:sshWrites.Count -eq 0 -and $script:sshWarnings.Count -eq 1) 'An incomplete local copy prevented reuse of a complete Key Vault pair or was silently overwritten.'

    $script:sshActiveNames = @()
    $script:sshDeletedNames = @($sshSecretNames)
    $script:sshRecoveries.Clear()
    $script:sshPrivateExists = $false
    $script:sshPublicExists = $false
    Set-AMRLKeySecretsIfMissing -VaultName $sshVaultName
    Assert-Test (($script:sshRecoveries -join ',') -eq ($sshSecretNames -join ',') -and $script:sshWrites.Count -eq 0) 'A soft-deleted SSH pair was not recovered together without replacement.'

    $script:sshActiveNames = @($script:sshPublicName)
    $script:sshDeletedNames = @($script:sshPrivateName)
    $script:sshRecoveries.Clear()
    Set-AMRLKeySecretsIfMissing -VaultName $sshVaultName
    Assert-Test (($script:sshRecoveries -join ',') -eq $script:sshPrivateName -and $script:sshWrites.Count -eq 0) 'A mixed active/soft-deleted SSH pair was not completed by recovering only the deleted half.'

    $script:sshActiveNames = @()
    $script:sshDeletedNames = @($script:sshPublicName)
    $script:sshRecoveries.Clear()
    $partialDeletedRejected = $false
    try { Set-AMRLKeySecretsIfMissing -VaultName $sshVaultName }
    catch { $partialDeletedRejected = $_.Exception.Message -like '*Key Vault is incomplete*' }
    Assert-Test ($partialDeletedRejected -and $script:sshRecoveries.Count -eq 0 -and $script:sshWrites.Count -eq 0) 'A lone deleted SSH secret was recovered or replaced without its pair.'

    $script:sshDeletedNames = @()
    $script:sshActiveNames = @($script:sshPublicName)
    $partialActiveRejected = $false
    try { Set-AMRLKeySecretsIfMissing -VaultName $sshVaultName }
    catch { $partialActiveRejected = $_.Exception.Message -like '*Key Vault is incomplete*' }
    Assert-Test ($partialActiveRejected -and $script:sshWrites.Count -eq 0) 'An incomplete active Key Vault pair was silently completed or overwritten.'

    $script:sshActiveNames = @()
    $script:sshDeletedNames = @()
    $script:sshPrivateExists = $true
    $script:sshPublicExists = $true
    $script:sshLocalPublic = 'ssh-ed25519 test-public-key'
    $script:sshDerivedPublic = 'ssh-ed25519 test-public-key'
    $script:sshWrites.Clear()
    Set-AMRLKeySecretsIfMissing -VaultName $sshVaultName
    Assert-Test (($script:sshWrites -join ',') -eq ($sshSecretNames -join ',')) 'A valid local SSH pair was not uploaded when Key Vault had no active or deleted pair.'

    $script:sshActiveNames = @()
    $script:sshDeletedNames = @()
    $script:sshPrivateExists = $false
    $script:sshPublicExists = $false
    $script:sshDirectoryExists = $false
    $script:sshWrites.Clear()
    $script:sshKeygenCalls = 0
    Set-AMRLKeySecretsIfMissing -VaultName $sshVaultName
    Assert-Test ($script:sshKeygenCalls -eq 2 -and $script:sshWrites.Count -eq 2) 'A fresh key pair was not generated and uploaded when neither local nor Key Vault keys existed.'

    $script:sshActiveNames = @($sshSecretNames)
    $script:sshPrivateExists = $true
    $script:sshPublicExists = $true
    $script:sshLocalPublic = 'ssh-ed25519 test-public-key'
    $script:sshDerivedPublic = 'ssh-ed25519 test-public-key'
    $script:sshVaultPublic = 'ssh-ed25519 different-public-key'
    $script:sshWrites.Clear()
    $mismatchedVaultPairRejected = $false
    try { Set-AMRLKeySecretsIfMissing -VaultName $sshVaultName }
    catch { $mismatchedVaultPairRejected = $_.Exception.Message -like '*differs from the local key pair*' }
    Assert-Test ($mismatchedVaultPairRejected -and $script:sshWrites.Count -eq 0) 'A Key Vault public-key mismatch was overwritten instead of failing safely.'

    $script:sshVaultPublic = ''
    $malformedVaultKeyRejected = $false
    try { Set-AMRLKeySecretsIfMissing -VaultName $sshVaultName }
    catch { $malformedVaultKeyRejected = $_.Exception.Message -like '*differs from the local key pair*' }
    Assert-Test ($malformedVaultKeyRejected -and $script:sshWrites.Count -eq 0) 'An empty Key Vault public key caused an unhandled parsing error or pair replacement.'
}

# Stage-wizard tests verify which settings are asked for each stage and which parameter-file values
# remain untouched when a stage is selected or an explicit file is used.
& {
    $previousInteractive = $script:InteractiveConfiguration
    $previousPlanMode = $script:PlanMode
    $previousExplicitFile = $script:ParameterFileWasExplicit
    $stageParameterPath = Join-Path $env:TEMP ('amrl-stage-test-' + [guid]::NewGuid().ToString('N') + '.json')
    $sourceDocument = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'main.parameters.demo.json') | ConvertFrom-Json
    $sourceDocument.parameters.stage.value = 'network'
    [System.IO.File]::WriteAllText($stageParameterPath, (ConvertTo-AMRLParameterJson -InputObject $sourceDocument))
    $script:stagePrompts = New-Object 'System.Collections.Generic.List[string]'
    $script:stageAnswers = [System.Collections.Generic.Queue[string]]::new()
    function Read-Host {
        param([string]$Prompt)
        $script:stagePrompts.Add($Prompt)
        if ($Prompt.StartsWith('Deployment stage') -and $script:stageAnswers.Count -gt 0) {
            return $script:stageAnswers.Dequeue()
        }
        return ''
    }
    try {
        $script:InteractiveConfiguration = $true
        $script:PlanMode = $true
        $script:ParameterFileWasExplicit = $false
        foreach ($selectedStage in @('network', 'compute', 'identity', 'all')) {
            $script:stagePrompts.Clear()
            $script:stageAnswers = [System.Collections.Generic.Queue[string]]::new([string[]]@($selectedStage))
            $stageDocument = Get-ParameterDocument -Path $stageParameterPath
            Assert-Test ($stageDocument.parameters.stage.value -eq $selectedStage) "Wizard did not select stage '$selectedStage'."
            Assert-Test ($script:stagePrompts[0] -eq 'Deployment stage (Allowed: all, network, compute, identity) [network]') 'Stage was not the first wizard question with all options and the saved default.'
            $expectedPromptCounts = @{ network = 12; compute = 11; identity = 16; all = 17 }
            Assert-Test ($script:stagePrompts.Count -eq $expectedPromptCounts[$selectedStage]) "Stage '$selectedStage' prompted for unrelated settings or omitted required settings."
            $hasNetworkPrompt = @($script:stagePrompts | Where-Object { $_ -like 'Network mode*' }).Count -eq 1
            Assert-Test ($hasNetworkPrompt -eq ($selectedStage -in @('network', 'all'))) "Network mode prompt was incorrect for '$selectedStage'."
            $hasDirectoryPrompt = @($script:stagePrompts | Where-Object { $_ -like 'departmentCount *' }).Count -eq 1
            Assert-Test ($hasDirectoryPrompt -eq ($selectedStage -in @('identity', 'all'))) "Directory prompt was incorrect for '$selectedStage'."
            Assert-Test (@($script:stagePrompts | Where-Object { $_ -like 'VM count for *' }).Count -eq 6) "Stage '$selectedStage' omitted shared placement inputs."
            foreach ($setting in @('networkMode', 'departmentCount', 'usersPerDepartment', 'useDedicatedFileServer', 'enableWindowsAdminCenter', 'useDedicatedWacHost')) {
                Assert-Test ($stageDocument.parameters.$setting.value -ceq $sourceDocument.parameters.$setting.value) "Stage '$selectedStage' changed preserved setting '$setting'."
            }
        }
        $defaultStageDocument = Get-ParameterDocument -Path $stageParameterPath
        Assert-Test ($defaultStageDocument.parameters.stage.value -eq 'network') 'Accepting the default did not retain the parameter-file stage.'
        $script:InteractiveConfiguration = $false
        $script:ParameterFileWasExplicit = $true
        $script:stagePrompts.Clear()
        $explicitStageDocument = Get-ParameterDocument -Path $stageParameterPath
        Assert-Test ($explicitStageDocument.parameters.stage.value -ceq 'network') 'Explicit-file preparation did not preserve the saved stage.'
        Assert-Test ($script:stagePrompts.Count -eq 0) 'Explicit-file stage selection unexpectedly launched wizard prompts.'
        $savedStageDocument = Get-Content -Raw -LiteralPath $stageParameterPath | ConvertFrom-Json
        Assert-Test ($savedStageDocument.parameters.stage.value -eq 'network') 'Read-only stage selection changed the parameter file.'
        $script:InteractiveConfiguration = $true
        $script:ParameterFileWasExplicit = $false
        $script:stagePrompts.Clear()
        $script:stageAnswers = [System.Collections.Generic.Queue[string]]::new([string[]]@('invalid', 'COMPUTE'))
        $retriedStageDocument = Get-ParameterDocument -Path $stageParameterPath
        Assert-Test ($retriedStageDocument.parameters.stage.value -ceq 'compute') 'Wizard did not reject an invalid stage or normalize an accepted stage.'
        Assert-Test (@($script:stagePrompts | Where-Object { $_ -like 'Deployment stage*' }).Count -eq 2) 'Invalid stage did not repeat the stage question.'
        $script:PlanMode = $false
        $script:stageAnswers = [System.Collections.Generic.Queue[string]]::new([string[]]@('identity'))
        $null = Get-ParameterDocument -Path $stageParameterPath
        $savedStageDocument = Get-Content -Raw -LiteralPath $stageParameterPath | ConvertFrom-Json
        Assert-Test ($savedStageDocument.parameters.stage.value -eq 'identity') 'Preparation did not save the selected wizard stage.'
    }
    finally {
        $script:InteractiveConfiguration = $previousInteractive
        $script:PlanMode = $previousPlanMode
        $script:ParameterFileWasExplicit = $previousExplicitFile
        Remove-Item -LiteralPath $stageParameterPath -Force
    }
}

# Report-layout tests keep the human-readable summary useful while excluding raw ARM resource IDs
# and avoiding duplicate validation findings.
& {
    $script:reportLines = New-Object 'System.Collections.Generic.List[string]'
    Initialize-AMRLBootstrapperReport -Mode 'Report layout test'
    $script:BootstrapperReport.Parameters = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'main.parameters.demo.json') | ConvertFrom-Json
    $script:BootstrapperReport.Context = [pscustomobject]@{ id = 'test-subscription'; tenantId = 'test-tenant'; name = 'Test subscription'; user = @{ name = 'test-account' } }
    $script:BootstrapperReport.FoundationLocation = 'southafricanorth'
    $script:BootstrapperReport.FoundationConfiguration = [pscustomobject]@{ ResourceGroup = 'foundation-rg'; IdentityName = 'deployment-mi'; IdentityResourceGroup = 'identity-rg'; VaultName = 'credentials-kv'; VaultResourceGroup = 'vault-rg' }
    $script:BootstrapperReport.Validation = [pscustomobject]@{
        FindingsAvailable = $true
        EnforcementEnabled = $true
        Blocking = @([pscustomobject]@{ flag = 'invalidCapacity'; message = 'Too many VMs for the allowed capacity per region.' })
        Advisory = @([pscustomobject]@{ flag = 'invalidDepartmentCount'; message = 'Department count exceeds definitions.' })
        ShouldBlockDeployment = $true
    }
    Add-AMRLReportIssue -Phase 'AMRL validation engine' -Severity Error -Message 'BLOCKING [invalidCapacity] Too many VMs for the allowed capacity per region.' -NextStep 'Reduce VM counts or increase maxVmsPerRegion.'
    Add-AMRLReportIssue -Phase 'AMRL validation engine' -Severity Warning -Message 'ADVISORY [invalidDepartmentCount] Department count exceeds definitions.' -NextStep 'Reduce departmentCount or define more departments.'
    Set-AMRLReportPhase -Name 'Bicep build and validation' -Status 'Succeeded' -Summary 'Build, lint, and validate passed.'
    Set-AMRLReportSource -Name 'Azure deployment what-if' -Status 'Succeeded' -Summary '2 resource changes (Create: 1, Modify: 1).' -Details "Create: 1 Resource groups [example]: example`nModify: 1 Virtual networks [example]: vnet1"
    Set-AMRLReportSource -Name 'Applied resource changes' -Status 'Available' -Summary '1 resource operation returned.' -Details 'Create [Succeeded]: /subscriptions/test/resourceGroups/example'
    $script:BootstrapperReport.DeploymentState = 'Succeeded'
    $script:BootstrapperReport.DeploymentStages = @([pscustomobject]@{ Stage = 'Network'; Status = 'Succeeded'; Name = 'network-stage' })
    $script:BootstrapperReport.AppliedChanges = @([pscustomobject]@{ Stage = 'Network'; Region = 'example'; ResourceType = 'Resource groups'; Operation = 'Create'; Status = 'Succeeded'; Name = 'example' })
    function Write-Host {
        param([object]$Object)
        $script:reportLines.Add([string]$Object)
    }
    Write-AMRLBootstrapperReport
    $reportText = $script:reportLines -join [Environment]::NewLine
    Assert-Test ($reportText -match 'Configuration used:' -and $reportText -match 'Prefix: AMRL' -and $reportText -match 'Network mode: fullMesh') 'Report omitted effective parameter values.'
    foreach ($expectedValue in @('Azure account: test-account', 'Tenant: test-tenant', 'Subscription: Test subscription (test-subscription)', 'Foundation resource group: foundation-rg', 'Managed identity: deployment-mi', 'Managed identity resource group: identity-rg', 'Key Vault: credentials-kv', 'Key Vault resource group: vault-rg', 'Foundation location: southafricanorth')) {
        Assert-Test ($reportText.Contains($expectedValue)) "Configuration report omitted '$expectedValue'."
    }
    Assert-Test ($reportText -notmatch 'Capacity availability') 'Report displayed the removed capacity availability check.'
    Assert-Test ($reportText -match 'Planned resource changes \(what-if\):' -and $reportText -match 'Create: 1 Resource groups \[example\]: example') 'Report omitted planned resource changes.'
    Assert-Test ($reportText -match 'current Azure resources against the template and current parameter values') 'Report did not explain the what-if comparison baseline.'
    Assert-Test ($reportText -match 'Bicep deployment results:' -and $reportText -match 'Overall: Succeeded' -and $reportText -match 'Network: Succeeded' -and $reportText -match '1 Resource groups \[example\]: Create \[Succeeded\]') 'Report omitted applied resource changes.'
    Assert-Test ($reportText -notmatch '/subscriptions/|/providers/|Microsoft.Resources/deployments') 'Report displayed technical resource ID prefixes.'
    Assert-Test ($reportText -match '\[PASS\] Bicep build and validation') 'Report did not provide an easy-to-scan check status.'
    Assert-Test ($reportText -match 'Bicep validation findings:\r?\n  Mode: enforce; blocking: 1; advisory: 1\r?\n  Deployment gate: blocked') 'Bicep validation section included details beyond mode, counts, and gate status.'
    Assert-Test ([regex]::Matches($reportText, 'BLOCKING \[invalidCapacity\]').Count -eq 1) 'Blocking validation error was duplicated across report sections.'
    Assert-Test ($reportText -match '\[Error\] AMRL validation engine: BLOCKING \[invalidCapacity\] Too many VMs for the allowed capacity per region\.\r?\n    Next step: Reduce VM counts or increase maxVmsPerRegion\.') 'Blocking validation error or its next step was not reader-friendly in Warnings and errors.'
    Assert-Test ($reportText -match '\[Warning\] AMRL validation engine: ADVISORY \[invalidDepartmentCount\] Department count exceeds definitions\.\r?\n    Next step: Reduce departmentCount or define more departments\.') 'Advisory validation message or next step was not rendered in Warnings and errors.'
    Assert-Test ($reportText -notmatch 'Standard_B2ls_v2|vmSizes') 'Report displayed VM size configuration.'
    Assert-Test (@($script:reportLines | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -ge 6) 'Report sections were not separated with blank lines.'
    Assert-Test ($reportText -notmatch 'Regional availability checks') 'Report used the removed regional availability wording.'
    $script:BootstrapperReport.FoundationConfiguration.IdentityResourceGroup = 'foundation-rg'
    $script:BootstrapperReport.FoundationConfiguration.VaultResourceGroup = 'foundation-rg'
    $script:reportLines.Clear()
    Write-AMRLConfigurationSummary
    $sharedGroupConfiguration = $script:reportLines -join [Environment]::NewLine
    Assert-Test ([regex]::Matches($sharedGroupConfiguration, 'foundation-rg').Count -eq 1) 'Configuration repeated the shared foundation resource group.'
    Assert-Test ($sharedGroupConfiguration -notmatch 'Managed identity resource group:|Key Vault resource group:') 'Configuration displayed redundant resource-group labels.'
}

# Applied-operation summaries exclude read-only ARM operations and render concise resource names.
& {
    Initialize-AMRLBootstrapperReport -Mode 'Applied operation test'
    function Get-AzJson {
        param([string[]]$Arguments)
        return @(
            [pscustomobject]@{ properties = [pscustomobject]@{ provisioningOperation = 'Create'; provisioningState = 'Succeeded'; targetResource = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/example'; resourceType = 'Microsoft.Resources/resourceGroups' } } }
            [pscustomobject]@{ properties = [pscustomobject]@{ provisioningOperation = 'Read'; provisioningState = 'Succeeded'; targetResource = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/example'; resourceType = 'Microsoft.Resources/resourceGroups' } } }
        )
    }
    Set-AMRLDeploymentOperationReport -DeploymentName 'amrl-test'
    Assert-Test ($script:BootstrapperReport.AppliedChanges.Count -eq 1) 'Applied-change report included read-only deployment operations.'
    $appliedDetails = [string]$script:BootstrapperReport.Sources['Applied resource changes'].Details
    Assert-Test ($appliedDetails -match 'Create \[Succeeded\]: example' -and $appliedDetails -notmatch '/subscriptions/|/providers/') "Applied deployment resource details were not summarized: $appliedDetails"
}

# Resource-name helpers strip ARM path prefixes and group Run Commands by their owning VM in what-if output.
& {
    Assert-Test ((Get-AMRLResourceDisplayName -ResourceId '/subscriptions/test/resourceGroups/AMRL-rg-indonesiacentral/providers/Microsoft.Compute/virtualMachines/AMRL-cliwin01/runCommands/join-domain') -eq 'AMRL-cliwin01 / join-domain') 'Run Command label retained technical prefixes or lost its VM.'
    Assert-Test ((Get-AMRLResourceDisplayName -ResourceId '/subscriptions/test/providers/Microsoft.Resources/deployments/AMRL-identity-stage-test') -eq 'AMRL-identity-stage-test') 'Deployment label retained technical prefixes.'
    $planDetails = @(Get-AMRLPlannedChangeDetails -Changes @(
        [pscustomobject]@{ changeType = 'Modify'; resourceId = '/subscriptions/test/resourceGroups/AMRL-rg-indonesiacentral/providers/Microsoft.Compute/virtualMachines/AMRL-cliwin01/runCommands/join-domain' }
        [pscustomobject]@{ changeType = 'Modify'; resourceId = '/subscriptions/test/resourceGroups/AMRL-rg-indonesiacentral/providers/Microsoft.Compute/virtualMachines/AMRL-cliwin01/runCommands/install-tool' }
        [pscustomobject]@{ changeType = 'Delete'; resourceId = '/subscriptions/test/resourceGroups/AMRL-rg-indonesiacentral/providers/Microsoft.Compute/virtualMachines/old-vm' }
    ))
    Assert-Test ($planDetails.Count -eq 2 -and $planDetails[0] -match 'AMRL-cliwin01 \[indonesiacentral\].*install-tool, join-domain') 'Plan did not group commands under their VM and region.'
    Assert-Test ($planDetails[1] -match '^DELETE: 1 Virtual machines \[indonesiacentral\]: old-vm$') 'Plan deletion was not conspicuous or lost its type/region.'

    # Nested deployment records are wrappers; keep leaf resources, latest state, and stage attribution.
    $script:partialNestedOperations = $false
    $script:nestedOperationCalls = New-Object 'System.Collections.Generic.List[object]'
    function New-TestDeploymentOperation {
        param([string]$Id, [string]$State = 'Succeeded', [string]$Timestamp = '2026-11-03T11:00:00Z', [string]$Operation = 'Create', [string]$ErrorMessage = '')
        [pscustomobject]@{ properties = [pscustomobject]@{
            provisioningOperation = $Operation; provisioningState = $State; timestamp = $Timestamp
            targetResource = [pscustomobject]@{ id = $Id }; statusMessage = $ErrorMessage
        } }
    }
    function Get-AzJson {
        param([string[]]$Arguments)
        if ($Arguments -contains 'show') { return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Failed' } } }
        $script:nestedOperationCalls.Add(@($Arguments))
        $name = $Arguments[[array]::IndexOf($Arguments, '--name') + 1]
        switch ($name) {
            'root-test' {
                New-TestDeploymentOperation '/subscriptions/test/providers/Microsoft.Resources/deployments/AMRL-identity-stage-test' 'Failed' -ErrorMessage 'Identity stage failed.'
                New-TestDeploymentOperation '/subscriptions/test/providers/Microsoft.Resources/deployments/AMRL-network-stage-test'
                New-TestDeploymentOperation '/subscriptions/test/providers/Microsoft.Resources/deployments/AMRL-validation-engine-test'
                New-TestDeploymentOperation '/subscriptions/test/providers/Microsoft.Resources/deployments/AMRL-validation-gate-test'
            }
            'AMRL-identity-stage-test' {
                New-TestDeploymentOperation '/subscriptions/test/resourceGroups/AMRL-rg-indonesiacentral/providers/Microsoft.Resources/deployments/wac-module'
            }
            'wac-module' {
                New-TestDeploymentOperation '/subscriptions/test/resourceGroups/AMRL-rg-indonesiacentral/providers/Microsoft.Compute/virtualMachines/AMRL-srvwin01'
                New-TestDeploymentOperation '/subscriptions/test/resourceGroups/AMRL-rg-indonesiacentral/providers/Microsoft.Compute/virtualMachines/AMRL-srvwin01' 'Running' '2026-11-03T10:00:00Z'
                New-TestDeploymentOperation '/subscriptions/test/resourceGroups/AMRL-rg-indonesiacentral/providers/Microsoft.Compute/virtualMachines/AMRL-srvwin01/runCommands/install-wac' 'Failed' -ErrorMessage 'Test installer failure.'
                New-TestDeploymentOperation '/subscriptions/test/resourceGroups/AMRL-rg-indonesiacentral/providers/Microsoft.Network/virtualNetworks/existing' -Operation 'ReadData'
            }
            'AMRL-network-stage-test' {
                if ($script:partialNestedOperations) { throw 'Read denied' }
                New-TestDeploymentOperation '/subscriptions/test/resourceGroups/AMRL-rg-indonesiacentral/providers/Microsoft.Network/virtualNetworks/AMRL-vnet-indonesiacentral'
            }
            default { return @() }
        }
    }
    Initialize-AMRLBootstrapperReport -Mode 'Nested operation summary test'
    Set-AMRLDeploymentOperationReport -DeploymentName 'root-test'
    Assert-Test ($script:BootstrapperReport.Sources['Applied resource changes'].Status -eq 'Available' -and $script:BootstrapperReport.DeploymentState -eq 'Failed') 'Deployment status or operation collection state was lost.'
    Assert-Test ($script:BootstrapperReport.AppliedChanges.Count -eq 3) 'Nested summary included wrappers/read-only operations or duplicate resource identities.'
    $vm = @($script:BootstrapperReport.AppliedChanges | Where-Object { $_.ResourceType -eq 'Virtual machines' })[0]
    Assert-Test ($vm.Status -eq 'Succeeded' -and $vm.Stage -eq 'Identity' -and $vm.Region -eq 'indonesiacentral') 'Resource grouping or latest operation state was incorrect.'
    Assert-Test ($script:BootstrapperReport.DeploymentStages.Count -eq 4) 'Top-level stage outcomes were not retained independently of resource totals.'
    $resourceFailures = @($script:BootstrapperReport.Issues | Where-Object { $_.Phase -eq 'Deployment operations' })
    Assert-Test ($resourceFailures.Count -eq 1 -and $resourceFailures[0].Severity -eq 'Error' -and $resourceFailures[0].Message -match 'AMRL-srvwin01 / install-wac: Failed|Test installer failure') 'Leaf resource failure was not concise, correctly classified, or deduplicated from its deployment wrapper.'
    $script:summaryLines = New-Object 'System.Collections.Generic.List[string]'
    function Write-Host { param([object]$Object) $script:summaryLines.Add([string]$Object) }
    Write-AMRLBootstrapperReport
    $summaryText = $script:summaryLines -join [Environment]::NewLine
    Assert-Test ($summaryText -match 'Identity: Failed' -and $summaryText -match 'Validation: Succeeded' -and $summaryText -match 'AMRL-srvwin01 / install-wac: Create \[Failed\]') 'Report omitted stage outcomes or readable failed resource names.'
    Assert-Test ($summaryText -notmatch '/subscriptions/|/providers/|Microsoft.Compute|wac-module') 'Compact resource report displayed technical IDs or successful module wrappers.'
    $script:partialNestedOperations = $true
    Initialize-AMRLBootstrapperReport -Mode 'Partial nested summary test'
    Set-AMRLDeploymentOperationReport -DeploymentName 'root-test'
    Assert-Test ($script:BootstrapperReport.Sources['Applied resource changes'].Status -eq 'Partial' -and $script:BootstrapperReport.AppliedChanges.Count -eq 2) 'Unreadable nested deployment was treated as a complete summary or discarded other results.'
    Assert-Test (@($script:BootstrapperReport.Issues | Where-Object { $_.Message -like '*summary is incomplete*' }).Count -eq 1) 'Partial collection warning was not preserved.'
    Assert-Test (@($script:nestedOperationCalls | Where-Object { $_ -contains 'wac-module' -and $_[2] -eq 'group' -and $_ -contains '--resource-group' -and $_ -contains '--subscription' }).Count -eq 2) 'Nested group/subscription scope was not preserved.'
    $snapshotReport = $script:BootstrapperReport
    $snapshotReport.OperationSnapshotDeploymentName = 'failed-root'
    $snapshotReport.OperationSnapshots = @{
        'failed-root' = [pscustomobject]@{
            State = 'Running'; Stage = 'Deployment'; Depth = 0
            Operations = @([pscustomobject]@{ properties = [pscustomobject]@{ provisioningOperation = 'Create'; provisioningState = 'Running'; targetResource = [pscustomobject]@{ id = '/subscriptions/test/providers/Microsoft.Resources/deployments/AMRL-network-stage-test' } } })
        }
        '/subscriptions/test/providers/Microsoft.Resources/deployments/AMRL-network-stage-test' = [pscustomobject]@{
            State = 'Running'; Stage = 'Network stage'; Depth = 1
            Operations = @([pscustomobject]@{ properties = [pscustomobject]@{ provisioningOperation = 'Create'; provisioningState = 'Running'; targetResource = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Resources/deployments/AMRL-network-reconciliation' } } })
        }
    }
    $callsBeforeSnapshotReport = $script:nestedOperationCalls.Count
    Set-AMRLDeploymentOperationReport -DeploymentName 'failed-root' -UseOperationSnapshots -DeploymentState Failed -FailureMessage 'Network stage failed: AMRL-network-stage-test'
    Assert-Test ($script:nestedOperationCalls.Count -eq $callsBeforeSnapshotReport) 'Failure report re-queried Azure instead of using captured progress snapshots.'
    Assert-Test ($snapshotReport.DeploymentState -eq 'Failed' -and @($snapshotReport.DeploymentStages | Where-Object { $_.Stage -eq 'Network stage' -and $_.Status -eq 'Failed' }).Count -eq 1) 'Snapshot summary did not override the failed stage and overall state.'
    Assert-Test ($snapshotReport.Sources['Applied resource changes'].Status -eq 'Partial' -and $snapshotReport.Sources['Applied resource changes'].Summary -match 'last in-progress snapshots') 'Snapshot-only report was not labeled partial.'
    $script:summaryLines.Clear()
    Set-AMRLDeploymentOperationReport -DeploymentName 'root-test' -ShowProgress
    $progressText = $script:summaryLines -join [Environment]::NewLine
    Assert-Test ($progressText -match 'Reading deployment operations: root-test' -and $progressText -match 'Resource operation collection finished: 2 resource results; Partial') 'Operation collection did not announce work and completion.'
    Assert-Test ($progressText -notmatch '/subscriptions/|/providers/|install-wac') 'Collection progress duplicated detailed resource results or technical IDs.'
}

# Live-polling behavior is simulated: a fake deployment transitions through Running to Succeeded,
# and nested resource changes are emitted once with their owning stage.
& {
    $script:liveDeploymentCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:liveOperationCalls = New-Object 'System.Collections.Generic.List[object]'
    $script:liveProgressMessages = New-Object 'System.Collections.Generic.List[string]'
    $script:liveDeploymentPoll = 0
    function Invoke-AzCli {
        param([string[]]$Arguments)
        $script:liveDeploymentCalls.Add(@($Arguments))
        return ''
    }
    function Get-AzJson {
        param([string[]]$Arguments)
        if ($Arguments[0] -eq 'deployment' -and $Arguments[1] -eq 'sub' -and $Arguments[2] -eq 'show') {
            $script:liveDeploymentPoll++
            $state = if ($script:liveDeploymentPoll -lt 3) { 'Running' } else { 'Succeeded' }
            return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = $state } }
        }
        if ($Arguments[0] -eq 'deployment' -and $Arguments[1] -eq 'operation') {
            $script:liveOperationCalls.Add(@($Arguments))
            $operationDeploymentName = $Arguments[[array]::IndexOf($Arguments, '--name') + 1]
            if ($operationDeploymentName -eq 'A27-compute-stage-amrl-test') {
                return @(
                    [pscustomobject]@{ properties = [pscustomobject]@{ provisioningOperation = 'Create'; provisioningState = 'Running'; targetResource = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Resources/deployments/vm-module' } } }
                )
            }
            if ($operationDeploymentName -eq 'vm-module') {
                $vmState = if ($script:liveDeploymentPoll -eq 1) { 'Running' } else { 'Succeeded' }
                return @(
                    [pscustomobject]@{ properties = [pscustomobject]@{ provisioningOperation = 'Create'; provisioningState = $vmState; targetResource = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/A27-srvwin01' } } }
                    [pscustomobject]@{ properties = [pscustomobject]@{ provisioningOperation = 'Read'; provisioningState = 'Succeeded'; targetResource = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/existing-vnet' } } }
                    [pscustomobject]@{ properties = [pscustomobject]@{ provisioningOperation = 'Create'; provisioningState = 'Running'; targetResource = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Resources/deployments/vm-module' } } }
                )
            }
            if ($operationDeploymentName -eq 'A27-network-stage-amrl-test') {
                throw 'Nested operations not yet available.'
            }
            if ($operationDeploymentName -eq 'A27-identity-stage-amrl-test') {
                return @(
                    [pscustomobject]@{ properties = [pscustomobject]@{ provisioningOperation = 'Create'; provisioningState = 'Succeeded'; targetResource = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/A27-jmp01/runCommands/install-wac' } } }
                )
            }
            $networkState = if ($script:liveDeploymentPoll -eq 1) { 'Running' } else { 'Succeeded' }
            return @(
                [pscustomobject]@{ properties = [pscustomobject]@{ provisioningOperation = 'Create'; provisioningState = $networkState; targetResource = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Resources/deployments/A27-network-stage-amrl-test' } } }
                [pscustomobject]@{ properties = [pscustomobject]@{ provisioningOperation = 'Create'; provisioningState = 'Running'; targetResource = [pscustomobject]@{ id = '/subscriptions/test/providers/Microsoft.Resources/deployments/A27-compute-stage-amrl-test' } } }
                [pscustomobject]@{ properties = [pscustomobject]@{ provisioningOperation = 'Create'; provisioningState = 'Succeeded'; targetResource = [pscustomobject]@{ id = '/subscriptions/test/resourceGroups/rg/providers/Microsoft.Resources/deployments/A27-identity-stage-amrl-test' } } }
            )
        }
        throw "Unexpected live deployment query: $($Arguments -join ' ')"
    }
    function Start-Sleep { param([int]$Seconds) }
    function Write-Host { param([object]$Object) $script:liveProgressMessages.Add([string]$Object) }

    $completedDeployment = Invoke-AMRLDeploymentWithProgress -DeploymentName 'amrl-test' -DeploymentLocation 'westeurope' -TemplateFile 'main.bicep' -ParameterFile 'main.parameters.local.json' -PollIntervalSeconds 1
    $createCall = $script:liveDeploymentCalls[0]
    Assert-Test ($createCall -contains '--no-wait' -and $createCall -contains '--output' -and $createCall -contains 'none') 'Live deployment was not submitted asynchronously.'
    Assert-Test ($completedDeployment.properties.provisioningState -eq 'Succeeded' -and $script:liveDeploymentPoll -eq 3) 'Progress polling did not wait for terminal deployment success.'
    Assert-Test (@($script:liveProgressMessages | Where-Object { $_ -match '\[Network stage\].*Running' }).Count -eq 1) 'Network stage progress was not displayed.'
    Assert-Test (@($script:liveProgressMessages | Where-Object { $_ -match '\[Compute stage\] A27-compute-stage-amrl-test: Create Running' }).Count -eq 1) 'Compute stage progress was not displayed.'
    Assert-Test (@($script:liveProgressMessages | Where-Object { $_ -match '\[Identity stage\] A27-identity-stage-amrl-test: Create Succeeded' }).Count -eq 1) 'Identity stage progress was not displayed.'
    Assert-Test (@($script:liveProgressMessages | Where-Object { $_ -eq 'Azure deployment status: Running' }).Count -eq 1 -and @($script:liveProgressMessages | Where-Object { $_ -eq 'Azure deployment status: Succeeded' }).Count -eq 1) 'Overall deployment state transitions were not displayed.'
    Assert-Test (@($script:liveProgressMessages | Where-Object { $_ -match '\[Compute stage\].*A27-srvwin01: Create Running' }).Count -eq 1) 'Nested VM running state was not reported under compute.'
    Assert-Test (@($script:liveProgressMessages | Where-Object { $_ -match '\[Compute stage\].*A27-srvwin01: Create Succeeded' }).Count -eq 1) 'Final nested VM state was not collected.'
    Assert-Test (@($script:liveProgressMessages | Where-Object { $_ -match '\[Identity stage\].*A27-jmp01 / install-wac: Create Succeeded' }).Count -eq 1) 'Run Command progress was missing, duplicated, or lost its owning VM.'
    Assert-Test (@($script:liveProgressMessages | Where-Object { $_ -match 'existing-vnet' }).Count -eq 0) 'Read-only operations were displayed as changes.'
    Assert-Test (@($script:liveOperationCalls | Where-Object { $_ -contains 'A27-compute-stage-amrl-test' -and $_[2] -eq 'sub' -and $_ -contains '--subscription' -and $_ -contains 'test' }).Count -eq 2) 'Nested subscription deployment scope was not preserved.'
    Assert-Test (@($script:liveOperationCalls | Where-Object { $_ -contains 'vm-module' -and $_[2] -eq 'group' -and $_ -contains '--resource-group' -and $_ -contains 'rg' }).Count -eq 2) 'Nested resource-group deployments were not queried once per poll.'
}

Write-Host "Bootstrapper unit checks passed: $script:checks"