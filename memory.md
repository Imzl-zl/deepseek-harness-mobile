# dsh-mobile 项目状态

> 快照 + 最近窗口，**覆盖更新**，不做流水追加。历史在 git 与 `.agents/notes/`；
> 稳定命令与坑点在 `tools.md`；现状事实在 `docs/`。

## 现在（2026-11-04）

- **思考行标题粘顶 + 重试可展开（11-04 第二批真机反馈）**：① 思考正文**不封顶**（照 DSH），
  标题行靠 `StickyNoteHost`（`ui/sticky_note.dart`）钉在列表顶部 —— 量位置必须**在帧后**
  （滚动通知里读到的是上一帧坐标，第一版因此永不出现）；② 重试行改成可展开：
  `重试延迟：{n}ms` + `失败原因：{message}（{code}）`（DSH `<details>` 同构）。
  **仍未修**：重启后这些行只剩 `重试 1/0`（无原因、无可展开），因为本地库每个 itemId
  只存**最后一条事件的 payload**，而 `llm/retry-started` / `tool/result` 的字段靠内存里的
  `previous` 合并 —— 冷启动就没有 previous 了（同一根因见下面的工具行"工具"）。

- **后台任务行 + 思考折叠（11-04 真机反馈）**：① "展开后再点折叠回不去"的真因是
  `Set.add` 只加不删（元素已在集合里时返回 false、集合不变），下一状态改由
  `toggledJobIds`（`ui/side_pane.dart`）一处算；② 停止按钮照 DSH 挪到行按钮**外面**
  （`.rowLine` 的兄弟）、只在 `running` 行出现、字形 `close` → `stopFill`（原来像
  "关闭 / 删除"，还挤着展开箭头）；③ 可展开判定照 `isObservable`（活的 || 有输出），
  活行没输出也能展开，展开后空输出说"（无输出）"；④ 思考正文**封顶半屏自己滚** ——
  Flutter 没有 `position: sticky`，用封顶换"标题行一直在视野里"（偏离记在
  `subsystems/turn-groups.md` §4）。app **1692**。

- **工具行不再溢出（11-04 真机）**：`mcp__chrome-devtools__evaluate_script` 这类长工具名把
  `ToolCard` 的 Row 撑破（右下角黄黑斜纹 = Flutter 的 `RIGHT OVERFLOWED BY 202 PIXELS`）。
  修法：名字按**可用宽度**设上限（有参数 55%、无参数用满）+ 单行省略号；
  `render_alignment_test.dart` 两条 390dp 用例钉住（变异校验：撤掉修法即 202 / 226 px 溢出）。app **1688**。

- **轨迹页空态：手机手里那份投影包旧了，不是连接器没注册投影（11-04）**：
  真机空态说"连接器没注册 trajectory 投影，升级连接器"，而同一台电脑同一连接器（0.1.16）
  **重启 App 后 20 轮立刻画出来**；电脑侧 `session_projcache` 里 `turnOutline` 20 条、
  `trajectory` 20 轮 458 步都在。根因链：这一屏只读 `session.projections` 一个包，而重读时机
  只有 `notification` / `openSession` / `connectLanding` / `appResume` —— 一轮跑二十分钟时
  `turn/end` 一次都不来，旧包（或缺键的包）换不掉；空态又把"包里没这个键"说成"连接器没注册投影"。
  修法：**进入轨迹页签本身是触发点**（`HostStateTrigger.viewFocus` → `AppModel.focusView(sid)`），
  空态分三档（包没到 / 缺键 / 没轮次），只有"包没到"给「重读」。app **1686** 项、
  `verify-platform-boundary` 712；真机装新包后进轨迹页正常（步数从 110 走到 119，说明真的重读了）。
  笔记 `implemented/2026-11-04-trajectory-view-refetch.md`，现状 `subsystems/trajectory-page.md`
  §2.1/§2.2/§8。**仍欠**：连接器不区分 DSH 信封的 `kind`（迁移态下会把缓存提示当精确快照），
  要动契约 §5.7，未改。

- **配对不再依赖中转（11-03 第六批，0.1.15）**：二维码载荷加 `lan`（`describeEndpoints` 的 direct 组，
  默认路由排第一）；监听面把升级请求 URL 交给 `accept`，`?pair=<offerId>&cand=<候选>` 命中就按配对候选
  建连接（放行仍只由 `pairing.allows` 判）；出码先试登记，失败时**有 `lan` 就降级出码**、没有才拒绝；
  手机端先拨 `lan`（同网段优先）、全不通才回落换票，配对成功后把 `lan` 种成 direct 端点。
  名册上报失败不再算配对失败（纯局域网必然失败，名册在下次连中转时重放）。顺手修掉接受路径的
  定时器泄漏（不自愈的连接断开后没停两个周期任务）。connector **844** / app **1684**；protocol 454/26/49 不变。
  **隔离实例实测**：probe profile 零配置、无令牌（relay 未运行）→ `POST /api/dsh-mobile/pair` 200 + SVG，
  jsQR 解出 `lan: ["ws://192.168.110.79:18790", …]`，node 替身拨 `?pair=` 拿到设备令牌，再用已配对身份
  直连跑通 `repo.info`；**App 自己的 Dart 代码**（真 `WebSocketTransport`、HTTP 缝做成"一调就抛"）
  同样拨 `?pair=` 配对成功、零 HTTP。端口是 18790 而非 8790：日常那台 DSH 占着 8790，
  验完已把 profile 恢复成 `[]`。笔记 `implemented/2026-11-03-pairing-without-relay.md`。
  **未做**：安卓真机上的新配对（用户选择用接口验；App 没有"再加一台电脑"的入口，
  进配对页只能走「重新配对」）。

