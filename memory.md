# dsh-mobile 项目状态

> 快照 + 最近窗口，**覆盖更新**，不做流水追加。历史在 git 与 `.agents/notes/`；
> 11-04 及更早的条目在 `memory/archive/2026-11.md`，11-12 ~ 11-15 的窗口在
> `memory/archive/2026-11b.md`；稳定命令与坑点在 `tools.md`；现状事实在 `docs/`。

## 现在（2026-11-22 · v0.2.22 / connector 0.1.29）

- **v0.2.22 已发版（2026-11-22）**：`dsh-mobile-v0.2.22-arm64-v8a.apk` **28.7 MB**
  （`armeabi-v7a` 25.0 / `x86_64` 31.2）+ `dsh-mobile-connector-0.1.29.tgz`（208.1 KB，
  npm `latest` = **0.1.29**，带 provenance）。Release notes 已手填。
  内容 = 本窗口三笔：子智能体目录四态 / 命令面 = 宿主的命令表面 / `/` 菜单技能段。
  **踩到一次**：`v0.2.22` 与 `connector-v0.1.29` 两个标签同时触发 `publish-connector`，
  两个 run 都过了 `npm view` 的幂等检查再同时 publish，后到的拿到
  `E409 Cannot publish over previously staged version`（npm 上的结果是对的，
  但 Actions 多一条红）。已给该 workflow 加 `concurrency: publish-connector` 串行化。

- **用户 2026-11-21 报的三条，定位结论**（真机 v0.2.20 + connector 0.1.28，走中转）：
  1. **子智能体面板永久转圈 = 已修**。三处叠加：目录"没读过"返回 `loading` 占位
     （界面上转圈、实则零个在飞请求）；`notModified` 时不落状态（一次失败之后再重试
     就永久停在 loading，且重试行只在 error 态 ⇒ 连补救入口都没有）；在飞表按 key
     合流（A 的慢读让 B 的请求根本不发）。外加"面板被看见"不是触发点。
     现为四态 `never/loading/ready/error`，迁移收在 `data/subagent_catalog_cache.dart`，
     新增触发列 `panelVisible`，在飞键 `(key, sid)`。笔记
     `implemented/2026-11-21-subagent-catalog-four-state.md`。
  2. **`/` 只有 `/goal`、`/plan` = 连接器白名单**（`connector/src/handlers.ts` 的
     `MOBILE_COMMANDS`）。桌面 `/` 菜单是"命令表 + 该会话的技能目录"
     （`ui-chat/src/client/chat/chat-snapshot-builder.ts:646` 的 `SlashEntryKind`），
     **技能目录手机端整块没接**。这一条**未动**，与"APP = 复刻桌面"同批做。
  3. **「新建会话闪一下回旧会话」未复现**：两次都成功，且电脑侧确实建出会话
     （`~/.dsh/sessions/…` 330 B 的 blank 文件）。仍缺一次带 RPC 轨迹的诊断包。
- **命令面已与桌面一致（2026-11-22）**：连接器的 `MOBILE_COMMANDS` 白名单**删掉**了 ——
  `command.execute` 把任何 `/名字` 原样交给宿主，`repo.info.commands` 报宿主的整张
  命令表（`CommandLineRunner.catalog()` 读 `commands.list(agent)`，一条不筛）。手机侧
  零名单，所以电脑装个插件多一条命令，手机 `/` 菜单立刻多一行。代价写在明处：
  `/export`、`/feedback` 的产物在手机上没有形态（界面如实显示宿主的 `text`，不假装
  文件到了手机）；崩溃窗口的重发只靠幂等表（与桌面 Web 同一个暴露面）。
  `repo.info` 触发点补了 `openSession`（命令表是 per-agent 的，刚连上可能为空）。
  笔记 `implemented/2026-11-22-command-surface-parity.md`；旧篇移入 `archived/`。
- **`/` 菜单的技能段已接上（2026-11-22）**：新方法 `skill.catalog`（只读、会话级）+
  连接器端口 `connector/src/dsh/skills.ts`（别名 → DSH 会话 id、30s 上限、坏行丢掉、
  只过 `name`/`description?`/`modelInvocable?`）+ `caps.skills`。手机侧
  `HostStateKey.skillCatalog`（会话级；触发 `connectLanding`/`openSession`，没有通知列）、
  `AppModel.slashSkills` 按 `_skillsSid` 判归属、`/` 面板第二段 `kSectionSkills`
  （选中插 `/名字 `，按普通消息发 —— 技能不是命令）。宿主面：
  `packages/api/session-controller/src/skill-catalog.ts:36` 的 `sessionSkillCatalog`。
  门禁：connector **890** · app **1985**；变异校验 1 次（去掉归属判据 ⇒ 恰好 1 红）。
- **本轮门禁**：app **1985**（+12 新 / 1 条改判）· connector **890** · boundary **979** ·
  size PASS（`app_model.dart` 5350 / `dsh_composer.dart` 1900，各是一次可见的提额）·
  `dart analyze --fatal-infos` 0 · 变异校验 3 次（在飞键、`notModified`、技能归属）。
