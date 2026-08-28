# Architecture

## Overview

AMRL is a subscription-scope Bicep deployment for a multi-region Azure lab. It creates resource groups, hub-and-spoke VNets, subnet and NSG segmentation, Azure Firewall routing, virtual machines, and optional Active Directory automation.

The primary region is the hub. Other selected regions are spokes. Spoke-to-spoke traffic is routed through the hub firewall rather than using direct spoke peering.

## Infrastructure as Code

The deployment is declarative. Bicep describes the desired resources, their configuration, scopes, and dependencies. Parameters provide the environment-specific inputs, including regions, VM counts, VM sizes, images, credentials references, and deployment stage.

The root [main.bicep](../main.bicep) orchestrates the deployment. Reusable modules own specific resource types:

- `modules/networking` owns VNets, subnets, NSGs, firewalls, and route tables.
- `modules/peering` owns hub-to-spoke and spoke-to-hub peering.
- `modules/compute` owns Windows and Linux VM resources.
- `modules/identity` owns AD automation and domain joining.
- `modules/logic` owns configuration and capacity validation.

## Resource Scope

`main.bicep` uses subscription scope so it can create one resource group per selected region. Regional resources are deployed into their corresponding resource group with module-level resource-group scope.

## Network Layout

Each region receives a VNet address space derived from its region index:

```text
10.<region index>.0.0/16
```

Subnet indexes are supplied through `subnetIndexMap`. The standard layout is:

```text
firewall = 0
jumpbox  = 1
dc       = 2
server   = 3
client   = 4
```

The hub contains the firewall and control-plane subnets. Spokes contain workload subnets and route tables. NSGs restrict administration and AD traffic by subnet role.

## Controlled Egress

The workload subnets no longer use direct outbound Internet access. Route tables for the server and client subnets send `0.0.0.0/0` to the Azure Firewall private IP, so all egress from those subnets is forced through the hub firewall. This creates a centralized inspection and policy-enforcement point while preserving internal communication and allowed outbound HTTP/HTTPS flows.

This is a controlled-egress design rather than a block-all design: outbound connectivity is still allowed where required, but it is centralized and inspectable at the firewall instead of being direct from the workload subnets.

## Desired State

The template combines the desired VM model with `existingVmPlacements`. Existing VM identities are retained, missing VM identities are created, and the combined placement model is used for validation, DNS generation, capacity calculations, and identity targeting.

The template does not discover live Azure VM inventory. Brownfield users must maintain `existingVmPlacements` in the parameter file.

[Back to README](../README.md)
