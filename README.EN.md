# reality

**English** | [简体中文](README.md)

Install and configure VLESS (Reality / TLS), TUIC, hysteria2 and ShadowTLS on your
Linux server with a single command.

`reality` builds a Docker Compose stack (sing-box or xray engine) in front of a
TLS-terminating proxy, generates the client configuration and QR codes, and gives
you a TUI plus an optional Telegram bot to manage users.

It is a hardened fork of [reality-ezpz](https://github.com/aleskxyz/reality-ezpz)
with three design rules on top of the upstream feature set:

1. **An installation never takes a well-known port.** The default setup binds
   `8443` and `8080`. Port `80` is used by exactly one mode — `letsencrypt`, which
   the ACME HTTP-01 challenge forces — and only when you ask for it.
2. **Every component comes from its own upstream.** Container images are the
   official ones, and Cloudflare WARP is registered directly against the
   Cloudflare client API.
3. **Camouflage target and website are separate.** The proxy port falls back to a
   real **remote** site, which is set automatically at deployment, while nginx
   serves **your own** site on the HTTP port. See
   [Website and camouflage](#website-and-camouflage).

---

## Features

* Docker + Compose installed and configured automatically
* `sing-box` or `xray` engine (default `sing-box`); `reality`, `letsencrypt` or
  `selfsigned` TLS (default `reality`)
* Transports: `tcp`, `http`, `grpc`, `ws`, `tuic`, `hysteria2`, `shadowtls`
  (default `tcp`)
* Multi-user with per-user UUID/password, client links and QR codes
* Cloudflare WARP outbound (free and WARP+ license), zero extra images
* BBR congestion control switched on automatically (`tcp_bbr` + the `fq` qdisc,
  written to `/etc/sysctl.d`), plus kernel socket/backlog tunables
* Letsencrypt certificate issuance and renewal through certbot
* Optional "safe internet" mode (blocks ads/malware, optionally adult content)
* Text-based user interface and Telegram bot for user management
* nginx serves your own site from `./website` on the HTTP port (`reality`/`shadowtls`
  fall back to a remote site instead, never to your own site)
* Password-protected backup / restore of users and configuration
* Kernel tunables, IPv6 support, `tcp`/`http`/`grpc`/`ws` multiplexing behind haproxy

---

## Requirements

* Linux with `apt` (Debian/Ubuntu) or `yum` (RHEL family) — anything else works as
  long as `curl`, `openssl`, `jq`, `qrencode`, `whiptail`, `zip`/`unzip` and Docker
  with the Compose plugin are available
* `x86_64` or `arm64`
* Root access
* A public IP. **A domain of your own is not required** — see
  [Do I need my own domain?](#do-i-need-my-own-domain). One is needed only for
  `letsencrypt`.
* Linux 4.9 or newer if you want BBR — older kernels are still fine, BBR is
  skipped with a warning there (see
  [Kernel tuning and BBR](#kernel-tuning-and-bbr))

---

## Quick start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh)
```

The installer writes everything to `/opt/reality`, starts the stack, prints
the first client configuration and opens the TUI on demand. It also places **a
copy of this script itself at `/opt/reality/reality.sh`**, which is what
every later management command runs; because that copy lives in the configuration
directory, each run refreshes it to the current version. This has nothing to do
with the Telegram bot being enabled — the bot merely mounts the same directory.

Common invocations:

```bash
# plain install with defaults (reality, sing-box, port 8443, website on 8080)
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh)

# name the remote site the camouflage falls back to (also becomes the SNI)
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh) \
  --camouflage www.microsoft.com

# pick your own ports, no website at all
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh) \
  --port 2087 --http-port off

# letsencrypt certificate (this mode is the only one that binds port 80)
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh) \
  --security letsencrypt --server vpn.example.com

# open the management menu later
bash /opt/reality/reality.sh --menu
```

---

## Port policy

| Listener | Default host port | Controlled by | Notes |
| --- | --- | --- | --- |
| Main proxy port | `8443/tcp` (and `/udp` for tuic/hysteria2) | `--port` | Any free port; `80` is refused, `443` is allowed but warns |
| Local website | `8080/tcp` | `--http-port` | Served by nginx out of `./website`; `off` leaves it unpublished |
| ACME challenge | `80/tcp` | forced | **Only** in `--security=letsencrypt` mode |

Behaviour worth knowing:

* A default installation publishes `8443/tcp` and `8080/tcp` and nothing else.
  Running a web server on `80`/`443` next to it is fine.
* `--http-port off` removes the HTTP listener and the nginx container completely
  (minimal footprint).
* Selecting `--security letsencrypt` switches the HTTP port to `80` and says so,
  because the ACME HTTP-01 challenge has no other port. Switching back to
  `reality`/`selfsigned` resets it to `8080` automatically.
* Explicitly asking for `443` with `--port` is still honoured (the warning is only
  a warning) — that is the user's call, not the installer's.

---

## Website and camouflage

Two different jobs, deliberately kept apart:

| | What it is | Where it lives |
| --- | --- | --- |
| **Camouflage** | What an unauthenticated probe sees on the proxy port. In `reality` the engine forwards the TLS handshake to a real remote site instead of answering it itself; in `shadowtls` the handshake server is that site. | `--camouflage <domain[:port]>`, a real remote site, set automatically at deployment |
| **Website** | A normal site of your own, served by nginx from `./website`. | `--http-port <port>` |

```bash
# camouflage = www.microsoft.com, own site on 8080
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh) \
  --camouflage www.microsoft.com

