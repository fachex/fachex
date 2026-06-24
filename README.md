# Fachex — Self-hosted Outlook-Web alternative on SOGo + Hestia

Replace a Microsoft 365 / Outlook Web subscription with a fully self-hosted,
AD-driven mail + calendar + contacts stack running on your own OVH/Proxmox
infrastructure.

## What this is

This repository holds the **architecture, deployment plan, and automation**
for running [SOGo](https://www.sogo.nu/) (Outlook-Web-style groupware) on top
of an existing [HestiaCP](https://hestiacp.com/) mail server, with
**Active Directory as the single source of truth** for identity.

Create a user in AD → they automatically get a mailbox in Hestia, a login in
SOGo, an entry in the global address list, and group/sharing membership. No
second password, no manual mailbox creation.

## Goals

- Outlook-Web feel in the browser (mail, calendar, contacts, tasks, filters/rules).
- **AD/Entra-synced identity** — provision-on-create, suspend-on-disable.
- **Single sign-on** with the AD password (web + ActiveSync).
- ActiveSync push to phones; web-only on desktop/Mac/Windows.
- Keep Hestia as the mailbox/domain manager (don't fight the panel).
- nginx as the single TLS-terminating reverse proxy.

## Power features (from the original requirement)

| Feature | Delivered by |
|---|---|
| Aliases | Hestia (Exim) + AD `proxyAddresses` → synced by the bridge |
| Distribution lists | AD mail-enabled groups → Hestia forwarders (server-side); SOGo contact lists (personal) |
| Rules / custom rules | SOGo Mail Filters UI → Dovecot Sieve (managesieve) |
| Groups | AD groups → SOGo groups (sharing/ACL/delegation) |
| Calendar | SOGo (CalDAV) — shared calendars, invitations, free/busy |
| Flag / labels | SOGo (IMAP `\Flagged` + colored labels) |
| Pin | Deferred — candidate open-source contribution (see `docs/roadmap.md`) |

## Documents

- [`docs/opennube-config.md`](docs/opennube-config.md) — **the concrete profile for this deployment** (real domains, scope, the two critical rules). Read this first.
- [`docs/sogo-install.md`](docs/sogo-install.md) — **start here**: create the LXC and install SOGo (Proxmox + in-container scripts).
- [`docs/hestia-integration.md`](docs/hestia-integration.md) — Phase 2: connect SOGo to Hestia's mail (dual-NIC to VLAN 5, managesieve, firewall, TLS).
- [`docs/email-vhost-setup.md`](docs/email-vhost-setup.md) — then route `email.opennube.net` → SOGo while `webmail.*` stays Roundcube (nginx vhost).
- [`docs/architecture.md`](docs/architecture.md) — components, data flow, the SSO/auth model.
- [`docs/deployment.md`](docs/deployment.md) — phased, step-by-step build on Proxmox.
- [`docs/ad-provisioning.md`](docs/ad-provisioning.md) — the AD → Hestia/SOGo sync bridge.
- [`docs/roadmap.md`](docs/roadmap.md) — what's next, including the "Pin" contribution.

## Scope for this deployment

- **AD-managed mailbox domain:** `opennube.net` only.
- **`opennube.com`:** stays in M365 (identity only; never a Hestia mailbox/alias).
- **Mailbox model:** one mailbox on `opennube.net` + aliases from AD.
- **Everything else in Hestia (client + other opennube domains):** untouched.

See `docs/opennube-config.md` for the full profile.

## Status

- ✅ **Phase 1 — SOGo deployed.** CT 902 (node09): SOGo v5 + PostgreSQL +
  memcached. Front-end nginx in the container serves WebServerResources
  (apache2 disabled to free :80).
- ✅ **Phase 2 — Hestia mail wired.** Dual-homed to VLAN 5; IMAPS 993 +
  submission 587 reachable; `mail.opennube.net` LE cert renewed (valid TLS).
  managesieve (4190 / Rules UI) deferred — see `docs/hestia-integration.md`.
- ✅ **Front door live.** `https://email.opennube.net` → dedicated nginx proxy
  (Certbot TLS) → container nginx → SOGo. Styled login over HTTPS.
- ✅ **Phase 3 — AD authentication + mail.** SOGo → AD (login + GAL). Dovecot
  **AD passdb** (`sAMAccountName=%n`, tried before Hestia's passwd-file, clients
  fall through) so AD passwords authenticate mailboxes live — no syncing.
  Send (`smtp://587/?tls=YES`) + receive working. **Multi-domain aggregation**:
  `@opennube.ai` added as a SOGo auxiliary account, same AD password. Hestia
  dual-homed to VLAN 12 so Dovecot can reach the DC.
- ⏳ **Phase 4 — provisioning bridge** (`fachex-sync`): auto-create Hestia
  mailboxes + pre-seed SOGo auxiliary accounts when AD users are added; aliases,
  groups. Also: SOGo for client domains (2nd source), `myopennube.com` once created.

Start here: `docs/sogo-install.md` → `docs/hestia-integration.md` →
`docs/email-vhost-setup.md` → Phase 3 in `docs/deployment.md`.
