# New Subscription Setup

[Back to README](../README.md)

Use this complete path for a new Azure subscription or tenant. It includes the final lab deployment; do not repeat the README quick start afterward. Detailed resource commands remain in their owning guides. Follow the checklist in order and return here after each linked step.

## Before You Start

Use one PowerShell session from the repository root. Install Azure CLI and Git; SSH-key setup also needs `ssh-keygen`. GitHub Actions setup is optional and additionally needs GitHub CLI (`gh`). Stop on command errors and replace all angle-bracket placeholders before running commands.

Resource creation requires subscription access. Role assignments and foundation locks require additional authorization, such as subscription Owner. Entra app creation requires tenant permission. Ask an administrator if these rights are unavailable.

Never share private keys, passwords, or secret-bearing terminal output. Secret-writing examples suppress output, but credentials already exposed must still be rotated.

## Setup Order

| Step | Action | Required State / Result |
|---|---|---|
| 1 | [Select Azure context and initialize values](#azure-context-and-foundation) | Capture the target subscription and tenant; initialize shared variables. |
| 2 | [Register providers and create the foundation group](#azure-context-and-foundation) | The group must exist before vault or identity creation. |
| 3 | [Create or reuse the vault](access-and-administration.md#create-or-reuse-key-vault), then [grant your user access](access-and-administration.md#user-secret-access) | Produces `kvId` and `userObjectId`. Do not run GitHub-app access yet. |
| 4 | [Create or reuse the managed identity](deployment.md#managed-identity), then [assign its role](deployment.md#required-role-assignment) | Produces `automationIdentity.id` and `automationIdentity.principalId`. |
| 5 | [Prepare SSH keys](access-and-administration.md#ssh-key-setup) and [administrator passwords](access-and-administration.md#admin-password-setup) | Requires vault access; allow RBAC propagation if necessary. |
| 6 | Optional: [choose the OIDC create/reuse path](ci-cd-validation.md#bootstrapping-oidc-for-a-new-subscription-or-tenant), then [grant the app vault access](access-and-administration.md#github-actions-secret-access) | Configure main, active-branch, and PR credentials on the same app. |
| 7 | [Configure deployment parameters and public IP](#configure-deployment-parameters) | Use this subscription's resource IDs and verified inventory. |
| 8 | Optional: [set GitHub secrets and variables](ci-cd-validation.md#github-actions-secrets-and-variables) | Requires GitHub authentication and repository administration access. |
| 9 | [Apply the foundation deletion lock](access-and-administration.md#foundation-deletion-lock) | Foundation resources and roles must already be in place. |
| 10 | [Check regional availability and quota](deployment.md#preflight-checks), then [build, lint, validate, and preview](ci-cd-validation.md#local-validation) | Resolve errors and review what-if before deploying. |
| 11 | [Deploy greenfield](deployment.md#greenfield-deployment), then [review deployment and guest results](validation-and-troubleshooting.md#post-deployment-review) | Deployment success alone does not prove operational readiness. |

Skip steps 6 and 8 for local-only deployment. If you return in a new session, reinitialize shared values and retrieve existing IDs rather than creating replacement resources.

## Azure Context And Foundation

Sign in, inspect available subscriptions, and select the intended subscription:

```powershell
az login --output none
az account list --query "[].{name:name,subscriptionId:id,tenantId:tenantId}" -o table
$subscriptionId = '<target-subscription-id>'
az account set --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) { throw 'Could not select the target subscription.' }
$azureContext = az account show | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $azureContext.id -ne $subscriptionId) {
  throw 'Azure context does not match the selected subscription.'
}
$tenantId = $azureContext.tenantId
$azureContext | Select-Object @{Name='Account';Expression={$_.user.name}}, id, tenantId
```

If the required tenant is unavailable, use `az login --tenant "<target-tenant-id>" --output none`, then repeat selection and verification. The portal also lists IDs under Subscriptions and Microsoft Entra ID Overview.

Initialize shared values. The foundation location is independent of lab placement; the vault name must be globally unique:

```powershell
az account list-locations --query "[].{name:name,displayName:displayName}" -o table
$foundationRg = 'amrl-foundation-rg'
$foundationLocation = '<foundation-region>'
$vaultName = '<globally-unique-vault-name>'
$automationIdentityName = 'amrl-deployment-mi'
$githubRepository = '<GitHub-owner>/<repository-name>'
$appDisplayName = 'AMRL-github-actions'
$parameterFile = '.\main.parameters.local.json'
$deploymentLocation = 'westeurope'
if (@($foundationLocation, $vaultName) | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -match '[<>]' }) {
  throw 'Choose an actual foundation region and globally unique vault name before continuing.'
}
```

This repository is `andriesdutoit-svg/azure-multiregion-lab`; fork owners must use their own owner/name. Register providers once per subscription and create the foundation group:

```powershell
foreach ($namespace in @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.ManagedIdentity', 'Microsoft.Storage', 'Microsoft.ContainerInstance')) {
  az provider register --namespace $namespace --wait --output none
  if ($LASTEXITCODE -ne 0) { throw "Provider registration failed: $namespace" }
}
az group create --name $foundationRg --location $foundationLocation --output none
if ($LASTEXITCODE -ne 0) { throw 'Foundation resource-group creation failed.' }
```

Storage and Container Instance support the cleanup Deployment Script. `--output none` avoids printing the provider catalogue. If the foundation group already exists, inspect it with `az group show --name $foundationRg --query "{name:name,location:location}" -o json` and reuse its location rather than trying to move it.

## Configure Deployment Parameters

Before this step, `$kvId` must identify the configured vault and `$automationIdentity.id` must identify the configured managed identity. Both are produced by earlier steps.

### Public IPv4 Address

The lookup below contacts an external HTTPS service. Alternatively set `$publicIp` using a trusted network-administrator source, then run the address check. Confirm that the address represents the workstation's actual outbound path, including VPN/proxy effects:

```powershell
$publicIp = ([string](Invoke-RestMethod -Uri 'https://api.ipify.org')).Trim()
$parsedAddress = $null
if (-not [System.Net.IPAddress]::TryParse($publicIp, [ref]$parsedAddress) -or $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
  throw 'Provide a valid public IPv4 address.'
}
```

This is required for the configured administration path regardless of whether GitHub Actions is used. GitHub's `YOUR_PUBLIC_IP` variable uses the bare address; `jumpboxAllowedSources` uses CIDR, such as `$publicIp/32`.

### Parameter File

Copy the demo only if the local file does not exist, then update references and the workstation access source. This example sets one `/32`; add other approved source networks separately:

```powershell
if (-not (Test-Path -LiteralPath $parameterFile)) {
  Copy-Item -LiteralPath '.\main.parameters.demo.json' -Destination $parameterFile
}
$parameters = Get-Content -Raw -LiteralPath $parameterFile | ConvertFrom-Json
foreach ($entry in $parameters.parameters.PSObject.Properties) {
  if ($entry.Value.reference.keyVault) { $entry.Value.reference.keyVault.id = $kvId }
}
$parameters.parameters.automationManagedIdentityResourceId.value = $automationIdentity.id
$parameters.parameters.jumpboxAllowedSources.value = @("$publicIp/32")
$parameters | ConvertTo-Json -Depth 30 |
  Set-Content -LiteralPath $parameterFile -Encoding UTF8
```

For a fresh lab, set `existingRegions` and `existingVmPlacements` to empty arrays and choose the lab prefix, regions, and VM counts. Do not carry another subscription's inventory into the new one. Keep at least one DC and jumpbox; dedicated file services need a Windows server target. Review images, sizes, and capacity in [Configuration Parameters Reference](configuration-parameters-reference.md). Secrets remain Key Vault references, not literal values.

## Value Lookups

| Value | Retrieval |
|---|---|
| Subscription / tenant | `$azureContext.id` / `$azureContext.tenantId` after account selection |
| Vault resource ID | `az keyvault show --name $vaultName --resource-group $foundationRg --query id -o tsv` |
| User object ID | `az ad signed-in-user show --query id -o tsv` |
| Identity resource / principal IDs | `$automationIdentity.id` / `$automationIdentity.principalId` from identity create/show |
| App client / registration object IDs | `$app.appId` / `$app.id` from app create/show; these are different IDs |
| GitHub service-principal object ID | `$servicePrincipal.id` from service-principal create/show |
| Git branch | `git branch --show-current` |
| Public IPv4 | [Public IPv4 Address](#public-ipv4-address) |