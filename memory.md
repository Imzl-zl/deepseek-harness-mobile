# dsh-mobile 项目状态

> 本文件是**当前状态快照** + 最近活跃窗口,允许覆盖更新。**不做流水追加** —— 历史属于 git 与 `.agents/notes/`。
> 决策与取舍见 `.agents/notes/`,稳定规律与坑点见 `tools.md`,现状事实见 `docs/`。
> 已落地的批次只在文末留一行索引,细节回 git 与笔记找。

## 下一步(新会话从这里开始)

> **2026-10-21 深夜：四阶段一轮收口** —— ① 剩下两处「跟手」改成锚定浮层（顶栏连接点、
> 抽屉行菜单；菜单触发从长按挪到行尾「…」，长按留给拖动）+ 抽屉拖动排序与组头常显计数
> （连接器新增 `workspace.insertBefore`，方法面 36→37）；② 容器中转端到端（配对 → 列表 →
> 发一句 → 收到回复），公网那段**未验（无服务器）**；③ 最终包只装一次（H2 归档闭环、D1 附件已补验：过），E/F/G/D/H 逐条
> 判据见 `docs/subsystems/subagent-page.md` §7.2（**D1 附件发送未过**、E3 拖动与 H2 归档
> 未验、D2/D3/A6 未造出）；④ 门禁全绿（flutter 1009 / connector 563 / relay 86 /
> protocol 486·26·49 / boundary 318 / CDP 六项）。
> 笔记：`.agents/notes/implemented/2026-10-21-anchored-popover-for-drawer-rows.md`、
> `.agents/notes/implemented/2026-10-21-drawer-drag-and-counts.md`。
> **D1 已通过**：根因是模型条目没声明 `input`（DSH 默认按纯文本拒），补 `input: [text, image]` 后图片能发、模型能读。

> 2026-10-20 晚这一轮把「渲染清单」清完了（1/3/5/6/7 改，2/4/8 判定不改），
> 并用 `DSH_HOME` 隔离实例做了**一次真机全测**。清单与逐条证据在
> `.agents/notes/proposed/2026-10-20-rendering-issues-todo.md`（第 9、10 条是
> 真机当场新发现的两条）；取舍与行号在
> `.agents/notes/implemented/2026-10-20-render-alignment-to-dsh-spec.md`。
> **2026-10-21：子智能体页按 Web 对齐已落地（P0+P1+P2）**：
> 活动态/时长/token 来自投影（`mode` 不再冒充 running）、目录是
> 「直接子级 + 展开才读」的树、三态分开、子会话头部有当前标题 + 切换 sheet、
> 一次性/未知换成 54px 只读框。**行与只读框按触屏重排**（行尾 44dp 展开按钮、
> 右列只放 token、时长进详情行、只读框文字两行），并补了**系统返回键回父会话**。
> 判据与仍缺的两条（`parentAvailable` / 右侧栏子智能体聊天）见
> `.agents/notes/implemented/2026-10-21-subagent-catalog-tree-and-state.md`
> 与 `docs/subsystems/subagent-page.md`。对照清单
> `.agents/notes/proposed/2026-10-21-subagent-web-parity.md` 仍是**差距的唯一出处**。
>
> **2026-10-21 晚：隔离实例真机验收（A/B/C 三段）** —— 抓到并修掉三个真机专属缺陷：
> ① 子会话白屏（`follow`/`page` 地址缺父级，宿主直接拒）、② 子会话发不出消息
> （`session.prompt` 被拒成 `is owned by subagent routing`，新增 `subagent.prompt`）、
> ③ 面板指标与顶栏 running 只在重连后才更新（清单行只在连上时拉过）。
> 另按用户当场意见把「切换子智能体」从底部 sheet 改成**锚定浮层**（`ui/dsh_popover.dart`）。
> 用户随后问「用量都没有东西啊」——**第四个真机缺陷**：用量页把"拉之前的快照"传进
> 无状态页面，永远空态；已收进 `UsagePageHost`（`initState` 拉 + `ListenableBuilder` 重画），
> 真机现在显示 578K / 两个项目。
> 逐条判据见 `docs/subsystems/subagent-page.md` §7 与
> `.agents/notes/implemented/2026-10-21-subagent-child-address-and-prompt.md`、
> `.agents/notes/implemented/2026-10-21-anchored-popover-for-top-bar-panels.md`。

