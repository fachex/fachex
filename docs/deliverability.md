# Deliverability & blocklist response (Hestia outbound)

The shared sending IP is **51.222.33.182** (Hestia VM `site.opennube.com`, OVH).
One listed IP blocks mail for **every** hosted domain, so treat this as priority.

## Golden rule: FCrDNS + HELO must all agree
Microsoft (Outlook/EXO) and Spamhaus require forward-confirmed reverse DNS with a
matching HELO. All three must reference ONE name:

```
HELO      = site.opennube.com                     (Exim primary_hostname)
A  (fwd)  = site.opennube.com -> 51.222.33.182     (DNS host = GoDaddy)
PTR (rev) = 51.222.33.182 -> site.opennube.com     (IP owner = OVH, NOT GoDaddy)
```

- **Forward A** lives at the **DNS host (GoDaddy)** for the domain.
- **Reverse PTR** lives at the **IP owner (OVH)** — set in OVH Manager → IP →
  "Edit the reverse". The server cannot set its own PTR. OVH requires the forward
  A to resolve to the IP first.
- Verify from a PUBLIC resolver (local `/etc/hosts` lies — it maps the hostname
  to 127.0.0.1):
  ```
  dig +short site.opennube.com @1.1.1.1      # -> 51.222.33.182
  dig +short -x 51.222.33.182 @1.1.1.1       # -> site.opennube.com
  ```

## Spamhaus removal
Symptom: `550 5.7.1 ... blocked using Spamhaus` in NDRs.
- **Check status via the WEB tool** (https://check.spamhaus.org) — the server's
  resolver is blocked from DNSBL queries, so `dig ...zen.spamhaus.org` gives false
  negatives (test: `dig +short 2.0.0.127.zen.spamhaus.org` should return 127.0.0.2;
  if empty, your resolver is blocked).
- Most of our hits are **policy/FCrDNS** listings (not spam) — fix HELO/forward/PTR
  alignment above, then use the removal form.
- The removal form's **verification email domain must match the PTR domain**
  (PTR `site.opennube.com` -> use a `@opennube.com` address). Choose "Immediate
  removal". It clears in minutes once records check out.
- If it IS spam: first find/stop the source (`exim -bpc`, `exim -bp | exiqsumm`,
  top `A=dovecot_login` senders), change the compromised password, flush the
  queue, THEN delist.

## Prevention (hosting provider on a shared IP)
- Keep rDNS/HELO aligned (above); re-check after any IP/hostname change.
- Strong mailbox passwords + fail2ban (constant brute-force); whitelist trusted
  client office IPs (see hestia-integration.md ops note).
- Outbound rate-limit per account so one cracked account can't blast before you
  notice; monitor the IP on a blocklist watcher.
- Durable option: route outbound through a reputable **smarthost/relay** so a
  single shared IP's reputation can't block all hosted domains.
  **This is now the plan** — Hestia → Proxmox Mail Gateway (`51.222.33.178`,
  clean IP) → internet. Full runbook: [`outbound-via-pmg.md`](outbound-via-pmg.md).
