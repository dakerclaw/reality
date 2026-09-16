# reality

[English](README.md) | **简体中文**

一条命令在 Linux 服务器上部署 VLESS（Reality / TLS）、TUIC、hysteria2 与 ShadowTLS。

`reality` 会用 Docker Compose 拉起一套代理栈（引擎可选 sing-box 或 xray），生成客户端配置
与二维码，并提供文本管理界面（TUI）和可选的 Telegram 机器人来管理用户。

本项目是 [reality-ezpz](https://github.com/aleskxyz/reality-ezpz) 的加固分支，在上游功能之上
额外确立两条设计准则：

1. **安装过程绝不占用知名端口。** 默认只绑定 `8443` 和 `8080`。端口 `80` 只有
   `letsencrypt` 模式会用（ACME HTTP-01 协议强制要求），且必须由你主动选择。
2. **每个组件都来自它自己的上游。** 容器镜像全部使用官方镜像（不再使用任何第三方转载镜像），
   Cloudflare WARP 直接调用 Cloudflare 官方接口注册，不再依赖社区的 `wgcf` 镜像。

---

## 功能特性

* 自动安装并配置 Docker 与 Compose 插件
* 引擎可选 `sing-box` / `xray`，TLS 可选 `reality` / `letsencrypt` / `selfsigned`
* 传输协议：`tcp`、`http`、`grpc`、`ws`、`tuic`、`hysteria2`、`shadowtls`
* 多用户，每用户独立 UUID / 密码，输出客户端链接与二维码
* Cloudflare WARP 出口（支持免费版与 WARP+ 授权），不引入任何额外镜像
* 通过 certbot 申请与自动续期 Letsencrypt 证书
* 可选「安全上网」模式（拦截广告 / 恶意域名，sing-box 还可拦截成人内容）
* 文本管理界面（TUI）与 Telegram 机器人管理用户
* 支持密码保护的备份与恢复（用户 + 配置）
* 内核参数调优、IPv6 支持，`tcp` / `http` / `grpc` / `ws` 由 haproxy 复用端口

---

## 环境要求

* Linux，包管理器为 `apt`（Debian / Ubuntu）或 `yum`（RHEL 系）；其他发行版只要具备
  `curl`、`openssl`、`jq`、`qrencode`、`whiptail`、`zip`/`unzip` 以及带 Compose 插件的
  Docker 也能运行
* 架构 `x86_64` 或 `arm64`
* root 权限
* 公网 IP；若要用 `letsencrypt` 还需要一个域名

---

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality-ezpz.sh)
```

安装脚本会把全部内容写入 `/opt/reality-ezpz`，启动服务栈，输出第一个客户端配置，并在需要时
打开 TUI。

常见用法：

```bash
# 使用默认配置安装（reality + sing-box，主端口 8443，HTTP 端口 8080）
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality-ezpz.sh)

# 自定义端口
bash <(curl -fsSL .../reality-ezpz.sh) --port 2087 --http-port off

# 使用 letsencrypt 证书（这是唯一会占用 80 端口的模式）
bash <(curl -fsSL .../reality-ezpz.sh) --security letsencrypt --server vpn.example.com

# 之后随时打开管理菜单
bash /opt/reality-ezpz/reality-ezpz.sh --menu
```

---

## 端口策略

这是与上游差异最大的部分。

| 监听用途 | 默认宿主端口 | 由谁控制 | 说明 |
| --- | --- | --- | --- |
| 主代理端口 | `8443/tcp`（tuic / hysteria2 另加 `/udp`） | `--port` | 可为任意空闲端口；`80` 会被拒绝，`443` 允许但会提示 |
| 明文 HTTP 侧 | `8080/tcp` | `--http-port` | reality / shadowtls 的伪装回退；设为 `off` 则完全不监听 |
| ACME 校验 | `80/tcp` | 强制 | **仅** `--security=letsencrypt` 模式使用 |

需要了解的行为：

* 默认安装只发布 `8443/tcp` 与 `8080/tcp`，此外不占用任何端口。本机继续在 `80`/`443`
  上运行 Nginx 等 Web 服务不受影响。
* `--http-port off` 会彻底去掉明文 HTTP 监听（最小暴露面）。
* 选择 `--security letsencrypt` 时脚本会把 HTTP 端口切到 `80` 并明确提示，因为 ACME
  HTTP-01 校验只能走 80 端口；切回 `reality` / `selfsigned` 后会自动恢复为 `8080`。
* 如果显式指定 `--port 443`，脚本仍会尊重你的选择（只提示、不阻止）——这是使用者的决定，
  不由安装器替你决定。

---

## 只使用官方源

| 组件 | 镜像 | 来源 |
| --- | --- | --- |
| xray 引擎 | `ghcr.io/xtls/xray-core:25.12.8` | GHCR，XTLS 官方发布 |
| sing-box 引擎 | `ghcr.io/sagernet/sing-box:v1.12.23` | GHCR，SagerNet 官方发布 |
| nginx | `nginx:1.24.0` | Docker Hub 官方 library |
| haproxy | `haproxy:2.8.0` | Docker Hub 官方 library |
| certbot | `certbot/certbot:v2.6.0` | Docker Hub 官方 certbot 镜像 |
| Telegram 机器人基础镜像 | `python:3.11-alpine` | Docker Hub 官方 library |

引擎容器始终显式声明 `command`（`run -c /etc/<core>/config.json`），因此不依赖镜像自带的
默认 `CMD`，换镜像也不会跑错配置。

其他来源：

* Docker 由 `https://get.docker.com` 安装，Compose 取自官方 `docker/compose` 仓库的
  release 产物。