待办（按顺序）:

0. **轨迹页对齐 + 移动端适配**（2026-10-22 用户当场指出：「时间轴，轮次，调用都没有啊」
   「完全没对齐 web」「要考虑屏幕空间和美观」）。差距与优先级清单在
   `.agents/notes/proposed/2026-10-22-trajectory-page-parity-and-mobile-fit.md`：
   P0 = 三个 chip 是死的、甘特没有数据源、条目 sheet 的黄色竖排英文待复现；
   P1 = Web 是表 + 时间轴 + 详情 tab；P2 = 640px 甘特在 390dp 上的适配；P3 = 本轮欠账。
   **先删死 chip，别留假入口**。

1. **轮组（turn/step 分组 + 折叠过程）** —— 用户当场指出 Web 与 App 结构不同：
   Web 是 `已完成，用时 X ⌃` 一个可展开的轮组，组内分 `已完成分析`/`执行了命令`，
   上下文注入与思考/工具都在组里；手机是平铺。这不是样式差，是**少了一层结构**
   （做法与代价见清单第 9 条）。
2. **`ask_user_question` 未计时提问答不了** —— 用户当场指出"提问报错"。
   我们的连接器在 `request.wait?.callId` 缺失时 fail-closed 抛出
   （`connector/src/interaction-claims.ts:255`），而 DSH 的 `wait` 对 indefinite
   提问**本来就没有**（`packages/interaction/user-questions/src/types.ts:140-145`）。
   做法见清单第 10 条。
3. **斜杠命令没有执行面** —— `/goal …` 走 `session.prompt` 变成**普通消息**（模型回
   "The user typed /goal …"）。DSH 的命令执行面是 `commands.execute(agent,line)`
   （`packages/interaction/commands/src/index.ts:360-367`），我们方法面里**没有它**
   （只有 `permission.switch` 内部拼 `/permission <preset>`）。要加 `command.execute`
   + 手机侧把 `/` 开头的输入走它。**命令卡的渲染本身已被单测钉住**，别混为一谈。
4. **电脑侧停一会儿，手机会清掉配对** —— 中转重启后名册是空的，设备换票拿到 401，
   App 把 401 归成 `notPaired`（终态）⇒ 清凭据回配对页。实测一次（清单第 11 条，
   含两条修法方向：名册持久化/503，或 App 侧只在连接器明确拒绝时才终态）。
5. **侧边栏移动 / 置顶：真机已验**（2026-10-21 晚，隔离实例）——
   长按菜单四项（无删除）、置顶后进本组最前并出图钉、跨置顶分区上移不可点、
   未分组桶上移/下移不可点、归档后从列表消失且能在「归档」页取消、
   **杀 App 重开 + 中转重启后置顶与顺序仍成立**。
   唯一没在真机隔离出来的是"同组内非置顶行之间的上下移"（本机没有工作区分组，
   所有会话都落在「未分组」桶，上移/下移一律不可点 —— C4 的判据先命中）。
6. **子智能体进入 / 后台任务看与停：真机已验**（2026-10-21 晚）：
   点目录行进子会话、`←` 回父、系统返回键同一条路、切兄弟后父级记忆不丢、
   子会话内容能加载、跑完变绿且时长定格、顶栏 running 计数会变。
   **但当场抓到两个只会在真机上暴露的缺陷**（都已修 + 补回归）：
   ① 子会话的 `follow`/`page` 缺父级地址 ⇒ 进去一片空白；
   ② 对子会话发消息被宿主拒 ⇒ 「发送失败」，唯一入口是新的 `subagent.prompt`。
   另有两条造不出来：孙级（宿主 `maxDepth` 默认 **1**，只能派直接子级）、
   一次性子会话（本 profile 的两个 in-process 后端都只产 `continuable`）。
