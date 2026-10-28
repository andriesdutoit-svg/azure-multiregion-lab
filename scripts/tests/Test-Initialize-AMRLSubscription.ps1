$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$scriptPath = Join-Path $repoRoot 'scripts/Initialize-AMRLSubscription.ps1'
. $scriptPath

$checks = 0
function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
    $script:checks++
}

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
    "automationManagedIdentityResourceId": { "value": "<AUTOMATION_MANAGED_IDENTITY_RESOURCE_ID>" },
    "jumpboxAllowedSources": { "value": ["<YOUR_PUBLIC_IP>/32"] },
    "jumpboxAdminPassword": { "reference": { "keyVault": { "id": "<KEYVAULT_ID>" }, "secretName": "jumpboxAdminPassword" } },
    "sshPublicKey": { "reference": { "keyVault": { "id": "<KEYVAULT_ID>" }, "secretName": "sshPublicKey" } }
  }
}
'@
$parameters = $parameterJson | ConvertFrom-Json
$updated = Set-AMRLParameterReferences `
    -Parameters $parameters `
    -KeyVaultId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/amrl-kv-test' `
    -IdentityId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/amrl-mi' `
    -PublicIp '203.0.113.12'
Assert-Test ($updated.parameters.jumpboxAdminPassword.reference.keyVault.id -like '*/vaults/amrl-kv-test') 'Key Vault references were not updated.'
Assert-Test ($updated.parameters.sshPublicKey.reference.keyVault.id -like '*/vaults/amrl-kv-test') 'SSH Key Vault reference was not updated.'
Assert-Test ($updated.parameters.automationManagedIdentityResourceId.value -like '*/userAssignedIdentities/amrl-mi') 'Managed identity reference was not updated.'
Assert-Test ($updated.parameters.jumpboxAllowedSources.value[0] -eq '203.0.113.12/32') 'Public IP placeholder was not replaced.'

$explicitParameters = $parameterJson | ConvertFrom-Json
$explicitParameters.parameters.jumpboxAllowedSources.value = @('<YOUR_PUBLIC_IP>/32', '198.51.100.27/32', '192.0.2.0/24')
$preserved = Set-AMRLParameterReferences `
    -Parameters $explicitParameters `
    -KeyVaultId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/amrl-kv-test' `
    -IdentityId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/amrl-mi' `
    -PublicIp '203.0.113.12'
Assert-Test ($preserved.parameters.jumpboxAllowedSources.value.Count -eq 3) 'Placeholder replacement dropped or merged explicit source ranges.'
Assert-Test ($preserved.parameters.jumpboxAllowedSources.value[0] -eq '203.0.113.12/32') 'Public IP placeholder was not replaced in place.'
Assert-Test ($preserved.parameters.jumpboxAllowedSources.value[1] -eq '198.51.100.27/32') 'Existing source range changed.'

$promptHost = Get-Command Read-Host -CommandType Function -ErrorAction SilentlyContinue
function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    return ''
}
$whatIfParameterPath = Join-Path ([System.IO.Path]::GetTempPath()) ('amrl-whatif-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $whatIfDocument = Get-ParameterDocument -Path $whatIfParameterPath -WhatIf
    Assert-Test (-not (Test-Path -LiteralPath $whatIfParameterPath)) 'Get-ParameterDocument wrote a file under -WhatIf.'
    Assert-Test ($whatIfDocument.parameters.regionCount.value -ge 1) 'The WhatIf parameter document was not prepared in memory.'
}
finally {
    Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    if ($null -ne $promptHost) {
        Set-Item Function:\Read-Host -Value $promptHost.ScriptBlock
    }
    if (Test-Path -LiteralPath $whatIfParameterPath) {
        Remove-Item -LiteralPath $whatIfParameterPath -Force
    }
}

