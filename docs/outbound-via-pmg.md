# Outbound mail relay: Hestia → Proxmox Mail Gateway → internet

Durable deliverability fix. Instead of every hosted domain sharing Hestia's
direct sending IP (`51.222.33.182`), Hestia hands all outbound mail to the
**Proxmox Mail Gateway (PMG)**, which sends from its own clean IP
(`51.222.33.178`). One cracked mailbox can no longer poison the reputation of
the IP that all domains send from, and PMG gives us outbound filtering +
quarantine so we see false positives instead of silent `Emails will not go out`.

## Confirmed facts (2026-06, verified from the boxes)

| Fact | Value | How verified |
|---|---|---|
| Hestia public egress / current sender | `51.222.33.182` | existing SPF, PTR |
| PMG public IP | `51.222.33.178` | user |
| PMG hostname | `pmg` | user |
| PMG LAN IP | `10.10.51.4` | user |
| `.178` blocklist status | **clean** | check.spamhaus.org |
| `.178` PTR (current) | `ip178.ip-51-222-33.net` (generic OVH) | `dig -x 51.222.33.178 @1.1.1.1` |
| `opennube.net` SPF (current) | `v=spf1 a mx ip4:51.222.33.182 -all` | `dig TXT opennube.net @1.1.1.1` |
| Hestia → `10.10.51.4:25` | **timed out** (LAN not routable from Hestia) | `nc -zv 10.10.51.4 25` |
| Hestia → `51.222.33.178:25` | **open** | `nc -zv 51.222.33.178 25` |