- **装完插件面板 404 的真正原因（11-03）**：不是热重载、不是令牌，是 **profile 里根本没有连接器的
  config 段** —— DSH 装插件只写 `dsh.profile.bundles`，不写 `cordis.patch.yml`；`relayUrl` 没有
  schema 默认值 → `validate-config` 抛 → mount 回滚 → `mountAdminFace` 一步没跑 →
  `/api/dsh-mobile/*` 全落共享通道兜底 `not found`（界面能开、接口全 404）。
  探针实测：缺 `relayUrl` 时注册的管理面路由 **0 条**。
  修法：缺 `relayUrl` 降级成"只让中转通道起不来"（`transport/startup.ts` 第三种缺席 +
  `relayConfigured`），原因进 `relayError` →「连接」卡 `detail`。connector **831** 项。
  本机 desktop profile 已补 config（`relayUrl: wss://dsh.0t0.me/ws/connector`）并把插件从
  **0.1.6 升到 0.1.11**（lockfile 原先钉死 0.1.6，npm 上 0.1.7/0.1.8 从未发布）。
  笔记 `implemented/2026-11-03-admin-face-must-not-need-config.md`。
  **遗留**：坏地址仍会让整次 mount 失败 → 面板照样 404（同一类，另开一篇）。直连端口被占
  已在 11-03 第五批改成只留声。

- **开箱即用 + 失败说人话（11-03 第二批）**：`relayUrl` 的 schema 默认值 = 内置中转
  （`BUILTIN_RELAY_URL`，面板里可换；显式空串仍算"没配"）；控制面升级被拒时从 `ws` 的
  `unexpected-response` 拿状态码 → `describeUpgradeFailure` 翻成 401/403/404 三句能照做的话 →
  「连接」卡 `detail`，**连上那一刻才清**（重连期间保留上次原因，不再只有「重连中」）；
  出码失败由路由 `try/catch` 归一成**带正文**的 400（以前空正文，面板只剩 `HTTP 400`）。
  真机现场：令牌是旧中转签的，用真令牌打升级请求回 **HTTP 401**。connector 831 / relay 161。
  中转管理台的「我的电脑 / 添加我的电脑」在**令牌模式**下指向登录页并写明原因
  （没有账号 cookie 时 `/console` 会静默 302 到 `/login`）。
  笔记 `implemented/2026-11-03-builtin-relay-is-the-default.md`。

- **管理台自己发令牌 + 连续失败锁定（11-03 第三批）**：`POST /admin/api/tokens/issue`
  （面板令牌页「添加我的电脑」，id 预填 `local`）—— 明文只在应答里出现一次，配置只落摘要，
  审计只记 id；同 id 已有活跃令牌回 **409**。连续失败锁定 `relay/src/lockout.ts`：
  **连错 5 次锁 15 分钟**，管理面认证失败与登录页失败**共用一份计数**，锁定期内连正确凭据
  也不放行，成功一次清零，到期自动放行；`lockout.failures: 0` 关闭。按客户端地址算
  （`clientIpOf` + `auth.trustProxy`，反代后面不配会把所有人并成一个桶）。
  笔记 `implemented/2026-11-03-admin-lockout-and-token-issue.md`。

- **网页反馈只有一个组件（11-03 第四批）**：`relay/src/ui/kit.ts` —— Toast + 页内弹框
  （`askConfirm` / `askValue` / `open`），遮罩与 Esc 都算取消并**兑现 Promise**。
  管理台 22 处 `alert/confirm/prompt` 全换掉，`post(path, body, okText)` 成功后默认
  toast「已保存」（断开/吊销/重置/签发各传准文案）—— 之前保存成功是**静默**的。
  控制台保留四个同名包装，实现搬到 Kit。`tests/ui-kit.test.ts` 机械拦"再写原生对话框"。
  笔记 `implemented/2026-11-03-web-feedback-kit.md`。

- **0.1.12 的"装完即用"只兑现一半（11-03 13:10 真机，0.1.13 修）**：`relayUrl` 是
  `.volatile()` 字段，schema 的 `.default()` 只作用于 `Config({})` 这种**构造**，
  loader 交给 `apply()` 的那份 config 在"profile 没有这一格"时给的是**空** ——
  面板能开，但点通道「启动」报「中转地址解析失败：」（冒号后什么都没有）。
  修法：兜底搬到读取处 `config.ts` 的 `relayUrlOrDefault()`，拨号/出码/登记/重建/面板投影
  全走它；"未配置"这一档从 `validate-config` 与 `transport/startup.ts` 删除（不可达）；
  空地址报错改成能照做的一句。**教训：默认值要写在会被读到的那一层。**

