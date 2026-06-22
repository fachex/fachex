# Stand up the SOGo container (do this first)

This is **Phase 1** — the SOGo LXC must exist and answer on `:20000` before the
`email.opennube.net` nginx vhost has anything to talk to.

Scripts (pre-filled for opennube):
- `deploy/proxmox/create-sogo-lxc.sh` — create the Debian 12 LXC on Proxmox.
- `deploy/sogo/install-sogo.sh` — install SOGo + PostgreSQL + memcached inside it.
- `deploy/sogo/sogo.conf` — config template (rendered by the installer).

## 1. Create the container (on a Proxmox node)

Edit the vars at the top of `create-sogo-lxc.sh` (CTID, IP, storage, bridge),
then:

```bash
bash deploy/proxmox/create-sogo-lxc.sh
```

Defaults: CTID 150, 2 vCPU, 4 GB RAM, 20 GB disk, IP `10.0.0.50/24`. Verify the
exact Debian 12 template name with `pveam available | grep debian-12` if the
download step complains.

## 2. Install SOGo (push scripts into the container, run installer)

```bash
pct push 150 deploy/sogo/install-sogo.sh /root/install-sogo.sh
pct push 150 deploy/sogo/sogo.conf       /root/sogo.conf.tmpl
pct exec 150 -- bash /root/install-sogo.sh
```

The installer:
- adds the SOGo v5 repo and installs `sogo` + `sope4.9-gdl1-postgresql` + memcached,
- creates the `sogo` PostgreSQL role/DB (random password, written into the conf),
- renders `/etc/sogo/sogo.conf` from the template,
- sets 5 workers and starts the `sogo` service.

> The repo URL/GPG fingerprint in the installer can change between SOGo
> releases — if the apt step fails, cross-check the current values in the
> official SOGo install docs and update `install-sogo.sh`.

## 3. Smoke test (before nginx, before AD)

From a host on the LAN:

```bash
curl -I http://10.0.0.50:20000/SOGo      # expect 200/redirect
```

At this point SOGo runs but isn't usable end-to-end yet — it still needs the
mail backend (step 4) and AD bind (step 5).

## 4. Point SOGo at Hestia's mail (Phase 2)

Edit `/etc/sogo/sogo.conf` in the container:
- set `MAILHOST` in `SOGoIMAPServer` / `SOGoSMTPServer` / `SOGoSieveServer` to
  your Hestia server.
On Hestia, enable **managesieve** and allow the SOGo LXC IP to reach 993/587/4190
(see `docs/deployment.md` Phase 2). Then `systemctl restart sogo`.

## 5. Wire AD auth + the opennube.net mailbox mapping (Phase 3)

- Fill `bindPassword` for `svc-mail` in `SOGoUserSources`.
- On Hestia's Dovecot: add the AD LDAP `passdb` matching `sAMAccountName` via
  `%n`, and set `auth_default_realm = opennube.net` so the bare AD username
  resolves to `<user>@opennube.net` (see `docs/opennube-config.md`).
- `systemctl restart sogo` and restart Dovecot.

## 6. Put it behind nginx

Now `deploy/nginx/email.opennube.net.conf` has a live backend — follow
`docs/email-vhost-setup.md`. `webmail.*` stays on Roundcube throughout.

## Firewall reminder

`tcp/20000` on the SOGo LXC should be reachable **only** from the nginx proxy
IP. Don't expose it publicly.
