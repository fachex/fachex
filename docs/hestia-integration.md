# Phase 2 — Connect SOGo to Hestia (mail backend)

Wire the SOGo container (902) to Hestia's Dovecot/Exim so it can read/send mail
and save Sieve rules. Hestia stays the mailbox manager; SOGo is the front end.

> Discovered values for opennube: Hestia VLAN 5 IP = **192.168.91.14**, mail FQDN
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
pct exec 902 -- ping -c1 192.168.91.14
pct exec 902 -- bash -c 'for p in 993 587 4190; do nc -zv 192.168.91.14 $p; done'
```

## TLS: connect by cert name, route to the private IP

Hestia has **valid certs**, so make SOGo connect using the cert's hostname (TLS
verification passes) while routing to Hestia's private VLAN 5 IP. Pin it in the
container's hosts file:

```bash
# inside 902
echo "192.168.91.14   mail.opennube.net" >> /etc/hosts     # e.g. 192.168.91.10  mail.opennube.net
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

### 1. Enable managesieve (so SOGo's Rules UI works) — DEFERRED, OPTIONAL

> ⚠️ **Deferred on purpose.** managesieve only powers SOGo's server-side
> Rules/filters UI — mail, calendar, contacts and send/receive all work without
> it. On this VM, `apt-get install dovecot-managesieved` triggered Debian
> **`needrestart`**, which auto-restarted MariaDB; MariaDB failed to come back
> and **all `webmail.*` went down** until `systemctl start mariadb`. As of the
> last check, `ss -ltnp | grep 4190` shows **nothing listening**. So leave this
> for a planned maintenance window and use the Hestia-native path, with
> `needrestart` in list-only mode so no service is auto-bounced:
>
> ```bash
> # ALWAYS prefix installs on the Hestia VM:
> NEEDRESTART_MODE=l apt-get install -y dovecot-managesieved
> ```
> Then enable the `sieve` protocol + the `managesieve-login` inet listener (4190)
> via Hestia's own Dovecot template, not by hand-editing conf.d, and restart
> Dovecot only (`systemctl restart dovecot` — never a blanket restart).

Reference (for the maintenance window — do not apply live without the above):

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

> **Gotcha — check cert expiry, not just the name.** SOGo verifies TLS on
> `imaps://` and sends SNI (`mail.opennube.net`), so Dovecot serves the
> per-domain LE cert — an expired one blocks mail even though the name matches.
> (Connecting by IP without SNI returns Hestia's *default* cert
> `CN=site.opennube.com`, a red herring. Also note `192.168.91.24` is just a
> secondary IP on the same Hestia `ens18` NIC as `.14`.) The opennube mail cert
> had **expired** because Hestia's **WAN IP was misconfigured** (`51.222.33.178`
> vs `.182`), pointing the public A record and ACME http-01 target at the wrong
> IP → `connection refused`. **Resolved:** after correcting the WAN IP so
> `mail./webmail.opennube.net` resolve to `.182`, `v-update-letsencrypt-ssl`
> reissued the cert (valid through ~Sep 2026). If a private mail host ever can't
> use http-01, fall back to **DNS-01 via the OVH API**. Re-verify with
> `openssl s_client -connect 192.168.91.14:993 -servername mail.opennube.net
> </dev/null 2>/dev/null | openssl x509 -noout -dates`.

## Phase 2 status

**Done:** valid TLS (`mail.opennube.net`, renewed through ~Sep 2026), IMAP 993
and submission 587 reachable from CT 902 over VLAN 5. SOGo has everything it
needs to function.
**Deferred:** managesieve / port 4190 (Rules UI only) — see the warning above.

Next: `docs/email-vhost-setup.md` (nginx front door, which also fixes the
unstyled `:20000` page) and Phase 3 AD auth in `docs/deployment.md`.

## Values to fill

| Placeholder | Meaning |
|---|---|
| `192.168.91.14` | Hestia's IP on VLAN 5 (`192.168.91.?`) |
| `mail.opennube.net` | Hostname Hestia's mail cert is issued for (e.g. `mail.opennube.net`) |

## Phase 3 Part B — mailbox auth (verified findings)

Observed: SOGo sends the **bare** `sAMAccountName` (e.g. `fabian.lazarte`) to
Dovecot (`SOGoForceExternalLoginWithEmail = NO` → uses the UID). Hestia keys
mailboxes by full address, so a domainless login fails.