- **局域网直连默认就开（11-03 第五批，0.1.14）**：`listenPort` 默认 **8790**、`listenHost`
  默认 **0.0.0.0**，没配时由 `listenPortOrDefault()` / `listenHostOrDefault()` 在**读取处**兜底。
  显式 `0` 仍是"关"（卡片「停用直连」写的就是它）。端口被占不再拖垮挂载：`startDirect`
  失败只留声（`onDirectTolerated` → `directError` →「连接」卡 detail）。推翻了
  `listener-config.test.ts` 原来那条"默认敞开不可接受"。
  **隔离实例实测（真进程、零配置）**：`0.0.0.0:8790` 在监听、`caps.direct = true`、
  `direct.running = true`、`detail: "0.0.0.0:8790"`。
  笔记 `implemented/2026-11-03-lan-listener-on-by-default.md`。

- **中转账号模式（11-02）**：`auth` 段开启后 `connectorAuth` 必须 `required`，匿名兑换关闭；
  邮箱注册（默认只限 `qq.com`，6 位码 / 10 分钟 / scrypt）、会话 cookie + CSRF、控制台建电脑、
  首次 `?id=` 绑定 `connectorId`；默认 **2 台电脑 / 5 GiB 月额度**，管理员可在 `/admin` 用户区改；
  管理台「用量」面板给出账号数 / 总用量 / 在线电脑 / 已配对设备 KPI，以及按已用降序的用户表（含零用量）、未归属主体单表；
  管理台自己不签发令牌，顶栏「我的电脑」和令牌页「添加我的电脑」都指向 `/console`（管理员与普通用户同一套添加电脑流程）。
  管理台「设置」可直接改默认电脑数、新账号默认月额度、SMTP 与注册开关/邮箱域名：先写回配置，再改运行时策略，不用重启；密码留空 = 不改。
  用户端与管理台视觉统一为纸张底色 + 衬线标题 + 细线分隔 + 朱红强调，亮/暗跟随系统。
  电脑侧「连接」卡令牌行加了「去注册 / 登录」外链（按 `relayUrl` 推导 `/login`，插件 0.1.11）；
  空 `relayTokenRef` 时面板按默认格 `relay-connector` 读写，不再拒绝贴令牌。
  账号库 SQLite `relay/data/relay.db`（挂目录，WAL）；SMTP 走 AhaSend `send.ahasend.com:587`，
  发件人 `noreply@0t0.me`（AhaSend 已校验域名），`--check-smtp` 自检、`--promote` 提管理员。
  浏览器实测：登录 → 控制台 → 添加电脑（令牌只显示一次）→ `/admin` 设置/令牌/用户/用量视图。relay **152** 条全绿；
  文档 `docs/subsystems/relay-accounts.md`，笔记
  `implemented/2026-11-02-relay-accounts-and-connector-binding.md`、
  `implemented/2026-11-02-connection-card-opens-relay-console.md`、
  `implemented/2026-11-02-connection-card-default-token-ref.md`、
  `implemented/2026-11-02-relay-editorial-ui-and-admin-settings.md`。

- **CI 修好 + README 重写（11-02）**：CI 从 10-31 起一直红，**原因与功能无关**——
  `app` job 第一步 `dart format --set-exit-if-changed` 有 20 个文件没格式化（上一批改动留下的），
  后面 analyze/test 根本没跑。补齐 format 后又冒出 3 条 `curly_braces`（超宽单行 `if` 被
  折成无括号两行）：`core/snapshot_call.dart`、`data/app_model.dart`、`wire/rpc/endpoint.dart`
  各补花括号。README 换成新版面板截图与真实项数（connector 818 / relay 139 / app 1659）。
  坑点写进 `tools.md` 的 format→analyze 那条。
- **插件页能删了 + 设置页去小字（11-01，真机反馈）**：用户原话「只能禁用、停用，
  没有删除？人家用户自己的东西，你凭啥不让人家删除」。① 卸载按钮**不再按 `removable`
  隐藏**（判定在宿主 `removeBundle`，被拒时显示 `not-removable` 原话）；② 插件页
  **按包分组**，归属用连接器新过线的 `BundleInfo.rows[].entryId`（金样随之重生成）；
  ③ 启停 / 卸载的结论改成**屏幕中央**浮层（`ui/dsh_center_notice.dart`），进度卡钉顶部；
  ④ 中转是**选**的（内置 `wss://dsh.0t0.me` / 自定义，`--dart-define=BUILTIN_RELAY` 可换）；
  ⑤ 设置页与连接 sheet 里重复标题的小字删掉（分组标题已经说了）。
  ⑥ **中转地址一律存根地址**（`canonicalEndpoint`）：二维码带的是电脑侧的
  `wss://host/ws/connector`（连接器自己拼那条路径），与根地址是同一台中转 ——
  不折叠就是表里两条、竞速互踢（`relay/src/server.ts` 的 `replaced`）。
  笔记 `implemented/2026-11-01-plugin-page-owns-the-delete.md`、
  `implemented/2026-11-01-builtin-relay-is-a-choice.md`、
  `implemented/2026-11-01-relay-url-is-a-root.md`。
