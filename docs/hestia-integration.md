# Phase 2 — Connect SOGo to Hestia (mail backend)

Wire the SOGo container (902) to Hestia's Dovecot/Exim so it can read/send mail
and save Sieve rules. Hestia stays the mailbox manager; SOGo is the front end.

> Discovered values for opennube: Hestia VLAN 5 IP = **192.168.91.24**, mail FQDN
> = **mail.opennube.net** (internal DNS already resolves the FQDN to the private
> IP, so the `/etc/hosts` pin below is optional — keep it only as a fallback).
> As of first test, **993 and 587 are open but 4190 is not** — managesieve must
> be enabled on Hestia (below).

## Network: dual-home the container

SOGo (CT 902) lives on **VLAN 12** (`172.17.17.99/24`, default gateway, reaches
AD/DC + nginx). Hestia lives on **VLAN 5** (`192.168.91.0/24`). Give 902 a
second, **gateway-less** NIC on VLAN 5 for direct L2 access to Hestia:

```
                  ┌─ eth0  VLAN 12  172.17.17.99/24   → AD/DC, nginx (default gw)
   CT 902 (SOGo) ─┤
                  └─ eth1  VLAN 5   192.168.91.99/24  → Hestia (NO gateway)
```

```bash
# on node09 — confirm vmbr1 trunks VLAN 5; pick a FREE .91 IP
pct set 902 -net1 name=eth1,bridge=vmbr1,tag=5,firewall=1,ip=192.168.91.99/24
pct reboot 902
```

> Only `eth0` has a gateway. `eth1` reaches Hestia as same-subnet L2, so it needs
> no gateway — and a second default route would cause asymmetric routing.

### Verify reachability

```bash
pct exec 902 -- ip -4 addr show eth1                  # expect 192.168.91.99
pct exec 902 -- apt-get install -y netcat-openbsd
pct exec 902 -- ping -c1 192.168.91.24
pct exec 902 -- bash -c 'for p in 993 587 4190; do nc -zv 192.168.91.24 $p; done'
```

## TLS: connect by cert name, route to the private IP

Hestia has **valid certs**, so make SOGo connect using the cert's hostname (TLS
verification passes) while routing to Hestia's private VLAN 5 IP. Pin it in the
container's hosts file:

```bash
# inside 902
echo "192.168.91.24   mail.opennube.net" >> /etc/hosts     # e.g. 192.168.91.10  mail.opennube.net
```

Confirm the cert's CN/SAN (run on Hestia):
```bash
openssl s_client -connect localhost:993 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
```

## Point SOGo at Hestia

Set `MAILHOST` in `/etc/sogo/sogo.conf` to `mail.opennube.net`:

```bash
# inside 902
sed -i 's|MAILHOST|mail.opennube.net|g' /etc/sogo/sogo.conf
systemctl restart sogo
```

Resulting endpoints (already in the template):
```
SOGoIMAPServer  = "imaps://mail.opennube.net:993";   # implicit TLS
SOGoSMTPServer  = "smtp://mail.opennube.net:587";    # submission + STARTTLS
SOGoSieveServer = "sieve://mail.opennube.net:4190";  # managesieve + STARTTLS
```

## Hestia side

### 1. Enable managesieve (so SOGo's Rules UI works)

Ensure Pigeonhole + managesieve are present and listening on 4190:

```bash
# on Hestia
apt-get install -y dovecot-sieve dovecot-managesieved      # if not already
```
`/etc/dovecot/conf.d/20-managesieve.conf`:
```
protocols = $protocols sieve
service managesieve-login {
  inet_listener sieve { port = 4190 }
}
```
Confirm `sieve` is in the `mail_plugins` for lmtp/lda, then:
```bash
systemctl restart dovecot
```

### 2. Allow the SOGo NIC through Hestia's firewall

Permit only 902's VLAN 5 address to the mail ports:

```bash
# on Hestia (HestiaCP firewall)
v-add-firewall-rule ACCEPT 192.168.91.99 993,587,4190 TCP "SOGo (CT902) to mail"
```

## Test the backend (decoupled from SOGo login)

> **Why not just log into SOGo yet?** The shipped `sogo.conf` has the AD LDAP
> source with a placeholder `bindPassword`. Until that bind works (Phase 3),
> SOGo has no usable auth source, so the web login will fail regardless of the
> mail backend. So first prove the Hestia mail path *independently* of SOGo:

```bash
# inside 902 — verify TLS cert name matches and IMAP answers
openssl s_client -connect mail.opennube.net:993 -servername mail.opennube.net \
  </dev/null 2>/dev/null | openssl x509 -noout -subject -dates -ext subjectAltName

# verify a real mailbox can authenticate over IMAPS (use a test Hestia account)
openssl s_client -crlf -connect mail.opennube.net:993 -servername mail.opennube.net
#   a LOGIN test@opennube.net 'the-hestia-password'
#   a LIST "" "*"
#   a LOGOUT
```

If the cert subject/SAN includes `mail.opennube.net` and the IMAP `LOGIN`
returns `a OK`, the SOGo→Hestia path is good. The end-to-end **SOGo web login**
test happens in Phase 3 once AD auth is wired, using an AD user whose
`opennube.net` mailbox exists in Hestia.

Next: `docs/email-vhost-setup.md` (nginx front door, which also fixes the
unstyled `:20000` page) and Phase 3 AD auth in `docs/deployment.md`.

## Values to fill

| Placeholder | Meaning |
|---|---|
| `192.168.91.24` | Hestia's IP on VLAN 5 (`192.168.91.?`) |
| `mail.opennube.net` | Hostname Hestia's mail cert is issued for (e.g. `mail.opennube.net`) |