Mechanism (no consolidation; multi-domain via aggregation):
1. **`auth_default_realm = opennube.net`** drop-in (`/etc/dovecot/conf.d/99-opennube-sogo.conf`)
   → maps the bare login to the **primary** `@opennube.net` mailbox. Only affects
   logins without an `@`, so all existing full-address logins are unaffected.
   Apply with `doveconf -n` check + `systemctl reload dovecot` (no apt, no restart).
2. **Password**: Hestia's Dovecot has **no LDAP module** (`libauthdb_ldap.so` absent),
   so AD-password auth needs `dovecot-ldap` installed (carefully:
   `NEEDRESTART_MODE=l apt-get install dovecot-ldap`, then dovecot-only reload).
   The AD `passdb` uses `pass_filter = (sAMAccountName=%n)` — because every domain
   mailbox for a person shares the local part, the AD password then authenticates
   `@opennube.net`, `@opennube.ai`, `@myopennube.com` alike.
3. **Aggregation**: SOGo primary = `@opennube.net`; the other domains added as
   SOGo **auxiliary accounts** (`SOGoMailAuxiliaryUserAccountsEnabled = YES`),
   each authenticating with the same AD password via the passdb above. Prefer this
   over a shared Dovecot master user (which would expose shared creds in user
   profiles). The provisioning bridge can later pre-seed the auxiliary accounts.

Quick validation before the passdb: set the Hestia mailbox password equal to the
user's AD password (`v-change-mail-account-password`) so SOGo pass-through works.

### Part B status — primary mailbox WORKING

Verified end-to-end: AD login → SOGo → `auth_default_realm = opennube.net`
maps the bare `sAMAccountName` → Dovecot opens `fabian.lazarte@opennube.net`,
inbox loads. Log: `imap-login: Login: user=<fabian.lazarte@opennube.net>,
rip=192.168.91.99`.

Caveats / next:
- Currently relies on the Hestia mailbox password == the user's AD password
  (set manually). **Fragile** — replace with the AD `passdb` so Dovecot
  validates against AD live (no sync). This is the production step.
- From-identity still shows the AD `mail` attribute (`@opennube.com`, M365).
  Fix: stop SOGo using `mail` for the address so it derives `uid@opennube.net`
  (`MailFieldNames` → non-existent attr → fallback to `uid@SOGoMailDomain`).

### From-identity fixed

SOGo derived the user's From from the AD `mail` attribute (`@opennube.com`/M365).
Fix (container only): `MailFieldNames = ("mailLocalAddress")` (non-existent attr)
→ SOGo falls back to `uid@SOGoMailDomain` = `@opennube.net`. The change only took
effect after clearing SOGo's caches: `systemctl restart memcached sogo` AND
`DELETE FROM sogo_user_profile WHERE c_uid='<user>'` (SOGo caches the LDAP user
record in memcached + seeds the default identity in the profile on first login).
Do NOT change the AD `mail` attribute — it's Entra/M365-synced.

### Sending (SMTP) fixed

Symptom: SOGo "cannot send message: (smtp) authentication failure"; Exim logged
no auth attempt from the SOGo IP — it failed before AUTH (STARTTLS path on 587).
Fix: use implicit-TLS submission. `SOGoSMTPServer = "smtps://mail.opennube.net:465"`
(port 465 is open on Hestia: `465 (submissions) open`). Send then succeeds
(`POST …/send 200`). Receive (IMAP 993) + send (SMTP 465) both working.

### Sending (SMTP) — CORRECTED fix

The working setting is **`SOGoSMTPServer = "smtp://mail.opennube.net:587/?tls=YES"`**
(NOT `smtps://465`). On plain `smtp://587` SOGo never issues STARTTLS, so Exim
doesn't offer AUTH (AUTH is only advertised post-STARTTLS) → SOGo fails before
auth → HTTP 405 on /send, and Exim logs a connection with no auth attempt. The
`?tls=YES` query param forces SOGo to STARTTLS (mirrors the `?tls=` param SOGo
uses on its IMAP URL). Verified: `swaks` to both 465 and 587 authenticated +
sent fine (server was always healthy), and after the param SOGo sends:
`<= … A=dovecot_plain:fabian.lazarte@opennube.net … id=…@opennube.net`.
