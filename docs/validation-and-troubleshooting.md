# Deployment Results and Troubleshooting

[Back to README](../README.md)

## Start Here

If deployment failed with `Deployment blocked by validation enforcement`, inspect the completed validation-engine output first. Replace the placeholders with the root deployment prefix and deployment name; the engine name uses the first 20 characters of the deployment name:

```powershell
az deployment sub show `
  --name "<prefix>-validation-engine-<deployment-name-prefix>" `
  --query "properties.outputs.blockingValidationDetails.value" `
  --output jsonc
```

This returns only active blocking findings, including each finding's flag, message, and remediation.

The command above shows only blocking findings. If you also want all Boolean flags and non-blocking warnings, run this expanded query:

```powershell
az deployment sub show `
  --name "<prefix>-validation-engine-<deployment-name-prefix>" `
  --query "properties.outputs.{flags:validationFlags.value,blocking:blockingValidationDetails.value,advisory:advisoryValidationDetails.value}" `
  --output jsonc
```

`blocking` contains deployment-stopping findings; `advisory` contains warnings that do not block enforcement. If neither explains the issue, use the symptom guide below to investigate Azure provisioning or guest failures.

Identify the failing layer before rerunning a deployment. Configuration findings, Azure provisioning errors, and guest/service failures need different checks:

