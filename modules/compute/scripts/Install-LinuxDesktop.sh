#!/bin/bash

# ============================================================================
# LINUX DESKTOP INSTALLATION SCRIPT
# Installs a GUI desktop environment and RDP access on Linux client VMs.
# Also configures Polkit so the AD-based Linux administrators group receives
# interactive authorization for desktop actions.
# ============================================================================

set -euo pipefail

echo "[INFO] Installing Ubuntu desktop"

export DEBIAN_FRONTEND=noninteractive

#
# Phase 1 - Package installation
# ubuntu-desktop-minimal: Lightweight GNOME desktop environment.
# xrdp: RDP server exposing the desktop session to jumpboxes.
# jq: Required below to parse the directory model JSON.
#

apt-get update

apt-get install -y \
    jq \
    ubuntu-desktop-minimal \
    xrdp

#
# Phase 2 - Resolve Linux administrators group
# Extract Linux admins group name from directory model JSON.
# Constructs AGDLP group name: {globalSecurityPrefix}_{linuxAdmins group name}, lower-cased to
# match Polkit's case-sensitive Identity= group lookup.
#

DOMAIN_NAME="${DomainName}"
DIRECTORY_MODEL="${DirectoryModel}"

LINUX_ADMINS_GROUP=$(echo "${DIRECTORY_MODEL}" | jq -r '
  .groupNaming.globalSecurityPrefix +
  "_" +
  .platformAdminGroups.linuxAdmins
' | tr '[:upper:]' '[:lower:]')

echo "[INFO] Linux administrators group = ${LINUX_ADMINS_GROUP}"

if [[ -z "${LINUX_ADMINS_GROUP}" || "${LINUX_ADMINS_GROUP}" == "null" ]]; then
    echo "[ERROR] Unable to determine Linux administrators group"
    exit 1
fi

#
# Phase 3 - Enable RDP service
#

systemctl enable xrdp
systemctl start xrdp

echo "[INFO] Ubuntu desktop installation completed"

#
# Phase 4 - Polkit configuration
# Grants the Linux administrators group interactive authorization for all desktop actions
# (ResultActive=yes), matching the sudo rights configured during domain join.
#

echo "[INFO] Configuring Polkit for Linux administrators"

mkdir -p /etc/polkit-1/localauthority/50-local.d

cat >/etc/polkit-1/localauthority/50-local.d/amrl-admins.pkla <<EOF
[AMRL Linux Admins]
Identity=unix-group:${LINUX_ADMINS_GROUP}@${DOMAIN_NAME}
Action=*
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF

systemctl restart polkit

echo "[INFO] Polkit configuration completed"