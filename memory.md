# dsh-mobile 项目状态

> 快照 + 最近窗口，**覆盖更新**，不做流水追加。历史在 git 与 `.agents/notes/`；
> 11-04 及更早的条目在 `memory/archive/2026-11.md`；稳定命令与坑点在 `tools.md`；
> 现状事实在 `docs/`。

## 现在（2026-11-14）

- **DSH 0.2.2-rc.3 体检：不用改代码，也没抬线**。本机宿主已在 **2026-11-13 15:30** 自己升到
  **rc.3**（`app.asar` 的 `LastWriteTime`），而连接器 22:06 还在写落盘点 ⇒ 它**已经在 rc.3 上真跑过**。
  形态因此与上一轮相反：**类型基线（rc.1）比跑着的宿主旧**。
  体检结论：`caps.ts` 的 **21 个服务键**、16 个服务的方法、6 组事件形状、`session.projections`
  的键集合（rc.1→rc.3 **49 → 51，只增 `conversationContinuation` / `worktree`，零删除**）
  全部在 rc.3 上原样存在；rc.2→rc.3 只有 **6 个提交**，`packages/` 下 374 个 `package.json`
  有差异、其中 373 个只改版本号（余 1 个是全新包），非清单文件只动了 90 个。
  **不抬线的理由**：`tests/manifest-compat.test.ts` 强制 `engines.dsh` 下界 == 钉住的版本，
  所以“抬 devDeps”必然连带放弃 rc.1/rc.2 宿主；而体检恰好证明那一段是真能用的。
  笔记 `implemented/2026-11-14-dsh-022-rc3-audit.md`。
- **Agent Teams 接入（任务板 + 开关）**：任务板是右抽屉第四枚「任务板」，数据就是已在读的
  `session.projections` 里的 `agentTeam`（**读路径零新增方法**）；开关照 DSH 放在
  **模型菜单**末尾（`ui/team_mode_row.dart`），停用要先确认且**只在用过模型时**确认
  （`TeamModeToggle.tsx:47`），**不做乐观更新**（写成功→重读投影→再画）。
  连接器只加 `caps.team` + **一个写方法** `team.setEnabled`（**方法面 52 → 53**），
  它经 gateway 转给宿主的 `agentTeams/setEnabled({agentId, enabled})`——让宿主的 lookup
  自己决定要不要 resume，与 Web 同一条路。
  **子会话两边都不给**（tab 与开关都藏）：照抄 DSH（`TeamModeToggle.tsx:30-32`），
  且子会话那块投影本身是空板（与"根会话关着"同形）。
  宿主的三个判断手机一律不算：`ready`（DAG）、`writeScopeWarnings`、
  `ownerName ?? ownerId ?? 未分配`。
  真宿主证据：本机 rc.3 的 projcache 里 40 个样本有 13 个带 `agentTeam`（含 `enabled: true` 那份）。
  笔记 `implemented/2026-11-14-agent-team-integration.md`；契约 `docs/subsystems/agent-team.md`。
  **未做**：真机点一遍开关并看 `team/mode` 落盘。
- **本轮门禁（2026-11-14）**：app **1931** · connector **860** · boundary **933** · size 通过
  （三处预算按规矩抬了数字并写明理由：`side_pane.dart` 950 → 982、`app_model.dart` 5150 → 5204、
  `AppModel` 方法数 176 → 177；`ChatPageState` **没涨**——开关那行搬进 `team_mode_row.dart`）。
  变异校验三条，各恰好红 1 条：拆掉"子会话不给 tab"、拆掉 `ownerId` 回落、拆掉停用确认判据。
- **一条要记住的反直觉事实**：`docs/upgrade-guide/v0.2.2-rc.2/` 的 **13 条 breaking topic
  全都不在 rc.3 上** —— 那个目录只在 master，rc.2/rc.3 两个标签下最新都只到 `v0.2.2-rc.1`。
  它们是 rc.3 之后才落到 master 的下一批（6 条已实测：`./brand` 子路径、`rankByName`、
  `resolveConfig`、`authorizeIndex`、`ptc-runtime-python`、`JOB_BACKGROUND_DISABLED`
  在 master 上都没了、在 rc.3 上都还在）。**有 guide ≠ 变更已进到你用的那一版。**