7. **隔离实例验收剩下的三条**（仍未验）：附件（`＋`→照片→芯片→发送→附件计数）、
   历史翻页（快照页 100 条，要造够真历史）、异常结局/重试/压缩标记。
8. **`mock/proto` 子代理面板还没跟上落地端**（2026-10-21 有意留的差异，用户已确认先提交）：
   原型 `renderSubs` 还是平铺的演示行（`task`/`state`/`dur`），而 App 已经是
   「直接子级 + 展开懒加载」的树 + 三态 + token + 详情行 + 行尾 44dp 展开 + 顶栏标题切换。
   同步要**一次做完**：disclosure 交互、三态演示数据（加载 / 失败+重试 / 已知空叶）、
   token 与详情行、一个新的 `verify-subs.mjs` —— 半截做会留下"看起来能点、没有断言"的面板。
   在那之前结构以 `app/lib/ui/subagent_tree.dart` 与 `docs/subsystems/subagent-page.md` 为准。
9. **「上传文件」** —— 开工单在
   `.agents/notes/proposed/2026-10-20-file-upload-shape.md`（DSH 侧入口
   `packages/client/file-upload/src/index.ts:105,118`；共 8 个触达点，**别半截提交**）。
10. **历史翻页的 `refetch` 标记被丢弃**（2026-10-22 静态审查发现，未修）：
    `sync_client_impl.dart:956` 把 `{kind:'refetch', seq, bytes}` 直接跳过、从不调
    `session.refetch` ⇒ **>1 MiB 的条目在会话里静默缺失**（不报错、不缺页，就是少一条）。
    连接器侧完整（`session-page.ts` + `refetchThresholdBytes` 默认 1 MiB）。
11. ~~失败回合没有"手动重试"入口~~ **不做（2026-10-22 查证）**：DSH Web 的
    `ui-conversation` 也没有这个入口（只有自动重试的 `ModelRetryItem` 展示）——
    不是我们对齐漏了，按"照 DSH"的原则不加。

别当缺口（定案，别再试）:

- **全局侧滑**：Flutter 原生抽屉本来就是整页可拖（`material/drawer.dart:680`
  的 `height: double.infinity`）。真限制是**系统返回手势** ——
  `setSystemGestureExclusionRects` **每条边最多 200dp 总高**。当前实现已是最优。
- **过程摘要的"用时/计数"在历史窗口不全时是如实降级**：`turn/start` 落在
  未加载的更早一页里，所以只说时长、不摆"0 条消息"。**别去"修"**。
- **用量甘特图**要**每步**起止，而 `sessionStats` 是会话级总量 ——
  拿总量画分段只能画出假图。要做得先加投影。
- **输入栏横滚钮组**只在加第五个钮时才需要（现在四个不换行）。
- **会话流里 `user/message` 不一定是人说的**：运行时上下文 / 技能目录 / 时间快照
  都是 `user/message`，靠 `source.kind === 'user'` 区分（DSH
  `conversation-nodes/message.ts:79`）。这条已修，别再按事件类型认角色。

## 2026-10-20 晚上这一轮（渲染对齐 + 隔离实例全测）

- **正文 13/20 → 14/24**（13 是次要档，不是正文）；标题字号表照 DSH。
- **工具卡正文**换成 `.ioCard`/`.ioSection`/`.ioText`（11/16 等宽、上限 150、内滚）。
- **折叠行**（思考 / 系统提示词 / 上下文注入 / 斜杠命令）按 `DisclosureRow` 重写：
  行高 36（触屏偏离）、标题 13、`label-tertiary`、去卡片；思考正文是 compact Markdown
  且收起时显示首行摘要，系统提示词/上下文是 11/16 等宽的 141px 滚动区。
- **斜杠命令卡**不再是工具卡形状：disclosure 行 + 代码正文（上限 260）。
- **宽表**：`IntrinsicColumnWidth` 拿到横向滚动（真机验过：六列可左右滑）。
- **围栏扫描**：`~~~`/四反引号/未闭合都按 CommonMark 处理（原来会改写围栏内源码）。
- **会话流方向修好**：`reverse: true` 下列表下标要倒着取 `items`（原来是**整段倒排**，
  最新在最上、进入会话落在最早一条）。
