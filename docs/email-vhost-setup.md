# Stand up `email.opennube.net` → SOGo (coexisting with Roundcube)

Goal: `email.<domain>` serves SOGo, while `webmail.<domain>` keeps serving
Hestia's Roundcube. They're different hostnames → different backends, so they
coexist with zero conflict. No Roundcube change required.

```
webmail.opennube.net  --->  Hestia / Roundcube      (unchanged)
email.opennube.net    --->  SOGo LXC  (new)
```

> One canonical SOGo URL (`email.opennube.net`) works for **all** users
> regardless of their mail domain — SOGo is multi-domain. You can later add
> `email.opennube.ai`, etc. to the same vhost `server_name`; they all proxy to
> the same SOGo.

## Prerequisites

1. **SOGo is running** on its LXC and answers on `http://<lxc-ip>:20000/SOGo`.
   If not, do `docs/deployment.md` Phase 1 first.
2. You control DNS for `opennube.net` and the front nginx proxy.

## Steps

### 1. DNS
Add an A/AAAA record on the front proxy's public IP:

```
email.opennube.net.        A     <front-nginx-public-ip>
autodiscover.opennube.net. A     <front-nginx-public-ip>   # optional, client autoconfig
autoconfig.opennube.net.   A     <front-nginx-public-ip>   # optional, client autoconfig
```

Leave `webmail.opennube.net` exactly as it is.

### 2. TLS cert
Issue a cert for the new names (Let's Encrypt example on the proxy):

```bash
certbot certonly --webroot -w /var/www/acme \
  -d email.opennube.net -d autodiscover.opennube.net -d autoconfig.opennube.net
```

### 3. Install the vhost
Copy [`deploy/nginx/email.opennube.net.conf`](../deploy/nginx/email.opennube.net.conf)
to the proxy and edit two things:

- `upstream sogo_backend` → your **SOGo LXC IP:20000**.
- `ssl_certificate*` paths → your cert (the certbot paths above already match).

```bash
cp email.opennube.net.conf /etc/nginx/conf.d/   # or sites-available + symlink
nginx -t && systemctl reload nginx
```

### 4. Point SOGo at itself for the new URL
On the SOGo LXC, make sure `/etc/sogo/sogo.conf` knows its external URL so
generated links/redirects are correct:

```
SOGoPageTitle = "OpenNube Mail";
WOPort = "127.0.0.1:20000";          # or 0.0.0.0:20000 if proxy is remote; firewall it
SOGoTrustProxyAuthentication = NO;
```
`systemctl restart sogo`.

### 5. Verify
- `https://email.opennube.net/` → redirects to `/SOGo` → SOGo login page.
- `https://webmail.opennube.net/` → still Roundcube. ✅ unchanged.
- Log in with a test mailbox (local Hestia password is fine until AD auth lands
  in `deployment.md` Phase 3).
- `curl -I https://email.opennube.net/SOGo` → `200`/redirect, valid TLS.

## What this does NOT do yet

- **AD login / SSO** — Phase 3 of `deployment.md` (SOGo LDAP source + Dovecot
  AD passdb). Until then SOGo authenticates against the mailbox's Hestia
  password.
- **managesieve / Rules UI** — Phase 2 (enable managesieve on Hestia's Dovecot).
- **Auto-provisioning** — the `fachex-sync` bridge (`ad-provisioning.md`).

This step is purely the front-door routing so SOGo is reachable at
`email.opennube.net` alongside Roundcube.