- **已知缺口**：摘要与内容的寿命不一致这条**根因**仍在 —— 将来放掉某个会话的快照
  必须同时放掉它的摘要，否则同一条"没变"死路会在别处复现。
- **本机 `desktop` profile 已还原成 npm 原装的连接器 0.1.28**（2026-11-22 收尾）：
  验真机时手工覆盖过 `lib/`，已按原样还原 —— 现在 `lib/` 是 npm 0.1.28 的原产物
  （`MOBILE_COMMANDS` 出现 7 处、无 `skill.catalog`、mtime 2026-11-20 22:18），
  备份目录已删除，`package.json` 仍是 `0.1.28`。
  **这台机器现在跑的是旧连接器**：要用 v0.2.22 的命令面与技能段，得把
  `dsh-mobile-connector` 升到 **0.1.29** 并重启 DSH；手机上的 APK 同理（应用内更新到 0.2.22）。
- **仍未做**：「新建会话闪回旧会话」要带 RPC 轨迹的诊断包才能钉死（用户未批准）；
  上面两批的真机复验只到"能进会话 / `/` 出两段"这一步。

## 上一窗口（2026-11-20 晚 · v0.2.21 / connector 0.1.28）

- **v0.2.21 已发版（2026-11-20）**：`dsh-mobile-v0.2.21-arm64-v8a.apk` **28.7 MB**
  （`armeabi-v7a` 25.0 / `x86_64` 31.2）+ `dsh-mobile-connector-0.1.28.tgz`（208.6 KB，
  npm `latest` = **0.1.28**）。Release notes 已手填。
  **踩到一次**：打标签时 `ci` 红在 `dart format`（新测试文件没本地格式化），
  `release` 与 `publish-connector` 却是绿的 —— 因为 `release.yml` 不含格式门禁。
  已补 `f7a0888` 并转绿；`v0.2.21` 标签指向 `df02736`（产物不受影响：
  APK 与 tgz 都不含那个测试文件，`lib/` 与 `src/` 逐字相同）。
  **下次发版前先跑 `dart format --set-exit-if-changed`**，别只跑 analyze 和 test。
- **两个用户报的故障，都已修并随本版发布**：
  1. **App 更新下载必然失败**（v0.2.18~0.2.20 全中）。`DshAppUpdate.kt:48` 回
     `DownloadManager.enqueue()` 的 `Long`，Dart 侧却写 `invokeMethod<String>`，
     `platform_channel.dart:366` 的 `as T?` 每次必抛
     `type 'int' is not a subtype of type 'String?'`。改成 `invokeMethod<void>`；
     新增 `app/test/app_update_download_test.dart` 5 条（驱动真通道，此前只有缝的替身）。
     笔记 `implemented/2026-11-20-update-download-channel-return-type.md`。
  2. **代理 TUN 抢走默认路由 ⇒ 出码报"没有可上报的地址"**。旧 `defaultDirectUrls`
     假设"默认路由网卡 = 局域网网卡"；TUN 在场时两个坏分支（码里写 `198.18.0.1`
     手机拨不通 / hint 落空时 6 条候选一条都不报）。判据改成**地址自己的事实**：
     `listener.ts` 新增 `isVirtualMac`（MAC OUI：全零=TUN、`00:50:56`=VMware、
     `00:15:5d`=Hyper-V、`02:42`=Docker）带出 `virtual` 事实，`defaultDirectUrls`
     排除虚拟网卡后优先 hint、否则在 RFC1918 里按 `192.168→172.16→10` 选一条
     （**仍只报一条**）。报错文案按候选实况分档（`isLanAddress` 与判据同源）。
     笔记 `implemented/2026-11-20-advertise-by-address-not-by-default-route.md`。
- **本轮门禁**：app **1973** · connector **885** · relay **183** · protocol 454/26/49 ·
  boundary **962** · size PASS · `dart analyze --fatal-infos` 0 issues。
  变异校验：更新下载 2 红；TUN 判据两类各 3~4 红；文案分档 1 红。
- **未做**：**两件都没真机验**。① 更新下载（`DownloadManager` 落盘/通知/点开安装
  这三跳是系统行为）；② 扫码后局域网那条真能不能拨通。都只到"请求发得出 /
  电脑侧选对地址"为止。
- **残留风险**：拿不到 MAC 的平台上 `virtual` 未知，VMware 地址仍可能被选中
  （按网段兜底）；网段偏好序是启发式，同机既有 `192.168.x`（不通）与 `10.x`（通）会选错。
- **v0.2.18~0.2.20 的用户升级路径**：那几版的「App 版本」下载是坏的，
  必须在 Release 页手动装一次 v0.2.21，之后的版本才能走应用内更新。

## 上一窗口（2026-11-17 晚 · v0.2.20）

- **v0.2.20 已发版（2026-11-17）**：`dsh-mobile-v0.2.20-arm64-v8a.apk` **27.4 MB**
  （`armeabi-v7a` 23.8 / `x86_64` 29.7）+ `dsh-mobile-connector-0.1.27.tgz`（0.1 MB，
  npm `latest` = **0.1.27**）。三个 run 全绿（`ci` 6m31s / `release` 6m20s /
  `publish-connector` 31s），Release notes 已手填。
  内容 = 出码只写"此刻活着的路" + 手机扫完先探两条再选。