$mismatchRejected = $false
try {
    Set-AMRLParameterReferences `
        -Parameters $explicitParameters `
        -KeyVaultId '/subscriptions/other/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/other-kv' `
        -IdentityId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/amrl-mi' `
        -PublicIp '203.0.113.12' | Out-Null
}
catch {
    $mismatchRejected = $true
}
Assert-Test $mismatchRejected 'A mismatched existing Key Vault reference was not rejected.'

$mutationCount = 0
Invoke-AMRLChange -WhatIf -Target 'local test' -Action 'attempt mutation' -Operation {
    $script:mutationCount++
} | Out-Null
Assert-Test ($mutationCount -eq 0) '-WhatIf did not suppress the wrapped mutation.'

$script:cliCalls = New-Object 'System.Collections.Generic.List[object]'
$script:roleAssignmentState = 'missing'
$script:federatedCredentialState = @()
$script:createdCredential = $null

function Get-AzTsv {
    param([string[]]$Arguments)
    if ($script:roleAssignmentState -eq 'present') { return '/subscriptions/test/providers/Microsoft.Authorization/roleAssignments/existing' }
    return ''
}

function Get-AzJson {
    param([string[]]$Arguments)
    return $script:federatedCredentialState
}

function Invoke-AzCli {
    param([string[]]$Arguments)
    $script:cliCalls.Add(@($Arguments))
    if ($Arguments -contains 'federated-credential' -and $Arguments -contains 'create') {
        $credentialPath = $Arguments[$Arguments.IndexOf('--parameters') + 1]
        $script:createdCredential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    }
    return ''
}

$oldWhatIf = $WhatIfPreference
try {
    $WhatIfPreference = $true
    Set-AMRLRoleAssignmentIfMissing `
        -AssigneeObjectId '11111111-1111-1111-1111-111111111111' `
        -PrincipalType ServicePrincipal `
        -Role 'Network Contributor' `
        -Scope '/subscriptions/test' | Out-Null
    Assert-Test ($script:cliCalls.Count -eq 0) 'A role assignment was created under -WhatIf.'
}
finally {
    $WhatIfPreference = $oldWhatIf
}

Set-AMRLRoleAssignmentIfMissing `
    -AssigneeObjectId '11111111-1111-1111-1111-111111111111' `
    -PrincipalType ServicePrincipal `
    -Role 'Network Contributor' `
    -Scope '/subscriptions/test' | Out-Null
Assert-Test ($script:cliCalls.Count -eq 1) 'A missing role assignment was not created.'
Assert-Test (($script:cliCalls[0] -join ' ') -match 'role assignment create') 'Unexpected Azure CLI call for role assignment.'

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

$sampleDeployment = [pscustomobject]@{
    name = 'amrl-20261028-120000'
    properties = [pscustomobject]@{
        outputs = [pscustomobject]@{
            validationSummary = [pscustomobject]@{ value = 'All validation checks passed.' }
            blockingValidationSummary = [pscustomobject]@{ value = 'No blocking findings.' }
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

$nestedDeployment = [pscustomobject]@{
    name = 'AMRL-validation-engine-amrl-20261028-12'
    properties = [pscustomobject]@{
        outputs = [pscustomobject]@{
            validationMessage = [pscustomobject]@{ value = 'Deployment blocked by validation enforcement.' }
            blockingValidationDetails = [pscustomobject]@{ value = @([pscustomobject]@{ flag = 'hasNoJumpboxes'; message = 'No jumpbox.'; remediation = 'Request a jumpbox.' }) }
            advisoryValidationDetails = [pscustomobject]@{ value = @() }
        }
    }
}
$nestedReport = Get-AMRLValidationReport -Deployment $nestedDeployment
Assert-Test ($nestedReport.Summary -eq 'Deployment blocked by validation enforcement.') 'Nested validation message was not used as the report summary.'
Assert-Test ($nestedReport.Blocking[0].flag -eq 'hasNoJumpboxes') 'Nested blocking details were not extracted.'
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

Write-Host "Bootstrapper unit checks passed: $script:checks"