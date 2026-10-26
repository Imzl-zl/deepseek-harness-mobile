# 发版前删掉两处演示入口：未配对空态与 ＋ 菜单

- 日期：2026-10-26
- 状态：已落地
- 相关：`implemented/2026-10-16-drawer-foot-drops-demo-and-automation.md`（底栏「演示」删除；
  本篇把"示例数据"这最后一条也删了）、`implemented/2026-10-25-wire-rpc-layer-layout.md`（同一批发版清理）

## Problem

发版前的真机上仍有两处**假数据入口**，都违反"生产路径不放假数据"（`memory.md` 教训 7）：

1. **未配对空态的「看示例数据」**：`app/lib/data/preview_data.dart` 里三条编的会话
   （带「（示例）」前缀），`AppModel.loadPreview()` 把它塞进内存，`ChatPage` 未配对时
   显示入口。它曾经有价值（界面锁在配对后时，只有它能让布局问题提前暴露），
   但发版产品里它让用户先看到一堆假会话再看到配对流程。
2. **`＋` 菜单的「演示：接管输入栏」**：`chat_page.dart` 的 `_enqueueDemoTakeovers()`
   往接管队列灌三条假交互（审批 / 提问 / 计划）。它同样只在"想看看卡片长什么样"时有用，
   而发版用户看到的是"这台电脑在请求越权执行 `rm -rf`"。

两处都不是静默兜底（要用户点），但**都在产品代码里、都进 release 包**。

## Decision

**产品代码里不再有演示内容**；示例内容搬到测试，注入走两个 `@visibleForTesting` 缝。

可机械判定的门槛：

- `app/lib/` 里不再出现 `preview_data`、`loadPreview`、`isPreview`、`看示例数据`、
  `演示：接管输入栏`、`_enqueueDemoTakeovers`；
- 示例会话内容与三条演示交互只存在于 `app/test/support/`；
- 测试通过 `AppModel.seedForTest(...)` / `AppModel.emitInteractionForTest(...)` 注入，
  不新增任何产品可见入口；
- `flutter test` / `dart analyze --fatal-infos lib test` / `dart format` 全绿。

## Alternatives considered

1. **`kDebugMode` 包一层，release 不显示**。
   最强理由：改动最小，调试包仍能看卡片、测试照旧点菜单。
   被否：用户装的就是 debug 包（真机验收一直 `flutter build apk --debug`），
   "release 看不到"解决不了他看到的那个问题；而且同一个界面出现两种行为模式，
   测试覆盖的也不是 release 的那条路。
2. **入口删掉、数据留在 `lib/`**。
   最强理由：不用迁测试（`loadPreview` 还能被测试调用）。
   被否：演示内容仍进 release 包、仍能被将来的代码路径重新接出来；
   "看不见"不等于"没有"，发版清理要把数据也搬走。
3. **保留「看示例数据」，只删「演示：接管输入栏」**。
   最强理由：首次打开没配对时，示例数据是唯一能说明"这一版长什么样"的东西。
   被否：发版产品的首屏应该是配对流程；假会话看起来和真会话一样（教训 7 的原话），
   这正是要避免的"看起来连上了"。
4. **把两条入口换成"只读的界面预览"，不造假会话**。
   最强理由：既保留"先看界面"的价值，又不冒充数据。
   被否：那是另一个功能（要设计、要真数据源），不是发版前的清理；本轮先删。

## Consequences

- 收益：release 包里没有任何演示会话 / 演示接管；首屏只有真实的配对与空态文案。
- 收益：示例内容进测试后，UI 用例仍覆盖长文本、代码块、三种工具状态、待审批、
  系统消息、三条选项的提问卡与计划卡 —— 覆盖没有因为删除而缩水。
- 代价：`AppModel` 多了两个 `@visibleForTesting` 方法（`seedForTest` /
  `emitInteractionForTest`）。它们只在测试里被引用，release 树摇会丢掉；
  但它们确实是"生产类上的测试缝"，是这次取舍里最不理想的一处。
- 代价：未配对用户失去"先看看界面"的入口（**有意**）；下一次若要做，
  应按"只读预览、不造假数据"重开，而不是把 `preview_data.dart` 搬回来。

## 真机验证（同日）

- 装新构建后（真机 d61cf622）未配对空态只有「还没配对 / 重新配对 / 连电脑」，
  **没有「看示例数据」**；`＋` 菜单的「演示：接管输入栏」已由代码与用例保证不存在
  （无会话时菜单不可点，未在真机上展开该项）。
- **重新配对**：起隔离 profile（`dsh-mobile-test`，直连 8790 + relay 8787），
  扫二维码配对成功；手机经 relay 连上并在首次 serving 时跑 `endpoint.describe`，
  合并出 relay + 三条直连。
- **留存端点**：停掉 relay、杀 App 冷启动 ⇒ 日志
  `[dial] direct ws://192.168.110.79:8790 通 (118ms)`，绿点、会话页正常。
  即"换 WiFi 后按当前 IP 重连"走的是保存下来的端点，不需要重扫。
- **时序注意**：`endpoint.describe` 只在连上后跑一次；配对完成后要让它落盘
  （一次 serving）再断 relay。第一次测试在配对后立刻断 relay，下一次启动仍只有
  relay —— 这是预期时序，不是 bug。

## 代码入口回指

- `app/lib/data/app_model.dart`（`seedForTest` / `emitInteractionForTest`，以及被删的 preview API）
- `app/lib/ui/chat_page.dart`（未配对空态不再有示例按钮；`＋` 菜单不再有演示项）
- `app/test/support/preview_data.dart`、`app/test/support/takeover_demo.dart`（示例内容的新家）
