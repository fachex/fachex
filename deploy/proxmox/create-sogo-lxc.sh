#!/usr/bin/env bash
# Create the SOGo LXC on a Proxmox node.
# Run this ON a Proxmox host (not inside a container).
#
# Edit the vars below, then: bash create-sogo-lxc.sh
set -euo pipefail

# --- Edit these ---------------------------------------------------------------
CTID="${CTID:-150}"                       # unused container ID
HOSTNAME_="${HOSTNAME_:-sogo}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"                   # MB
SWAP="${SWAP:-1024}"                       # MB
DISK_GB="${DISK_GB:-20}"
STORAGE="${STORAGE:-local-lvm}"            # rootfs storage
TEMPLATE_STORE="${TEMPLATE_STORE:-local}"  # where templates live
BRIDGE="${BRIDGE:-vmbr0}"
IP_CIDR="${IP_CIDR:-10.0.0.50/24}"         # SOGo LXC LAN IP
GATEWAY="${GATEWAY:-10.0.0.1}"
# ------------------------------------------------------------------------------

TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"   # verify exact name below

echo ">> Ensuring Debian 12 template is present"
pveam update || true
if ! pveam list "${TEMPLATE_STORE}" | grep -q "${TEMPLATE}"; then
  echo "   Template not found locally. Available Debian 12 templates:"
  pveam available | grep 'debian-12-standard' || true
  echo "   Downloading ${TEMPLATE} ..."
  pveam download "${TEMPLATE_STORE}" "${TEMPLATE}"
fi

echo ">> Creating LXC ${CTID} (${HOSTNAME_})"
pct create "${CTID}" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
  --hostname "${HOSTNAME_}" \
  --cores "${CORES}" --memory "${MEMORY}" --swap "${SWAP}" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}" \
  --unprivileged 1 --features nesting=1 \
  --onboot 1 --start 1

echo ">> Waiting for container to boot"
sleep 8

echo
echo ">> LXC ${CTID} up at ${IP_CIDR%/*}"
echo ">> Next:"
echo "   pct push ${CTID} deploy/sogo/install-sogo.sh /root/install-sogo.sh"
echo "   pct push ${CTID} deploy/sogo/sogo.conf       /root/sogo.conf.tmpl"
echo "   pct exec ${CTID} -- bash /root/install-sogo.sh"
