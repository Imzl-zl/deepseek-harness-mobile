# 在服务器上跑中转（Docker + 公网 wss）

把中转放到一台有公网地址的机器上，手机在**任何网络**下都能连到家里的电脑。
中转只转发与记账，不存会话内容（契约 §2 / §12）。

> **先决条件**：这台服务器有公网 IP；**有域名**就走 §4 的 TLS（推荐）。只有 IP、没证书时按 §3.1 的明文路径先跑（两处开关要显式打开）。
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

## 3.1 只有公网 IP、还没有域名时（明文，可先用）

2026-10-29 实机验证过的路径。判据：内容仍端到端加密（握手后逐帧 AEAD），明文的代价是
**元数据可见**；所以公网明文必须由用户显式打开两处开关（手机侧一次确认 + 连接器配置）。

1. **配置里 `host` 必须是 `0.0.0.0`**（示例文件给的是 `127.0.0.1`，容器里那样映射出去连不上）。
2. **令牌在容器里签**（不用手算 sha256，摘要会自动写回挂载的配置）：
   ```bash
   docker compose run --rm relay \
     node src/main.ts --config /config/relay.config.json --issue-token connector home-pc
     # 同一个人的第二台电脑：加 --owner，限流按人共用一个桶（不配则按连接器各算各的）
     node src/main.ts --config /config/relay.config.json --issue-token connector office-pc --owner alice
   ```
   输出里那串令牌只出现一次，交给电脑侧。
3. **连接器**：在这台电脑的 DSH 里打开「手机」面板 →「连接」卡，地址填
   `ws://<公网IP>:8787/ws/connector`、勾上「允许公网明文 ws://」，保存即可（**不用重启 DSH**，
   通道会自动重连）。也可以改 `cordis.patch.yml` 的 `relayUrl` + `allowInsecurePublic: true`
   （`allowInsecureLocal` 只管非公网）后重启。
4. **令牌**进 DSH 凭据：`dsh-mobile-connector/relay-connector` 那条记录的 `payload.token`。
5. **手机**：出码后二维码里的 relay 就是 `ws://<公网IP>:8787`；配对页的确认卡会多一行
   红字「这台电脑的中转是明文连接……元数据可见」，点「确认并配对」即同意
   （那一下同时落成用户级偏好 `net.allow_plaintext_public`）。
6. **验收**：手机关 WiFi 只留移动数据，App 仍显示「已连接」（= 走的是公网中转）。
7. 上云安全组要放行该端口（例：TCP 8787）；以后有域名/证书时按第 4 步换成 `wss://`。

## 4. 打开 TLS（有域名时）

```bash
cd relay
cp Caddyfile.example Caddyfile     # 把 relay.example.com 换成你的域名
# 在 docker-compose.yml 里取消 caddy 那段与 volumes 的注释
docker compose up -d caddy
```

**验证**：`curl -s -o /dev/null -w '%{http_code}\n' https://relay.example.com/` → `405`
（与第 3 步同一条：HTTP 面在应答），且 `https` 证书链有效。

## 5. 让电脑侧连过来

在电脑的 DSH 里打开「手机」面板 →「连接」卡：地址、直连端口、令牌都在那里改，
保存后通道自动重连。等价的配置文件写法（profile 的 `cordis.patch.yml`）：

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

## 6.5 上线前的四道闸（容器不会拖垮宿主）

容器的隔离只覆盖进程，不覆盖**端口、磁盘、内存、重启循环**。`relay/docker-compose.yml`
的四项按"炸了也只在容器里"配好：

