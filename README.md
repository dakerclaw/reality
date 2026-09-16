# reality

**English** | [简体中文](README.zh-CN.md)

Install and configure VLESS (Reality / TLS), TUIC, hysteria2 and ShadowTLS on your
Linux server with a single command.

`reality` builds a Docker Compose stack (sing-box or xray engine) in front of a
TLS-terminating proxy, generates the client configuration and QR codes, and gives
you a TUI plus an optional Telegram bot to manage users.

It is a hardened fork of [reality-ezpz](https://github.com/aleskxyz/reality-ezpz)
with two design rules on top of the upstream feature set:

1. **An installation never takes a well-known port.** The default setup binds
   `8443` and `8080`. Port `80` is used by exactly one mode — `letsencrypt`, which
   the ACME HTTP-01 challenge forces — and only when you ask for it.
2. **Every component comes from its own upstream.** Container images are the
   official ones (no third-party re-published images), and Cloudflare WARP is
   registered directly against the Cloudflare client API instead of through a
   community `wgcf` image.

---

## Features

* Docker + Compose installed and configured automatically
* `sing-box` or `xray` engine, `reality`, `letsencrypt` or `selfsigned` TLS
* Transports: `tcp`, `http`, `grpc`, `ws`, `tuic`, `hysteria2`, `shadowtls`
* Multi-user with per-user UUID/password, client links and QR codes
* Cloudflare WARP outbound (free and WARP+ license), zero extra images
* Letsencrypt certificate issuance and renewal through certbot
* Optional "safe internet" mode (blocks ads/malware, optionally adult content)
* Text-based user interface and Telegram bot for user management
* Password-protected backup / restore of users and configuration
* Kernel tunables, IPv6 support, `tcp`/`http`/`grpc`/`ws` multiplexing behind haproxy

---

## Requirements

* Linux with `apt` (Debian/Ubuntu) or `yum` (RHEL family) — anything else works as
  long as `curl`, `openssl`, `jq`, `qrencode`, `whiptail`, `zip`/`unzip` and Docker
  with the Compose plugin are available
* `x86_64` or `arm64`
* Root access
* A public IP; a domain name as well if you want `letsencrypt`

---

## Quick start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality-ezpz.sh)
```

The installer writes everything to `/opt/reality-ezpz`, starts the stack, prints
the first client configuration and opens the TUI on demand.

Common invocations:

```bash
# plain install with defaults (reality, sing-box, port 8443, http port 8080)
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality-ezpz.sh)

# pick your own ports
bash <(curl -fsSL .../reality-ezpz.sh) --port 2087 --http-port off

# letsencrypt certificate (this mode is the only one that binds port 80)
bash <(curl -fsSL .../reality-ezpz.sh) --security letsencrypt --server vpn.example.com

# open the management menu later
bash /opt/reality-ezpz/reality-ezpz.sh --menu
```

---

## Port policy

This is the part that differs most from the upstream project.

| Listener | Default host port | Controlled by | Notes |
| --- | --- | --- | --- |
| Main proxy port | `8443/tcp` (and `/udp` for tuic/hysteria2) | `--port` | Any free port; `80` is refused, `443` is allowed but warns |
| Plain HTTP side | `8080/tcp` | `--http-port` | Reality/ShadowTLS camouflage fallback; `off` leaves it unpublished |
| ACME challenge | `80/tcp` | forced | **Only** in `--security=letsencrypt` mode |

Behaviour worth knowing:

* A default installation publishes `8443/tcp` and `8080/tcp` and nothing else.
  Running a web server on `80`/`443` next to it is fine.
* `--http-port off` removes the HTTP listener completely (minimal footprint).
* Selecting `--security letsencrypt` switches the HTTP port to `80` and says so,
  because the ACME HTTP-01 challenge has no other port. Switching back to
  `reality`/`selfsigned` resets it to `8080` automatically.
* Explicitly asking for `443` with `--port` is still honoured (the warning is only
  a warning) — that is the user's call, not the installer's.

---

## Official sources only

| Component | Image | Registry |
| --- | --- | --- |
| xray engine | `ghcr.io/xtls/xray-core:25.12.8` | GHCR, published by XTLS |
| sing-box engine | `ghcr.io/sagernet/sing-box:v1.12.23` | GHCR, published by SagerNet |
| nginx | `nginx:1.24.0` | Docker Hub official library |
| haproxy | `haproxy:2.8.0` | Docker Hub official library |
| certbot | `certbot/certbot:v2.6.0` | Docker Hub, official certbot image |
| Telegram bot base | `python:3.11-alpine` | Docker Hub official library |

The engine container always runs with an explicit `command`
(`run -c /etc/<core>/config.json`), so the deployment does not depend on an
image's default `CMD`.

Other sources:

* Docker is installed from `https://get.docker.com`, Compose from the official
  `docker/compose` GitHub release.
