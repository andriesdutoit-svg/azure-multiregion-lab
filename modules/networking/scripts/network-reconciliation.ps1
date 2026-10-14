<#
.SYNOPSIS
Performs bounded cleanup of declared lab peerings and disabled Bastion resources.
.DESCRIPTION
Consumes NETWORK_MODE, HUB_REGION, EXISTING_REGIONS, PREFIX, and ENABLE_BASTION
from the deployment-script environment. Targets framework-named resources in
declared existing regions, not arbitrary Azure resource discovery.
Peering queries/removals run only for hubSpoke or hubSpokeFirewall. Bastion cleanup
runs independently when ENABLE_BASTION is false, including fullMesh deployments.
Authenticates with the supplied managed identity and records found/deleted/failed
targets through DeploymentScriptOutputs. Retained jumpbox Public IPs are untouched.
.NOTES
The Bicep caller controls script instantiation. Removal needs network permissions;
missing targets are tolerated, and caught deletion failures become warnings rather
than a guaranteed deployment failure. Review outputs to confirm cleanup results.
#>

# 1. Desired-state inputs and framework resource identities
param()

$networkMode = $env:NETWORK_MODE
$hubRegion = $env:HUB_REGION
$existingRegions = $env:EXISTING_REGIONS -split ','
$prefix = $env:PREFIX
$enableBastion = $env:ENABLE_BASTION -eq 'True'

# Script instantiation and action selection are separate: being invoked for Bastion
# cleanup must not remove peerings that still belong to a full-mesh target topology.
$requiresPeeringCleanup =
    $networkMode -eq 'hubSpoke' -or
    $networkMode -eq 'hubSpokeFirewall'

$resourceGroupName = "$prefix-rg-$hubRegion"

$bastionName = "$prefix-bas-$hubRegion"
$bastionPublicIpName = "$prefix-bas-pip-$hubRegion"
$vnetName = "$prefix-vnet-$hubRegion"

# 2. Process-scoped managed-identity authentication
Disable-AzContextAutosave -Scope Process

Connect-AzAccount -Identity | Out-Null

Write-Output '[Info] Deployment script authenticated with its managed identity.'

# Initialize results outside action gates so skipped actions still have an output shape.
$peeringsToRemove = @()

$foundPeerings = @()
$missingPeerings = @()
$deletedPeerings = @()
$deleteFailures = @()

$foundBastionResources = @()
$deletedBastionResources = @()
$bastionDeleteFailures = @()

# 3. Candidate peering enumeration and removal
# Both enumeration and Azure peering operations are gated by the desired topology.
# Candidate names come from declared spoke pairs and framework naming conventions;
# hub connections and same-region pairs are excluded, without Azure-wide discovery.

if ($requiresPeeringCleanup)
{
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
}
else
{
    Write-Output "[Info] Peering reconciliation skipped because networkMode '$networkMode' does not require cleanup."
}

Write-Output "[Info] Reconciliation mode: network=$networkMode; hub=$hubRegion; declared regions=$($existingRegions.Count)."
Write-Output "[Info] Reconciliation summary: candidates=$($peeringsToRemove.Count); found=$($foundPeerings.Count); removed=$($deletedPeerings.Count); failures=$($deleteFailures.Count)."

# 4. Disabled Bastion cleanup: host, Public IP, then dedicated subnet
# This gate is intentionally separate from peering cleanup: fullMesh can retire Bastion
# without peering queries/removals, while hub-spoke can clean peerings and retain Bastion.
# Each removal is independently caught; a failed host/IP removal can also prevent subnet removal.
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

# 5. Azure Deployment Scripts output contract
# These summaries distinguish attempted and confirmed actions; deployment success alone
# is not proof that every candidate was removed.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments',
    'DeploymentScriptOutputs',
    Justification = 'Azure Deployment Scripts reads this reserved output variable after the script completes.'
)]

$DeploymentScriptOutputs = @{
    PeeringsToRemove       = ($peeringsToRemove | ConvertTo-Json -Compress)
    MissingPeerings        = ($missingPeerings | ConvertTo-Json -Compress)
    FoundPeerings          = ($foundPeerings | ConvertTo-Json -Compress)
    DeletedPeerings        = ($deletedPeerings | ConvertTo-Json -Compress)
    DeleteFailures         = ($deleteFailures | ConvertTo-Json -Compress)

    FoundBastionResources   = ($foundBastionResources | ConvertTo-Json -Compress)
    DeletedBastionResources = ($deletedBastionResources | ConvertTo-Json -Compress)
    BastionDeleteFailures  = ($bastionDeleteFailures | ConvertTo-Json -Compress)
}