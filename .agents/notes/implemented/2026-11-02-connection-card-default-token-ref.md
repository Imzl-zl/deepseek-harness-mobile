# Agent Note: 连接卡的 `relayTokenRef` 为空时落到默认格，而不是拒绝写令牌

Status: implemented

## Problem

`relayTokenRef` 空着是**合法且常见**的：连接器的自动兑换、拨号读取、cookbook 里的手工配置
都用默认格 `relay-connector`（`index.ts` 的 `tokenRef()`）。但面板的「连接」卡读的是配置原文：
空串就显示"凭据引用 —"、令牌"未设置"，保存时还直接回
`relayTokenRef 未配置：不知道令牌该写进哪条记录`。

结果是：用户从"去注册 / 登录"外链拿到令牌，回来粘贴时被面板拒绝；自动兑换过令牌的电脑，
面板也一直显示"未设置"——而拨号其实读得到。三处（自动兑换、拨号、面板）对"令牌放哪"
说法不一致。

## Decision

把默认引用收成一个常量 `DEFAULT_RELAY_TOKEN_REF = 'relay-connector'`（`dsh/relay-token.ts`），
三处都用它：

1. `index.ts` 的 `tokenRef()`：配置为空 → 默认格（行为不变，只是常量化）。
2. `readConnectionState`：配置里 `relayTokenRef` 缺席 / 空串 / 类型不对 → 默认格；
   并且**总是**按这个有效引用查令牌状态。
3. 保存：写/清令牌都用有效引用；**不改写配置里的 `relayTokenRef`**——空串仍然表示"用默认"。

准入门槛（可机械判定）：

- `readConnectionState` 返回的 `relayTokenRef` 永远是非空字符串（默认格或配置值）。
- `relayTokenRef` 为空 / 缺席时，`tokenStatusOf` 收到的参数必须是 `'relay-connector'`。
- 保存 `token.op = 'set'` 时，`writeToken` 的 ref 必须是 `'relay-connector'`，不额外写配置字段。
- 类型不是字符串的 `relayTokenRef` 不许被 `String(...)` 成别的 ref。

## Alternatives considered

1. **首次保存令牌时把 `relayTokenRef` 写进配置**
   - 最强的理由：配置里显式出现目标格，读的人一眼看得懂；以后改引用也有落脚点。
   - 为何被否：空串本来就是"用默认"的合法表达；为一次令牌写入多改一格配置、多一次 revision
     与冲突面，而值仍然是同一个默认格。显式化可以用文档解决，不必改用户配置。
2. **在连接卡里加一个 `relayTokenRef` 输入框**
   - 最强的理由：用户能自己选凭据格，多环境/多中转时更灵活。
   - 为何被否：它把内部凭据键暴露成产品字段，而自动兑换、拨号与 cookbook 已经约定默认格；
     多一个可编辑值就多一个"面板写 A、拨号读 B"的来源。真要换格，改配置比在卡里点更清楚。
3. **保持拒绝，提示用户先去 `cordis.patch.yml` 填 `relayTokenRef`**
   - 最强的理由：零行为变化，错误信息已经把"写哪条记录"说出来了。
   - 为何被否：新加的"去注册 / 登录"外链刚把令牌交到用户手里，回面板却贴不进去；
     新用户第一次配置就撞死，这不是"再改一处配置"能接受的路径。
4. **只在保存时兜底，读面继续回"未设置"**
   - 最强的理由：不碰读面的"不猜 ref"原则，改动更小。
   - 为何被否：自动兑换过的令牌仍然显示"未设置"，保存后下一次读还是"未设置"；
     面板与拨号继续各说各话，问题只被推迟到下一次刷新。

## Consequences

- 收益：令牌粘贴开箱可用；自动兑换/手工配置的令牌在面板里显示为已设置；三处只有一个引用名。
- 代价：配置里没有 `relayTokenRef` 时，面板也会显示 `relay-connector`（这是**有效值**，不是配置值）；
  读面会去查一条可能不存在的默认记录（`describeRecord`，代价可忽略）；旧测试里"缺席就不问凭据面"
  的断言被替换为"缺席就查默认格"。