**Routing decision:** Hestia smarthosts to PMG over the **public** IP
`51.222.33.178:25` (the internal `10.10.51.4` path is unreachable). PMG already
trusts `.182` (Hestia's egress) so it accepts the relay without auth.

## Order of operations — DNS first, Exim last

Do these in order. The Exim flip is the only risky step and it must come *after*
the DNS is ready, or mail will start arriving at recipients from `.178` while
SPF still says "only `.182` may send" → SPF `fail` → straight to spam/reject.

### 1. SPF — authorize `.178` (do FIRST, it's just DNS)

At **GoDaddy** (DNS host) for **every domain that sends mail through Hestia**,
add `ip4:51.222.33.178` to the SPF TXT record. For `opennube.net`:

```
v=spf1 a mx ip4:51.222.33.182 ip4:51.222.33.178 -all
```

Keep `.182` in there during the cutover (mail may still leave directly until the
smarthost is confirmed). You can drop `.182` later, once 100% of outbound is
confirmed going through PMG.

> Repeat for `pegfl.com`, `lsdomain.com`, and any other live sending domain.
> A domain that sends through PMG without `.178` in its SPF will fail SPF.
> Run `dig +short TXT <domain> @1.1.1.1` per domain to see the current record.

SPF caveat: a record may not list `ip4:...` directly — some use `include:`. Edit
whatever authorizes `.182` today so it also authorizes `.178`. Watch the 10-DNS-
lookup SPF limit if a domain already chains several `include:`s.

### 2. PTR + HELO for `.178` (FCrDNS — same golden rule as `.182`)

PMG must present a HELO name that forward-confirms to `.178`. Pick a real FQDN
(e.g. `pmg.opennube.com` or `mail.opennube.com` — must be a domain we control
DNS for) and align all three:

```
HELO      = pmg.opennube.com   (PMG: Configuration → Mail Proxy → "smarthost"/myhostname; see step 4)
A  (fwd)  = pmg.opennube.com -> 51.222.33.178   (GoDaddy)
PTR (rev) = 51.222.33.178 -> pmg.opennube.com   (OVH Manager → IP → Edit reverse)
```

- Add the forward **A** record at GoDaddy first (OVH requires forward-resolves-
  to-IP before it will accept the PTR).
- Set the **PTR** in OVH Manager for `51.222.33.178` (NOT GoDaddy).
- Verify from a public resolver:
  ```
  dig +short pmg.opennube.com @1.1.1.1     # -> 51.222.33.178
  dig +short -x 51.222.33.178 @1.1.1.1     # -> pmg.opennube.com
  ```
- The generic `ip178.ip-51-222-33.net` will keep working for connectivity, but
  Microsoft/Spamhaus want the FCrDNS name to match the HELO — so set this before
  relying on PMG for volume.

### 3. DKIM — confirm signatures survive the relay

Hestia (Exim) DKIM-signs on the way out. PMG relays the message **as-is** for an
already-signed, authenticated relay, so the existing `d=opennube.net` DKIM
signature stays valid (PMG does not re-sign or alter the signed headers/body for
a plain relay). After the cutover, send a test to a Gmail account and check
**Show original → DKIM: PASS, SPF: PASS (from 51.222.33.178), DMARC: PASS**.
If DKIM breaks, the cause is PMG rewriting a signed header — check PMG isn't
adding/stripping headers inside the DKIM `h=` set.

### 4. PMG — accept relay from Hestia + set up quarantine

On PMG (web UI):

**a. Trust Hestia as a relay source.** PMG must accept and relay mail coming
from Hestia's egress `51.222.33.182` without treating it as spam-from-outside.
- Configuration → Mail Proxy → **Networks**: add `51.222.33.182/32` (and the
  Hestia LAN if applicable) as a trusted network so PMG relays it outbound
  rather than rejecting it as an open-relay attempt.

**b. HELO / myhostname.** Configuration → Mail Proxy → **Options** (or
`/etc/pmg/templates` / `postfix main.cf` `myhostname`): set the HELO PMG uses
when sending to the internet to `pmg.opennube.com` (matches step 2).

**c. Quarantine instead of silent drop (the user's key ask).** So outbound
false-positives are held + reviewable rather than vanishing:
- Configuration → Spam Detector / Mail Proxy → ensure spam action is
  **quarantine**, not reject/discard, for the relayed mail.
- Configuration → **"Send NDR on Blocked"**: currently `No`. Set to **Yes** so a
  blocked/quarantined outbound message generates a notification (the sending user
  has no console — the NDR is how they learn it was held).
- Set a quarantine admin notification address (e.g. `fabian.lazarte@opennube.net`)
  so a daily digest of held mail goes somewhere a human reads.

### 5. Hestia — point Exim's smarthost at PMG (THE RISKY STEP)

> ⚠️ This is a production change on the box that previously had a MariaDB outage
> from an unguarded apt/needrestart. This step touches **only Exim config files +
> an Exim reload** — no apt, no package install, so needrestart is not involved.
> Still: **back up first, validate config, reload (not restart), test immediately,
> and keep the rollback one command away.**

HestiaCP's Exim reads `/etc/exim4/exim4.conf.template`. The smarthost is set via
a router + transport, or (simplest, panel-aware) Hestia's own smarthost hook.

**Backup first:**
```bash
cp -a /etc/exim4/exim4.conf.template /root/exim4.conf.template.$(date +%F-%H%M).bak
```

**Option A — Hestia-native (preferred if present).** Newer HestiaCP exposes a
relay/smarthost via `/etc/exim4/smtp_relay.conf` referenced by the template.
Check:
```bash
grep -n smtp_relay /etc/exim4/exim4.conf.template
```
If present, populate it (host:port and, if PMG required auth, credentials —
here PMG accepts `.182` by IP so no auth):
```
# /etc/exim4/smtp_relay.conf  (format: host:port or host:port:user:pass)
51.222.33.178:25
```

**Option B — explicit smarthost router/transport in the template.** If there's
no native hook, add a router that sends everything not local to PMG, ahead of the
`dnslookup` router:

```
# --- routers --- (BEFORE dnslookup)
send_via_pmg:
  driver = manualroute
  domains = ! +local_domains
  transport = pmg_smarthost
  route_list = * 51.222.33.178::25
  no_more

# --- transports ---
pmg_smarthost:
  driver = smtp
  hosts_require_tls = false
  # PMG accepts our IP; opportunistic TLS is fine, not required
  tls_tempfail_tryclear = true
```

(Use `::25` double-colon so Exim treats the IP literal as host+port correctly.)

**Validate, then reload (never blanket-restart):**
```bash
exim -bV                       # parse/syntax check the config — must say "no errors"
exim -bt postmaster@gmail.com  # routing test: should show it routing via pmg_smarthost
systemctl reload exim4         # reload, not restart — does not drop the queue
```

If `exim -bV` reports any error, **do not reload** — restore the backup:
```bash
cp -a /root/exim4.conf.template.<stamp>.bak /etc/exim4/exim4.conf.template
```

### 6. Test one message end-to-end

```bash
echo "pmg relay test $(date)" | mail -s "pmg outbound test" you@gmail.com
exim -bp            # is it queued? frozen?
tail -f /var/log/exim4/mainlog   # watch: should show  H=51.222.33.178 ... C="250 OK"
```

On the Gmail side, **Show original**:
- `Received:` chain shows the hop through PMG (`pmg.opennube.com [51.222.33.178]`).
- **SPF: pass** (`51.222.33.178` now authorized).
- **DKIM: pass** (`d=opennube.net`).
- **DMARC: pass**.

Then send a real message from a `pegfl.com` mailbox to the Microsoft recipient
that was bouncing `550 Spamhaus` — it should now leave from the clean `.178` and
deliver.

## Rollback

Single step, instant:
```bash
cp -a /root/exim4.conf.template.<stamp>.bak /etc/exim4/exim4.conf.template
exim -bV && systemctl reload exim4
```
Mail reverts to leaving Hestia directly from `.182`. (DNS changes from steps 1–2
are additive and safe to leave in place — `.178` in SPF and its PTR do no harm
when unused.)

## Why public IP, not the LAN

`nc -zv 10.10.51.4 25` from Hestia **timed out** — Hestia and PMG are not on the
same routable LAN segment, so the internal address is a dead end from here. The
public `51.222.33.178:25` is reachable and PMG trusts `.182` by IP, so the public
path is correct and not a security downgrade (it's our own gateway, TLS-capable).
If the two are later put on a common VLAN, switch `route_list`/`smtp_relay.conf`
to `10.10.51.4:25` to keep the relay off the public interface.
