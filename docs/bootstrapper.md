# Bootstrapper Guide

[Back to README](../README.md)

Use the bootstrapper to prepare and deploy AMRL in a new or existing subscription. It creates or reuses prerequisites, configures Bicep parameters, and optionally invokes `main.bicep`. Subscription age does not determine which deployment method to use. The manual alternative is [Manual Preparation](manual-preparation.md), followed by [Bicep Deployment](deployment.md).

| Area | Bootstrapper Responsibility |
|---|---|
| Subscription-level setup | Providers, foundation resource groups, deployment identity/RBAC, Key Vault, credentials, protection locks, and optional GitHub OIDC identity/access. |
| Bicep setup and deployment | Parameter-file configuration, access-source CIDRs, optional GitHub Actions deployment settings, preflight, `what-if`, and deployment after confirmation. |

## Requirements

### Subscription-Level Setup

- Access to the target subscription and permission to create resources and assign roles. Prerequisite resources do not have to exist already.
- Only with `-IncludeGitHub`: Entra app-management permission for OIDC identity/access setup.

Sign in before running the bootstrapper:

```powershell
az login
```

The browser opens for authentication; return to the terminal when sign-in completes. The bootstrapper displays the active account, tenant, and subscription and asks you to confirm them. Answer No to see the saved subscriptions and choose one; if none is suitable, or you are not signed in, it offers the sign-in flow.

### Bicep Setup

