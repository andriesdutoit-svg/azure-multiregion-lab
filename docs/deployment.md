# Deployment Guide

[Back to README](../README.md)

## Prerequisites

- Azure CLI installed and authenticated.
- Access to the target subscription.
- A Key Vault containing the referenced credentials and SSH keys.
- VM sizes, images, regional quota, and regional availability verified for the subscription.
- A parameter file with valid region, network, compute, and identity settings.

## Greenfield Deployment

For a new environment, use an empty `existingRegions` array and an empty `existingVmPlacements` array.

```powershell
az deployment sub create `
  --name <deployment-name> `
  --location <deployment-location> `
  --template-file main.bicep `
  --parameters <parameters-file>.json
```

## Brownfield Deployment

For an existing environment:

- List reused networking regions in `existingRegions`.
- List every retained VM in `existingVmPlacements`.
- Keep the original region indexes for existing VNets.
- Increase `regionCount` only after verifying the new regions and VM sizes.
- Increase VM counts to the desired totals; reconciliation creates only missing VM identities.

Example inventory entry:

```json
{
  "type": "srvlin",
  "index": 2,
  "regionKey": "centralindia"
}
```

## Stages

| Stage | Behavior |
|---|---|
| `network` | Creates or reuses regional networking and peerings. |
| `control` | Creates missing DCs and jumpboxes. |
| `identity` | Runs AD bootstrap, replica promotion, directory population, and domain join automation. It may also create missing workload VMs needed by the identity flow. Existing control-plane DCs are required. |
| `workload` | Creates missing workload VMs. |
| `all` | Runs the complete workflow. |

Typical staged order:

```text
network -> control -> identity -> workload
```

Use a new deployment name when rerunning identity automation so Azure reapplies the VM Run Command resources.

## Region Indexes

Region indexes determine VNet address spaces as well as placement order. Existing region indexes are part of the brownfield network contract. Do not renumber existing regions after deployment. A deleted region's index can be reused only after its VNets and peerings have been removed and no remaining VNet uses that address space.

The current validation rule requires region index values to be contiguous and start at `1`. If an index is freed, assign it to the replacement region rather than shifting all existing regions.

## Preflight Checks

```powershell
az vm list-sizes --location <region> -o table
az vm list-usage --location <region> -o table
az vm image list --publisher Canonical --offer 0001-com-ubuntu-server-jammy --sku 22_04-lts-gen2 --location <region>
```

[Back to README](../README.md)
