# CI/CD Workflow and Local Checks

[Back to README](../README.md)

Start with local checks for manual deployments. GitHub Actions and OIDC setup are optional automation paths; they are not prerequisites for running the lab from your workstation.

## Local Validation

Prerequisites: Azure CLI authenticated to the target subscription, an existing parameter file, and referenced foundation resources. Set the parameter path and deployment metadata location explicitly, or reuse the values from [New Subscription Setup](new-subscription-setup.md):

```powershell
$parameterFile = '.\main.parameters.local.json'
$deploymentLocation = 'westeurope'
if (-not (Test-Path -LiteralPath $parameterFile)) { throw 'Configure the parameter file before validation.' }
```

Build and lint locally, then validate the deployment and preview proposed changes without creating resources:

```powershell
az bicep build --file main.bicep
az bicep lint --file main.bicep
```

```powershell
az deployment sub validate `
  --location $deploymentLocation `
  --template-file main.bicep `
  --parameters $parameterFile
```

```powershell
az deployment sub what-if `
  --location $deploymentLocation `
  --template-file main.bicep `
  --parameters $parameterFile
```

Review the proposed changes before [deploying](deployment.md). For outputs and guest-readiness checks afterward, use [Deployment Results and Troubleshooting](validation-and-troubleshooting.md).

## GitHub Actions

The workflow at `.github/workflows/validate.yml` runs for pushes to `main`, pushes to feature branches, pushes to fix branches, manual runs via `workflow_dispatch`, and pull requests targeting `main`.

It performs:

1. Azure OIDC login.
2. Bicep build.
3. Bicep lint.
4. Parameter placeholder replacement for the demo file.
5. Subscription deployment validation.
6. What-if analysis.

The workflow requires Azure credentials configured as GitHub secrets and demo values configured as repository variables. Configure these GitHub Actions values:

| Name | Type | Purpose |
|---|---|---|
| `AZURE_CLIENT_ID` | Secret | Entra application ID used for Azure OIDC login. |
| `AZURE_TENANT_ID` | Secret | Microsoft Entra tenant ID. |
| `AZURE_SUBSCRIPTION_ID` | Secret | Azure subscription ID used by the workflow. |
| `YOUR_PUBLIC_IP` | Variable | Public IP address allowed to access jumpboxes. |
| `KEYVAULT_ID` | Variable | Resource ID of the Key Vault referenced by the demo parameter file. |
| `AUTOMATION_MANAGED_IDENTITY_RESOURCE_ID` | Variable | Resource ID of the User Assigned Managed Identity used by Deployment Scripts. The identity must have the Network Contributor role at subscription scope. |

When creating a new branch, make sure the matching GitHub Actions federated credential is created in Azure so OIDC authentication remains valid for that branch. This also applies to fix branches that should trigger validation automatically.

Pull-request workflows use the separate Entra federated credential subject `repo:<GitHub profile>/<repo>:pull_request`, not the source branch subject. Create this credential when enabling Azure login for pull requests. Do not expose Azure credentials to workflows that execute untrusted code from forked repositories.

## Release Workflow

The workflow at `.github/workflows/release.yml` runs when a tag matching `v*` is pushed. It requires `contents: write` permission and uses `softprops/action-gh-release@v2` with generated release notes enabled.

Typical release flow:

```powershell
git tag <release-tag-starting-with-v>
git push origin <release-tag-starting-with-v>
```

## Bootstrapping OIDC for a New Subscription or Tenant

Run this once whenever the target Azure subscription or tenant changes (for example, moving the lab to a new subscription). It creates the Entra app registration used for GitHub Actions OIDC login, grants it access, and wires up federated credentials for `main`, the active branch, and pull requests.

