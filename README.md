# reality

**简体中文** | [English](README.EN.md)

一条命令在 Linux 服务器上部署 VLESS（Reality / TLS）、TUIC、hysteria2 与 ShadowTLS。

`reality` 会用 Docker Compose 拉起一套代理栈（引擎可选 sing-box 或 xray），生成客户端配置
与二维码，并提供文本管理界面（TUI）和可选的 Telegram 机器人来管理用户。

本项目是 [reality-ezpz](https://github.com/aleskxyz/reality-ezpz) 的加固分支，在上游功能之上
额外确立三条设计准则：

1. **安装过程绝不占用知名端口。** 默认只绑定 `8443` 和 `8080`。端口 `80` 只有
   `letsencrypt` 模式会用（ACME HTTP-01 协议强制要求），且必须由你主动选择。
2. **每个组件都来自它自己的上游。** 容器镜像全部使用官方镜像（不再使用任何第三方转载镜像），
   Cloudflare WARP 直接调用 Cloudflare 官方接口注册，不再依赖社区的 `wgcf` 镜像。
3. **伪装目标与自有网站彻底分离。** 代理端口把未通过校验的流量回落到部署时指定的
   **远端真实大站**，nginx 则在 HTTP 端口上正常负载**你自己的网站**。详见
   [网站与伪装](#网站与伪装)。

---

## 功能特性

* 自动安装并配置 Docker 与 Compose 插件
* 引擎可选 `sing-box` / `xray`，TLS 可选 `reality` / `letsencrypt` / `selfsigned`
* 传输协议：`tcp`、`http`、`grpc`、`ws`、`tuic`、`hysteria2`、`shadowtls`
* 多用户，每用户独立 UUID / 密码，输出客户端链接与二维码
* Cloudflare WARP 出口（支持免费版与 WARP+ 授权），不引入任何额外镜像
* 自动开启 BBR 拥塞控制（加载 `tcp_bbr` + `fq` 队列，写入 `/etc/sysctl.d`），
  并附带内核 socket / backlog 调优
* 通过 certbot 申请与自动续期 Letsencrypt 证书
* 可选「安全上网」模式（拦截广告 / 恶意域名，sing-box 还可拦截成人内容）
* 文本管理界面（TUI）与 Telegram 机器人管理用户
* nginx 在 HTTP 端口上正常负载 `./website` 里的自有网站（`reality` / `shadowtls` 的
  回落目标是远端站点，不会落在你自己的站上）
* 支持密码保护的备份与恢复（用户 + 配置）
* 内核参数调优、IPv6 支持，`tcp` / `http` / `grpc` / `ws` 由 haproxy 复用端口

---

## 环境要求

* Linux，包管理器为 `apt`（Debian / Ubuntu）或 `yum`（RHEL 系）；其他发行版只要具备
  `curl`、`openssl`、`jq`、`qrencode`、`whiptail`、`zip`/`unzip` 以及带 Compose 插件的
  Docker 也能运行
* 架构 `x86_64` 或 `arm64`
* root 权限
* 公网 IP。**完全不需要自己有域名** —— 见[可以不买域名吗](#可以不买域名吗)；
  只有 `letsencrypt` 模式才需要一个域名。
* 想要 BBR 加速需要 Linux 4.9 及以上；更低版本内核也能正常部署，只是会跳过 BBR 并给出
  告警（见[内核调优与 BBR](#内核调优与-bbr)）

---

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh)
```

安装脚本会把全部内容写入 `/opt/reality`，启动服务栈，输出第一个客户端配置，并在需要时
打开 TUI。它同时会把**本脚本自身的一份副本放到 `/opt/reality/reality.sh`**，
此后所有管理操作都通过这一份执行；因为副本就在配置目录里，每次运行都会被刷新为当前版本。
这件事与是否启用 Telegram 机器人无关 —— 机器人只是恰好也挂载同一个目录。

常见用法：

```bash
# 使用默认配置安装（reality + sing-box，主端口 8443，网站端口 8080）
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh)

# 指定伪装回落的远端大站（同时会作为 SNI）
bash <(curl -fsSL .../reality.sh) --camouflage www.microsoft.com

# 自定义端口，并完全不挂网站
bash <(curl -fsSL .../reality.sh) --port 2087 --http-port off

# 使用 letsencrypt 证书（这是唯一会占用 80 端口的模式）
bash <(curl -fsSL .../reality.sh) --security letsencrypt --server vpn.example.com

# 之后随时打开管理菜单
bash /opt/reality/reality.sh --menu
```

---

## 端口策略

这是与上游差异最大的部分。

| 监听用途 | 默认宿主端口 | 由谁控制 | 说明 |
| --- | --- | --- | --- |
| 主代理端口 | `8443/tcp`（tuic / hysteria2 另加 `/udp`） | `--port` | 可为任意空闲端口；`80` 会被拒绝，`443` 允许但会提示 |
| 本机网站 | `8080/tcp` | `--http-port` | 由 nginx 从 `./website` 目录提供；设为 `off` 则完全不监听 |
| ACME 校验 | `80/tcp` | 强制 | **仅** `--security=letsencrypt` 模式使用 |

需要了解的行为：

* 默认安装只发布 `8443/tcp` 与 `8080/tcp`，此外不占用任何端口。本机继续在 `80`/`443`
  上运行 Nginx 等 Web 服务不受影响。
* `--http-port off` 会彻底去掉 HTTP 监听与 nginx 容器（最小暴露面）。
* 选择 `--security letsencrypt` 时脚本会把 HTTP 端口切到 `80` 并明确提示，因为 ACME
  HTTP-01 校验只能走 80 端口；切回 `reality` / `selfsigned` 后会自动恢复为 `8080`。
* 如果显式指定 `--port 443`，脚本仍会尊重你的选择（只提示、不阻止）——这是使用者的决定，
  不由安装器替你决定。

---

## 网站与伪装

两件事，刻意分开处理：

| | 是什么 | 在哪里配置 |
| --- | --- | --- |
| **伪装** | 未通过校验的探测者在代理端口上看到的内容。`reality` 模式下引擎不自己应答 TLS 握手，而是把握手转发给远端真实站点；`shadowtls` 模式下该站点就是握手目标。 | `--camouflage <domain[:port]>`，一个远端真实站点，部署时输入 |
| **网站** | 你自己的正常网站，由 nginx 从 `./website` 目录提供。 | `--http-port <port>` |

```bash
# 伪装目标 = www.microsoft.com，自有网站在 8080
bash <(curl -fsSL .../reality.sh) --camouflage www.microsoft.com

# 挂自己的网站：把文件丢进根目录即可，不需要其他操作
ls /opt/reality/config/website
```

几点说明：

* `--camouflage` 默认值为 `www.fastly.com`，并且会同时设置 SNI —— 因为探测者发出的就是
  SNI，并会拿回来的证书与之比对。只有在你明确想让两者不同时才额外传 `--domain`，此时
  脚本会给出告警：SNI 与证书不匹配正是主动探测要抓的特征。
* REALITY 官方对目标网站的**最低标准是 TLS 1.3 + H2**，所以选站前先验一下：
  `openssl s_client -connect <host>:443 -servername <host> -tls1_3 -alpn h2 </dev/null | grep ALPN`
  必须返回 `ALPN protocol: h2`，去掉 `-alpn` 再跑一次则必须协商出 `TLSv1.3`。当前默认值
  两项都满足（`www.microsoft.com`、`www.apple.com`、`www.cloudflare.com` 同样可以）。
  反之只返回 `http/1.1` 的站点（例如 Akamai 官网首页）低于该标准：它对外公告的 ALPN
  与它所冒充的站点并不一致。
* 从没有 `--camouflage` 的旧版本升级时，脚本会把原 `domain` 的值沿用到新配置项上，
  不会让你的回落目标在升级中悄悄换掉。
* 首次运行会写入一个中性的占位首页
  `/opt/reality/config/website/index.html`。**已存在的文件绝不会被覆盖** —— 把你自己的
  站点放进去，升级时不会丢。
* 在 `reality` / `shadowtls` 模式下，这个网站就是全部 HTTP 暴露面；不再通过明文 HTTP
  转发远端伪装站点的内容。

---

## 可以不买域名吗

可以。默认模式根本不使用你自己的域名；而且本分支已经把自家网站交给 nginx 托管，连这一块
也不需要域名。

| 模式 | 需要自有域名？ | 握手里带的是什么 |
| --- | --- | --- |
| `reality`（默认） | 不需要 | SNI 用的是**远端**伪装大站（`--camouflage`，默认 `www.fastly.com`），探测者拿到的是那个站点的真实证书 |
| `shadowtls` 传输 | 不需要 | 握手服务器同样是远端伪装大站 |
| `selfsigned` | 严格说不必要 | 自签证书；客户端必须接受不受信任的证书（`allow_insecure` / `insecure=1`），主动探测能够察觉 |
| `letsencrypt` | **需要** | 为你的自有域名签发公信证书 —— ACME HTTP-01 要求该域名解析到本机，并占用 `80` 端口 |

所以纯粹只有公网 IP 的机器，**没有任何需要填写的东西**：

```bash
# reality + sing-box，伪装目标默认 www.fastly.com，无需任何额外参数
bash <(curl -fsSL .../reality.sh)

# 同样不需要域名，只是换个探测者会看到的站点
bash <(curl -fsSL .../reality.sh) --camouflage www.microsoft.com
```

* 不用配 DNS 记录，也不用在本地签证书：`reality` / `shadowtls` 模式下引擎只是把握手转发给
  远端站点、不做 TLS 终结，因此既不会生成 `server.crt` / `server.key`，也不会往引擎容器里
  挂载证书。
* 只要不涉及 `letsencrypt`，`--server` 直接填公网 IP 即可；能自动探测时脚本会自己探测，
  只有在探测失败且未手工指定时才会以提示信息中止安装。
* `ws`、`tuic`、`hysteria2` 与 `reality` 组合会被拒绝（它们需要真正的 TLS 终结）。没有域名时
  可用的组合是 `reality` + `tcp` / `http` / `grpc`，或者 `shadowtls` 传输。
* 代价是你借用了别人的域名：请选一个**服务器与客户端都能访问**、且 TLS 指纹普通的站点。
  详见[安全说明](#安全说明)。

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
* `tgbot.py` 以及放在 `/opt/reality` 下的本脚本副本都从本仓库拉取；机器人优先使用
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
  bash /opt/reality/reality.sh
```

---

## 命令行参数

| 参数 | 说明 |
| --- | --- |
| `-t, --transport <tcp\|http\|grpc\|ws\|tuic\|hysteria2\|shadowtls>` | 传输协议（默认 `tcp`） |
| `-d, --domain <domain>` | Reality 握手使用的 SNI 域名（默认跟随 `--camouflage`） |
| `--camouflage <domain[:port]>` | `reality` / `shadowtls` 模式下未通过校验的流量所回落的远端真实站点（默认 `www.fastly.com`，端口默认 `443`） |
| `--server <server>` | 本机公网 IP 或域名；使用 `letsencrypt` 时必须是域名 |
| `--port <port>` | 主代理端口（默认 `8443`） |
| `--http-port <port\|off>` | nginx 承载本机网站的宿主端口（默认 `8080`，`off` 表示不监听） |
| `-c, --core <xray\|sing-box>` | 引擎（默认 `sing-box`） |
| `--security <reality\|letsencrypt\|selfsigned>` | TLS 模式（默认 `reality`） |
| `--enable-safenet <true\|false>` | 拦截广告 / 恶意域名，sing-box 下还会拦截成人内容 |
| `--enable-bbr <true\|false>` | 开启 BBR 拥塞控制与 `fq` 队列（默认 `true`；内核不支持时只告警并跳过） |
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
| `-u, --uninstall` | 卸载服务栈与 `/opt/reality` |
| `-h, --help` | 查看帮助 |

---

## 用户管理

```bash
bash /opt/reality/reality.sh --add-user john
bash /opt/reality/reality.sh --show-user john   # 客户端链接 + 二维码
bash /opt/reality/reality.sh --list-users
bash /opt/reality/reality.sh --delete-user john
```

用户名只允许字母与数字（`A-Z`、`a-z`、`0-9`）。

## Telegram 机器人

```bash
bash /opt/reality/reality.sh \
  --enable-tgbot true \
  --tgbot-token 123456789:AA... \
  --tgbot-admins your_telegram_username
```

机器人运行在独立容器中，挂载 `/opt/reality`，并以 argv 列表方式调用本地脚本副本——
来自按钮的用户名不可能被当作 shell 命令执行。支持的命令：`/start`、`/add`、`/delete`、
`/list`、`/show`。

请注意：该容器挂载了 Docker socket，实际权限等同于宿主机 root，不需要远程管理用户时建议
不要开启。

## Cloudflare WARP

```bash
bash /opt/reality/reality.sh --enable-warp true
bash /opt/reality/reality.sh --enable-warp true --warp-license XXXXXXXX-XXXXXXXX-XXXXXXXX
```

注册过程会向 Cloudflare 申请一个免费 WARP 设备，把设备 id、token、client id、接口地址以及
本机生成的私钥写入 `/opt/reality/config`，并作为引擎出口使用。关闭 WARP 时会在
Cloudflare 侧删除该设备。

## 内核调优与 BBR

每次运行都会写入并应用 `/etc/sysctl.d/99-reality.conf`，因此调优以标准 sysctl drop-in 的
形式在重启后依然有效。除 socket 缓冲、backlog、conntrack 等参数外，**BBR 默认开启**：

```ini
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

BBR 是内核自带能力，不需要从软件源安装任何东西 —— 脚本只做两件事：加载 `tcp_bbr` 与
`sch_fq`，写入上面两个键。它不做的是「假装成功」：状态会从 `/proc` 读回来并如实汇报。

```
$ bash /opt/reality/reality.sh --show-server-config
...
BBR: ON (kernel: bbr, qdisc: fq)
```

| 情况 | 会发生什么 |
| --- | --- |
| 正常内核（4.9 及以上） | 加载模块、写入两个键，BBR 立即生效 |
| 内核不支持 BBR（低于 4.9，或容器无法加载宿主机模块） | 打印告警，并且**不把这两个键写进配置文件**，避免之后每次重启都失败；其余调优项照常应用 |
| 传 `--enable-bbr false` | 从文件中移除这两行；只有当当前值确实是 `bbr` / `fq` 时才回退，你自己设定的拥塞控制算法不会被覆盖 |
| 内核拒绝其中某个键 | 在告警里点名该键，其余键仍然应用 |

因为每个键是单独写入的，内核拒绝某一项时不会再出现「BBR 实际没生效、安装器却报告成功」
的情况。

注意这里说的是**内核**拥塞控制。`hysteria2` 传输另外会在 QUIC 配置里声明
`congestion_control=bbr`，那是客户端传输层设置，与本项互相独立。

```bash
bash /opt/reality/reality.sh --enable-bbr false   # 关闭
bash /opt/reality/reality.sh --enable-bbr true    # 重新开启
```

---

## 备份与恢复

```bash
# 上传加密备份，输出下载地址
bash /opt/reality/reality.sh --backup --backup-password '一个强密码'

# 在本机或其他机器上恢复
bash /opt/reality/reality.sh --restore <url 或路径> --backup-password '一个强密码'
```

备份包内含用户列表与 `/opt/reality/config`。请务必设置密码：不设密码时压缩包就是
明文的密钥集合。

## 升级

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh)
```

重复执行安装脚本会保留原有配置，缺失的配置项（例如新引入的 `http_port`、`camouflage`）
会自动补上，配置目录里的脚本副本也会一并刷新。如果你之前部署的版本把主端口固定在 `443`，
请注意当前默认值已改为 `8443`，明文 HTTP 侧也从 `80` 变为 `8080`；如需保持旧布局，请显式
传入 `--port 443`。

项目名从 `reality-ezpz` 改为 `reality` 之后，安装目录也从 `/opt/reality-ezpz` 变为 `/opt/reality`。
用旧版本部署过的服务器**无需手工搬迁**：脚本每次启动都会先检查旧目录，存在的话先停掉旧的
compose 项目（旧容器 `reality-ezpz-engine-1` / `reality-ezpz-nginx-1` 占着 `8443` 与 `8080`，
不停掉新容器起不来），再把整棵目录移动到新位置——密钥、用户列表与网站都原样保留——最后按新
项目名 `reality` 重建容器。整个过程只移动、不删除数据。如果新旧目录同时存在，脚本会保留新目录
并给出告警，把旧目录留给你自行处置。

从更早的版本升级时还有一处修复值得一提：`/opt/reality/reality.sh` 过去只在启用
Telegram 机器人时才会生成，因此按文档执行 `bash /opt/reality/reality.sh --menu`
会报文件不存在。现在这份副本与机器人开关无关，重跑一次安装命令即可补上。

从还没有 `camouflage` 的版本升级时，有两处行为变化：

* 远端伪装目标会沿用旧的 `domain` 值，回落目标不会在升级中改变。
* HTTP 端口过去是把远端站点的内容以明文 HTTP 转发出来，现在改为提供**你自己的**网站。
  想保持原来的观感，可把那个站点的页面复制到 `/opt/reality/config/website`。

## 卸载

```bash
bash /opt/reality/reality.sh --uninstall   # 不会卸载 Docker 本身
```

---

## 安全说明

* Reality 的设计目标是让人无法把它与真实 TLS 站点区分开；SNI 域名与端口要符合你的威胁模型。
  伪装站点应选本机可访问的真实热门 HTTPS 站点，并让 SNI 与它是同一个域名 —— 探测者会拿
  回来的证书与自己发出的 SNI 做比对。
* 生成的客户端配置包含服务器地址、UUID 与 Reality 公钥，请把 `--show-user` 的输出当作机密。
* `--enable-tgbot` 会赋予机器人容器 Docker socket 权限，不需要远程管理时请保持关闭。
* 备份默认上传到公共粘贴服务，请配合 `--backup-password` 使用，或把 `BACKUP_UPLOAD_URL`
  指向你自己的服务器。
* 请只在你掌控的机器上以 root 运行安装脚本：它会安装软件包、写入 `/opt` 并调整内核参数。

---

## 常见问题

| 现象 | 排查方向 |
| --- | --- |
| `bash: /opt/reality/reality.sh: No such file or directory` | 该副本由安装器放置。旧版本只在启用 Telegram 机器人时才创建它，重跑一次安装命令即可补上；或手动 `curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh -o /opt/reality/reality.sh` |
| 提示 `Port 80 must be free ...` | 你选择了 `letsencrypt`，但 80 端口已被其他服务占用 |
| 升级后提示 `both /opt/reality-ezpz and /opt/reality exist` | 两个目录同时存在，脚本保留了 `/opt/reality` 并跳过迁移；确认数据在哪一边后手工删掉另一个 |
| 容器反复重启 | `docker logs $(docker compose -p reality ps -q engine)` |
| 客户端连不上 | 主端口是否放行（防火墙 / 安全组），SNI 域名是否匹配 |
| 提示 `WARP account creation has been failed!` | 能否访问 `api.cloudflareclient.com` |
| 提示 `BBR was requested but is not active` | 当前内核没有 BBR（需 4.9+），或容器无法加载宿主机模块；`--enable-bbr false` 可消除该提示 |
| 提示 `these kernel settings ... were skipped` | 列出的键在当前内核上不存在；其余键已应用，不影响 BBR |
| 提示 `the SNI (...) differs from the camouflage site (...)` | 你同时传了 `--domain` 与 `--camouflage`；除确有需要外，两者应指向同一个站点 |
| HTTP 端口上显示的是占位首页 | 把你的文件放进 `/opt/reality/config/website` —— `index.html` 只在目录为空时生成 |
| 伪装站点连接失败 | `--camouflage` 必须是本机能够访问的真实站点，本机不会为它提供任何内容 |
| Telegram 机器人无响应 | Token / 管理员名单是否正确，`/opt/reality/tgbot/tgbot.py` 是否存在 |
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
