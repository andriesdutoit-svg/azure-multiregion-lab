#!/bin/bash

set -euo pipefail

DOMAIN_NAME="$1"
DIRECTORY_MODEL="$2"
VM_TYPE="$3"
SERVER_ADMIN_USERNAME="$4"
SERVER_ADMIN_PASSWORD="$5"

echo "Starting AMRL Linux Domain Join"

echo "DomainName = ${DOMAIN_NAME}"
echo "VmType = ${VM_TYPE}"

if [[ -z "${SERVER_ADMIN_PASSWORD}" ]]; then
    echo "ServerAdminPassword was not supplied"
    exit 1
fi

if realm list | grep -qi "${DOMAIN_NAME}"; then
    echo "Computer is already joined to a domain."
    exit 0
fi

echo "Linux domain join script loaded successfully"