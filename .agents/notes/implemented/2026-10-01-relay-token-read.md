# Agent Note: 连接器令牌的读取 —— 读不到就大声失败，不编一个、不返回空串

Status: implemented（`src/dsh/relay-token.ts` + 4 条用例；`/pairing/register` 的调用与命令接线见"仍未做"）

## Problem

上一轮把"出码登记"的核心写好了，但登记调用要带 `Authorization: Bearer <连接器令牌>`，
而**令牌怎么读**我还没查证过 —— 按项目规则（禁止猜）当时没有写这个调用。本轮先做这次查证：

- `credentialKey(scope, id)`，两段都须匹配 `^[a-z][a-z0-9-]*$`（`packages/credentials/credentials/src/index.ts:22,69`）；
- `readRecord(key)`（同文件 `:217`）；`modifyRecord` 是唯一写路径（`:236-250`）；
- 记录面的 `payload` 按定义由插件自己解释（`packages/credentials/credentials/src/types.ts:52-57`）。
- 现成范式：`IDENTITY_RECORD = credentialKey('dsh-mobile-connector', 'identity')`（`dsh/identity.ts:31`）。

## Decision

`src/dsh/relay-token.ts`：`readRelayToken(credentials, ref) → Promise<string>`，
记录键为 `credentialKey('dsh-mobile-connector', ref)`，载荷取 `{ token: string }`。

三条判断，**全部朝"大声失败"的方向**：

1. **记录不存在 → 抛**，不生成。连接器令牌是**带外配好的**（操作者把中转签发的令牌放进凭据 seam），
   插件自己编一个只会得到中转不认识的令牌 —— 症状是"连不上"，与"没配令牌"难以区分。
   这与身份记录的行为**故意不同**：身份是"没有就生成"（它是我们自己的密钥对），
   而令牌是别人签发的凭据，我们无权生成。
2. **记录类型不对 → 抛**（不静默当成"没配"）：读到别人的 `oauth` 记录时，
   静默返回 `undefined` 会把排查方向引到配置上。
3. **不返回空串**（载荷里没有非空 `token` → 抛）：空令牌会退化成"匿名连接"，
   中转回 401，症状与"没配"一样却更难关联。

**不缓存**：每次要令牌时现读。凭据面是带锁的记录面，读一次很便宜；缓存反而会在操作者
更新令牌后继续用旧的 —— "改了没生效"是最难查的一类。

准入门槛（可机械判定）：4 条用例 —— 读得到且**读的是那个具名记录**（`CredentialKey` 是品牌类型，
只能整体比对）、记录不存在、类型不对、载荷缺 `token`（三种坏载荷）。

## Alternatives considered

1. 记录不存在时生成一个随机令牌
   - 最强的理由：与身份记录一致（"没有就生成"），插件总能起来。
   - 为何被否：**方向反了**。身份是我们自己的密钥对，生成它天经地义；令牌是中转签发的凭据，
     本地生成只会得到一个中转不认的串。那会把"配置缺失"变成"连接被拒"，
     而两者的排查入口完全不同（配置 vs 网络）。
2. 读不到就返回 `''`，让中转的 401 来暴露问题
   - 最强的理由：少三个错误分支。
   - 为何被否：空令牌是**匿名连接**，中转可能按"未认证"而不是"令牌错误"处理；
     而且日志里只会看到一次 401，指不回"凭据里缺了一条记录"。
3. 缓存令牌（避免每次出码都读凭据）
   - 最强的理由：凭据读取有锁，理论上可以省一次。
   - 为何被否：出码是低频操作（人手点一次），省不到什么；而缓存会带来"操作者换了令牌、
     插件还在用旧的"这种静默不一致。

## Consequences

- 收益：连接器侧读令牌的路径就绪且被测；四种失败都是明确的错误（不是静默降级）。
- 代价：`credentialKey` 会在 `ref` 不符合 `^[a-z][a-z0-9-]*$` 时抛错 —— 那是**好事**（配置错误当场暴露），
  但错误来自 DSH 而不是我们，所以文案里保留了原始信息。
- **仍未做（下一轮）**：
  1. **`POST /pairing/register` 的调用**：读令牌 → `POST ${relayUrl}/pairing/register`
     （body `{codeHash}`，Bearer 令牌）→ 失败即"不出码"（出码核心已按这条实现并测过）。
     一处**待查证**：连接器的 WS 拨号要带 `Authorization` 头，而 Node 的全局 `WebSocket`
     **不支持自定义头** —— 这会影响"连接器用不用 `ws`"那个结论（第 33 轮的笔记说它零依赖），
     下一轮先查证再改。
  2. **命令接线**：`ctx.commands.register({ name:'dsh-mobile-pair', description, handler })`
     （API 已在第 22 轮查证）。
