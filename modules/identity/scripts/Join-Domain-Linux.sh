#!/bin/bash

set -euo pipefail

DOMAIN_NAME="${DomainName}"
DIRECTORY_MODEL="${DirectoryModel}"
VM_TYPE="${VmType}"
SERVER_ADMIN_USERNAME="${ServerAdminUsername}"
SERVER_ADMIN_PASSWORD="${ServerAdminPassword}"

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
# Phase 2 - Already joined check
#

if realm list | grep -qi "^domain-name: ${DOMAIN_NAME}$"; then
    log_info "Computer is already joined to ${DOMAIN_NAME}"
    exit 0
fi

#
# Phase 3 - Install prerequisites
#

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
    samba-common-bin

log_info "Prerequisite installation completed"

#
# Phase 4 - DNS validation
#

log_info "Validating DNS"

host "${DOMAIN_NAME}"

log_info "DNS validation completed"

#
# Phase 5 - Domain discovery
#

log_info "Discovering domain"

realm discover "${DOMAIN_NAME}"

log_info "Domain discovery completed"

#
# Phase 6 - Domain join
#

log_info "Joining domain"

echo "${SERVER_ADMIN_PASSWORD}" | realm join \
    "${DOMAIN_NAME}" \
    --user="${SERVER_ADMIN_USERNAME}"

log_info "Domain join completed"

#
# Phase 7 - SSSD configuration
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
# Phase 8 - Access configuration
#

realm permit --all

log_info "Configuring Linux administrator sudo rights"

if cat >/etc/sudoers.d/linux-admins <<EOF
%GGS_Linux_Admins@amrl.lab ALL=(ALL:ALL) ALL
EOF
then
    chmod 440 /etc/sudoers.d/linux-admins
    log_info "Linux administrator sudo rights configured"
else
    log_warn "Failed to configure Linux administrator sudo rights"
fi

#
# Phase 9 - Validation
#

log_info "Validating domain membership"

realm list

log_info "Linux domain join completed successfully"