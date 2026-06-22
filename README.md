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
- [`docs/email-vhost-setup.md`](docs/email-vhost-setup.md) — route `email.opennube.net` → SOGo while `webmail.*` stays Roundcube (nginx vhost + runbook).
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

Planning / design. No services deployed yet. Start with `docs/deployment.md`.
