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

Pull-request workflows use the separate Entra federated credential subject `repo:<GitHub profile>/<repo>:pull_request`, not the source branch subject. Create this credential when enabling Azure login for pull requests. Do not expose Azure credentials to workflows that execute untrusted code from forked repositories.

## Release Workflow

The workflow at `.github/workflows/release.yml` runs when a tag matching `v*` is pushed (for example, `v2.4.2`). It requires `contents: write` permission and uses `softprops/action-gh-release@v2` with generated release notes enabled.

Typical release flow:

```powershell
git tag v2.4.2
git push origin v2.4.2
```

## Bootstrapping OIDC for a New Subscription or Tenant

Run this once whenever the target Azure subscription or tenant changes (for example, moving the lab to a new subscription). It creates the Entra app registration used for GitHub Actions OIDC login, grants it access, and wires up federated credentials for `main`, the active branch, and pull requests.

```powershell
# Create the app registration and service principal
$app = az ad app create --display-name "<repo-name>-github-actions" | ConvertFrom-Json
az ad sp create --id $app.appId

# Grant Contributor on the target subscription
az role assignment create --assignee $app.appId --role Contributor `
  --scope "/subscriptions/<subscription-id>"

# Create a federated credential (repeat per branch/subject)
az ad app federated-credential create --id $app.id --parameters '{
  "name": "github-actions-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<GitHub profile>/<repo>:ref:refs/heads/main",
  "description": "GitHub Actions - main branch",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

Create additional federated credentials with `subject` set to `repo:<GitHub profile>/<repo>:ref:refs/heads/<branch>` for each active branch, and `repo:<GitHub profile>/<repo>:pull_request` for pull-request runs.

Then set the GitHub Actions secrets so `azure/login` can use OIDC:

```powershell
gh secret set AZURE_CLIENT_ID -b "<app.appId>" -R <GitHub profile>/<repo>
gh secret set AZURE_TENANT_ID -b "<tenant-id>" -R <GitHub profile>/<repo>
gh secret set AZURE_SUBSCRIPTION_ID -b "<subscription-id>" -R <GitHub profile>/<repo>
```

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