- **「没变就别再搬」第 3 批（11-01，摘要 + 恢复语义 + 记账补齐）**：
  ① **出站账现在是恒等式** —— 记账点搬到连接层唯一出帧点（`emit`），
  `Σ connector.bytes.out_frame.* === connector.bytes.outbound`
  （`tests/out-frame-bytes.test.ts` 直接断言差额为 0）。真机一次"什么都没变的回前台"
  **230 920 B**：`ev` **147 037**（63.7%）/ `res` 76 638（33.2%）/ `credit` 6 859（3.0%）/
  `hello-ack` 386。**规划稿里"未计量 30% = status/job/host/presence/pong"实测不存在（0）**
  —— 那 30% 是封箱后 base64 + 帧头（口径差），账本齐了才看出来。
  ② **重连不再整窗重放**：手机以前恒报 `since = 0`（`openSession` 的默认值，
  `ItemStore.cursorOf` 零调用点），连接器只好把宿主窗口逐条重发。现在水位唯一 owner 是
  连接层的 `DeviceSession.sinceOf`（落盘水位），`sync.hello` / `subscribe` 现取，
  连接器**只在缓冲能证明覆盖时才跳段**，覆盖不到退回整窗（方向：多发可以、少发不行）。
  ③ **快照带内容摘要**（契约 §5.7.1）：十个只读方法请求可带 `digest`，命中回
  `{notModified:true}`（每个 41 B）；手机按 `(方法, 参数)` 存"上次成功应用那一包"的摘要，
  `notModified` 时不清数据/不报错/不通知；不带 `digest` 的老客户端逐字不变。
  **真机改后（连续两轮一致）：总出站 230 920 → 3 250 B（−98.6%）**，其中
  `ev` 147 037 → **0**、`res` 76 638 → 2 006、快照明文 56 536 → 410（10 × 41）。
  内容真变的对照：`session.projections` 回正文 1 114 B 并被应用（标题在那一包里），
  `session.list` 仍 41 B（那一页字节确实没变），合计 2 030 B（改前同一条探针 47 507 B）。
  冷启动第一次落地仍是整窗 `ev`（内存里没有内容，必须重放）—— 这是如实的代价。
  **接不上时怎么办（补洞）**：重连后的第一条 `ev` 若远在本地水位之上（电脑侧重启过、
  只能给最近窗口），就用现成的 `session.page(beforeSeq: 第一条的 seq)` 往回翻到水位，
  把中间那段补上；**补不到就什么都不做**（不清内容，下次再试）。水位由"连续收到"封顶，
  不越过没到的内容。判据与做法见 `remote-channel.md` §5.4 规则 5。
  **冷启动也接上了（11-01）**：打开会话先 `itemsOf(sid)` 读回条目 → 界面立刻有内容 →
  `since` 取**条目自己的 `seq` 上界**（不取 `cursors.last_seq`：计数器在"事件因空洞
  没入库却照样落盘"时会超前）；一条条目都没有就不认水位。本地条目**按电脑身份分区**
  （`meta` 的 `local_items.host` vs `pcSignPubHex`，换电脑清库）。真机：冷启动
  **219 965 → 71 739 B（−67.4%）**，其中 `ev` **147 039 → 0**（两轮一致）；
  剩下的 70 KB 全是进程首次拉起时的快照正文（摘要表是每进程的）。笔记
  `implemented/2026-11-01-cold-start-restore-from-local-store.md`。
  笔记 `implemented/2026-11-01-never-pull-unchanged.md` 与
  `implemented/2026-11-01-resume-from-persisted-watermark.md`。
- **会话列表分页（11-01）**：`session.list` 请求 `{limit?, offset?}`、应答加 `hasMore`
  （不传 = 整表，老客户端不变）；手机一页 **50** 行，首屏只要一页，**刷新问"已加载窗口"**
  （翻过的页不被打回），加载更多从 `offset = 已加载行数` 接着要、按 `sid` 去重；
  滚到快底**自动**要下一页（`ui/load_more_on_scroll.dart`，几何判据复用
  `load_older_trigger.dart`；只认 `ScrollUpdateNotification`，否则 `ListView` 预构建会把
  后面几页一次吞掉），末尾那行保留作可见说明。**四个"假设整表"的洞已补**
  （`pruneSessions` 曾在分页后删窗口外会话的草稿 —— 现在只在整表时剪；落点 / 抽屉搜索 /
  归档与子智能体面板走 `ensureFullSessionRows()`，代价是那之后窗口变成整表）。
  真机（新 APK）：一次标题变更 **252 000 → 47 507 B**
  （其中 `session.list` **250 122 → 45 630**，50 行），相对最初 1 943 515 B 是 **-97.6%**；
  首屏 landing ~2.1 MB → **918 263 B**。笔记 `implemented/2026-11-01-session-list-paging.md`。
