# Agent Note: 手机侧配对收口成两段（受限通道先建，秘密后发）

## Problem

上一轮把 `app/lib/core/` 改成了配对 v2（公开邀请 + 候选身份），但配对页与编排仍是 v1：
凭 `codeHash` 换票、发明文 `pair` 帧、拿到 SAS 之后再让用户点"开始连接"。
结果是两处同时坏：

- **编不过**：`handshake_driver.dart` 收了 `transcriptContext` 却忘了往下传
  （一个错让 9 个测试文件编译失败）；`pairing_flow.dart` 还在调已被删除的
  `ticketByCodeHash` / `encodePairFrame`。
- **语义错**：v1 的顺序是"先发秘密、再让用户核对 SAS"，而 v2 的硬不变量是
  **用户确认前不发送秘密、不创建有效设备记录、不签发长期令牌**（`pairing-v2.md` §5）。
  照 v1 的顺序接上去，界面看起来能用，只是唯一的授权凭据先出去了。

## Decision

按 `pairing-v2.md` §5 把这条链**做成两段**，并把协议细节收进一个新层：

- **`core/pairing_channel.dart`（新）**：候选受限通道。复用现有握手驱动与 `BoxCodec`
  （不造第二套密码学），差别只在三处授权边界：`pairingKeyInfo` 派生域、
  `pairingId = offerId`（临时标识）、`transcriptContext` 进被签字节；`open()` 只建通道，
  `commit(code)` 才发 `pair-commit`。
- **`core/pairing_flow.dart`**：`beginPairing()` 停在"通道已就绪、秘密未发"，
  返回 `PairingAttempt`；用户确认后 `commit()`。两段之间的停顿就是产品要的那一步。
- **`ui/pairing_page.dart`**：身份卡（电脑 ID / 中转 / 公钥指纹，全部来自二维码）
  → 「确认并配对」→ 完成卡（SAS 变辅助显示）。
- **帧层的三处 v2 更正**：`pair-commit` / `pair-result` 是**封箱帧**（`isPreKeysPlaintextFrame`
  只留握手三帧）；握手门禁只放行握手三帧（与 `connector/src/transport/codec.ts:132` 逐字对齐）；
  业务客户端的 `pairingFrames` 探针删除（配对已不走业务连接）。
- **地址所有权收成一处**：升级 URL 从 `platform/ticketed_transport.dart` 挪到
  `core/endpoint.dart` 的 `deviceUpgradeUrl()`，配对链与正式连接共用它；
  `allowInsecureLocal` 一路透到地址边界（生产只认 wss，明文只给显式开启的本机调试）。
- **回执诊断点名到字段**：`parsePairAck` 的格式校验逐个字段做，错误信息说出是哪个字段
  （不带字段值 —— 令牌是凭据）。

## Alternatives considered

- **保持一段式，把 SAS 放在提交之前**：那要求先提交秘密才拿得到 SAS，顺序天生矛盾；
  且 v2 明写 SAS 不再是授权门（授权来自二维码固定的电脑身份 + 候选持钥证明 + 秘密校验）。
  否决。
- **让配对也走业务连接（`SyncClient` 加一个"配对模式"）**：业务连接有退避重连、订阅、
  发件箱，它们对一次短交互都是负担，而"只允许保活与 pair-commit"这条收口会散在
  业务分支里。否决（单开一层，收口集中在一处）。
- **`pair-commit` 不封箱（照 v1 的明文例外）**：载荷就是配对码，明文上线等于把凭据交给中转。
  否决。
- **保留 `pairingFrames` 探针**：它让业务客户端"顺手收集配对帧"，是 v1 的连接模型残留，
  且没有消费者。删除（属于"删除过时兼容路径"）。

## Consequences

- 用户面对**两次点击**（连接电脑 / 确认并配对），而中间那一步是真正的安全门：
  确认前电脑侧连这台设备的记录都没有。
- 页面会在用户阅读期间**持有一条候选连接**：因此通道要回 `pong`（否则电脑侧半开判据会在
  用户还在看的时候关掉它），退出页面要 `cancel()`，提交后立刻 `close()`。
- `PairingPage` 多一个 `allowInsecureLocal`（装配点按 `kDebugMode` 传），
  它与二维码解析的同名参数是同一条边界的两处 —— 少了任何一处都会出现"码认了、票换不了"。
- Dart 侧发起方与**真电脑侧**的互操作**尚未验证**：`test/support/fake_pc.dart` 是同一份
  契约的 Dart 替身，只证明"手机侧符合契约"；跨端证据仍待真机用例
  （`integration_test/channel_e2e_test.dart`，需在跑的中转与连接器）。