## 现在（2026-11-13）

- **连接方式收成三层**：**能力**（电脑通道 `running` / `connected`）/ **策略**（手机
  `device.route_policy`：自动 / 只用直连 / 只用中转，**配对与连接共用**）/ **当前**（界面一句事实）。
  拨号过滤只有一处（`core/endpoint_policy.dart`），`dialOrder` 分桶（直连整体在前，冷却全局最后）；
  配对 `auto` 不再看 `/24`（`myIpv4` 只用于多条地址排序）。出码载荷多可选 `routes`：
  中转控制面没连上就**不登记、码里没有 relay**；面板出码卡两档（同一 WiFi / 任何网络）。
- **连接面板 11 → 6 行**：删「打开侧面板」「手动填写地址」，合并「重新连接 / 重试」；
  新「连接方式」页（策略三档 + 地址即点即连 + 添加地址）；设置页「配对时先试」改名「连接方式」；
  空态删「打开会话抽屉」。小字三原则（不可逆 / 与相邻项相反 / 动态值）见决策笔记。
- **后台任务通知默认关**：`device.notify_tasks` = off（默认）/ failures / all；
  审批、提问、整轮完成三类不给开关。
- **本轮门禁**：app **1897** · connector **856** · boundary **908** · size 通过
  （AppModel 176 方法，+1 = 通知策略 setter）· proto **34 项**（新增 4 条，做过变异校验：
  把「打开侧面板」加回去恰好那一条红）。**真机验收四条全过**（2026-11-14，隔离实例 :3099 +
  本地中继 :8787）：关中转出码→any 拒、lan 出码且手机直连；关直连出码→lan 拒、any 码里无 `lan`
  且 `routes:["relay"]`，手机自动落中转；两条都关→「两条路都没开…」；策略=只用直连 + 停直连 +
  开中转 → 手机**不回落**（证明是"不试"而非"排后"）。验收时顺带修掉一个真 bug：
  **`extra` 在监听面停着时仍上报直连地址**，二维码因此谎称局域网可用 —— 修法是
  `describeEndpoints` 里"没有监听面 ⇒ 一条直连都不报"（含 `extra`），回归用例在
  `tests/endpoints.test.ts`，connector 现 **857 项**。

## 现在（2026-11-12）

- **v0.2.16 已发版（2026-11-12）**：`versionName 0.2.16`（`versionCode` = CI run number）+ 
  **首个按 ABI 拆包**的版本（`--split-per-abi`）：`dsh-mobile-v0.2.16-arm64-v8a.apk` **28.7 MB**
  / `-armeabi-v7a` 25.0 MB / `-x86_64` 31.2 MB（上一版通用包 78.8 MB）；
  `dsh-mobile-connector-0.1.24.tgz`（202 KB，npm `latest` = **0.1.24**，OIDC + provenance）。
  三个 run 全绿（`ci` 8m12s / `release` 4m42s / `publish-connector` 30s），Release notes 待手填。
  内容 = 八笔：a11y 第四批（13 处角色 + 关掉一个真入口）· `chat_page` 第二刀（4762 → 4422，
  上限 4450）· `AppModel` 提醒簇搬去 `data/notices.dart`（5127 行 / 175 方法，上限 5150·175）·
  直连收 `wss://`（手机手填 + 电脑侧 `extra`）· 三处文档漂移收口 · DSH 0.2.2-rc.2 体检（不用改代码）·
  文档地图 + 点对点 cookbook · 否决 frp 隧道。各篇笔记见 `implemented/2026-11-12-*`。
  **体积口径修正**：`docs/cookbook/release.md` §3.5 原写 arm64 41.4 MB（那是本机
  `--target-platform android-arm64` 的一次量法）；发货的 `--split-per-abi` 产物是 28.7 MB —— 表已改。

- **DSH 0.2.2-rc.2 体检（2026-11-12）**：本机安装的宿主仍是 **0.2.2-rc.1**（= 我们的 pin），
  npm `next` 是 **rc.2**，`engines.dsh` 的 `>=0.2.2-rc.1 <0.2.3-0` 放行它；
  16 个服务键 / 20+ 个方法 / `$events` 与两条 waterfall / 10 个事件形状 / 13 个包的导出差集
  逐项核过，**没有一处被删改** ⇒ rc.2 不用改代码（也没抬类型基线：类型比运行宿主新会掩盖问题）。
  顺手修掉两条过期引用（`agent-loop/src/tool-calls.ts` 在 rc.1 时就不存在了）。
  方法与结果见 `implemented/2026-11-12-dsh-022-rc2-audit.md`。

