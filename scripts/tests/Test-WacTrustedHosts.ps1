$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$scriptPath = Join-Path $repoRoot 'modules/identity/scripts/Install-WAC.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'WAC installer did not parse.' }
$helper = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-AmrlWacTrustedHosts'
}, $true)
if ($null -eq $helper) { throw 'WAC TrustedHosts helper is missing.' }
Invoke-Expression $helper.Extent.Text

$script:checks = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Get-CimInstance {
    param($ClassName, $ErrorAction)
    [pscustomobject]@{ PartOfDomain = $script:domainJoined }
}
function Set-WACWinRmTrustedHosts {
    param($ErrorAction)
    $script:domainCalls++
}
function Get-Item {
    param($LiteralPath, $ErrorAction)
    $script:reads++
    Assert-Test ($LiteralPath -eq 'WSMan:\localhost\Client\TrustedHosts') 'Unexpected WinRM path.'
    [pscustomobject]@{ Value = $script:trustedHosts }
}
function Set-Item {
    param($LiteralPath, $Value, [switch]$Force, $ErrorAction)
    $script:writes++
    Assert-Test ($Force -and $LiteralPath -eq 'WSMan:\localhost\Client\TrustedHosts') 'Unexpected write.'
    if (-not $script:ignoreWrite) { $script:trustedHosts = $Value }
}
function Write-Log { param($Message) }

$script:domainJoined = $false
$script:domainCalls = 0
$script:reads = 0
$script:writes = 0
$script:ignoreWrite = $false
$script:trustedHosts = ''
$targetsJson = '["AMRL-srvwin01.amrl.lab","AMRL-cliwin01.amrl.lab","amrl-srvwin01.amrl.lab"]'
Set-AmrlWacTrustedHosts -TargetFqdnsJson $targetsJson
Assert-Test ($script:writes -eq 1 -and $script:domainCalls -eq 0) 'Fresh workgroup setup did not use only the explicit path.'
$actualHosts = @($script:trustedHosts -split ',')
Assert-Test ($actualHosts.Count -eq 2 -and 'AMRL-srvwin01.amrl.lab' -in $actualHosts -and 'AMRL-cliwin01.amrl.lab' -in $actualHosts) 'Targets were omitted or duplicated.'
Set-AmrlWacTrustedHosts -TargetFqdnsJson $targetsJson
Assert-Test ($script:writes -eq 1) 'Rerun unnecessarily rewrote TrustedHosts.'

$script:trustedHosts = ' retained.example.test ,AMRL-SRVWIN01.AMRL.LAB'
Set-AmrlWacTrustedHosts -TargetFqdnsJson $targetsJson
Assert-Test ('retained.example.test' -in ($script:trustedHosts -split ',')) 'Existing trust was removed.'
Assert-Test (@($script:trustedHosts -split ',').Count -eq 3) 'Merge did not preserve and deduplicate entries.'

$writesBefore = $script:writes
Set-AmrlWacTrustedHosts -TargetFqdnsJson '[]'
Assert-Test ($script:writes -eq $writesBefore) 'Empty targets changed TrustedHosts.'
foreach ($invalidJson in @('["*"]', '["*.amrl.lab"]', '["server"]', '["server.amrl.lab,other.amrl.lab"]', '[null]', 'not-json')) {
    $rejected = $false
    try { Set-AmrlWacTrustedHosts -TargetFqdnsJson $invalidJson }
    catch { $rejected = $true }
    Assert-Test $rejected "Invalid targets were accepted: $invalidJson"
}
Assert-Test ($script:writes -eq $writesBefore) 'Invalid targets changed TrustedHosts.'

$script:trustedHosts = '*'
Set-AmrlWacTrustedHosts -TargetFqdnsJson $targetsJson
Assert-Test ('*' -notin ($script:trustedHosts -split ',')) 'Pre-existing allow-all trust was not replaced by explicit targets.'
Assert-Test ('AMRL-srvwin01.amrl.lab' -in ($script:trustedHosts -split ',')) 'Explicit targets were not added after removing allow-all trust.'
$script:trustedHosts = 'existing.example.test,*'
Set-AmrlWacTrustedHosts -TargetFqdnsJson $targetsJson
Assert-Test ('existing.example.test' -in ($script:trustedHosts -split ',')) 'Existing specific trust was removed while replacing allow-all trust.'
Assert-Test ('*' -notin ($script:trustedHosts -split ',')) 'Allow-all trust was retained with specific target entries.'

$script:trustedHosts = ''
$script:ignoreWrite = $true
$verificationFailed = $false
try { Set-AmrlWacTrustedHosts -TargetFqdnsJson $targetsJson }
catch { $verificationFailed = $_.Exception.Message -like '*verification failed*' }
Assert-Test $verificationFailed 'Unapplied settings were reported as verified.'

$script:domainJoined = $true
$readsBefore = $script:reads
$writesBefore = $script:writes
Set-AmrlWacTrustedHosts -TargetFqdnsJson $targetsJson
Set-AmrlWacTrustedHosts -TargetFqdnsJson $targetsJson
Assert-Test ($script:domainCalls -eq 2) 'Domain-joined fresh/rerun path did not retain the existing WAC cmdlet.'
Assert-Test ($script:reads -eq $readsBefore -and $script:writes -eq $writesBefore) 'Domain-joined branch touched workgroup trust settings.'

Write-Output "WAC TrustedHosts tests passed: $script:checks assertions."