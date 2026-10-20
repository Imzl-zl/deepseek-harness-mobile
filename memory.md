# dsh-mobile 项目状态

> 本文件是**当前状态快照** + 最近活跃窗口,允许覆盖更新。**不做流水追加** —— 历史属于 git 与 `.agents/notes/`。
> 决策与取舍见 `.agents/notes/`,稳定规律与坑点见 `tools.md`,现状事实见 `docs/`。
> 已落地的批次只在文末留一行索引,细节回 git 与笔记找。

## 下一步(新会话从这里开始)

> **在跑的任务书**:同一份 goal(goal-a9fd6fb1)。已落地**十九批**并**真机验证**。
>
> **DSH Web 的节点清单（`register-node-renderers.ts` 14 个 key）已全部有对应呈现** ——
> 逐个对照查出并修好了 7 处丢失：工具名被覆盖 / 参数行是键名 / 系统消息巨墙 /
> 流式文本不显示 / 斜杠命令卡 / 异常结局与重试（真日志 80 条"出了什么事"）/
> 过程摘要 / 压缩标记。`unknown` 是 `OtherItem`，`turn-tail` / `assistant-actions`
> 是桌面专属操作（**但"复制/用量 pill"那条正在做**，见待办 8）。
>
> **用户 2026-10-19 夜间反馈的 11 条里，8 条已落地**（气泡隐形 / 抽屉顺序 /
> 无会话 tab / 新建会话复用 blank / 按项目折叠 / 右抽屉统一宽度 / 全屏钮 /
> 停止 3s 自动解除 / 子智能体可进入）。**剩 3 条**见下。

待办:

1. ~~**历史翻页**~~ **2026-10-26 全链路做完**（anchor / `session.page` /
   `loadOlderHistory` / 滚到顶触发，四处都有单测，其中两处做过变异验证）。
   **只剩端到端没验** —— 装到公司电脑后手机停在"还没连电脑"
   （DSH profile 要重新出码配对，用户不在）。判据：滚到顶多出几轮，
   且过程摘要开始显示真实用时与计数（`turn/start` 进窗口了）。
2. **过程摘要的"用时/计数"在历史窗口不全时是如实的降级，不是 bug**：
   2026-10-19 真机看到 `🕐 第 12 轮 · 不到 1 秒`（渲染链路通了）——
   该轮的 `turn/start` 落在**更早且未加载的页**里。`stats` 因此只说时长、
   不摆"0 条消息"（`TurnProcessItem.stats` 只列有的项）。**别去"修"它** ——
   编一个用时或编一个计数才是错。第 1 条做完，这里自然就好了。
8. ~~**消息底部操作栏**~~ **2026-10-20 做完并真机验过**（复制 + 用量 pill +
   明细弹窗，挂在一轮已有的 `TurnProcessRow` 上 —— 它本来就是 DSH 的 `turn-tail`）。
   只做复制与用量：点赞/点踩要 `message-feedback` 写面、分支要 `session/fork`，
   本仓都未接，**不做死按钮**。真机实测：`用量 94.4K tok` + `复制`
   （窄屏 `Wrap` 自动折行），点开「本轮用量」= 94,408 tok / 缓存命中 30% /
   未缓存输入 66,352 / 缓存读取 27,946 / 输出 110。
   见 `.agents/notes/implemented/2026-10-20-turn-tail-actions.md`。
10. ~~**附件**~~ **2026-10-20 图片这条做真了**（系统照片选择器 + 自写通道，
    零 pub 依赖）。**「上传文件」仍不做**：DSH 的文件 part 要 `receiptId`
    （来自 `uploadFile`，本仓未接）。
    - 形状（`session-controller/src/types.ts:90-98`）：
      `{type:'image', mediaType, data(base64), name?}` **内联直发、不需要先上传**；
      `{type:'file', receiptId}` 才要回执。`mediaType` ∈ png/jpeg/webp/gif
      （`attachment/src/types.ts:8`）。
    - **我上一轮的判断错了**：`app/` 下**没有 `ohos/` 工程**（只有
      android/ios/windows），鸿蒙是未来目标、不是今天会被破坏的构建。
      真风险是"把鸿蒙能不能编过交给别人的发布节奏" ⇒ 照
      `dsh/gesture-exclusion` 的先例自写通道。
    - 原生：**相册**走 API 33+ `MediaStore.ACTION_PICK_IMAGES`（系统照片选择器，
      **不需要权限**，官方说它取代 `READ_MEDIA_IMAGES`）；以下退
      `ACTION_GET_CONTENT`（SAF，同样不要权限）⇒ Manifest 一行没加。
      **拍照**走 `ACTION_IMAGE_CAPTURE`，但**本 App 已为扫一扫声明了 CAMERA**
      （`AndroidManifest.xml:4`）⇒ 按 Android 规矩必须先授予、否则抛
      `SecurityException`；`EXTRA_OUTPUT` 走 `FileProvider`
      （`cacheDir/dsh_photo/`，API 24+ 给 `file://` 抛 `FileUriExposedException`）。
    - **本仓第一个手写 Android 依赖**：`androidx.core:core:1.13.1`
      （`FileProvider` 在它里面，Flutter embedding 不带）。取 1.13.1 而非最新；
      provider 的 `authorities="${applicationId}.dshfileprovider"`。
    - **限额仍不猜**：`ImageAttachmentLimits` 是部署解析的
      （`attachment/src/types.ts:74-82`），手机不知道；超了让电脑侧拒，
      把它的话如实显示（DSH 也是准入时校验，`types.ts:85-92`）。
    - **端到端未验**：未配对时输入栏置灰，`＋` 点不开 —— 要等配对后看
      "点照片/拍照 → 芯片 → 发送后气泡旁显示附件计数"。
      `iOS` / `Windows` 没有实现（通道不存在 ⇒ 点「照片」会直说没有相册）。