- **文档入口 + 点对点直连（2026-11-10 晚）**：新增 `docs/README.md`（一页纸地图：按任务找文档、
  连不上时的排查顺序）与 `docs/cookbook/direct-p2p.md`（不经服务器：Tailscale 打洞 / 公网 IPv6，
  含 `tailscale ping` 证实真点对点的判据）。
  **不提供 frp 方案**：普通 `tcp` 隧道数据经 VPS 转发，与已有中转重叠；
  `xtcp` 要两端都跑 frpc，手机装不了 —— 否决理由见 `rejected/2026-11-10-no-frp-tunnel.md`。
  代码上撤掉「直连只能明文」这条自设边界：手机手填直连收 `wss://`
  （`app/lib/ui/add_endpoint_dialog.dart`），电脑侧 `extra` 收 `wss://` 任意主机
  （`connector/src/admin/advertise.ts`）—— 监听面仍然不终结 TLS，TLS 在反代 / `tailscale serve` 那一跳。
  笔记 `implemented/2026-11-10-direct-endpoint-accepts-wss.md`。顺手修掉一个死分支：
  直连公网明文以前永远报「必须 WSS」，现在先走「请先勾选确认」。
  门禁全绿（connector / app / `verify-platform-boundary`，条数以 `tools.md` 为准）。

- **v0.2.15 已发版（2026-11-10）**：Release `dsh-mobile-v0.2.15.apk`（**75.14 MB**，
  `versionCode 18`（= CI 的 run number）/ `versionName 0.2.15`）+
  `dsh-mobile-connector-0.1.23.tgz`（连接器本次没改，npm `latest` 仍 0.1.23）。
  **签名核对**：`apksigner verify --print-certs` → `CN=dsh-mobile, OU=release, O=Imzl-zl, C=CN`、
  SHA-256 `c0a55225…`，与本机 `app/android/app/release.jks` 同一把。
  三个 run 全绿（`ci` / `release` / `publish-connector`）；Release notes 是**手填**的
  （三笔修复直提 main、没走 PR，流水线自动生成的只剩一行 compare 链接）。
  **真机**：官方包已装，但必须**卸载重装**——我试装时用了 `--build-number=19..23`，
  比 CI 这次的 run number（18）大，`adb install -r` 会被判降级；卸载导致隔离实例的配对丢失（重扫即可）。
  教训：以后本机试装包**不要**用大于当前 run number 的 build number，否则会挡住官方更新。
  内容 = **三笔与「新建会话」相关的修复** + 一个新真机用例：
  1. 会话行的 `blank` 缓存跟着 `turn/start` 当场翻（原来只等清单重读）；
  2. 流式尾归**当前会话**（`_liveTailBelongs`：切会话清空、只收当前会话的 `live` 帧）；
  3. **「标题说新会话、正文是旧对话、点 ＋ 没反应」的兜底**：判据收成
     `AppModel.sessionBlankOf`（宿主说 `blank` **且** 手里没可见条目，`OtherItem` 不算），
     顶栏 / hero / 复用 / 抽屉可见性与标签 / 内联列表 / 分页水位全部走它 ——
     `session/title` 那条通知丢多少次也不会再自相矛盾。
     笔记 `implemented/2026-11-10-stale-blank-row-self-heals.md`（里面写明“通知为何会丢”仍未证）。
  真机证据：隔离实例（`D:\tmp\dsh-mobile-home` + `--profile dsh-mobile-test`，直连 18791）
  + 本机 3425 网关的免费渠道（`free/deepseek-v4.1-flash`，真跑了两轮生成、不花官方账号的钱）；
  `new_session_real_device_test.dart` 的旧会话换页 / 复用不多建 / 发过一句再点 ＋ 三条全过。

