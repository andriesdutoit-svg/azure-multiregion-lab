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

    # Ubuntu repository HTTP responses are rejected on the controlled egress path.
    find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec \
        sed -i -E 's#http://(archive|security)\.ubuntu\.com/ubuntu#https://\1.ubuntu.com/ubuntu#g' {} +

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

# Resolve the OU from the directory model for a new join; joined machines still continue through repair below.
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
# Phase 6 - SSSD configuration, hostname, and dynamic DNS
# SSSD (System Security Services Daemon) authenticates users and enforces group membership.
# ad_gpo_access_control = permissive: Allows login by any domain user; GPO restrictions not enforced at login.
# Sudo rights are instead enforced via sudoers file entries using AGDLP groups (see Phase 8).
# Hostname is set to FQDN and adcli triggers an immediate DNS registration alongside SSSD's dyndns settings.
#

log_info "Configuring SSSD"

SSSD_CONFIG="/etc/sssd/sssd.conf"

SSSD_UPDATED=false

declare -A DESIRED_SSSD_SETTINGS=(
    ["ad_gpo_access_control"]="permissive"
    ["dyndns_update"]="True"
    ["dyndns_refresh_interval"]="43200"
    ["dyndns_update_ptr"]="True"
)

# Reconcile only these managed keys and preserve unrelated sssd.conf settings.
for SETTING in "${!DESIRED_SSSD_SETTINGS[@]}"; do

    DESIRED_VALUE="${DESIRED_SSSD_SETTINGS[$SETTING]}"

    if grep -q "^${SETTING}[[:space:]]*=" "${SSSD_CONFIG}"; then

        CURRENT_VALUE=$(grep "^${SETTING}[[:space:]]*=" "${SSSD_CONFIG}" |
            head -n1 |
            cut -d'=' -f2- |
            xargs)

        if [[ "${CURRENT_VALUE}" != "${DESIRED_VALUE}" ]]; then

            sed -i \
                "s|^${SETTING}[[:space:]]*=.*|${SETTING} = ${DESIRED_VALUE}|" \
                "${SSSD_CONFIG}"

            SSSD_UPDATED=true

        fi

    else

        printf '\n%s = %s\n' \
            "${SETTING}" \
            "${DESIRED_VALUE}" \
            >> "${SSSD_CONFIG}"

        SSSD_UPDATED=true

    fi

done

if [[ "${SSSD_UPDATED}" == "true" ]]; then

    log_info "[Updated] SSSD configuration"

else

    log_info "[Verified] SSSD configuration"

fi

log_info "Configuring Linux hostname"

# SSSD dynamic DNS registers under the short hostname's domain suffix, so the OS hostname must be the FQDN.
CURRENT_HOSTNAME=$(hostname)

if [[ "${CURRENT_HOSTNAME}" != *".${DOMAIN_NAME}" ]]; then
    hostnamectl set-hostname "${CURRENT_HOSTNAME}.${DOMAIN_NAME}"
fi

log_info "Hostname configured as $(hostname)"

chmod 600 /etc/sssd/sssd.conf

systemctl enable sssd

if [[ "${SSSD_UPDATED}" == "true" ]]; then

    # Restart only after a managed SSSD setting changes.
    systemctl restart sssd

    log_info "[Updated] SSSD service restarted"

else

    log_info "[Verified] SSSD service restart not required"

fi

log_info "SSSD configured"

log_info "Triggering dynamic DNS update"

# Forces an immediate DNS registration instead of waiting for SSSD's next dyndns_refresh_interval.
adcli update --verbose || log_warn "Dynamic DNS update failed"

log_info "Dynamic DNS update triggered"

log_info "Configuring automatic home directory creation"

DESIRED_MKHOMEDIR_ENTRY="session       optional                        pam_mkhomedir.so umask=0027"

# Enable automatic home creation only if the required PAM session entry is absent, then verify it.
if grep -Fq "${DESIRED_MKHOMEDIR_ENTRY}" /etc/pam.d/common-session; then

    log_info "[Verified] Automatic home directory creation"

else

    pam-auth-update --enable mkhomedir

    if grep -Fq "${DESIRED_MKHOMEDIR_ENTRY}" /etc/pam.d/common-session; then

        log_info "[Updated] Automatic home directory creation"

    else

        log_error "Failed to configure automatic home directory creation"
        exit 1

    fi

fi

#
# Phase 7 - Access configuration
# Realm login is intentionally permissive for domain users; administrative sudo remains restricted by the AGDLP sudoers entry below.
# The sudoers principal uses the Linux administrators group and domain in %GROUP@DOMAIN form.
#

CURRENT_LOGIN_POLICY=$(realm list | awk -F': ' '
/login-policy/ {
    print $2
}')

if [[ "${CURRENT_LOGIN_POLICY}" == "allow-realm-logins" ]]; then

    log_info "[Verified] Realm login policy"

else

    realm permit --all

    UPDATED_LOGIN_POLICY=$(realm list | awk -F': ' '
/login-policy/ {
    print $2
}')

    if [[ "${UPDATED_LOGIN_POLICY}" == "allow-realm-logins" ]]; then

        log_info "[Updated] Realm login policy"

    else

        log_error "Failed to configure realm login policy"
        exit 1

    fi

fi

log_info "Configuring Linux administrator sudo rights"

SUDOERS_PATH="/etc/sudoers.d/linux-admins"

DESIRED_SUDOERS_CONTENT="%${LINUX_ADMINS_GROUP}@${DOMAIN_NAME} ALL=(ALL:ALL) ALL"

# Replace sudoers only when its desired rule differs; validate the file before accepting the change.
CURRENT_SUDOERS_CONTENT=""

if [[ -f "${SUDOERS_PATH}" ]]; then

    CURRENT_SUDOERS_CONTENT=$(cat "${SUDOERS_PATH}")

fi

if [[ "${CURRENT_SUDOERS_CONTENT}" == "${DESIRED_SUDOERS_CONTENT}" ]]; then

    log_info "[Verified] Linux administrator sudo policy"

else

    cat >"${SUDOERS_PATH}" <<EOF
${DESIRED_SUDOERS_CONTENT}
EOF

    chmod 440 "${SUDOERS_PATH}"

    if visudo -cf "${SUDOERS_PATH}"; then

        log_info "[Updated] Linux administrator sudo policy"

    else

        log_warn "Invalid sudoers configuration detected"
        exit 1

    fi

fi

#
# Phase 8 - Validation
#

log_info "Validating domain membership"

realm list

log_info "Linux domain join completed successfully"