- **上下文注入不再冒充用户消息**（`source.kind` 判据）。
- **键盘弹起时接管卡不再撑爆底部**（上限按"可用高度"算，扣掉 `viewInsets.bottom`）。

**隔离实例真机验收**（`DSH_HOME=D:\tmp\dsh-e2e`；起法见清单「验收状态」一节）：
已验 = 流式正文、代码块、宽表横滚、工具卡展开、轮摘要真实数字、上下文注入三行、
审批接管卡（真跑通一次越权写入）；未验 = 附件、历史翻页、异常结局/重试/压缩标记。
**`/goal` 没走命令通道**（被当普通消息发出）—— 下一轮先查这一条。


## 附件与图片（做过的，别重做）

- 形状（`session-controller/src/types.ts:90-98`）：图片
  `{type:'image', mediaType, data(base64), name?}` **内联直发、不用先上传**；
  文件 `{type:'file', receiptId}` 才要回执。`mediaType` ∈ png/jpeg/webp/gif
  （`attachment/src/types.ts:8`）。
- **`app/` 下没有 `ohos/` 工程**（只有 android/ios/windows）—— 鸿蒙是未来目标，
  不是今天会被破坏的构建。真风险是"把鸿蒙能不能编过交给别人的发布节奏"，
  所以照 `dsh/gesture-exclusion` 的先例**自写通道、零 pub 依赖**。
- 相册 = API 33+ `ACTION_PICK_IMAGES`（**不要权限**）/ 以下 `ACTION_GET_CONTENT`；
  拍照 = `ACTION_IMAGE_CAPTURE`，但**本 App 已为扫一扫声明 CAMERA**
  （`AndroidManifest.xml:4`）⇒ 必须先授予否则 `SecurityException`，
  `EXTRA_OUTPUT` 走 `FileProvider`（`cacheDir/dsh_photo/`）。
- **本仓唯一手写 Android 依赖**：`androidx.core:core:1.13.1`。
- **限额不猜**：`ImageAttachmentLimits` 是部署解析的（`attachment/src/types.ts:74-82`）；
  超了让电脑侧拒、把它的话如实显示。
- **图片预算按"一条消息合计"算**（3 MiB），不是按每张 —— 见第八条教训。
## 当前能力(都已在真机上跑通过)

- **会话面**:流 / 历史 / 发送 / 取消 / 排队(编辑·删除·插话)/ 插话与打断 / 列表按工作区分组。
- **交互转手机**:审批 / 提问 / 计划审查,per-session 待处理队列,跨会话角标与提示行。
- **只读面**:统计条、模型名与切换、权限档、Agent 预设目录、后台任务、子智能体目录、归档。
- **连接**:中转 + 局域网直连,**首次经中转学地址、之后走直连**(连续 3 次重连都成立)。
  **换 WiFi 自动连上已验**(2026-10-19 家→公司):重启 App 15 秒内连上,前提是电脑侧
  DSH 已在新网络跑着;新地址由 `endpoint.describe` 的 direct 通道自报学到。
  **两个功能分开**:「换个连接方式」(立刻断、只试这一条,失败回自动)与「自动队列」
  (记住的 → 同网段 → 用户顺序,失败顺延);入口是设置页顶部块 + **顶栏状态点**。
  队列可**拖动排序**、可删除 / 手填(限非公网),删掉的自报端点可在「已隐藏」里放回。
- **新会话页**:连上后落到 blank 会话 → hero(鱼 + 标题 + 预览版徽标 + 两枚 chip)。
- **PC 端**:两通道各自开关;`/api/dsh-mobile/advertise` 管上报地址(藏虚拟网卡 / 追加)。

## 八条教训

> 前五条是"替身复现的不是真形状"；第六条是"提交不完整"；
> 第七条是"生产路径上的假数据"；第八条是"线上预算要按帧算"。