* `tgbot.py` 以及放在 `/opt/reality-ezpz` 下的本脚本副本都从本仓库拉取；机器人优先使用
  本地副本，仅在缺失时才联网下载。
* 路由规则集来自 SagerNet 官方 `sing-geosite` 仓库；私有地址段直接内联写进生成的配置，
  不再下载第三方 geoip 文件。
* Cloudflare WARP 直接调用官方 `api.cloudflareclient.com/v0a1922` 接口，密钥对由本机
  OpenSSL 生成，磁盘上不再出现 `wgcf` 的 `.toml` 文件。

以下两个网络依赖不是本项目自有，可以自行重定向：

| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| `BACKUP_UPLOAD_URL` | `https://temp.sh/upload` | `--backup` 上传加密备份的目标地址 |
| `RULESET_BASE_URL` | 社区 `sing-box-rules` 镜像 | `bypass` 规则集，上游没有对应官方文件 |

```bash
BACKUP_UPLOAD_URL=https://files.example.com/upload \
RULESET_BASE_URL=https://rules.example.com/sing-box \
  bash /opt/reality-ezpz/reality-ezpz.sh
```

---

## 命令行参数

| 参数 | 说明 |
| --- | --- |
| `-t, --transport <tcp\|http\|grpc\|ws\|tuic\|hysteria2\|shadowtls>` | 传输协议（默认 `tcp`） |
| `-d, --domain <domain>` | Reality 握手使用的 SNI 域名（默认 `www.google.com`） |
| `--server <server>` | 本机公网 IP 或域名；使用 `letsencrypt` 时必须是域名 |
| `--port <port>` | 主代理端口（默认 `8443`） |
| `--http-port <port\|off>` | 明文 HTTP 侧端口（默认 `8080`，`off` 表示不监听） |
| `-c, --core <xray\|sing-box>` | 引擎（默认 `sing-box`） |
| `--security <reality\|letsencrypt\|selfsigned>` | TLS 模式（默认 `reality`） |
| `--enable-safenet <true\|false>` | 拦截广告 / 恶意域名，sing-box 下还会拦截成人内容 |
| `--enable-warp <true\|false>` | 出口流量走 Cloudflare WARP |
| `--warp-license <license>` | WARP+ 授权码 |
| `--regenerate` | 重新生成 Reality 密钥与 short id |
| `--restart` | 重启服务栈 |
| `--default` | 恢复默认配置 |
| `--show-server-config` | 打印服务端配置 |
| `--add-user <username>` | 新增用户 |
| `--list-users` | 列出全部用户 |
| `--show-user <username>` | 打印某用户的客户端链接与二维码 |
| `--delete-user <username>` | 删除用户 |
| `--enable-tgbot <true\|false>` | 启用 Telegram 机器人 |
| `--tgbot-token <token>` | Telegram 机器人 Token |
| `--tgbot-admins <user1,user2>` | 允许使用机器人的 Telegram 用户名（不带 `@`） |
| `--backup` | 创建并上传备份 |
| `--restore <url\|file>` | 从备份恢复 |
| `--backup-password <password>` | 为备份设置密码 |
| `-m, --menu` | 打开 TUI |
| `-u, --uninstall` | 卸载服务栈与 `/opt/reality-ezpz` |
| `-h, --help` | 查看帮助 |

---

## 用户管理

```bash
bash /opt/reality-ezpz/reality-ezpz.sh --add-user john
bash /opt/reality-ezpz/reality-ezpz.sh --show-user john   # 客户端链接 + 二维码
bash /opt/reality-ezpz/reality-ezpz.sh --list-users
bash /opt/reality-ezpz/reality-ezpz.sh --delete-user john
```

