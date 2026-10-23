# 在服务器上跑中转（Docker + 公网 wss）

把中转放到一台有公网地址的机器上，手机在**任何网络**下都能连到家里的电脑。
中转只转发与记账，不存会话内容（契约 §2 / §12）。

> **先决条件**：这台服务器有公网 IP 与一个域名（A 记录指过去）。
> 手机对**非私网**地址强制 `wss://`（`app/lib/core/endpoint.dart` 的
> `isPrivateOrLoopback`），所以公网必须有 TLS；中转自己不终结 TLS。

## 1. 签发一个连接器令牌（在本机仓库根执行）

令牌是明文，只出现一次；配置里存的是 `sha256(令牌)` 的十六进制。

```pwsh
node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))"
# 把输出记下来（下面叫 <TOKEN>），再算摘要：
node -e "console.log(require('node:crypto').createHash('sha256').update(process.argv[1],'utf8').digest('hex'))" '<TOKEN>'
```

**验证**：第二行输出 64 位十六进制。

## 2. 写配置文件（服务器上）

```json
{
  "port": 8787,
  "host": "0.0.0.0",
  "tokens": [
    { "kind": "connector", "id": "home-pc", "hash": "<上一步的摘要>" }
  ],
  "rateLimit": { "capacity": 60, "refillPerSecond": 6 }
}
```

放到服务器上的 `relay/relay.config.json`（与 compose 同目录）。**它不进镜像**
（根 `.dockerignore` 挡着），因为它是这台机器的凭据表。

## 3. 起服务

```bash
# 服务器上，仓库根
cd relay
docker compose up -d --build
docker compose ps        # 等 (healthy)
docker compose logs -f relay
```

**验证（三条都要）**：

```bash
# ① 容器在听，且日志里是配置里的端口
docker compose logs relay | tail -3          # 期望：中转已监听 ws://0.0.0.0:8787（摘要表 1 条）
# ② HTTP 面活着（普通 GET 被拒 = 它在应答）
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8787/     # 期望：405
# ③ 连接器令牌能升级、错令牌不能
node -e "const W=require('ws');const w=new W('ws://127.0.0.1:8787/ws/connector',{headers:{authorization:'Bearer <TOKEN>'}});w.on('open',()=>{console.log('ok');process.exit(0)});w.on('unexpected-response',(_,r)=>{console.log('status',r.statusCode);process.exit(1)})"
```

## 4. 打开 TLS（公网必须）

```bash
cd relay
cp Caddyfile.example Caddyfile     # 把 relay.example.com 换成你的域名
# 在 docker-compose.yml 里取消 caddy 那段与 volumes 的注释
docker compose up -d caddy
```

**验证**：`curl -s -o /dev/null -w '%{http_code}\n' https://relay.example.com/` → `405`
（与第 3 步同一条：HTTP 面在应答），且 `https` 证书链有效。

## 5. 让电脑侧连过来

电脑上的连接器配置（profile 的 `cordis.patch.yml`）：

```yaml
- id: dsh-mobile-connector
  config:
    relayUrl: wss://relay.example.com/ws/connector
    relayTokenRef: relay-connector      # 这个 ref 指向 <TOKEN>（DSH 凭据面）
    listenPort: 8790                    # 局域网直连仍然保留，回家自动走直连
    listenHost: 0.0.0.0
```

**验证**：中转日志出现 `连接器 home-pc 控制面已连接`；
`GET /api/dsh-mobile/status` 的 `relayUrl` 是**拨号地址**（`wss://…`），
而配对载荷里的 `relay` 就是同一个域名（`relayHintFor` 对域名原样返回）。

## 6. 手机重新配对

公网地址变了，旧的配对载荷作废：在电脑上出码，手机扫/粘贴。

**验证（这条是公网的核心判据）**：手机**关掉 WiFi 只留移动数据**，
App 仍显示「已连接」，且能在会话里收到新消息 ——
说明走的是 `wss://relay.example.com` 而不是局域网直连。

## 7. 已知边界

- **中转重启会清空设备名册**：手机换票先拿到 401，但**这不是终态** —— 名册是电脑侧在
  每次连上中转时重放上去的，电脑重连即补，手机退避重试会自动恢复（不会清凭据）。
  电脑侧确认不认这台设备时才以关闭码 4003 + `protocol/not-paired` 明说。
- **单实例**：不做多实例与状态同步（范围决定）。
- **速率限制**：匿名那一跳按来源地址分桶，已认证的按身份（见 `docs/subsystems/pairing-v2.md`）。

## 8. 本机容器验证（2026-10-21，无公网服务器时的替代证据）

没有服务器时，**容器这一段仍能端到端验掉**，只有"真实互联网穿越"验不了。
本机实测（`docker run` + 容器配置，摘要来自 `.credentials.yaml` 的 `relay-connector` 令牌）：

| 判据 | 结果 |
|---|---|
| 镜像构建 + `docker inspect` 健康检查 | 过（`healthy`） |
| `GET /` → **405**（HTTP 面在应答） | 过 |
| `WS /ws/connector` 无令牌 / 错令牌 → **401**、对令牌 → 升级 | 过 |
| 连接器注册：容器日志出现「连接器 home-pc 控制面已连接」 | 过 |
| **容器承载真流量**：手机重新配对 → 会话列表 → 发一句 → 收到模型回复 | 过（配对走 `ws://127.0.0.1:8787/ws/connector` + `adb reverse tcp:8787`；容器内 `netstat` 同时有连接器与手机的 established） |
| 公网：关 WiFi 只留移动数据仍「已连接」 | **未验（无服务器）** |

**一个 Windows 本机的坑（与服务器部署无关）**：Docker Desktop 把 `-p 8787:8787` 发布到
宿主机后，**局域网侧连不上** —— Windows 防火墙的入站放行规则只覆盖了 `node.exe`
（上一轮 node 中转因此能通），`com.docker.backend` 没有放行规则，而 `WLAN 2` 的网络类别是
`Public`。判据：手机 `curl http://<PC 局域网 IP>:8787/` 超时，宿主 `curl 127.0.0.1:8787` 回 405。
绕过办法（不改防火墙）：`adb reverse tcp:8787 tcp:8787` + 配对载荷里的 `relay` 写成
`ws://127.0.0.1:8787/ws/connector`（手机拨自己的回环，经 USB 到宿主）。
服务器上没有这道防火墙，公网部署不需要这个绕法。