1. **投影信封**:`session.projections` 回 `null | {kind, asOfSeq, values}`,**手机要 `values`**。
   连接器曾整包透传 ⇒ 统计条/权限档/子智能体在生产里全空态而单测全绿
   (修在 `connector/src/dsh/projections.ts` 的 `valuesOf`)。**新接投影面先问"替身回的是真形状吗"。**
2. **模型目录**:`buildModelCatalog` 返回**对象**(`{default, routableProviders, groups, failures}`)
   不是数组;解析器认错形状 ⇒ 生产里一次都没解析成功过。
3. **`session/select-model` 没有"不能写"的约束**:Web 调的就是它
   (`ui-model-selection/src/client/directory.ts:98`)。我曾把**测试纪律**(测试 profile 与日常
   profile 共用 `~/.dsh/`)错升成产品约束。
4. **"空"有两种表达,判空只查一种就会漏**:`items.isEmpty` 漏了 `OtherItem`(hero 从未显示);
   `usage == null` 漏了**字段齐全但全零**的对象(输入框底下显示 `0 tok`)。
5. **判据要能区分"没命中"与"没实现"**:同一句"点了没反应"可能是坐标偏 30px、也可能是回调没跑
   ——2026-10-18 两者同时发生,白查了五轮。**先加一行 `debugPrint` 确认回调跑了没有**,再怀疑手势。
6. **一个功能要一次提交完整**:2026-10-20 发现 `3979191`（"用量搬到抽屉"）只提交了
   `ui/usage_page.dart`，而它引用的 `UsageProject` / `grouped` 在 `model/usage_summary.dart`
   里**没进库** —— 那个提交单独编译不过（下一个提交 `5b36be4` 才补齐）。
   **没 CI 时这类残缺提交不会被拦**。规律：**提交前 `git status --porcelain` 必须是空**
   （除了自己有意的未跟踪文件），且新加的文件要**反向 grep 一下"谁引用了它"**。
7. **生产路径上的假数据是最容易漏的一类**（不报错、不空屏、样式也对，
   只是名字/数字是编的）。2026-10-20 一次自查抓到两个：
   - `＋` 的「附件」加一枚 `PendingAttachment('新增文件.txt')`，而 `_send()`
     的 `content` 只有文本块 ⇒ **发送时静默丢弃**（比死按钮更糟：
     死按钮是没反应，这个是"看起来成功了"）；
   - 文件面板表头写死 `chat_page.dart` / `+128 −46`，而面板体显示「还没有改动」
     ⇒ **表头与面板体互相矛盾**；同面板底部三个动作全是 `_notWired`
     （而我们自己的规则写着"只弹还没做的假入口比没有这一行更糟"）。
   **抓法两条**：① grep `lib/` 里写死的文件名/中文/数字；
   ② grep `_notWired(` 与 `还没做` —— 每个都是"承诺了但没做"的入口。
   **2026-10-20 收口**：`_notWired` **已删除**（没有调用方了）；`＋` 菜单
   从 7 项降到 4 项，每一项都是真的（拍照 / 照片 / 后台任务 / 演示）。
   注意这条规则**不给"弹一句还没做"留例外** —— 我一度用"它说的是还没做、
   不是假装做了"给自己找台阶，被 `settings_page.dart:7` 的原文否掉。
8. **线上预算要按"帧"算，不按"对象"算**（2026-10-20 连续踩两次）：
   ① 只算了一层膨胀 —— 二进制 `N` → JSON base64 `1.33N`，**漏了 `box` 的
   base64url 又 ×1.33** ⇒ 实际一帧 ≈ **1.78N**（一张 5 MB 照片 ≈ 8.9 MB 帧，
   撞 8 MiB 上限**并关连接**）；
   ② 预算按"每张图"给 —— **漏了整条 content 共用一帧**（两张 3 MiB ⇒ 10.7 MB）。
   **自查的问法**：这个值在线上最终会被**哪一帧**承载？**那一帧里还有谁？**
   **传播后的体积**是多少（base64、加密、再 base64 各乘多少）？