* `tgbot.py` and the copy of this script placed in `/opt/reality-ezpz` are pulled
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
  bash /opt/reality-ezpz/reality-ezpz.sh
```

---

## Command line reference

| Option | Description |
| --- | --- |
| `-t, --transport <tcp\|http\|grpc\|ws\|tuic\|hysteria2\|shadowtls>` | Transport protocol (default `tcp`) |
| `-d, --domain <domain>` | SNI domain used for the Reality handshake (default `www.google.com`) |
| `--server <server>` | Public IP or domain of this machine; a domain is required for `letsencrypt` |
| `--port <port>` | Main proxy port (default `8443`) |
| `--http-port <port\|off>` | Plain HTTP side (default `8080`, `off` = unpublished) |
| `-c, --core <xray\|sing-box>` | Engine (default `sing-box`) |
| `--security <reality\|letsencrypt\|selfsigned>` | TLS mode (default `reality`) |
| `--enable-safenet <true\|false>` | Block ads/malware, plus adult content on sing-box |
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
| `--tgbot-admins <user1,user2>` | Telegram usernames allowed to use the bot (no `@`) |
| `--backup` | Create and upload a backup archive |
| `--restore <url\|file>` | Restore from a backup |
| `--backup-password <password>` | Password-protect the backup |
| `-m, --menu` | Open the TUI |
| `-u, --uninstall` | Remove the stack and `/opt/reality-ezpz` |
| `-h, --help` | Show help |

---

## User management

```bash
bash /opt/reality-ezpz/reality-ezpz.sh --add-user john
bash /opt/reality-ezpz/reality-ezpz.sh --show-user john   # client link + QR code
bash /opt/reality-ezpz/reality-ezpz.sh --list-users
bash /opt/reality-ezpz/reality-ezpz.sh --delete-user john
```

Usernames must be alphanumeric (`A-Z`, `a-z`, `0-9`).

## Telegram bot

```bash
bash /opt/reality-ezpz/reality-ezpz.sh \
  --enable-tgbot true \
  --tgbot-token 123456789:AA... \
  --tgbot-admins your_telegram_username
```

The bot runs in its own container, mounts `/opt/reality-ezpz` and executes the
locally mounted copy of this script with an argv list — a username coming from a
button can never be interpreted as a shell command. Bot commands: `/start`,
`/add`, `/delete`, `/list`, `/show`.

Note that the bot container mounts the Docker socket and therefore effectively has
root-equivalent permissions. Enable it only if you need it.

## Cloudflare WARP

```bash
bash /opt/reality-ezpz/reality-ezpz.sh --enable-warp true
bash /opt/reality-ezpz/reality-ezpz.sh --enable-warp true --warp-license XXXXXXXX-XXXXXXXX-XXXXXXXX
```

Registration creates a free WARP device against Cloudflare, stores the device id,
token, client id, interface addresses and the locally generated private key in
`/opt/reality-ezpz/config`, and uses the device as the engine's outbound. Turning
WARP off deletes the device on Cloudflare's side.

## Backup and restore

```bash
# upload an encrypted archive, prints a URL
bash /opt/reality-ezpz/reality-ezpz.sh --backup --backup-password 'a strong password'

# restore on this or another machine
bash /opt/reality-ezpz/reality-ezpz.sh --restore <url-or-path> --backup-password 'a strong password'
```

The archive contains the user list and `/opt/reality-ezpz/config`. Always use a
password: without one the archive is a plain zip of your keys.

## Upgrade

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality-ezpz.sh)
```

Re-running the installer keeps the existing configuration; missing keys (for
example the new `http_port`) are added automatically. If you deployed an earlier
version that pinned the main port to `443`, note that the default is now `8443`
and the plain HTTP side moved from `80` to `8080` — set `--port 443` explicitly if
you want to keep the old layout.

## Uninstall

```bash
bash /opt/reality-ezpz/reality-ezpz.sh --uninstall   # keeps the Docker packages
```

---

## Security notes

* Reality is designed to be indistinguishable from a real TLS site; keep the SNI
  domain and the port realistic for your threat model.
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
| Container restarts in a loop | `docker logs $(docker compose -p reality-ezpz ps -q engine)` |
| Client cannot connect | The main port is reachable (firewall/security group), and the SNI domain matches |
| `WARP account creation has been failed!` | Outbound access to `api.cloudflareclient.com` |
| Telegram bot silent | Token/admins correct, and `/opt/reality-ezpz/tgbot/tgbot.py` exists |
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
