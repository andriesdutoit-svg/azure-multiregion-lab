# CI/CD Workflow and Local Checks

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

## Validation Reference

This guide covers how validation runs in GitHub Actions and locally. For the validation outputs, placement and capacity checks, post-deployment review command, and Run Command troubleshooting, see [Validation and Troubleshooting](validation-and-troubleshooting.md).

[Back to README](../README.md)