# serve your own site: drop files into the docroot, nothing else to do
ls /opt/reality/config/website
```

Notes:

* `--camouflage` defaults to `www.fastly.com` and also sets the SNI, because a
  probe sends the SNI and compares the certificate it gets back against it. Set
  `--domain` as well only if you deliberately want them to differ, and expect a
  warning if you do: a mismatch is visible to an active probe.
* REALITY's documented minimum for a target site is **TLS 1.3 + H2**, so qualify
  a candidate before relying on it — `openssl s_client -connect <host>:443
  -servername <host> -tls1_3 -alpn h2 </dev/null | grep ALPN` has to answer
  `ALPN protocol: h2`, and the same command without `-alpn` has to negotiate
  `TLSv1.3`. The shipped default clears both, and so do `www.microsoft.com`,
  `www.apple.com` and `www.cloudflare.com`. A site that answers `http/1.1`
  instead (Akamai's own front page, for one) sits below that minimum: the ALPN
  it advertises does not match what the site it claims to be would offer.
* Upgrading from a version without `--camouflage` carries the old `domain` value
  over to it, so the fallback target does not change under your feet.
* The first run writes a neutral placeholder page to
  `/opt/reality/config/website/index.html`. **An existing file is never
  overwritten** — put your own site there and it survives upgrades.
* In the `reality`/`shadowtls` modes this website is the whole HTTP surface;
  nothing is relayed to the remote camouflage site over plain HTTP anymore.

---

## Do I need my own domain?

No. The default mode never uses a domain you own, and since this fork serves your
own website through nginx, you do not need one for that either.

| Mode | Own domain needed? | What the handshake carries |
| --- | --- | --- |
| `reality` (default) | No | The SNI is the **remote** camouflage site (`--camouflage`, default `www.fastly.com`), and a probe gets that site's real certificate back |
| `shadowtls` transport | No | The handshake server is the remote camouflage site as well |
| `selfsigned` | Not strictly | A self-signed certificate; clients must accept an untrusted one (`allow_insecure`/`insecure=1`), which an active probe can notice |
| `letsencrypt` | **Yes** | A publicly trusted certificate for your own domain — ACME HTTP-01 needs that domain to resolve to this machine and needs port `80` |

So for a plain IP-only box there is nothing to name at all:

```bash
# reality + sing-box, camouflage defaults to www.fastly.com — nothing to supply
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh)

# still no domain, but choose what a probe will see instead
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh) \
  --camouflage www.microsoft.com
