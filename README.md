# Azure Multi-Region Lab (AMRL) v2.4.2

AMRL is a subscription-scope Azure lab implemented with Bicep. It demonstrates modular Infrastructure as Code, parameter-driven desired state, staged deployment, hub-and-spoke networking, capacity-aware VM placement, and idempotent Active Directory automation.

See [Project History and Learning Notes](docs/project-history.md) for the design decisions and IaC concepts demonstrated by the project.

## Prerequisites

- Azure CLI installed and authenticated to the target subscription.
- Permission to create subscription and resource-group resources.
- Azure Key Vault containing the referenced admin credentials and SSH keys.
- Valid VM sizes and images for the target regions.
- Sufficient regional vCPU quota.

Trial and Student subscriptions may restrict regions, VM sizes, images, or quota. Check availability before deployment using the commands in [Validation and Troubleshooting](docs/validation-and-troubleshooting.md).

## Quick Start: Greenfield

1. Copy `main.parameters.demo.json` to a local parameter file.
2. Replace its placeholders with your public IP, SSH public key, and Key Vault ID.
3. Set `existingRegions` and `existingVmPlacements` to empty arrays.
4. Deploy the Bicep template:

```powershell
az deployment sub create `
        --name <deployment-name> `
        --location <deployment-location> `
        --template-file main.bicep `
        --parameters <parameters-file>.json
```

For Key Vault setup and parameter details, see [Deployment Guide](docs/deployment.md) and [Configuration Parameters Reference](docs/configuration-parameters-reference.md).

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

## Architecture

The deployment creates a hub-and-spoke topology:

- The primary region is the hub.
- Other selected regions are spokes.
- The hub contains Azure Firewall and control-plane resources.
- Workload traffic is routed through the hub firewall.
- Server and client subnets route internal and Internet traffic through the firewall; spoke DCs and jumpboxes route internal traffic through it while retaining direct Internet access.
- Jumpboxes provide the administrative entry point.
- Spoke workload subnets are protected by role-based NSGs and route tables.

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

See [Deployment Guide](docs/deployment.md) for stage prerequisites and brownfield examples.

## Identity and Domain Join

Identity automation runs through Azure VM Run Command resources:

```text
Primary DC forest bootstrap
        ->
Replica DC promotion
        ->
Directory population
        ->
Windows and Linux domain join
        ->
Departmental share provisioning (when enabled)
```

The scripts inspect current state before applying changes. Existing forests, domain controllers, and domain memberships are retained. Missing or incomplete configuration is repaired where supported.

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
modules/networking/peering.bicep   Hub-to-spoke peering
modules/compute                    Windows and Linux VM resources
modules/identity                   AD and domain-join automation
modules/logic                      Placement and configuration validation
docs/                              Detailed project documentation
```

## Known Limitations

- Live Azure VM discovery is not automatic; brownfield inventory must be maintained in `existingVmPlacements`.
- Region indexes determine VNet address spaces and must be treated as part of the deployed network contract.
- Azure VM SKU availability and quota are subscription- and region-specific and require preflight checks.
- Identity scripts depend on guest networking, DNS, Kerberos, LDAP, and a healthy Azure VM Agent.
- Control-plane placement falls back to the hub after spoke capacity is exhausted; per-region validation reports hub overflow after placement rather than preventing the fallback.
- The solution is designed for networking structures created by its own modules, not arbitrary existing VNets.

See the detailed guides for implementation boundaries and operational guidance.

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

**v2.4.2** completes identity reconciliation improvements and the directory population workflow cleanup.