11. ~~**会话页与输入栏背景"不和谐"**~~ **2026-10-20 量出来并修掉**。
    真机像素：`#FFFFFF`(会话区) → **`#F1F3F5`(输入栏外面那条灰带)** →
    `#FFFFFF`(卡内)。所以是两件事叠起来：① 输入栏垫了 `c.sidebar` 灰带
    （底部像独立的栏、与上面断开）；② 卡片 `layer1`（亮色也纯白）**且无阴影**，
    在白底上隐形。**关键事实**：DSH 的 `--dsw-specific-input-major` 亮色
    **也是白**（`design-platform.css:269`）—— 看得见**完全靠 `elevation-soft`
    那层阴影**（`InputBar.module.css:62-63`），**只改底色改不出来**。
    已补 `composer` / `borderL2` token + 三层 `boxShadow`（发丝环
    `spreadRadius:0.5` + 两层模糊），外层底色改 `bgBase`。
    见 `.agents/notes/implemented/2026-10-20-composer-elevation-soft.md`。
    **顶栏那条灰带也一起修了**（同一个错）：DSH 的 `.header`
    （`ConversationRoot.module.css:15`）**只画 `border-bottom: 0.5px
    border-l3`、没有 background** —— 顶栏与页面同色。
    改后整页是一个连续白面（顶栏白+发丝线 / 会话区白 / 输入栏浮卡）。
    `sidebar` 色仍用于抽屉/设置/配对页（那些确实是"侧栏表面"）。
2. **剩下四件事的真机验收**（投影/渲染/接线都有单测，其中三处含**变异验证**）：
   - **流式文本**：判据是用户发一句话，正文边生成边显示。
   - **斜杠命令卡**：判据是在有 `/goal` 或 `/compact` 的会话里看到卡片。
   - **异常结局与重试**：判据是在有错误的会话里看到"第 N 轮出错 + DSH 原文"。
   - **压缩标记**：判据是在发生过压缩的会话里看到"已压缩上下文 ·
     替换 N 条 · 压掉 N tok"（**本会话 `session-1f80f156` 就有一条**）。
   - **过程摘要** ✅ 2026-10-19 已验（`第 12 轮` 那一行）。
2. **用量汇总的甘特图**：现在只有账本（一轮一行）。甘特要**每步**起止，
   而 `sessionStats` 是会话级总量（llmMs/toolMs/ttftMs/decodeMs）——
   拿总量画分段只能画两条 100% 宽的段（假图）。要逐步耗时可考虑插件加投影。
3. **输入栏横滚钮组**：rikkahub 的 `weight(1f)+horizontalScroll`
   （`ChatInput.kt:302-306`）。现在四个钮不换行，加第五个时才需要。
4. **全局侧滑的真相**（别当缺口）：Flutter 原生抽屉**本来就是整页高**可拖
   （`material/drawer.dart:680` 的 `height: double.infinity`），宽度由
   `drawerEdgeDragWidth` 控制。限制在**系统返回手势**：Android 官方
   `setSystemGestureExclusionRects` **每条边最多排除 200dp 总高度**。
   **结论：当前实现已是约束下的最优**，不要再试图"整页都能拖"。
5. DSH 0.2.1 的 `registerFetchRoute` 开始校验同路径重复注册:同 path 的 GET/POST 必须合成
   一条 `methods: ['GET','POST']`(0.2.0 时是绿的)。
6. **"又要扫码"先分清是"首次安装"还是"被重装"**（2026-10-26 真机踩到，
   **第一次判断错了，已修正**）：
   `adb shell dumpsys package com.example.dsh_mobile` 看两个时间戳：
   - `firstInstallTime == lastUpdateTime` ⇒ **这是首次安装**（这一版从没在
     这台手机上配对过）。**不是"被重装清数据"** —— 我第一次就这么判错了，
     还写进了笔记。`adb install -r` 实测是保住 `firstInstallTime` 的
     （重装后 lastUpdate 变、firstInstall 不变）。
   - `firstInstallTime` **变了**（比上次记的晚）⇒ 那才是被卸载重装过。
   - **判据**：先跟**上一次装包时记下的** `firstInstallTime` 比，别只看两个字段相等。
     （`tools.md:96` 那条"never `flutter install`"仍然成立，它防的是**同一份
     凭据被卸掉**；这里说的是"换个装包/换台手机时本来就没有凭据"。）

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

