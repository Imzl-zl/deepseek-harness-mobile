# 轨迹页对齐与移动端适配 —— 问题清单（待办，按优先级）

> 2026-10-22 00:05 用户在真机上提的（原话）：
> 「我看轨迹页时间轴，轮次，调用都没有啊，点击第几轮下面的弹框怎么有一些黄的竖着写的英文啥的都是啥啊？
> 这个轨迹你完全没对齐 web 啊？还有就是 web 的我看了电脑屏大，你这个还需要看看怎么适配移动端，
> 考虑屏幕空间，和用户体验还有美观」
>
> 这份清单是**差距的唯一出处**；做完一条划一条（改成 implemented 笔记），不要散落在对话里。

## P0：看起来能用、其实没接线（假入口）

1. **三个 chip 是死的**：`trajectory_page.dart:163-167` 的 `_Chip(label:'时长', on:true)` /
   `轮次` / `调用` **都没有 `onTap`**。它们长得像切换器，点了什么都不发生 ——
   用户说的「时间轴，轮次，调用都没有啊」首先就是这个。
   处置：要么做成真切换（三份数据各自有来源），要么**删掉**。
   按第八条教训（"承诺了但没做"比没有更糟），在数据面没补齐前**先删**，别留着。
2. **甘特条永远没有数据**：`_TrajectoryTab`（`chat_page.dart:3332-3357`）只传 `entries`，
   `rows` 恒为 null ⇒ 轨迹页只剩"一轮一行"的账本，**没有任何时间轴**。
   数据面缺口：`turnOutline` 只有 `{turn, seq, prompt, response}`，**没有每步起止**；
   `sessionStats` 是会话级总量（`memory.md` 已记"拿总量画分段只能画出假图"）。
   要做真时间轴，得先加一个"每步起止"的投影（Host 侧），不是前端能补的。
3. **「轨迹条目」sheet 里的黄色竖排英文**（用户原话"黄的竖着写的英文"）：
   待复现。已知该 sheet 是 `_showTraceSheet`（`chat_page.dart:1412-1431`）的三行
   `DshKeyValue`（角色 / 耗时 / 结果），而 `DshKeyValue` 的 value 是**无约束的 `Text`**
   （`dsh_sheet.dart:164-171`）—— 长英文 value 在 Row 里会横向溢出。
   下次真机先抓一张图：若是溢出条纹，改 `Flexible` + 换行；若是真的竖排，再找旋转来源。

## P1：与 Web 的结构差（不是样式差）

4. **Web 的轨迹是一张表 + 时间轴 + 详情 tab**：`ui-trajectory/src/client/TrajectoryTable.tsx`
   （虚拟行 `useStableVirtualRowStructure`、`DetailTab`）、`timeline.ts`（时间轴）、
   `layout.ts`（41 KB 的布局/列定义）。我们只有"一轮一行 + 三行 KV sheet"，
   连"调用"这一层（tool call 明细）都没有独立视图。
   处置：先定**手机形态**（见第 6 条），再决定搬多少 —— 不要 1:1 移植 `layout.ts`。
5. **账本的 `took` 恒为空**：`turnOutline` 不带耗时，`TraceEntry.took` 只能空着
   （代码注释里写明了"空着比编一个数字诚实"）。用户看到的"没有时间"有一半是这个。
   处置：要么补投影（同第 2 条），要么把这一格去掉，别留空列。

## P2：移动端适配（用户明确要求"考虑屏幕空间、体验、美观"）

6. **640px 固定宽甘特 + 横滑**是原型（桌面）的尺寸，手机上：
   - 横滑区占掉一屏高度却只有 4 行 14px 轨道，信息密度极低；
   - 左侧 34px 标签列 + 640px 轨道 = 用户要先横滑才知道有内容。
   处置候选（待评审）：竖屏改"每轮一行迷你条 + 点开看该轮的分段"，
   或者把时间轴做成可折叠的一条总览；**不要在 390dp 上硬塞 640px**。
7. **三个视图的信息层级**：时长（形状）/ 轮次（每轮摘要）/ 调用（工具明细）——
   手机上更适合"轮次为主、其余两层点进去"，而不是三个平级 tab。

## P3：本轮（2026-10-21 深夜）验收留下的欠账

8. ~~D1 附件发送未过~~ **已查清（2026-10-22）**：不是 App 的缺陷，宿主回
   `ProtocolException(internal): Model "auto" does not support image input.` ——
   免费渠道的 `auto` 不接受图片。App 路径正确（请求发出、错误如实显示、芯片保留）。
   剩下的是一条 UX：错误在键盘挡住的 SnackBar 里，容易看不见（可考虑内联到输入栏）。
9. **E3 拖动排序真机未验**：隔离实例凑不出"同一工作区下两条可见会话"
   （新会话 blank 不列；宿主账本只记带 `workspaceId` 建的会话）。
   要验得先让宿主把会话记进工作区（或让 `session.create` 带 `workspaceId` —— 那是产品改动）。
10. **H2 归档→取消归档闭环未验**（上一轮只验了"归档后从列表消失"那一半）。
11. **A6 / D2 / D3 未造出**：一次性子会话（两个 in-process 后端只产 continuable）、
    历史翻页（没有 >100 条事件的会话）、异常结局（没有稳定制造失败回合的手段）。

## 相关事实（别重复查）

- 轨迹页数据来源：`turnOutline` 投影（`session.projections`，契约 §5.7）。
- 轨迹页文件：`app/lib/ui/trajectory_page.dart`（甘特 + 账本）、
  `chat_page.dart` 的 `_TrajectoryTab`（接线）与 `_showTraceSheet`（条目详情）。
- Web 侧：`packages/client/ui-trajectory/src/client/`（`TrajectoryTable.tsx` /
  `timeline.ts` / `layout.ts` / `locales.ts`）。
