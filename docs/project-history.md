# Project History and Learning Notes

[Back to README](../README.md)

## Project Evolution

- **v1.0**: Bicep multi-region deployment baseline.
- **v1.5**: Automated deployment and validation.
- **v1.6-v1.11**: Network foundation, security, modularity, and hub-spoke routing.
- **v1.12**: Stage-based deployment control.
- **v1.13**: Role-based VM sizing, storage, and CI validation.
- **v2.0**: AD forest and replica DC automation.
- **v2.1**: Directory population and AGDLP group seeding.
- **v2.1.1**: Brownfield networking reuse.
- **v2.2**: Domain join automation, identity reconciliation, and department refactoring.
- **v2.3.1**: Route table and hub-spoke routing refactor.
- **v2.3.2**: Brownfield VM placement reconciliation, capacity accounting, Linux domain-join resilience, and stable region-index guidance.
- **v2.3.3**: Controlled egress through Azure Firewall for workload subnets.
- **v2.3.4**: Linux client GUI desktop with RDP access, and dynamic DNS registration for FQDN reachability.
- **v2.3.5**: Brownfield placement validation and clearer deployment diagnostics.
- **v2.4**: Main Bicep decomposition into staged modules.
- **v2.4.1**: Brownfield networking and cross-spoke routing fixes.
- **v2.4.2**: Identity reconciliation and directory population cleanup.
- **v2.5**: Selectable network topologies and brownfield firewall support.
- **v2.6**: Windows administration GPOs and unique passwords for new AD users.
- **v2.7**: Windows/Linux endpoint administration and configuration reconciliation.
- **v2.8**: Blocking/advisory validation findings, `reportOnly`/`enforce` modes, pre-stage deployment gating, and remediation details.
- **v2.8.1**: Engineering hardening for deployment logging, retained-jumpbox SSH-key targeting, and network-coverage validation.
- **v2.9 (development branch)**: Optional hub-region Azure Bastion, desired-state peering/Bastion cleanup without a separate execution flag, and reconciliation-identity validation. Implementation on this branch does not by itself imply a published release or full live-transition sign-off.

## Roadmap

- **v2.10-v2.12:** Azure Arc, service accounts and file-server reconciliation, then monitoring and observability. The service-account and file-migration architecture will be scoped during v2.11 development.
- **v3.0-v3.3:** Security enhancements and policy baselines, public key infrastructure, hybrid identity, then multi-forest support.
- **v4.x:** Automatic discovery, explicit DC IP allocation and safe DNS reconciliation, full topology reconciliation, reverse transitions, and zero-VM deployment support.
- **Stretch goals:** Advanced networking, security, and lab lifecycle automation.

## Learning Outcomes Demonstrated

### Declarative IaC

Bicep defines resource topology, configuration, scopes, dependencies, and deployment conditions. Parameter files provide environment-specific desired state without changing the modules.

### Modular Design

Networking, compute, identity, peering, and validation responsibilities are separated into reusable modules. The root template coordinates those modules and passes explicit contracts between them.

### Desired State Reconciliation

The VM model distinguishes desired resources from existing inventory. Missing resources are created, existing resources are retained, and identity scripts inspect current state before remediating it.

### Dependency Management

Explicit dependencies ensure that VNets, route tables, VMs, forest bootstrap, replica promotion, directory population, and domain join occur in the required order.

### Operational Feedback

Validation outputs and Run Command instance views expose placement decisions, capacity calculations, and guest execution results. This separates template errors from Azure availability or guest configuration problems.

## Known Boundaries

- Live Azure VM discovery is not automatic; brownfield inventory is supplied through parameters.
- Azure SKU availability and quota must be checked against the target subscription.
- Region indexes determine VNet address spaces and must be treated as part of the deployed network contract.
- Identity scripts are idempotent, but guest networking, DNS, Kerberos, LDAP, and Azure VM Agent health can still affect execution.
- Supported network reconciliation retires candidate spoke-to-spoke peerings for hub-spoke targets and disabled framework-owned Bastion resources. Broader firewall, route-table, association, and region retirement remains future work; see [deployment boundaries](deployment.md#brownfield-topology-simplification).

## Third-Party Components

AMRL incorporates concepts and architectural inspiration from [Set-DummyAD](https://github.com/BOAScripts/Set-DummyAD) (MIT License). AMRL does not execute the original Set-DummyAD solution directly; it has been substantially adapted and integrated into this deployment framework.

Concepts derived from or inspired by Set-DummyAD include AD OU generation, department modelling, security group generation, AGDLP group nesting, file share creation, NTFS permission assignment, and manager/user population workflows.

Files containing logic derived from or inspired by Set-DummyAD:

- `modules/identity/scripts/Install-Forest.ps1`
- `modules/identity/scripts/Promote-ReplicaDC.ps1`
- `modules/identity/scripts/Populate-AD.ps1`

AMRL follows a non-destructive deployment model: re-execution of the identity stage creates missing objects and repairs selected attributes rather than enforcing an exact directory state.

[Back to README](../README.md)