## 真机联调的成本纪律(立过规,别问第二遍)

- **`--profile` 只隔进程/插件/端口**，`~/.dsh/{.credentials.yaml,sessions,storages}`
  全局共用 —— 但它**不是**唯一办法：`DSH_HOME` 是官方支持的**数据根覆盖**
  （`packages/util/home-paths/src/index.ts:17,135` 的 `DSH_HOME_ENV` 与
  `resolveDshHome()`，优先级 显式配置 → `$DSH_HOME` → `~/.dsh`）。
  所以**起隔离实例是可行的**：`$env:DSH_HOME='<临时目录>'` 后再启动，
  credentials / sessions / storages / attachments 全部落在那个目录，
  **不碰用户的 `~/.dsh`**。端到端验收应当走这条路，而不是"做不了"。
  仍不要做的是：拿**默认**根另起第二个实例（那才是并发写同一份会话日志）。
- **跑之前报一句"这次约几个轮次"并拿到准** —— 审批探针要模型真跑越权命令,花的是用户的钱。
- 装 App 一律 `flutter build apk --debug` + `adb install -r`;`flutter install` 与
  `flutter test integration_test/` **都会先卸载旧 App**,配对凭据一卸全没。
- 屏幕灭掉 = 引擎暂停(用例报"did not complete"且没原因)⇒ `adb shell svc power stayon true`。

## 前置事实(会卡住实施)

- **单帧上限 8 MiB，而任何二进制载荷在线上会放大 ≈1.78 倍**
  （契约 §40 + `connector/src/transport/codec.ts:53,77`：超了接收侧
  `protocol/bad-frame` **并关闭连接**）。
  放大链：原始 `N` → JSON 的 base64 `1.33N` → 密文 ≈`1.33N` →
  `box` 的 base64url（协议 §132 `base64url(密文‖16字节tag)`）**再 ×1.33**
  ⇒ **一帧 ≈ 1.78 N**。
  **所以二进制附件的原始字节预算 = 3 MiB**（3×1.78 ≈ 5.3 MiB，余 2.7 MiB）。
  图片由 `MainActivity.encodeForTransport` 压（≤3 MiB 原样过、超了按最长边
  1600px 重编码），Dart 侧 `kMaxImageBytesForTransport` 再兜一道。
  **发别的二进制（将来传文件）也要按这条算，别只算 base64 那一层。**

- **DSH 运行时 0.2.1-rc.2**(桌面版自带)。连接器 devDeps/peerDeps 都跟 0.2.1-rc.2,
  `schemastery` 跟 **3.18.5**(钉旧版会装出两份 ⇒ tsdown 报 "type cannot be named")。
- **Flutter 3.41.9 / Dart 3.11.5 版本锁死**(上界由鸿蒙 fork 定)。Android 构建要
  `ANDROID_HOME='D:\soft\android-sdk'` + `JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-21.0.9.10-hotspot'`。
- 明文 HTTP 放行有**四处**,少一处静默不通:Android `network_security_config.xml`(debug)、
  `PairingPage.allowInsecureLocal`、`main.dart` 的 `PairingClient`、profile `cordis.patch.yml`。
- **无线直连三件一起对**:`listenPort: 8790` + `listenHost: '0.0.0.0'`、8790 监听在 `0.0.0.0`、
  `caps.direct === true`。**`relayUrl` 必须写环回** —— 写死局域网 IP 会绕开 `relayHintFor`
  的自愈,换网后手机拨不通而重新出码还是死地址。
- `connector/` 与 `relay/` 是**两个独立 pnpm 工程**,导入风格不同、别顺手统一
  (connector 写 `.js` 因 tsdown 打包,relay 直接跑 `.ts`)。本仓库**没有 CI**。

## 方法面 33/37

