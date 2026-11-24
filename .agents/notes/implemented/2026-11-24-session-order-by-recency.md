# Agent Note: 会话组内顺序 = 最近更新（两张档：最近更新 / 手动）

Status: implemented

## Problem

用户 2026-11-24：

> 我 APP 新建会话怎么桌面上显示的不是第一个是后面？？这都优化几次了一直有问题？？

上一轮（`2026-11-17-blank-row-pinned-to-group-head.md`）只把 **blank** 行钉在组首，
提交说明自己写着"没做的：非 blank 会话之间手机仍按账本序，桌面默认按 updatedAt"。
于是这条路的每一步都在换位：

| 阶段 | 它的排序键 |
|---|---|
| 点「新建会话」（命中复用旧 blank） | 账本里的**老位置**（账本一动不动） |
| 显示 | blank 钉首 —— 看起来对了 |
| 发第一条消息后 `sessionBlankOf` 翻 false | 丢掉 blank 特权，**落回账本老位置**，可能直接掉进「展开其余 N」 |

根因不是"新建错了"，是**排序键选错了**：手机把 `workspace.list` 的账本行序当显示序；
桌面把账本只当成员集合，顺序一律 `updatedAt` 降序（`orderByRecency`），再把当前 blank 钉首。
数据层一直带着 `updatedAt`（`connector/src/handlers.ts` 逐行透传、宿主清单本来就降序，
`packages/api/session-controller/src/list.ts`），缺的只是"用它排"。

## Decision

**组内两个非 blank 分区按 `device.session_order` 排，默认"最近更新"（`updatedAt` 降序，
并列按 sid 升序）；"手动"档就是账本序本身。用户一动顺序（拖动落点 / 菜单上移下移 /
拖动排序）档位切到"手动"。**

准入门槛（可机械判定）：

1. `app/lib/model/session_order.dart` 是两档的唯一表达（`wire` = `updated` / `manual`）；
   落盘键 `device.session_order`，照 `device.route_policy` 的写法，认不出回默认。
2. `bucketSessionsByWorkspace` 的两个新参数 `order` / `updatedAtOf` **必填** ——
   新调用点漏传编译不过（判据只有一处，不在调用点各判一次）。
3. 顺序逐字照桌面：`updated` 档 = `ordersByRecency` 的 (updatedAt 降序, sid 升序)；
   blank 段**恒按传入顺序**且钉在组首（它的 `updatedAt` 最旧也一样）；
   「未分组」桶走同一个 `partition`（不另写一条规则）。
4. 重排成功后档位切 `manual` 的唯一一处在 `AppModel.moveSession`；
   设置页有一行「会话排序」能切回「最近更新」（否则用户回不到默认）。
5. `node app/tools/verify-size.mjs` 的预算**不许抬**（`AppModel` / `app_model.dart`
   用设备偏好存取对收窄，不是加两套读写）。

## Alternatives considered

1. **只做"最近更新"，删掉拖动排序**
   - 最强的理由：桌面默认档就是它；删掉手动档等于删掉一整类状态（谁拥有顺序、
     怎么反馈、跨端不一致），手机也少一处与 Web 的已知差异。
   - 为何被否：拖动排序是真功能（2026-10 就落地了，`2026-10-22-drawer-drag-insertion-line.md`），
     用户会立刻发现"拖了没用"。而且删掉它并不能解决"新建会话要第一"——
     那一条靠的是排序键，不是"有没有手动档"。
2. **只做"最近更新"，拖动时写账本但不切档**
   - 最强的理由：不动设置面，改动最小。
   - 为何被否：`updated` 档下账本序不是显示序 ⇒ 拖动写完看不见变化 = "拖了个寂寞"，
     比删掉功能更糟（功能看着在、实际不生效）。
3. **在手机上另存一份手动顺序（照桌面 `sessionOrderByAccount` 存浏览器本地）**
   - 最强的理由：与桌面完全同构，手动顺序不依赖宿主的账本语义。
   - 为何被否：宿主的 `workspace.insertSessionBefore` 已经是"手动的真相"，手机再存一份
     就是第二份顺序，两边迟早不一致。手机侧"手动 = 账本序"，不加存储。
4. **把新建会话的 blank 行写进账本最前（而不是显示层钉首）**
   - 最强的理由：一条数据事实同时解决两端显示，最"正统"。
   - 为何被否：写账本会改电脑侧的项目内顺序，而用户只是"开了个还没内容的新会话"；
     2026-11-17 已经因为"显示层钉首 vs 挪账本"选过一次，结论是不写账本。
     发第一条消息后掉位这件事，靠排序键解决更干净。

## Consequences

- 收益：新建会话发完第一句话仍在组首（`updated` 档下它是 `updatedAt` 最新的）；
  手机与桌面的默认顺序不再有已知差异，`session-ordering.md` 里那条"已知差异"删除。
- 代价：多一个设备偏好（`device.session_order`）与设置页一行；拖动/上移下移多一步写档。
- 代价：`updated` 档下账本序只影响"手动档看到什么"，用户若从手动切回最近更新，
  之前拖出来的顺序**不会丢**（账本没改），但显示立刻变成时间序 —— 需要在设置页的
  那一行说清（文案已写"最近更新 / 手动"）。
- 代价：`AppModel` 增加 `sessionOrder` / `setSessionOrder` 与 `updatedAtOf`；
  为此把设备偏好的读写收成一对（`devicePref` / `setDevicePref`），文件行数不涨。
