#!/bin/bash

# ============================================================================
# LINUX DOMAIN JOIN SCRIPT
# Joins Linux VMs to Active Directory domain using realmd/SSSD integration.
# Idempotent: script checks for existing domain membership and skips only the
# join-specific work while retaining the configuration healing steps.
# ============================================================================

set -euo pipefail

DOMAIN_NAME="${DomainName}"
DIRECTORY_MODEL="${DirectoryModel}"
# Extract Linux admins group name from directory model JSON.
# Constructs AGDLP group name: {globalSecurityPrefix}_{linuxAdmins group name}.
# Example: From model {groupNaming: {globalSecurityPrefix: "AMRL"}, platformAdminGroups: {linuxAdmins: "LinuxAdmins"}}
#   → produces group name "AMRL_LinuxAdmins" for sudoers configuration.
LINUX_ADMINS_GROUP=""
VM_TYPE="${VmType}"

SERVER_ADMIN_USERNAME="${ServerAdminUsername}"
SERVER_ADMIN_PASSWORD="${ServerAdminPassword}"
RECONCILIATION_TOKEN="${ReconciliationToken}"

log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $1"
}

log_info "Starting AMRL Linux Domain Join"

#
# Phase 1 - Validation
#

if [[ -z "${DOMAIN_NAME}" ]]; then
    log_error "DomainName was not supplied"
    exit 1
fi

if [[ -z "${SERVER_ADMIN_USERNAME}" ]]; then
    log_error "ServerAdminUsername was not supplied"
    exit 1
fi

if [[ -z "${SERVER_ADMIN_PASSWORD}" ]]; then
    log_error "ServerAdminPassword was not supplied"
    exit 1
fi

log_info "Input validation completed successfully"

#
# Phase 2 - Idempotency check: already joined?
# Realm list output includes domain-name field only for joined domains.
# The result controls package installation, discovery, and join behavior below.
#

ALREADY_JOINED=false

if command -v realm >/dev/null 2>&1 && realm list | grep -qi "domain-name:[[:space:]]*${DOMAIN_NAME}$"; then
    log_info "Computer is already joined to ${DOMAIN_NAME}"
    ALREADY_JOINED=true
fi

#
# Phase 3 - Install prerequisites when the VM still needs to join or heal
#
# Already joined VMs skip package installation, but continue through the
# configuration and validation phases below so incomplete setup can heal.
#

if [[ "${ALREADY_JOINED}" == "false" ]] || ! command -v realm >/dev/null 2>&1; then
    log_info "Installing domain join prerequisites"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        realmd \
        sssd \
        sssd-tools \
        adcli \
        krb5-user \
        packagekit \
        oddjob \
        oddjob-mkhomedir \
        samba-common-bin \
        bind9-dnsutils \
        jq

    log_info "Prerequisite installation completed"
else
    log_info "Skipping prerequisite installation because the computer is already joined"
fi

COMPUTER_OU=$(echo "${DIRECTORY_MODEL}" | jq -r \
    ".computerOuMapping.${VM_TYPE}")

if [[ -z "${COMPUTER_OU}" || "${COMPUTER_OU}" == "null" ]]; then
    log_error "No OU mapping defined for VM type: ${VM_TYPE}"
    exit 1
fi

COMPUTER_OU_DN=$(echo "${COMPUTER_OU}" | awk -F'/' '
{
    for (i=NF; i>=1; i--) {
        printf "OU=%s", $i

        if (i > 1) {
            printf ","
        }
    }
}')

ROOT_OU_NAME=$(echo "${DIRECTORY_MODEL}" | jq -r \
    '.rootOuName')

DOMAIN_DN=$(echo "${DOMAIN_NAME}" | awk -F'.' '
{
    for (i=1; i<=NF; i++) {
        printf "DC=%s", $i

        if (i < NF) {
            printf ","
        }
    }
}')

FULL_COMPUTER_OU_DN="${COMPUTER_OU_DN},OU=${ROOT_OU_NAME},${DOMAIN_DN}"

log_info "Computer OU = ${COMPUTER_OU}"
log_info "Computer OU DN = ${COMPUTER_OU_DN}"
log_info "Full Computer OU DN = ${FULL_COMPUTER_OU_DN}"

LINUX_ADMINS_GROUP=$(echo "${DIRECTORY_MODEL}" | jq -r '
  .groupNaming.globalSecurityPrefix +
  "_" +
  .platformAdminGroups.linuxAdmins
')

if [[ -z "${LINUX_ADMINS_GROUP}" || "${LINUX_ADMINS_GROUP}" == "null" ]]; then
    log_error "Unable to determine Linux administrators group from directory model"
    exit 1
fi

log_info "Linux administrators group = ${LINUX_ADMINS_GROUP}"

#
# Phase 4 - DNS and domain validation
#

if [[ "${ALREADY_JOINED}" == "false" ]]; then
    log_info "Validating DNS and discovering domain"

    realm discover "${DOMAIN_NAME}"

    log_info "DNS and domain validation completed"
else
    log_info "Skipping DNS and domain discovery because the computer is already joined"
fi

#
# Phase 5 - Domain join
#

if [[ "${ALREADY_JOINED}" == "false" ]]; then

    log_info "realm join OU = ${FULL_COMPUTER_OU_DN}"

    echo "${SERVER_ADMIN_PASSWORD}" | realm join --verbose \
        "${DOMAIN_NAME}" \
        --user="${SERVER_ADMIN_USERNAME}" \
        --computer-ou="${FULL_COMPUTER_OU_DN}"

    log_info "Domain join completed"

else

    log_info "Skipping domain join because the computer is already joined"

fi

#
# Phase 6 - SSSD configuration
# SSSD (System Security Services Daemon) authenticates users and enforces group membership.
# ad_gpo_access_control = permissive: Allows login by any domain user; GPO restrictions not enforced at login.
# Sudo rights are instead enforced via sudoers file entries using AGDLP groups (see Phase 8).
#

log_info "Configuring SSSD"

if ! grep -q "^ad_gpo_access_control = permissive" /etc/sssd/sssd.conf; then
    cat >> /etc/sssd/sssd.conf <<EOF

ad_gpo_access_control = permissive
EOF
fi

chmod 600 /etc/sssd/sssd.conf

systemctl enable sssd
systemctl restart sssd

log_info "SSSD configured"

log_info "Configuring automatic home directory creation"

pam-auth-update --enable mkhomedir

log_info "Home directory creation configured"

#
# Phase 7 - Access configuration
# realm permit --all: Allows login for any domain user (permissive access model).
# Sudo rights are controlled by AGDLP group membership configured in sudoers file.
# %{LINUX_ADMINS_GROUP}@{DOMAIN_NAME}: Sudoers entry grants sudo to domain-based AGDLP group.
# Example: %AMRL_LinuxAdmins@amrl.local ALL=(ALL:ALL) ALL → domain admins can sudo without password.
#

realm permit --all

log_info "Configuring Linux administrator sudo rights"

if cat >/etc/sudoers.d/linux-admins <<EOF
%${LINUX_ADMINS_GROUP}@${DOMAIN_NAME} ALL=(ALL:ALL) ALL
EOF
then
    chmod 440 /etc/sudoers.d/linux-admins

    if visudo -cf /etc/sudoers.d/linux-admins; then
        log_info "Linux administrator sudo rights configured"
    else
        log_warn "Invalid sudoers configuration detected"
    fi
else
    log_warn "Failed to configure Linux administrator sudo rights"
fi

#
# Phase 8 - Validation
#

log_info "Validating domain membership"

realm list

log_info "Linux domain join completed successfully"