- **列表行只搬手机读的五个投影键（11-01）**：`session.list` 的每行原本带宿主整块
  projection summary（本机 94.5% 的包体，`turnOutline` 645 KB + `trajectory` 353 KB
  两项就 1 MB），而手机 `readSessionSummary` 只读 `title` / `modelSelection` /
  `subagentTiming` / `tokenUsage` / `subagentCatalog`。白名单在
  `connector/src/protocol/session-row.ts`，与 Dart 解析器由
  `tests/session-row-payload.test.ts` **逐字比对**（变异校验 2 红 / 3 红）。
  真机：一次标题变更出站 **1 943 515 → 252 000 B（-87%）**，通知与重取帧数不变。
  **不做 `session.row`**：裁键已拿 87%，窄口只剩行本体那 3%（77 KB），不值得为它引入
  行级合并语义。笔记 `implemented/2026-11-01-list-row-payload.md`。
- **重取范围第 2 批（11-01，连接器侧）**：`session.modelCatalog` 接**四条**宿主失效事件
  （`llm/adapters-updated`、`settings/document-updated`、`credentials/*-updated`），
  `permission.catalog` 接 `permission-presets/catalog-changed`；宿主级、不带 `sid`、
  不筛发起者，**只改连接器一处**。事件类型靠 devDependency 带入（改名 = 编译错误）。
  `settings/document-updated` 一条事件两个 key。真机：改默认模型后**通知 +107 ms /
  手机重取帧 +141 ms**（旧构建同一条写入 0 通知 0 帧）；一次标题变更出站 **1 943 515 B**
  （整表 1 941 638 B）。**`llm/models-updated` 没接**：DSH 源码有、出厂 `0.2.1-rc.5`
  的 `app.asar` 里 0 处（死代码）。**权限预设目录未验**（宿主 195 插件里没有
  `dsh-auto-review`）。笔记 `…/2026-11-01-…` 文末。
- **重取范围按触发源拆（11-01，第 1 批落地）**：`refreshSessions()` 从产品路径消失 ——
  拆成 `refreshSessionRows()`（只做行）与 `refreshHostCatalogs()`（模型 / 权限 / 预设 /
  `repo.info`）；登记表长到 **9 个 key**（`app/lib/data/host_state.dart`），多一列
  `ownWrite`（切模型 / 分支 / 页面重试立即重取，不压 150 ms 窗口）。
  **一条通知只花它那一个往返**：切模型 8 → **2**（真机入站帧 **19 → 7**；通知 → 手机
  首个重取帧 **+63 ms ~ +186 ms**）。首屏是**一次并行批次**（九项同时发起、只 `await` 行、
  目录失败不拦落点）：实测 17 个入站帧在 `session.list` 的 **1.9 MB 响应到达前 327 ms**
  全部发出（串行时不可能）。**一批只通知一次**（`AppModel.notifyListeners` 上的闸，
  首屏整棵树重建 6+ 次 → 1 次）。新增纯观测指标 `connector.bytes.outbound`：
  **一次切模型出站 1.94 MB**，几乎全是 `session.list` 整包（本机 349 行）——
  这是"要不要窄口只取一行"的判据（第 2 批已量：改一次标题同量级）。
  笔记 `implemented/2026-11-01-refetch-scope-by-trigger.md`；现状 `remote-channel.md` §5.9 +
  `app-channel-client.md` §2.3 + `connect-landing.md` §2。
- **宿主状态同步（10-31，P1/P3 落地）**：新增 `host` 帧（契约 §5.9）—— 电脑侧改了
  模型 / 权限档 / 标题 / 设置 / 任务表时，推一条**只有 key 的提示**（不进业务 `seq`、
  不带值），手机按 key 重取快照（同 key 150 ms 合并、断连不排队、未知 key 计数）。
  **触发点全听宿主事件**（`model/selection` / `permission/preset` / `session/title` /
  `settings/document-updated` / `jobs.events`）—— 这是"Web 改的也能跟上"的唯一来源；
  原稿"跳过发起者"的规则随之作废。P3：流式文本改成 `ValueListenable`，纯流式 delta
  不再整页通知（流式期间页面重建 **0** 次，计数桩钉住）。中转窗口落盘（P2）**没做**。
  笔记 `implemented/2026-10-31-host-state-sync.md`；现状 `remote-channel.md` §5.9 +
  `app-channel-client.md` §2.3。真机：Web 改模型 / 权限 → 手机 **+71 / +99 ms** 上屏；
  断开期间改、重连后仍是最新值。
- **顺带修掉的一条陈旧门禁（10-31）**：`connector/tests/relay-transport-seam.test.ts` 还在断言
  "没有 tokens 就退出 2"，而 `connectorAuth` 默认 `open` 之后空摘要表是**合法起点** ——
  这条用例于是永远等一个不会来的退出码，整份 `pnpm test` 卡死。改成断言
  "`required` 且无 tokens 才失败"，并补一条钉住开放模式的空表能起来。