- **「标题变新会话、正文还是旧对话、点 ＋ 没反应」= 那一行停在了 `blank: true`**（2026-11-10）：
  `blank` 是宿主的字段、手机只缓存，重读清单靠 `session/title` 之类的通知；那条通知
  一丢（中转抖动 / 进程被冻结 / 重取失败），行就永久卡住 —— 而 `displayTitle` 里
  blank 压过 title（与 DSH `tree.ts:287` 同形），于是顶栏写「新建会话」、正文还是旧对话，
  `findBlankSession` 又把它当新会话复用 ⇒ 再点也没反应。健康连接上它自愈（实测标题事件
  ~1 秒就把整行刷真）。**未证**：通知为什么丢（中转只做字节转发，代码看不出会吞帧）。
  修法：这道判据收成一道 `AppModel.sessionBlankOf`（宿主说 blank **且** 手里没可见条目，
  `OtherItem` 不算），顶栏 / hero / 复用 / 抽屉可见性 / 内联列表 / 分页水位全部走它。
  单测红→绿 + 变异校验；笔记 `implemented/2026-11-10-stale-blank-row-self-heals.md`。
- **另两条同日修复**：① `turn/start` 到达时那一行当场翻 `blank: false`（笔记
  `implemented/2026-11-10-blank-row-stale-after-turn.md`）；② 流式尾归当前会话
  （`_liveTailBelongs`，笔记 `implemented/2026-11-10-live-tail-belongs-to-session.md`）。
  两条都有单测 + 变异校验，但**都不是**上面那条反馈的根因（真机 A/B 已排除）。
- **真机复现环境（2026-11-10 跑通）**：隔离 home `D:\tmp\dsh-mobile-home` + `--profile dsh-mobile-test`
  （web 3099 / 直连 18791）。三件坑在 `tools.md` 的「隔离实例」第 10 条：`relayUrl` 必须私网地址、
  `POST /api/dsh-mobile/pair` 回 SVG 要 jsQR 解、直连端点要 `pairingStore.saveEndpoints` 自己塞。
  跑 `integration_test/` **会卸 App**，事后装 Release APK 装回来。

- **v0.2.14 已发版（2026-11-09）**：Release `dsh-mobile-v0.2.14.apk`（78.79 MB，
  `versionCode 17` / `versionName 0.2.14`）+ `dsh-mobile-connector-0.1.23.tgz`（201 KB，
  与 0.2.13 那份相同 —— 连接器本次没改）。内容 = **#8 的四件**（后台任务完成通知（按 jobId
  去重 / 30 分钟窗口）/ 已回答问答标题「问答 · 已回答」/ 文件预览行号 + 面包屑 /
  轨迹段字段 JSON（标题注明非原始 payload））+ notify 在非 Android 的 release 装配即抛 +
  边界门禁两处唤醒（扫真实形态、每条规则必须有适用文件）。Release notes 由流水线按 PR
  自动生成（7 条）。**签名核对**：`apksigner verify --print-certs` →
  `CN=dsh-mobile, OU=release, O=Imzl-zl, C=CN`、SHA-256 `c0a55225…`，与本机
  `app/android/app/release.jks` 同一把（`keytool -list -v` 同指纹）⇒ 官方包可覆盖本机构建。
  笔记 `implemented/2026-11-09-*`。
- **2026-11-09 一批**：边界门禁唤醒（只扫 `app/lib` / 认文件形态 import / 剥注释只在一处，
  843→862 含规则覆盖检查）、notify 在非 Android 的 release 装配即抛、#8 四件（语义来自
  @williamking-art 的 #8，重写见各 PR 的「来源与署名」）、测试条数只住 `tools.md`、
  #8 文档漂移逐条判过（十组落地、三组不成立）。笔记 `implemented/2026-11-09-*`。
- **v0.2.13 已发版（2026-11-09）**：`dsh-mobile-v0.2.13.apk`（78.8 MB）+
  `dsh-mobile-connector-0.1.23.tgz`。内容 = **「添加电脑」入口**（连接 sheet，已配对时给）：
  只进配对页、**不清任何槽**，取消也不动凭据；加完记 `_previousHostId`，「切回上一台」立刻可用。
  取舍见 `implemented/2026-11-08-add-computer-without-clearing.md`。**真机**：0.2.13（code 16）
  已装，官方包直接覆盖本机构建 —— 本机 `key.properties` 与 CI 是同一把签名密钥，不用卸载重装。
