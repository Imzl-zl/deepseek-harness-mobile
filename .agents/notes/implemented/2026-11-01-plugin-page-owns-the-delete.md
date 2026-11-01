# Agent Note: 插件页按包分组，卸载由用户决定、由宿主判定

Status: implemented

## Problem

真机上的插件页只有一排开关。卸载按钮存在于「包」那一段，但被 `removable` 挡着：
宿主标成不可卸的包，按钮整枚不画。用户看到的是"我连自己装的插件都删不掉"，原话：

> 只能禁用、停用，没有删除？我就奇怪了那我想删除咋办？？
> 人家用户自己的东西，你凭啥不让人家删除，就是删除出问题了那也是人家自己删的。

同一屏还有第二个问题：启停的结论（`restart-required` / `overridden`）画成列表顶部的一张
卡片。列表一滚，那句话就在用户看不见的地方 —— 他点完开关，感觉是"什么都没发生"，
于是又来一句「居然弹框在上面都被遮挡了？不是屏幕居中？？」。

第三个问题不是 bug：插件行与包是两段互相对照的列表，而"这个插件属于哪个可卸载的包"
正是点卸载前唯一要回答的问题，界面却把它留给了用户。

## Decision

1. **让用户能删**：每个 `installed` 的包都画「卸载」，`removable` 不参与隐藏。
   真正的许可是宿主的 `removeBundle`（`packages/boot/plugin-manager/src/index.ts:1039`
   抛 `not-removable`），被拒时把那句原话显示出来。手机不替宿主预先拦。
2. **按包分组**：包卡里放它带来的插件行，归属用宿主给的 `BundleInfo.rows[].entryId`
   （`types.ts:61-70`）—— 连接器把 `rows` 过线，手机不按 `moduleName` 猜。
   没有归属的行（内建模板配的那些）单独一段「其他插件」。
3. **结论在屏幕中央**：新增 `ui/dsh_center_notice.dart`（overlay 级、不挡操作、2.2 s /
   错误 4 s 自动消失）；进度卡钉在页面顶部，不随列表滚走。
4. **同一原则的另一处**：设置页端点行的「⋯」（里面有删除）以前在"正在按用户点名连接"
   时被整枚禁用，理由是"删了失败就没地方回落"。那也是替用户做决定 —— 删掉之后回落自然
   落到表里下一条。门去掉了（`settings_page.dart` 的 `_EndpointRow`）。

准入门槛（可机械判定）：

1. 装了 N 个包 ⇒ 页面上有 N 枚「卸载」（不看 `removable`）；未装的包没有。
2. 同一份 `plugin.list` + `plugin.listBundles`，把某个 `rows[].entryId` 改掉，那一行就
   换到另一张卡（或进「其他插件」）—— 归属只由 `entryId` 决定。
3. 启停回 `overridden` ⇒ 那句话出现在屏幕中央（水平居中，偏差 <24px）。
4. `requestedEndpoint == 这一条` 时（点名连接进行中），那一行的「⋯」照样点得开，
   菜单里「删除这个端点」在。

## Alternatives considered

1. **保留"不可卸就不画按钮"**
   - 最强的理由：点一个必然失败的按钮，是把宿主的拒绝当成用户的错；上一版正是这条
     （`app/test/plugins_page_test.dart` 里写着"点了必然失败"）。
   - 为何被否：`removable` 只是预告，不是判定。它同时对"用户自己装、但被上一台机器的
     installation manifest 认领"的包也给 false —— 那种情况用户没有任何别的出口。
     让他点一次、看到宿主的原话，比让他对着一个没有入口的页面猜要好。
2. **按 `moduleName` 把行挂到包上（不改协议）**
   - 最强的理由：连接器一行都不用动，手机自己就能配对。
   - 为何被否：`moduleName` 不等于包名（`@scope/pkg` 的子路径、被多包共用的模块都会撞），
     宿主已经给了 `rows[].entryId` 这个准确答案；按名字猜就是第二份判据，迟早和宿主对不上。
3. **启停结论继续用 `DshToast`（底部浮条）**
   - 最强的理由：零新件，全 app 只有一种提示。
   - 为何被否：插件页的列表很长，用户点的那一行可能在屏幕中间也可能在底部；底部浮条会被
     "手指 / 键盘 / 底部手势条"挡住，而且用户明确要求"屏幕居中"。`DshToast` 的规则
     （"结果看得见的不弹"）不变，只是这里多了一种"看哪儿说不准"的场合。

## Consequences

- 收益：卸载在插件行的旁边就能找到；宿主的拒绝原话可见；归属不再靠人对照两张表。
- 代价：`plugin.listBundles` 的应答多了 `rows`（一包几行，量级是几十字节到几百字节），
  金样 `connector/tests/fixtures/wire-shapes.json` 随之重生成。
- 代价：多一个 overlay 级组件，且它是**静态状态** —— 页面 `dispose` 必须
  `DshCenterNotice.dismiss()`，否则它会飘到别的页面上（`plugins_page.dart` 已收）。
- 代价：用户可能对着一个会被拒的按钮点两次；第一次看到 `not-removable` 之后就知道了。

## 判据

- connector **816 项全绿**（含 `tests/plugins.test.ts` 的 `rows` 透传与丢掉无 `rowId` 的行）。
- flutter **1656 项全绿**；`test/plugins_page_test.dart` 新增/改写 4 条：卸载按钮在
  `removable=false` 的包上也存在、点了照样发 `plugin.remove`、按 `entryId` 分组、结论水平居中。
  `test/settings_page_test.dart` +1：点名连接进行中「⋯」仍能打开并看到「删除这个端点」。
- `dart analyze --fatal-infos lib test` 只剩 3 条与本次无关的旧 info（`snapshot_call.dart` /
  `app_model.dart` / `wire/rpc/endpoint.dart` 的 `curly_braces`）。
- `node app/tools/verify-platform-boundary.mjs` 700 项通过。

## 代码入口回指

- `app/lib/ui/plugins_page.dart`（分组、卸载、居中结论）、`app/lib/ui/dsh_center_notice.dart`。
- `app/lib/model/plugins.dart` 的 `PluginBundle.rows` / `PluginBundleRow`。
- `connector/src/dsh/plugins.ts` 的 `declaredRowsOf`。
- 文档：`docs/subsystems/remote-channel.md` §5.7、`docs/plugin-and-jobs-notes.md` §A.4 / §A.7。
