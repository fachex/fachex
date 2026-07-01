# Roadmap

## v1 — Outlook-Web parity (this plan)
- SOGo on Proxmox LXC, AD-authenticated, talking to Hestia mail.
- Single sign-on (AD password) for web + ActiveSync.
- `fachex-sync` provisioning bridge: AD user → Hestia mailbox.
- Aliases, server-side distribution lists, rules, groups, calendar, flags.

## v2 — Polish
- AD distribution-group → Hestia forwarder full lifecycle (membership churn).
- Quota from AD attribute; per-user overrides.
- Webhook-driven near-instant provisioning from the DC.
- SOGo themeing to match an Outlook-Web look.

## v3 — Optional SSO hardening
- OIDC/SAML front door against Entra for MFA at SOGo login.
  Requires moving SOGo→Dovecot to master-user auth (and a plan for native
  ActiveSync password clients). Trade-offs documented in `architecture.md`.

## Deferred — "Pin to top" (open-source contribution)
Outlook Web's pin has no IMAP/SOGo equivalent. Two paths:
- **Workflow now:** a dedicated colored label + a saved/sorted view.
- **Real feature later:** implement pinning via an IMAP keyword (e.g.
  `$Pinned`) plus a pinned section in SOGo's message list. Self-contained,
  upstreamable to the SOGo project — a good first contribution rather than
  building a whole client.

## Client domains on SOGo (decided — closed, not building the SQL source)

Original goal: let client domains (e.g. `lsdomain.com`, `pegfl.com`) use SOGo
too, replacing Roundcube for them, via a dedicated SOGo SQL user source (see
below for the design that was scoped but not built).

**Decision (2026-07):** not needed.
- **pegfl.com** — the client mostly uses Outlook desktop, rarely touches a web
  client, so there's no real demand for SOGo there. Stays on Roundcube/Outlook.
- **lsdomain.com** — effectively Fabian's personal domain. Added as a plain
  **secondary IMAP account** inside the existing AD-backed SOGo (Preferences →
  Mail → Accounts → Add Mail Account: server `mail.opennube.net`, IMAP 993,
  SMTP 587 STARTTLS, username = full `user@lsdomain.com` address + its own
  Hestia mailbox password). No SOGo-side config changed — Dovecot already
  authenticates it via the existing AD-passdb-falls-through-to-Hestia chain.
  Outbound from this account automatically relays through PMG since
  `lsdomain.com` already has `smtp_relay.conf` set up.
- Net: the SQL user source / separate-tenant work below is **shelved**. Revisit
  only if another client domain specifically wants a SOGo web client of its own.

<details>
<summary>Original design notes (kept for reference if this is revisited)</summary>

- **Auth is already half-solved:** the AD passdb falls through to Hestia's
  passwd-file, so client mailboxes already authenticate at Dovecot. Clients log
  in with their normal Hestia mailbox password (no AD).
- **Missing piece:** a SOGo **SQL user source** for clients — a table
  (`email`, `password-hash`, `domain`) mirroring Hestia's flat-file accounts
  (`/etc/exim4/domains/<domain>/passwd`, **MD5-CRYPT** hashes), with SOGo set to
  `userPasswordAlgorithm = md5-crypt`. A small sync (cron or folded into
  `fachex-sync`) keeps the table in step with Hestia.
- **Architecture decision (undecided):**
  1. Separate "clients" SOGo container (Hestia-backed, no AD) — cleanest tenant
     isolation from the internal AD SOGo; branded per client (e.g.
     `email.lsdomain.com`). *(leaning recommendation)*
  2. One shared SOGo, multi-tenant, using `SOGoDomainsVisibility` + per-domain
     isolation so tenants can't see each other's GAL/free-busy.
  3. Per-client SOGo — max isolation/branding, most containers.
- **Watch-out:** GAL/address-book visibility must be scoped per domain so client
  A can't see client B or opennube. (For the SQL client source, keep
  `isAddressBook` off or per-domain.)

</details>
