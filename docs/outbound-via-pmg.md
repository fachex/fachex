# Outbound mail relay: Hestia → Proxmox Mail Gateway → internet

Durable deliverability fix. Instead of every hosted domain sharing Hestia's
direct sending IP (`51.222.33.182`), Hestia hands outbound mail to the
**Proxmox Mail Gateway (PMG)**, which sends from its own clean IP
(`51.222.33.178`). One cracked mailbox can no longer poison the reputation of
the IP all domains send from, and PMG scans outbound (quarantine) so we see
false positives instead of silent `Emails will not go out`.

**Status: WORKING for `opennube.net`** (2026-06). Verified: Hestia relays via
PMG `:26`, PMG accepts (`250 ... queued`) and sends from `.178`. Rollout to the
other domains is per-domain (SPF + a one-line file), see "Rollout" below.

## Topology (as actually discovered)

```
                         pfSense (NAT)
   internet  <—— .178 ——>  10.10.51.0/29  ——  PMG (ens18 = 10.10.51.4)
      ^                         |                  ^  ^
      |                    DNAT :25 → .4:25        :25 inbound (postscreen)
   Hestia (.182) ——————————————┘                  :26 outbound relay  ← we use this
      pfSession NAT: .178:26 → .4:26 (src-restricted to .182)
```

- **PMG has no public IP.** Its only NIC is `ens18 = 10.10.51.4/29`; `51.222.33.178`
  is a **NAT on pfSense** (`.178 ⇄ 10.10.51.4`). Inbound mail: internet → `.178:25`
  → DNAT → PMG `:25`. PMG egress is SNAT'd out as `.178` (clean IP, PTR
  `pmg.opennube.com`).
- **PMG separates inbound and outbound onto different ports** (from `master.cf`):
  - **`:25`** (postscreen → `smtpd pass`) is **inbound only** — it overrides
    `mynetworks` down to `127.0.0.0/8,10.10.51.2`, so *no external IP can relay
    through it* by design. (This is why adding `.182` to the global `mynetworks`
    did nothing for `:25` — the override wins. Symptom: `554 5.7.1 Relay access
    denied` even though `postconf -h mynetworks` listed `.182`.)
  - **`:26`** is the **trusted/outbound relay submission port** — it uses the
    *global* `mynetworks` (which includes `10.10.51.0/29` and `51.222.33.182/32`)
    with `permit_mynetworks, reject_unauth_destination`, and still runs the
    content filter (`scan:127.0.0.1:10023`). **Feed outbound mail here.**

So the relay target is **PMG `:26`**, reached either via a pfSense NAT
(`.178:26`) or directly over the internal `/29` (`10.10.51.4:26`).

## Prerequisites on PMG (one-time)

1. **Trust Hestia's egress.** Configuration → Mail Proxy → **Networks** → add
   `51.222.33.182/32`. (The internal `10.10.51.0/29` is already trusted natively.)
   Then make it live: `pmgconfig sync --restart 1`.
2. **HELO / FCrDNS for `.178`.** PMG's `myhostname` was `pmg.opennube.local`
   (from the resolver search domain) — wrong for a public sender. Fix it in the
   **override** template PMG actually reads (not `/var/lib`):
   ```bash
   cp -a /etc/pmg/templates/main.cf.in /root/main.cf.in.$(date +%F).bak
   sed -i 's|^myhostname = .*|myhostname = pmg.opennube.com|' /etc/pmg/templates/main.cf.in
   pmgconfig sync --restart 1
   postconf -h myhostname        # -> pmg.opennube.com
   ```
   Align DNS so FCrDNS holds: forward `A pmg.opennube.com → 51.222.33.178`
   (GoDaddy) and PTR `51.222.33.178 → pmg.opennube.com` (OVH). Verify:
   `dig +short pmg.opennube.com @8.8.8.8` and `dig +short -x 51.222.33.178 @8.8.8.8`.
3. **Quarantine, not silent drop / backscatter.** Keep "Send NDR on Blocked" =
   **No** (global Yes = backscatter risk on inbound spam). Use spam action =
   quarantine + quarantine notification digests for outbound-visibility instead.

## Prerequisite on pfSense (if using the public `.178:26` path)

The NAT only forwards `:25` by default; expose `:26` **source-restricted to
Hestia** so it isn't an internet-facing relay port:

Firewall → NAT → Port Forward → Add:
- Interface **WAN**, Protocol **TCP**, Destination **WAN address**, Dest port **26**
- Redirect target **10.10.51.4**, port **26**
- **Source (Advanced) = single host `51.222.33.182`**  ← required
- Add associated filter rule. Save → Apply.