This is optional for local-only deployment. Prerequisites: initialize `$githubRepository` and `$appDisplayName` using [Azure Context And Foundation](new-subscription-setup.md#azure-context-and-foundation), and authenticate to the target subscription. App registrations are tenant-scoped: an app may be reused across subscriptions in the same tenant after assigning appropriate access, but an old tenant's app ID must not be assumed valid in a new tenant.

Use the same PowerShell session for the examples below. Set the repository owner/name and capture the currently selected Azure subscription and tenant first. For AMRL, the repository is `andriesdutoit-svg/azure-multiregion-lab`:

```powershell
if ([string]::IsNullOrWhiteSpace($githubRepository) -or $githubRepository -match '[<>]') {
  throw 'Set githubRepository to the actual owner/repository name from New Subscription Setup.'
}
$azureContext = az account show | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $azureContext.id -or -not $azureContext.tenantId) {
  throw 'Sign in and select the target Azure subscription before continuing.'
}
```

Choose exactly one of the following paths, then continue with [Grant Access And Configure Credentials](#grant-access-and-configure-credentials).

### Create New App

Use this path only if the app and service principal do not already exist in the current tenant:

```powershell
az ad app list --display-name $appDisplayName --query "[].{name:displayName,clientId:appId,objectId:id}" -o table
# Create the app registration and service principal
$app = az ad app create --display-name $appDisplayName | ConvertFrom-Json
$servicePrincipal = az ad sp create --id $app.appId | ConvertFrom-Json
```

### Reuse Existing App

If the app was already created, skip the create path. Populate the variables using its Application (client) ID:

```powershell
$githubActionsAppId = '<application-client-id>'
$app = az ad app show --id $githubActionsAppId | ConvertFrom-Json
$servicePrincipal = az ad sp show --id $app.appId | ConvertFrom-Json
```

### Grant Access And Configure Credentials

Prerequisites: `$app` and `$servicePrincipal` from exactly one create/reuse path above, and the verified `$azureContext`. Grant access and create the main-branch credential:

```powershell
# Grant Contributor on the target subscription
az role assignment create --assignee-object-id $servicePrincipal.id `
  --assignee-principal-type ServicePrincipal --role Contributor `
  --scope "/subscriptions/$($azureContext.id)"

# Create the main-branch federated credential using a JSON file
$credential = @{
  name        = 'github-actions-main'
  issuer      = 'https://token.actions.githubusercontent.com'
  subject     = "repo:${githubRepository}:ref:refs/heads/main"
  description = 'GitHub Actions - main branch'
  audiences   = @('api://AzureADTokenExchange')
}
$credentialPath = Join-Path $env:TEMP 'github-actions-main.json'
$credential | ConvertTo-Json -Depth 3 |
  Set-Content -LiteralPath $credentialPath -Encoding ASCII

az ad app federated-credential create `
  --id $app.id `
  --parameters $credentialPath
```

JSON files avoid inline JSON quoting problems in Windows PowerShell. Before repeating a credential creation command, inspect existing credentials with `az ad app federated-credential list --id $app.id --query "[].{name:name,subject:subject}" -o table`; do not create duplicates.

For each additional active branch, repeat the main-branch example with a unique credential name and `subject` set to `repo:<GitHub profile>/<repo>:ref:refs/heads/<branch>`. The issuer and audience stay the same.

Retrieve the active branch with `git branch --show-current`. For an active branch other than `main`, this complete example creates its credential:

```powershell
$branchName = git branch --show-current
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branchName)) { throw 'Select a Git branch first.' }
if ($branchName -ne 'main') {
  $credential = @{
    name = 'github-actions-active-branch'
    issuer = 'https://token.actions.githubusercontent.com'
    subject = "repo:${githubRepository}:ref:refs/heads/$branchName"
    description = "GitHub Actions - $branchName"
    audiences = @('api://AzureADTokenExchange')
  }
  $credentialPath = Join-Path $env:TEMP 'github-actions-active-branch.json'
  $credential | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $credentialPath -Encoding ASCII
  az ad app federated-credential create --id $app.id --parameters $credentialPath
}
```

Use a different credential name when adding another branch; the fixed example name is not a wildcard credential for all branches.

Create the separate pull-request credential on the same app registration, using `$app` from the earlier steps:

```powershell
$credential = @{
  name        = 'github-actions-pull-request'
  issuer      = 'https://token.actions.githubusercontent.com'
  subject     = "repo:${githubRepository}:pull_request"
  description = 'GitHub Actions - pull requests'
  audiences   = @('api://AzureADTokenExchange')
}
$credentialPath = Join-Path $env:TEMP 'github-actions-pull-request.json'
$credential | ConvertTo-Json -Depth 3 |
  Set-Content -LiteralPath $credentialPath -Encoding ASCII

az ad app federated-credential create `
  --id $app.id `
  --parameters $credentialPath
```

The pull-request subject has no branch suffix; the same credential covers pull-request runs for this repository. Do not grant Azure access to workflows executing untrusted fork code.

### GitHub Actions Secrets And Variables

Prerequisites: the app/credentials above, the configured vault and identity, `$githubRepository` and `$azureContext`, and `$publicIp` from [Public IPv4 Address](new-subscription-setup.md#public-ipv4-address). These commands require repository administration access. Authenticate GitHub CLI and set the Actions values:

```powershell
gh auth login
gh auth status
gh secret set AZURE_CLIENT_ID -b $app.appId -R $githubRepository
gh secret set AZURE_TENANT_ID -b $azureContext.tenantId -R $githubRepository
gh secret set AZURE_SUBSCRIPTION_ID -b $azureContext.id -R $githubRepository
```

Retrieve the resource IDs rather than typing them. Public-IP discovery belongs to deployment parameter setup, not GitHub authentication; reuse that value here:

```powershell
if ([string]::IsNullOrWhiteSpace($publicIp)) { throw 'Complete public-IP setup before setting GitHub variables.' }
$kvId = az keyvault show --name $vaultName --resource-group $foundationRg --query id -o tsv
$automationIdentityResourceId = az identity show --name $automationIdentityName --resource-group $foundationRg --query id -o tsv

gh variable set YOUR_PUBLIC_IP -b $publicIp -R $githubRepository
gh variable set KEYVAULT_ID -b $kvId -R $githubRepository
gh variable set AUTOMATION_MANAGED_IDENTITY_RESOURCE_ID -b $automationIdentityResourceId -R $githubRepository
gh secret list -R $githubRepository
gh variable list -R $githubRepository
```

`YOUR_PUBLIC_IP` is the IPv4 address without `/32`; the workflow adds the CIDR suffix. Secret listing shows names, not secret values. Local-only deployments do not need this GitHub configuration.

## Validation Reference

This guide covers how validation runs in GitHub Actions and locally. For the validation outputs, placement and capacity checks, post-deployment review command, and Run Command troubleshooting, see [Validation and Troubleshooting](validation-and-troubleshooting.md).

[Back to README](../README.md)
