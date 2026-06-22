# Environment profile — opennube

Concrete values and decisions for **this** deployment. The generic docs
(`architecture.md`, `deployment.md`, `ad-provisioning.md`) describe the
pattern; this file is the source of truth for our actual names and scope.

## Identity & domains

| Thing | Value | Role |
|---|---|---|
| AD/DC domain | `opennube.local` | Internal AD (LDAP). Login = `sAMAccountName`. |
| Identity / UPN / `mail` domain | `opennube.com` | Synced to Entra/M365. **Mailboxes live in Exchange Online.** Identity only for SOGo. |
| **SOGo/Hestia mailbox domain** | `opennube.net` | The one domain the AD bridge manages. Primary SOGo address = `<sAMAccountName>@opennube.net`. |
| Also in Hestia, **not** AD-managed | `opennube.ai`, `myopennube.com`, `opennube.cloud` | Left as-is. Can become alias domains later (see below). |
| Client domains | (various) | **Never** touched by AD or `fachex-sync`. Manual in Hestia. |

## Mailbox model

- **One mailbox per user**, on `opennube.net`.
- Additional addresses are **aliases** on that mailbox, sourced from AD
  `proxyAddresses` — but **only** for AD-managed Hestia domains (today: just
  `opennube.net`). 
- A user therefore effectively has two inboxes: their **M365** mailbox
  (`@opennube.com`) and their **SOGo** mailbox (`@opennube.net`). That is
  intentional given "opennube.com stays in M365".

## The two critical rules for this setup

### 1. Decouple identity domain from mailbox domain via `sAMAccountName`

AD `mail` = `jdoe@opennube.com`, but the SOGo mailbox = `jdoe@opennube.net`.
Everything keys on `sAMAccountName` (`jdoe`):

- **SOGo login:** users type their AD username `jdoe` (not an email).
- **SOGo mailbox:** `SOGoMailDomain = opennube.net` → mailbox is
  `jdoe@opennube.net`.
- **Dovecot AD passdb filter matches the local part** (`%n`) against
  `sAMAccountName`, so the opennube.net mailbox domain never has to equal the
  opennube.com identity domain:

  ```
  # dovecot-ldap.conf.ext (AD passdb)
  base       = OU=Mail Users,DC=opennube,DC=local
  auth_bind  = yes
  pass_filter = (&(objectClass=person)(sAMAccountName=%n))
  user_filter = (&(objectClass=person)(sAMAccountName=%n))
  ```
  `%n` = local part of the IMAP login (`jdoe` from `jdoe@opennube.net`).

- **Dovecot userdb** stays the Hestia passwd-file, keyed on the full address
  `jdoe@opennube.net` → mailbox path + quota.

> SOGo sends the full `jdoe@opennube.net` as the IMAP/SMTP/Sieve login. Confirm
> SOGo builds that from `UID + SOGoMailDomain` (set
> `SOGoForceExternalLoginWithEmail` accordingly, or set `IMAPLoginFieldName` to
> an attribute holding the opennube.net address) — verify against your SOGo
> version during Phase 3.

### 2. `opennube.com` must NOT be a local mail domain in Hestia

Its MX points to M365. Because the domain also exists in Hestia, Exim could try
to deliver `@opennube.com` locally and shadow Exchange Online.

- In Hestia, keep `opennube.com` **web-only** (no mail domain), or configure it
  to relay externally — so Exim never treats it as local.
- The bridge **never** creates `@opennube.com` mailboxes or aliases (it is on
  the explicit exclude list).

## SOGo user source (AD) for this profile

```
SOGoMailDomain = "opennube.net";
SOGoUserSources = (
  {
    type = ldap;
    id = "ad-opennube";
    hostname = "ldaps://dc1.opennube.local";
    baseDN = "OU=Mail Users,DC=opennube,DC=local";
    bindDN = "CN=svc-mail,OU=Service Accounts,DC=opennube,DC=local";
    bindPassword = "CHANGE_ME";
    UIDFieldName = "sAMAccountName";   // login users type
    IDFieldName  = "sAMAccountName";
    bindFields = ("sAMAccountName", "userPrincipalName");
    MailFieldNames = ("mail", "proxyAddresses");  // GAL display (opennube.com)
    canAuthenticate = YES;
    isAddressBook = YES;               // Global Address List
    displayName = "OpenNube Directory";
    groupObjectClasses = ("group");
    MembershipFieldName = "member";
  }
);
```

## fachex-sync scope for this profile

```yaml
ad:
  uri: ldaps://dc1.opennube.local
  userScope: "OU=Mail Users,DC=opennube,DC=local"
  bindDN: CN=svc-mail,OU=Service Accounts,DC=opennube,DC=local
hestia:
  domainOwners:
    opennube.net: <hestia_owner_user>     # the Hestia user that owns opennube.net
sync:
  managedMailboxDomains: [ "opennube.net" ]      # where mailboxes are created
  managedAliasDomains:   [ "opennube.net" ]      # which proxyAddresses become aliases
  excludeDomains:        [ "opennube.com" ]      # M365 — never create here
  mailboxLocalPartFrom:  sAMAccountName          # jdoe -> jdoe@opennube.net
  defaultQuota: "5G"
  retentionDays: 30
  dryRun: true
```

To later turn `opennube.ai` / `myopennube.com` / `opennube.cloud` into aliases,
add them to `managedAliasDomains` (and ensure they're Hestia mail domains).
