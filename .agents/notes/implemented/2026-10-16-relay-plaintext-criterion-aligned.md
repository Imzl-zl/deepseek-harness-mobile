# Agent Note: 中转明文判据对齐到手机侧（无线引导不再被校验器堵死）

Status: implemented

## Problem

要把真机联调从"USB 引导"改成**无线引导**：二维码里的 `relay:` 字段取自连接器配置
（`connector/src/pairing.ts:155`），所以只要把它指向局域网地址，手机扫码就能拨到局域网的
relay —— 全程不插线。

改完配置重启 profile，插件**直接挂载失败**：

```
validate-config: 中转必须使用 WSS；仅显式开启的本机调试允许明文
```

根因不是配置写错，而是**两套判据漂了一次**：

| 侧 | 明文 `ws://` 的放行判据 |
|---|---|
| 手机 `app/lib/core/endpoint.dart:27-35` | `allowInsecureLocal && isPrivateOrLoopback(host)` —— 2026-10-14 已扩到"回环 + 私网 + CGNAT + link-local + ULA" |
| 连接器 `connector/src/transport/relay-url.ts:4`（改前） | `allowInsecureLocal && ['localhost','127.0.0.1','[::1]'].includes(hostname)` —— **只有回环** |

`192.168.2.43` 在手机侧被放行、在连接器侧被拒。而这条链路里**必须**是私网地址
（手机要从 WiFi 拨过来），于是"无线引导"被自己的校验器堵死。

## Decision

**把连接器侧判据对齐成手机侧那一套**，并用**同一批地址**钉住，避免再漂：

1. `relay-url.ts` 抽出 `isNonPublicHost(host)`，语义逐条照 `isPrivateOrLoopback`：
   IPv4 四段私网（10/8、172.16/12、192.168/16）+ CGNAT 100.64/10 + link-local 169.254/16
   + IPv6 前缀（`fe80::/10` / `fc00::/7`）+ `::1` 单独认 + IPv4-mapped。
2. **IPv4-mapped 认两种形状**：安卓报 dotted（`::ffff:192.168.1.1`），
   而 WHATWG `URL` 把同一地址归一成十六进制（`::ffff:c0a8:101`）—— 只认一种就会漏。
3. IPv6 字面量在 `url.hostname` 里带方括号，判据前剥掉，与手机侧 `Uri.host` 形状对齐。
4. `new URL` 解析失败时包成明确错误（`ws://` 不是 WHATWG 的特殊 scheme，少写端口就走到这），
   不让裸 `TypeError` 冒到调用方面前。
5. 新增 `connector/tests/relay-url-nonpublic.test.ts`（25 条）：22 个非公网地址逐条放行、
   9 个公网地址逐条拒绝、边界三条（172.32 / 172.15 / 192.169）、凭据查询片段三条。
   **期望值来自手机侧那份实现的语义，不是手抄常量** —— 谁先改判据谁先红。

## Alternatives considered

1. **只改配置、不动代码**（例如让二维码带 loopback 地址）。
   - 最强的理由：零代码改动。
   - 为何被否：loopback 在手机的 WiFi 上拨不通，`ws://127.0.0.1:8787` 只在 `adb reverse` 下成立 ——
     那正是要消除的东西。
2. **在连接器侧另立一套"私网判据"**（写死 192.168/16 就够用）。
   - 最强的理由：改动更小。
   - 为何被否：这正是刚犯过的错 —— 判据分居两处必漂。要做就做成同一语义 + 同一批向量。
3. **把 relay 也关掉，手机只走 direct**。
   - 最强的理由：少一个组件。
   - 为何被否：`direct` 端点是**连上之后**才由 `endpoint.describe` 学到的，
     冷启动时端点表里没有它 —— 没有引导通道就永远学不到。

## Consequences

- 收益：**真机联调全程无 USB**。冷启动（`force-stop` + 重启）后手机自己连上，
  电脑侧稳定保持 `192.168.2.43:8790 ← 192.168.2.29:41138 ESTABLISHED`；
  连接器也改拨局域网 relay（`192.168.2.43:8787`），不再依赖 loopback。
- 配套（都在 `~/.dsh/profiles/dsh-mobile-test/cordis.patch.yml`，gitignore，换机器要重配）：
  `relayUrl` 指向 `ws://192.168.2.43:8787/ws/connector`；`listenPort: 8790` + `listenHost: 0.0.0.0`。
  relay 的 `relay.config.json` 的 `host` 也改成 `0.0.0.0`。
- 代价：电脑在局域网上多两个明文 `ws` 口（relay 8787 + 直连 8790）。鉴权仍分别是
  连接器令牌与 §4.1 握手本身（未配对设备在 `hello` 处被 `protocol/not-paired` 拒）；
  代价是**元数据可见**，与 2026-10-14 直连落地时记的取舍同一条。
- 门禁：connector `tsc` 0 / **477 通过 0 失败**（+25 即新文件）/ build ✓；
  `app` 侧未改代码，`verify-platform-boundary` 234 ✓。
- **遗留**：① 电脑换 IP / 手机换 WiFi 后，二维码里的 relay 地址会过期 —— 要重新出码
  （管理面 `POST /api/dsh-mobile/pair` 直接出，不建会话、不花 token）；② 手机端**端点选择器 UI 仍未做**
  （`AppModel` 已备好 `endpoints`/`activeEndpoint`/`preferEndpoint`），地址变了用户无法手改。