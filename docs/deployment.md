# Deployment plan (phased)

Build it in order. Each phase ends in a testable state, so you never have a
big-bang cutover. Config snippets are reference templates — **confirm paths and
versions against your installed SOGo/Hestia/Dovecot** before applying, and
snapshot the relevant LXC/VM first.

---

## Phase 0 — Prerequisites & decisions

- [ ] DNS control for all domains (you have nginx + DNS).
- [ ] An AD service account `svc-mail` (read-only) for SOGo + Dovecot LDAP binds.
- [ ] An AD service account / API credential for the bridge to call Hestia.
- [ ] A dedicated OU (or group) that marks **mailbox-enabled** users, e.g.
      `OU=Mail Users` or group `grp-mail-enabled`. Keeps non-mail AD accounts
      (service accounts, computers) out of the mail system.
- [ ] LDAPS reachable from the SOGo LXC, Dovecot host, and bridge LXC.
- [ ] Decide mailbox quota default (set per-account, can be overridden by AD attr later).

---

## Phase 1 — SOGo node (LXC)

Debian 12 LXC, 2 vCPU / 4 GB RAM is plenty to start.

```bash
# Add the official SOGo repo (use the current key/URL from sogo.nu nightly/stable docs)
apt update && apt install -y sogo sope4.9-gdl1-postgresql memcached postgresql

# PostgreSQL: dedicated DB + role for SOGo's own store
sudo -u postgres psql -c "CREATE USER sogo WITH PASSWORD 'CHANGE_ME';"
sudo -u postgres psql -c "CREATE DATABASE sogo OWNER sogo;"
```

Minimal `/etc/sogo/sogo.conf` (GNUstep plist syntax):

```
{
  SOGoProfileURL = "postgresql://sogo:CHANGE_ME@127.0.0.1:5432/sogo/sogo_user_profile";
  OCSFolderInfoURL = "postgresql://sogo:CHANGE_ME@127.0.0.1:5432/sogo/sogo_folder_info";
  OCSSessionsFolderURL = "postgresql://sogo:CHANGE_ME@127.0.0.1:5432/sogo/sogo_sessions_folder";
  SOGoMemcachedHost = "127.0.0.1";

  SOGoTimeZone = "America/Guayaquil";   // set yours
  SOGoLanguage = "English";
  SOGoMailDomain = "example.com";       // primary; multi-domain handled in Phase 3

  // Mail plumbing — filled in Phase 2
  SOGoIMAPServer = "imaps://mail.example.com:993";
  SOGoSMTPServer = "smtp://mail.example.com:587";
  SOGoSieveServer = "sieve://mail.example.com:4190";
  SOGoMailingMechanism = "smtp";
  SOGoSMTPAuthenticationType = "PLAIN";
  SOGoForceExternalLoginWithEmail = YES;

  // Quality-of-life
  SOGoMailCustomFromEnabled = YES;      // send-as aliases
  SOGoTrustProxyAuthentication = NO;
}
```

```bash
systemctl enable --now memcached sogo
```

**Test:** `https://<lxc-ip>/SOGo` should load the login page (auth not wired yet).

---

## Phase 2 — Connect SOGo to Hestia's mail

On the **Hestia** host:

1. **Enable managesieve** (so SOGo's Rules UI works). Hestia uses Dovecot
   Pigeonhole; ensure the protocol + service are on:

   ```
   # /etc/dovecot/conf.d/20-managesieve.conf
   protocols = $protocols sieve
   service managesieve-login {
     inet_listener sieve { port = 4190 }
   }
   ```
   Confirm `sieve` is in the `mail_plugins` for lmtp/lda, then
   `systemctl restart dovecot`.

2. **Allow SOGo to reach Dovecot/Exim over the LAN** (firewall the SOGo LXC IP
   only): IMAPS 993, submission 587, managesieve 4190. Keep TLS on all three.

**Test:** With a known existing Hestia mail account (local password for now),
log into SOGo. You should see folders, send/receive mail, and the Rules panel
should save a test filter. Once this works, move auth to AD in Phase 3.

---

## Phase 3 — AD integration (auth + GAL + groups)

### 3a. SOGo authenticates against AD

Add an LDAP **user source** in `/etc/sogo/sogo.conf`:

```
SOGoUserSources = (
  {
    type = ldap;
    id = "ad";
    CNFieldName = "cn";
    UIDFieldName = "sAMAccountName";   // login name users type
    IDFieldName = "sAMAccountName";
    bindFields = ("sAMAccountName", "userPrincipalName", "mail");
    MailFieldNames = ("mail", "proxyAddresses");
    hostname = "ldaps://dc1.corp.example.com";
    baseDN = "OU=Mail Users,DC=corp,DC=example,DC=com";
    bindDN = "CN=svc-mail,OU=Service Accounts,DC=corp,DC=example,DC=com";
    bindPassword = "CHANGE_ME";
    canAuthenticate = YES;
    isAddressBook = YES;               // this source becomes the GAL
    displayName = "Global Address List";
    // Groups for sharing/ACL:
    groupObjectClasses = ("group");
    MembershipFieldName = "member";
  }
);
SOGoEnableDomainBasedUID = YES;        // for multi-domain
```

> **Multi-domain:** for several mail domains, either widen `baseDN` to cover all
> mail users and rely on the `mail` attribute, or define one source per domain.
> Set `SOGoMailDomain` to your primary and let `MailFieldNames` resolve the rest.

### 3b. Dovecot authenticates against AD (split passdb/userdb)

On Hestia's Dovecot, **add** an LDAP passdb while keeping the Hestia passwd-file
as userdb. Reference `/etc/dovecot/conf.d/auth-ldap.conf.ext`:

```
passdb {
  driver = ldap
  args = /etc/dovecot/dovecot-ldap.conf.ext
}
# Keep Hestia's existing userdb (passwd-file) for mailbox location + quota.
```

`/etc/dovecot/dovecot-ldap.conf.ext`:

```
uris = ldaps://dc1.corp.example.com
dn = CN=svc-mail,OU=Service Accounts,DC=corp,DC=example,DC=com
dnpass = CHANGE_ME
auth_bind = yes
base = OU=Mail Users,DC=corp,DC=example,DC=com
user_filter = (&(objectClass=person)(|(mail=%u)(userPrincipalName=%u)))
pass_filter = (&(objectClass=person)(|(mail=%u)(userPrincipalName=%u)))
```

Order matters: put the LDAP passdb so AD is authoritative for password checks.
`systemctl restart dovecot`.

> **Hestia-upgrade safety:** Hestia regenerates Dovecot config on some updates.
> Keep these additions in a clearly named drop-in and document them in
> `docs/ad-provisioning.md`'s runbook so they can be re-applied if overwritten.

**Test:** Log into SOGo with an AD username + AD password against a Hestia
mailbox the bridge has created. Verify GAL autocomplete shows AD users and a
shared calendar can be granted to an AD group.

---

## Phase 4 — nginx, DNS, TLS, autodiscover

### nginx reverse proxy (per domain or a single mail host)

```nginx
server {
  listen 443 ssl http2;
  server_name mail.example.com autodiscover.example.com autoconfig.example.com;

  ssl_certificate     /etc/ssl/mail.example.com/fullchain.pem;
  ssl_certificate_key /etc/ssl/mail.example.com/privkey.pem;

  client_max_body_size 100m;          # large attachments
  proxy_read_timeout 3600;            # ActiveSync long-poll

  location / { return 302 /SOGo; }

  location /SOGo {
    proxy_pass http://SOGO_LXC_IP;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header x-webobjects-server-protocol HTTPS/1.0;
    proxy_set_header x-webobjects-remote-host $remote_addr;
    proxy_set_header x-webobjects-server-name $host;
    proxy_set_header x-webobjects-server-url https://$host;
    proxy_buffering off;
  }

  # ActiveSync (EAS) for phones
  location /Microsoft-Server-ActiveSync {
    proxy_pass http://SOGO_LXC_IP/SOGo/Microsoft-Server-ActiveSync;
    proxy_connect_timeout 3600;
    proxy_send_timeout 3600;
    proxy_read_timeout 3600;          # EAS ping needs long timeouts
    proxy_buffering off;
  }
}
```

If you set `SOGoTrustProxyAuthentication`/headers, also set
`SOGoTrustProxyAuthentication = NO` unless you implement header auth.

### DNS per domain

- `mail.<domain>` → nginx (A/AAAA).
- `autodiscover.<domain>` and `autoconfig.<domain>` → nginx (for client setup).
- MX, SPF, DKIM, DMARC — **already in Hestia**; leave as-is.

**Test:** Add the account on an iPhone/Android via Exchange/ActiveSync using
`mail.<domain>` + AD credentials. Mail, calendar, and contacts should push.

---

## Phase 5 — Provisioning bridge

See [`ad-provisioning.md`](ad-provisioning.md). Deploy `fachex-sync` to its LXC,
point it at AD + Hestia, run in dry-run, then enable reconciliation.

---

## Phase 6 — Validation checklist

- [ ] New AD user (in scope OU) appears as a Hestia mailbox within one sync cycle.
- [ ] That user logs into SOGo web with AD password; sends + receives mail.
- [ ] Rules/filter saves and fires (Sieve).
- [ ] AD `proxyAddresses` show up as send-as aliases in compose.
- [ ] Mail-enabled AD group delivers to all members (Hestia forwarder).
- [ ] Calendar invite + free/busy works between two AD users.
- [ ] ActiveSync on phone pushes mail/cal/contacts with AD password.
- [ ] Disabling the AD user suspends the mailbox (login denied, mail retained).
- [ ] GAL autocomplete lists AD users.

---

## Phase 7 — Operations

- **Backups:** SOGo PostgreSQL (calendars/contacts!) on a schedule; Hestia
  already backs up Maildir — verify it includes mail. Snapshot LXCs.
- **HA (later):** SOGo is stateless beyond Postgres + memcached; you can run two
  SOGo LXCs behind nginx and make Postgres HA. Not needed for v1.
- **Monitoring:** Exim queue, Dovecot auth failures, SOGo `sogo` service, bridge
  reconcile log + last-success timestamp.
- **Runbook:** keep the Dovecot/SOGo AD drop-ins documented so they can be
  re-applied after a Hestia upgrade.
