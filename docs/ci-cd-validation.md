# CI and Validation

[Back to README](../README.md)

## GitHub Actions

The workflow at `.github/workflows/validate.yml` runs for pushes to `main`, pushes to feature branches, pushes to fix branches, manual runs via `workflow_dispatch`, and pull requests targeting `main`.

It performs:

1. Azure OIDC login.
2. Bicep build.
3. Bicep lint.
4. Parameter placeholder replacement for the demo file.
5. Subscription deployment validation.
6. What-if analysis.

The workflow requires Azure credentials configured as GitHub secrets and demo values configured as repository variables. See the workflow file for the exact secret and variable names.

When creating a new branch, make sure the matching GitHub Actions federated credential is created in Azure so OIDC authentication remains valid for that branch. This also applies to fix branches that should trigger validation automatically.

## Local Validation

Build and lint the template locally:

```powershell
az bicep build --file main.bicep
az bicep lint --file main.bicep
```

Validate a deployment without creating resources:

```powershell
az deployment sub validate `
  --location <deployment-location> `
  --template-file main.bicep `
  --parameters <parameters-file>.json
```

Preview changes:

```powershell
az deployment sub what-if `
  --location <deployment-location> `
  --template-file main.bicep `
  --parameters <parameters-file>.json
```

## Validation Outputs

The template returns placement, capacity, and configuration outputs rather than relying only on deployment success. Review `validationSummary`, `validationMessage`, `validationDebug`, `vmPlacement`, and `vmCountPerRegion` after a deployment.

The custom Bicep outputs are evaluated only when Azure creates or updates a deployment. `az deployment sub validate` checks whether the template can be submitted, while `what-if` previews resource changes; neither command exposes evaluated template outputs.

Before deployment, use both checks:

```powershell
az deployment sub validate `
  --location <deployment-location> `
  --template-file main.bicep `
  --parameters <parameters-file>.json

az deployment sub what-if `
  --location <deployment-location> `
  --template-file main.bicep `
  --parameters <parameters-file>.json
```

Use `what-if` to review which regions and resources will be created or reused. To inspect the calculated `vmPlacement`, capacity flags, and validation message themselves, deploy with a unique deployment name and review the outputs immediately afterward.

Show the validation outputs for a completed subscription deployment:

```powershell
az deployment sub show `
  --name <deployment-name> `
  --query "properties.outputs.{summary:validationSummary.value,message:validationMessage.value,debug:validationDebug.value,capacity:capacityCheck.value,placements:vmPlacement.value,counts:vmCountPerRegion.value}" `
  --output json
```

For a deployment to be considered valid, confirm that `validationSummary` is `Validation passed.` and that `validationDebug.hasRegionOverflow`, `validationDebug.hasNonControlInHub`, and `validationDebug.hasInsufficientWorkloadCapacity` are `false`. A successful ARM deployment only confirms that Azure accepted the resource operations; it does not confirm that every calculated placement or guest Run Command completed correctly.

Azure deployment success means that Azure accepted the resource operation. For VM Run Commands, inspect the guest execution state and exit code separately.

[Back to README](../README.md)