- **v0.2.12 已发版（2026-11-08）**：Release `dsh-mobile-v0.2.12.apk`（release 签名，
  `CN=dsh-mobile, OU=release`，75 MB）+ `dsh-mobile-connector-0.1.23.tgz`（0.19 MB）；
  npm `latest` = **0.1.23**（OIDC + provenance）。内容 = 新建会话在途合并、用量页换源与
  按天活动分批（见下两条）。CI 首轮 `connector` 红：Dart 探针下载
  `libsqlite3.x64.linux.so` 的哈希与 sqlite3 构建钩子的期望值不符（**远端资产 flake，
  与本次改动无关**），`gh run rerun --failed` 后四个 job 全绿。
- **新建会话不再"连点成好几个"（2026-11-08）**：`createSession` 照 DSH 的 `connectBlank`
  按 `(工作区, 预设)` **在途合流**（同一目标连点只发一次 `session.create`）；本地那一行按
  真值写 `blank: true` + `cwd`（原来默认 false 且没 cwd：App 把它画成正常会话、桌面按
  `sessionVisible` 藏掉 —— 这就是"桌面上没有"，复用判据也因此失效）；建完重读会话清单。
  blank 行现在显示「新建会话 / 尚未开始」（原来「未命名 / 2 条」，把系统事件当内容）。
  **真机验收（隔离实例 + adb）**：连点 3 次 5→6（只建一个），再点复用不增。
  笔记 `implemented/2026-11-08-new-session-inflight-guard.md`。
- **用量页能出来了（2026-11-08）**：`usage.summary` 的总量 / 分项 / 项目 / 会话改读
  `session.list` 行自带的 `tokenUsage` 投影提示（原来逐会话 `projections.of`：
  本机 327 会话 / 539 MB 日志 ⇒ 页面永远空着）；按天活动改成可选 `{days: 1..366}`，
  **每批只新扫 4 个会话**、按投影水位缓存，应答带 `daysProgress`，手机接着要下一批。
  页面重排成**累计**（构成条 + 缓存命中 + 四格占比）/ **近期活动**（今天 · 近 30 天对比 ·
  日均 · 平均每轮 · 7/30/90 热力图）/ **项目**（占比条 → 会话占比）。**真机验收**：
  首屏 0.6 s 出总量，活动 4/6 → 6/6 两秒内补齐。笔记
  `implemented/2026-11-08-usage-summary-from-list-rows.md`。
- **v0.2.11 已发版**（`app/pubspec.yaml` `0.2.11+6`；Release：`dsh-mobile-v0.2.11.apk`（release 签名）
  + `dsh-mobile-connector-0.1.22.tgz`）：内容 = 抽屉分组补问账本（新建会话不再先落「未分组」）、
  Markdown 表格横滚条改细条且不常驻、顶栏开抽屉换回基线 `☰`；插件 0.1.22 的「配对新手机」
  卡加了 App 下载入口。README 重排（**下载**单独成节）并换成这一版的真机截图。
- **流式条目与持久条目同形（2026-11-07）**：累加器按 `chunk.type` 分流成
  `LiveMessage {reasoning, text}`（`app/lib/core/live_message.dart`），思考不再冒充正文；
  尾条目搬到 `chat_turns.dart` 的 `LiveAssistantTurn`，与 `AssistantTurn` 并排，
  思考走 `ReasoningRow(running: true)`（摘要 = 最后完成段落首行），正文 `selectable: false`。
  决策笔记 `implemented/2026-11-07-live-message-shape.md`。**未做**：流式块级冻结、
  阅读位置补偿（倒序列表最新端插入/增长会顶走阅读内容，已量到 100 px）。
- **顶栏开抽屉改回基线 `☰`（2026-11-07）**：自画三横线（`ui/dsh_menu_glyph.dart`，
  不进机生成的图标表；原型同一组坐标的 inline SVG）。`DshAppBarButton` 增 `glyph`。
  笔记 `implemented/2026-11-07-drawer-toggle-icon.md`。
- **抽屉分组与滚动条（2026-11-07）**：会话清单落地后若有会话不在任何工作区里，
  补问一次 `workspace.list`（`_probeWorkspaceLedger`，一个 sid 一次）—— 桌面新建的会话
  不再先落「未分组」；Markdown 表格的横向滚动条改由主题给（3 px 细条、半透明拇指、
  无轨道），并关掉常驻拇指。笔记 `implemented/2026-11-07-workspace-ledger-probe.md`。
