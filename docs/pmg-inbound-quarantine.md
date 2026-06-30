# Inbound filtering + spam quarantine via PMG

Goal: inbound mail for opennube.net flows through PMG so spam is **quarantined**
(held, reviewable) and each user gets a spam report with the ability to release
false positives. Companion to `outbound-via-pmg.md` (that covers the reverse
direction).

**Status: WORKING for opennube.net + opennube.ai + lsdomain.com** (2026-06). MX
repointed to PMG for all three; inbound flows internet → PMG (filter) → Hestia →
mailbox; spam (Level 5) is quarantined; the per-user Verbose spam report is
delivered (domain-agnostic — `pmgqm send` covers any mailbox with held mail, no
extra per-domain report config). Verified each with a GTUBE/spam test held in
quarantine and surfaced in the report.

**lsdomain.com is a client domain** (Hestia-local mailbox passwords, not AD) —
treated with pegfl-level caution: full pre-flight before any DNS change.
Pre-flight found and handled:
- **Duplicate `v=spf1` records** (`ip4:.../31`-only + the real one) — same
  permerror trap as opennube.net/.ai. Deleted the redundant one; kept/edited the
  `mx mx:mail.lsdomain.com include:secureserver.net` record (added `.178` for a
  future outbound rollout).
- **`include:secureserver.net` in SPF** turned out to be legacy/harmless — `dig
  mail.lsdomain.com` resolves (via a CNAME to the bare domain) to `51.222.33.182`,
  confirming mail is 100% Hestia-hosted, nothing actually depends on GoDaddy.
  *Always confirm the MX target's A/CNAME chain before relying on SPF alone to
  judge where mail is hosted.*
- **DKIM key exists on Hestia but was never published** to
  `mail._domainkey.lsdomain.com` — pre-existing gap, unrelated to inbound, flagged
  for whenever outbound deliverability work touches this domain.

Post-cutover cleanups done:
- **Hestia antispam disabled per-domain** (`v-delete-mail-domain-antispam <owner>
  <domain>`) for opennube.net + opennube.ai so PMG-filtered mail isn't re-scored /
  double-tagged at Hestia. (Owner found via `v-search-domain-owner <domain>`;
  antivirus left on as harmless defense-in-depth.)
- **Local recursive resolver on PMG** — installed `unbound`, pointed
  `/etc/resolv.conf` at `127.0.0.1`. Spamhaus ZEN now resolves (the high-value
  DNSBL; it blocks public resolvers). dnswl.org/uribl.com still refuse free-tier
  queries from the cloud IP — SpamAssassin self-disables them via
  `/root/.spamassassin/dnsblock_*` markers (leave them); score impact is ~0.001,
  negligible. (`grep -r forward-addr /etc/unbound/` must be empty = direct
  recursion, not forwarding to the blocked public resolvers.)

> ⚠️ **The unbound/`resolv.conf`→127.0.0.1 change is PMG-ONLY.** PMG and the SOGo
> container need *opposite* DNS: PMG uses local `unbound` (public recursion, for
> DNSBLs); **SOGo must use the AD domain controller (`172.17.17.100`) as its
> resolver** so it can resolve internal `.local` names like
> `ONAD1.opennube.local`. Pasting the PMG unbound commands into the SOGo CT once
> repointed SOGo to 127.0.0.1 → unbound can't resolve `.local` → SOGo `LDAPSource:
> Can't contact LDAP server` for the svc-mail bind → **all SOGo logins fail** (DC
> is fine; only the *name* won't resolve). Fix: restore SOGo's
> `/etc/resolv.conf` to `search opennube.local` + `nameserver 172.17.17.100`,
> `systemctl disable --now unbound`, `systemctl restart sogo`. Diagnosis tell:
> `ping 172.17.17.100` works but `getent hosts ONAD1.opennube.local` returns
> nothing.

To add another domain (recipe): PMG Relay Domains + Transport (`<domain> →
51.222.33.182:25, Use MX No`) → `v-delete-mail-domain-antispam` on Hestia →
swaks pretest to PMG `:25` → flip MX to `pmg.opennube.com`.

## Gotchas hit during the cutover (read before repeating for another domain)
- **MX hostname typo:** the MX was first set to `pmg.opennube.**net**` (no A
  record) → unresolvable → **all inbound broke** until corrected to
  `pmg.opennube.com`. Use the `.com` name (matches PTR/HELO/cert).
- **The spam-quarantine rule was disabled.** PMG → Mail Filter →
  `Quarantine/Mark Spam (Level 5)` was OFF (only Level 3 *Modify/tag* was on, and
  `Block Spam (Level 10)` should stay OFF so high scores are *held*, not dropped).
  Enabling Level 5 is what makes spam land in quarantine. Confirm its log line:
  `moved mail for <…> to spam quarantine (rule: Quarantine/Mark Spam (Level 5))`.
- **Quarantine GUI date filter:** `Since=Until=<today>` shows "No data in
  database / No match found" because `Until` is treated as start-of-day, excluding
  same-day mail. Widen `Until` to tomorrow.
- **GTUBE can't be *sent* through Gmail/M365** (they block it outbound). Test by
  injecting with `swaks` straight to PMG `:25`, or from an external box.
- **Hestia message-size limit vs PMG:** PMG's `Message Size` (Options) was 10 MB,
  smaller than Hestia — so large *outbound* (e.g. `paulo@pegfl.com`) hit
  `552 Message size exceeds fixed limit`. Raise PMG to ≥ Hestia (e.g. 50 MB).
- **PMG SpamAssassin DNSBL queries** (`dnswl.org`, `uribl.com`) get rate-limited
  from a public resolver (`RCVD_IN_DNSWL_BLOCKED` / `URIBL_BLOCKED`), degrading
  scoring. Fix with a local caching resolver or `dns_query_restriction deny`.

