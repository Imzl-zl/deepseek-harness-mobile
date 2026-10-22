# dsh-mobile 项目状态

> 本文件是**当前状态快照** + 最近活跃窗口，允许覆盖更新。**不做流水追加** —— 历史属于 git 与 `.agents/notes/`。
> 决策与取舍见 `.agents/notes/`，稳定规律与坑点见 `tools.md`，现状事实见 `docs/`。
> 已落地的批次只在文末留一行索引，细节回 git 与笔记找。

## 下一步（新会话从这里开始）

> **2026-10-22 凌晨：轨迹页重做 + refetch 补取 + 新建会话落进工作区**（一次提交，代码与笔记同批）
> ① 轨迹页只留**「轮次」一屏**（每轮一行 + 用时迷你条 + 纵向块详情）：640px 横滑甘特与三个假 chip
> 一起删掉；`DshKeyValue` 加 `multiline`，修掉真机那条 `RIGHT OVERFLOWED BY 474 PIXELS`。
> ② `SyncClient.refetch` 接上 —— 翻页里的 `refetch` 标记不再被跳过（>1 MiB 的条目不再**静默缺失**）。
> ③ `session.create` 按 DSH 的链解析 `workspaceId`（显式 → 当前会话工作区 → 最近工作区），
> 建完重读一次 `workspace.list` —— 手机建的会话不再永远进「未分组」。
> 判据与证据：`docs/subsystems/trajectory-page.md` §5 +
> `.agents/notes/implemented/2026-10-22-trajectory-turns-only-and-duration-bars.md` /
> `-refetch-markers-are-fetched.md` / `-new-session-lands-in-a-workspace.md`。
> 真机：d61cf622，**两次 build 两次 install**（第一次那个包暴露了"行少时内容顶到下半截"的空洞，
> 第二次才修掉），`firstInstallTime` 始终是 2026-10-19 18:57:02。
> **E3 拖动排序同一晚补齐**：这台机器是 **root**（KernelSU），用 `sendevent` 注真手势验过
> 会话行拖动（dedupe `mv-1792606235984569`，顺序变 `[Greeting, Nested, …]`）与项目头拖动
> （`workspaceIds` 从 `[dsh-e2e, dsh-mobile, …]` 变 `[dsh-mobile, dsh-e2e, …]`）——
> `input swipe` / `motionevent` / `draganddrop` 都做不出落点，recipe 见 `tools.md`。
> 门禁：flutter **1032** / connector **563** / relay **86** / protocol **486·26·49** /
> boundary **318** / CDP 六项（31 / 18 / 28 / 53 / picker / 25）/ analyze+format 0。

待办（按顺序）:

0. **E3 拖动排序：已验（2026-10-22 晚补）** —— 会话行与项目头两条都走真手势，
   判据是宿主账本真的换了顺序（见上）。剩下的只是"换一台**没 root** 的手机时怎么验"，
   那条写进 `tools.md`（`input` 那一套都做不出落点）。
1. **轮组（turn/step 分组 + 折叠过程）** —— 用户当场指出 Web 与 App 结构不同：
   Web 是 `已完成，用时 X ⌃` 一个可展开的轮组，组内分 `已完成分析`/`执行了命令`；
   手机是平铺。这不是样式差，是**少了一层结构**（做法与代价见
   `.agents/notes/proposed/2026-10-22-trajectory-page-parity-and-mobile-fit.md` 第 9 条）。
2. **`ask_user_question` 未计时提问答不了** —— 我们的连接器在 `request.wait?.callId` 缺失时
   fail-closed 抛出（`connector/src/interaction-claims.ts:255`），而 DSH 的 `wait` 对 indefinite
   提问**本来就没有**（`packages/interaction/user-questions/src/types.ts:140-145`）。
3. **斜杠命令没有执行面** —— `/goal …` 走 `session.prompt` 变成**普通消息**。
   DSH 的执行面是 `commands.execute(agent,line)`（`packages/interaction/commands/src/index.ts:360-367`），
   我们方法面里没有它。命令卡的渲染已被单测钉住，别混为一谈。