- **插件面板给出 App 下载入口（2026-11-07）**：「配对新手机」卡里加「还没装手机 App？下载最新版」
  → `releases/latest`；插件版本提到 **0.1.22**（面板文案属插件产物）。笔记
  `implemented/2026-11-07-download-entry-in-panel.md`。README 重排：**下载**单独成节，
  截图换成 0.2.10 真机（会话 / 设置 / 面板配对卡）。
- **v0.2.10 已发版**（`app/pubspec.yaml` `0.2.10+5`；Release：`dsh-mobile-v0.2.10.apk`（release 签名）
  + `dsh-mobile-connector-0.1.21.tgz`）：内容 = 流式思考与正文分流（`LiveMessage`，思考不再混进正文）、
  **思考随轮组折叠的两处判据**（答复自带的思考算过程证据 / 未收口的一轮过程保持展开，
  笔记 `implemented/2026-11-07-reasoning-is-process.md`）、端点动作弹框改「立即连接」并去掉
  冗余状态句（笔记 `implemented/2026-11-07-endpoint-action-label-and-disabled-state.md`）。
- **v0.2.9 已发版**（`app/pubspec.yaml` `0.2.9+4`；Release：`dsh-mobile-v0.2.9.apk`（release 签名）
  + `dsh-mobile-connector-0.1.21.tgz`）：内容 = P1 能力口与事件载荷端口、S0–S4、设置行值封顶 42%、
  一批过期与多余的解释句。**connector 0.1.21 一并发了**：`v*` 标签本来就会发插件
  （`publish-connector.yml:19` 同时监听 `v*` 与 `connector-v*`，发布步没有标签守卫），npm
  `latest` 现在就是 0.1.21（带 SLSA provenance）。三条链（投影 / 子代理 / 审批）已于
  2026-11-07 在 0.2.2-rc.1 隔离宿主 + 真机跑通，证据在
  `implemented/2026-11-05-022-rollout-handoff.md`。
- **面板六条反馈 + 连接器标识（2026-11-06/07，`f441462`）**：本机版本读 `/status`（不联网）、
  Kit 全角数字归一 + 错误带码位、`#电脑` 改已用/上限、服务端错误码统一翻人话、最后一名
  管理员降级按钮真禁用、默认只报默认路由 IPv4（其余进「更多地址」）、设备行短码与
  「最近答话 / 此刻连接」两列。connector **新装随机；旧装 `local` 强制迁移**（已配对
  手机重扫、旧中转令牌清除），不再保留 `local`。决策笔记 `implemented/2026-11-06-*` 与
  `implemented/2026-11-07-connector-id-force-random.md`。
- **分层现状**（PR #9 → main `47b3472`）：`data → wire` 走能力口（`HostReads` 18 / `HostWrites`
  22，`HostRpcHolder` 两个 getter），事件载荷走 `EventFields` 端口（core 声明、wire 实现）；
  `core → wire` 与 `data/`、`ui/`、`core/` 的 `wire/` import 都是 **0**。`data/` 字段名读点
  **22 → 0**，门禁 `data-no-field-name` 钉住（把线上字段名当字面量传给 `fieldOf` /
  `stringField` / `intField` 即红，报行号）。代价：5 个测试文件因"字段名撞端口方法名"改名、
  端口返回 `SnapshotReply` 三态、`core → model` 多了一条纯类型环。
- **存储与主机**：`HostScope` + 装饰器 + v2→v3 迁移，**换电脑不再清库**（`clear()` 删掉只剩
  `clearScope()`）；`HostSessions` 按 `hostId` 池化（切电脑 = 换可见指针，跨台通知 id 带主机
  前缀）；`AppServices` 持唯一 `NotifyPort`。**未做**：S5（AppModel 切片、`chat_page` 拆文件）。
- **真机验收**：真机库副本（24.5 MB）喂 v2→v3 —— 4136 条条目一条不少、14 个水位键全带前缀、
  `device.*` 原样；debug 包装机实测迁移（未分域行 0、无崩溃，验完复原空 v3）。**唯一没验**：
  两台电脑同时配对后切电脑外观不回默认（要两次扫码）。
