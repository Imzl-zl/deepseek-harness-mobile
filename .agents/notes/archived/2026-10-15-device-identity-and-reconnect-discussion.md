# 新会话提示词:设备身份生命周期 + 重连出路 + 管理面(方向已定,落地待设计)

> **已被取代(2026-10-15)**:四个议题已全部落地。结论分别记在
> `.agents/notes/implemented/2026-10-15-new-identity-per-pairing-is-intentional.md`、
> `.agents/notes/implemented/2026-10-15-connection-terminal-failure-goes-to-pairing.md`、
> `.agents/notes/implemented/2026-10-15-device-admin-face-dsh-house-style.md`;
> 事故复盘在 `docs/postmortem/2026-10-15-offline-batch-hard-delete-nuked-own-phone.md`。
> 本篇结论不改,移入 `archived/` 冻结。

> 用法:新开一个会话,把下面「提示词」整段贴进去。四个议题的**方向已由用户拍定**,
> 这一轮的任务是把方向落成设计与代码,**不要重新讨论方向**。
> 行号于 2026-10-15 逐条核对过;动过代码后会漂,引用前顺手核。

---

## 人话版(给非技术读者)

**背景**:手机 App 要连电脑上的 DSH,靠"配对"——电脑上出一个二维码,手机扫一下,双方认亲。
为了安全,手机里存一把**身份钥匙**,电脑那边按这把钥匙记一台"设备"。之后每次重连都靠这
把钥匙相认。

**议题 1 —— 钥匙要不要只用一次?**
现在的设计:每扫一次码,手机就换一把新钥匙。所以反复重连会在电脑上留下多条"我的手机"
记录(实测攒了 31 条),而电脑规定最多 8 台、却从来没代码检查过。
用户拍定:**保持现状,不改成"一把钥匙用一辈子"**。理由:禁用(停用)一台设备就应该是终态,
恢复了就重新扫、换把新钥匙;"能换钥匙"本身就覆盖了"钥匙泄露了要更换"的场景。
**用户主动重配导致记录变多,是用户自己的事;设计有问题,才是我们的事。**
⇒ 本轮议题 1 基本不改代码,只做两件事:把契约里"最多 8 台"那个假门禁改成如实描述
(**不设上限**——记录增加是用户自己的事),以及把"为什么这么定"落成决策笔记。

**议题 2 —— 连不上时,手机只知道转圈**
设备被停用/删除后,手机就一直显示"重连中…",不告诉用户为什么,也不给出路。规范里其实
早就写了"这种情况该清掉凭据、跳配对页让用户重新扫码",但**一行代码都没实现**。
用户拍定:**只改手机**——身份不被认时,清掉凭据、跳到配对页、写明"这台电脑不再认本机了,
请重新扫码"。(不改协议:改协议要动契约和中转,代价大,而用户要做的动作一样。)

**议题 3 —— 用户找不到重新扫码的入口**
用户原话:"我就没看到手机有重新配对。" 查清了:聊天页上没这个入口,唯一的路藏在侧边抽屉
里,要点 3 步。用户拍定:**任何界面下,最多 2 步必须能走到"重新配对"**。

**议题 4 —— 电脑上的设备管理页缺能力**
用户原话:"可以吊销也可以删除啊,要不然你一直放在那干啥？？最好就是禁用也可以解禁删除,
可以多选删除单个删除。" 即:**停用(可逆)+ 解禁 + 删除(硬删,支持单选和多选)**。
用户要求:**按 DSH 插件开发规范来做,设计做优雅**。规范与先例的权威记录已在本仓
(`docs/plugin-and-jobs-notes.md` 的 A.6/A.8/C 节,以及笔记
`2026-10-15-permission-switch-through-dsh-two-doors.md`)——先读它们,别重新推导。