Even on `:26`, PMG still rejects anything not in `mynetworks`; the source
restriction just keeps the port from being probed/abused from the internet.

> Alternative (no firewall hole): give Hestia a vNIC on `10.10.51.0/29`
> (`.3` or `.6` are free; `.1` gw, `.4` PMG; gateway-less so Hestia's default
> route is untouched) and relay to the internal `10.10.51.4:26`. Cleaner long
> term; the only change vs. below is `host: 10.10.51.4`.

## Prerequisite in DNS (per sending domain)

Every domain that relays through PMG must authorize `.178` in SPF, or mail now
leaving from `.178` fails SPF. Edit the *existing* record (don't add a second
`v=spf1` — two records = `permerror`):
```
v=spf1 a mx ip4:51.222.33.182 ip4:51.222.33.178 -all
```
Done for `opennube.net`. Verify a *single* `v=spf1` line:
`dig +short TXT <domain> @8.8.8.8`.

## The Hestia change — native SMTP relay, no template edit

HestiaCP's `exim4.conf.template` already has a native relay (macros read at
send-time), so **we add a data file, not config** — far lower risk on this box:

- `SMTP_RELAY_FILE` resolves per-domain first
  (`/etc/exim4/domains/<domain>/smtp_relay.conf`), else global
  (`/etc/exim4/smtp_relay.conf`). Format is Exim `lsearch` (`key: value`):
  `SMTP_RELAY_HOST/PORT/USER/PASS = ${lookup{host|port|user|pass}lsearch{FILE}}`.
- Omitting `user`/`pass` makes `SMTP_RELAY_USER` empty → the router
  `send_via_unauthenticated_smtp_relay` fires, whose transport is **`remote_smtp`**
  — the one that **DKIM-signs** (`dkim_domain`/`dkim_selector=mail`/`dkim_private_key`).
  So **DKIM is preserved automatically**. (The authenticated path uses
  `smtp_relay_smtp`, which does *not* sign — we deliberately avoid it.)
- Isolation is automatic: a domain with no per-domain file falls back to the
  (absent) global file → `require_files` fails → that router is skipped → normal
  direct delivery. So a per-domain file touches only that domain.