- **中转踩过的雷（v0.2.9 那次）**：令牌表里两条记录都绑 `connectorId: local`（两个租户的电脑都用
  默认 `pcId`）时，中转**拒绝启动**（停了约 4 分钟）；清掉其中一条的绑定后恢复。修法见
  `implemented/2026-11-07-connector-id-force-random.md`：新装随机 id、旧装 `local` 强制迁移
  （手机重扫、旧令牌清除），中转侧把旧 `local` 当墓碑 —— v0.2.11 起这条已在生产生效，不会再触发。
- **生产中转已更新到 v0.2.11 代码**（`dsh.0t0.me`，华为云 `/opt/dsh-mobile`，`v0.2.11` 标签 /
  `841bc33`，镜像 `sha256:4e309b47…`）：`git fetch && git checkout v0.2.11` + `docker compose -f
  docker-compose.server.yml up -d --build`，容器 healthy。本次中转侧变更 = **旧 `local` 令牌按
  墓碑处理**（`token-table.ts`：保留在 `byId` 供管理台吊销，不进 `byConnector`/`byHash`）+
  管理台页面与 UI kit。启动日志「摘要表 **3** 条」即墓碑生效（配置里 4 条，`local` 那条被排除）；
  上次那颗"两条 `local` 拒绝启动"的雷因此不会复发。更新后实测：配置里 `local` 绑定已由连接器
  侧迁移清掉（那台电脑换了随机 id `pc-Wjg3E1COkdC-` 并重新登记），重启中转后半秒内
  `connector.open` 就回来了 —— 旧令牌失效没有造成掉线，走的是既定的迁移路径。
  回滚：`git checkout 6c9d906 && docker compose -f docker-compose.server.yml up -d --build`。
- **门禁**：全绿即通过；**各项条数只住 `tools.md`**（protocol 三条 / boundary / connector / relay /
  app 的 format·analyze·test）。

## 下一步

0. **旧装升级是一次性迁移**：所有 `local` 强制换随机，已配对手机重扫；`required` 模式需在
   管理台重签令牌。中转侧的旧 `local` 令牌是墓碑（不阻止启动、不能再用），管理台可删。
1. **数据面收敛（三批已落地）**：触发源按来源拆、行只带手机读的五个投影键、列表分页、
   重连带落盘水位、十个只读快照带 `digest`、出站账补齐。留给以后的：`permission.catalog` /
   `repo.info` 仍在 `connectLanding`；`session.projections` 仍是 20+ 键一整包；权限预设目录
   的真机验收；摘要表是每进程的（冷启动要十份快照正文）。
2. **多设备并发准入真机复验**：两台手机同时连同一台电脑；吊销 A 后 B 仍在线。两条关闭路径
   分开看 —— A 答完时 B 由会话事件（`approval/decided` / `tool/result`）关门，B 迟一步再答
   才拿 `interaction/not-pending`；单测已钉，端到端要两台真机。
3. **状态语义对齐（A–H 已落地）**：真机复验还差 4 条（子智能体在跑可见、提问草稿、
   发送模式真值、断连重连）。
4. 真机复验改动卡 / 差异 / 提及（要模型请求 —— 先报价再跑）。
5. `usage.summary` 的 byDay 时区。
6. 大改后巡检 `docs/` 与代码漂移（2026-11-12 已清三处：分层规则、`installStatus` 两形态、
   `caps.approval`；那次的结论与判据见 `implemented/2026-11-12-doc-drift-three.md`）。
7. **投影包按消费者拆**（方案 `proposed/2026-11-04-projection-payload-split.md`，未实现）。

