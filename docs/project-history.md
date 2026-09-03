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

[Back to README](../README.md)
