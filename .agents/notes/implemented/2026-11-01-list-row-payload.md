# Agent Note: 列表行只搬手机读得到的那五个投影键

Status: implemented（2026-11-01）

## Problem

上一批（`2026-11-01-refetch-scope-by-trigger.md`）把"一条通知只重取它说的那一份快照"
落地后，`session.list` 成了唯一还整包搬的东西，而它每次标题变更 / 切模型都要重取一遍。
笔记文末留了一句"先量再改：`connector.bytes.outbound` 已经能报字节"。

2026-11-01 真机量出来的账（`d61cf622`，直连 8790，351 行）：

| 项 | 字节 | 说明 |
|---|---|---|
| 一次标题变更出站 | **1 943 515** | `host` 帧 152 B + `session.projections` ~1.7 KB + `session.list` **1 941 638** |
| 其中 `session.list` 的投影块 | 1 398 436（**94.5%**） | 宿主给的每行 summary 整块 |
| └ `turnOutline` | 645 243 | **列表一个键都不读** |
| └ `trajectory`（本仓自带投影） | 353 250 | **列表一个键都不读** |
| 行本体（去掉 projections） | 77 651 | 351 行 × ~220 B |

也就是说：**99.9% 的字节买的是"这一行标题变了一个字"**，而其中 1 MB 是
"每一行的最近 200 轮时间轴"——那份数据只有**打开某个会话**时才有用。

## Decision

**连接器在行的装配处按白名单裁剪 `projections.values`，只放手机列表真正读的五个键**
（`title` / `modelSelection` / `subagentTiming` / `tokenUsage` / `subagentCatalog`），
白名单唯一拼写处 `connector/src/protocol/session-row.ts`。

判据是**手机读的那几个键**，不是"我们觉得列表该有什么"：
`app/lib/wire/rpc/session.dart` 的 `readSessionSummary` 是全仓唯一读列表行的地方，
它只取这五个（`_titleOf` / `modelSelectionOf` / `parseSubagentTiming` /
`parseTokenUsage` / `parseSubagentCatalogValue`）。`connector/tests/session-row-payload.test.ts`
**直接解析那个 Dart 文件**两侧比对：手机哪天多读一个键，那条用例会红并指出要加哪个。

结果（真机同一条探针，两次）：**1 943 515 → 252 000 B**（`session.list` 1 941 638 →
250 122，**-87%**），通知与手机重取帧数不变（notices +1、入站 +5 帧），
UI 无变化（标题 / 模型 chip / token 计数都还在）。

## Alternatives considered

1. **新增 `session.row`（只取一行的窄口）**
   - 最强理由：切模型 / 改标题只影响一行，整表 302+ 行里 301 行是白搬。
   - 为何被否（**这次没做，不是以后也不做**）：
     (a) 它需要行级合并语义 —— 把一行 upsert 进本地列表要定义"顺序怎么动"，
     而列表顺序是宿主的（`session.ordering` 一事的现状文档写明），我们没有
     `mergeOrderedBaseline` / `asOfSeq` 那套东西可依；
     (b) 它治的是"**多搬了 301 行**"，而实测显示**单行的体积才是主因**（每行
     4 OKB 里 3.9 KB 是项目时间轴）——先裁键立刻拿 -87%，而窄口顶多再省掉
     那 301 行 × ~220 B 的**行本体**（77 KB）。先做便宜的 87%，剩下的 3% 不值一个
     不可逆的协议决定。
2. **只给 `trajectory` 投影加 `summary: false`（宿主现成的机制）**
   - 最强理由：一行改动，语义最正 —— 宿主专门为"不该进 summary 的重投影"留了这个标记
     （`session-projection/src/types.ts:11-20`、注册处 `src/index.ts:521-533`）。
   - 为何被否（**作为唯一手段被否，作为补充也不做**）：它只能管**本仓注册的**投影，
     而 1 MB 里 **64%** 是宿主自己的 `turnOutline`（645 KB），那一个我们改不了
     （宿主的投影表是它的）。只加自己的 `summary: false` 能省 353 KB（-24%），
     而白名单能省 1.31 MB（-88%）；两件都做是同一个判据的两处表达，本仓的规矩是一处。
3. **行级推送（宿主 `api-session/added` 时推一行，手机 upsert）**
   - 最强理由：DSH 浏览器就这么做，字节最省（一行 JSON ≈1 KB）。
   - 为何被否：与"只推提示、不推数据"的主线冲突（`2026-10-31-host-state-sync.md`），
     真要做得先推翻快照方法是唯一真值，并引入一套行级合并语义（同 1a）。
4. **什么都不做**
   - 最强理由：零风险。
   - 为何被否：这不是"少省一点"，是**每次改标题 / 换模型都多花 1.9 MB** ——
     中转按字节计额（`memory.md` 的成本纪律那条），而手机上这些动作是高频的。

## Consequences

- 收益：一次标题变更 / 切模型的出站 **1.9 MB → 0.25 MB**（-87%）；首屏 `session.list`
  同样按此比例缩小（本机 1.94 MB → ~0.25 MB），经蜂窝 / 中转的额度和电量都按这个比例降。
- 代价 1（跨端白名单）：手机想从列表行多读一个投影键，必须同时改
  `protocol/session-row.ts` 与那个 Dart 文件 —— 这是**有意**的：两处不同步时用例会红
  （`tests/session-row-payload.test.ts`），而不是悄悄丢数据。
- 代价 2（宿主新投影不会自动过线）：宿主将来给 summary 加新键，手机要它就得进白名单。
  这也正是要的：**"哪几个键值得每次重取都搬"是一个决定，不该由宿主替我们做**。
- 代价 3（金样）：`connector/tests/fixtures/wire-shapes.json` 是**真实 DSH 清单**生成的，
  行的 values 变小了，必须 `UPDATE_WIRE_SHAPES=1` 重生成（68 440 → 34 010 B）。
  App 侧 `test/wire_shapes_replay_test.dart` 读同一份文件，已一并跑绿。
- 代价 4（打开会话那一包没变）：`session.projections` 仍是 20+ 键一整包
  （`remote-channel.md` §5.7 那条方法就写着"若实测太大退路是只读需要的键"）。
  本批**不动它**：它每个会话只在打开 / 切换时拉一次，而且 `trajectory` / `turnOutline`
  正是它要给的。若以后要收窄，那是同一条判据的下一步，判据同样是"手机读哪几个键"。

## Testing

- `connector/tests/session-row-payload.test.ts`（3 条）：
  ① 白名单与 `app/lib/wire/rpc/session.dart` 的 `values[...]` 读点逐字相等（解析口径坏了会直接说）；
  ② 名单外的键不放行（含 `turnOutline` / `trajectory` 与一个虚构的未来键）；
  ③ 缺席的键不补 `undefined`（"缺席"与"null"在手机侧是两种意思）。
- 变异校验（两次都实测）：把 `'turnOutline'` 加进白名单 → **2 红**（①②）；删掉 `'title'`
  → **3 红**（①②③，因为"缺席不补 undefined"那条也随白名单缩水）。即名单两侧都有绊线,
  不是"只有一条用例盯着"。
- 金样：`UPDATE_WIRE_SHAPES=1 pnpm test` 重生成后，connector `pnpm test` **799 项**全绿、
  App `flutter test` **1628 项**全绿（含 `wire_shapes_replay_test.dart` 58 条）。
- 真机（`d61cf622`，直连 8790，App 未重装）：同一条 `session/rename` 探针两次，
  出站 252 000 / 250 122 B 级别；notices +1、入站 +5 帧（与裁剪前一致）；
  截图确认标题 / 模型 chip / token 计数照旧。