用户名只允许字母与数字（`A-Z`、`a-z`、`0-9`）。

## Telegram 机器人

```bash
bash /opt/reality-ezpz/reality-ezpz.sh \
  --enable-tgbot true \
  --tgbot-token 123456789:AA... \
  --tgbot-admins your_telegram_username
```

机器人运行在独立容器中，挂载 `/opt/reality-ezpz`，并以 argv 列表方式调用本地脚本副本——
来自按钮的用户名不可能被当作 shell 命令执行。支持的命令：`/start`、`/add`、`/delete`、
`/list`、`/show`。

请注意：该容器挂载了 Docker socket，实际权限等同于宿主机 root，不需要远程管理用户时建议
不要开启。

## Cloudflare WARP

```bash
bash /opt/reality-ezpz/reality-ezpz.sh --enable-warp true
bash /opt/reality-ezpz/reality-ezpz.sh --enable-warp true --warp-license XXXXXXXX-XXXXXXXX-XXXXXXXX
```

注册过程会向 Cloudflare 申请一个免费 WARP 设备，把设备 id、token、client id、接口地址以及
本机生成的私钥写入 `/opt/reality-ezpz/config`，并作为引擎出口使用。关闭 WARP 时会在
Cloudflare 侧删除该设备。

## 备份与恢复

```bash
# 上传加密备份，输出下载地址
bash /opt/reality-ezpz/reality-ezpz.sh --backup --backup-password '一个强密码'

# 在本机或其他机器上恢复
bash /opt/reality-ezpz/reality-ezpz.sh --restore <url 或路径> --backup-password '一个强密码'
```

备份包内含用户列表与 `/opt/reality-ezpz/config`。请务必设置密码：不设密码时压缩包就是
明文的密钥集合。

## 升级

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality-ezpz.sh)
```

重复执行安装脚本会保留原有配置，缺失的配置项（例如新引入的 `http_port`）会自动补上。
如果你之前部署的版本把主端口固定在 `443`，请注意当前默认值已改为 `8443`，明文 HTTP 侧也从
`80` 变为 `8080`；如需保持旧布局，请显式传入 `--port 443`。

## 卸载

```bash
bash /opt/reality-ezpz/reality-ezpz.sh --uninstall   # 不会卸载 Docker 本身
```

---

## 安全说明

* Reality 的设计目标是让人无法把它与真实 TLS 站点区分开；SNI 域名与端口要符合你的威胁模型。
* 生成的客户端配置包含服务器地址、UUID 与 Reality 公钥，请把 `--show-user` 的输出当作机密。
* `--enable-tgbot` 会赋予机器人容器 Docker socket 权限，不需要远程管理时请保持关闭。
* 备份默认上传到公共粘贴服务，请配合 `--backup-password` 使用，或把 `BACKUP_UPLOAD_URL`
  指向你自己的服务器。
* 请只在你掌控的机器上以 root 运行安装脚本：它会安装软件包、写入 `/opt` 并调整内核参数。

---

## 常见问题

| 现象 | 排查方向 |
| --- | --- |
| 提示 `Port 80 must be free ...` | 你选择了 `letsencrypt`，但 80 端口已被其他服务占用 |
| 容器反复重启 | `docker logs $(docker compose -p reality-ezpz ps -q engine)` |
| 客户端连不上 | 主端口是否放行（防火墙 / 安全组），SNI 域名是否匹配 |
| 提示 `WARP account creation has been failed!` | 能否访问 `api.cloudflareclient.com` |
| Telegram 机器人无响应 | Token / 管理员名单是否正确，`/opt/reality-ezpz/tgbot/tgbot.py` 是否存在 |
| xray 容器启动即退出 | 官方镜像会降权运行，证书文件必须可读（安装脚本已 chmod 到 `644`） |

---

## 致谢与许可

本项目基于 [aleskxyz](https://github.com/aleskxyz) 的
[reality-ezpz](https://github.com/aleskxyz/reality-ezpz)，遵循 Apache License 2.0；
本分支沿用同一许可，详见 [LICENSE](LICENSE)。

运行时使用的上游项目：
[XTLS/Xray-core](https://github.com/XTLS/Xray-core)、
[SagerNet/sing-box](https://github.com/SagerNet/sing-box)、
[SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite)、
[haproxy](https://www.haproxy.org/)、[nginx](https://nginx.org/)、
[certbot](https://github.com/certbot/certbot)。
