# dsh-mobile Tools

## Concepts

- 本文件记录项目协作知识,不替代正式设计文档、`docs/` 或当前代码。
- 真值优先级:`docs/design-and-tech-plan.md`(总纲)> 三份 `docs/*-notes.md`(专项)> 可跑通的验证脚本 > 本文件。
- 主链路:改 `mock/proto/` → 跑验证脚本 → 截图 → 同步 `app/`(Flutter 落地端)。
- 本仓库**没有** `package.json` / `pubspec.yaml` / CI;所有命令都是显式脚本,不存在 `npm test` 这类约定命令。

## Read First

- `docs/design-and-tech-plan.md` —— 设计与技术基线(冲突时以它为准)
- `docs/subsystems/remote-channel.md` + `docs/channel-review-notes.md` —— 通道契约与评审(后者含 DSH 行号、待补六条、实测数据)
- `docs/subsystems/connector-and-relay.md` + `docs/subsystems/app-channel-client.md` —— 电脑侧/中转与手机端的落地设计
- `docs/cookbook/channel-bootstrap.md` —— 开工步骤与精确验证命令(新会话从这里开始动手)
- `docs/settings-porting-notes.md` —— 设置项搬运清单(42 项)
- `docs/plugin-and-jobs-notes.md` —— 插件与后台任务边界
- `docs/standalone-mode-notes.md` —— 本机运行模式
- `.agents/notes/AGENTS.md` —— 决策笔记不变量
- `memory.md` —— 当前状态快照

## Tools

- 多端边界校验(不需要 Flutter 工程):`node app/tools/verify-platform-boundary.mjs` —— 扫描 `app/lib` 与 `app/packages`,共 6 条规则:
  1. `core-no-platform-import`:`app/lib/{core,data,model}` 禁 `dart:io` 与 `package:flutter/{services,widgets,material}.dart`(否则纯 Dart 单测写不了)
  2. `ui-no-impl-import`:`app/lib/ui` 禁 import 各端实现包(`*_(ios|android|ohos)/`)
  3. `ui-no-platform-import`:`app/lib/ui` 禁 `dart:io`
  4. `branch-whitelist`:平台分支(`Platform.` / `defaultTargetPlatform` / `MethodChannel` / `EventChannel`)只允许出现在 `app/packages/**`、`app/lib/platform/**`、`app/lib/ui/adaptive/**`
  5. `no-platform-isohos`:全仓禁 `Platform.isOhos`(会导致 `flutter run` / `build har` / `attach` 失败,鸿蒙判断用 `defaultTargetPlatform`)
  6. `fallback-not-in-release`:`app/lib/platform/registry.dart` 引用兜底实现(`InMemory` / `NullPush` / `Noop`)必须带 `kDebugMode` 守卫

  自带规则自检 13 条,所以 `lib/` 还没代码时也不是空转(当前输出:`规则自检 13 条 + 扫描 2 个 Dart 文件`)- 通道协议验证(不需要浏览器/手机/公网):`node protocol/verify-fixtures.mjs` —— 16 条 fixture / 486 项断言(两种结果规则、快照水位与分页、待审批重建、live 帧不入账);`node protocol/verify-loopback.mjs` —— 26 项,手机 ⇄ 中转 ⇄ 电脑侧桥接回环(含"中转状态清空后重启"与强制走桥接分支的 `5b`)。改 `protocol/` 后两条必须全绿;`DSH_DEBUG=1` 可打印每条恢复应答
