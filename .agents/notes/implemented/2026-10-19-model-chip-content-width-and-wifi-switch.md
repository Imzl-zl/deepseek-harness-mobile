# Agent Note: 模型 chip 按内容宽（Flutter 四个"撑满"元凶 + 换 WiFi 验证）

Status: implemented

## Problem

用户 2026-10-19 两条反馈：

1. "我们的输入款就设计不是和很好，**模型占那么大**"。
2. "忘了告诉你我来公司上班了，关机了，**换 WiFi 了**，刚好试试之前更新的连接的能力"。

第一轮已把模型 chip 从"裸名字"改成"`database` 图标 + 名字"
（`.agents/notes/implemented/2026-10-19-composer-drop-busy-send-icon-model-chip-icon.md`），
但**没有几何判据**，也没有让它在内容变少时收缩。

## 调查

### 1. 换 WiFi 自动连上 —— **验证通过**（家 → 公司）

判据（memory.md 挂了很久的那条）：**不动手机、不扫码**自动连上。

实测：重启 App 后 **15 秒内**自动连上，状态点绿、会话列表完整拉回。
**两个此前不知道的前提**（都写进 memory）：

- **电脑侧 DSH 必须已在新网络跑着**。这次一开始连不上，是因为公司这台电脑的
  DSH 没启动（8099/8790 都没监听），手机端点表里全是家里的 `192.168.1.4`，
  拨不通。启动 DSH 后，手机从 `endpoint.describe` 的 **direct 通道自报**学到
  新地址（手填那条的标签从"手填"变成"WLAN 2"—— 说明它就是自报的那条）。
- **profile 的 `cordis.patch.yml` 里 `relayUrl` 写死了家里 IP**
  （`ws://192.168.1.4:8787`）。`relayHintFor`（`connector/src/pairing.ts:173-184`）
  **只对环回地址做替换**，字面局域网 IP 原样返回 —— 所以中转通道换网络后仍指向
  旧地址，**只有 direct 自报能用**。换电脑/换网络时要改配置。

顺手清掉了 4 条 IPv6 隐私地址端点（memory 已知缺口 6）—— 它们把端点表撑到
7 条，用户要找的那条被挤到最底。

### 2. 模型 chip 宽度 —— 最小复现逐层定位四个"撑满"元凶

用户说"模型占那么大"，先用 widget 测试量真实几何（`composer_layout_test.dart`）：
800px 屏上模型**文字** 233px（29.1%），加 padding/图标/等级/chevron 后整个 chip
约 40%。390px 真机折算约 156px = 左组一半以上。

然后用最小复现逐层加，找出四个会把 `constraints.maxWidth` 吃满的元凶：

| 层 | 加之前 | 加之后 |
|---|---|---|
| `Container(constraints: BoxConstraints(minHeight: 32))` | 91.3 | **496.0** |
| `InkWell` | 91.3 | 496.0 |
| `Material` | 91.3 | 496.0 |
| `Container(alignment: Alignment.center)` | 398.0 | **496.0** |

根因分两类：

- **`BoxConstraints(minHeight: 32)` 的宽度方向是 `0..Infinity`** —— 收到
  `0..上层maxWidth` 时 `Container` 自己的宽取 **maxWidth`（有界就用 biggest）。
- **`Material` / `InkWell` / `Container(alignment:)` 天生撑满**，且
  `Align(widthFactor: 1.0)` 救不了 `Material`（它只在该子自己不撑满时有效）。

## Decision

**四件事一起做才收缩**（缺一个仍 496）：

1. `_Chip` 底色用 `Container(decoration:)` **不用 `Material`**（按内容宽排）；
   代价是没有水波纹 —— 有意接受：chip 点了立刻开 sheet，反馈是"sheet 出现了"，
   而 DSH Web 的 chip 也只有 CSS transition（`ui-model-selection` 的 `.trigger`）。
2. `_Chip` 内的 `Container` **不带 `constraints`、不带 `alignment`**；
   `min-height: 32` 由 `padding: vertical 6` + 12px 字号行高自然达到（≈30）。
3. 调用方用 `Flexible(fit: FlexFit.loose)` + `Align(widthFactor: 1.0)` +
   `ConstrainedBox(maxWidth: 62%)`：内容窄时不撑满、内容宽时压到上限。
4. 内层 `Row` 里的模型名用 `Flexible(fit: FlexFit.loose)` —— 默认 tight 会把
   Text 拉到"Row 宽 − 其他子宽"（探针：308.75，而内容宽只要 271），
   裸 Text 则会取 `0..X` 的 X（探针：529，越过 62% 上限）。

**另外**：推理等级改成**有条件渲染**（`reasoningLabel` 可空）——
DSH Web 的 `effortLabel` 本来就是条件的（`ModelSelect.tsx:488` 的
`{effortLabel !== undefined && …}`），而我们原来在"没选模型"时显示"默认"，
那一截在 390px 屏上占约 40px，而"默认"说的是"没有信息"。

## Alternatives considered（否掉的）

- **模型 chip 改纯图标**（rikkahub 的 `onlyIcon`）：手机上"此刻用哪个模型"
  是高频信息，纯图标要点开才知道，比占 40% 更影响使用。已在上一轮笔记否过。
- **把 62% 上限改小**：名字会更早被省略号截断，用户反而更不知道是哪个模型。
- **用 `IntrinsicWidth`**：它能按内容宽，但会**二次布局**（每个 chip 多一轮
  measure），输入栏每帧重建 —— 性能代价不值。
- **保留 `Material` 只加 `Align(widthFactor)`**：实测救不了（见上表）。

## Consequences

- 收益（实测，800px 屏）：有等级时 chip **350**（原 496），无等级时 **284.75**
  （省 65px），权限 chip 左缘从 562 → **350.75**。390px 真机上观感同样成立。
- 代价：`_Chip` 没有水波纹；chip 高度从"至少 32"变成"约 30"（视觉差 2px）。
- 测试：`composer_layout_test.dart` 3 项全绿 —— 62% 上限 / 权限 chip 恒宽 34 /
  发送键在最右不重叠 / 长模型名下仍成立 / **无等级时 chip 更窄**。
- 全量门禁：`flutter test 752` / `analyze 0` / `format 0`。
