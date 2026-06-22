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
