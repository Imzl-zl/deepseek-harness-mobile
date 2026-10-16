# Agent Note: 手机端顶栏/状态位/消息渲染四条议题,按「先探原生缝、再列方案、后动代码」交接

Status: proposed

## Problem

上一轮把四条议题里的前两条做完了,但**工作方式被用户点名批评**,原话:

> "我们先了方案说了需求,你老是以结论凑过程,凑结果,不是探索过程找局部最优和全局最优,
> 探索 dsh 原生能力,去获得更好的结果"

有实锤:① 猜"那个在跑的是子智能体不是后台任务"当结论写进报告,其实根因是 `job` 帧归桶错;
② 标题先用 `cwd` 目录名兜底,后才发现 DSH 原生就有 `projections` hints;
③ 把"adb 点不开会话行"这个我方工具限制说成"需要你手动验证",把成本转嫁给用户。

剩下的议题(连接状态位占地方、顶栏标题挤、消息渲染、归档)每一条都可能已有原生缝,
所以缺的不是人手,是**先把 DSH 给了什么读完再决定**的那一步。

## Decision

这一轮的顺序是硬要求,四条议题都按它走:

1. **先探索 DSH 原生能力**:相关包源码读完,列出"原生缝有哪些、哪些没有"。
   引用一律 `packages/...:行号`,查不到写「未找到」,**禁止猜**。
2. **再列方案**:每条给出可选方案(含"什么都不做")与各自代价,
   局部最优(这一屏好看)与全局最优(与 Web 同源、单一真值源)分开说。
3. **最后动代码**:代码要能指回"哪个原生缝/哪条放弃的理由"。

准入门槛(可机械判定):

1. 每条议题开工前,输出里有一段"DSH 原生能力清单",带 `packages/...:行号`。
   没有这一段就不许动代码。
2. 每个新加的结构,要么指回一个原生缝,要么写明"原生没有、为何自己造"。
3. 报"已验证"必须附**我亲手跑出的证据**(命令输出/截图);adb 驱动不了就说驱动不了,
   不许写成"需要用户手动验证"。
4. 看到第二个真值源,按"让第二处读第一处"处理,**不是再加一个分支**。

## Alternatives considered

1. 直接接着上轮的势头把四条做完(状态位改绿点、标题限宽、渲染、归档)
   - 最强的理由:交付最快,用户看着进度舒服;前两条也是这么做出来的。
   - 为何被否:前两条正是这么做出来的,结果每一处都离原生能力差一层,
     用户每轮都能再挑出新问题。症状(顶栏挤、名字变、chip 不显示)修了三处,
     病根(没先读源码)没动,下一条议题还会再犯。
2. 先补一轮"DSH 能力盘点"文档,把四条涉及的面全查清楚再动手
   - 最强的理由:一次查清,后面四条都省力;也能沉淀成 `docs/` 的现状事实。
   - 为何被否:四条议题跨 `ui-theme` / `ui-chat` / `ui-jobs` / `ui-subagent` /
      `workspace-controller`,一次全查等于把上轮的上下文压力再复制一遍,
     而其中消息渲染那一面查完可能直接改变做法(见下)。按议题逐个查,查一条做一条。
3. 只做用户最新点名的两条(状态位 + 标题限宽),其余记 TODO
   - 最强的理由:范围小、当天能完,用户最近盯的就是这两条。
   - 为何被否:消息渲染是用户**最早**提的,一直没动;攒着不让它变小。
     至少要完成"消息渲染的 DSH 能力清单"这一步(可能只要读两三个文件),
     让下一条会话带着结论开工。

## Consequences

- 收益:每条议题的做法可复查(原生缝清单 + 行号);"凑结果"这个模式有明文门槛挡着;
  交接文档里附上已查证的源码位置,新会话不用把查过的东西再查一遍。
- 代价:单条议题的交付变慢(先查后做);原生能力清单要写读源码的结论,
  读错了会比不读更糟——所以门槛里要求带行号,可被下一个人复核。

---

# 交接正文(给新会话的开工材料)

## A. 已验证状态(勿重做)