4. **电脑侧停一会儿，手机会清掉配对** —— 中转重启后名册是空的，设备换票拿到 401，
   App 把 401 归成 `notPaired`（终态）⇒ 清凭据回配对页。实测一次（清单第 11 条）。
5. **侧边栏移动 / 置顶：真机已验**（2026-10-21 晚，隔离实例）—— 长按菜单四项（无删除）、
   置顶后进本组最前并出图钉、跨置顶分区上移不可点、未分组桶上移/下移不可点、
   归档后从列表消失且能在「归档」页取消、杀 App 重开 + 中转重启后置顶与顺序仍成立。
   同组内**非置顶行之间**的上下移：**2026-10-22 已验**（下移一次，账本顺序变了）。
6. **子智能体进入 / 后台任务看与停：真机已验**（2026-10-21 晚）：点目录行进子会话、`←` 回父、
   系统返回键同一条路、切兄弟后父级记忆不丢、子会话内容能加载、跑完变绿且时长定格、顶栏 running 计数会变。
   两个只在真机暴露的缺陷已修（子会话地址缺父级、子会话发消息被拒 → `subagent.prompt`）。
   孙级（`maxDepth: 2`）已验；一次性子会话本 profile 造不出（两个 in-process 后端只产 `continuable`）。
7. **异常结局 / 重试 / 压缩标记**（仍未造出）：没有稳定制造**失败**回合的手段（取消 ≠ 失败）；
   压缩标记未出现。历史翻页这轮用 B 的实验验掉了（见下），附件 D1 已过。
8. **`mock/proto` 子代理面板还没跟上落地端**（2026-10-21 有意留的差异，用户已确认先提交）：
   原型 `renderSubs` 还是平铺演示行，App 已是「直接子级 + 展开懒加载」的树 + 三态 + token + 详情行。
   同步要**一次做完**（disclosure、三态演示数据、token 与详情行、`verify-subs.mjs`），半截做会留下假面板。
9. **「上传文件」** —— 开工单在 `.agents/notes/proposed/2026-10-20-file-upload-shape.md`
   （DSH 侧入口 `packages/client/file-upload/src/index.ts:105,118`；共 8 个触达点，**别半截提交**）。
10. ~~历史翻页的 `refetch` 标记被丢弃~~ **已修（2026-10-22）**：`SyncClient.refetch` + `page()` 合并 +
    失败如实报（`SessionPage.failure`）。真机实验：把 `refetchThresholdBytes` 调到 1，
    61 条消息的会话滚到顶 → 翻页 + 逐条补取 → **会话开头（系统提示词 + 第一句 prompt）出现在手机上**。
11. ~~失败回合没有"手动重试"入口~~ **不做**：DSH Web 的 `ui-conversation` 也没有这个入口。

别当缺口（定案，别再试）:

- **全局侧滑**：Flutter 原生抽屉本来就是整页可拖（`material/drawer.dart:680` 的 `height: double.infinity`）。
  真限制是**系统返回手势** —— `setSystemGestureExclusionRects` **每条边最多 200dp 总高**。当前实现已是最优。
- **过程摘要的"用时/计数"在历史窗口不全时是如实降级**：`turn/start` 落在未加载的更早一页里，
  所以只说时长、不摆"0 条消息"。**别去"修"**。
- **轨迹页还没有时间轴 / 「调用」明细 —— 这是欠账，不是墙**：数据在手机上就有（每条事件带 `time`，
  Web 的 Overview 正是客户端现算的：`ui-trajectory/src/client/layout.ts:145,166`、`:190-196`）；
  缺的是手机侧投影把起点覆盖掉了（`data/projection.dart:197` 写 `updatedAt`、`:237` 又覆盖）。
  做法：给工具条目加 `startedAt`、`tool/result` 改成继承，再画行内时间轴。详见
  `docs/subsystems/trajectory-page.md` §1 与笔记 `2026-10-22-trajectory-turns-only-and-duration-bars.md`。
- **输入栏横滚钮组**只在加第五个钮时才需要（现在四个不换行）。
- **会话流里 `user/message` 不一定是人说的**：运行时上下文 / 技能目录 / 时间快照都是 `user/message`，
  靠 `source.kind === 'user'` 区分（DSH `conversation-nodes/message.ts:79`）。这条已修。

