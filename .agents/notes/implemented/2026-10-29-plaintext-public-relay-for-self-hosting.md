# Agent Note: 明文放行分两档——非公网常开，公网只认用户确认

Status: implemented

## Problem

`allowInsecureLocal` 一直绑在 `kDebugMode` 上（`main.dart` 两处）。后果比"调试方便"大得多：

- **release 包只认 `wss://`**，于是局域网直连与组网（Tailscale 的 100.64/10）在正式包里
  全部不可用 —— 而这两条正是"低延迟直连"这个功能存在的理由；
- 自部署中转的用户没有域名/证书（国内域名与证书都有审核周期），拿不到 `wss`，
  在 release 里**根本连不上自己的中转**；
- 手机侧也没有"接受自签证书"的缝（全仓无 `badCertificateCallback` /
  `SecurityContext` / `onBadCertificate`），所以"自签 + wss"这条路同样走不通。

## Decision

把明文拆成**两档**，判据仍然只有一处（`core/endpoint.dart` 的 `checkedRelayUri`）：

1. **非公网**（回环 / 私网 / CGNAT / link-local / ULA）：`allowInsecureLocal`，
   装配层**常开**（`allowInsecureLocal: true`）—— 局域网直连、组网直连在所有构建可用。
2. **公网**：`allowInsecurePublic`，**只认用户显式确认**。确认落成用户级偏好
   `net.allow_plaintext_public`（`AppModel.allowPlaintextPublic` / `setAllowPlaintextPublic`），
   重启后仍认。
3. `wss://` 任何主机始终放行（域名或 IP 都行）。

准入门槛（可机械判定）：

1. 公网 `ws://` 在没有 `allowInsecurePublic` 时**必须被拒**（`test/endpoint_test.dart`
   的"公网 ws 默认被拒"）。
2. 确认点**只有两个**：手填端点对话框的勾选、配对页确认卡（那一步把电脑身份摆出来）。
   确认文案必须写明"内容仍端到端加密，网络上的元数据（帧大小与时序）可见"。
3. 确认是**用户级**的（一次确认，之后该用户的自部署明文都放行）——
   按 URL 记会变成"每加一条地址确认一次"，且换票路径要按 URL 查表，多一个真值。
4. 换票路径（`PairingClient`）与配对页、手填对话框**必须用同一个判据**，
   否则会出现"配上了、票换不了"（2026-10-13 真机踩过）。

## Alternatives considered

1. 只允许"公网 IP + Let's Encrypt 的 IP 证书"（`letsencrypt.org/2025/01/16/6-day-and-ip-certs`）
   - 最强的理由：零代码改动、端到端 TLS 保护元数据，安全面最干净。
   - 为何被否：它是**运维门槛**，不是每个人都能马上做到（要 80/443 挑战、6 天自动续期、
     域名审核周期）；作为"唯一路径"会把自部署卡死。文档里仍把它列为推荐。
2. 自签证书 + 指纹固定（`IOWebSocketChannel.connect(customClient:)` → `badCertificateCallback`
   只认钉住的 SHA-256）
   - 最强的理由：仍然走 TLS，元数据也加密；技术上已核实可行（`web_socket_channel-3.0.3`
     的 `customClient` 参数、Dart SDK 的 `WebSocket.connect`）。
   - 为何被否：先连先信（TOFU）在首次连接时仍可被中间人；要再配一套"指纹在哪看、
     怎么核对"的 UI 与存储。**留作下一步**，不是这次的范围。
3. 保持现状（debug 才放明文）
   - 最强的理由：安全面最小，release 永远只有 TLS。
   - 为何被否：release 里局域网直连与组网都不可用 —— 与功能目标直接冲突。

## Consequences

- 收益：release 可以跑局域网直连、组网直连、以及"纯 IP 自部署中转"；
  用户不必为了内网直连专门用 debug 包。
- 代价：**公网明文会让网络看到元数据**（帧大小与时序）；这意味着"内容保密"与
  "流量不可观察"从此是两件事，必须在确认文案与文档里说清，不能只写"已加密"。
- 代价：确认是用户级的，粒度粗 —— 用户确认过一次之后，任何公网 `ws://` 都放行。
  要更细就得按 URL/host 记，那条会在换票路径上引入第二个真值（因此这次不做）。
- 内置中转仍然应该是**域名 + wss**（IP 会变、IP 证书 6 天要续），自部署才用明文档。
