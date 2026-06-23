#!/usr/bin/env bash
# Create the SOGo LXC on a Proxmox node.
# Run this ON a Proxmox host (not inside a container).
#
# Edit the vars below, then: bash create-sogo-lxc.sh
set -euo pipefail

# --- Edit these (defaults match the live opennube container, CTID 902) --------
CTID="${CTID:-902}"                        # unused container ID
HOSTNAME_="${HOSTNAME_:-sogo}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"                    # MB
SWAP="${SWAP:-1024}"                        # MB
DISK_GB="${DISK_GB:-20}"
STORAGE="${STORAGE:-local}"                 # rootfs storage
TEMPLATE_STORE="${TEMPLATE_STORE:-local}"   # where templates live
BRIDGE="${BRIDGE:-vmbr1}"
IP_CIDR="${IP_CIDR:-172.17.17.99/24}"       # SOGo LXC IP (note: /24 must match GATEWAY's subnet)
GATEWAY="${GATEWAY:-172.17.17.1}"
VLAN_TAG="${VLAN_TAG:-12}"                   # VLAN 12: mgmt / AD-DC / nginx
NAMESERVER="${NAMESERVER:-10.11.12.240}"
SEARCHDOMAIN="${SEARCHDOMAIN:-opennube.local}"
TAGS="${TAGS:-opennube}"

# Second NIC on VLAN 5 to reach Hestia (192.168.91.0/24). GATEWAY-LESS on purpose:
# the default route stays on eth0/VLAN12; eth1 only needs same-subnet L2 to Hestia.
# Leave NET1_IP_CIDR empty to skip the second NIC.
NET1_BRIDGE="${NET1_BRIDGE:-vmbr1}"
NET1_VLAN_TAG="${NET1_VLAN_TAG:-5}"
NET1_IP_CIDR="${NET1_IP_CIDR:-192.168.91.99/24}"
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
  --net0 "name=eth0,bridge=${BRIDGE},tag=${VLAN_TAG},firewall=1,ip=${IP_CIDR},gw=${GATEWAY}" \
  --nameserver "${NAMESERVER}" --searchdomain "${SEARCHDOMAIN}" \
  --tags "${TAGS}" \
  --unprivileged 1 --features nesting=1 \
  --onboot 1 --start 1

# Second NIC on VLAN 5 (to Hestia) — gateway-less by design
if [ -n "${NET1_IP_CIDR}" ]; then
  echo ">> Adding eth1 on VLAN ${NET1_VLAN_TAG} (${NET1_IP_CIDR}) -> Hestia"
  pct set "${CTID}" -net1 "name=eth1,bridge=${NET1_BRIDGE},tag=${NET1_VLAN_TAG},firewall=1,ip=${NET1_IP_CIDR}"
fi

echo ">> Waiting for container to boot"
sleep 8

echo
echo ">> LXC ${CTID} up at ${IP_CIDR%/*}"
echo ">> Next:"
echo "   pct push ${CTID} deploy/sogo/install-sogo.sh /root/install-sogo.sh"
echo "   pct push ${CTID} deploy/sogo/sogo.conf       /root/sogo.conf.tmpl"
echo "   pct exec ${CTID} -- bash /root/install-sogo.sh"
