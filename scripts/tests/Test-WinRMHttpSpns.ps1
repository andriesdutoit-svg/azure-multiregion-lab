$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$scriptPath = Join-Path $repoRoot 'modules/identity/scripts/Reconcile-WinRMHttpSpns.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'SPN repair script did not parse.' }
$functionAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-AmrlWinRMHttpSpns'
}, $true)
if ($null -eq $functionAst) { throw 'SPN repair function is missing.' }
Invoke-Expression $functionAst.Extent.Text

$script:checks = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

$script:computerSystem = [pscustomobject]@{ Name = 'AMRL-srvwin01'; PartOfDomain = $true; Domain = 'amrl.lab' }
$script:secureChannelCalls = 0
$script:secureReadyAfter = 1
$script:requireSecureBeforeSpn = $true
$script:sleepCalls = 0
$script:listingFailures = 0
$script:registeredSpns = @()
$script:spnAdds = New-Object 'System.Collections.Generic.List[string]'

function Get-CimInstance {
    param([string]$ClassName, $ErrorAction)
    $script:computerSystem
}
function Test-ComputerSecureChannel {
    param($ErrorAction)
    $script:secureChannelCalls++
    return $script:secureChannelCalls -ge $script:secureReadyAfter
}
function Resolve-AmrlComputerAccountName {
    param([object]$ComputerSystem)
    'AMRL\' + $ComputerSystem.Name + '$'
}
function Invoke-AmrlSetSpn {
    param([string[]]$Arguments)
    if ($script:requireSecureBeforeSpn -and $script:secureChannelCalls -lt $script:secureReadyAfter) {
        throw 'SPN operation ran before secure channel readiness.'
    }
    if ($Arguments[0] -eq '-L') {
        if ($script:listingFailures -gt 0) {
            $script:listingFailures--
            return [pscustomobject]@{ ExitCode = 1; Output = @('LDAP bind failed') }
        }
        return [pscustomobject]@{ ExitCode = 0; Output = @($script:registeredSpns) }
    }
    if ($Arguments[0] -eq '-S') {
        $script:spnAdds.Add($Arguments[1])
        $script:registeredSpns += $Arguments[1]
        return [pscustomobject]@{ ExitCode = 0; Output = @('Registered') }
    }
    throw "Unexpected setspn arguments: $($Arguments -join ' ')"
}
function Write-AmrlSpnLog { param([string]$Message) }
function Start-Sleep {
    param([int]$Seconds)
    $script:sleepCalls++
}

$script:secureChannelCalls = 0
$script:secureReadyAfter = 3
$script:sleepCalls = 0
Set-AmrlWinRMHttpSpns -ExpectedDomain 'amrl.lab' -MaximumAttempts 5 -RetryDelaySeconds 1
Assert-Test ($script:secureChannelCalls -eq 3 -and $script:sleepCalls -eq 2) "SPN repair did not wait for the machine secure channel (checks=$script:secureChannelCalls; sleeps=$script:sleepCalls)."
Assert-Test ($script:spnAdds.Count -eq 2 -and $script:registeredSpns.Count -eq 2) 'SPN repair did not register both HTTP SPNs.'

$addsBeforeRerun = $script:spnAdds.Count
$script:secureChannelCalls = 0
$script:secureReadyAfter = 1
Set-AmrlWinRMHttpSpns -ExpectedDomain 'amrl.lab' -MaximumAttempts 3 -RetryDelaySeconds 1
Assert-Test ($script:spnAdds.Count -eq $addsBeforeRerun) 'Rerunning SPN repair duplicated already-registered SPNs.'

$script:registeredSpns = @()
$script:listingFailures = 1
$script:secureChannelCalls = 0
$script:secureReadyAfter = 1
$script:sleepCalls = 0
$addsBeforeTransient = $script:spnAdds.Count
Set-AmrlWinRMHttpSpns -ExpectedDomain 'amrl.lab' -MaximumAttempts 3 -RetryDelaySeconds 1
Assert-Test ($script:sleepCalls -eq 1 -and $script:spnAdds.Count -eq ($addsBeforeTransient + 2)) 'Transient LDAP failure was not retried before SPN registration.'

$script:secureChannelCalls = 0
$script:secureReadyAfter = 100
$script:sleepCalls = 0
$boundedFailure = $false
try { Set-AmrlWinRMHttpSpns -ExpectedDomain 'amrl.lab' -MaximumAttempts 3 -RetryDelaySeconds 1 }
catch { $boundedFailure = $_.Exception.Message -like '*failed after 3 attempts*' }
Assert-Test ($boundedFailure -and $script:secureChannelCalls -eq 3 -and $script:sleepCalls -eq 2) 'Unready secure channel did not fail after the configured retry bound.'

$script:computerSystem.Domain = 'other.lab'
$script:secureChannelCalls = 0
$script:sleepCalls = 0
$domainMismatch = $false
try { Set-AmrlWinRMHttpSpns -ExpectedDomain 'amrl.lab' -MaximumAttempts 3 -RetryDelaySeconds 1 }
catch { $domainMismatch = $_.Exception.Message -like '*not expected domain*' }
Assert-Test ($domainMismatch -and $script:secureChannelCalls -eq 0 -and $script:sleepCalls -eq 0) 'Wrong-domain machines were retried or modified.'

$joinSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'modules/identity/scripts/Join-Domain.ps1')
$joinBicep = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'modules/identity/domain-join.bicep')
$spnBicep = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'modules/identity/domain-join-spn.bicep')
$stageSource = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'modules/stages/identity-stage.bicep')
Assert-Test ($joinSource -notmatch 'Set-AmrlWinRMHttpSpns' -and $joinBicep -notmatch 'reconcile-winrm-spns') 'Domain join still performs SPN repair before reboot.'
Assert-Test ($spnBicep -match 'timeoutInSeconds:\s*1200' -and $spnBicep -match 'treatFailureAsDeploymentFailure:\s*true') 'Post-join SPN repair lacks bounded Run Command execution.'
Assert-Test ($stageSource -match '(?s)module domainJoinWindowsSpns.*?dependsOn:\s*\[\s*domainJoinWindows\s*\]' -and $stageSource -match '(?s)module windowsAdminCenter.*?domainJoinWindowsSpns') 'Identity-stage SPN repair or WAC dependency is missing.'
Assert-Test ($stageSource -match '(?s)module fileServices.*?dependsOn:\s*\[\s*adPopulate\s*domainJoinWindows\s*\]') 'File services unexpectedly depend on SPN repair.'

Write-Output "Windows post-join SPN reconciliation tests passed: $script:checks assertions."
