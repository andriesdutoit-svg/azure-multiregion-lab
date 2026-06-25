# Azure Multi-Region Lab — v1.9

## Overview

This project deploys a secure, multi-region Azure lab environment using Bicep. Version 1.9 focuses on security hardening, identity foundations, and infrastructure best practices to prepare for Active Directory integration in v2.0.

---

## Key Architecture Principles

- Multi-region deployment
- Subnet-level segmentation
- Jumpbox-only administrative access
- Private-only internal workloads
- Infrastructure as Code (Bicep)

---

## Security Hardening (v1.9)

### Network Security
- Subnet-specific NSGs (DC, server, client, jumpbox)
- Explicit deny rules to stop lateral movement
- Override default AllowVNetInBound

### Access Control
- Single entry point via jumpbox
- No direct RDP/SSH from internet to internal VMs
- No VM-to-VM administrative access

### Public Exposure
- Public IP assigned only to jumpbox
- All other VMs are private-only

---

## Identity & Authentication

### Admin Model
- Single admin identity: `azureadmin`
- Role-based credential separation via Key Vault

### Key Vault Integration
- Passwords stored securely in Key Vault
- Separate secrets per role:
  - jumpboxAdminPassword
  - serverAdminPassword
  - clientAdminPassword

### Linux Authentication
- SSH key-based authentication enabled
- Password login disabled
- Public key deployed via Bicep

---

## VM Security Enhancements

- Trusted Launch (Gen2, Secure Boot, vTPM)
- System Assigned Managed Identity enabled
- Boot diagnostics enabled
- VM agent enabled for extensions and monitoring

---

## Naming Convention

| Resource Type | Pattern |
|--------------|--------|
| Domain Controllers | dc01, dc02 |
| Windows Servers | srvwin01 |
| Linux Servers | srvlin01 |
| Windows Clients | cliwin01 |
| Linux Clients | clilin01 |
| Jumpbox | jmp01 |

- Zero-padded numbering (01–09)
- Consistent naming across Azure and OS

---

## Network Architecture

- Multi-region VNets with peering
- Centralised jumpbox access across regions
- AD-required ports pre-configured

---

## AD Readiness

- DNS configured to use DC IPs (future state)
- Time synchronization validated
- Naming aligned for AD integration
- Network prepared for replication and authentication

---

## SSH Key Model

- Public key stored in parameters file (non-sensitive)
- Private key stored securely on jumpbox
- Login flow:
  - Laptop → RDP → Jumpbox
  - Jumpbox → SSH → Linux VMs

---

## v1.9 Outcome

- Secure, segmented, multi-region environment
- Centralised administrative access
- Hardened authentication (key-based for Linux)
- Ready for Active Directory deployment

---