- 会话列表按**工作区**分组:抽屉 + 主界面内联列表共用 `bucketSessionsByWorkspace`
  (`app/lib/model/workspace.dart`);`workspace.list` 走 workspace 控制器流基线
  (`packages/api/workspace-controller/src/feed.ts:85-96`)。
- 列表**可见性**照 DSH Web 的 `sessionVisible`
  (`packages/client/ui-workspace/src/client/tree.ts:238-255`):子智能体会话不列、
  `blank` 且非当前不列。真机复验 anatomy-test 3 条,与 Web 一致。
- 标题链 = DSH 的 `displayTitleOf`
  (`packages/api/session-controller/src/client/sessions/service.ts:116-127`),
  数据来自 `session.list` 行自带的投影提示(`list.ts:291-312`);
  **列表与顶栏同一个名字**(`currentTitle` 与 `displayTitle` 同一条链)。
- 统计条三项与 Web 同公式:`tok/s`(`ui-chat/src/client/chat/StatsPills.tsx:166-170`)、
  上下文占用(`ui-conversation/src/client/context-occupancy.ts:15-25`)、
  缓存命中率分母(`StatsPills.tsx:118-120`)。
- `job` 帧带 `sid`,手机不再猜归桶(`connector/src/job-subscriptions.ts` 的 `transform`)。
- 重连放弃:连续失败 10 次(约 3 分钟)停,显示「连接不上」+ 手动重试。
- 终端失败(换票 401)→ 清凭据回配对页,不退避。
- 术语已对齐:抽屉「示例」→「演示」(原型 `mock/proto/index.html:487`);
  「子代理」→「子智能体」(DSH `ui-subagent/src/client/locales.ts:36`)。
- 顶栏 chip 行已加(`_LiveChipsRow`),文案逐字照 Web
  (`ui-subagent/src/client/locales.ts:36-39`、`ui-jobs/src/client/locales.ts:8-11`),
  **有才显示**;点它开右抽屉对应面板。

**门禁基线**(改完重跑,数字会变):app `flutter test` 520 / `dart analyze --fatal-infos` 0 /
`dart format --output=none --set-exit-if-changed` 0 / `node app/tools/verify-platform-boundary.mjs` 218 /
connector `pnpm exec tsc --noEmit` + `pnpm build` + `pnpm test` 445 /
`node protocol/verify-fixtures.mjs` 486 / `verify-loopback.mjs` 26 / `verify-vectors.mjs` 49 /
`node mock/proto/tools/verify-icons.cjs`。

## B. 本轮要做的四条(按用户点名顺序)

### ① 连接状态位:占地方 → 改成点

用户原话:"还有这个已连接是不是占地方?显示个绿点啥的就行?没链接就红的,
连接中就转圈,需要重连啥的你可以显示其他的可以点击去重连啥的"

**先探索**:DSH Web 的连接/状态指示在哪个包、有哪些原生状态可读
(我们这边只有 `ConnectionStateView`:idle/connecting/handshaking/serving/backoff/gaveUp);
圆点颜色形状是否在 `ui-theme` 有对应 token(项目规则:颜色只能来自
`app/lib/theme/dsh_colors.dart`,不许自己取色)。

**约束**:点它之后的重连入口要保留;而用户明确要求"web 右边有个侧栏,
手机右边也可以做一个"——**右抽屉的入口不能因为改成点就丢了**。
现在 `_onStatusTap`(`app/lib/ui/chat_page.dart`)是 serving 开右抽屉、异常弹连接 sheet。

### ② 顶栏标题限宽

用户原话:"web 屏幕大能显示很多,手机屏小,你需要限制大小,给子智能体,
后台任务,这些留位置"

现状:`☰ 标题(Expanded) 状态位 ＋`,标题长了把状态位挤到 42vw 上限
(`app/lib/ui/dsh_app_bar.dart` 的 `DshStatusPill`)。chip 行加完之后更挤。

### ③ 消息渲染(最大未知,用户最早提的)

用户原话:"其实还有手机端的渲染也有问题,这些都是可以参考 web 的,
就是 web 移动到手机上都能参考,像 html 的渲染啥的"