**外加那次事故**:31 条记录被清掉,真因不只是脚本误点——那个按钮按"当前离线"**批量硬删**,
而用户当时正在排查"断开后一直重连",他的手机正是离线态,这个筛选条件专门命中这种状态;
确认文案还写成了"已吊销记录"(实际删的是离线记录),也没说"那台手机需要重新配对"。
这轮一起修:去掉这个批量按钮、确认对话框改页面内且必带后果、补一篇事故记录。

---

## 提示词(整段复制)

我们在做 dsh-mobile —— DSH 的移动端客户端。核心原则:**DSH Web 上能看的每一个面,
背后都有 `@Remote` 方法或会话投影;接线是照形状透传,不是重新设计。**

### 已定方向(2026-10-15 拍定)

| 议题 | 方向 | 代价 / 意味 |
|---|---|---|
| 1 设备身份 | **不持久化,保持现状**:每次配对(扫码)生成新身份;停用=终态,恢复=重新扫码换新身份 | 记录会随用户主动重配而增加——这是用户行为,不是设计缺陷,不为它改身份模型。本轮议题 1 基本不改代码 |
| 2 失效后手机 | **只改手机侧**:清凭据 + 跳配对页 + 可读提示,**不动协议** | 手机区分不了"被停用 / 令牌失效 / 中转不认";三者恢复动作相同,可接受 |
| 3 重连态 UI | **任何状态下用户两步内走到"重新配对"**,写不成断言不算做完 | 现状 3 步;UI 基线是 `mock/proto/` + `docs/design-and-tech-plan.md`,**不是 DSH**(DSH 没有手机端) |
| 4 管理面 | **停用(可逆)+ 解禁 + 删除(硬删,单选 + 多选)**,按 DSH 插件开发规范做、设计做优雅 | 多选是对插件页 house style 的有意偏离,要写明"偏离 + 原因" |

**一条判别原则(用户原话"你设计有问题就是你的事啊")**:用户主动行为导致的累积
(反复重配留下记录)照常接受;设计缺陷(标签骗人、找不到入口、规定了却不实现、上限没人管)
必须修。动手前先分清自己在修哪一类。

### 已查证的事实(2026-10-15 核对,先读代码复核再往下)

1. **devId 算式两端一致**:`base64url(sha256(utf8(devPubDhHex)).slice(0,16))`
   —— 手机 `app/lib/core/pairing.dart:137-140`;电脑 `connector/src/pairing.ts:88-91`
   (`deviceIdOf`,注入点 `:130`)。**devId 完全由设备的 X25519 静态 DH 公钥决定。**
2. **每次扫码都生成新主种子**:`app/lib/ui/pairing_page.dart:198`
   (`toHex(randomBytes(32))` → `deriveIdentity`)。注释原话:"主种子此刻只在本页内存里,
   确认并配对成功之后才进系统安全存储"。⇒ **devId 每次必然不同**,写进去的必然是新行。
3. **`putDevice` 是唯一新增设备的路径**(`connector/src/index.ts:412`、`:434-444`);
   本地凭据是**单槽覆盖**(`app/lib/main.dart:139-173`、
   `app/lib/platform/pairing_store.dart:264-296`)。重新配对同一台电脑与配对另一台电脑
   现在被混成一条路;旧行留在表里(离线、未停用、永不被回收)。
4. **`putDevice` 写的行不带 `revokedAt`**(`index.ts:438-444`),同 devId 的 put 是整行覆盖
   ⇒ 只有"身份持久化"方案下重新配对才会自动解吊销。**该方案已否决**,所以现网里停用行
   永远停在那,复活一台设备的唯一途径是管理面解禁——这正是议题 4 要补的能力。
5. **8 台上限没有任何代码 enforce**:契约 `docs/subsystems/remote-channel.md:706`
   写"每电脑 8 台",全仓无 MAX_DEVICES 检查。管不管、怎么管,是议题 1 剩下的唯一决定。