- **外观：壁纸 + 透明度（10-31）**：设置页「通用」加两行（背景 / 透明度 0–100%）；
  壁纸存 App 私有目录（`files/appearance/wallpaper.img`，路径靠 `getDatabasesPath()` 推，
  不引 `path_provider`）；色板经 `DshColorTokens.withSurfaceAlpha` 派生一份、**只降 10 个表面色**；
  **不设下限、图上不叠遮罩**（`100%` 就是只剩壁纸；第一版的下限 55% 与遮罩被用户当场退回，
  理由是"用户怎么搞是用户的事"）；毛玻璃只贴输入栏一条。**这是 DSH 没有的
  手机侧扩展**（它那点通透来自 macOS 窗口材质）。笔记
  `implemented/2026-10-31-wallpaper-and-surface-alpha.md`，现状见
  `docs/subsystems/appearance-wallpaper.md`。同批修掉**启动即崩**：`namespace` 改过而
  Kotlin 源码包名没跟上（`ClassNotFoundException: ...MainActivity`），源码迁到
  `io/github/imzlzl/dsh_mobile/`，笔记 `implemented/2026-10-31-android-namespace-activity-mismatch.md`。
- **中转上域名 + TLS（10-31）**：`dsh.0t0.me`（华为云 ECS）→ Caddy 终结 TLS、反代 `relay:8787`；
  证书走 **acme.sh + ZeroSSL http-01**（国内机器出站到 Let's Encrypt 超时、ZeroSSL 不支持
  tls-alpn，所以 80 必须放行）；Caddy 镜像从**华为云 SWR 加速**拉（Docker Hub 与 DaoCloud 都超时）；
  relay 端口已收口成 `127.0.0.1:8787`，公网只留 80/443。连接器 `relayUrl` =
  `wss://dsh.0t0.me/ws/connector`。流程写进 `docs/cookbook/relay-on-a-server.md` §4，
  取舍见 `implemented/2026-10-31-relay-tls-zerossl.md`。
- **多机四步全部落地**（方案 `proposed/2026-10-29-one-phone-many-computers.md`）：
  ① 归属（`Endpoints.id = hostId|url` / `host.<hostId>.*` / `repo.info.hostName`，120ea3a）；
  ② 凭据分槽（`dsh.pairing.<hostId>.*` + `active`，cb2bd1d）；
  ③ 拨号竞速 + 缓冲按"在服务的设备"裁剪（ba9e438）；
  ④ 独占与切换：`device/busy` 四处门禁同批（错误码 35→36）、占用位 = `presence.serving()`、
  握手 `acceptHello` 准入（同一 devId 放行）、拒绝理由带占用者（`协议码 说明`，≤120 字节）、
  控制面 `?id=` 必带自报、面板「在服务」+「接管」（eb9696e）；手机侧「切换电脑」= 换槽 +
  重新装配 + 「切回上一台」、被占用停机（`busy-wait`）、15s 总预算、2s/8s 提示、结论后
  60s±20% 静默慢重试（e2a2499）；过期的一轮拨号不许动连接（真机 `backoff→handshake`，129b1a0）。
  笔记 `implemented/2026-10-30-*`（六篇）。
- **真机验收（10-30）**：`serving` 随连接出现/断开（关 App 后 **873ms** 释放），两条路径都能进；
  面板那一行是 `运行中 · 前台 · 在服务` 且只有它有「接管」；`?id=` 实测 OPEN / 403 / 不带也 403。
- **第二台设备 = 逐跳静态审查**（没有第二台真机）：出票 → 中转开通道 → 拨数据面 →
  `hello` → `peerOf` → `occupantOf` → 4003 → 中转转发 → `busy-wait` → 界面，逐跳核对后
  抓到并修掉**两个真漏洞**：① 中转把 4003 吞成 4000（门槛 4 走中转必失效）；② 停用只标
  `revokedAt` 而不收连接。另收紧两处竞态（迟到 `offline` 不删新记录、准入判"任何别的在线
  设备"）。**旧数据/旧客户端兼容全删** —— 协议未发版；笔记 `2026-10-30-drop-legacy-compat.md`。
  仍**证明不了**两台"同时"握手那一瞬（要"在途占位"维度）。**停用**此前没有生产者
  （名册过滤 + 解析丢字段），现已补上；**删除=先停用再清理**（活跃行拒删）——
  `2026-10-30-revoke-then-purge.md`。
- **中转可观测/限额/面板（10-30，四批）**：摘要表可变（吊销即生效 + 接受前重验）；按人流量额度
  （**默认不限制**、计量常开，上限由管理员在面板设：UTC 周期惰性结算、`cut`/`block`/`off`、
  默认内存态、`persist` 才落盘、配对通道不计量）；
  日志一行一个 JSON 事件（固定事件名，不记帧/令牌）；`/admin` 是独立控制台（同端口、Bearer、
  分区导航 + 近 60 分钟真曲线；设上限/重置/断开/吊销·删除；页面免令牌）。笔记 `relay-*`（五篇）。
- **工程化（10-30）**：仓库已**公开**；README（logo + Linux.do 徽章 + 门禁表）；`ci.yml` 四 job +
  每次 push 出 **debug APK 产物**；`release.yml`（v* 出 tgz + APK）；`publish-connector.yml`
  （connector-v* → npm **OIDC**，可信发布已 Valid，**0.1.2 带 provenance**，无需 token）；
  **签名已配置**（四个 Secrets 已写，`app/tools/android-signing.ps1` 生成；v0.1.1 实测
  正式签名：`CN=dsh-mobile`，SHA-256 `C0:A5:52:25…:AC:DB`）；步骤见 `docs/cookbook/release.md`；
  applicationId = `io.github.imzlzl.dsh_mobile`（发版后不可改）。