## 门禁（改代码后必须全绿，项数以 `tools.md` 为准）

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | 通道协议（三条都全绿） |
| `node app/tools/verify-platform-boundary.mjs` | 多端边界（规则自检 + 全量扫描） |
| `node app/tools/verify-rpc-single-caller.mjs` | `app/lib`（`wire/` 外）零 `call<` |
| `node mock/proto/tools/verify-{icons.cjs,tool-paths.mjs}` | 图标集 / 24 个工具脚本无硬编码盘符 |
| `cd app && flutter test` | 手机端全量（约 1 分钟） |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format` | 各 0 |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + 全量 |
| `cd relay && pnpm typecheck && node --test` | 类型 + 全量 |

**改断言必须做一次变异校验**（故意破坏不变量，确认恰好那几条红，条数写进提交）。
## 八条教训

1. **投影信封**：`session.projections` 回 `{kind, asOfSeq, values}`，手机要 `values`。
2. **模型目录是对象**（`{default, routableProviders, groups, failures}`）不是数组。
3. `session/select-model` **没有"不能写"约束**：别把测试纪律升成产品约束。
4. **"空"有两种表达**：`items.isEmpty` 漏了 `OtherItem`；`usage == null` 漏了"字段齐全但全零"。
5. **判据要能区分"没命中"与"没实现"**：先一行 `debugPrint` 确认回调跑了，再怀疑手势。
6. **一个功能一次提交完整**；**生产路径上的假数据最容易漏**（不报错、不空屏，只是名字/数字是编的）。
7. **线上预算按帧算**：二进制 `N` → JSON base64 → box 再 base64url ≈ `1.78N`。
8. **用例喂的形状必须是线上形状**：真机事件/真库行先 dump 再写断言；字段类型只在 `wire/` 断言。

## 真机联调的成本纪律

- 隔离实例：`$env:DSH_HOME='D:\tmp\dsh-mobile-home'` + `dsh --profile dsh-mobile-test`；`--profile`
  只隔进程/插件/端口，**凭据/会话/存储共用** → 跑之前报轮次并拿到准。装 App 用 `adb install -r`
  （`flutter install` 会先卸载）。

## 仍未注意就会翻车

- **改源码只用编辑工具**（shell 替换静默出错）；`dart format` 会重排文件，之后再编辑要重读。
- **同一件事只有一处判据**（重建哪条通道 / 起传输容忍什么 / 面板读什么）：已有同名模块 +
  回归用例，别在 `index.ts` 再写；坑点见 `tools.md`。

## 已知缺口（仍在）

- 计划审查卡手机上不存在（**有意**，契约 §15）；连接卡保存后只轮询 6 秒判连上；「清空全部
  记录」会把还在用的离线设备一起删；旧历史合并载荷修不回来（要 `session.page` 重放，未做）。

## 已落地索引

- 2026-09-30 通道协议定稿 / 配对 v1 / 连接层拆分 — `implemented/2026-09-30-*`、`2026-10-01-*`
- 2026-10-02 安卓里程碑 / 主题层 / 图标 / 本地库 / 配对 — `implemented/2026-10-02-*`
- 2026-10-07..09 配对 v2、设备身份、三处线上形状错 — `implemented/2026-10-0[789]-*`
- 2026-10-13..17 交互链、审批/提问、发送模式、端点切换、标题、设置页 — `implemented/2026-10-1[3-7]-*`
- 2026-10-19..24 渲染对齐、轨迹/轮组、用量、文件页、插件、任务、通知 — `implemented/2026-10-19-*`..`24-*`
- 2026-10-25 RPC 应答面收口（8 批） — `implemented/2026-10-25-wire-*`
- 2026-10-26 评审六批 + 真实清单进金样 + 桌面四件事 + 连通落点 — `implemented/2026-10-26-*`
- 2026-10-27 UI 状态语义（审计 → 机制 → A–H 批） — `implemented/2026-10-27-*`
- 2026-10-28 渲染批次 + 唤醒判据修正 — `implemented/2026-10-28-*`
- 2026-10-29 连接卡 / 无令牌可挂载 / 装配层回归网 / 端点剪枝 / 明文两档 — `implemented/2026-10-29-*`
- 2026-10-30 多机四步 + 中转可观测·限额·面板 — `implemented/2026-10-30-*`
- 2026-11-04 轨迹页重读、目标条、中转三块收口 — `implemented/2026-11-04-*`
- 2026-11-05..07 双轨版本线 / S2/S4 / 面板六条 / connector 随机标识 / 0.2.2 三条链 —
  `implemented/2026-11-05-*`、`2026-11-06-*`、`2026-11-07-connector-id-force-random.md`
- 2026-11-08 新建会话在途合并 / 用量汇总结算换源 — `implemented/2026-11-08-*`
- 2026-11-09 门禁唤醒 / notify release / #8 四件 / 计数与文档漂移 — `implemented/2026-11-09-*`