## 八条教训

> 前五条是"替身复现的不是真形状"；第六条是"提交不完整"；
> 第七条是"生产路径上的假数据"；第八条是"线上预算要按帧算"。

1. **投影信封**：`session.projections` 回 `null | {kind, asOfSeq, values}`，**手机要 `values`**。
   连接器曾整包透传 ⇒ 统计条/权限档/子智能体在生产里全空态而单测全绿（修在 `valuesOf`）。
2. **模型目录**：`buildModelCatalog` 返回**对象**（`{default, routableProviders, groups, failures}`）
   不是数组；解析器认错形状 ⇒ 生产里一次都没解析成功过。
3. **`session/select-model` 没有"不能写"的约束**：Web 调的就是它。我曾把**测试纪律**错升成产品约束。
4. **"空"有两种表达，判空只查一种就会漏**：`items.isEmpty` 漏了 `OtherItem`（hero 从未显示）；
   `usage == null` 漏了**字段齐全但全零**的对象（输入框底下显示 `0 tok`）。
5. **判据要能区分"没命中"与"没实现"**：同一句"点了没反应"可能是坐标偏 30px、也可能是回调没跑。
   **先加一行 `debugPrint` 确认回调跑了没有**，再怀疑手势。
6. **一个功能要一次提交完整**：`3979191`（"用量搬到抽屉"）只提交了 `ui/usage_page.dart`，
   它引用的 `UsageProject` / `grouped` 没进库 ⇒ 那个提交单独编译不过。
   规律：**提交前 `git status --porcelain` 必须是空**（除自己有意的未跟踪文件），
   且新加的文件要**反向 grep 一下"谁引用了它"**。
7. **生产路径上的假数据是最容易漏的一类**（不报错、不空屏、样式也对，只是名字/数字是编的）。
   **抓法两条**：① grep `lib/` 里写死的文件名/中文/数字；② grep `_notWired(` 与 `还没做`。
   注意这条规则**不给"弹一句还没做"留例外**。
8. **线上预算要按"帧"算，不按"对象"算**：二进制 `N` → JSON base64 `1.33N` → `box` 的 base64url 再 ×1.33
   ⇒ **一帧 ≈ 1.78N**。**自查的问法**：这个值在线上最终会被**哪一帧**承载？那一帧里还有谁？

## 真机联调的成本纪律（立过规，别问第二遍）

- **`--profile` 只隔进程/插件/端口**，`~/.dsh/{.credentials.yaml,sessions,storages}` 全局共用 ——
  但 `DSH_HOME` 是官方支持的**数据根覆盖**（`packages/util/home-paths/src/index.ts:17,135`），
  所以起隔离实例是可行的（`$env:DSH_HOME='D:\tmp\dsh-e2e'` + `dsh --profile mobile-e2e --port 63900 --no-open`）。
  **`dsh.cmd` 在 PATH 上**（`D:\soft\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd`）；
  直接 `Start-Process` 那个 `DeepSeek Harness.exe` 会因为参数里的空格**静默失败**（`Cannot find module 'D:\soft\DeepSeek'`）。
- **跑之前报一句"这次约几个轮次"并拿到准** —— 审批探针要模型真跑越权命令，花的是用户的钱。
- **这台机器是 root（KernelSU）**：`adb shell id` = `uid=0`。长按拖动这类"必须在 500ms 后仍不动、
  再移动"的手势只能用 `sendevent` 注（`/dev/input/event7`，逻辑像素 ×133.333）；
  `input swipe/motionevent/draganddrop` 都做不出落点 —— recipe 与判据见 `tools.md`。
- 装 App 一律 `flutter build apk --debug` + `adb install -r`；`flutter install` 与
  `flutter test integration_test/` **都会先卸载旧 App**，配对凭据一卸全没。
- 屏幕灭掉 = 引擎暂停 ⇒ `adb shell svc power stayon true`。

## 前置事实（会卡住实施）