### Per-domain (canary / selective)
```bash
printf 'host: 51.222.33.178\nport: 26\n' \
  > /etc/exim4/domains/opennube.net/smtp_relay.conf
chmod 644 /etc/exim4/domains/opennube.net/smtp_relay.conf
exim -bV                                                     # config still valid
exim -bt -f fabian.lazarte@opennube.net you@gmail.com        # routes via send_via_unauthenticated_smtp_relay → remote_smtp → 51.222.33.178:26
```
No reload needed — the macros read the file at send-time. (Hestia's active
config is `/var/lib/exim4/config.autogenerated`, regenerated from the template;
we don't touch the template, so nothing to regenerate.)

### Global (all domains)
Same two lines in `/etc/exim4/smtp_relay.conf`. Every domain whose SPF includes
`.178` then relays through PMG.

## Test
```bash
sendmail -f fabian.lazarte@opennube.net you@gmail.com <<'EOF'
From: fabian.lazarte@opennube.net
To: you@gmail.com
Subject: opennube.net via PMG

relay test
EOF
grep 'R=send_via' /var/log/exim4/mainlog | tail -3
```
Success line:
```
=> you@gmail.com R=send_via_unauthenticated_smtp_relay T=remote_smtp
   H=51.222.33.178 ... C="250 ... Ok: ... queued as <PMG-qid>"
```
Then Gmail → Show original: **SPF pass (51.222.33.178), DKIM pass (d=<domain>),
DMARC pass**. (`250 queued` = PMG accepted; Show-original = it landed authed.)

## Rollout status
Per-domain (NOT global — see warning below). Each: add `.178` to SPF first
(single `v=spf1` record), confirm DKIM key present+published, drop the relay
file, test.
1. ✅ `opennube.net` — working; SOGo real sends reach Gmail inbox.
2. ✅ `opennube.ai` — working (SPF `.178` added, single record).
3. ✅ `pegfl.com` — working. **The Microsoft recipient that hard-bounced
   `550 Spamhaus` now accepts the mail (no bounce).** Original problem solved.
   (Gmail still Junk-folders pegfl while the IP warms — placement, not delivery.)
4. Pending, per-domain when needed: `opennube.com.ar` (SPF `.178` first — it's
   `p=quarantine`, so it WILL break if relayed without `.178`).

### ⚠️ Do NOT use a global `/etc/exim4/smtp_relay.conf` (yet)
A blanket global file routes *every* Hestia domain through `.178` immediately —
and any domain whose SPF lacks `.178` then fails SPF. For `p=quarantine`/`reject`
domains that means quarantine/reject at recipients. A 2026-06 audit of
`/etc/exim4/domains/` found domains that would **break** on a global flip:
`pegfl.com` and `opennube.com.ar` (both `p=quarantine`, `.178` not yet in SPF at
audit time). Others need SPF hygiene first (`colinadeleste.com` has no SPF;
`lsdomain.com` has a duplicate-`v=spf1` permerror + GoDaddy mail; `ultravos.com`
has a stray `_dmarc` typo in its SPF; `neko.com.ar` runs mail on Cloudflare, not
Hestia). Going global saves no SPF work (each domain still needs `.178`) and adds
all-or-nothing risk. **Stay per-domain until every sending domain's SPF has
`.178`.** Audit command:
```bash
for d in $(ls /etc/exim4/domains/); do
  spf=$(dig +short TXT "$d" @8.8.8.8 | grep -i 'v=spf1' | tr -d '\n')
  has178=$(echo "$spf" | grep -q '51.222.33.178' && echo YES || echo "no ")
  dmarc=$(dig +short TXT _dmarc."$d" @8.8.8.8 | grep -io 'p=[a-z]*' | head -1)
  printf '%-26s .178:%s  dmarc:%-12s %s\n' "$d" "$has178" "${dmarc:-none}" "$spf"
done
```

## Rollback
Per-domain: `rm /etc/exim4/domains/<domain>/smtp_relay.conf` → instant revert to
direct delivery (no reload needed). Global: `rm /etc/exim4/smtp_relay.conf`.

## Disable PMG's own DKIM signing (critical)

Hestia already DKIM-signs validly (`s=mail`, key published at
`mail._domainkey.<domain>`). PMG, by default, was **also** signing outbound with
its own selector `s=pmg` (Configuration → Mail Proxy → **DKIM**: *Enable DKIM
Signing = Yes*, *Sign all Outgoing Mail = Yes*, *Signing Domain Source =
Envelope*). That second signature was **broken** — Gmail reported
`dkim=neutral (bad format) header.s=pmg`, and no `pmg._domainkey.<domain>` key
was ever published. A malformed/unverifiable signature is a **spam signal** even
when a second signature passes.

**Fix: Configuration → Mail Proxy → DKIM → set "Enable DKIM Signing" = No.**
(Don't just toggle "Sign all Outgoing Mail" — disable the feature entirely; PMG
re-signing is redundant when Hestia signs correctly.) After this, Gmail shows a
single clean `dkim=pass header.s=mail`, with SPF+DKIM+DMARC all passing.
(Note: PMG's Sign Domains list also had a typo `opennue.net` — moot once
disabled, but a latent bug if DKIM is ever re-enabled.)

## Spam foldering after auth passes = cold-IP warmup
With SPF/DKIM/DMARC all passing and FCrDNS aligned, residual spam-foldering is
just `.178` having no sending history. Mark **Not spam**, reply, and send normal
(non-"test") content for a day or two. The original problem was Microsoft
*rejecting* (`550`); delivering-to-spam is a far softer, self-resolving state.

## Gotchas hit (so we don't relive them)
- `554 Relay access denied` from PMG while `.182` *was* in `mynetworks` →
  `:25` has an `-o mynetworks=127.0.0.0/8,10.10.51.2` override. Use `:26`.
- Mail delivered but landed in spam with `dkim=neutral (bad format) header.s=pmg`
  → PMG double-signing with an unpublished/broken selector. Disable PMG DKIM
  (above); let Hestia be the sole signer.
- `postconf -h X` reads the *file*, not the running process — confirm with a
  real send, not just `postconf`.
- PMG `myhostname` comes from the resolver **search domain** (`opennube.local`),
  not `/etc/hosts` — fix via the `main.cf.in` override, don't rename the node.
- Two `v=spf1` records = SPF `permerror` (worse than missing `.178`). Edit the
  existing record; never add a second.
- PMG's `:25` override trusts `10.10.51.2`, and `/etc/hosts` calls PMG `.2`, but
  the real NIC is `.4` — pre-existing PMG config quirk; harmless, tidy later.