契约封闭集 **37**、实现 **33**,差额 4 个是契约列了没实现的:`settings.describe` /
`settings.update` / `credentials.set` / `credentials.unset`(依据见契约 §5.8)。
2026-10-21 加的五条是 `workspace.insertSessionBefore` / `workspace.pin` /
`workspace.unpin` / `workspace.insertBefore`(项目头拖动排序) 与 `subagent.prompt`
(子会话唯一的写入口,见下)。
**两个数都从代码里数,不靠减**;数法见 `tools.md`(要数 `METHODS` + `handlers.ts` 的**两种**注册形态)。
**三处必须同步**:`tools.md`、契约 §5.7 的表、这里的"x/37"。

**`session.projections` 是打开全部只读面的那把钥匙**:请求体只有 `{sessionId}`,返回所有投影的当前值。
已核实的键:`modelSelection` / `permissions` / `subagentCatalog` / `deliverables` / `tokenUsage` /
`contextPressure` / `sessionStats` / `turnOutline` / `todos` / `goal` / `plan` / `inbox` /
`title` / `workingDirectory` / `agentPreset` / `userQuestions`。

## 已定案的契约(实施时按这个写,不要重新发明)

细则在 `docs/subsystems/` 各篇,这里只列**最容易重新发明错的**:

- **配对 v2**(`pairing-v2.md`):公开邀请与秘密分离、候选不是设备、**用户确认前不发秘密**;
  两段式 `beginPairing()`(秘密未发)→ 用户确认 → `commit(code)`。
- **一条连接只服务一台设备**:握手/AEAD 密钥/`fc`(nonce 唯一来源)/重放窗口全是每设备状态。
- **认证与可见面的边界**:只有握手三帧与 `presence` 明文(`needsBox(t)` 是唯一判据);
  中转只读 `sid`/`seq`/`fc`/帧类型/帧头 `id`,方法名与载荷不可见。
- **AEAD**:AES-256-GCM(Electron 的 crypto 没有 `chacha20-poly1305`);nonce 是 `fc` 的 96 位大端。
- **帧头 `id` 与幂等键是两个标识符**:`requestId` 只进信封(形状由业务定,如 `i:<callId>` 带冒号),
  帧头 `id` 另铸且必须过 §3 的 ASCII 安全字符集。**把业务键写进帧头 = 连接器按 bad-frame 关连接。**
- **幂等**:两阶段(落盘 `pending` → 执行 → 改 `done`);**落盘失败即拒绝该写操作**;`requestId` 在信封顶层。
- **密钥**:API 密钥值不回传手机,改密钥只发新值。

## 已知缺口(定位过、有证据,都未修)

1. **首配的匿名限流桶是单一全局桶**:形状校验在取桶之后,约 6 请求/秒即可让所有新设备换票 429
   (约 10 s 恢复)。与 `pairing-v2.md` §3 的要求不符。
2. `stats.devices` 实为**通道数**(`relay/src/core.ts`),与 §8.2 的 `devices` 表不同名同义。
3. 握手层 close 4003 与 `protocol/revoked` 帧两条兜底路径仍走退避,未收口。
4. `pairing_page.dart` 的配对码 `TextField` 没关输入法联想,**手打**的 JSON 会被破坏(粘贴没事)。
5. **PC 端「上报地址」面板没有布局/点击的自动化测试**(只有 i18n 键完整性门禁;API 侧有用例)。
6. **IPv6 隐私地址仍会上报**:这台机器报 7 条,其中 4 条是每次轮换都变的 GUA。
   `dialOrder` 已把它们排后面(不再是 30 秒冷启动的成因),但仍占列表位,要用户手动藏。
7. ~~图片附件发不出去~~ **已解决（2026-10-22）**：根因是**模型配置**——`llm-pi-ai` 的模型条目
   不声明 `input` 时按 `DEFAULT_INPUT = ['text']` 在发送前拒掉（`llm-pi-ai/src/config.ts:74`）。
   profile 补 `input: [text, image]` 后 D1 通过：电脑侧 `user/message` 有 `{type:'image'}`，
   模型回复读出了截图内容。**换免费渠道/模型时先看这一条**，别再把"没声明"当成"不支持"。
   （顺带：错误原本只在键盘挡住的 SnackBar 里，`D1` 那两次就是这样被漏看的。）

## 范围决定(别再当缺口)