- **单帧上限 8 MiB，任何二进制载荷在线上放大 ≈1.78 倍**（契约 §40 + `connector/src/transport/codec.ts:53,77`）。
  **二进制附件的原始字节预算 = 3 MiB**（3×1.78 ≈ 5.3 MiB）。图片由 `MainActivity.encodeForTransport` 压。
- **DSH 运行时 0.2.1-rc.2**；连接器 devDeps/peerDeps 跟 0.2.1-rc.2，`schemastery` 跟 **3.18.5**。
- **Flutter 3.41.9 / Dart 3.11.5 版本锁死**（上界由鸿蒙 fork 定）。Android 构建要
  `ANDROID_HOME='D:\soft\android-sdk'` + `JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-21.0.9.10-hotspot'`。
- 明文 HTTP 放行有**四处**，少一处静默不通：Android `network_security_config.xml`（debug）、
  `PairingPage.allowInsecureLocal`、`main.dart` 的 `PairingClient`、profile `cordis.patch.yml`。
- **无线直连三件一起对**：`listenPort: 8790` + `listenHost: '0.0.0.0'`、8790 监听在 `0.0.0.0`、`caps.direct === true`。
  **`relayUrl` 必须写环回** —— 写死局域网 IP 会绕开 `relayHintFor` 的自愈。
- `connector/` 与 `relay/` 是**两个独立 pnpm 工程**，导入风格不同、别顺手统一。本仓库**没有 CI**。

## 方法面 33/37

契约封闭集 **37**、实现 **33**，差额 4 个是契约列了没实现的：`settings.describe` / `settings.update` /
`credentials.set` / `credentials.unset`。2026-10-21 加的五条是 `workspace.insertSessionBefore` /
`workspace.pin` / `workspace.unpin` / `workspace.insertBefore` 与 `subagent.prompt`。
**两个数都从代码里数，不靠减**；数法见 `tools.md`（要数 `METHODS` + `handlers.ts` 的**两种**注册形态）。
**三处必须同步**：`tools.md`、契约 §5.7 的表、这里的"x/37"。

**`session.projections` 是打开全部只读面的那把钥匙**：请求体只有 `{sessionId}`，返回所有投影的当前值。
已核实的键：`modelSelection` / `permissions` / `subagentCatalog` / `deliverables` / `tokenUsage` /
`contextPressure` / `sessionStats` / `turnOutline` / `todos` / `goal` / `plan` / `inbox` / `title` /
`workingDirectory` / `agentPreset` / `userQuestions`。

## 已定案的契约（实施时按这个写，不要重新发明）

细则在 `docs/subsystems/` 各篇，这里只列**最容易重新发明错的**：

- **配对 v2**：公开邀请与秘密分离、候选不是设备、**用户确认前不发秘密**；两段式 `beginPairing()` → `commit(code)`。
- **一条连接只服务一台设备**：握手/AEAD 密钥/`fc`/重放窗口全是每设备状态。
- **认证与可见面的边界**：只有握手三帧与 `presence` 明文（`needsBox(t)` 是唯一判据）。
- **AEAD**：AES-256-GCM；nonce 是 `fc` 的 96 位大端。
- **帧头 `id` 与幂等键是两个标识符**：`requestId` 只进信封（如 `i:<callId>` 带冒号），
  帧头 `id` 另铸且必须过 §3 的 ASCII 安全字符集。**把业务键写进帧头 = 连接器按 bad-frame 关连接。**
- **幂等**：两阶段（落盘 `pending` → 执行 → 改 `done`）；**落盘失败即拒绝该写操作**。
- **密钥**：API 密钥值不回传手机，改密钥只发新值。

## 已知缺口（定位过、有证据，都未修）

