# Agent Note: 中转永不签发设备令牌（删掉 `--issue-token device`）

## Problem

v2 落地后留下一个**坏的工具面**：`relay/src/main.ts` 的 `--issue-token device <id>` 照旧往
配置摘要表里写 `{kind:'device'}` 条目，而 v2 的设备凭据面已经搬到**名册**（由电脑侧经
`POST /devices` 写入）。于是操作者照 CLI 的提示签一个设备令牌，手机拿去换票得到
**403 `wrong-credential-kind`**，而电脑侧一切正常 —— 症状指向"中转坏了"，真因是工具面
还停在 v1。

根子不止是顺序问题：`http-face.ts` 原来"先摘要表、后名册"，摘要有 device 条目时它先认领，
名册那条路就被跳过。但即使把顺序改成"先名册"，CLI 签的随机令牌名册里也没有对应摘要
（名册里只有电脑侧那个令牌的哈希），所以照样 403。

## Decision

**删掉这个能力，而不是修好它。**

- `TokenKind` / `TokenConfigEntry` 的 `kind` 收紧为 `'connector'`（编译期就堵住）；
- `--issue-token` / `--revoke-token` 只接受 `connector`，给 `device` 时**明确报错退出 2**
  并说明设备令牌该走哪条路；
- `createDigestAuthenticator` 表里出现 `device` 条目**直接抛错**，`main.ts` 捕获后打印
  原因与修法、以退出码 2 退出；
- `http-face.ts` 的认证顺序改成**先名册、后摘要表**，让"设备凭据面在名册"这条分层
  不依赖别处的校验也成立。

理由：中转签发设备令牌 = 转发器凭空造出"我是某台设备"的凭据，正是当初决定
"让连接器签、中转只存摘要"时否掉的形状（`remote-channel.md` §12.1：身份判定由电脑侧做，
中转只转发与记账）。留着它只会继续制造"签了却连不上"的困惑。

## Alternatives considered

- **把顺序改成先名册后摘要**（单独做）：修好"名册里有同一设备"的情况，但 CLI 签的令牌
  名册里仍然没有，403 照旧。而且它保留了一个违背设计的入口。否决（仅作为本次改动的一
  部分保留，因为它让分层更稳）。
- **让 CLI 把设备令牌摘要也写进名册**：那要求中转自己维护设备身份，与"名册由电脑侧写入"
  冲突，且引入第二个真值来源。否决。
- **启动时忽略 device 条目并打警告**：静默降级。操作者会以为令牌有效，然后在 403 上
  查半天。否决（本仓的纪律是入口配错就明确失败）。

## Consequences

- v1 时代的 `relay.config.json` **会起不来**：启动信息指明是哪一条、为什么、怎么修
  （删掉它，设备走配对流程）。这是明确的失败，不是降级。
- `Authenticated` 的唯一定义移到 `digest-auth.ts`（`http-face.ts` 再导出一次，
  老调用方不用改）；`http-face` 里 `caller?.kind !== 'connector'` 的 403 分支变成
  `caller === undefined`（两者等价，因为摘要表只放连接器）。
- 测试改了形状而非强度：`digest-auth` / `issue-token` / `revoke-token` 三个文件改用
  connector 身份，另加两条"device 条目被拒"（单元级 + 起真进程的启动级）。
  `server.test.ts` 里"device 摘要条目当连接器令牌 → 401"改成"不认识的令牌 → 401"，
  并把启动级拒绝补成独立用例。relay 74 → **75 项**。
- 设备吊销从此只走电脑侧（`devices.revoke` / 从名册摘掉），`--revoke-token device`
  也被拒并在错误信息里说明。