- `--profile` **只隔进程/插件/端口**;`~/.dsh/{.credentials.yaml,sessions,storages}` **全局共用**。
  **不另起测试 profile**;专用会话走「问 → 建(名字带 `[可删]`)→ 跑 → 用户确认后删」。
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

## 方法面 27/32

契约封闭集 **32**、实现 **28**,差额 4 个是契约列了没实现的:`settings.describe` /
`settings.update` / `credentials.set` / `credentials.unset`(依据见契约 §5.8)。
**两个数都从代码里数,不靠减**;数法见 `tools.md`(要数 `METHODS` + `handlers.ts` 的**两种**注册形态)。
**三处必须同步**:`tools.md`、契约 §5.7 的表、这里的"x/31"。

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
| `node app/tools/verify-platform-boundary.mjs` | **300 项**(22 条规则自检 + 扫 84 个 Dart 文件) |
| `node mock/proto/tools/verify-icons.cjs` / `verify-tool-paths.mjs` | 图标集(**100 个**;app/lib 引用 43 个)/ 工具脚本不许硬编码盘符(19 个) |
| `cd app && flutter test` | **882 项** |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format --output=none --set-exit-if-changed …` | 各 **0**(analyze 比 `flutter analyze` 严) |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + **550 项** |
| `cd relay && pnpm typecheck && pnpm test` | 类型 + **86 条** |
| CDP 浏览器组 | `verify-proto`(**31** = 顶栏与统计条 13 + 新会话页 hero 18) / `verify-authz`(18) / `verify-settings`(28) / `verify-tasks`(53) / `verify-picker` |
| | **2026-10-26 六项实测全绿**（这一串以前从没在本会话跑过；起法：`pwsh -File mock/proto/tools/cdp.ps1 -Port 9400`，然后 `$env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'`。注意 `verify-proto` / `verify-picker` 的汇总行格式与其它三个不同，别用同一条 `Select-String` 去抓） |

**项数的唯一出处是 `tools.md`**;**改断言必须做一次变异校验**(故意破坏不变量,确认**恰好**那一条红)。

## 仍未注意就会翻车的

- **改源码只用编辑工具,不用 shell 字符串替换** —— shell 出错是静默的(曾把源文件写空、造出空文件、
  让一处计数静默漂移 28 条)。批量改测试代码时用脚本文件 + 事后 `dart analyze`,别用内联 `node -e`。
- **`dart format` 会重排文件**,之后再编辑同一文件要**重新读一遍**(编辑工具会因"文件变过"拒绝)。
- 提交纪律 / 多替身接口 / 真机坐标 等**稳定坑点的唯一出处是 `tools.md` → Pitfalls**;本文件不复制一份。

## 已落地批次索引(细节回 git 与 `.agents/notes/`)

- **2026-10-19**(十六批,共 16 个提交):渲染三缺陷照 DSH 修 → 输入栏去忙时发送图标
  + 模型 chip 图标优先 → 右抽屉改真抽屉 + 快速跳转钮(rikkahub `MessageJumper`)
  → 浅色主题三档 + **全部 UI 面迁完** → 跨会话用量汇总(连接器 + 手机)
  → 输入栏几何判据 + 模型 chip 按内容宽(省 65px) → **换 WiFi 自动连上已验证**(家→公司)
  → 轨迹页接 `turnOutline` → 消息流显示流式文本 → 斜杠命令卡
  (`command/run` + `command/done`) → 一轮的异常结局与模型重试（`turn/end` 的
  reason + `llm/retry`；真日志 80 条"出了什么事"）→ 一轮的过程摘要
  （`turn-process`）→ **上下文压缩标记**（`compaction/*`；DSH Web 节点清单至此
  **全部有对应呈现**）→ **历史翻页骨架**（`session.page` + `loadOlderHistory`，
  26 个测试替身收成 `FakeSyncClient` 基类）。
  **`app/test/fixtures/real-session-events.json` 是真机落盘事件** —— 手写形状的
  用例只会复述实现的假设,这是"我们以为的形状与真形状不同"的判据。
- **2026-10-18/19**(连接与端点,9 个提交):帧头 id 与幂等键分离 → 多地点端点保留 → 端点管理 UI →
  PC 端上报地址后端 → 面板 + 0.2.1 适配 → 点名连接 → 切换/重连归位 → 拖动柄 44×44 → 全零投影收起。
  **每篇都有决策笔记,哈希回 `git log` 找。**
- **更早**:`6a9249b` 顶栏一行 + 统计条横滚 + hero + 图标集 98→100;交互转手机整链 / 端点切换与
  局域网直连 / 归档面 / 排队与打断 / 设置页四组 / 标题单一真值源 / 模型目录真形状 /
  设备身份与失效恢复 / 传输分开关 / 假数据清理 / 配对 v2 三侧收口。
