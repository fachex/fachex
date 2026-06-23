#!/usr/bin/env bash
# Install SOGo v5 + PostgreSQL + memcached inside a Debian 12 LXC.
# Run as root INSIDE the SOGo container.
#
# Expects the config template at /root/sogo.conf.tmpl (pushed alongside this).
set -euo pipefail

PG_SOGO_PASS="${PG_SOGO_PASS:-$(openssl rand -base64 24 | tr -d '/+=' )}"
TZ_NAME="${TZ_NAME:-America/Guayaquil}"
TMPL="${TMPL:-/root/sogo.conf.tmpl}"

echo ">> [1/6] Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y gnupg2 ca-certificates wget apt-transport-https openssl \
                   postgresql memcached

echo ">> [2/6] SOGo v5 repository (Debian 12 / bookworm)"
# NOTE: verify the key fingerprint + repo URL against the current SOGo install
# docs (https://www.sogo.nu/support.html#/docs) — they change occasionally.
wget -qO- "https://keys.openpgp.org/vks/v1/by-fingerprint/74FFC6D72B925A34B5D356BDF8A27B36A6E2EAE9" \
  | gpg --dearmor | tee /usr/share/keyrings/sogo-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/sogo-archive-keyring.gpg] http://packages.sogo.nu/nightly/5/debian/ bookworm bookworm" \
  > /etc/apt/sources.list.d/sogo.list

echo ">> [3/6] Install SOGo + PostgreSQL backend"
apt-get update
apt-get install -y sogo sope4.9-gdl1-postgresql

echo ">> [4/6] PostgreSQL role + database for SOGo's own store"
# Use runuser (always present) rather than sudo (absent on minimal LXC templates).
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='sogo'" | grep -q 1; then
  runuser -u postgres -- psql -c "CREATE USER sogo WITH PASSWORD '${PG_SOGO_PASS}';"
fi
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='sogo'" | grep -q 1; then
  runuser -u postgres -- psql -c "CREATE DATABASE sogo OWNER sogo;"
fi

echo ">> [5/6] Render /etc/sogo/sogo.conf"
[ -f "${TMPL}" ] || { echo "ERROR: template ${TMPL} missing"; exit 1; }
install -d -o sogo -g sogo /etc/sogo
sed -e "s|__PG_PASS__|${PG_SOGO_PASS}|g" -e "s|__TZ__|${TZ_NAME}|g" "${TMPL}" \
  > /etc/sogo/sogo.conf
chown sogo:sogo /etc/sogo/sogo.conf
chmod 640 /etc/sogo/sogo.conf
# Worker processes
sed -i 's/^PREFORK=.*/PREFORK=5/' /etc/default/sogo 2>/dev/null || true

echo ">> [6/6] Enable services"
systemctl enable --now memcached
systemctl restart sogo
systemctl enable sogo

cat <<EOF

============================================================
SOGo installed.
  Web (direct):     http://$(hostname -I | awk '{print $1}'):20000/SOGo
  PostgreSQL 'sogo' password:  ${PG_SOGO_PASS}
    (already written into /etc/sogo/sogo.conf)

STILL TO FILL IN /etc/sogo/sogo.conf:
  1. SOGoIMAPServer/SOGoSMTPServer/SOGoSieveServer -> set MAILHOST to your
     Hestia server's hostname/IP (Phase 2).
  2. SOGoUserSources bindPassword -> the svc-mail AD account password (Phase 3).
After edits:  systemctl restart sogo

THEN: put it behind nginx as email.opennube.net  (docs/email-vhost-setup.md)
============================================================
EOF