| 闸 | 配置 | 不配会怎样 |
|---|---|---|
| 重启循环 | `restart: on-failure:5` | 配置写错时容器**每次都立刻退**，`unless-stopped` 把它变成永远重启：刷日志、吃 CPU |
| 日志封顶 | `logging: json-file, max-size 10m, max-file 3` | 默认无上限，被刷的端口把宿主磁盘写满（最常见的拖垮方式） |
| 资源上限 | `mem_limit: 256m`、`cpus: 1.0` | 泄漏或洪水先在宿主上表现出来（OOM 杀别人） |
| 端口暴露 | 公网绑 `127.0.0.1:8787:8787` + Caddy | `8787:8787` 明文挂公网：链路上任何人可读到连接器令牌，拿到就能替这台电脑报名册 |

**验收**：`docker compose config -q` 无输出；`docker compose up -d` 后 `docker compose ps`
是 `(healthy)`；`docker stats --no-stream` 里中转的 MEM USAGE 远低于上限。

## 6.6 更新镜像（两端版本要对齐）

```bash
cd ~/dsh-mobile            # 服务器上的仓库目录
git pull                   # 取到中转侧的新代码
docker compose -f relay/docker-compose.yml build relay
docker compose -f relay/docker-compose.yml up -d relay
docker compose -f relay/docker-compose.yml logs --tail 3 relay   # 期望：中转已监听 ws://0.0.0.0:8787（摘要表 N 条）
```

- **`relay.config.json` 是挂载的**（不进镜像），重建不会丢令牌摘要；`N` 条应与更新前一致。
- **重启会断开所有手机**：它们退避后自动换票重连；连接器重连后重放名册，`serving` 恢复。
- **连接器要先于或同时更新**：中转的控制面要求 `?id=<connectorId>`，旧连接器不带它就 403
  （`docs/subsystems/connector-and-relay.md` §1.6）。

## 6.7 管理面板（中转自带，服务器上直接看）

中转自己提供一页只读+可管的面板：在线连接器（id / 人 / 连接时长 / 最后心跳）、
活跃通道（电脑 / 设备 / 用途 / 已转发字节）、按人额度、名册行数、令牌清单；
能改某人额度、重置用量、断开连接、吊销/恢复令牌；要彻底抹掉一条弃用身份，先吊销、再删除（活跃令牌不给删）。**没有独立的端口** —— 它挂在
中转同一个 `host:port` 的 `/admin` 下，所以安全组不用多开、反代不用多配。

1. **签一个管理令牌**（在容器里，摘要写回挂载的配置；明文只出现一次）：

   ```bash
   docker compose run --rm relay \
     node src/main.ts --config /config/relay.config.json --issue-admin ops
   ```

   输出里那串令牌存进密码管理器。配置里只会出现 `"admin": { "id": "ops", "hash": "…" }`。

2. **重启中转**让新配置生效（`docker compose up -d relay`），然后打开：

   - 有域名：`https://relay.example.com/admin`
   - 只有公网 IP：`http://<公网IP>:8787/admin`

3. **验证**（三条都要）：

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8787/admin          # 401
   curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer <CLI令牌>" http://127.0.0.1:8787/admin   # 200
   curl -s -H "Authorization: Bearer <CLI令牌>" http://127.0.0.1:8787/admin/api/state   # JSON：connectors/channels/quota/...
   ```

   4. **两个不要**：
   - 不要在**明文**（`http://`）路径上长期用面板：管理令牌和连接器令牌是同一个暴露面，
     链路上可读；有域名就放到 Caddy 后面（TLS 由它终结，面板自动跟着上）。
   - 不要在面板写配置的同时跑 `--issue-token` / `--revoke-token`：两个进程整份重写
     同一个 `relay.config.json`，后写的会覆盖先写的。串行操作。

   **默认不限制任何人**：中转一直在记账（面板能看到用量），但没人有上限，也就没人会被挡。
   要给某人设上限，就在面板那一行点「设上限」填字节数（会写回配置的 `quota.owners`）；
   点「改上限」留空 = 取消上限。面板写的是**按人**的上限；按连接器主体的临时覆盖
   只在本进程有效（配置里没有这一格），重启即回到"不限"。

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