1. **首配的匿名限流桶是单一全局桶**：约 6 请求/秒即可让所有新设备换票 429（约 10 s 恢复）。
2. `stats.devices` 实为**通道数**，与 §8.2 的 `devices` 表不同名同义。
3. 握手层 close 4003 与 `protocol/revoked` 帧两条兜底路径仍走退避，未收口。
4. `pairing_page.dart` 的配对码 `TextField` 没关输入法联想，**手打**的 JSON 会被破坏（粘贴没事）。
5. **PC 端「上报地址」面板没有布局/点击的自动化测试**（只有 i18n 键完整性门禁；API 侧有用例）。
6. **IPv6 隐私地址仍会上报**：`dialOrder` 已把它们排后面，但仍占列表位。
7. **"最近工作区"缺 `createdAt`**：我们的 `workspace.list` 行只转四个字段
   （`connector/src/dsh/workspaces.ts:187-192`），所以"没有任何会话的工作区"永远不会被
   `newSessionWorkspaceId` 选中 —— 与 DSH 的 `recentWorkspace` 有一处已知偏离
   （`.agents/notes/implemented/2026-10-22-new-session-lands-in-a-workspace.md`）。

## 范围决定（别再当缺口）

- **刷新令牌轮换不做** / **中转不做多实例**（单实例 + I7 重启收敛就是个人工具的形态）。
- **鸿蒙暂缓**（不是放弃）：Flutter 版本锁保留，OHOS 适配/HUKS/推送全部暂停。
- **插件不做"逐插件页面适配"**：只做清单/状态/启停/安装日志 + `volatile` 字段通用表单。
- **管理页面不做**：二维码唯一出口，DSH 的 `CommandResult` 只有 text 没有图片出口。
- **不做 hard pin**："手动选择"= 立刻试一次（失败回自动）+ 拖动排序。
- **手机上不做（C 类）**：目录选择器、唤起电脑应用、内嵌浏览器/Office 预览、快捷键/窗口管理、
  workflow/schedule/skill、实验性功能。

## 门禁（改代码后必须全绿）

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | **486 / 26 / 49** 项 |
| `node app/tools/verify-platform-boundary.mjs` | **318 项**（22 条规则自检 + 扫 88 个 Dart 文件） |
| `node mock/proto/tools/verify-icons.cjs` / `verify-tool-paths.mjs` | 图标集（100 个）/ 20 个工具脚本无硬编码盘符 |
| `cd app && flutter test` | **1032 项** |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format --output=none --set-exit-if-changed …` | 各 **0** |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + **563 项** |
| `cd relay && pnpm typecheck && pnpm test` | 类型 + **86 条** |
| CDP 浏览器组 | `verify-proto`（**31**）/ `verify-authz`（18）/ `verify-settings`（28）/ `verify-tasks`（53）/ `verify-picker` / `verify-drawer`（**25**） |

**项数的唯一出处是 `tools.md`**；**改断言必须做一次变异校验**（故意破坏不变量，确认**恰好**那一条红）。

## 仍未注意就会翻车的

- **改源码只用编辑工具，不用 shell 字符串替换** —— shell 出错是静默的。
- **`dart format` 会重排文件**，之后再编辑同一文件要**重新读一遍**。
- 提交纪律 / 多替身接口 / 真机坐标 / adb 合成不出拖动落点 等**稳定坑点的唯一出处是 `tools.md` → Pitfalls**。

## 已落地批次索引

细节回 `git log`（每篇都有 hash 与决策笔记）。**唯一要记住的资产**：
`app/test/fixtures/real-session-events.json` **是真机落盘事件** —— 手写形状的用例只会复述实现的假设。

- 2026-10-21 子智能体页对齐 Web —— `.agents/notes/implemented/2026-10-21-subagent-catalog-tree-and-state.md`。
- 2026-10-21 晚 真机验收修掉的三条 + 锚定浮层 —— `2026-10-21-subagent-child-address-and-prompt.md`、`2026-10-21-anchored-popover-for-top-bar-panels.md`。
- 2026-10-21 深夜 抽屉行菜单锚定 + 拖动排序 —— `2026-10-21-anchored-popover-for-drawer-rows.md`、`2026-10-21-drawer-drag-and-counts.md`。
- 2026-10-22 轨迹页只做轮次 + refetch 补取 + 新建会话落进工作区 ——
  `2026-10-22-trajectory-turns-only-and-duration-bars.md`、`2026-10-22-refetch-markers-are-fetched.md`、
  `2026-10-22-new-session-lands-in-a-workspace.md`。
