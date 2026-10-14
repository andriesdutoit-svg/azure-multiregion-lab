#!/bin/bash

# ============================================================================
# LINUX DESKTOP INSTALLATION SCRIPT
# Installs a GUI desktop environment and RDP access on Linux client VMs.
# Also configures Polkit so the AD-based Linux administrators group receives
# authorization for desktop actions in the declared active/inactive/other contexts.
# Inputs DomainName and DirectoryModel are supplied by VM Run Command; run with
# package/service configuration permissions on an Ubuntu client. Identity-stage
# completes this desktop prerequisite before domain-join commands run.
# Reruns reapply package installation, service enablement, and the managed Polkit file;
# this script does not join the domain, create AD groups, or change network exposure.
# ============================================================================

set -euo pipefail

echo "[Info] Installing Ubuntu desktop packages."

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

echo "[Info] Linux administrators group was resolved for Polkit configuration."

if [[ -z "${LINUX_ADMINS_GROUP}" || "${LINUX_ADMINS_GROUP}" == "null" ]]; then
    echo "[Error] Unable to determine the Linux administrators group."
    exit 1
fi

#
# Phase 3 - Enable RDP service
#

systemctl enable xrdp
systemctl start xrdp

echo "[Info] Ubuntu desktop packages installed."

#
# Phase 4 - Polkit configuration
# Grants the modeled Linux administrators group all actions for ResultAny, ResultInactive,
# and ResultActive. This is broad lab authorization, separate from the sudoers policy
# configured during domain join; the heredoc is the managed policy payload, not commentary.
#

echo "[Info] Configuring Polkit for Linux administrators."

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

echo "[Info] Polkit configuration command completed."
echo "[Info] Desktop, RDP, and Polkit setup completed."