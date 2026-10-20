# reality

**简体中文** | [English](README.EN.md)

一条命令在 Linux 服务器上部署 VLESS（Reality / TLS）、TUIC、hysteria2 与 ShadowTLS。

`reality` 会用 Docker Compose 拉起一套代理栈（引擎可选 sing-box 或 xray），生成客户端配置
与二维码，并提供对话式文本管理界面和可选的 Telegram 机器人来管理用户。

本项目是 [reality-ezpz](https://github.com/aleskxyz/reality-ezpz) 的加固分支，在上游功能之上
额外确立三条设计准则：

1. **443 一个端口同时承载代理与网站。** 默认只绑定 `443`（明文 HTTP 入口默认关闭，
   需要时用 `--http-port` 打开）。`443` 上 haproxy
   只读 TLS 握手里的 SNI 并原样转发：带伪装 SNI 的连接进引擎（REALITY 必须自己看握手，
   所以这里不终结 TLS），其余连接交给 nginx 上你自己的网站。端口 `80` 只有
   `letsencrypt` 模式会用（ACME HTTP-01 强制要求），且必须由你主动选择。
2. **每个组件都来自它自己的上游。** 容器镜像全部使用官方镜像，
   Cloudflare WARP 直接调用 Cloudflare 官方接口注册。
3. **伪装目标与自有网站彻底分离。** 带伪装 SNI 的探测者被回落到部署时指定的
   **远端真实大站**；不带该 SNI 的访问（例如浏览器直接打开 `https://<IP>`）看到的才是
   **你自己的网站**。详见[网站与伪装](#网站与伪装)。

---

## 功能特性

* 自动安装并配置 Docker 与 Compose 插件
* 引擎可选 `sing-box` / `xray`，默认为 `sing-box`；TLS 可选 `reality` / `letsencrypt` / `selfsigned`，默认为 `reality`。
* 传输协议：`tcp`、`http`、`grpc`、`ws`、`tuic`、`hysteria2`、`shadowtls`，默认为 `tcp`。
* 多用户，每用户独立 UUID / 密码，输出客户端链接与二维码
* Cloudflare WARP 出口（支持免费版与 WARP+ 授权），不引入任何额外镜像
* 自动开启 BBR 拥塞控制（加载 `tcp_bbr` + `fq` 队列，写入 `/etc/sysctl.d`），
  并附带内核 socket / backlog 调优
* 通过 certbot 申请与自动续期 Letsencrypt 证书
* 可选「安全上网」模式（拦截广告 / 恶意域名，sing-box 还可拦截成人内容）
* 对话式文本管理界面（编号选择、无需方向键）与 Telegram 机器人管理用户
* 自有网站由 nginx 提供：`https://<IP>` 走 `443`（与代理共用一个端口）；明文入口
  `--http-port` 默认关闭，需要时显式打开；`reality` / `shadowtls` 的回落目标仍是远端站点，不会混进来
* 支持密码保护的备份与恢复（用户 + 配置）
* 内核参数调优、IPv6 支持，`tcp` / `http` / `grpc` / `ws` 由 haproxy 复用端口

---

## 环境要求

* Linux，包管理器为 `apt`（Debian / Ubuntu）或 `yum`（RHEL 系）；其他发行版只要具备
  `curl`、`openssl`、`jq`、`qrencode`、`zip`/`unzip` 以及带 Compose 插件的
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
打开管理菜单。它同时会把**本脚本自身的一份副本放到 `/opt/reality/reality.sh`**，
此后所有管理操作都通过这一份执行；因为副本就在配置目录里，每次运行都会被刷新为当前版本。
这件事与是否启用 Telegram 机器人无关 —— 机器人只是恰好也挂载同一个目录。

常见用法：

```bash
# 使用默认配置安装（reality + sing-box，代理与网站共用 443；不额外开明文端口）
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh)

# 指定伪装回落的远端大站（同时会作为 SNI）
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh) \
  --camouflage www.microsoft.com

# 自定义端口（网站仍只在共用的 443 上）
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh) \
  --port 2087

# 需要明文 HTTP 入口时显式打开（例如放在 CDN / 反向代理后面）
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh) \
  --http-port 8080

# 使用 letsencrypt 证书（这是唯一会占用 80 端口的模式）
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh) \
  --security letsencrypt --server vpn.example.com

# 之后随时打开管理菜单
bash /opt/reality/reality.sh --menu
```

---

## 端口策略

| 监听用途 | 默认宿主端口 | 由谁控制 | 说明 |
| --- | --- | --- | --- |
| 代理 + 网站（HTTPS） | `443/tcp`（tuic / hysteria2 另加 `/udp`） | `--port` | 一个端口两种用途，由 haproxy 按 SNI 分流；`80` 会被拒绝 |
| 网站（明文 HTTP） | 不开启（`off`） | `--http-port` | 由 nginx 从 `./website` 目录提供；默认不监听，显式给一个端口才发布（`443` 上的网站不受影响） |
| ACME 校验 | `80/tcp` | 强制 | **仅** `--security=letsencrypt` 模式使用 |

需要了解的行为：

* 默认安装只发布 `443/tcp`，此外不额外占用任何端口。`443` 上 haproxy 只做一次
  SNI 判别：带伪装 SNI 的连接按原样转给引擎，其余连接（浏览器打开 `https://<IP>`、别的
  主机名）交给 nginx。默认（`reality`）模式下这个网站用自签证书，首次访问会提示不受信任
  —— 这是预期行为，不是配置错误。
* 代理端口与网站端口不能相同：`--port 443 --http-port 443` 这类组合会被拒绝。
* 明文 HTTP 入口默认不发布；要开就 `--http-port <端口>`，要关就是 `--http-port off`。
  `https://<IP>` 上的网站不受影响，因为它与代理共用 `443`，nginx 容器也仍然存在。
* 选择 `--security letsencrypt` 时脚本会把 HTTP 端口切到 `80` 并明确提示，因为 ACME
  HTTP-01 校验只能走 80 端口；切回 `reality` / `selfsigned` 后回到默认（不发布）。
* `selfsigned` + `tcp` 与 `reality` 走同一套 SNI 分流（引擎自己终结 TLS，网站用自签证书）。
  只填 IP 时 SNI 会自动落到默认站点（见[可以不买域名吗](#可以不买域名吗)）。
  `http` / `grpc` / `ws` 传输则由 haproxy 终结 TLS 并按路径分流，网站同样在 `443` 上
  （`letsencrypt` 用你申请到的证书，浏览器不会提示；`selfsigned` 仍是自签证书）。
* `letsencrypt` + `tcp` 是唯一例外：浏览器和代理客户端发出的 SNI 完全相同，无法区分，
  所以 `443` 整条留给代理，网站只走 `--http-port`（默认不发布，需要时显式给端口）。
* 从旧版本升级时，配置里遗留的 `port=8443`（老版本的出厂值）会被自动改成 `443` 并打印
  提示；其他自定义端口保持不变。

---

## 网站与伪装

两件事，刻意分开处理：

| | 是什么 | 在哪里配置 |
| --- | --- | --- |
| **伪装** | 未通过校验的探测者在代理端口上看到的内容。`reality` 模式下引擎不自己应答 TLS 握手，而是把握手转发给远端真实站点；`shadowtls` 模式下该站点就是握手目标。 | `--camouflage <domain[:port]>`，一个远端真实站点，部署时自动设定 |
| **网站** | 你自己的正常网站，由 nginx 从 `./website` 目录提供，`https://<IP>`（复用代理的 443）始终可访问；明文 `--http-port` 需要显式开启。 | 把文件放进 `./website`，端口用 `--port` / `--http-port` |

```bash
# 伪装目标 = www.microsoft.com，代理与网站共用 443（明文入口默认不开）
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh) \
  --camouflage www.microsoft.com

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
* 在 `reality` / `shadowtls` 模式下，`443` 上只有带伪装 SNI 的连接会进引擎；直接用 IP
  或不带该 SNI 的域名访问，看到的就是你自己的网站。反过来说，用伪装域名当 SNI 去访问
  这台机器，看到的仍是远端大站 —— 那正是主动探测应该看到的东西。
* 想用自己的证书替换 `443` 上的自签证书：把 `fullchain` 与私钥分别写到
  `/opt/reality/config/certificate/server.crt` 和 `server.key`，再重启 nginx 容器。

---

## 可以不买域名吗

可以。默认模式根本不使用你自己的域名；而且本分支已经把自家网站交给 nginx 托管，连这一块
也不需要域名。

| 模式 | 需要自有域名？ | 握手里带的是什么 |
| --- | --- | --- |
| `reality`（默认） | 不需要 | SNI 用的是**远端**伪装大站（`--camouflage`，默认 `www.fastly.com`），探测者拿到的是那个站点的真实证书 |
| `shadowtls` 传输 | 不需要 | 握手服务器同样是远端伪装大站 |
| `selfsigned` | 不需要 | 自签证书；客户端必须接受不受信任的证书（`allow_insecure` / `insecure=1`，客户端链接里已经带上），主动探测能够察觉。只填公网 IP 时 SNI 会自动落到默认站点，因为客户端从不把 IP 当作 TLS SNI 发出去 |
| `letsencrypt` | **需要** | 为你的自有域名签发公信证书 —— ACME HTTP-01 要求该域名解析到本机，并占用 `80` 端口 |

所以纯粹只有公网 IP 的机器，**没有任何需要填写的东西**：

```bash
# reality + sing-box，伪装目标默认 www.fastly.com，无需任何额外参数
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh)

# 同样不需要域名，只是换个探测者会看到的站点
bash <(curl -fsSL https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh) \
  --camouflage www.microsoft.com
```

* 不用配 DNS 记录，也不用在本地签证书：`reality` / `shadowtls` 模式下引擎只是把握手转发给
  远端站点、不做 TLS 终结，因此既不会生成 `server.crt` / `server.key`，也不会往引擎容器里
  挂载证书。
* 只要不涉及 `letsencrypt`，`--server` 直接填公网 IP 即可；能自动探测时脚本会自己探测，
  只有在探测失败且未手工指定时才会以提示信息中止安装。
* `ws`、`tuic`、`hysteria2` 与 `reality` 组合会被拒绝（它们需要真正的 TLS 终结）。没有域名时
  可用的组合是 `reality` + `tcp` / `http` / `grpc`、`selfsigned` + `tcp` / `http` / `grpc`，
  或者 `shadowtls` 传输。`selfsigned` 只填 IP 时，SNI 会自动设成默认站点而不是那个 IP ——
  客户端从不把 IP 当作 TLS SNI 发出去，若真设成 IP，`443` 上的 SNI 分流会把代理流量误送到网站。
* 代价是你借用了别人的域名：请选一个**服务器与客户端都能访问**、且 TLS 指纹普通的站点。
  详见[安全说明](#安全说明)。

---

## 只使用官方源

| 组件 | 镜像 | 来源 |
| --- | --- | --- |
| xray 引擎 | `ghcr.io/xtls/xray-core:26.3.27` | GHCR，XTLS 官方发布 |
| sing-box 引擎 | `ghcr.io/sagernet/sing-box:v1.14.1` | GHCR，SagerNet 官方发布 |
| nginx | `nginx:1.30.5` | Docker Hub 官方 library |
| haproxy | `haproxy:3.4.4` | Docker Hub 官方 library |
| certbot | `certbot/certbot:v5.8.0` | Docker Hub 官方 certbot 镜像 |
| Telegram 机器人基础镜像 | `python:3.14-alpine` | Docker Hub 官方 library |

每个镜像都钉在各自项目的**最新稳定版**上，不使用 `latest` 一类的浮动 tag，因此不同时间安装的
两台服务器跑的是同一份代码。xray 从 v26.4 起的版本都被上游标记为 pre-release，所以这里取的是
最后一个正式版；升级镜像时 `reality.sh` 顶部的 `image[]` 和上面这张表必须一起改。

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
| `-t, --transport <tcp\|http\|grpc\|ws\|tuic\|hysteria2\|shadowtls\|anytls>` | 传输协议（默认 `tcp`）；`anytls` 需要 sing-box 内核与真实 / 自签证书（不能配 `reality`），由引擎自己终止 TLS |
| `-d, --domain <domain>` | Reality 握手使用的 SNI 域名（默认跟随 `--camouflage`） |
| `--camouflage <domain[:port]\|self>` | `reality` / `shadowtls` 模式下未通过校验的流量所回落的远端真实站点（默认 `www.fastly.com`，端口默认 `443`）；填 `self` 则回落本机网站并为 SNI 域名签发真实证书（需要 `--server` 是域名，且 ACME HTTP-01 使用端口 80） |
| `--server <server>` | 本机公网 IP 或域名；使用 `letsencrypt` 时必须是域名 |
| `--port <port>` | 代理端口，同时用于网站 HTTPS（默认 `443`） |
| `--http-port <port\|off>` | nginx 明文网站的宿主端口（默认 `off`：不发布；给一个端口才监听） |
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
| `--format <uri\|clash\|singbox\|v2ray\|json>` | 配合 `--show-user` 选择客户端配置的导出格式（默认 `uri`）：`clash` / `singbox` / `v2ray` 给出可直接粘贴的 outbound 片段，`json` 给出完整的 sing-box 客户端配置。`v2ray` 只覆盖 vless 系列传输 |
| `--delete-user <username>` | 删除用户 |
| `--enable-tgbot <true\|false>` | 启用 Telegram 机器人 |
| `--tgbot-token <token>` | Telegram 机器人 Token |
| `--tgbot-admins <user1,123456789>` | 机器人管理员：Telegram 用户名（不带 `@`）或数字 ID |
| `--harden-docker <true\|false>` | 把 Docker socket 放进最小权限代理（`tecnativa/docker-socket-proxy`），机器人不再直接拿到 socket；默认 `false`（仅精简挂载，不引入第三方镜像） |
| `--backup` | 创建并上传备份 |
| `--restore <url\|file>` | 从备份恢复 |
| `--backup-password <password>` | 为备份设置密码 |
| `--hysteria2-up <mbps>` / `--hysteria2-down <mbps>` | hysteria2 服务端上下行（Mbps），两个都填才生效：等价于关闭 `ignore_client_bandwidth`，改由服务端按此速率用 Brutal 整形 |
| `--tuic-congestion <cubic\|new_reno\|bbr>` | tuic v5 的拥塞控制算法（默认 `bbr`） |
| `--ss-port <port\|off>` | 额外开放一个 Shadowsocks 2022（`2022-blake3-aes-128-gcm`）入口，自带独立端口（仅 sing-box；默认关闭）。它不参与 SNI 分流，因为纯 TCP 没有 TLS SNI 可分；每个用户会派生一把稳定的独立密钥 |
| `--dns-provider <cloudflare>` | 改用 DNS-01 校验来签发证书（默认关闭）：不再需要 80 端口入站，并会自动附带一张 `*.你的域名` 泛域名证书 |
| `--dns-credentials <path>` | DNS 服务商凭据文件的宿主机路径（Cloudflare 为含 `dns_cloudflare_api_token = ...` 的 ini 文件），会以只读方式挂进 certbot 容器 |
| `--open-firewall` | 在宿主防火墙（ufw / firewalld）放行代理与网站端口；未识别到防火墙时只打印需要在安全组放行的端口 |
| `--check-update` | 对比钉死的镜像 tag 与上游最新 tag 后退出（只读，不改任何东西） |
| `--doctor` | 对运行中的服务栈做一次只读体检（容器、端口、SNI 分流、证书、DNS）后退出 |
| `-m, --menu` | 打开管理菜单 |
| `-u, --uninstall` | 卸载服务栈并删除 `/opt/reality`；旧版遗留的 `/opt/reality-ezpz` 与内核调优文件也会一并清理 |
| `-h, --help` | 查看帮助 |

### 伪装目标与「偷自己」

`reality` / `shadowtls` 下，未通过校验的探测流量会被回落到 `--camouflage` 指向的真实站点。探测器用你发出的 SNI 去比对回落站点返回的证书，所以两者必须是同一个域名（`--domain` 与 `--camouflage` 会自动保持一致）。

* **借用大厂域名**（默认 `www.fastly.com`）：省事，但对方可能限速、TLS 指纹与真实站点不同、证书也会轮换。显式把 `--camouflage` 指向某个大厂域名时，安装脚本会明确提醒。
* **`--camouflage self`（偷自己）**：回落到**本机 nginx**，并由 `certbot` 为 SNI 域名签发**真实证书**。探测者看到的是与你 SNI 完全匹配的真实证书，也不依赖任何第三方站点。代价是必须用域名（`--server <domain>`），且 ACME HTTP-01 需要 80 端口（脚本会自动把 `--http-port` 固定为 80）。证书续期后会自动重启 nginx。

### 运维与体检

* `--doctor`：只读体检（容器是否在跑、端口是否监听、SNI 分流是否正常、证书有效期、域名解析），不改动任何东西。
* `--check-update`：把钉死的镜像 tag 与上游最新 tag 做「同形态」比较（例如 `vX.Y.Z` 只和 `vX.Y.Z` 比），有新版本不会改变退出码。
* `--open-firewall`：自动在 ufw / firewalld 放行代理与网站端口；识别不到防火墙时打印需要在云厂商安全组放行的端口。

---

---

## 管理菜单

`bash /opt/reality/reality.sh --menu` 打开一个纯文本菜单：每一项都有编号，输入数字回车即可，
不需要方向键，所以在手机 SSH 客户端上和桌面终端上一样好用。

* 选项一律按编号选择，`q` 或直接回车返回上一层
* 输入类提示会先显示**当前值**：直接回车保持原值；没有当前值时回车等于返回
* 确认类提示只认 `y` / `n`，回车取提示里标出的默认项
* 任意一步都可以用 `Ctrl-D` 退出
* 屏幕不会被清空，之前打印的客户端配置与二维码仍可向上翻看

> 早期版本用的是 whiptail 全屏对话框，它需要约 32 行终端和方向键，手机端基本无法操作，
> 因此已整体改为文本问答，`whiptail` 也不再是依赖。

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
  --tgbot-admins your_telegram_username,123456789
```

机器人运行在独立容器中，挂载 `/opt/reality`，并以 argv 列表方式调用本地脚本副本——
来自按钮的用户名不可能被当作 shell 命令执行。命令只有 `/start`（列出下面三个按钮），
查看配置、新增用户、删除用户都通过按钮菜单完成。

请注意：该容器挂载了 Docker socket，实际权限等同于宿主机 root，不需要远程管理用户时建议
不要开启。

### 管理员名单：用户名或数字 ID

`--tgbot-admins` 的每一项既可以是 Telegram 用户名，也可以是账号的数字 ID；逗号分隔、不加
空格，两种写法可以混用。

| 写法 | 例子 | 规则 |
|---|---|---|
| Telegram 用户名 | `dakerjie` | 不带 `@`；5–32 个字符，字母开头，只能用字母、数字、下划线，不能以 `_` 结尾 |
| 数字 ID | `123456789` | 账号的永久编号，4–15 位数字 |

**没有设置用户名的账号只能用数字 ID 授权。** 用户名在 Telegram 里是可选项，可以随时改名，
释放后还可能被别人抢注；数字 ID 与账号终身绑定、不会被回收，所以用起来更省心。鉴权时两种
写法都会比对，其中用户名**不区分大小写**。

### 怎么拿到自己的数字 ID

任选一种，30 秒内搞定：

1. **@userinfobot**（推荐）：打开 https://t.me/userinfobot 点 Start（或随便发一句话），
   回复中以 `Id:` 开头的那一行就是你的数字 ID。
2. **@getidsbot**：打开 https://t.me/getidsbot 发任意一句话，回复中 `ID:` 后面的那串数字
   即为数字 ID。
3. **不借助第三方机器人**：自己刚建的机器人就是现成的查询工具。先在 Telegram 里给
   `@你的机器人` 发一句 `/start`，然后执行：

   ```bash
   curl -s "https://api.telegram.org/bot<你的BOT_TOKEN>/getUpdates" \
     | grep -o '"from":{"id":[0-9]*' | head -1
   ```

   输出里的 `"id":` 后面那串数字就是你的数字 ID（即 `message.from.id`）。
   注意要赶在机器人容器启动前查，或者先停掉机器人容器——它一启动就会把积压的消息取走。

三条要注意的规则：

1. **只能与机器人私聊**。鉴权比对的是会话本身：私聊里才代表你的账号，群里拿到的是群，不会
   被识别成管理员；而且客户端配置（含二维码）会直接发到群里。
2. **改用户名就要同步改名单**。名单以容器环境变量 `BOT_ADMIN` 注入，改完必须重跑一次配置让
   容器重建；换成数字 ID 就没有这个麻烦。
3. **管理菜单里一样能配**。`bash /opt/reality/reality.sh --menu` → 「Telegram Bot」项的输入框
   同样接受两种写法。

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
会自动补上，配置目录里的脚本副本也会一并刷新。注意 `http_port` 的出厂值已改为「不发布」：
旧配置里**没写**这一项的实例会补成 `off`；显式写过端口的实例保持原值，不会被静默关掉。

## 卸载

```bash
bash /opt/reality/reality.sh --uninstall   # 不会卸载 Docker 本身
```

`--uninstall` 会停掉并删除本项目创建的全部容器（引擎、nginx、haproxy、certbot、telegram bot），
再删除配置目录与内核调优文件 `/etc/sysctl.d/99-reality.conf`；镜像保留。从更早版本升级上来的
机器还会一并清理旧部署目录 `/opt/reality-ezpz` 与它的旧 compose 项目 `reality-ezpz`，所以不会留下
仍占着 443/8080 的容器。需要 root 权限；Docker 本身与 `/etc/docker/daemon.json` 保持不动。

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
| 提示 `Port 80 must be free ...` | 你选择了 `letsencrypt`，但 80 端口已被其他服务占用 |
| 容器反复重启 | `docker logs $(docker compose -p reality ps -q engine)` |
| 客户端连不上 | 主端口是否放行（防火墙 / 安全组），SNI 域名是否匹配 |
| 提示 `WARP account creation has been failed!` | 能否访问 `api.cloudflareclient.com` |
| 提示 `BBR was requested but is not active` | 当前内核没有 BBR（需 4.9+），或容器无法加载宿主机模块；`--enable-bbr false` 可消除该提示 |
| 提示 `these kernel settings ... were skipped` | 列出的键在当前内核上不存在；其余键已应用，不影响 BBR |
| 提示 `the SNI (...) differs from the camouflage site (...)` | 你同时传了 `--domain` 与 `--camouflage`；除确有需要外，两者应指向同一个站点 |
| 网站显示的是占位首页 | 把你的文件放进 `/opt/reality/config/website` —— `index.html` 只在目录为空时生成 |
| 浏览器打开 `https://<IP>` 提示证书不受信任 | `443` 上的网站用自签证书（CN 是 `--server` 的值），属预期；想消除提示就按[网站与伪装](#网站与伪装)换成自己的证书 |
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
