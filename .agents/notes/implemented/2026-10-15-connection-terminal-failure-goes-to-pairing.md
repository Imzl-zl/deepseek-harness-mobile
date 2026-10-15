# Agent Note: 身份不被认是终态 —— 清凭据回配对页,不再是无限重连

Status: implemented

## Problem

设备被停用、或记录被删之后,手机的表现是**永远"重连中…"**:换票拿 401 → 退避 →
再换票再 401。用户原话:"下午连了一次,断开后一直显示重连、想重新扫码也进不去页面"。

三层原因叠在一起:

1. **契约与错误表规定了动作,却没有人执行。** 契约 §11 故障矩阵和
   `app/lib/core/errors.dart`(`notPaired` / `revoked` → `ClientAction.rePair`)都写着
   "清除本地凭据,回配对页",但 `ClientAction` 在整个 `app/lib` **没有任何消费者**。
2. **错误码在传递中被丢掉。** `ticketed_transport.dart` 把换票被拒的
   `ProtocolException`(带着 `notPaired` 码)转成 `TransportException` 时**只留 message**,
   于是连接层分不清"身份不被认"和"网络不通",一律进退避。
3. **中转不区分原因,手机也不该假装知道。** 401 的 body 只有 `{error:'unauthorized'}`
   (`relay/src/http-face.ts:61`),`relay/src/issue-token.ts:89` 原话:"将来可以把'你被吊销了'
   与'这个令牌没见过'分开告诉设备 —— 今天两者都是 401"。

顺带:重新配对入口在 ChatPage **不存在** —— 顶栏状态位点开的是侧抽屉,空态「连电脑(配对)」
只在未配对时出现;唯一出口是抽屉连接行,从 ChatPage 数要 3 步。

## Decision

**只改手机侧,不动协议**(用户拍定:三者的恢复动作相同,精确原因只是 diagnostics;
改协议要动契约 + relay + connector + 486/49 两道门禁)。

1. **码一路透传**:`TransportException` 加可选 `ErrorCode? code`;
   `TicketedWebSocketTransport` catch `ProtocolException` 时把码带上;
   `EndpointTransport` 对终态错误**直接 rethrow,不换端点** —— 否则换到 direct 会把 401
   掩盖成握手层的 close 4003,码又丢了。
2. **终态用 `closed` + 一个标志表达,不给状态机加新 state**:
   `_lastConnectWasTerminal = clientAction == ClientAction.rePair`。终态**不退避**,
   `start()` 直接挡回。这同时避掉一个真崩溃:终态停留 `closed` 后,一次 resume 会让
   `setAppState(foreground)` 把 `closed` 当"该重连"调 `start()` → `closed → connecting`
   **非法迁移**(已有回归用例 + 变异校验:删守卫即红)。
3. **`ClientAction` 的执行处只有一处**:`app/lib/data/connection_recovery.dart` 的
   `ConnectionRecovery`。`rePair` → 清凭据 + 回配对页 + 人话提示;别的动作 → `report`,
   **无静默兜底**。UI 层零 `if (code == notPaired)`。三个副作用(clearCredentials /
   openPairing / report)全部缝注入,于是"清了凭据且回了配对页"能被纯 Dart 单测直接断言。
4. **手动与自动收敛到同一个 `repair()`**:换电脑(议题 3)与被停用(议题 2)是同一件事。
5. **议题 3 的入口**:顶栏连接状态位**已配对时常驻**、点它弹共享连接操作 sheet
   (重新配对 / 打开侧面板 / 断开并清掉凭据 / 取消);空态在 `paired` 时加 1 步直达按钮;
   抽屉原路保留。判据写成 widget 断言:**三个代表状态各 ≤2 次点击触发重新配对**。
6. **提示照实,不假装知道原因**:`这台电脑已不再认可本机(可能已停用,或凭据已失效)。
   请重新扫码配对。`

## Alternatives considered

1. **改协议:让 relay / connector 把"被停用"和"令牌没见过"分开过线**
   - 最强的理由:手机能说精确原因("这台电脑移除了你");契约 §11 那行也就不必改;
     诊断价值高。
   - 为何被否:用户拍定只改手机侧;三者恢复动作相同;改动面是契约 §3.1/§11 + relay +
     connector + 手机解析 + 486/49 两道门禁,而收益只是一句更精确的文案。
2. **给连接状态机加一个 `terminal` state**
   - 最强的理由:"不再重连"是状态机的一等事实,比一个 bool 标志显性;
     `closed` 的既有语义是"连接结束,会退避"。
   - 为何被否:要动迁移白名单、退避表、presence 上报与全部既有用例;而标志位 +
     `start()` 守卫 + `AppModel` 一个连接周期只呈递一次就够。代价见下(遗留路径)。
3. **重配入口放进设置页**(照原型 IA:设置 → 关于与连接 → 设备管理)
   - 最强的理由:与交互基线一致,设置页本就是这类入口的家。
   - 为何被否:app 的设置页还是 `_notYet` 占位;为它先建一页设置超出本轮范围;且那条路
     从根界面数要 4 步,不满足"两步内"。**列为设置页落地后的归宿。**

## Consequences

- 收益:转圈消失;清凭据 + 回配对页 + 人话提示;≤2 步判据有断言;
  `ClientAction` 从"规定了不执行"变成有唯一执行处;顺手修掉一个会崩的非法状态迁移。
- 代价:
  - **两条遗留路径仍会退避而非终态**:握手层的 `protocol/not-paired` 以 WS close
    4003 + reason 到达(`_onTransportEvent`,没有 `ProtocolException`,不走
    `_connectFailure`);契约的 `protocol/revoked` 连接器按设计**从不发**,若真以帧到达
    走 `_protocolFailure` 也不判终态。两者按讨论笔记都是罕见兜底,本期按"换票 401"
    主路径收口。要收口需在 close-code / 帧路径也判 `rePair`。
  - **顶栏状态位与设计文档规定的内容(任务/文件变更)冲突**,已按项目规则记为有意偏离
    (见 `docs/design-and-tech-plan.md`);等任务/文件计数接进状态位时,连接态改为仅非
    serving 时常驻。
  - 老 `AppModel` 重装配时未 dispose 旧客户端(既有行为,未在本次改,避免扩大 diff)。