- **面板 / 装配 / 端点 / 明文（10-29）**：「连接」卡只碰白名单三格 + 令牌三态（值永不过线）；
  `start-transport` 放过两种允许的缺席（缺令牌 / `listenPort = 0`）；装配层三处判据搬出
  `index.ts`；`Endpoint.hostId` = 电脑公钥（不用 `pcId`，会撞），`dialOrder` 带失败冷却；
  明文 `ws://` 非公网放行、公网只认用户确认。笔记 `implemented/2026-10-29-*`（六篇）。
- **通道全景**：`protocol/` + `relay/`（中转）+ `connector/`（电脑侧网关）全部落地；手机侧
  `app/lib/core/` 是连接层，`app/lib/wire/` 是**线上形状的唯一解码层**（`wire/rpc/` 18 个面、
  46 个方法；`wire/` 外零 `call<`；方法面 52/50，差额 2 = `credentials.set`/`unset`）。
- **UI**：各页全部接真数据，真机验收到 10-28。**唤醒判据**已照 DSH 的 `idleSteer` 修好：
  子智能体的 `agent-message` / `subagent-settled` 走 `next-step` 也算唤醒
  （`implemented/2026-10-28-turn-trigger-idle-steer.md`，现状 `turn-groups.md` §6.1）。
- **未验**：图片上限四条、`readBytes` 预览、插件安装/卸载的真实 pnpm 流程；桌面四件事的真机
  验收（分支已通过；改动卡/差异/提及要一轮**当前宿主进程里**跑完的对话，记录是内存态）。
  `caps.changes` 真机 **true**；计划审查卡**有意不接**；中转面板只在本机浏览器验过。

## 下一步

0. **数据面收敛（"没变就别再搬"三批已全部落地）**：触发源按来源拆、行只带手机读的五个
   投影键、列表分页（50 行 + `hasMore`）、**重连带落盘水位（不再整窗重放）**、
   **十个只读快照带 `digest`**、出站账补齐到恒等式。connector **816** / app **1649**。
   留给以后的：① **`permission.catalog` 与 `repo.info` 还在 `connectLanding`** —— 它们只在
   权限 sheet / 文件页被读，按这条不变量该改成"首见时无条件拉"（摘要已把代价压到几十字节，
   所以这条的优先级下降）；② `session.projections` 仍是 20+ 键一整包（每会话只拉一次，
   判据同上）；③ 权限预设目录那条真机验收（要装 `dsh-auto-review` 并重启一次宿主，本机没有）；
   ④ **摘要表是每进程的**：冷启动第一次落地仍要拿十份快照正文（约 70 KB）。
   要再省就得把摘要持久化（键是 `(方法, 参数)` + 那一包的摘要），属于"缓存自证"那一档的
   下一步 —— 先看这条值不值得（它只影响冷启动一次）。
1. **多机第 4 步的真机复验**：只剩两条要**两台设备**才能做的（第二台被
   `device/busy` 拒并说出占用者、切回上一台的真实链路）—— 单测已覆盖，
   真机可用"第二个 DSH_HOME + 另一份连接器身份"补；命中不了的按未验证如实说。
2. **状态语义对齐（A–H 已全落地）**：现状 `docs/subsystems/ui-state.md`；真机复验还差 4 条
   （子智能体在跑可见、提问草稿、发送模式真值、断连重连）。因果见 `implemented/2026-10-27-*`。
3. 跑一轮真机复验改动卡 / 差异 / 提及（要模型请求 —— 先报价再跑）。
4. `usage.summary` 的 byDay 时区；`plugin.installStatus` 的 4 键/8 键两形态
   （真出现第二种时 `readPluginJob` 会红，属**已知的下一处**）。
5. 大改后巡检一次 `docs/` 与代码的漂移。**已知一处**：`connector/src/dsh/interaction-client.ts:63`
   import 了 `transport/backoff.js`，而 `connector-and-relay.md` §1.2 写着「`dsh/` 不 import `transport/`」；
   两者选一个改（补机械规则会立刻红，改文档则承认这条方向可用）。
6. **投影包按消费者拆**（方案已记录，未实现）：一次 `session.projections` **80.6 KB**，其中
   `trajectory` **72.2 KB（89.6%）**、`turnOutline` 3.7 KB、其余 27 键 4.7 KB —— 而聊天页每轮
   只需要轮级用时（turns-only 3.3 KB）。W1 拆键 + 可选 `keys` → 每轮 **8 KB（−90%）**；
   W2 步级带 `sinceTurn` 游标 → 进页面 76 → ~14 KB。笔记
   `proposed/2026-11-04-projection-payload-split.md`（含被否的五条）。

