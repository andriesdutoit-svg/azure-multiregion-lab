# Azure Multi-Region Lab (AMRL) v2.8

AMRL is a subscription-scope Azure lab implemented with Bicep. It demonstrates modular Infrastructure as Code, parameter-driven desired state, staged deployment, selectable network topologies, capacity-aware VM placement, and idempotent Active Directory automation.

See [Project History and Learning Notes](docs/project-history.md) for the design decisions and IaC concepts demonstrated by the project.

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

Example VM inventory entry:

```json
{
        "type": "srvlin",
        "index": 2,
        "regionKey": "centralindia"
}
```

Existing VM identities are retained and excluded from VM creation. Missing VM identities are created, and existing VM occupancy is counted before new placement.

See [Placement and Reconciliation](docs/placement-and-reconciliation.md) for the complete model.

## What This Project Demonstrates

- Declarative Azure infrastructure using Bicep.
- Reusable modules with explicit resource-group and subscription scopes.
- Parameter-driven greenfield and brownfield deployments.
- Deterministic regional placement with capacity protection.
- Brownfield reconciliation using existing region and VM inventories.
- Staged deployment of networking, compute, identity, and workloads.
- Idempotent AD forest, replica, directory population, and domain-join automation.
- Optional departmental file services on the primary DC or the first Windows server.
- Validation outputs that explain template decisions and configuration problems.
- Secure credential and SSH-key references through Azure Key Vault.
- Controlled egress via Azure Firewall for workload subnets, with internal cross-spoke traffic and workload Internet access routed through the firewall.
- Automatic GUI desktop and RDP access on Linux clients, with dynamic DNS registration for FQDN reachability.
- v2.4 staged module decomposition with explicit network, compute, and identity stage contracts.
- v2.4.1 brownfield network reconciliation and reliable cross-spoke routing for spoke DCs and jumpboxes.
- v2.4.2 identity reconciliation improvements and responsibility-based directory population functions.
- v2.5 selectable hub-and-spoke firewall, hub-and-spoke peering-only, and full-mesh topology creation.
- v2.6 OU-targeted Server and Client Administration GPO provisioning, Windows administrators group-reference reconciliation, and unique random passwords for newly created AD users.
- v2.7 AD-group-based Windows and Linux endpoint administration with selected GPO, SSSD, realm-login, home-directory, and sudoers reconciliation.
- v2.8 validation findings classified as blocking or advisory, with `reportOnly` and `enforce` modes, pre-stage enforcement, and remediation details.

## Network Topology

The `networkMode` parameter selects the network topology without changing VM placement or identity orchestration:

| `networkMode` | Deploys | Connectivity |
|---|---|---|
| `hubSpokeFirewall` | Hub-spoke peerings, Azure Firewall, firewall policy, `AzureFirewallSubnet`, route tables, and UDRs | Cross-spoke traffic is routed through the hub firewall. |
| `hubSpoke` | Hub-spoke peerings only | Hub-to-spoke traffic only. Azure VNet peering is non-transitive, so spokes cannot communicate through the hub. |
| `fullMesh` | Direct peering between every selected region | Direct region-to-region connectivity without Azure Firewall or UDRs. |

The primary region remains the hub and control-plane anchor for `dc01` and `jmp01` in every mode. Role-based NSGs protect all standard subnets.

For brownfield topology simplification, cleanup can remove candidate spoke-to-spoke peerings when moving to `hubSpoke` or `hubSpokeFirewall`. The template infers candidates from `existingRegions`; it does not discover or validate the previously deployed topology. Confirm that matching peerings are obsolete before enabling deletion. See [Deployment Guide](docs/deployment.md#brownfield-topology-simplification) for the cleanup procedure, scope, and RBAC requirement.

See [Architecture](docs/architecture.md) for the resource model, module boundaries, network layout, addressing, and desired-state model.

## Deployment Stages

| Stage | Behavior |
|---|---|
| `network` | Creates or reuses regional networking and peerings. |
| `compute` | Creates missing domain controllers, jumpboxes, and workload VMs. |
| `identity` | Runs AD bootstrap, replica promotion, directory population, and domain joins. Missing workload VMs needed by the identity flow may also be created. Existing control-plane DCs are required. |
| `all` | Runs the complete workflow. |

Typical staged order:

```text
network -> compute -> identity
```

Stages are dependency layers rather than isolated products: compute requires networking to exist, and identity may create missing workload VMs. See the [Deployment Guide](docs/deployment.md#stages) for sequencing, prerequisites, brownfield examples, and readiness checks.

`validationMode=reportOnly` reports findings and continues; `validationMode=enforce` fails the validation gate when blocking findings are active. See [Deployment Results and Troubleshooting](docs/validation-and-troubleshooting.md) for validation outputs.

## Identity and Domain Join

Identity automation runs through Azure VM Run Command resources:

```text
Primary DC forest bootstrap
        ->
Replica DC promotion
        ->
Directory population
        ->
Group Policy provisioning
        ->
Windows and Linux domain join
        ->
Departmental share provisioning (when enabled)
```

The scripts inspect current state before applying changes. Existing forests, domain controllers, and domain memberships are retained. Missing or incomplete configuration is repaired where supported. Administration GPOs are imported from exported backups only when absent, so later template edits do not overwrite an existing GPO.

See [Identity and Domain Join](docs/identity-and-domain-join.md) for Windows and Linux behavior, healing, troubleshooting, and Run Command inspection.

See [Access and Administration](docs/access-and-administration.md) for RDP, SSH, Key Vault setup and recreation, and AD access.

See [CI/CD Workflow and Local Checks](docs/ci-cd-validation.md) for GitHub Actions and Azure authentication guidance.

## Validation

The deployment returns outputs for placement and configuration review, including:

- `validationSummary`
- `validationMessage`
- `validationFlags`
- `workloadCapacitySummary`
- `workloadCapacityByRegion`
- `invalidExistingVmPlacementDetails`
- `invalidExistingVmPlacementCount`
- `hasInvalidExistingVmPlacements`
- `vmPlacement`
- `vmCountPerRegion`
- `capacityCheck`
- `regionSummary`

See [Deployment Results and Troubleshooting](docs/validation-and-troubleshooting.md).

See [CI/CD Workflow and Local Checks](docs/ci-cd-validation.md) for GitHub Actions and local Bicep validation.

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

- Live Azure discovery is not used for brownfield reconciliation. You must declare existing network regions in `existingRegions` and existing VMs in `existingVmPlacements`; planned topology reconciliation will likewise require manually declared current and desired topologies.
- Region indexes determine VNet address spaces and must be treated as part of the deployed network contract.
- Brownfield topology cleanup infers candidate spoke-to-spoke peerings from `existingRegions`; it does not discover the prior topology or retire firewall resources, route tables, UDR associations, `AzureFirewallSubnet`, or resources required by reverse or expansion transitions. See [Deployment Guide](docs/deployment.md#brownfield-topology-simplification).
- Azure VM SKU availability and quota are subscription- and region-specific and require preflight checks.
- Identity scripts depend on guest networking, DNS, Kerberos, LDAP, and a healthy Azure VM Agent.
- Control-plane placement falls back to the hub after spoke capacity is exhausted; per-region validation reports hub overflow after placement rather than preventing the fallback.
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

## Release

**v2.8 is complete.** It adds a classified validation findings catalog, `reportOnly` and `enforce` modes, and a validation gate that blocks network, compute, and identity stages when blocking findings are active. Blocking and advisory findings include remediation guidance. Full topology migration and resource retirement remain planned work.
