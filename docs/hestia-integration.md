# Phase 2 — Connect SOGo to Hestia (mail backend)

Wire the SOGo container (902) to Hestia's Dovecot/Exim so it can read/send mail
and save Sieve rules. Hestia stays the mailbox manager; SOGo is the front end.

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
pct exec 902 -- ping -c1 <HESTIA_IP>
pct exec 902 -- bash -c 'for p in 993 587 4190; do nc -zv <HESTIA_IP> $p; done'
```

## TLS: connect by cert name, route to the private IP

Hestia has **valid certs**, so make SOGo connect using the cert's hostname (TLS
verification passes) while routing to Hestia's private VLAN 5 IP. Pin it in the
container's hosts file:

```bash
# inside 902
echo "<HESTIA_IP>   <MAIL_FQDN>" >> /etc/hosts     # e.g. 192.168.91.10  mail.opennube.net
```

Confirm the cert's CN/SAN (run on Hestia):
```bash
openssl s_client -connect localhost:993 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
```

## Point SOGo at Hestia

Set `MAILHOST` in `/etc/sogo/sogo.conf` to `<MAIL_FQDN>`:

```bash
# inside 902
sed -i 's|MAILHOST|<MAIL_FQDN>|g' /etc/sogo/sogo.conf
systemctl restart sogo
```

Resulting endpoints (already in the template):
```
SOGoIMAPServer  = "imaps://<MAIL_FQDN>:993";   # implicit TLS
SOGoSMTPServer  = "smtp://<MAIL_FQDN>:587";    # submission + STARTTLS
SOGoSieveServer = "sieve://<MAIL_FQDN>:4190";  # managesieve + STARTTLS
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

## Test (before AD)

Use an **existing Hestia mailbox** with its local Hestia password (AD auth comes
in Phase 3):

1. Browse to SOGo (direct `http://172.17.17.99:20000/SOGo`, or via
   `email.opennube.net` once nginx is up).
2. Log in as `someuser@opennube.net` + its Hestia password.
3. Confirm: folders load, send a test mail, receive a test mail.
4. Settings → Mail → Filters: create+save a test filter (proves managesieve).

Green on all four = SOGo↔Hestia is wired. Next: `docs/email-vhost-setup.md`
(nginx front door) and Phase 3 AD auth in `docs/deployment.md`.

## Values to fill

| Placeholder | Meaning |
|---|---|
| `<HESTIA_IP>` | Hestia's IP on VLAN 5 (`192.168.91.?`) |
| `<MAIL_FQDN>` | Hostname Hestia's mail cert is issued for (e.g. `mail.opennube.net`) |