- Run Windows PowerShell 5.1 from the repository root with Azure CLI, Bicep, and `ssh-keygen` available.
- Only with `-IncludeGitHub`: Git, authenticated GitHub CLI (`gh`), and repository write access for Actions settings.
- For an existing lab, prepare a reviewed parameter file as described under [Existing Environments](#existing-environments).

## Run Modes

Run the bootstrapper in this order: check readiness with `-Plan`, configure prerequisites with `-Prepare`, then deploy with `-Deploy`. Exactly one mode is required per run; the mode switches are mutually exclusive.

### 1. Plan

Start with read-only checks:

```powershell
.\scripts\Initialize-Lab.ps1 -Plan
```

Plan checks subscription readiness and Bicep values without making changes or saving interactive choices. It reports missing prerequisites without creating them. When prerequisites are ready, it runs Bicep build/lint, Azure validate, and `what-if`. These checks do not provide the saved Bicep configuration-findings report or prove guest readiness.

### 2. Prepare

Run Prepare to configure prerequisites and review the lab deployment without deploying lab resources:

```powershell
.\scripts\Initialize-Lab.ps1 -Prepare
```

In interactive mode, answer the lab-setting prompts; Enter accepts each displayed default from `main.parameters.local.json` or, on first run, the demo template. Prepare then:

1. Collects the selected stage and Bicep settings, then saves the interactive choices to the git-ignored local parameter file.
2. Confirms the Azure account, tenant, and subscription to use.
3. Checks and prepares foundation prerequisites: registers required resource providers; creates or reuses the foundation resource group, managed identity, RBAC assignments, and Key Vault; and applies protection locks.
4. Reuses active Key Vault passwords and keys. For missing password secrets, it recovers soft-deleted values when available; otherwise, it follows the normal generation or secure-entry flow. For SSH, it recovers missing soft-deleted key secrets as a pair, preserves a complete Key Vault pair even if the local copy is absent, and generates a new pair only when neither active nor recoverable SSH secrets exist.
5. Saves the top-level foundation resource group and Key Vault name, and access source to the parameter file. Identity naming, administrator usernames, and secret names come from [shared defaults](configuration-parameters-reference.md#shared-amrl-defaults), not parameter inputs. Parameter files using retired identity parameters, metadata fields, or per-secret Key Vault references are rejected; update them to the current example schema. With `-IncludeGitHub`, it also configures the requested GitHub OIDC settings.
6. If the required foundation resources are available, runs Bicep build and lint, Azure deployment validation, and `what-if`. Review the preview and resolve errors or unexpected changes before deploying.

If SSH key setup fails, the bootstrapper records the error and continues independent foundation checks. When the deployment identity and Key Vault are available, it still runs the read-only Bicep checks and `what-if`; however, any foundation setup error causes `-Deploy` to be skipped and is shown in the final report.

Creating or recovering a password secret does not reconcile an existing Windows local administrator or Active Directory account to that value. If a secret is missing and a replacement is created while its account already exists, the secret and account passwords may differ; rotate or otherwise align the existing account separately when required.

For GitHub Actions, add `-IncludeGitHub` to Prepare and subsequent Plan/Deploy runs. Interactive Prepare asks for the repository; the Entra app display name comes from shared defaults. Omit the switch for local-only deployment. With `-ParameterFile`, supply the repository under [Using `-ParameterFile`](#using-parameterfile).

### 3. Deploy

When Plan checks and the Prepare preview are satisfactory, run Deploy:

```powershell
.\scripts\Initialize-Lab.ps1 -Deploy
```

Deploy repeats the complete Prepare workflow: it collects or loads configuration, checks and prepares foundation resources, credentials, permissions, and locks, saves resolved parameter references, configures GitHub OIDC when requested, and runs Bicep build/lint, Azure validation, and `what-if`. Without `-ParameterFile`, it runs the interactive wizard again, using saved local values as defaults; press Enter to accept them.

Deploy then prompts for a deployment name, defaulting to `amrl-<prefix>-<timestamp>`, and uses it for both `what-if` and deployment. To start the Bicep deployment, enter the exact word `DEPLOY`. One mistyped confirmation gets a second attempt; after two mismatches, the wizard asks whether to cancel (`y/N`). `y` cancels, while `n` or Enter restarts the confirmation prompts with the same deployment name and preview. The Bicep deployment starts only if foundation setup and preflight/`what-if` checks succeed and you confirm with `DEPLOY`. The bootstrapper polls Azure and prints stage updates with indented resource operations from nested deployments, retaining each resource's stage label and printing only new operation/state combinations. These are Azure provisioning states, not proof of guest readiness. It then reports deployment validation findings and VM setup checks when available. Review the [results](#results) and perform the [guest checks](validation-and-troubleshooting.md#post-deployment-review) afterward.

## Options And Configuration

### Configuration Switches

| Switch | Default | Effect |
|---|---|---|
| `-Plan` | Required mode | Read-only subscription readiness and Bicep checks. Makes no changes and does not save interactive choices. |
| `-Prepare` | Required mode | Creates or reuses subscription-level items and checks Bicep values with preflight and `what-if`; does not deploy lab resources. |
| `-Deploy` | Required mode | Creates or reuses subscription-level items, checks Bicep values, then deploys after you type `DEPLOY`. |
| `-IncludeGitHub` | Off | Configures GitHub OIDC, including missing credentials for `main`, the active branch, and pull requests. In Plan mode, inspects settings without changing them. |
| `-ReportPath <path>` | Omit to disable | Saves the final report as a UTF-8 text file and still prints it to the console. Relative paths resolve from the current working directory; the parent directory must exist. A file-write failure is reported and returns a failing exit code. |

### Configuration Parameters

| Parameter | Default or prompt | Purpose |
|---|---|---|
| `-ParameterFile <path>` | Omit for the wizard | Use an existing parameter file without lab-setting prompts. Recommended for brownfield deployments. |

### Using `-ParameterFile`

Pass `-ParameterFile <path>` to use a complete, reviewed parameter file without lab-setting prompts. For example, after preparing the local file, run read-only checks and deploy with that same file:

```powershell
.\scripts\Initialize-Lab.ps1 -ParameterFile .\main.parameters.local.json -Plan
.\scripts\Initialize-Lab.ps1 -ParameterFile .\main.parameters.local.json -Deploy
```

Both parameter templates include `prefix.metadata.bootstrap.azureTenantId` and `azureSubscriptionId`, plus top-level `foundationResourceGroup` and `keyVaultName` parameters. The deployment identity name comes from `config/amrl-defaults.json`; do not add an identity name or resource ID to the parameter file or bootstrap metadata. With `-ParameterFile`, tenant and subscription IDs must be filled in, and the active Azure CLI context must match; the bootstrapper does not ask or switch context. The bootstrapper derives the subscription deployment location from the first `regionIndexMap` entry by numeric index; no deployment-location metadata is required. Explicit files are checked for every required Bicep parameter and fail before subscription setup if any are missing; use `main.parameters.example.json` as the complete schema.

With `-IncludeGitHub`, explicit files must set `prefix.metadata.bootstrap.githubRepository`; the Entra app display name is fixed in `config/amrl-defaults.json`. The bootstrapper does not prompt for it and rejects `githubAppDisplayName` metadata overrides. The file must also contain exactly one approved IPv4 `/32` in `jumpboxAllowedSources` for the `YOUR_PUBLIC_IP` repository variable. An unresolved jumpbox IP placeholder is rejected rather than prompting.

#### Existing Environments

The bootstrapper can deploy changes to an existing (brownfield) lab, but we recommend `-ParameterFile` with a reviewed configuration rather than the wizard. You are responsible for declaring `existingRegions`, every retained VM in `existingVmPlacements`, unchanged region indexes, and desired VM totals. The bootstrapper does not discover this inventory.

Follow the [brownfield checklist](deployment.md#brownfield-deployment), run `-Plan` with the reviewed file, then use the same file with `-Deploy` after reviewing `what-if`. Direct Azure CLI deployment and stage selection are covered in the [Deployment Guide](deployment.md).

### Subscription-Level Setup Values

| Values | Source |
|---|---|
| Azure account, tenant, subscription | Interactive runs confirm the Azure CLI context and save tenant/subscription IDs. Explicit parameter files supply tenant/subscription IDs and must match the active Azure CLI context. |
| Subscription deployment location | Derived from the first `regionIndexMap` entry by numeric index; this is not stored in metadata. |
| Managed identity, administrator, and secret names | [config/amrl-defaults.json](../config/amrl-defaults.json), shared by Bicep and the bootstrapper; no parameter-file or GitHub-variable overrides. |
| Foundation resource group and Key Vault name | Top-level `foundationResourceGroup` and `keyVaultName` parameters; the bootstrapper resolves and saves them there. |
| Foundation resource location | Always derived from the first `regionIndexMap` entry by numeric index, in both wizard and `-ParameterFile` runs. The bootstrapper prints the selected value and never prompts for it or persists location metadata. New foundation groups, identities, and vaults use this region; existing resources are not moved, and soft-deleted vaults recover in their original location. The same region is used for subscription deployment operations. |
| Foundation groups, identity, and vault | Interactive wizard runs always prompt for the foundation resource-group name, defaulting to the configured value. Keeping it reuses its resources. Choosing another group searches that group for active vaults and prompts to reuse one; if there are several, choose one or create a new vault. If no active vault is selected, the bootstrapper checks for soft-deleted vaults whose original resource ID belongs to that group and offers recovery with explicit confirmation. It generates an available new name only when no existing vault is selected. With `-ParameterFile`, the configured group and vault name, plus the shared default identity name, are used without a name prompt. New vault names are checked for availability. |
| Password secrets and SSH keys | Active passwords are reused; soft-deleted password secrets are recovered when available; otherwise missing passwords are generated or securely entered. Existing guest account passwords are not rotated. |
| GitHub OIDC repository | Default from the template's `prefix` metadata. Prompted with `-IncludeGitHub`; without the switch, no GitHub or Entra app configuration occurs. |
| GitHub Entra app display name | Fixed in [config/amrl-defaults.json](../config/amrl-defaults.json); not configurable through parameters or prompts. |

### Bicep Setup Values

| Values | Source |
|---|---|
| `stage` | First wizard question, listing `all`, `network`, `compute`, and `identity`; defaults to the parameter-file value. Preserved without prompting with `-ParameterFile`. |
| Lab prefix, `regionCount`, `maxVmsPerRegion`, `validationMode`, individual `vmCounts` | Shared wizard prompts; current local-file values, or demo values on first run, are defaults. Bicep enforces numeric parameter bounds; the AMRL validation engine evaluates cross-field configuration rules. |
| `networkMode` | Prompted for `network`/`all`; otherwise preserved. |
| `departmentCount`, `usersPerDepartment` | Prompted for `identity`/`all`; otherwise preserved. |
| `useDedicatedFileServer`, `enableWindowsAdminCenter`, `useDedicatedWacHost` | Yes/no questions for `identity`/`all`; otherwise preserved. File services always run with the identity stage. |
| Region map and remaining Bicep values | Current parameter file or demo template; preserved. The wizard uses the first `regionCount` regions without renumbering address indexes. |
| Deployment identity and Key Vault | Identity ID derived from the subscription, foundation group, and shared default name. Vault parameters are saved after setup; secret values remain in Key Vault. |
| Jumpbox source CIDRs | Existing ranges are preserved; an unresolved placeholder uses an approved public IPv4 `/32`. |
| GitHub Actions secrets and variables | With `-IncludeGitHub`, populated from the selected identity, tenant/subscription, vault, and approved public IP. |

See [Configuration Parameters Reference](configuration-parameters-reference.md) for parameter definitions and dependencies.

#### Select A Stage

Without `-ParameterFile`, the first wizard question selects the deployment stage:

```text
Deployment stage (Allowed: all, network, compute, identity) [<saved stage>]:
```

Enter accepts the `stage` value from the current local parameter file, or the demo template on first run. The answer determines which subsequent Bicep questions are asked. Preparation saves the selected stage; Plan uses it without saving it. The selected value is passed to Bicep and displayed under Configuration used.

With `-ParameterFile`, no stage question is asked: the file's `stage` value is used unchanged for preparation, Plan, and Deploy. To change it, edit that value in the reviewed parameter file or rerun the wizard without `-ParameterFile`.

| Stage | Bicep wizard questions |
|---|---|
| Every stage | Prefix, region count, validation mode, maximum VMs per region, and individual VM counts. These shared placement inputs determine regional infrastructure, subnet allocation, and guest targets. |
| `network` | Shared questions plus network mode. |
| `compute` | Shared questions only. |
| `identity` | Shared questions plus department/user counts and file-service/WAC options. |
| `all` | All questions. |

Settings outside the selected stage are preserved from the parameter file or demo defaults. Subscription-level setup and optional GitHub questions still apply. Stages retain their existing Bicep dependencies: compute/identity runs require declared existing infrastructure and inventory where appropriate; identity can also create missing workload VMs needed for domain join. Stage selection does not discover retained resources or automatically deploy earlier stages.

## Safety And Results

### Subscription-Level Setup Safety

- Tools/authentication and optional GitHub repository access are checked before Azure resource changes. Key Vault secret operations retry recognized RBAC-propagation failures for up to about ten minutes; role-assignment operations use a shorter six-attempt retry. Firewall denials, explicit deny assignments, and unrelated errors stop immediately.
- Active password secrets and existing credentials are reused; soft-deleted password secrets are recovered when available, otherwise missing passwords are generated or securely entered. The bootstrapper never rotates existing guest account passwords. Keep passwords and private keys out of logs and committed files.
- Generated vault names start with `amrl-kv-` followed by the first eight characters of the subscription ID after hyphens are removed. The bootstrapper checks that name and suffixes `-1` through `-9` for availability; a name reserved by a soft-deleted vault is unavailable, so it tries the next candidate. Creation requires confirmation of the selected name and irreversible purge protection; the resulting group and vault name are saved in the parameter file. The script never purges vaults or silently substitutes a different vault for the configured one.
- Interactive Prepare/Deploy always asks for the foundation resource-group name, even when the configured group exists. Accepting the default reuses that group; selecting another name switches bootstrap-managed identity and vault setup to that group and updates the saved vault parameters. If the selected foundation group is missing, it is created. For a soft-deleted vault, its original resource ID is checked against the selected subscription, group, and vault name, and interactive recovery requires confirmation; existing secrets are preserved. If recovery is declined, the wizard asks for a different foundation group name before creating resources. With `-ParameterFile`, no group-name or recovery prompt is shown; a soft-deleted vault is recovered only when its ID exactly matches those configured inputs. Permission errors and recovery mismatches still stop setup. Plan reports prerequisites without creating or recovering resources.
- A valid Azure region name does not guarantee that this subscription is eligible to create every resource there. If Azure rejects the first mapped region as ineligible, verify subscription eligibility or use [manual preparation](manual-preparation.md#azure-context-and-foundation) to create prerequisites and run subscription deployments in a supported location. Do not renumber an existing lab's region indexes just to select a location. Manual preparation retains its separate location choices.
- Existing foundation resources keep their locations. Missing identities and vaults are created in the first mapped region even when the existing group's metadata location differs; no location prompt is shown.
- Foundation deletion locks cover the identity and vault resource groups, including all resources in those groups.
- GitHub setup verifies OIDC trust and role assignments; conflicting credential trust requires manual review.

### Bicep Setup Safety

- Existing region indexes and explicit access-source ranges are preserved. For brownfield changes, review declared inventory and desired state before using `-ParameterFile`.
- Review `what-if` before confirming `DEPLOY`. The wizard does not replace the AMRL validation engine or discover retained VM inventory.
- GitHub Actions variable values and secret names are verified after setup. Secret values cannot be read back.

### Results

The final report summarizes the effective configuration, foundation checks and changes, Bicep validation findings, Azure `what-if` predictions, deployment operations, and VM guest checks when available. Pass `-ReportPath <path>` to save this report as plain text in addition to console output. Validation findings and the full VM setup-check table appear only in this report. Post-deployment collection displays progress messages, including after failure, without repeating result details; live Azure resource progress remains visible during deployment. The report distinguishes failed, skipped, unavailable, and not-requested results. Foundation setup can occur during Prepare even when lab resources are not deployed; secret values are never printed.

`what-if` predicts changes against current Azure resources; it is not a comparison with the previous parameter file or wizard run. A predicted `Create` does not mean this run created the resource. For validation findings, deployment failures, guest-check limits, and follow-up steps, see [Deployment Results and Troubleshooting](validation-and-troubleshooting.md).

Planned changes are grouped by VM for Run Commands and by resource type and region for other resources, with deletions marked `DELETE`. Bicep deployment results show overall and stage status, nested-resource totals, and failed or incomplete operations using readable names rather than ARM paths. Deployment records are excluded from resource totals; unreadable operation lists are reported as partial or unavailable. ARM operation labels are not an exact comparison with what-if: `Create` can also update an existing resource. Guest execution results remain in the separate VM setup-check table.

## Manual Alternative

[Manual Preparation](manual-preparation.md) separates subscription-level prerequisites from Bicep setup. Follow it instead of bootstrap preparation, then use [Bicep Deployment](deployment.md) to validate, preview, and deploy. Do not repeat manual preparation after a completed bootstrapper run unless a specific repair is required. GitHub OIDC instructions remain in [CI/CD Workflow and Local Checks](ci-cd-validation.md#github-oidc-setup).