6. **手机被拒的真实失败点在换票,不在握手**:设备行不在名册里(`publishDevices` 过滤
   revoked,`index.ts:407`)→ 手机 `/ws-ticket` 拿 401,body 只有 `{error:'unauthorized'}`
   (`relay/src/http-face.ts:61`;`relay/src/issue-token.ts:89` 原话:"将来可以把'你被吊销了'
   与'这个令牌没见过'分开告诉设备 —— 今天两者都是 401")→ `app/lib/core/pairing_client.dart:80`
   映射成 `notPaired` → `app/lib/platform/ticketed_transport.dart:65-69` **把错误码丢掉**,
   只抛 `TransportException('换票失败：换票被拒（HTTP 401）')`。
7. **"回配对页"这个动作规定了两处、实现为零**:契约 §11 故障矩阵(`remote-channel.md:725`)
   与手机错误表(`app/lib/core/errors.dart:92-93`,`notPaired`/`revoked` → `ClientAction.rePair`)。
   `ClientAction` 在 `app/lib` **没有任何消费者**,`ErrorCode.revoked` 一次都没被构造过。
   握手层的 `protocol/not-paired`(`connector/src/protocol/handshake-driver.ts:164`)只是名册
   陈旧时的兜底:它只以 WS close 4003 + reason 到达,**没有协议帧带它**;契约的
   `protocol/revoked` 连接器**从不发**(`:76-80` 有意把三种情况合并)。
8. **重连态出口的真实现状(可静态回答,不必真机复现)**:ChatPage **没有**出口 ——
   顶栏状态位点击在已配对时开侧栏(`app/lib/ui/chat_page.dart:554-560`),空态
   「连电脑(配对)」按钮只在 `!paired` 时出现(`:1534`)。唯一出口是抽屉连接行
   (`app/lib/main.dart:276-283` → `:294` → 「重新配对（换一台电脑）」`:309`),
   从 ChatPage 数要 **3 步**(汉堡 → 连接行 → 重新配对)。用户原话:"我就没看到手机有重新配对。"
9. **管理面现状**(`connector/client.js`):单台「吊销」(软,`revoke`)/「删除」(硬,
   `remove`),底部按状态一键清(`removeScope('offline'|'revoked'|'all')`,`:440-465`),
   已吊销默认折叠(`:430-437`)。**没有解禁端点**,停用是单向的。
   `revokeAllOffline` 端点(`connector/src/index.ts:583-600`)在 UI 里**没有任何调用者**
   (死代码)。三个破坏性按钮全部走 `window.confirm`。

### 议题 4 的规范依据(先读本仓,别重新推导)

connector 是一个 DSH 插件,设备面板是它经 slot 贡献进 DSH「插件」页的 UI。插件开发规范与
先例的权威记录已在仓内:

- `docs/plugin-and-jobs-notes.md` —— A.6(插件 UI = 浏览器里的 React 组件 + slot 注册,
  无服务端渲染)、A.8(`ui-plugin-manager` 是操作台 + 配置页宿主)、C 节(插件页为何无法
  通用渲染)
- `.agents/notes/implemented/2026-10-15-permission-switch-through-dsh-two-doors.md` ——
  本插件 UI 为何走 Slots、为何手写 `client.js`、为什么不 require Harness Client 包

**手机端是手机端的事**:议题 2/3 只按 `app/` 的基线(`mock/proto/` +
`docs/design-and-tech-plan.md`)走,不掺 DSH 源码;DSH 只约束议题 4。

**本次要守住的设计格调(housestyle,逐条对应插件页的既有做法)**:

1. **可逆停用是一对布尔端点,不是两个动作**:先例 `setBundleEnabled(name, enabled)`
   (`packages/boot/plugin-manager/src/index.ts:458,476`)。
2. **文案用「启用 / 停用」,不自造词**:先例
   `packages/client/ui-plugin-manager/src/client/locales.ts:57,199-201`;状态词
   「未运行 / 已停用」。**底层字段与协议仍叫 `revokedAt` / `protocol/revoked`,不改名**
   (形状透传原则)——变的只是界面文案。
3. **硬删必须过页面内的命名确认对话框,不用 `window.confirm`**:先例 `locales.ts:196-198`
   (标题问句 + 一句后果 + 确认键)与 `manager-store.ts:286-288,666-671` 的
   `pendingConfirm`。本面板按 `client.js:36-40` 的约束手画 + `--dsw-alias-*` token。
4. **失败必须带原因显示**:`停用失败：{reason}`(`presentation.ts:63-70`)。
5. **拒绝要有码 → 句子**:`presentation.ts:48-61` 的 `CODE_KEYS` 把每个拒绝码映射成一句人话。
6. **结果分「立即生效 / 需要重启」**:`ChangeResult.application:
   'applied' | 'restart-required'`(`manager-store.ts:659`)。停用一台设备对那台手机等于
   "下次重连即失败",这个后果必须写进确认文案。
7. **不留死代码**:`revokeAllOffline` 端点没有调用者——接上或删掉。
8. **多选是对 house style 的有意偏离**(插件页逐行开关 + 逐个确认,无多选):按项目规则在
   `docs/design-and-tech-plan.md` 写明"偏离 + 原因"。
9. **入口 slot 的备选**(`ui-plugin-manager/src/client/slot-contract.ts:86-134`):
   `plugins.bundle.config`(现状)/ `plugins.detail.section` / `plugins.detail.actions`;
   契约注明 detail contribution 跟着打开页的主题渲染、自己决定要不要渲染。放哪这轮定,引契约。

### 2026-10-15 事故(先读这段再动手)

真机排查时,`chrome-devtools` 的 `evaluate_script` 有个 `dialogAction` 参数**默认 accept**,
脚本点到「清掉当前离线（31）」,`window.confirm` 被自动接受。**31 条设备记录被硬删除
(不是停用)**——`~/.dsh/storages/dsh_mobile_core.json` 的 `devices` 表现在是空的
(删除抹行;停用只标 `revokedAt`、行还在)。含用户那台(当时离线)。

**标签没有撒谎,真正的问题是三件**:

1. **按"当前离线"批量硬删,圈进的正是用户自己的手机**。用户当时在排查"断开后一直重连",
   他的手机就是离线态 —— 这个按钮的筛选条件专门命中这种状态;服务端跳过"在线"保护不了它。
2. **确认文案张冠李戴,且不说后果**:`confirmCleanRevoked`「真删除 {n} 条**已吊销**记录？」
   被用在删**离线(未停用)**记录上;而按钮都没说"那台手机需要重新配对"
   (DSH 的 `confirmUninstall` 是连后果一起说的:`卸载后它提供的功能会消失。`)。
3. **破坏性操作走 `window.confirm`**:浏览器原生对话框,`chrome-devtools` 能自动 accept。

⇒ 本轮:① **去掉"按当前离线批量硬删"这个按钮** —— 它的人口专门命中"暂时离线但还在用"的
   设备,要删具体的几台用多选;② 确认对话框改成页面内 + 逐动作正确文案 + 必带后果;
   ③ 在 `docs/postmortem/` 补一篇事故记录。

### 四个议题(方向已定,这轮做设计与落地)

**议题 1:设备身份生命周期 —— 本轮基本不改代码**

已定:不持久化,每次配对新身份是正常设计。剩下三件事:

- **不设上限(已定)**:契约 §10 那行"设备上限 | 每电脑 8 台"(`remote-channel.md:706`)
  从来没有代码 enforce,而硬拒第 9 台会把用户锁在门外、与"重配是正常恢复路径"冲突。
  记录随用户主动重配而增加是用户自己的事,清理归管理面。
  ⇒ **先把契约那行改成如实描述**(与文档冲突时先改文档再改代码;`docs/AGENTS.md`
  去废话守则:只记当下事实,不写"以前如何")。建议改成:
  `| 设备上限 | 不设上限 | 每设备一把密钥 ⇒ 停用粒度小;重新配对即新身份,记录随主动重配增加,清理走管理面 |`
  `tools.md` / `memory.md` 里若有同一个数字,同步。
- **落一篇决策笔记**:为什么"每次配对新身份"是有意设计(停用终态 + 重扫换新覆盖泄露场景
  + 用户主动累积照常接受),以及被否决的方案(主种子持久化)及其代价。
- 顺带核对:单槽覆盖(`pairing_store.dart:264-296`)在新模型下有没有坑(换电脑重配会覆盖
  旧电脑凭据——旧电脑那行变成孤儿记录,只能管理面清理)。

**议题 2:设备失效后手机的动作**

已定:只改手机侧,不动协议。要设计:

- 换票被拒(401/409)时:清凭据 + 跳配对页 + 明说"这台电脑已不再认可本机(已停用或凭据失效),
  请重新扫码"。**不假装知道是哪种原因。**
- 与"网络断了"区分:退避重连只留给网络类失败;`notPaired` 是一次性终态,不进退避。
- 诊断面照实显示(`app/lib/data/app_model.dart:454-477` 的 `connectionDiagnosis` 已把
  close code/reason 显示到空态),但别把裸 401 当成人话。
- 验收:构造"行被删 / 行被停用"两种存储状态,断言手机清凭据并落到配对页,而不是继续退避。

**议题 3:重连态的 UI 出路**

判据(已定):**任何状态下用户都能在两步内走到"重新配对"**,写不成断言不算做完。
现状 3 步,差的一步在这轮补。候选落点:连接状态行常驻可点 / 空态在 `paired` 时也给出口 /
重连失败 N 次后给出入口。落点这轮定,断言照判据写。
**UI 基线是 `mock/proto/` + `docs/design-and-tech-plan.md`**(DSH 没有手机端,别去 DSH 找)。

**议题 4:管理面(电脑侧插件面板)**

已定:停用可逆、要能解禁、删除支持单选 + 多选;交互与文案照 DSH 插件管理器范式。要设计:

- **端点形状照 `setBundleEnabled`**:一个布尔(或把现有 `revoke(devId)` 扩成
  `setEnabled(devId, enabled)`),停用与解禁是同一个动作的两个值,不是两个端点。
  解禁 = 清 `revokedAt` + 重报名册(`index.ts:579` 是唯一写停用处,照它对称着写)。
- **文案对齐 DSH**:「停用 / 启用 / 删除」,状态词「运行中 / 未运行 / 已停用」;
  底层字段与协议仍叫 `revokedAt` / `protocol/revoked`,不改名。
- **确认对话框照 `confirmUninstall` 的形状**:标题问句 + 一句后果 + 确认键;
  停用要写明"那台手机下次重连就会失败";删除要写明"那台手机需要重新配对";
  多选批量删要给规模("真删除这 3 台?在线的 1 台会跳过")。**不用 `window.confirm`**,
  按 `client.js:36-40` 的约束手画 + `--dsw-alias-*` token。
- **失败与拒绝照 DSH**:`停用失败：{reason}`;拒绝码 → 一句人话(照 `CODE_KEYS`)。
- **多选**:行首 checkbox + 顶部浮现操作栏,或"编辑模式"切换——二选一并说清为什么不选
  另一个;同时按项目规则在 `docs/design-and-tech-plan.md` 写明这是对 DSH 范式的有意偏离
  (插件管理器逐行 + 逐个确认,无多选)+ 原因(用户要"挑几台删")。
- 与"按状态一键清"的分工:哪些场景多选真的更快;31 行的翻页与"全选"要不要。
- **去掉"按当前离线批量硬删"那个按钮**(它命中"暂时离线但还在用"的设备,2026-10-15 事故
  就是它);`removeScope` 的 scope 随之收成 `'revoked' | 'all'`,要删具体的几台用多选。
- 顺手处理:`revokeAllOffline` 死端点(接上或删掉);入口 slot 是否从 `plugins.bundle.config`
  挪走(引 `slot-contract.ts`)。

### 硬规则

1. **Web 调哪个,手机就调哪个。** 拿不准先读 `packages/client/ui-*/src/client/*.ts`。
   找不到就写「未找到」,禁止"通常如此"。
2. **形状逐字透传**:不挑字段、不改名、不补默认值、不猜默认值。
3. **引用行为给 `文件:行号`**;行号会漂,动代码后顺手核。引用 DSH 行为必须给
   `packages/...:行号`;DSH 参考源码在 `D:\sudy\github\deepseek-harness`(只读)。
4. **标签、注释、代码必须同义**:一个操作在三处说法不一致 = 缺陷(2026-10-15 事故的真因)。
   改行为必须同批改三处。
5. **破坏性操作走页面内确认对话框,不用 `window.confirm`**(照 DSH `confirmUninstall`);
   真机/浏览器自动化点破坏性按钮前必须显式 `handle_dialog(dismiss)`。
6. **对 DSH 范式的有意偏离必须写明**:"偏离 + 原因"写进 `docs/design-and-tech-plan.md`,
   不静默偏离。
7. 结论落 `.agents/notes/`(状态由目录位置决定);本篇在 `proposed/`,落地后随代码移
   `implemented/`。
8. 改完跑门禁:`connector` 侧 `pnpm exec tsc --noEmit` / `pnpm build` / `pnpm test`
   (fixtures 断言 = 486、向量 = 49);`app/` 侧 `flutter test` +
   `node app/tools/verify-platform-boundary.mjs`;动了 `mock/proto/` 跑对应 `verify-*.mjs`。

### 参考

- DSH 文档:[架构总览](https://deepseek-harness.github.io/deepseek-harness/reference/)、
  [第一个插件](https://deepseek-harness.github.io/deepseek-harness/develop/basic/);
  DSH 源码(只读)`D:\sudy\github\deepseek-harness`
- DSH 范式出处:`packages/client/ui-plugin-manager/src/client/{locales.ts,slot-contract.ts,
  presentation.ts,manager-store.ts}`、`packages/boot/plugin-manager/src/index.ts`
- 契约:`docs/subsystems/remote-channel.md` §5.7(停用语义,`:386`)、§8.1(电脑侧 schema,
  `:601`)、§10(参数表 / 设备上限,`:706`)、§11(故障矩阵,`:725`)、§12.1(配对流程,`:748`)
- 决策笔记:`.agents/notes/implemented/2026-10-01-connector-identity-home.md`、
  `2026-10-02-pairing-bootstrap-and-device-binding.md`、
  `2026-10-15-permission-switch-through-dsh-two-doors.md`(插件 UI 为何走 Slots、为何手写
  `client.js`)
- 门禁基线:`tools.md` / `memory.md`

---

## 附:这一轮之前已经落地的东西(别重做)

- 权限切换:`permission.catalog`(读 DSH `permissionPresets.catalog()`)+ `permission.switch`
  (写 DSH `/permission <档位>` 命令);手机上三档手抄枚举已删
- 投影信封 bug:连接器曾把 DSH 的 `{kind,asOfSeq,values}` 原样透传,导致手机侧
  `tokenUsage`/`permissions`/`subagentCatalog` 全部取不到
- 后台任务接线:`job.list`/`job.follow`/`job.unfollow`/`job.kill`,假示例数据已删
- 插件 UI:`connector/client.js` 手写 `window.__ModuleLoader__.load` 闭包工厂,注册
  `plugins.bundle.config` slot,渲染在 DSH「插件」页本组合包详情页
- 管理面四个 RPC:`/api/dsh-mobile/{status,pair,revoke,devices/remove}`
- 设备清理:单台停用/删除、按状态一键清、已停用默认折叠
- 构建环境:`local.properties` 的 `sdk.dir` 与 `flutter config --android-sdk` 曾指错
