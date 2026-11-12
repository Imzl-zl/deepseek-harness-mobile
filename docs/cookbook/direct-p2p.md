# 手机和电脑点对点直连（不经任何服务器）

**目标**：手机 ⇄ 电脑之间**不经过第三方转发**，各自用自己家的网络。
两条路都能做到，代价不同。

| 方案 | 要不要装东西 | 打洞失败时 | 首次配对能否远程 |
|---|---|---|---|
| **Tailscale**（推荐） | 两端各装一个 App | 走 Tailscale 的 DERP 中继（**这时就经过服务器了**） | 能（tailnet 地址是 CGNAT，面板可上报） |
| **公网 IPv6** | 不装 | 没有失败这回事，通就是通 | **不能**（`ws://` 公网面板不收，先在家配对一次） |

> **为什么不内置"打洞"？** 打洞要做 STUN/ICE、NAT 类型探测、中继兜底，
> 而手机蜂窝网大量是 CGNAT / 对称型 NAT —— 双方都在 CGNAT 后面时打洞**必然失败**，
> 最后还是得中继。Tailscale 已经把这套做完了（含 DERP 兜底），
> 所以本项目的打洞答案就是它（`docs/subsystems/remote-channel.md:56`），不自己再造一遍。

## 一、Tailscale

### 1. 两端都装、登同一个账号

- 手机：应用商店装 Tailscale，登录。
- 电脑：装 Tailscale，登录同一个 tailnet。
- 电脑上取自己的 tailnet 地址：

```pwsh
tailscale ip -4        # 形如 100.101.102.103
```

### 2. 让连接器把这个地址报给手机

DSH →「手机」面板 →「通道与地址」→「更多地址」→ 把

```
ws://100.101.102.103:8790
```

加为**上报**（`extra`）。`100.64/10` 属于 CGNAT，电脑侧判据认它，不需要开任何明文开关。

**为什么不自动出现**：默认只上报"默认路由那张网卡的 IPv4"（避免 VMware 虚拟网卡和
轮换的 IPv6 占满手机列表），tailnet 地址要你点名一次。

### 3. 验证"是不是真的点对点"

这是**唯一能证明没走服务器**的判据，在电脑上跑：

```pwsh
tailscale ping <手机在 tailnet 里的设备名>
```

- `pong from phone (100.x) via 192.168.x.x:41641` → **点对点**，不经服务器
- `pong from phone (100.x) via DERP(hkg)` → 走中继了，**这时经过 Tailscale 的服务器**

想看它为什么没打洞：`tailscale status` 里那一行会带 `direct` 或 `relay "xxx"`。
酒店/公司网络、双 CGNAT、UDP 被封，都会退化成 DERP —— 那不是 bug，是 NAT 的物理限制。

### 4. 配对

正常出码扫码即可：二维码里的 `lan` 数组现在包含这条 tailnet 地址，
**手机在任何网络下都能扫**（`connector/src/pairing.ts:275`）。

### 5. 为什么它算"打洞"

- 数据面是 WireGuard：打洞成功时两端直接收发，**没有任何服务器看到流量**。
- 控制面（谁在哪、密钥）始终走 Tailscale 的协调服务器 —— 它知道你的设备在线的，
  但看不到内容。这一点要说清楚：**"点对点"指数据面，不等于"零服务器依赖"**。

## 二、公网 IPv6（真正零第三方）

前提：家宽有 IPv6（光猫拨号一般会下发 `/64`），手机网络也有 IPv6
（移动/电信/联通的 4G/5G 基本都有）。

### 1. 电脑侧改监听地址

面板**不能**改这一项（白名单只有 `relayUrl` / `allowInsecurePublic` / `listenPort`），
得改 profile 的 `cordis.patch.yml`：

```yaml
- id: dsh-mobile-connector
  config:
    listenPort: 8790
    listenHost: "::"        # 双栈：IPv4 与 IPv6 都收（默认 0.0.0.0 只有 IPv4）
```

改完重启 DSH。**先验 IPv4 没坏**：手机连同一 WiFi 仍能直连（`ws://192.168.x.x:8790`）。
若系统关了双栈（`net.ipv6.bindv6only=1`），`::` 会只收 IPv6 —— 那就改成具体的 GUA。

### 2. 取电脑的 IPv6 地址

```pwsh
Get-NetIPAddress -AddressFamily IPv6 |
  Where-Object { $_.IPAddress -notlike 'fe80*' -and $_.IPAddress -ne '::1' } |
  Select-Object IPAddress, InterfaceAlias, PrefixOrigin
```

要的是 `2408:` / `240e:` / `2409:` 开头的 GUA（`Temporary` 的隐私地址会轮换，优先 `Public`）。

### 3. 路由器放行入站

IPv6 没有 NAT，但家用路由器默认有防火墙。在路由器的 IPv6 防火墙里给这台电脑的 GUA
放行 **TCP 8790**（关掉"阻止入站"或加一条允许规则）。各家界面不同，这是**最容易失败的一步**。

### 4. 手机手填那条端点

**不要指望面板上报它**：电脑侧 `extra` 只收 `ws://` + 非公网（`connector/src/admin/advertise.ts`），
而 GUA 是公网地址 —— 那一条是刻意留的，公网明文必须由你在手机上逐次确认。

设置 →「添加端点」→ 直连 →

```
ws://[2408:xxxx:xxxx::1]:8790
```

→ 勾「公网明文」确认。

**验收**：手机断开 WiFi、只留移动数据，浏览器先试

```
http://[2408:xxxx:xxxx::1]:8790/
```

- 几秒内报「连接被重置 / HTTP 错误」→ 端口通了（WS 服务不接受普通 GET）
- 一直转圈到超时 → 防火墙还是挡着

然后回 App 里拨这条端点（或重连一次）。

> 家里有域名 + 证书、又把它解析到这条 IPv6 的话，可以反代 / `tailscale serve` 终结 TLS
> 换成 `wss://` —— 那一档面板可以上报，首次配对也能远程扫。

### 5. 地址会变

家宽 IPv6 前缀在重拨后会变，手机里那条就废了。两个办法：

- 路由器上开 DDNS（很多路由器自带 `dynv6` / `No-IP`），手机填 `ws://[域名]:8790`
  —— 但 `ws://` + 域名会被判成公网，仍要勾确认（而不是按 IP 判）；
- 手动：前缀变了就回手机把那条端点改一次（面板本来就收不了 `ws://` 公网）。

## 两条路都适用的边界

- **首次配对**：Tailscale 能远程扫（`lan` 数组里带的就是 tailnet 地址）；
  IPv6 明文那一档不能 —— 面板不收 `ws://` 公网，所以请先在同一 WiFi 配对一次，
  或先用中转配对一次，再手填 IPv6 端点。
- **明文**：IPv6 那条是 `ws://` + 公网地址 → 手机必须勾一次「公网明文」；
  Tailscale 的 `100.64/10` 属 CGNAT，明文直接放行，不用确认。
  内容仍逐帧 AEAD，暴露的是元数据。想要 TLS 就把反代 / `tailscale serve` 放到监听面前面。
- **直连建连预算是 3 秒**（`app/lib/platform/transport_factory.dart`）。
  IPv6 跨境或 Tailscale 打洞中继切换时偶尔会超，超了自动拨下一条端点。
  所以**保留一条中转当兜底**仍然值得。
- **Tailscale 被墙时的现实**：国内网络下 Tailscale 的控制面（`login.tailscale.com`）
  与 DERP 可能不稳，打洞成功与否取决于网络。这不是本项目能解决的，
  所以它没有替代中转，只是多一条路。