- **出码不再问"这张码给谁用"**：面板删掉「同一 WiFi / 任何网络」二选一，`/pair` 不读 body；
  判据收成 `planPairingOffer`（两条都没有就拒，文案分档说清"监听没启动"与"没有可上报地址"）。
  面板只报通道事实，码里有什么只在出码后说。笔记
  `implemented/2026-11-17-offer-carries-what-is-alive.md`；契约 `pairing-v2.md` §3。
- **手机扫完同时探两条**：`probePairing` 直接复用 `beginPairing(directOnly/relayOnly)`
  真拨一遍（探测=完整受限握手），逐条给「通 / 不通（原因）/ 这张码不含 / 按设置未尝试」；
  用户选一条，预选按 `route_policy`，且**策略决定探测范围**（`directOnly` 不换票、
  `relayOnly` 不拨局域网）。提交前收掉另一条。顺手修掉 `tryRelay` 握手失败不收半开
  socket 的老漏。笔记 `implemented/2026-11-17-pairing-route-choice-on-phone.md`；
  文档 `pairing-v2.md` §5、`remote-channel.md` §12.1。
- **本轮门禁**：app **1968** · connector **870（869 过 / 1 跳过）** · relay **183** ·
  protocol 454/26/49 · boundary **962** · size PASS（拆出 `ui/pairing_routes_panel.dart`）·
  icons 62 · format 0。变异校验：出码判据 1 红；探测去掉 relay 分支 2 红（笔记按实测写）。
- **未做**：**真机没验**（要重扫码，会清掉这台手机的配对凭据）；插件面板在 DSH 真 React 里的
  落位只在隔离实例验了接口（`D:\tmp\dsh-mobile-home` + `dsh-mobile-test` + `--port 3099`），
  没点界面。

## 上一窗口（2026-11-17 早 · v0.2.19）

- **v0.2.19 已发版（2026-11-17）**：`dsh-mobile-v0.2.19-arm64-v8a.apk` **27.3 MB**
  （`armeabi-v7a` 23.8 / `x86_64` 29.7）+ `dsh-mobile-connector-0.1.26.tgz`（连接器没动）。
  三个 run 全绿（`ci` 7m11s / `release` 6m00s / `publish-connector` 21s，后者按幂等挡掉）。
  Release notes 已手填（修了什么 + 该下哪个包 + 已知未对齐）。
  内容 = 一笔：**「新建会话」那一行钉在组首**（见下一条）。
- **「新建会话不在工作区第一个」= 组内分区漏了桌面那一条**（用户 2026-11-17 报的
  「可以新建但不在第一个」）。抽屉与内联列表都按 `workspace.list` 的账本行序排，而桌面把
  **当前 blank 会话钉在组首**（`pinCurrentBlank`，`tree.ts:213-219`）+ blank 一律排前
  （`sectionMembers`，`:269-283`）。账本序给不出它：点「新建会话」先复用账本里**已有的**
  blank，位置还是它当初被建出来时的老位置（只有真新建的才被 `attachSession` 插到最前，
  `entity.ts:147-149`）。现在 `bucketSessionsByWorkspace` 的分区是
  **blank → 置顶 → 其余**，`isBlank` 必填（走 `sessionBlankOf`，与可见性 / watermark
  同一道门）；blank 行被摘出 `DrawerSection.reorderableIds`，菜单与拖动都只认那一段
  （它自己移不动，紧挨着它的那一行也上不去；拖到它身上不画线、松手按最后扫过的那一格插）。
  **仍未对齐**：非 blank 之间手机按账本序，桌面默认按 `updatedAt`；要那条得先做
  「手动 / 最近更新」排序开关。笔记 `implemented/2026-11-17-blank-row-pinned-to-group-head.md`，
  文档 `docs/subsystems/session-ordering.md` §1.5。
- **踩到一条 Flutter 事实（写进笔记与 docs）**：`DragTarget` 的 `onMove` **不受**
  `onWillAccept` 约束 —— 框架先把 target 放进 `_enteredTargets`、再问 `didEnter`、
  然后对全部 entered 报 move（`drag_target.dart:932-945`）。所以"这个落点不接"必须
  在 `onMove` 里再判一次，否则插入线照样画上去。
- **本轮门禁**：app **1960** · boundary **956** · size 通过（`session_drawer.dart` 一度
  1408 > 1400，压回上限内 —— 该文件下次加东西要先把注释收一收）。
  变异校验四条：删 blank 分区 ⇒ 分组 3 条红；`display` 改回含 blank ⇒ 菜单 2 条红；
  去掉 `onMove` 落点门 / `_canAccept` 落点行守卫 ⇒ 拖动那条各红一处。
- **未做**：**真机没验**（新建之后抽屉里那一行是否真在组首）—— v0.2.19 就是给这一步用的。
  接线缺口：`main.dart` 传的是不是真判据只有类型兜底，没有端到端用例。

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