| Symptom | First checks |
|---|---|
| Build or template validation fails | [Local validation](ci-cd-validation.md#local-validation), parameter shape, required counts, and reported findings. |
| Azure provisioning fails | [Deployment operations](#deployment-operation-checks), regional availability/quota, image, and permissions. |
| Jumpbox or workload is inaccessible | [Access path and account](access-and-administration.md), Public IP/Bastion, NSGs, routing, and VM state. |
| Domain join or name lookup fails | [DNS and domain connectivity](#dns-and-domain-connectivity), DC readiness, then the target Run Command instance view. |
| Department shares are unavailable | Selected file-server host, domain membership, SMB share presence, and modeled group/NTFS permissions. See [File Services](identity-and-domain-join.md#departmental-file-services). |
| WAC install fails or is missing | Confirm identity-stage execution, then inspect `install-wac` Run Command `instanceView` for `executionState`, `exitCode`, and output. Check host DNS/HTTPS to `download.microsoft.com`, installer signature, and WAC service/configuration checks. |
| WAC discovers a server but cannot manage it | Separate TCP reachability, guest firewall, WinRM authentication, and WAC credential delegation. See [WAC and WinRM checks](#wac-and-winrm-checks). |

## Post-Deployment Review

After a successful subscription deployment, query the root deployment to read its saved validation summary, blocking/advisory finding details, capacity, and placement outputs. This command only reads the completed deployment outputs; it does not rerun validation:

```powershell
az deployment sub show `
  --name "<deployment-name>" `
  --query "properties.outputs.{summary:validationSummary.value,blocking:blockingValidationDetails.value,advisory:advisoryValidationDetails.value,capacity:capacityCheck.value,placements:vmPlacement.value}" `
  --output json
```

Then verify the user-visible result: administration access, expected Windows/Linux domain membership, domain DNS, and enabled shares/desktops. Inspect guest `executionState`, `exitCode`, `error`, and `output`; a successful ARM resource operation alone is not proof of guest readiness.

## WAC And WinRM Checks

The current WAC gateway uses WinRM over HTTP (TCP 5985) to manage Windows servers. The gateway's own browser UI uses HTTPS; this is a separate connection. Before changing NSGs, check the complete path and the target's effective guest policy:

```powershell
Test-NetConnection <server-fqdn> -Port 5985
Test-WSMan <server-fqdn> -Authentication Kerberos
Get-NetConnectionProfile
Get-NetFirewallRule -PolicyStore ActiveStore -Name '*WINRM*'
gpresult /scope computer /r
```

`Test-NetConnection` confirms only TCP connectivity. If it fails, verify the source and destination NSGs/routes, WinRM listener, and Windows Firewall. The Server and Client Administration GPOs allow TCP 5985 and 5986 from `10.0.0.0/8` on all profiles; the Domain Controller WinRM GPO allows TCP 5985 from the same range on all profiles. Identity-stage Run Commands refresh and verify the applicable GPO before removing legacy per-VM firewall rules. Check the active GPO rule in `ActiveStore`, its source scope, and the VM's profile.

If authenticated Kerberos WinRM reports that the target is unknown to Kerberos, query the target computer account for both HTTP SPNs and verify identity stage has completed:

```powershell
setspn -Q HTTP/<computer>
setspn -Q HTTP/<computer>.<domain>
```

The Windows domain-join script and DC reconciliation module use `setspn -S` to add missing SPNs to the target computer account. Do not add duplicates to another account. `Test-WSMan` alone checks WSMan response, while `Invoke-Command` with Kerberos verifies that an authenticated remote session can actually be created.

If TCP and `Test-WSMan` work and WAC succeeds with **Manage As** but fails with **Use my Windows account** (`0x8009030e`), investigate Kerberos delegation between the user's browser session, WAC gateway, and target. This symptom points to a delegation issue rather than an NSG port block. RBCD is a candidate future configuration and is not currently provisioned by AMRL. Use explicit Manage As credentials as the current workaround. Do not enable unconstrained delegation as a troubleshooting shortcut.

WinRM over HTTPS on TCP 5986 is not currently configured: the GPO/NSG allowance alone does not provide a listener or server certificate. HTTPS hardening is deferred until the PKI phase.

## Template Validation

`modules/logic/validation.bicep` evaluates configuration and placement rules and returns outputs used by `main.bicep`.

Findings are classified as `block` or `advisory`. With `validationMode=reportOnly`, findings are reported and deployment continues. With `validationMode=enforce`, an active blocking finding makes `validationGate` fail; network, compute, and identity stages depend on that gate and do not execute. Advisory findings do not block enforcement mode.

It checks:

- Required DC and jumpbox counts.
- Region count and index validity.
- Primary DC and jumpbox pinning.
- Non-control VMs remaining outside the hub.
- Desired capacity and regional overflow.
- VM size and OS disk role keys.
- Existing region coverage for staged brownfield deployments.
- Whether compute/identity deployments skip networking for selected regions absent from `existingRegions`.
- Whether newly created VM placements in compute or identity stages target regions missing from `existingRegions` when network provisioning is skipped.
- Remaining workload capacity after existing and new control-plane placement.
- Department and identity configuration.
- File services requiring identity automation.
- Dedicated file-server mode requiring enabled file services and an available `srvwin` VM. See [File Server Reassignment on Brownfield Expansion](placement-and-reconciliation.md#file-server-reassignment-on-brownfield-expansion).
- Windows Admin Center dedicated-host mode requiring WAC to be enabled, and the availability of a modeled `srvwin` when dedicated hosting is requested.

The current template requires `vmCounts.dc >= 1` for every deployment. It evaluates the primary DC and `fileServerName` before the identity and file-service feature flags can suppress their resource modules. With `vmCounts.dc=0`, template evaluation fails because no primary DC exists to supply `fileServerName`; set `dc` to at least `1` and redeploy.

`hasNoDomainControllers` and `hasNoJumpboxes` are evaluated from the final VM placement model, which combines declared existing VM placements with planned placements. They distinguish the loss of the AD control plane from the loss of the supported jumpbox remote-access path; they do not query Azure to confirm that an inventoried VM exists. A zero-DC model can still fail earlier during root-template evaluation as described above, before validation outputs are returned.

## Useful Outputs

- `validationSummary`: Short status for quick review.
- `validationMessage`: First detected validation message.
- `validationFlags`: Boolean validation flags.
- `enforcementEnabled`: Whether `validationMode` is set to `enforce`.
- `shouldBlockDeployment`: Whether enforcement is enabled and blocking findings are active.
- `blockingValidationFlags`: Names of active blocking findings.
- `blockingValidationDetails`: Active blocking findings with category, flag, message, and remediation guidance.
- `blockingValidationSummary`: Summary of active blocking findings.
- `deploymentBlockMessage`: Message used when the enforcement gate fails.
- `advisoryValidationFlags`: Names of active advisory findings.
- `advisoryValidationDetails`: Active advisory findings with category, flag, message, and remediation guidance.
- `networkRegionsMissingFromInventory`: Selected regions missing from `existingRegions` when compute/identity is selected and networking is skipped.
- `newVmRegionsWithoutNetwork`: Target regions for newly created VMs that are not declared in `existingRegions` while the network stage is skipped.
- `workloadCapacitySummary`: Workload demand versus remaining capacity.
- `workloadCapacityByRegion`: Per-region control-plane and workload capacity.
- `capacityCheck`: Overall requested capacity check: `totalVMs` is the requested VM count, `capacity` is `regionCount * maxVmsPerRegion`, and `withinLimit` indicates whether the requested count fits that total capacity. It does not confirm per-region or spoke workload capacity; review the regional outputs and validation flags separately.
- `invalidExistingVmPlacementDetails`: Existing VM entries whose regions are not active.
- `invalidExistingVmPlacementCount`: Number of invalid existing VM placement entries.
- `hasInvalidExistingVmPlacements`: Whether invalid existing VM placement entries were found.
- `vmPlacement`: Combined existing and new VM placement model.
- `vmCountPerRegion`: Final count by region.
- `regionSummary`: Addressing, subnet, and regional VM summary.

Each entry in `blockingValidationDetails` and `advisoryValidationDetails` includes `category`, `flag`, `message`, and `remediation`. The `remediation` property contains a recommended corrective action; it does not change parameters or repair resources automatically.

## Finding Interpretation

A healthy result has `validationSummary` set to `All validation checks passed.` and `capacityCheck.withinLimit` set to `true`. In `validationFlags`, the following flags should be `false`:

- `hasRegionOverflow`: A region, including the hub, exceeds `maxVmsPerRegion`.
- `invalidCapacity`: The total requested VM count exceeds `regionCount * maxVmsPerRegion`.
- `hasNoDomainControllers`: The final placement model contains no DC, so the AD control plane will be unavailable. A jumpbox may still be present and accessible.
- `hasNoJumpboxes`: The final placement model contains no jumpbox, so the supported remote-access path into the environment is unavailable.
- `hasNonControlInHub`: A workload VM was placed in the hub.
- `hasInsufficientWorkloadCapacity`: Control-plane placement left too few spoke slots for workloads.
- `hasMissingNetworkPrerequisites`: Compute/identity is selected while networking is skipped and one or more selected regions are absent from `existingRegions`. Review `networkRegionsMissingFromInventory`; run `stage=network` first, or list a region only if its networking already exists.
- `hasUncoveredNewVmNetworks`: A compute or identity deployment would create VMs in regions not declared as having existing networking. Run `stage=network` or `stage=all`, or correct `existingRegions` if that networking already exists.
- `missingDedicatedFileServer`: `useDedicatedFileServer` is `true` but no `srvwin` VM exists. Target selection falls back to the primary DC so template evaluation can continue, but the configuration is invalid and should be corrected.
- `invalidDedicatedFileServerConfiguration`: `useDedicatedFileServer` is `true` while `enableFileServices` is `false`.
- `invalidFileServicesIdentityConfiguration`: `enableFileServices` or `useDedicatedFileServer` is `true` while `enableIdentity` is `false`.
- `invalidDedicatedWacHostConfiguration`: blocking; `useDedicatedWacHost` is `true` while `enableWindowsAdminCenter` is `false`.
- `missingDedicatedWacHost`: advisory; WAC and dedicated-host mode are enabled, but the final placement model has no `srvwin`. WAC falls back to the primary jumpbox; add or retain a Windows server, or disable dedicated-host preference.
- `invalidWindowsAdminCenterIdentityConfiguration`: blocking; `enableWindowsAdminCenter` is `true` while `enableIdentity` is `false`, so the identity-owned WAC module cannot run.
- `windowsAdminCenterSkippedForStage`: advisory; WAC and identity are enabled, but the selected stage is not `identity` or `all`, so WAC will not be installed in this deployment. Run `stage=identity` or `stage=all` when ready.
- `hasMalformedDomainName`: `enableIdentity` is `true` but `domainName` is blank, single-label, or contains a space, backslash, forward slash, or `@`. Group Policy provisioning builds the domain DN and SYSVOL path to `Groups.xml` from this value. The flag reports the issue before the Run Command, though validation flags are diagnostic and do not by themselves block deployment.
- `hasEmptySysAdminDepartmentCode`: `sysAdminDepartment` is empty or its department code is blank. Group Policy provisioning resolves the Windows admins group created by directory population from this code.
- `hasNoGpoTargetDc`: `enableIdentity` is `true` but `dc01` is not pinned to the primary region. Group Policy is provisioned on the primary domain controller, so there is no target for the import.
- `hasInvalidGpoNames`: `enableIdentity` is `true` but one or more of `serverAdministration`, `clientAdministration`, `windowsLaps`, or `domainControllerWinRM` is empty. The first three names identify exported backups; the DC WinRM name identifies the generated policy.

The template findings cover configuration it can evaluate; they do not replace guest-side checks. Failures inside the Group Policy Run Command itself are reported by the deployment because `ad-gpo.bicep` sets `treatFailureAsDeploymentFailure`. The script fails fast with an explicit message when the base64 ZIP parameter is empty or not decodable, when the expanded archive lacks the `GpoTemplates` root folder or a packaged GPO backup, when `directoryModel.gpoNames` is incomplete, when a target OU is missing, when a WinRM firewall rule cannot be reconciled in its GPO, or when `Groups.xml` does not hold exactly one member entry to reconcile.

`validationFlags` reports each finding independently. `validationMessage` contains only the first active finding in catalog order, with blocking findings listed before advisory findings. In `reportOnly` mode, findings do not block deployment. In `enforce` mode, active blocking findings fail the validation gate before stage modules execute; advisory findings remain non-blocking. This gate does not roll back resources from earlier successful deployments. Some invalid configurations can still fail earlier during template evaluation, such as `vmCounts.dc=0` when the root template requires a primary DC. Also inspect VM Run Command results separately.

The stage network check uses the declared `existingRegions` inventory; it does not discover VNets, confirm role subnets, or verify live connectivity. It checks every selected region because the current subnet contract is produced for the full region set, even when no VM is newly placed there. Network-prerequisite findings are advisory and do not block enforcement mode; confirm that every required VNet and role subnet actually exists before deploying VMs when networking is skipped.

## DNS and Domain Connectivity

Use these checks when a deployment or guest command reports domain lookup or join failures. Run them from a lab VM with private connectivity to the domain, substituting actual names and addresses:

```powershell
Resolve-DnsName '<domainName>'
Resolve-DnsName '<prefix>-srvwin01.<domainName>'
Test-NetConnection -ComputerName '<dc-private-ip>' -Port 53
```

Check actual DC NIC addresses, VNet DNS settings, and DC DNS/AD services. Candidate DNS addresses use `.4` in declared DC regions; that address is likely in a fresh DC-only subnet but is not reserved or discovered. Multiple DCs may occupy different addresses. Deleting/recreating the NIC at `.4`, stale inventory, another NIC occupying it, service failure, or blocked connectivity can invalidate the endpoint. Reused VNets retain their previous DNS settings; verify before making deliberate changes rather than readdressing retained DCs implicitly.

On a Linux workload, these checks help distinguish domain configuration from infrastructure SSH-key access:

```bash
realm list
getent passwd '<domain-user>@<domainName>'
id '<domain-user>@<domainName>'
```

## Automation Log Statuses

Use `[Created]`, `[Verified]`, `[Updated]`, `[Removed]`, `[Skipped]`, `[Warning]`, and `[Error]` to identify automation outcomes; `[Info]` indicates progress. Review warnings and errors, then confirm the guest execution state and exit code. A completion message alone does not prove success.

## Azure Availability Checks

Template validation cannot guarantee that a VM size, image, or quota is available in Azure. Check these independently:

Regional vCPU quotas vary significantly by subscription type:

- **Trial/Free subscriptions**: often 4–8 vCPU per region.
- **Student subscriptions**: often 4 vCPU per region.
- **Standard/Pay-as-you-go subscriptions**: often 20+ vCPU per region.

Example: if each VM uses 2 vCPUs and your regional quota is 4, set `maxVmsPerRegion = 2`.

```powershell
az vm list-sizes --location "<region>" -o table
az vm list-usage --location "<region>" -o table
az vm image list --publisher Canonical --offer 0001-com-ubuntu-server-jammy --sku 22_04-lts-gen2 --location "<region>"
```

Trial and Student subscriptions can have regional quota and SKU restrictions.

## Deployment Operation Checks

```powershell
az deployment operation sub list `
  --name "<deployment-name>" `
  --query "[].{state:properties.provisioningState,target:properties.targetResource.resourceName}" `
  -o table
```

For VM Run Command failures, inspect the instance view. A resource operation can be reported as `Succeeded` while the guest command has failed; the guest `executionState` and `exitCode` are authoritative for script execution.

[Back to README](../README.md)
