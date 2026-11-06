# 默认只上报主地址：端点候选不再自动变成手机端点

Status: implemented

## Problem

2026-11-06 真机，电脑侧「手机」面板的「上报给手机的地址」把网卡枚举结果原样列出：
WLAN 2（`192.168.2.58`）、VMware VMnet1（`192.168.40.1`）、VMnet8（`192.168.235.1`）、
三条 IPv6 GUA，每行一个「删除」。用户原话：

> 有的系统虚拟机地址，有的其他地址，根本用不上吧？能用的就是主机的 IP 地址吧？这不是多余？

监听面枚举全部非内部网卡是**有意的**（`connector/src/transport/listener.ts:143-167`：
按网卡名过滤又脆又漏），但「候选池」被直接当成了「上报集合」。手机因此收到一堆
永远拨不通的端点，面板也要用户逐条删。

## Decision

**默认上报集合只含默认路由那张网卡的 IPv4**，判据收敛到
`connector/src/endpoints.ts` 的 `defaultDirectUrls()`：

1. `lanHint`（`lan-address.ts:40` 的 `defaultRouteIPv4()`，内核选路、不发包）命中的那条；
2. 拿不到 hint 时，**只有唯一一条候选**才默认报（显式绑定 `listenHost` / 单网卡机器）；
3. 多候选且没有 hint ⇒ 一条都不默认报。

其余网卡地址仍是候选，进面板「更多地址（N）」折叠区，用户点名 `extra` 才上报；
`hide` 仍可藏掉默认那条。二维码里的 `lan` 与 `endpoint.describe` 用**同一份**默认集合
（`describeEndpoints`），不另写一套。`advertise` 的 `hide`/`extra` 语义不变。

## Alternatives considered

1. **保持全报，只把默认路由排第一（改动前）**
   - 最强的理由：第二张网卡 / Tailscale 可能才是手机拨得通的那条；全报给手机留了回落。
   - 为何被否：手机端点是**用户可见列表**，不是内部候选池；默认路由通常就是手机所在
     局域网，其余地址先占位置、再让用户逐条删。回落的价值由 `extra` 保留，不需要默认全报。
2. **只报 IPv4，IPv6 收进折叠区**
   - 最强的理由：IPv6 GUA 会因隐私扩展轮换，是最典型的"拨不通还占位"。
   - 为何被否：VMware 的 IPv4 虚拟网卡同样拨不通；只按地址族过滤只解决一半，
     仍要用户逐条删。
3. **按网卡名过滤虚拟网卡（VMware / Docker / vEthernet…）**
   - 最强的理由：实现直观，能精确命中用户截图里那两条。
   - 为何被否：网卡名随系统语言、驱动版本、虚拟化产品变化，是典型的"又脆又漏"；
     `listener.ts` 当初拒绝这条路，现在也不该从另一端把它加回来。
4. **把默认集合写进配置（用户先选一次）**
   - 最强的理由：最可控，绝不替用户猜。
   - 为何被否：换 WiFi / DHCP 换地址后配置就过期；而且"哪张网卡是主网卡"本来就是
     内核选路的事实，让用户重填一遍是重复劳动。

## Consequences

- 收益：手机上默认只有一条直连 + 一条中转；面板一打开就是"能用的那条"，VMware 与
  轮换 IPv6 不再占位；用户仍可显式上报第二张网卡。
- 代价：默认路由不是手机所在局域网时（双网卡、默认路由走 WAN），直连默认不生效，
  用户要到「更多地址」里点名上报；没有默认路由且多候选时只剩中转 —— 这是如实结果，
  不猜。二维码的 `lan` 也随之只带主地址，跨网配对仍靠中转。
- 证据：`connector/tests/endpoints.test.ts`（默认集合 / 无 hint 多候选 / 单候选）、
  `connector/tests/advertise.test.ts`（folded / hide / extra）、
  `connector/tests/client-panel.test.ts`（折叠区与上报）。
- 契约：`docs/subsystems/remote-channel.md` 的 `endpoint.describe`、`lan`、IPv6 三条；
  `docs/subsystems/pairing-v2.md` 的 `lan` 一条。
