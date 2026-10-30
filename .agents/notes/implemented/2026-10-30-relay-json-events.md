# Agent Note: 中转日志改成一行一个 JSON 事件（中转可观测/限额/面板 第 3 批）

Status: implemented

## Problem

日志是"中文句子 + 可选 detail"（`main.ts` 里的 `console.*` 注入）。人能读，
但**检索不了**：要回答"这台连接器这个月被限流几次""哪条通道被谁关了、关闭码是多少"，
只能拿正则去猜句子，而句子随时会为可读性改写。同时有几处关键事件根本不存在：
拒票是静默的（`server.ts` 对 401 只 `refuse`）、票签发只有一句 debug、通道关闭没有
"谁关的 / 什么码"的记录。

## Decision

1. **一行一个 JSON 事件**：`json-logger.ts` 实现既有的 `ChannelLogger` 接口，
   字段固定 `ts / level / evt`，`detail` 里的对象**平铺**进同一行；`evt` 是短名
   （`channel.open`），不是句子。
2. **保留字段不可被覆盖**：`detail` 里出现 `ts/level/evt` 一律忽略。
3. **长字符串截断到 512 字节**：这是对"误把整帧/整份名册塞进日志"的兜底
   （不靠纪律，靠代码）。`Error` 只留消息、不留栈（一行一条）。
4. **事件清单**（新增的加粗）：
   `connector.open` / `connector.close` / **`connector.id-mismatch`** /
   `roster.applied` / `roster.refused` / `ticket.issued` / **`ticket.rejected`** /
   `channel.open` / `channel.close`（带 `code`/`reason`/`bytes`/`ms`）/
   `admission.rejected` / **`channel.error`** / `delivery.failed` / `quota.rejected`。
5. **不记内容**：帧载荷、令牌、`tokenHash`、配对秘密一律不进日志（契约 §12.2）。
   `debug` 级默认关，`DSH_RELAY_DEBUG=1` 才开；帧级日志本来就没有。

## Alternatives considered

1. **保留文本 + 在 detail 里塞结构**
   - 最强的理由：改动最小，人读起来还是顺的。
   - 为何被否：检索仍然依赖句子前缀，且"事件名"没有唯一拼写 —— 同一件事在两个文件里
     写成两句话，查询就断成两半。
2. **引入 pino / winston**
   - 最强的理由：生态成熟，序列化、采样、轮转都是现成的。
   - 为何被否：中转的依赖只有 `ws`，而日志面只有 12 个事件；多一个依赖等于给
     `node:24-alpine` 镜像多一层供应链面，换来的能力这里用不上（轮转在容器侧）。
3. **日志写文件 + 自己做轮转**
   - 最强的理由：不依赖容器日志驱动，直接 `tail` 文件更直观。
   - 为何被否：容器已经有 `json-file` 的 `10m × 3` 封顶（`docker-compose.yml`），
     自己轮转等于两套策略打架；何况中转也会以裸进程方式跑（此时 stdout 就是终端）。
4. **把 `owner` 等归属字段缓存在一个上下文里随每次调用自动带上**
   - 最强的理由：调用点少写几个字段，不容易漏。
   - 为何被否：Node 里没有可靠的"当前请求上下文"（`AsyncLocalStorage` 能行，但那会给
     每条通道加一次上下文切换），而这里的调用点本来就是少数几个、字段都能就地取到。

## Consequences

- 收益：`docker logs | grep '"evt":"quota.rejected"'` 就是一条可用的查询；面板第 4 批
  读的是同一批事件与内存计数，不需要第二套口径。
- 收益：关闭码与理由第一次进日志 —— 手机看到 `4003`/`4008` 时，中转侧能对上时间点。
- 代价：人直接读日志不如中文句子顺（`jq` 一行就补回来了）。
- 代价：`channel.close` 每条通道一次，连接抖动多时日志行数会涨；容器侧封顶兜底，
  但**没有采样** —— 若将来单机连接数上万，这条可能要按 `purpose`/关闭码过滤后再落。
- 代价：`evt` 是新的"事实形状"，改名会断查询。它们与代码一起改，且都写在本篇里。

## 本批的机械门槛（实测）

- `cd relay; pnpm typecheck` → 0；
- `node --test` → **123 / 123**（批前 117，新增 6：`tests/json-logger.test.ts`）。
- 变异校验（一次）：把字符串截断去掉 → **恰 1 红**（"长字符串截断到上限"）。
