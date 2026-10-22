# Azure Multi-Region Lab (AMRL)

AMRL deploys a multi-region Azure lab of Windows and Linux machines, connected networks, and optional Active Directory services using Bicep. Parameter files control the lab's size, placement, topology, and enabled services, supporting both new environments and expansion of existing AMRL labs.

**Current completed milestone:** v2.10 Windows Admin Center and remote management. See [Project History](docs/project-history.md) for delivered scope and deferred work.

## What You Deploy

- Regional VNets, role subnets, and NSGs, with full-mesh or hub-spoke connectivity and optional Azure Firewall routing.
- Domain-controller and jumpbox VMs in the primary region, with additional DCs, jumpboxes, and Windows/Linux workloads placed according to capacity.
- Optional AD forest and replica promotion, departmental OUs/groups/users, Group Policy, and workload domain joining.
- Jumpbox-based administration, optional Azure Bastion, departmental file shares, and Linux client desktops.

The project demonstrates modular Infrastructure as Code, staged deployment, declared-inventory reconciliation, and configuration validation. See [Architecture](docs/architecture.md) for how these parts fit together.

See [Project History and Learning Notes](docs/project-history.md) for release history, learning outcomes, and the roadmap.

## Getting Started

Choose one path:

| Your Environment | Start Here |
|---|---|
| New Azure subscription or tenant | [New Subscription Setup](docs/new-subscription-setup.md), including the final deployment |
| Existing foundation, new lab | [Greenfield Quick Start](#quick-start-greenfield) |
| Existing AMRL lab | [Brownfield Quick Start](#quick-start-brownfield) |

## Prerequisites

- Azure CLI installed and authenticated to the target subscription.
- Permission to create subscription and resource-group resources.
- Azure Key Vault containing the referenced admin credentials and SSH keys.
- A User Assigned Managed Identity for deployment-script automation; grant it the Network Contributor role at subscription scope and pass its resource ID through `automationManagedIdentityResourceId`.
- Valid VM sizes and images for the target regions.
- Sufficient regional vCPU quota.
- At least one domain controller requested with `vmCounts.dc >= 1`, even when identity and file services are disabled.

Trial and Student subscriptions may restrict regions, VM sizes, images, or quota. Check availability before deployment using the commands in [Validation and Troubleshooting](docs/validation-and-troubleshooting.md).

## Quick Start: Greenfield

Use this quick start only when the Key Vault, secrets, and deployment managed identity already exist. The new-subscription guide is a complete alternative path, not a prerequisite workflow to repeat afterward.

1. Copy `main.parameters.demo.json` to `main.parameters.local.json` for the new lab; do not overwrite an existing lab's parameter file.
2. Replace `<YOUR_PUBLIC_IP>` with your public IPv4 address (the demo adds `/32`), `<KEYVAULT_ID>` with your Key Vault resource ID, and `<AUTOMATION_MANAGED_IDENTITY_RESOURCE_ID>` with your User Assigned Managed Identity resource ID.
3. Ensure the Key Vault contains the referenced `sshPublicKey`, `sshPrivateKey`, `jumpboxAdminPassword`, `serverAdminPassword`, and `clientAdminPassword` secrets. Keep the Key Vault references in the parameter file; do not paste SSH keys or passwords into it.
4. Set `existingRegions` and `existingVmPlacements` to empty arrays.
5. Keep at least one DC and one jumpbox, then choose the required workload counts and topology.
6. Complete [Local Validation](docs/ci-cd-validation.md#local-validation), including what-if review, then deploy:

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

Review [deployment and guest results](docs/validation-and-troubleshooting.md#post-deployment-review), then follow [Access and Administration](docs/access-and-administration.md) to connect. For foundation setup and parameter details, see [New Subscription Setup](docs/new-subscription-setup.md) and [Configuration Parameters Reference](docs/configuration-parameters-reference.md).

## Quick Start: Brownfield

For an existing AMRL environment:

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
| `identity` | Runs AD bootstrap, replica promotion, directory population, and domain joins. Missing workload VMs needed by the identity flow may also be created. Existing control-plane DCs are required. |
| `all` | Runs the complete workflow. |

Stages are dependency layers rather than isolated products: compute requires networking to exist, and identity may create missing workload VMs. See the [Deployment Guide](docs/deployment.md#stages) for sequencing, prerequisites, brownfield examples, and readiness checks.

## Identity and Domain Join

Azure VM Run Commands configure AD, Group Policy, domain membership, and optional departmental shares. Scripts retain existing state and repair selected configuration; GPO backups seed missing policies rather than overwrite existing ones. See [Identity and Domain Join](docs/identity-and-domain-join.md) for the workflow and reconciliation boundaries, and [Access and Administration](docs/access-and-administration.md) for RDP, SSH, and credential setup.

## Validation

Deployment outputs describe placement, capacity, configuration, and active validation findings. `validationMode=reportOnly` reports findings and continues; `validationMode=enforce` blocks stages when blocking findings are active, while advisory findings remain non-blocking.

See [Deployment Results and Troubleshooting](docs/validation-and-troubleshooting.md) for outputs and readiness checks, and [CI/CD Workflow and Local Checks](docs/ci-cd-validation.md) for local and automated validation.

## Repository Structure

```text
main.bicep                        Placement model and subscription-scope orchestration
main.parameters.*.json            Deployment parameter examples
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

- [New Subscription Setup](docs/new-subscription-setup.md)
- [Architecture](docs/architecture.md)
- [Deployment Guide](docs/deployment.md)
- [Configuration Parameters Reference](docs/configuration-parameters-reference.md)
- [Placement and Reconciliation](docs/placement-and-reconciliation.md)
- [Identity and Domain Join](docs/identity-and-domain-join.md)
- [Access and Administration](docs/access-and-administration.md)
- [Deployment Results and Troubleshooting](docs/validation-and-troubleshooting.md)
- [CI/CD Workflow and Local Checks](docs/ci-cd-validation.md)
- [Project History and Learning Notes](docs/project-history.md)
