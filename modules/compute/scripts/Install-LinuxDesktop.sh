#!/bin/bash

DOMAIN_NAME="${DomainName}"
DIRECTORY_MODEL="${DirectoryModel}"

LINUX_ADMINS_GROUP=$(echo "${DIRECTORY_MODEL}" | jq -r '
  .groupNaming.globalSecurityPrefix +
  "_" +
  .platformAdminGroups.linuxAdmins
')

if [[ -z "${LINUX_ADMINS_GROUP}" || "${LINUX_ADMINS_GROUP}" == "null" ]]; then
    echo "[ERROR] Unable to determine Linux administrators group"
    exit 1
fi

set -euo pipefail

echo "[INFO] Installing Ubuntu desktop"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    ubuntu-desktop-minimal \
    xrdp

systemctl enable xrdp
systemctl start xrdp

echo "[INFO] Ubuntu desktop installation completed"

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