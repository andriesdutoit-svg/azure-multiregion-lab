# Azure Multi-Region Lab (AMRL)

AMRL is an educational, hands-on Azure lab for exploring multi-region infrastructure, Active Directory automation, and Bicep-based deployment. It deploys Windows and Linux machines and connected networks; parameter files control the lab's size, placement, topology, and enabled services, supporting both new environments and expansion of existing AMRL labs. It is intended for learning and experimentation, not production deployment.

## What You Deploy

- Regional VNets, role subnets, and NSGs, with full-mesh or hub-spoke connectivity and optional Azure Firewall routing.
- Domain-controller and jumpbox VMs in the primary region, with additional DCs, jumpboxes, and Windows/Linux workloads placed according to capacity.
- AD forest and replica promotion, directory population, Group Policy, workload domain joining, and departmental file services in the identity stage.
- Jumpbox-based administration, optional Azure Bastion, departmental file shares during identity setup, and Linux client desktops for modeled Linux clients.

The project demonstrates modular Infrastructure as Code, staged deployment, declared-inventory reconciliation, and configuration validation. See [Architecture](docs/architecture.md) for how these parts fit together.

See [Project History and Learning Notes](docs/project-history.md) for release history, learning outcomes, and the roadmap.

## Getting Started

Choose a deployment method, whether your subscription is new or already in use:

| Method | Preparation And Deployment |
|---|---|
| **Bootstrapper (recommended)** | [Bootstrapper Guide](docs/bootstrapper.md): create or reuse prerequisites, configure Bicep, review `what-if`, and deploy. |
| **Manual** | [Manual Preparation](docs/manual-preparation.md): subscription-level setup, then Bicep setup. Continue with [Bicep Deployment](docs/deployment.md). |

The bootstrapper covers both setup areas below. You do not need to create the Key Vault, secrets, or deployment identity beforehand; existing resources can be reused through the parameter file's foundation resource group and Key Vault name. Bicep and the bootstrapper read the identity name, administrator usernames, and secret names from [shared defaults](config/amrl-defaults.json). The default foundation resource location is the first `regionIndexMap` entry; this is separate from the VM regions the lab deploys into. Azure's listed regions may still be restricted for new resources in a particular subscription.

