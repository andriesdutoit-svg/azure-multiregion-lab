# New Subscription Setup

[Back to README](../README.md)

Use this complete path for a new Azure subscription or tenant. It owns foundation and credential setup and includes the final lab deployment; do not repeat the README quick start afterward. Follow the checklist in order, using the optional CI links only when required.

## Before You Start

Use one PowerShell session from the repository root. Install Azure CLI and Git; SSH-key setup also needs `ssh-keygen`. GitHub Actions setup is optional and additionally needs GitHub CLI (`gh`). Stop on command errors and replace all angle-bracket placeholders before running commands.

Resource creation requires subscription access. Role assignments and foundation locks require additional authorization, such as subscription Owner. Entra app creation requires tenant permission. Ask an administrator if these rights are unavailable.

Never share private keys, passwords, or secret-bearing terminal output. Secret-writing examples suppress output, but credentials already exposed must still be rotated.

## Setup Order

| Step | Action | Required State / Result |
|---|---|---|
| 1 | [Select Azure context and initialize values](#azure-context-and-foundation) | Capture the target subscription and tenant; initialize shared variables. |
| 2 | [Check/register providers and create the foundation group](#azure-context-and-foundation) | The group must exist before vault or identity creation. |
| 3 | [Create or reuse the managed identity](#managed-identity), then [assign its role](#required-role-assignment) | Produces `automationIdentity.id` and `automationIdentity.principalId`. |
| 4 | [Create or reuse the vault](#create-or-reuse-key-vault), then [grant your user access](#user-secret-access) | Produces `kvId` and `userObjectId`. Do not run GitHub-app access yet. |
| 5 | [Prepare SSH keys](#ssh-key-setup) and [administrator passwords](#admin-password-setup) | Requires vault access; allow RBAC propagation if necessary. |
| 6 | Optional: [choose the OIDC create/reuse path](ci-cd-validation.md#bootstrapping-oidc-for-a-new-subscription-or-tenant), then [grant the app vault access](#github-actions-secret-access) | Configure main, active-branch, and PR credentials on the same app. |
| 7 | [Configure deployment parameters and public IP](#configure-deployment-parameters) | Use this subscription's resource IDs and verified inventory. |
| 8 | Optional: [set GitHub secrets and variables](ci-cd-validation.md#github-actions-secrets-and-variables) | Requires GitHub authentication and repository administration access. |
| 9 | [Apply the foundation deletion lock](#foundation-deletion-lock) | Foundation resources and roles must already be in place. |
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

This repository is `andriesdutoit-svg/azure-multiregion-lab`; fork owners must use their own owner/name. Check the required providers and register only those not already registered, then create the foundation group:

```powershell
foreach ($namespace in @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.ManagedIdentity', 'Microsoft.Storage', 'Microsoft.ContainerInstance')) {
  $registrationState = az provider show --namespace $namespace --query registrationState --output tsv
  if ($LASTEXITCODE -ne 0) { throw "Could not check registration state for $namespace." }

  if ($registrationState -ne 'Registered') {
    az provider register --namespace $namespace --wait --output none
    if ($LASTEXITCODE -ne 0) { throw "Provider registration failed for $namespace." }

    $registrationState = az provider show --namespace $namespace --query registrationState --output tsv
    if ($LASTEXITCODE -ne 0 -or $registrationState -ne 'Registered') {
      throw "Provider $namespace did not reach Registered state. Current state: $registrationState."
    }
  }
}
az group create --name $foundationRg --location $foundationLocation --output none
```

Storage and Container Instance support the network-reconciliation Deployment Script. `--output none` avoids printing the provider catalogue. If the foundation group already exists, inspect it with `az group show --name $foundationRg --query "{name:name,location:location}" -o json` and reuse its location rather than trying to move it.

### Managed Identity

After creating the foundation group, inspect its identities. Create the selected identity only if it does not already exist:

```powershell
az identity list --resource-group $foundationRg --query "[].{name:name,resourceId:id,principalId:principalId}" -o table
$automationIdentity = az identity create --name $automationIdentityName `
  --resource-group $foundationRg --location $foundationLocation | ConvertFrom-Json
```

For an existing identity, use this instead of `create`:

```powershell
$automationIdentity = az identity show --name $automationIdentityName `
  --resource-group $foundationRg | ConvertFrom-Json
```

### Required Role Assignment

Grant the identity Network Contributor access to the target subscription for applicable peering/Bastion cleanup:

```powershell
az role assignment create `
  --assignee-object-id $automationIdentity.principalId `
  --assignee-principal-type ServicePrincipal `
  --role "Network Contributor" `
  --scope "/subscriptions/$($azureContext.id)" --output none
```

Use `$automationIdentity.id` in the deployment parameter file. The identity is used when network reconciliation runs, not for every VM guest operation. See [Reconciliation RBAC](deployment.md#rbac-requirements-for-network-reconciliation) for its operational scope.

## Key Vault Setup

Parameter files reference credentials through Key Vault rather than embedding them. Required secret names are `sshPublicKey`, `sshPrivateKey`, `jumpboxAdminPassword`, `serverAdminPassword`, and `clientAdminPassword`.

### Create Or Reuse Key Vault

Inspect existing vaults and create the selected vault only if it does not already exist:

```powershell
az keyvault list --resource-group $foundationRg --query "[].{name:name,id:id}" -o table
az keyvault create --name $vaultName --resource-group $foundationRg --location $foundationLocation `
  --enable-rbac-authorization true --enabled-for-template-deployment true `
  --enable-purge-protection true --output none
```

`--enabled-for-template-deployment true` allows ARM/Bicep to resolve secret references. Purge protection is irreversible: a deleted vault cannot be permanently purged until its soft-delete retention expires. It protects recovery but does not prevent soft deletion.

### User Secret Access

Grant the signed-in administrator permission to write secrets in the selected vault:

```powershell
$kvId = az keyvault show --name $vaultName --resource-group $foundationRg --query id -o tsv
$userObjectId = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee-object-id $userObjectId `
  --assignee-principal-type User --role "Key Vault Secrets Officer" --scope $kvId --output none
```

Allow time for RBAC propagation before writing secrets; do not recreate the vault or broaden permissions merely to bypass propagation delays.

### SSH Key Setup

Use a dedicated lab key rather than a personal GitHub or production key. Generate it interactively at a new path without overwriting an existing key:

```powershell
$sshKeyPath = Join-Path $HOME '.ssh/amrl_ed25519'
if (-not (Test-Path -LiteralPath $sshKeyPath)) {
  New-Item -ItemType Directory -Path (Split-Path $sshKeyPath -Parent) -Force | Out-Null
  ssh-keygen -t ed25519 -f $sshKeyPath
  if ($LASTEXITCODE -ne 0) { throw 'SSH key generation failed.' }
}
az keyvault secret set --vault-name $vaultName --name sshPublicKey `
  --value ((Get-Content "$sshKeyPath.pub" -Raw).Trim()) --output none
az keyvault secret set --vault-name $vaultName --name sshPrivateKey --file $sshKeyPath --output none
```

Keep passphrases out of scripts and chat; a protected key must be unlocked when SSH uses it, and AMRL does not distribute the passphrase. Keep `--output none` on secret-writing commands so the response does not print the private key.

### Admin Password Setup

Set distinct, strong passwords using masked prompts. Run interactively on a protected workstation without transcripts or diagnostic tracing; the CLI receives temporary plaintext in process memory/arguments:

```powershell
foreach ($secretName in @('jumpboxAdminPassword', 'serverAdminPassword', 'clientAdminPassword')) {
  $securePassword = Read-Host "Password for $secretName" -AsSecureString
  try {
    $passwordValue = [System.Net.NetworkCredential]::new('', $securePassword).Password
    az keyvault secret set --vault-name $vaultName --name $secretName --value $passwordValue --output none
  }
  finally {
    $passwordValue = $null
    $securePassword.Dispose()
  }
}
az keyvault secret list --vault-name $vaultName --query "[].{name:name,enabled:attributes.enabled}" -o table
```

These secrets initialize local VM accounts, not generated AD users. Generated users receive independent random passwords and require a separate secure reset/delivery process. If credentials were exposed, rotate both vault secrets and credentials on retained guests; updating the vault alone does not rotate existing VM passwords or authorized SSH keys.

### GitHub Actions Secret Access

Optional for CI automation. Complete or reload the [OIDC app setup](ci-cd-validation.md#bootstrapping-oidc-for-a-new-subscription-or-tenant) first. Use its Application (client) ID to resolve the service principal in the current tenant:

```powershell
$githubActionsAppId = $app.appId
if ([string]::IsNullOrWhiteSpace($githubActionsAppId)) { throw 'Complete or reload OIDC app setup first.' }
$githubActionsSpObjectId = az ad sp show --id $githubActionsAppId --query id -o tsv
az role assignment create --assignee-object-id $githubActionsSpObjectId `
  --assignee-principal-type ServicePrincipal --role "Key Vault Secrets User" --scope $kvId --output none
```

### Foundation Deletion Lock

After creating foundation resources and their RBAC assignments, protect the group from accidental control-plane deletion:

```powershell
az lock create `
  --name protect-foundation `
  --lock-type CanNotDelete `
  --resource-group $foundationRg --output none
```

The lock covers the group and contained resources while permitting updates and secret operations. It does not prevent data-plane secret deletion; soft delete and purge protection govern recovery. Remove it only for intentional foundation deletion, then restore it after maintenance:

```powershell
az lock delete --name protect-foundation --resource-group $foundationRg --output none
```

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