**先探索**:Web 侧消息正文由哪个包渲染(markdown / 代码高亮 / HTML),在 `ui-chat` 里找;
通道传过来的正文是什么**表示**(纯文本?markdown?结构化块?)——
这决定手机要不要自己渲染。如果 DSH 传 markdown 而手机当纯文本显示,
就是"原生能力没用上"的典型,按 §Decision 的顺序处理。

### ④ 归档(原生缝齐全,可搭 `workspace.list` 这趟车)

- `workspace.archiveSession` / `unarchiveSession`
  (`packages/api/workspace-controller/src/index.ts:154-166`),
  基线带 `archivedSessionIds`(`feed.ts:75`)。
- 原型基线有归档(`mock/proto/index.html:486` 底栏 + `app.js:286-329` 左滑归档);
  手机现在是 `_notYet('归档列表')` 空桩(`app/lib/main.dart`)。
- 抽屉底栏五项(文件/归档/演示/自动化/设置)**都不是编的**:原型基线全有
  (`index.html:484-493`),DSH 各有原生缝;手机全是桩。

## C. 已修过的 bug 模式(盯第四处)

**两个真值源**是这轮反复出现的病根,已修三处;看到第四处按同一招处理
(让第二处读第一处,不是再加分支):

1. 标题:列表走 `displayTitle`,顶栏走本地推导 → 统一成一条链。
2. 任务归桶:手机猜 `_jobs.keys.last` → 连接器在帧上盖 `sid`。
3. 统计:手机自己算一套公式 → 与 Web 逐字一致(引用源码行号)。

回归钉子(勿删):`app/test/job_panel_test.dart` 的「帧带 sid 就按 sid 归桶」
(做过变异校验:`keys.last` 一回去它就红)、
`app/test/session_list_wiring_test.dart` 的「标题只有一个真值源」两条。

## D. 环境与坑

- **开工前先起服务**:test profile 与中继都会退后台,会话一切换就可能掉。
  掉了的症状是手机报"连接被拒绝"(`relay/offline`)并开始退避 —— 那是**正确行为**,
  别误判成 bug。起法:
  `node <npx 缓存>/@deepseek-ai/dsh/lib/bin.js --profile dsh-mobile-test --no-open --port 8099`
  (**别用用户日常的 19387**);`cd relay; node src/main.ts --config relay.config.json`(8787)。
  本会话收尾时两者都已停(8099 / 8787 无监听),新会话要自己起。
- **动 Flutter UI / 手势 / 布局前,先 `node app/tools/flutter-api.mjs <符号>` 查本机 SDK 源码**
  (项目军规新增的一条:`Flutter 行为不许猜`,引用写 `packages/flutter/lib/src/...:行号`;
  查不到按 `tools.md`「Flutter 行为查证」那张表的顺序继续,最后才是真机实测)。
  本轮四条全都要动 UI,所以这条会一直被用到。
- 连接器改了 `src/` 必须 `cd connector; pnpm build`(插件加载 `lib/index.js` 的 junction),
  再重启 profile。
- 真机:`adb install -r` 后 `adb shell monkey -p com.example.dsh_mobile -c android.intent.category.LAUNCHER 1`。
- **`adb reverse tcp:8787 tcp:8787` 不随 USB 重插保留** —— 掉了手机报"连接被拒绝"。
- **`adb shell input tap` 点不开会话行 / chip**,但 `input swipe` 能滚列表、☰(60,128)能开抽屉。
  "chip 有没有出现"这类验证要么先解决驱动方式,要么明确说"未验证"——
  **不许把成本转嫁给用户**。
- 管理面要浏览器 cookie:开 `http://127.0.0.1:8099/?token=<启动日志里的>` 再在页内 fetch。
- `ctx.logger` 到不了 CLI stdout,`console.error` 可以(连接器里已留探针)。
- 中继名册是**全量快照**(差集即删除),别改回 append-only(2026-10-15 事故)。

## E. 提交纪律

- 改 `connector/src/**` → tsc + build + test;改 `app/lib/**` → 边界校验。
- 非平凡改动留决策笔记(`implemented/`),代码与笔记同批提交;被约束的代码入口留一行注释回指。
- 每轮结束报"做了什么 / 门禁数字 / **没做到什么(说清原因)**"。