## 门禁（改代码后必须全绿，项数以 `tools.md` 为准）

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | 454 / 26 / 49 项 |
| `node app/tools/verify-platform-boundary.mjs` | 694 项（25 条规则自检 + 160 个 Dart 文件） |
| `node app/tools/verify-rpc-single-caller.mjs` | `app/lib`（`wire/` 外）零 `call<` |
| `node mock/proto/tools/verify-{icons.cjs,tool-paths.mjs}` | 图标集 / 24 个工具脚本无硬编码盘符 |
| `cd app && flutter test` | 1649 项（约 1 分钟） |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format` | 各 0 |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + **831** 项 |
| `cd relay && pnpm typecheck && node --test` | 类型 + **161** 条 |

**改断言必须做一次变异校验**（故意破坏不变量，确认恰好那几条红，条数写进提交）。

## 九条教训

1. **投影信封**：`session.projections` 回 `{kind, asOfSeq, values}`，手机要 `values`。
2. **模型目录是对象**（`{default, routableProviders, groups, failures}`）不是数组。
3. `session/select-model` **没有"不能写"约束**：别把测试纪律升成产品约束。
4. **"空"有两种表达**：`items.isEmpty` 漏了 `OtherItem`；`usage == null` 漏了"字段齐全但全零"。
5. **判据要能区分"没命中"与"没实现"**：先一行 `debugPrint` 确认回调跑了，再怀疑手势。
6. **一个功能一次提交完整**：提交前 `git status --porcelain` 必须只剩有意的文件。
7. **生产路径上的假数据最容易漏**（不报错、不空屏，只是名字/数字是编的）。
8. **线上预算按帧算**：二进制 `N` → JSON base64 → box 再 base64url ≈ `1.78N`。
9. **用例喂的形状必须是线上形状**：真机事件/真库行先 dump 再写断言；字段类型只在 `wire/` 断言。

## 真机联调的成本纪律

- 隔离实例：`$env:DSH_HOME='D:\tmp\dsh-mobile-home'` + `dsh --profile dsh-mobile-test`；`--profile` 只隔
  进程/插件/端口，`~/.dsh/{.credentials.yaml,sessions,storages}` 共用 —— **跑之前报轮次并拿到准**（花用户的钱）。
- 装 App 一律 `flutter build apk --debug` + `adb install -r`（`flutter install` 会先卸载）。

## 仍未注意就会翻车

- **改源码只用编辑工具**（shell 替换静默出错）；**`dart format` 会重排文件**，之后再编辑要重读。
- **同一件事只有一处判据**（重建哪条通道 / 起传输容忍什么 / 面板读什么）：都已有同名模块 + 回归用例
  （`transport/rebuild.ts`、`transport/startup.ts`、`connection-card.ts`），别在 `index.ts` 再写；坑点见 `tools.md`。
## 已知缺口（仍在）

- 计划审查卡手机上不存在（**有意**，契约 §15）；保存「连接」卡后只轮询 6 秒判是否连上，
  慢网会停在"重连中"；「清空全部记录」会把还在用的离线设备一起删掉，被删那几台只会
  重试到重新配对（确认框里写明）；上述"未验"各项仍在。
- **重启后工具行显示成"工具"**（11-04 发现，未修）：本地库每个 itemId 只存一条 payload，
  `tool/result` 覆盖 `tool/call`，而结果事件不带工具名（真机 DB：**200 条 `tool/result`、
  0 条 `tool/call`**）—— 冷启动后历史行只剩兜底名（`data/projection.dart:317` 的
  `kUnknownToolName`）。实时那一份对，因为名字来自内存里合并过的 call。
## 已落地索引

- 2026-09-30 通道协议定稿 / 配对 v1 / 连接层拆分 — `implemented/2026-09-30-*`、`2026-10-01-*`
- 2026-10-02 安卓里程碑 / 主题层 / 图标 / 本地库 / 配对 — `implemented/2026-10-02-*`
- 2026-10-07..09 配对 v2、设备身份、三处线上形状错 — `implemented/2026-10-0[789]-*`
- 2026-10-13..17 交互链、审批/提问、发送模式、端点切换、标题、设置页 — `implemented/2026-10-1[3-7]-*`
- 2026-10-19..24 渲染对齐、轨迹/轮组、用量、文件页、插件、任务、通知 — `implemented/2026-10-19-*`..`24-*`
- 2026-10-25 RPC 应答面收口（8 批） — `implemented/2026-10-25-wire-*`
- 2026-10-26 评审六批 + 真实清单进金样 + 桌面四件事 + 连通落点 — `implemented/2026-10-26-*`
- 2026-10-27 UI 状态语义（审计 → 机制 → A–H 批） — `implemented/2026-10-27-*`；现状 `docs/subsystems/ui-state.md`
- 2026-10-28 渲染批次 + 唤醒判据修正 — `implemented/2026-10-28-*`
- 2026-10-29 连接卡 / 无令牌可挂载 / 装配层回归网 / 删掉空转的 `deviceLimit` / 端点剪枝 /
  明文两档 / 高亮语言集 — `implemented/2026-10-29-*`（六篇）
- 2026-10-30 多机四步（归属/凭据分槽/拨号竞速/独占与切换）+ 中转可观测·限额·面板 — `implemented/2026-10-30-*`（九篇；方案页留在 `proposed/`）
- 2026-11-04 轨迹页进入即重读（`viewFocus`）+ 空态三态 — `implemented/2026-11-04-trajectory-view-refetch.md`；现状 `subsystems/trajectory-page.md` §2.1/§2.2/§8
