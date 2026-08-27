# Validation and Troubleshooting

[Back to README](../README.md)

## Template Validation

`modules/logic/validation.bicep` evaluates configuration and placement rules and returns outputs used by `main.bicep`.

It checks:

- Required DC and jumpbox counts.
- Region count and index validity.
- Primary DC and jumpbox pinning.
- Non-control VMs remaining outside the hub.
- Desired capacity and regional overflow.
- VM size and OS disk role keys.
- Existing region coverage for staged brownfield deployments.
- Remaining workload capacity after existing and new control-plane placement.
- Department and identity configuration.

## Useful Outputs

- `validationSummary`: Short status for quick review.
- `validationMessage`: First detected validation message.
- `validationDebug`: Boolean validation flags.
- `validationCapacityDebug`: Workload demand versus remaining capacity.
- `validationWorkloadCapacityDebug`: Per-region control-plane and workload capacity.
- `vmPlacement`: Combined existing and new VM placement model.
- `vmCountPerRegion`: Final count by region.
- `regionSummary`: Addressing, subnet, and regional VM summary.

## Azure Availability Checks

Template validation cannot guarantee that a VM size, image, or quota is available in Azure. Check these independently:

```powershell
az vm list-sizes --location <region> -o table
az vm list-usage --location <region> -o table
az vm image list --publisher Canonical --offer 0001-com-ubuntu-server-jammy --sku 22_04-lts-gen2 --location <region>
```

Trial and Student subscriptions can have regional quota and SKU restrictions.

## Deployment Operation Checks

```powershell
az deployment operation sub list `
  --name <deployment-name> `
  --query "[].{state:properties.provisioningState,target:properties.targetResource.resourceName}" `
  -o table
```

For VM Run Command failures, inspect the instance view. A resource operation can be reported as `Succeeded` while the guest command has failed; the guest `executionState` and `exitCode` are authoritative for script execution.

[Back to README](../README.md)
