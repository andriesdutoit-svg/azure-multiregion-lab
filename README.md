# Azure Multi-Region Lab (AMRL) v2.8

AMRL is a subscription-scope Azure lab implemented with Bicep. It demonstrates modular Infrastructure as Code, parameter-driven desired state, staged deployment, selectable network topologies, capacity-aware VM placement, and idempotent Active Directory automation.

**v2.8 is complete.** See [Project History and Learning Notes](docs/project-history.md) for release evolution, design decisions, and IaC learning outcomes.

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

1. Copy `main.parameters.demo.json` to a local parameter file.
2. Replace `<YOUR_PUBLIC_IP>` with your public IPv4 address (the demo adds `/32`), `<KEYVAULT_ID>` with your Key Vault resource ID, and `<AUTOMATION_MANAGED_IDENTITY_RESOURCE_ID>` with your User Assigned Managed Identity resource ID.
3. Ensure the Key Vault contains the referenced `sshPublicKey`, `sshPrivateKey`, `jumpboxAdminPassword`, `serverAdminPassword`, and `clientAdminPassword` secrets. Keep the Key Vault references in the parameter file; do not paste SSH keys or passwords into it.
4. Set `existingRegions` and `existingVmPlacements` to empty arrays.
5. Set `vmCounts.dc` to at least `1`.
6. Deploy the Bicep template:

```powershell
az deployment sub create `
        --name <deployment-name> `
        --location <deployment-location> `
        --template-file main.bicep `
        --parameters <parameters-file>.json
```

The managed identity is used only for applicable brownfield peering cleanup during `stage=network` or `stage=all`; the cleanup script is not deployed for greenfield deployments. For Key Vault setup and parameter details, see [Deployment Guide](docs/deployment.md) and [Configuration Parameters Reference](docs/configuration-parameters-reference.md).

## Quick Start: Brownfield

For an existing AMRL environment:

1. List reused networking regions in `existingRegions`.
2. List every retained VM in `existingVmPlacements`.
3. Keep existing region indexes unchanged because they determine VNet address spaces.
4. Set `vmCounts` to the desired total VM counts.
5. Use a new deployment name when rerunning identity automation.

See [Brownfield Deployment](docs/deployment.md#brownfield-deployment) for an inventory example and [Placement and Reconciliation](docs/placement-and-reconciliation.md) for the complete model.

## What This Project Demonstrates

- Modular Bicep infrastructure with explicit scopes and staged deployment.
- Parameter-driven greenfield and brownfield deployment using declared inventories.
- Deterministic, capacity-aware placement across selectable network topologies.
- Active Directory automation, Group Policy, and Windows/Linux endpoint administration.
- Optional departmental file services and Linux client desktops.
- Key Vault-backed credentials and classified validation findings with optional deployment enforcement.

## Network Topology

The `networkMode` parameter selects the network topology without changing VM placement or identity orchestration:

| `networkMode` | Deploys | Connectivity |
|---|---|---|
| `hubSpokeFirewall` | Hub-spoke peerings and Azure Firewall routing | Cross-spoke traffic and workload Internet egress use the hub firewall. |
| `hubSpoke` | Hub-spoke peerings only | Hub-to-spoke traffic only. Azure VNet peering is non-transitive, so spokes cannot communicate through the hub. |
| `fullMesh` | Direct peering between every selected region | Direct region-to-region connectivity without Azure Firewall or UDRs. |

Confirm candidate peerings are obsolete before enabling brownfield cleanup; it does not discover the prior topology. See [Deployment Guide](docs/deployment.md#brownfield-topology-simplification) for cleanup safety and [Architecture](docs/architecture.md) for resource, routing, and addressing details.

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
main.bicep                         Subscription-scope orchestrator
main.parameters.*.json             Deployment parameter examples
modules/networking                 VNets, subnets, NSGs, firewall, routes
modules/networking/peering.bicep   Mode-specific hub-spoke or full-mesh peering
modules/compute                    Windows and Linux VM resources
modules/identity                   AD and domain-join automation
modules/logic                      Placement and configuration validation
docs/                              Detailed project documentation
```

## Known Limitations

- No live inventory discovery: maintain `existingRegions` and `existingVmPlacements` manually.
- Preserve deployed region indexes; they determine VNet address spaces.
- Topology cleanup is not full migration or resource retirement. See [Deployment Guide](docs/deployment.md#brownfield-topology-simplification) for supported boundaries.
- Verify regional VM availability and quota before deployment, and guest networking, DNS, AD services, and VM Agent health afterward. Deployment success alone does not prove operational readiness.
- The solution is designed for networking structures created by its own modules, not arbitrary existing VNets.

## Planned Future Work

The planned roadmap is:

- **v2.8.1:** Engineering hardening, including drift tests, SSH-key reconciliation, deployment logging, and safe configuration updates.
- **v2.9-v2.12:** Azure Bastion, Azure Arc, service accounts and file-server reconciliation, then monitoring and observability. The service-account and file-migration architecture will be scoped during v2.11 development.
- **v3.0-v3.3:** Security enhancements and policy baselines, public key infrastructure, hybrid identity, then multi-forest support.
- **v4.x:** Automatic discovery, explicit DC IP allocation and safe DNS reconciliation, full topology reconciliation, reverse transitions, and zero-VM deployment support. Advanced networking, security, and lab lifecycle automation remain stretch goals.

See [Deployment Guide](docs/deployment.md#brownfield-topology-simplification) for current topology-cleanup boundaries.

## Detailed Documentation

- [Architecture](docs/architecture.md)
- [Deployment Guide](docs/deployment.md)
- [Configuration Parameters Reference](docs/configuration-parameters-reference.md)
- [Placement and Reconciliation](docs/placement-and-reconciliation.md)
- [Identity and Domain Join](docs/identity-and-domain-join.md)
- [Access and Administration](docs/access-and-administration.md)
- [Deployment Results and Troubleshooting](docs/validation-and-troubleshooting.md)
- [CI/CD Workflow and Local Checks](docs/ci-cd-validation.md)
- [Project History and Learning Notes](docs/project-history.md)