```

* No DNS record to create and no certificate to issue locally: in the
  `reality`/`shadowtls` modes the engine relays the handshake to the remote site
  instead of terminating it, so no `server.crt`/`server.key` is generated and
  nothing is mounted into the engine container.
* `--server` accepts a bare public IP as long as `letsencrypt` is not in play; the
  address is auto-detected when it can be, and only then does an empty value abort
  the install with a hint.
* `ws`, `tuic` and `hysteria2` are refused together with `reality` (they need real
  TLS termination). Without a domain the useful combinations are `reality` with
  `tcp`/`http`/`grpc`, or the `shadowtls` transport.
* The trade-off is that you are borrowing someone else's domain: pick a site that
  is reachable from **both** the server and the client, with an ordinary-looking
  TLS stack. See [Security notes](#security-notes).

---

## Official sources only

| Component | Image | Registry |
| --- | --- | --- |
| xray engine | `ghcr.io/xtls/xray-core:26.3.27` | GHCR, published by XTLS |
| sing-box engine | `ghcr.io/sagernet/sing-box:v1.14.1` | GHCR, published by SagerNet |
| nginx | `nginx:1.30.5` | Docker Hub official library |
| haproxy | `haproxy:3.4.4` | Docker Hub official library |
| certbot | `certbot/certbot:v5.8.0` | Docker Hub, official certbot image |
| Telegram bot base | `python:3.14-alpine` | Docker Hub official library |

Every image is pinned to the newest **stable** release of its project, never to a
floating tag such as `latest`, so two servers installed months apart run exactly
the same code. For xray, everything from v26.4 on is flagged pre-release
upstream, so the last official release is pinned instead. When bumping an image,
change `image[]` at the top of `reality.sh` and this table together.

The engine container always runs with an explicit `command`
(`run -c /etc/<core>/config.json`), so the deployment does not depend on an
image's default `CMD`.

Other sources:

* Docker is installed from `https://get.docker.com`, Compose from the official
  `docker/compose` GitHub release.
* `tgbot.py` and the copy of this script placed in `/opt/reality` are pulled
  from this repository; the bot prefers the local copy and only downloads when it
  is missing.
* Route rule sets come from SagerNet's official `sing-geosite` repository. The
  private destination ranges are inlined in the generated configuration instead of
  being downloaded.
* Cloudflare WARP registration uses the official
  `api.cloudflareclient.com/v0a1922` endpoint with a locally generated X25519 key
  pair (OpenSSL). There is no `wgcf` image and no `.toml` file on disk.

Two network dependencies are not first-party and can be redirected:

| Variable | Default | Purpose |
| --- | --- | --- |
| `BACKUP_UPLOAD_URL` | `https://temp.sh/upload` | Where `--backup` uploads the encrypted archive |
| `RULESET_BASE_URL` | community `sing-box-rules` mirror | The `bypass` rule set, which has no upstream equivalent |

```bash
BACKUP_UPLOAD_URL=https://files.example.com/upload \
RULESET_BASE_URL=https://rules.example.com/sing-box \
  bash /opt/reality/reality.sh
```

---

## Command line reference

| Option | Description |
| --- | --- |
| `-t, --transport <tcp\|http\|grpc\|ws\|tuic\|hysteria2\|shadowtls>` | Transport protocol (default `tcp`) |
| `-d, --domain <domain>` | SNI domain used for the Reality handshake (default follows `--camouflage`) |
| `--camouflage <domain[:port]>` | Remote site unauthenticated probes are relayed to, in the `reality`/`shadowtls` modes (default `www.fastly.com`; port defaults to `443`) |
| `--server <server>` | Public IP or domain of this machine; a domain is required for `letsencrypt` |
| `--port <port>` | Main proxy port (default `8443`) |
| `--http-port <port\|off>` | Host port of the local website served by nginx (default `8080`, `off` = unpublished) |
| `-c, --core <xray\|sing-box>` | Engine (default `sing-box`) |
| `--security <reality\|letsencrypt\|selfsigned>` | TLS mode (default `reality`) |
| `--enable-safenet <true\|false>` | Block ads/malware, plus adult content on sing-box |
| `--enable-bbr <true\|false>` | Enable the BBR congestion control and the `fq` qdisc (default `true`; skipped with a warning on kernels that lack BBR) |
| `--enable-warp <true\|false>` | Route outbound traffic through Cloudflare WARP |
| `--warp-license <license>` | WARP+ license key |
| `--regenerate` | Regenerate Reality keys and short id |
| `--restart` | Restart the stack |
| `--default` | Reset to the default configuration |
| `--show-server-config` | Print the server side configuration |
| `--add-user <username>` | Add a user |
| `--list-users` | List users |
| `--show-user <username>` | Print the client link and QR code of a user |
| `--delete-user <username>` | Delete a user |
| `--enable-tgbot <true\|false>` | Enable the Telegram bot |
| `--tgbot-token <token>` | Telegram bot token |
| `--tgbot-admins <user1,123456789>` | Bot admins: Telegram usernames (no `@`) or numeric user ids |
| `--backup` | Create and upload a backup archive |
| `--restore <url\|file>` | Restore from a backup |
| `--backup-password <password>` | Password-protect the backup |
| `-m, --menu` | Open the TUI |
| `-u, --uninstall` | Remove the stack and `/opt/reality` |
| `-h, --help` | Show help |