With the [prerequisites](#prerequisites) installed, sign Azure CLI into the intended subscription, then run Prepare mode from the repository root in Windows PowerShell 5.1:

```powershell
.\scripts\Initialize-Lab.ps1 -Prepare
```

Confirm the Azure context and answer the wizard questions. Prepare mode sets up subscription-level items and checks Bicep values with preflight and `what-if`, but does not deploy lab resources. Review the proposed changes, then deploy using the saved configuration:

```powershell
.\scripts\Initialize-Lab.ps1 -ParameterFile .\main.parameters.local.json -Deploy
```

The script reruns preflight and `what-if`, then requires you to type `DEPLOY`. See the setup guide for optional read-only `-Plan`, GitHub configuration, and safety details. After deployment, [review the results](docs/validation-and-troubleshooting.md#post-deployment-review) and [connect to the lab](docs/access-and-administration.md).

The manual path is an alternative, not an additional phase after bootstrapper deployment. For an existing lab, review [Existing Lab Configuration](#existing-lab-configuration) before using either method.

> **Cost and cleanup:** This lab provisions billable resources, including virtual machines, managed disks, Azure Firewall, and optional Bastion. Estimate costs for your chosen regions and sizes before deploying, and deallocate or remove resources when they are no longer needed. Network reconciliation is not a full teardown; review the [cleanup boundaries](docs/deployment.md#brownfield-topology-simplification). Verify ownership before deleting the foundation resource group because its Key Vault and managed identity may be shared or reused.

## Prerequisites

Run the bootstrapper from Windows PowerShell 5.1 with Azure CLI, Bicep, and `ssh-keygen` available.

### Subscription-Level Setup

- Azure CLI authenticated to the intended subscription; see [sign-in and subscription selection](docs/bootstrapper.md#requirements).
- Permission to create prerequisite resources and assign required roles.
- Required providers, deployment identity/RBAC, and Key Vault credentials/protections. The bootstrapper creates or reuses these; the [manual path](docs/manual-preparation.md#subscription-level-setup) prepares them explicitly.
- Optional GitHub OIDC identity/access setup requires Entra app-management permission.

### Bicep Setup

- A configured parameter file using the foundation resource group and Key Vault name; the wizard can prepare this for a new lab. The deployment identity uses the shared default name in that same group.
- Valid VM sizes and images for the target regions.
- Sufficient regional vCPU quota.
- At least one domain controller requested with `vmCounts.dc >= 1`; AD is the lab's control plane, even when identity setup is deferred to a later stage.

Trial and Student subscriptions may restrict regions, VM sizes, images, or quota. Check availability before deployment using the commands in [Validation and Troubleshooting](docs/validation-and-troubleshooting.md).

GitHub Actions is optional. Use `-IncludeGitHub` for bootstrapper-managed OIDC and repository settings. Publishing the Bicep deployment values to Actions also requires Git, authenticated GitHub CLI, and repository write access.

## Manual Bicep Deployment

Use this direct Azure CLI path after [Manual Preparation](docs/manual-preparation.md). If you choose the [bootstrapper](docs/bootstrapper.md), it handles preparation and can also deploy; do not repeat this deployment after a completed bootstrapper run.

### Subscription-Level Setup Check

- The Key Vault and required administrator, service-account, and SSH-key secrets must exist.
- The deployment managed identity must exist and have Network Contributor at subscription scope.

### Bicep Setup And Deployment

1. Copy `main.parameters.demo.json` to `main.parameters.local.json` for the new lab; do not overwrite an existing lab's parameter file.
2. Replace `<YOUR_PUBLIC_IP>` with your public IPv4 address (the demo adds `/32`) and `<KEYVAULT_NAME>` with your Key Vault name. Set `foundationResourceGroup` to the resource group containing both the Key Vault and the deployment identity named by the shared defaults.
3. Keep passwords and SSH keys out of the parameter file; Bicep retrieves the required secrets from Key Vault. For a new lab, set `existingRegions` and `existingVmPlacements` to empty arrays; for an existing lab, maintain [reviewed inventory](#existing-lab-configuration).
4. Keep at least one DC and one jumpbox, then choose workload counts, topology, and the intended deployment stage.
5. Complete [Local Validation](docs/ci-cd-validation.md#local-validation), including what-if review, then deploy:

```powershell
$parameterFile = '.\main.parameters.local.json'
$deploymentLocation = 'westeurope'
$deploymentName = 'amrl-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
az deployment sub create `
        --name $deploymentName `
        --location $deploymentLocation `
        --template-file main.bicep `
        --parameters $parameterFile
```

Review [deployment and guest results](docs/validation-and-troubleshooting.md#post-deployment-review), then follow [Access and Administration](docs/access-and-administration.md) to connect. See [Configuration Parameters Reference](docs/configuration-parameters-reference.md) for the complete Bicep settings.

## Existing Lab Configuration

These are Bicep setup considerations for either deployment method; the bootstrapper does not discover retained inventory.

If deploying through the bootstrapper, use `-ParameterFile` with the reviewed configuration rather than the wizard. Run `-Plan`, review `what-if`, then use the same file with `-Deploy`. See [Existing Environments](docs/bootstrapper.md#existing-environments).

1. List reused networking regions in `existingRegions`.
2. List every retained VM in `existingVmPlacements`.
3. Keep existing region indexes unchanged because they determine VNet address spaces.
4. Set `vmCounts` to the desired total VM counts.
5. Use a new deployment name when rerunning identity automation.

See [Brownfield Deployment](docs/deployment.md#brownfield-deployment) for an inventory example and [Placement and Reconciliation](docs/placement-and-reconciliation.md) for the complete model.

## Network Topology

The `networkMode` parameter selects the network topology without changing VM placement or identity orchestration:

| `networkMode` | Deploys | Connectivity |
|---|---|---|
| `hubSpokeFirewall` | Hub-spoke peerings and Azure Firewall routing | Cross-spoke traffic and workload Internet egress use the hub firewall. |
| `hubSpoke` | Hub-spoke peerings only | Hub-to-spoke traffic only. Azure VNet peering is non-transitive, so spokes cannot communicate through the hub. |
| `fullMesh` | Direct peering between every selected region | Direct region-to-region connectivity without Azure Firewall or UDRs. |

Confirm candidate peerings are obsolete before enabling destructive network reconciliation; it does not discover the prior topology. See [Deployment Guide](docs/deployment.md#brownfield-topology-simplification) for safety boundaries and [Architecture](docs/architecture.md) for resource, routing, and addressing details.

## Deployment Stages

| Stage | Behavior |
|---|---|
| `network` | Creates or reuses regional networking and peerings. |
| `compute` | Creates missing domain controllers, jumpboxes, and workload VMs. |
| `identity` | Runs AD bootstrap, replica promotion, directory and Group Policy provisioning, workload domain joins, and departmental file services. It may create missing workload VMs; existing control-plane DCs are required. Linux client desktops are installed when modeled; Windows Admin Center is optional. |
| `all` | Runs the complete workflow. |

Stages are dependency layers rather than isolated products: compute requires networking to exist, and identity may create missing workload VMs. See the [Deployment Guide](docs/deployment.md#stages) for sequencing, prerequisites, brownfield examples, and readiness checks.

## Identity and Domain Join

Azure VM Run Commands configure AD, Group Policy, and domain membership. The identity stage also provisions departmental file shares; Linux client desktops are installed when those VMs are modeled, and Windows Admin Center can be enabled optionally. Identity can run after network and compute stages. See [Identity and Domain Join](docs/identity-and-domain-join.md) for the workflow and [Access and Administration](docs/access-and-administration.md) to connect to the lab.

## Validation

Deployment outputs describe placement, capacity, configuration, and active validation findings. `validationMode=reportOnly` reports findings and continues; `validationMode=enforce` blocks stages when blocking findings are active, while advisory findings remain non-blocking.

See [Deployment Results and Troubleshooting](docs/validation-and-troubleshooting.md) for outputs and readiness checks, and [CI/CD Workflow and Local Checks](docs/ci-cd-validation.md) for local and automated validation.

## Repository Structure

```text
main.bicep                        Placement model and subscription-scope orchestration
main.parameters.*.json            Deployment parameter examples
scripts/Initialize-Lab.ps1        Prerequisite preparation and guided Bicep deployment
modules/stages                   Network, compute, and identity stage contracts
modules/networking               VNets, subnets, NSGs, peerings, firewall, routes, Bastion
modules/compute                  Windows and Linux VM resources and guest helpers
modules/identity                 AD, domain-join, and departmental share automation
modules/logic                    Configuration/capacity validation and enforcement gate
docs/                            Detailed project documentation
```

## Known Limitations

- No live inventory discovery: maintain `existingRegions` and `existingVmPlacements` manually.
- Preserve deployed region indexes; they determine VNet address spaces.
- Network reconciliation is not full migration or resource retirement. See [Deployment Guide](docs/deployment.md#brownfield-topology-simplification) for supported boundaries.
- Verify regional VM availability and quota before deployment, and guest networking, DNS, AD services, and VM Agent health afterward. Deployment success alone does not prove operational readiness.
- The solution is designed for networking structures created by its own modules, not arbitrary existing VNets.

## Planned Future Work

See the [Roadmap](docs/project-history.md#roadmap) for planned capabilities and deferred work.

## Detailed Documentation

- [Bootstrapper Guide](docs/bootstrapper.md)
- [Manual Preparation](docs/manual-preparation.md)
- [Architecture](docs/architecture.md)
- [Bicep Deployment Guide](docs/deployment.md)
- [Configuration Parameters Reference](docs/configuration-parameters-reference.md)
- [Placement and Reconciliation](docs/placement-and-reconciliation.md)
- [Identity and Domain Join](docs/identity-and-domain-join.md)
- [Access and Administration](docs/access-and-administration.md)
- [Deployment Results and Troubleshooting](docs/validation-and-troubleshooting.md)
- [CI/CD Workflow and Local Checks](docs/ci-cd-validation.md)
- [Project History and Learning Notes](docs/project-history.md)

## License

AMRL's original code and documentation are licensed under the [MIT License](LICENSE). Third-party components retain their own licenses; see the license file in each component directory.