- **刷新令牌轮换不做** / **中转不做多实例**(单实例 + I7 重启收敛就是个人工具的形态)。
- **鸿蒙暂缓**(不是放弃):Flutter 版本锁保留,OHOS 适配/HUKS/推送全部暂停。
- **插件不做"逐插件页面适配"**(架构上不存在通用渲染):只做清单/状态/启停/安装日志 + `volatile`
  字段通用表单。**别自己从零做通用 schema 渲染器** —— DSH 两次否决过。
- **管理页面不做**:二维码唯一出口,DSH 的 `CommandResult` 只有 text 没有图片出口。
- **不做 hard pin(钉死某个端点、失败也不换)**:用户明确要求"连接不上会自动试其他的"。
  "手动选择"= 立刻试一次(失败回自动)+ 拖动排序,不是"锁死在一条上"。
- **手机上不做(C 类)**:目录选择器、唤起电脑应用、内嵌浏览器/Office 预览、快捷键/窗口管理、
  workflow/schedule/skill、实验性功能。

## 门禁(改代码后必须全绿)

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | **486 / 26 / 49** 项 |
| `node app/tools/verify-platform-boundary.mjs` | **318 项**(22 条规则自检 + 扫 88 个 Dart 文件) |
| `node mock/proto/tools/verify-icons.cjs` / `verify-tool-paths.mjs` | 图标集(**100 个**;app/lib 引用 49 个)/ 工具脚本不许硬编码盘符(20 个) |
| `cd app && flutter test` | **1010 项** |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format --output=none --set-exit-if-changed …` | 各 **0**(analyze 比 `flutter analyze` 严) |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + **563 项** |
| `cd relay && pnpm typecheck && pnpm test` | 类型 + **86 条** |
| CDP 浏览器组 | `verify-proto`(**31** = 顶栏与统计条 13 + 新会话页 hero 18) / `verify-authz`(18) / `verify-settings`(28) / `verify-tasks`(53) / `verify-picker` / `verify-drawer`(**25** = 长按菜单四项 + 无删除 + 置顶标记 + 上移边界 + 下移 + 置顶/取消置顶 + 归档 + 拖动排序) |
| | **2026-10-21 六项实测全绿**（起法：`pwsh -File mock/proto/tools/cdp.ps1 -Port 9400`，然后 `$env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'`。注意 `verify-proto` / `verify-picker` 的汇总行格式与其它几个不同，别用同一条 `Select-String` 去抓） |

**项数的唯一出处是 `tools.md`**;**改断言必须做一次变异校验**(故意破坏不变量,确认**恰好**那一条红)。

## 仍未注意就会翻车的

- **改源码只用编辑工具,不用 shell 字符串替换** —— shell 出错是静默的(曾把源文件写空、造出空文件、
  让一处计数静默漂移 28 条)。批量改测试代码时用脚本文件 + 事后 `dart analyze`,别用内联 `node -e`。
- **`dart format` 会重排文件**,之后再编辑同一文件要**重新读一遍**(编辑工具会因"文件变过"拒绝)。
- 提交纪律 / 多替身接口 / 真机坐标 等**稳定坑点的唯一出处是 `tools.md` → Pitfalls**;本文件不复制一份。

## 已落地批次索引

细节回 `git log`（每篇都有 hash 与决策笔记）。**唯一要记住的资产**：
`app/test/fixtures/real-session-events.json` **是真机落盘事件** ——
手写形状的用例只会复述实现的假设，这份 fixture 才是"我们以为的形状与真形状不同"
的判据。

- 2026-10-21 子智能体页对齐 Web（目录树 / 三态 / 指标 / 头部切换 / 只读框）——
  `.agents/notes/implemented/2026-10-21-subagent-catalog-tree-and-state.md`。
- 2026-10-21 晚 真机验收修掉的三条 + 锚定浮层：
  `.agents/notes/implemented/2026-10-21-subagent-child-address-and-prompt.md`、
  `.agents/notes/implemented/2026-10-21-anchored-popover-for-top-bar-panels.md`。