---

## User management

```bash
bash /opt/reality/reality.sh --add-user john
bash /opt/reality/reality.sh --show-user john   # client link + QR code
bash /opt/reality/reality.sh --list-users
bash /opt/reality/reality.sh --delete-user john
```

Usernames must be alphanumeric (`A-Z`, `a-z`, `0-9`).

## Telegram bot

```bash
bash /opt/reality/reality.sh \
  --enable-tgbot true \
  --tgbot-token 123456789:AA... \
  --tgbot-admins your_telegram_username,123456789
```

The bot runs in its own container, mounts `/opt/reality` and executes the
locally mounted copy of this script with an argv list — a username coming from a
button can never be interpreted as a shell command. The only command is `/start`,
which lists the three buttons; viewing, adding and deleting users go through that
menu.

Note that the bot container mounts the Docker socket and therefore effectively has
root-equivalent permissions. Enable it only if you need it.

### Admin list: username or numeric id

Every entry of `--tgbot-admins` is either a Telegram username or the numeric id of
the account. Separate them with `,` and no spaces; the two forms can be mixed.

| Form | Example | Rule |
|---|---|---|
| Telegram username | `dakerjie` | No `@`; 5-32 characters, starts with a letter, letters/digits/underscores only, may not end with `_` |
| Numeric id | `123456789` | The permanent account number, 4-15 digits |

**An account that never picked a username can only be authorised by its numeric
id.** A username is optional in Telegram, can be changed at any time and may be
recycled by somebody else once released; the numeric id is bound to the account
for good and is never reused, so it is the safer choice. Both forms are compared
when a caller is checked, and usernames are matched **case-insensitively**.

### How to find your numeric id

Any of these takes about 30 seconds:

1. **@userinfobot** (recommended): open https://t.me/userinfobot and press Start
   (or send it anything). The line starting with `Id:` in its reply is your
   numeric id.
2. **@getidsbot**: open https://t.me/getidsbot and send it a message; the digits
   after `ID:` in its reply are your numeric id.
3. **Without a third-party bot**: the bot you just created is the lookup tool.
   Send `/start` to `@your_bot` from Telegram first, then run:

   ```bash
   curl -s "https://api.telegram.org/bot<your BOT_TOKEN>/getUpdates" \
     | grep -o '"from":{"id":[0-9]*' | head -1
   ```

   The digits after `"id":` are your numeric id (that is `message.from.id`).
   Do it before the bot container starts, or stop that container first — once it
   runs it consumes the queued updates itself.

Three things worth knowing:

1. **Private chats only.** The chat itself is what gets checked: in a private chat
   it stands for your account, while in a group it is the group and you will not be
   recognised as an admin — and the client configurations, QR codes included, would
   be posted into that group.
2. **Renaming means updating the list.** The list is injected into the container as
   the `BOT_ADMIN` environment variable, so re-running the configuration is required
   for it to take effect. With a numeric id there is nothing to update.
3. **The TUI configures it too.** `bash /opt/reality/reality.sh --menu` →
   "Telegram Bot" accepts both forms in its input box.

## Cloudflare WARP

```bash
bash /opt/reality/reality.sh --enable-warp true
bash /opt/reality/reality.sh --enable-warp true --warp-license XXXXXXXX-XXXXXXXX-XXXXXXXX
```

Registration creates a free WARP device against Cloudflare, stores the device id,
token, client id, interface addresses and the locally generated private key in
`/opt/reality/config`, and uses the device as the engine's outbound. Turning
WARP off deletes the device on Cloudflare's side.

## Kernel tuning and BBR

Every run writes `/etc/sysctl.d/99-reality.conf` and applies it, so the
tuning survives reboots by being a normal sysctl drop-in. On top of the socket
buffer, backlog and conntrack values, **BBR is enabled by default**:

