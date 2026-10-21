# 轨迹页对齐与移动端适配 —— 问题清单（待办，按优先级）

> 2026-10-22 00:05 用户在真机上提的（原话）：
> 「我看轨迹页时间轴，轮次，调用都没有啊，点击第几轮下面的弹框怎么有一些黄的竖着写的英文啥的都是啥啊？
> 这个轨迹你完全没对齐 web 啊？还有就是 web 的我看了电脑屏大，你这个还需要看看怎么适配移动端，
> 考虑屏幕空间，和用户体验还有美观」
>
> 这份清单是**差距的唯一出处**；做完一条划一条（改成 implemented 笔记），不要散落在对话里。

## P0：看起来能用、其实没接线（假入口）

1. ~~三个 chip 是死的~~ **已修（2026-10-22）**：`trajectory_page.dart` 的
   `_Chip` 行（「时长 / 轮次 / 调用」）与那个 `onPressed: () {}` 的搜索钮一起删掉 ——
   原型里根本没有这一行（`mock/proto` 没有 `tj-tools`），是落地端自己加的假入口。
   用例 `trajectory_test.dart` 新增一条"不摆假入口"。**等三个视图各自有数据源再加回来**。
2. **甘特条永远没有数据**：`_TrajectoryTab`（`chat_page.dart:3332-3357`）只传 `entries`，
   `rows` 恒为 null ⇒ 轨迹页只剩"一轮一行"的账本，**没有任何时间轴**。
   数据面缺口：`turnOutline` 只有 `{turn, seq, prompt, response}`，**没有每步起止**；
   `sessionStats` 是会话级总量（`memory.md` 已记"拿总量画分段只能画出假图"）。
   要做真时间轴，得先加一个"每步起止"的投影（Host 侧），不是前端能补的。
3. **「轨迹条目」sheet 的横向溢出**（用户原话"黄的竖着写的英文"，2026-10-22 截图确认）：
   那不是竖排文字，是 Flutter 的 **overflow 条纹** —— 黄黑斜纹 + 红字
   `RIGHT OVERFLOWED BY 474 PIXELS`；「结果」两个字被挤成竖排是**同一个原因**。
   根因：`_showTraceSheet`（`chat_page.dart:1412-1431`）用 `DshKeyValue` 摆三行，
   而 `DshKeyValue` 的 value 是**无约束的 `Text`**（`dsh_sheet.dart:164-171`）：
   `Row(children: [Expanded(label), Text(value), ...])` —— 长英文 value 拿到自己的
   固有宽度、把 `Expanded` 的标签压到 2 字宽，然后整行溢出 474px。
   处置（下一轮）：**长文本不该用 KV 行**。`_showTraceSheet` 的「结果」改成
   "标签一行、正文下一行、可换行"的纵向块；`DshKeyValue` 可加一个可选
   `multiline` 参数（默认保持现状，别影响统计/用量那几张 sheet）。

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
   **2026-10-22 00:35 复测：已通过**。根因是**模型配置**——`llm-pi-ai` 的模型条目
   不声明 `input` 时按 `DEFAULT_INPUT = ['text']`（`llm-pi-ai/src/config.ts:74`）在发送前拒；
   profile 补 `input: [text, image]` 后，电脑侧 `user/message` 有 `{type:'image'}`，
   模型回复**读出了截图内容**。教训：**"模型不支持"先查声明，别先信报错**。
9. **E3 拖动排序真机未验**：隔离实例凑不出"同一工作区下两条可见会话"
   （新会话 blank 不列；宿主账本只记带 `workspaceId` 建的会话）。
   静态审查：纯函数 + 8 条用例成立，缺的只是数据条件。
10. **H2 归档→取消归档闭环**：**2026-10-22 已验通过**（未分组 3→2→3）。
11. **A6 / D2 / D3 未造出**，2026-10-22 做了静态审查（见
    `docs/subsystems/subagent-page.md` §7.3）：
    - A6：逻辑成立（`mode == one-shot` 两支 + 两条用例）；
    - **D2 发现缺口**：`sync_client_impl.dart:956` 把 `refetch` 标记跳过、从不调
      `session.refetch` ⇒ **>1 MiB 的条目会静默缺失**（不报错、不缺页，就是少一条）。
      连接器侧是完整的（`session-page.ts` + `refetchThresholdBytes` 1 MiB）；
    - **D3 发现缺口**：四档结局都有渲染，自动重试也有 `RetryRow`，但**没有"手动重试
      失败回合"的入口**。

## 相关事实（别重复查）

- 轨迹页数据来源：`turnOutline` 投影（`session.projections`，契约 §5.7）。
- 轨迹页文件：`app/lib/ui/trajectory_page.dart`（甘特 + 账本）、
  `chat_page.dart` 的 `_TrajectoryTab`（接线）与 `_showTraceSheet`（条目详情）。
- Web 侧：`packages/client/ui-trajectory/src/client/`（`TrajectoryTable.tsx` /
  `timeline.ts` / `layout.ts` / `locales.ts`）。
