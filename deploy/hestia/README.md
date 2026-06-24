# Hestia Dovecot — AD passdb (Phase 3, WORKING)

Lets opennube AD users authenticate to their Hestia mailboxes with their live AD
password — no password syncing. Clients keep using their Hestia passwords.

## Prereqs (done for opennube)
- Hestia dual-homed onto VLAN 12 (gateway-less NIC `ens19` 172.17.17.98/24) so
  Dovecot can reach the DC (172.17.17.100:636). See netplan `60-vlan12.yaml`.
- `/etc/hosts`: `172.17.17.100 ONAD1.opennube.local`
- AD CA trusted: fetch `cACertificate` via LDAP →
  `/usr/local/share/ca-certificates/opennube-ad-ca.crt` → `update-ca-certificates`
- `NEEDRESTART_MODE=l apt-get install -y dovecot-ldap`  (the =l avoids the
  needrestart auto-bounce that took MariaDB down once)

## Files
- `dovecot-ldap-ad.conf.ext` → `/etc/dovecot/dovecot-ldap-ad.conf.ext` (chmod 600, set dnpass)
- `05-auth-ldap-ad.conf` → `/etc/dovecot/conf.d/05-auth-ldap-ad.conf`

## Apply
`doveconf -n` (confirm `driver = ldap` passdb appears BEFORE `driver = passwd-file`),
then `systemctl reload dovecot` (reload only — never a blanket restart).

## Verify
- `doveadm auth test fabian.lazarte@opennube.net`  → succeeds via ldap passdb
- `doveadm auth test someclient@clientdomain.com`  → still succeeds via passwd-file
- Set the Hestia mailbox password to random; SOGo login still works = AD is the authority.

## Multi-domain
Because `pass_filter` matches `sAMAccountName=%n` (the shared local part), the same
AD password authenticates every domain mailbox (`@opennube.net`, `@opennube.ai`, …).
In SOGo, additional domains are added as auxiliary accounts
(`SOGoMailAuxiliaryUserAccountsEnabled = YES`), username = full `<user>@<domain>`.