## Root cause found (2026-06): inbound bypasses PMG entirely

PMG is **fully configured** to be opennube.net's inbound gateway — except the one
step that actually directs mail to it. Verified from the boxes:

| Check | Value | Meaning |
|---|---|---|
| `dig MX opennube.net` | `0 mail.opennube.net` → Hestia `.182` | **MX points to Hestia, not PMG** |
| `grep to=<…opennube.net>` on PMG | (nothing) | no opennube.net inbound ever reaches PMG |
| PMG Relay Domains | `opennube.net` | PMG *is* set to handle it |
| PMG Transports | `opennube.net → 51.222.33.182:25, Use MX: No` | PMG would forward filtered mail to Hestia |
| PMG Spam Quarantine | empty (3+ months) | nothing to quarantine — PMG never sees the mail |

So the world delivers opennube.net mail straight to Hestia (`mail.opennube.net`
→ `.182`); PMG only does **outbound relay** today. The "37 incoming junk" on
PMG's status report is just spam bots hitting PMG's public `.178:25` directly —
not real opennube.net mail. **No spam rule will ever populate the quarantine
until inbound actually transits PMG.**

## The fix: repoint the MX to PMG

Change opennube.net's MX (at GoDaddy) from `mail.opennube.net` to:
```
opennube.net.  MX  0  pmg.opennube.com.
```
`pmg.opennube.com` already resolves to `.178` (the pfSense NAT to PMG `:25`, which
already receives — the bot junk proves `:25` is forwarded to PMG). Flow becomes:
internet → PMG `:25` (filter + quarantine) → transport → Hestia `.182:25` → mailbox.

### Safe sequence (it's live inbound — validate before touching DNS)
1. **Pre-test PMG→Hestia forwarding without changing DNS** — on PMG:
   ```bash
   nc -zv 51.222.33.182 25                       # PMG can reach Hestia SMTP?
   apt-get install -y swaks                       # PMG is Debian; apt OK here (NOT the Hestia box)
   swaks --to fabian.lazarte@opennube.net --from test@example.com \
         --server 127.0.0.1:25 --header "Subject: PMG inbound path test" \
         --body "Testing PMG forward to Hestia."
   ```
   If it lands in the opennube.net **mailbox**, PMG→Hestia works and Hestia accepts
   PMG's mail. (A localhost-injected clean message is treated as relay → uses the
   opennube.net transport → forwards to `.182`.)
2. **Only then change the MX** → `pmg.opennube.com`.
3. **Test real inbound** from Gmail: clean → inbox via PMG; spammy → Spam Quarantine.
4. **Rollback** anytime: MX back to `mail.opennube.net`.

### Watch-outs
- **SPF on forwarded mail:** mail reaches Hestia from `.178` with the *original*
  external sender — strict inbound SPF on Hestia could reject it. Hestia must
  **trust PMG `.178`** as its upstream gateway (skip SPF/spam re-checks for it).
  The pre-test reveals this: if the test message doesn't arrive, whitelist `.178`
  on Hestia.
- **fail2ban:** add `51.222.33.178` to Hestia's `ignoreip` so PMG's deliveries
  can't get it banned (see hestia-integration.md ops note).
- **Direction:** PMG's spam rules are direction `In`; they only apply once the MX
  sends real external mail through PMG. Localhost/trusted injections count as
  `Out` and skip the inbound spam rules.

## Quarantine + per-user spam report config (PMG)

Discovered state and what to set:

- **Mail Filter rules** (Configuration → Mail Filter): the spam **quarantine** rule
  was **disabled**. Factory rules present:
  - `Quarantine/Mark Spam (Level 3)` — action *Modify* (tags `[SPAM]`, delivers) — was the only spam rule on.
  - `Quarantine/Mark Spam (Level 5)` — action *Quarantine* — **was OFF; enable it.** ← the fix for "nothing is held"
  - `Block Spam (Level 10)` — action *Block* (discard) — **leave OFF** so high-scoring
    false positives are *held*, not discarded.
- **Spam Detector → Options:** RBL + Razor2 on, Bayesian off, Heuristic 3 (scoring works).
- **Spam Detector → Quarantine:**
  - `User Spamreport Style = Verbose` → per-user reports ON.
  - `Authentication mode = Ticket` → report links Deliver/Whitelist **without login**.
  - `EMail From = pmgreport@opennube.net`.
  - `Quarantine Host = none` → **set to `pmg.opennube.com`** so the report's action
    links resolve (`:8006` is NATed through pfSense).
  - Lifetime 7 days.
- Send reports on demand for testing: `pmgqm send` (runs daily by default).

Per-user **login** to browse/release quarantine (deferred — "Piece 2"): needs PMG
LDAP/AD integration (Configuration → LDAP → AD `ONAD1.opennube.local`) so users
authenticate and see only their own quarantine, plus exposing the quarantine UI
(reverse proxy `quarantine.opennube.net → 10.10.51.4:8006`, or the NAT already in
place). Not required for Ticket-mode report links.

## PMG environment facts (reference)
- PMG 8.2.0, single NIC `ens18 = 10.10.51.4/29`, gw `10.10.51.1`. No public IP on
  the box — `51.222.33.178` is a **pfSense NAT** (`.178 ⇄ 10.10.51.4`).
- Ports: External SMTP `25` (inbound), Internal SMTP `26` (trusted/outbound relay).
- `:8006` (admin + quarantine UI) is NATed through pfSense.
- HELO/`myhostname = pmg.opennube.com`; PTR `.178 → pmg.opennube.com`.