- 变异校验(验证断言不是恒真,不碰仓库):把 `protocol/` 复制到临时目录后注入,再跑两个脚本。**实测基线**:① `reference/relay.mjs` 去掉 `seq !== expected` → fixtures 红(仅 `07`);② `reference/bridge.mjs` 的 `hello` 返回空 `transient` → fixtures 红(`09`)**且回环红(`5b`)**;③ `reference/takeover.mjs` 去掉"前台且订阅"过滤 → fixtures 红(6 条,`16`)
- 会话规模标定(只读 DSH 仓库,用于标定重放窗口与帧上限):统计 `C:\sudy\github\deepseek-harness\snapshots\**\*.jsonl` 的事件数 / turn 数 / 单事件字节(结果:中位 21 事件/turn、单事件 max 7 KB、最大会话 99 事件,见 `docs/channel-review-notes.md` §6)
- 跨端密码学向量:`node protocol/tools/gen-vectors.mjs` 机生成(用 `node:crypto`,勿手改产物),`node protocol/verify-vectors.mjs` 重算比对(33 项:握手派生 10 字段 + AEAD 往返 5 条 + 篡改拒绝 3 条)。**两侧实现各自跑同一批向量**
- 图标集校验(不需要浏览器):`node mock/proto/tools/verify-icons.cjs`
- 起独立 headless Chrome(不碰日常浏览器,默认端口 9400):`pwsh -File mock/proto/tools/cdp.ps1 -Port 9400`
- 设环境后跑验证:`$env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'`
  - `node mock/proto/tools/verify-proto.mjs` —— 布局与交互(顺序、控件位置、搜索过滤、动画、遮罩)
  - `node mock/proto/tools/verify-authz.mjs` —— **授权矩阵 18 项**,必须 0 失败
  - `node mock/proto/tools/verify-picker.mjs` —— 选择类列表列固定
  - `node mock/proto/tools/verify-settings.mjs` —— 设置页导航/控件/边界回归,27 项(首页分组顺序 + 通用页 11 行顺序)
  - `node mock/proto/tools/verify-tasks.mjs` —— 对话 dock(目标 / 任务清单)+ 自动化任务页,53 项
  - `node mock/proto/tools/measure-composer.mjs` —— 量输入区控件几何
  - `node mock/proto/tools/shoot.mjs` / `shoot-composer.mjs` / `shoot-picker.mjs` / `shoot-settings.mjs` / `shoot-tasks.mjs` —— 截图到 `mock/proto/shots/`
- 语法检查:`node --check mock/proto/app.js`(同 `interactions.js`、`tools/*.mjs`)
- 图标重新抽取(DSH 升级后):`node mock/proto/tools/extract-dsh-icons.mjs`
- 关键入口:`mock/proto/index.html`(原型唯一入口);`app/lib/theme/dsh_theme.dart`(Flutter 主题)
- 只读参考源码:DSH `C:\sudy\github\deepseek-harness`;Agents-Anywhere `C:\sudy\github\Agents-Anywhere`;rikkahub `C:\sudy\github\rikkahub`
- DSH 侧高信号入口(只读):
  - 开发者文档 <https://deepseek-harness.github.io/deepseek-harness/reference/> —— 子系统 `reference/subsystems/web-server`、`web-client`、`client-modules`;另有 `develop/basic/`、`guide/quickstart`
  - 架构决策笔记金矿 `C:\sudy\github\deepseek-harness\.agents\notes\archived\architecture\`:`2026-07-19-gui-layering-and-rpc-protocol`(GUI 分层与 RPC 协议)、`2026-07-23-unified-session-query-service`(统一会话查询服务)、`2026-07-25-web-command-surfaces-and-assembly`(命令面与装配)、`2026-07-25-web-input-machine-and-slash-pipeline`(输入状态机与 slash 流水线)、`2026-07-28-user-settings-seam`(用户设置缝)。每篇都带 `.zh.md`

## Patterns

- **先查源码再动手**:任何"DSH 是怎么做的"问题,先 grep 出 `packages/...:行号` 再改代码;结论写进 `docs/`,不留在对话里。
- **验证脚本是规格**:行为改动先改/加断言,再改实现,最后跑全绿。
- **结构照 DSH,形态按触屏**:能照抄就照抄;触屏不适用时有意偏离,并在方案文档写明原因。
- **纯浏览器原型**:`mock/proto/` 无构建步骤,双击 `index.html` 即可验证;所有交互用 Pointer Events 手写,便于真机触屏复现。
- **跨模块只走注入的 api**:`interactions.js` 不裸调 `app.js` 私有符号。
- **批量改文档用「临时 `node` 脚本 + 每处断言恰好命中一次」**:比手写多次替换稳;命中数不等于预期就报错退出,避免静默改错行。

## Pitfalls

- **9222 端口不可用**:本机日常 Chrome 占用它,CDP 探测返回 `404 page not found`。用 `cdp.ps1` 换端口(默认 9400);9400 也可能被上一轮遗留的 headless Chrome 占着,开新端口前先探 `http://127.0.0.1:<port>/json/version`。
- **`cdp.ps1` 跑完不会自己关浏览器 —— 端口被占的根因**:脚本 `Start-Process` 起 headless 之后既不等待也不停止(`-KeepOpen` 只决定要不要拿 `-PassThru` 的那个对象),`%TEMP%\proto-cdp-*` profile 也从不清理。所以**每跑一轮验证就漏一个 headless + 约 500 个文件的临时目录**,端口就这样被逐个占满(实测 9400 与 9410 各挂了一个)。收工清理,只匹配 `proto-cdp` 因此不会碰日常浏览器:

  ```powershell
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
    Where-Object { $_.CommandLine -match 'proto-cdp' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  Get-ChildItem -Directory $env:TEMP -Filter 'proto-cdp-*' | Remove-Item -Recurse -Force
  ```

  停止的判定:`Get-NetTCPConnection -State Listen -LocalPort 9400` 无输出 = 已释放。
