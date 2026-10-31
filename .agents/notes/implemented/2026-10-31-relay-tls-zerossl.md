# Agent Note: 中转改用域名 + 国内可用的 TLS 路径

Status: implemented

## Problem

手机侧对**非私网**地址强制 `wss://`（`app/lib/core/endpoint.dart` 的 `isPrivateOrLoopback`），
而之前整条链路靠 `ws://127.0.0.1:8787`（`adb reverse`）与局域网直连，出了家门就断。
用户注册了 `dsh.0t0.me` 指向中转服务器（华为云 ECS），要求换成域名。

上 TLS 时撞到三件在国内机器上才成立的硬事实（2026-10-31 实测）：

1. **Docker Hub 拉不动**：`registry-1.docker.io` → `dial tcp 202.160.130.52:443: i/o timeout`；
   `docker.m.daocloud.io` 的 blob 存储（`image-mirror.r2.daocloud.vip`）同样超时。
   只有云厂商自己的加速可用（华为云 SWR 14 秒拉完）。
2. **出站到 Let's Encrypt 超时**：`acme-v02.api.letsencrypt.org` → `172.65.32.248:443 i/o timeout`，
   `api.buypass.com` 也不通；同机器到 `acme.zerossl.com` 是 200。
   于是 Caddy 内置 ACME 直接失败并每 60 秒重试一次。
3. **ZeroSSL 不支持 `tls-alpn-01`**：`Supported validation types are: http-01 dns-01`。
   所以"443 已经开了、不碰 80"这条省事路径不存在，安全组必须放行 **80**。

## Decision

1. **镜像**：`docker pull swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/library/caddy:2-alpine`
   再 `docker tag` 成 `caddy:2-alpine`。不用来源不明的第三方反代（`docker.1panel.live` 实测超时）。
2. **证书**：`acme.sh`（gitee 镜像）+ **ZeroSSL**、`http-01`、`ec-256`；
   证书装到 `/opt/dsh-mobile-relay/relay/certs/{fullchain,key}.pem`，
   Caddyfile 用 `tls` 指令直接加载，**关掉 Caddy 内置的自动签发**（`tls` 存在即跳过 ACME）。
3. **续期**：`--install-cert` 带 `--pre-hook` 停 caddy、`--post-hook` 起 caddy
   （http-01 standalone 要独占 80，而 Caddy 占着它），`--reloadcmd` 让容器 reload。
4. **收口**：compose 的 relay 端口改成 `127.0.0.1:8787:8787` —— Caddy 反代到同网络内的
   `relay:8787`，公网只留 80/443。
5. 连接器 `relayUrl` → `wss://dsh.0t0.me/ws/connector`（本机 profile 的
   `cordis.patch.yml`，改前备份 `.bak-20261031`）。

## Alternatives considered

1. **继续用 IP + 明文（`ws://<公网IP>:8787`）**
   - 最强理由：零改动，已经跑通过。
   - 为何被否：手机对公网地址强制 `wss://`，明文只能走"用户显式同意"那条红字路径；
     而 8787 上 `Authorization: Bearer <连接器令牌>` 对链路上任何人可见 —— 拿到它就能
     替这台电脑向中转报名册。用户既然有域名，就没必要留这个口子。
2. **Caddy 内置 ACME，换一家 CA**
   - 最强理由：一行 `acme_ca` 就换掉，证书与续期全由 Caddy 托管，不需要 `certs/` 目录。
   - 为何被否：能连的只有 ZeroSSL，而**它不支持 `tls-alpn-01`**；Caddy 走 http-01 也要 80，
     既然都要 80，不如用 `acme.sh`（它顺手把续期的停/起钩子也管了，且不依赖 Caddy 的
     EAB 支持版本）。LE 与 Buypass 在这台机器上根本不可达。
3. **DNS-01（阿里云 RAM AccessKey）**
   - 最强理由：一个端口都不用开，续期全自动，最干净。
   - 为何没走：`0t0.me` 的 DNS 在阿里云，需要把一份**长期 DNS 凭据**放到服务器上
     （会写进 `~/.acme.sh/account.conf`）。开源 80 的代价更小；等真要收掉 80 时再换这条。
4. **`wss://dsh.0t0.me:8787`（复用已经放行的 8787，不开 443）**
   - 最强理由：安全组一行都不用改。
   - 为何被否：证书仍然要 80 或 DNS 才能签，省不掉那一步；而让 TLS 跑在 8787 上，
     等于把一个"非标准 wss 端口"写进手机端点表与连接器配置，以后每台设备都要记这个例外。

## Consequences

- 收益：手机在**任何网络**下都能连（走 `wss://dsh.0t0.me`），令牌不再明文过公网；
  仓库侧 `docs/cookbook/relay-on-a-server.md` 补了国内镜像源、ZeroSSL 路径与 `wss` 升级验证。
- 代价 1：**80 必须长期放行**（续期要用）。它只做验证与 308 跳转，但确实是一个额外的入站口。
- 代价 2：证书**不由 Caddy 托管**，在 `./certs` 里，服务器重装要重新签一次；
  续期依赖 acme.sh 自己的定时任务 + 那对 pre/post 钩子。
- 代价 3：安全组里 **8787 的入方向规则仍然存在**（只是本机不再监听）——
  建议删掉，否则将来任何绑 `0.0.0.0:8787` 的东西都会直接暴露。
- 代价 4：换域名后**旧配对载荷作废**，手机要重扫一次二维码（载荷里的 `relay` 变了）。

## Testing

- `curl -s -o /dev/null -w '%{http_code}' https://dsh.0t0.me/` → **405**（中转 HTTP 面在应答）。
- `echo | openssl s_client -connect dsh.0t0.me:443 -servername dsh.0t0.me` → 链能验到
  `Sectigo Public Server Authentication Root E46` / `ZeroSSL ECC DV SSL CA 2`。
- 升级路径：`wss://dsh.0t0.me/ws/connector` 带**假令牌** → `status 401`
  （TLS + WebSocket 升级 + 令牌校验三段都通，且没把真令牌写进任何脚本）。
- 收口：外网连 `dsh.0t0.me:8787` 被拒；`https://dsh.0t0.me/` 仍是 405。