```ini
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

BBR lives in the kernel, so there is nothing to install from a repository — the
installer loads `tcp_bbr` and `sch_fq` and writes the two keys. What it does *not*
do is pretend: the state is read back from `/proc` and reported.

```
$ bash /opt/reality/reality.sh --show-server-config
...
BBR: ON (kernel: bbr, qdisc: fq)
```

| Situation | What happens |
| --- | --- |
| Normal kernel (4.9+) | The module is loaded, both keys are written and BBR is active immediately |
| Kernel without BBR (older than 4.9, or a container that cannot load its host's modules) | A warning is printed and **the two keys are left out of the file**, so nothing fails on every reboot afterwards. Every other tunable is still applied |
| You pass `--enable-bbr false` | The two lines are dropped from the file, and the live kernel is only reset if it was `bbr`/`fq` — a congestion control you picked yourself is never overwritten |
| The kernel rejects one key | That key is named in a warning and the remaining keys are still applied |

Because each key is written on its own, a kernel that refuses one setting can no
longer leave BBR quietly unapplied while the installer reports success.

Note that this is the **kernel** congestion control. The `hysteria2` transport
additionally advertises `congestion_control=bbr` in its QUIC configuration, which
is a client-side transport setting and is independent of this.

```bash
bash /opt/reality/reality.sh --enable-bbr false   # turn it off
bash /opt/reality/reality.sh --enable-bbr true    # turn it back on
```

---

## Backup and restore

```bash
# upload an encrypted archive, prints a URL
bash /opt/reality/reality.sh --backup --backup-password 'a strong password'

# restore on this or another machine
bash /opt/reality/reality.sh --restore <url-or-path> --backup-password 'a strong password'
```

The archive contains the user list and `/opt/reality/config`. Always use a
password: without one the archive is a plain zip of your keys.

## Upgrade

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh)
```

Re-running the installer keeps the existing configuration; missing keys (for
example `http_port` or the new `camouflage`) are added automatically, and the
script copy inside the configuration directory is refreshed too.

## Uninstall

```bash
bash /opt/reality/reality.sh --uninstall   # keeps the Docker packages
```

---

## Security notes

* Reality is designed to be indistinguishable from a real TLS site; keep the SNI
  domain and the port realistic for your threat model. The camouflage site should
  be a real, popular HTTPS site the machine can reach, and the SNI should be that
  same domain — a probe compares the certificate it gets back against the SNI it
  sent.
* The generated client configurations contain the server address, UUID and Reality
  public key — treat `--show-user` output as a secret.
* `--enable-tgbot` gives the bot container Docker socket access. If you do not need
  remote user management, leave it off.
* Backups are uploaded to a public paste service by default. Use
  `--backup-password` and/or point `BACKUP_UPLOAD_URL` at your own endpoint.
* Only run the installer as root on a machine you control; it installs packages,
  writes to `/opt` and tunes kernel parameters.

---

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `Port 80 must be free ...` | You selected `letsencrypt` while another service owns port 80 |
| Container restarts in a loop | `docker logs $(docker compose -p reality ps -q engine)` |
| Client cannot connect | The main port is reachable (firewall/security group), and the SNI domain matches |
| `WARP account creation has been failed!` | Outbound access to `api.cloudflareclient.com` |
| `BBR was requested but is not active` | The running kernel has no BBR (needs 4.9+) or is a container that cannot load its host's modules; `--enable-bbr false` silences it |
| `these kernel settings ... were skipped` | The listed keys do not exist on this kernel; the rest were applied and BBR is unaffected |
| `the SNI (...) differs from the camouflage site (...)` | You passed both `--domain` and `--camouflage`; point them at the same site unless you have a reason not to |
| The HTTP port shows the placeholder page | Put your files into `/opt/reality/config/website` — `index.html` is only created when nothing is there |
| The camouflage site is unreachable from the server | `--camouflage` must be a real site the machine can reach; nothing is served locally for it |
| Telegram bot silent | Token/admins correct, and `/opt/reality/tgbot/tgbot.py` exists |
| `xray` exits immediately | The official image drops privileges; certificate files must be readable (the installer chmods them to `644`) |

---

## Credits and license

Based on [reality-ezpz](https://github.com/aleskxyz/reality-ezpz) by
[aleskxyz](https://github.com/aleskxyz), Apache License 2.0. This fork keeps the
same license; see [LICENSE](LICENSE).

Upstream projects used at runtime:
[XTLS/Xray-core](https://github.com/XTLS/Xray-core),
[SagerNet/sing-box](https://github.com/SagerNet/sing-box),
[SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite),
[haproxy](https://www.haproxy.org/), [nginx](https://nginx.org/),
[certbot](https://github.com/certbot/certbot).
