# Agent Note: 图片上限从宿主的 `imageLimits` 读，手机不写死一个数

Status: implemented

## Problem

选图这条链上原本有两个**我们自己的**数：

- `kMaxImageBytesForTransport` / `kMaxTotalImageBytesForMessage`（各 3 MiB，
  `app/lib/platform/photo_picker.dart:48,59`）；
- 单张 → 合计的预算判断 `fitsMessageBudget`（`:65-68`）。

它们描述的是**我们这条管道**：单帧 8 MiB、二进制在线上放大 ≈1.78 倍
（契约 §40、`connector/src/transport/codec.ts:53,77`）。这条规则是对的 —— 撞上它
不是"一条错误"，而是**整条连接被关掉**。

但它们是**通道层**的规则，答不了"这台电脑收多大的图"。那个答案是宿主的业务上限，
而且**部署可配**：`packages/attachment/attachment/src/index.ts:34-46` 的默认值是
`maxImageBytes` 50 MB、`maxImagesPerMessage` 20、`maxMessageImageBytes` 200 MB、
`maxImagePixels` 64,000,000、`maxImageDimension` 65,535、
`mediaTypes` = png/jpeg/webp/gif；用户可以把单图上限调到 5 MB。

手机原先**一个都没读**：超了就让 DSH 拒，用户看到的是"发送失败"里夹着一句英文码。

## Decision

**上限只从电脑侧的投影读。**

1. 不需要新方法：`session-controller/src/list.ts:98-105` 已经把这个投影注册成
   **`imageLimits`**（`wire.view` 就是 `ctx.attachments.imageLimits`，schema 在 `list.ts:32-39`），
   随我们已经在调的 `session.projections` 一起到手机。
2. `app/lib/model/image_limits.dart` 解析它（`DshImageLimits.fromWire`）。
   **三个必需项缺一就整个当"不知道"**（`maxImageBytes` / `maxImagesPerMessage` /
   `maxMessageImageBytes`）：拿一半的限制作判断，会给出"这张能发"的错误结论。
3. 选图时**先问宿主的限制**（`imageLimitViolationOf`），每条话点名是哪一条：
   类型不收 / 超张数 / 超单图 / 超合计。**只报第一条撞上的** —— "超限"两个字
   答不了用户"我该删一张还是换一张"。
4. **再问通道层预算**（`fitsMessageBudget`）：两个主人，各说各的话，谁先撞上就报谁。
   顺序是"业务在前、管道在后"：先让用户知道"这台电脑不收"，再谈"这条连接塞不下"。
5. **投影缺席（老连接器）⇒ 前置拦一次都不做**：`limits == null` 时 `imageLimitViolationOf`
   恒返回 `null`，让 DSH 自己拒 —— 它的拒绝码（`IMAGES_TOO_LARGE` / `TOO_MANY_IMAGES`）
   在错误消息里，手机原样显示（`chat_page.dart` 的 `发送失败：$error`）。

## Alternatives considered

1. **继续用手写的 50 MB / 20 张（照 DSH 默认值抄一份）** —— 最强理由：零连接器/协议改动，
   而且默认部署下与宿主一致。
   被否：这正是本仓反复踩的那类坑（`memory.md` 教训 1/2/4/7）。部署把上限调小之后，
   手机放行的图会被电脑拒；调大之后，手机白拦。症状是"有时能发有时不能发"，
   而两边都没有一条日志指向"两份上限不一样"。
2. **给 `session.projections` 加一个专用方法 / 加参数** —— 被否：`imageLimits` 已经是
   投影键之一，为它单开一个口就是把 DSH 已有的投影面翻译一遍。
3. **在手机侧解码图片量像素/长边，判 `maxImagePixels` / `maxImageDimension`** —— 被否：
   选图器给出的字节已经是原生侧压过的，解码要额外依赖（`dart:ui` 的
   `instantiateImageCodec` 可以，但那是一次真实解码）；这两条在默认部署下永远不是
   先撞上的那一条（3 MiB 的通道预算先到）。**字段保留、判据留空**，
   写在文档的已知边界里 —— 不假装判了。
4. **把拒绝码翻译成中文** —— 被否：契约 §3.1 的码表是封闭的，码本身就是给人看的；
   翻译一遍会让"电脑侧说的"和"手机显示的"变成两句话。

## Consequences

- **收益**：超限的三种情形各自有一句能照做的话；上限跟着电脑走，手机不写死任何数字。
- **代价**：`mediaTypes` 之外的格式会有**两句**话（选图器自己那句 + 这一句）——
  第一句来自系统选择器的 MIME 过滤，第二句来自宿主的 `mediaTypes`；两者不一致时
  以后者为准（它才是权威）。
- **代价**：像素 / 长边两条上限**没有前置判据**（见 Alternatives 3），只有宿主拒。
- **代价**：`imageLimits` 是**每个会话的投影**，换会话到新包落地前 `imageLimits` 为空
  （与统计条 / 权限档同一条纪律）—— 那一瞬间前置拦不生效，靠拒绝码兜。

## 判据

- flutter **1199 → 1206**（`test/image_limits_test.dart` 7 条）：超张数、超单图（话里带上限本身）、
  超合计、等于上限放行、类型不收、投影缺席恒放行、`fromWire` 认不出/半份 ⇒ null
  （含"非字符串 mediaTypes 项跳过"）。
- **变异校验**：把单图判据从 `>` 改成 `>=` ⇒ 恰好「放行：都在上限内就没有话」一条红
  （它守的正是"等于上限是放行"这个边界），做完即还原。
- `dart analyze --fatal-infos` 0、`dart format` 0。

## 代码入口回指

`app/lib/model/image_limits.dart`（`DshImageLimits` / `imageLimitViolationOf`）、
`app/lib/data/app_model.dart` 的 `imageLimits` getter、
装进选图路径的那一处 `app/lib/ui/chat_page.dart` 的 `_pickPhoto`；
现状见 `docs/subsystems/attachments.md`（与 `docs/subsystems/usage-page.md` 同级的现状文档）。
