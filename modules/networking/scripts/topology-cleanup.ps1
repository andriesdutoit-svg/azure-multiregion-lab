param()

$networkMode = $env:NETWORK_MODE
$hubRegion = $env:HUB_REGION
$existingRegions = $env:EXISTING_REGIONS -split ','
$prefix = $env:PREFIX
$executePeeringCleanup = $env:EXECUTE_PEERING_CLEANUP -eq 'True'

Disable-AzContextAutosave -Scope Process

Connect-AzAccount -Identity | Out-Null

$context = Get-AzContext

Write-Output '[Info] Deployment script authenticated with its managed identity.'

$peeringsToRemove = @()

foreach ($sourceRegion in $existingRegions)
{
    foreach ($targetRegion in $existingRegions)
    {
        if (
            $sourceRegion -ne $targetRegion -and
            $sourceRegion -ne $hubRegion -and
            $targetRegion -ne $hubRegion
        )
        {
            $peeringsToRemove += [PSCustomObject]@{
                ResourceGroup = "$prefix-rg-$sourceRegion"
                VnetName      = "$prefix-vnet-$sourceRegion"
                PeeringName   = "$prefix-vnet-$sourceRegion-to-$prefix-vnet-$targetRegion"
            }
        }
    }
}

$foundPeerings = @()
$missingPeerings = @()
$deletedPeerings = @()
$deleteFailures = @()

foreach ($peering in $peeringsToRemove)
{
    $existingPeering = Get-AzVirtualNetworkPeering `
        -ResourceGroupName $peering.ResourceGroup `
        -VirtualNetworkName $peering.VnetName `
        -Name $peering.PeeringName `
        -ErrorAction SilentlyContinue

    if ($null -ne $existingPeering)
    {
        $foundPeerings += $peering.PeeringName

        if ($executePeeringCleanup)
        {
            try
            {
                Remove-AzVirtualNetworkPeering `
                    -ResourceGroupName $peering.ResourceGroup `
                    -VirtualNetworkName $peering.VnetName `
                    -Name $peering.PeeringName `
                    -Force `
                    -ErrorAction Stop


                $deletedPeerings += $peering.PeeringName
            }
            catch
            {
                $deleteFailures += $peering.PeeringName
                Write-Output "[Warning] Failed to remove candidate peering $($peering.PeeringName); review deployment diagnostics."
            }
        }
    }

}

Write-Output "[Info] Cleanup mode: network=$networkMode; hub=$hubRegion; declared regions=$($existingRegions.Count)."
Write-Output "[Info] Cleanup summary: candidates=$($peeringsToRemove.Count); found=$($foundPeerings.Count); removed=$($deletedPeerings.Count); failures=$($deleteFailures.Count)."

# This is the Azure Deployment Scripts output contract.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments',
    'DeploymentScriptOutputs',
    Justification = 'Azure Deployment Scripts reads this reserved output variable after the script completes.'
)]

$DeploymentScriptOutputs = @{
    PeeringsToRemove = ($peeringsToRemove | ConvertTo-Json -Compress)
    MissingPeerings   = ($missingPeerings | ConvertTo-Json -Compress)
    FoundPeerings = ($foundPeerings | ConvertTo-Json -Compress)
    DeletedPeerings = ($deletedPeerings | ConvertTo-Json -Compress)
    DeleteFailures = ($deleteFailures | ConvertTo-Json -Compress)
}