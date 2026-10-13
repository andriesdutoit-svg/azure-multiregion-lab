param()

$networkMode = $env:NETWORK_MODE
$hubRegion = $env:HUB_REGION
$existingRegions = $env:EXISTING_REGIONS -split ','
$prefix = $env:PREFIX
$enableBastion = $env:ENABLE_BASTION -eq 'True'

$resourceGroupName = "$prefix-rg-$hubRegion"

$bastionName = "$prefix-bas-$hubRegion"
$bastionPublicIpName = "$prefix-bas-pip-$hubRegion"
$vnetName = "$prefix-vnet-$hubRegion"

Disable-AzContextAutosave -Scope Process

Connect-AzAccount -Identity | Out-Null

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

$foundBastionResources = @()
$deletedBastionResources = @()
$bastionDeleteFailures = @()

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

        try
        {
            Remove-AzVirtualNetworkPeering `
                -ResourceGroupName $peering.ResourceGroup `
                -VirtualNetworkName $peering.VnetName `
                -Name $peering.PeeringName `
                -Force `
                -ErrorAction Stop

            $deletedPeerings += $peering.PeeringName
            Write-Output "[Info] Removed spoke-to-spoke peering: $($peering.PeeringName)."
        }
        catch
        {
            $deleteFailures += $peering.PeeringName
            Write-Output "[Warning] Failed to remove candidate peering $($peering.PeeringName); review deployment diagnostics."
        }
    }

}

Write-Output "[Info] Reconciliation mode: network=$networkMode; hub=$hubRegion; declared regions=$($existingRegions.Count)."
Write-Output "[Info] Reconciliation summary: candidates=$($peeringsToRemove.Count); found=$($foundPeerings.Count); removed=$($deletedPeerings.Count); failures=$($deleteFailures.Count)."

if (-not $enableBastion)
{
    $bastionResource = Get-AzResource `
        -ResourceGroupName $resourceGroupName `
        -ResourceType 'Microsoft.Network/bastionHosts' `
        -Name $bastionName `
        -ErrorAction SilentlyContinue

    if ($null -ne $bastionResource)
    {
        $foundBastionResources += $bastionName

        Write-Output "[Info] Bastion reconciliation candidate detected: $bastionName."

        try
        {
            Remove-AzResource `
                -ResourceId $bastionResource.ResourceId `
                -Force `
                -ErrorAction Stop

            $deletedBastionResources += $bastionName

            Write-Output "[Info] Removed Bastion host: $bastionName."
        }
        catch
        {
            $bastionDeleteFailures += $bastionName

            Write-Output "[Warning] Failed to remove Bastion host: $bastionName."
        }
    }

    $publicIpResource = Get-AzPublicIpAddress `
        -ResourceGroupName $resourceGroupName `
        -Name $bastionPublicIpName `
        -ErrorAction SilentlyContinue

    if ($null -ne $publicIpResource)
    {
        $foundBastionResources += $bastionPublicIpName

        Write-Output "[Info] Bastion reconciliation candidate detected: $bastionPublicIpName."

        try
        {
            Remove-AzPublicIpAddress `
                -ResourceGroupName $resourceGroupName `
                -Name $bastionPublicIpName `
                -Force `
                -ErrorAction Stop

            $deletedBastionResources += $bastionPublicIpName

            Write-Output "[Info] Removed Bastion public IP: $bastionPublicIpName."
        }
        catch
        {
            $bastionDeleteFailures += $bastionPublicIpName

            Write-Output "[Warning] Failed to remove Bastion public IP: $bastionPublicIpName."
        }
    }

    $vnet = Get-AzVirtualNetwork `
        -ResourceGroupName $resourceGroupName `
        -Name $vnetName `
        -ErrorAction SilentlyContinue

    if ($null -ne $vnet)
    {
        $bastionSubnet = $vnet.Subnets | Where-Object {
            $_.Name -eq 'AzureBastionSubnet'
        }

        if ($null -ne $bastionSubnet)
        {
            $foundBastionResources += 'AzureBastionSubnet'

            Write-Output '[Info] Bastion reconciliation candidate detected: AzureBastionSubnet.'

            try
            {
                $vnet = Remove-AzVirtualNetworkSubnetConfig `
                    -Name 'AzureBastionSubnet' `
                    -VirtualNetwork $vnet

                $null = Set-AzVirtualNetwork `
                    -VirtualNetwork $vnet `
                    -ErrorAction Stop

                $deletedBastionResources += 'AzureBastionSubnet'

                Write-Output '[Info] Removed AzureBastionSubnet.'
            }
            catch
            {
                $bastionDeleteFailures += 'AzureBastionSubnet'

                Write-Output '[Warning] Failed to remove AzureBastionSubnet.'
            }
        }
    }
}

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

    FoundBastionResources = ($foundBastionResources | ConvertTo-Json -Compress)
    DeletedBastionResources = ($deletedBastionResources | ConvertTo-Json -Compress)
    BastionDeleteFailures = ($bastionDeleteFailures | ConvertTo-Json -Compress)
}