- **代理会拦 localhost**:若环境有 HTTP 代理,CDP 请求会被拦成 404;跑脚本时带 `NO_PROXY=127.0.0.1,localhost`。
- **PowerShell 里的 Node 内联脚本会被转义搞坏**:多行 `node -e "..."` 遇中文/引号易碎,改为写临时 `.mjs` 文件再跑。
- **手改 `styles.css` 曾截断规则**:改完必须确认 `{` 与 `}` 计数相等,并用浏览器跑一次 `verify-proto.mjs`。
- **`openSheet` 切 sheet 的返回栈竞态**:不要"先 close 再 open"(异步 popstate 会把新开的 sheet 弹掉),`openSheet` 内部复用同一层。
- **`.page--side` 必须挂过渡**:漏了就没有抽屉动画,视觉上是"啪一下"。所有从右滑入的全屏页(`.page--settings` / `.page--tasks`)都要列进 `.motion ...` 那份过渡名单,否则整页瞬移。
- **从抽屉切全屏页要同步摘掉 drawer 层**:`settings-open` / `tasks-open` 都必须 `D.set(0, true)` + `closeLayer("drawer", true)`;漏了页面会开在没收起的抽屉后面,还留下 `drawer` 幽灵层。
- **覆盖 `.btn` 的 `flex` / `min-height` 必须带 `.btn` 前缀**:`.btn` 在样式表里更靠后,同权重下会盖掉前面对 `.xxx-new` 的覆盖(表现是筛选行被挤到换行)。
- **别用 `scrollWidth` 判断文字有没有换行**:换行后并不横向溢出,要数文本节点的 `Range.getClientRects().length`。
- **`[hidden]` 会被 `display:flex` 盖掉**:组件级 `display` 规则要配 `[hidden]{display:none!important}`。
- **`engines.dsh` 不参与任何判定**:DSH 插件兼容性看 `peerDependencies` 对 `@deepseek-ai/dsh*` 的范围,不匹配会**静默跳过**并记入 `skippedBundles`(`packages/util/package-manifest/README.md:93`、`packages/boot/app-boot/src/plugin-compatibility.ts:68`);写 `engines.dsh` 既不报错也不拦截
- **DSH 引用行号会漂移**:改文档时顺手核对被引行是否仍指向该内容(已发生过 §7.5 密钥原则从 :313 漂到 :366)。
- 血泪史条目见 `docs/postmortem/`;此处只留结论。
