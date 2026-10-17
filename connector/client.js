/**
 * 连接器的**浏览器半侧**：DSH Web GUI 里「手机」入口的管理弹框。
 *
 * ## 为什么是手写的，而不是 TS + 打包
 *
 * DSH 的 client bundle 必须是 `window.__ModuleLoader__.load({id, factory})` 这种
 * **闭包工厂**格式（`client-modules/src/client/manifest.ts:10`），React 从浏览器的
 * 模块表 `require` 进来（不装第二份、不走 CDN、不 UDU 探测）。
 * 产出这种格式的共享 tsdown 预设（`packages/client/tsdown.client.ts`）在 DSH 仓库里，
 * 依赖 lightningcss 与仓库内相对路径 —— 我们是不在 DSH workspace 的独立工程，用不了它。
 *
 * DSH 的插件开发技能因此提供了一条**手写**的第一等路径
 * （`templates/decoration/client.js` 就是手写的），本文本走那条。
 * 代价是这一份没有类型检查，所以它**刻意薄**：所有判断都在电脑侧
 * （`src/admin/routes.ts` 与 `src/admin/device-admin.ts` 有单测），
 * 这里只做「fetch 端点 → 渲染」。
 *
 * ## 入口是哪个 slot（2026-10-17 从插件页卡迁到侧边栏弹框）
 *
 * 用户原话：「我之前不是说不要插件列表这个 UI？要左侧边栏的入口的弹框 UI……
 * 你就在插件下面，工作区上面啊？点击弹框多方便？？还有这个位置别的插件可能
 * 也会占，所以你不能硬编码，要规范，标准啊」。
 *
 * 所以走两个**标准槽**，一个字节的位置都不硬编码：
 *
 * 1. `sidebar.panellist`（列表槽，`ui-sidebar/src/client/index.ts:83` 声明）——
 *    **order 5**：插件（`ui-plugin-manager` 的 order 0）之下、自动化任务
 *    （`ui-schedule` 的 order 10）之上，而面板列表整体在工作区树上方，
 *    于是正是"插件下面、工作区上面"。别的插件照样往这个槽注册、各自排序。
 * 2. `main`（keyed 槽，`ui-layout/src/client/index.ts:73`）—— 同一个 id 的
 *    主面板，内容画成**弹框**（`createPortal` 挂 body，点遮罩/Esc 关 =
 *    `ctx.layout.selectPanel(null)`）。
 *
 * 原来的 `plugins.bundle.config`（插件页组合包详情卡）**已撤**：用户明确不要
 * 那个入口，而同一个管理面不该有两个家。
 *
 * ## 为什么 `dsh.client` 不列 `inject`
 *
 * `inject` 的语义是"**我的 bundle 物化前，哪些包的 factory 必须先到位**"
 * （`client-modules/src/client/manifest.ts:47-48`），**不是** cordis 的服务依赖 ——
 * 后者在本文件底部 `exports.inject = ['slots', 'locale', 'layout']`。
 * 本 bundle 只 `require('react')` 与 `require('react-dom')`，而它们在
 * `client/web/src/platform.ts:8-9` 的 `PLATFORM_MODULES` 里，是 shell 共享进冻结
 * 模块表的**基线外部**，白拿。所以一个模块表 inject 都不该列。
 * （第一版列了 `dsh-client-ui-plugin-manager`，理由是"我要往它的 slot 注册"——
 *  **那是服务依赖，不是模块表依赖，猜错了**。）
 *
 * ## 为什么不要 require Harness Client 包
 *
 * `references/practices.md:35` 的原话：它们变来变去、plain-JS 没有类型检查，
 * 而一个抛错的组件会让整个 slot 条目变白（console: `slot entry crashed in '<slot>'`）。
 * 所以控件自己画。**样式只引用 `--dsw-alias-*` token**（同一条 practices 的约定：
 * "Tokens then remain the only shared styling dependency"），
 * token 定义在 `ui-theme/src/styles/design-platform.css`。
 *
 * ## 面板怎么排
 *
 * 按操作者的任务频率自上而下：
 *
 * 1. **状态**（最高频："我的手机连上了吗"）—— 连接态 + 在线台数 + 拨向哪条路；
 *    其下是**传输方式**：每条通道一个开关 + 「全部启动/全部停止」（2026-10-17
 *    用户：「不是有两中方式为啥就一个开关」）。通道列表来自 `GET /transport`，
 *    加新方式自动长一行；
 * 2. **设备**（"管理"）—— 在线的排最前；每行动作是**停用 / 启用**（可逆，一对布尔，
 *    照 DSH `setBundleEnabled(name, enabled)`）+ **删除**（硬，抹掉行）；多选走行首
 *    checkbox 与顶部浮现栏；已停用默认折叠；底部按状态清（只剩"已停用 / 全部"）；
 * 3. **配对新手机**（最低频）—— 出码 + 二维码 + **倒计时**（到期自动清）。
 *
 * 顺序的依据：看一眼状态 > 偶尔管理 > 极少配对。把配对放最上面会让
 * 90% 的访问先看到一张和自己无关的二维码。
 *
 * ## 词汇：界面说「停用 / 启用 / 删除」，底层仍叫 `revokedAt`
 *
 * 照 DSH `locales.ts:199-201` 的 `启用 / 停用 / 删除` 与 `:63` 的状态词
 * `未运行 / 运行中`、`:46` 的 `已停用`。**字段与协议一个都没改名** ——
 * 服务端行的 `revokedAt`、状态里的 `revoked` 布尔都照旧（形状透传原则），
 * 变的只是操作者看到的词。
 *
 * ## 破坏性操作：页面内 DOM 对话框，不用 `window.confirm`
 *
 * 2026-10-15 事故：`chrome-devtools` 的 `evaluate_script` 有个 `dialogAction`
 * 参数**默认 accept**，脚本点到「清掉当前离线（31）」，`window.confirm` 被自动
 * 接受，**31 条设备记录被硬删除**（含用户自己那台 —— 他当时正在排查重连，是离线态）。
 * 原生对话框挡不住自动化，页面内的才挡得住。
 *
 * 对话框的形状照 DSH `confirmUninstall`（`PluginManagerPage.tsx:1367-1390`）：
 * 标题问句 + 一句后果 + 确认键，样式只用 `--dsw-alias-*` token 自己画。
 * **逐动作文案必须对上新行为**：事故里确认框写"已吊销记录"而实际删的是离线记录，
 * 这种张冠李戴不允许再出现 —— 所以每处的后果句都写清"到底会发生什么"。
 *
 * ## 多选为什么是"浮现操作栏"，不是"编辑模式"
 *
 * **有意偏离 DSH 插件管理器范式**：那边是逐行开关 + 逐个确认、**没有多选**
 * （`manager-store.ts:650-681` 只有 `setRowEnabled` 与 `uninstall` 两个行级动作）。
 * 偏离的理由：用户原话"最好就是禁用也可以解禁删除，可以多选删除单个删除"——
 * 真机联调会攒下几十行"配对过、连过一次、再没连过"的记录，挑几台删是真实场景。
 *
 * 而**不选"编辑模式"切换**：多选是**临时动作**（挑完就删、删完就散），
 * 模式切换会改变整个列表的交互语义 —— 进编辑态后每行首当其冲的是勾选框而不是
 * 名称，行级按钮的语义也要跟着收起来，用户为了删两台要先切换再切回。
 * 浮现栏挂在列表顶部、只在有勾选时出现，**不改变行本身**：没勾选时列表与
 * 单行操作一模一样，勾选后多出的只是一个"已选 N 台 / 删除所选 / 取消"。
 *
 * ## 在线的设备：按状态清绝不碰，显式点名可以删
 *
 * 服务端按**形状**判（`device-admin.ts` 不变量 2）：
 * - `scope: 'revoked' | 'all'`（按状态清）**绝不碰在线的** —— 它的人口是隐式的
 *   一整类，2026-10-15 事故的危险正来自隐式人口。跳过的台数由 `skippedOnline`
 *   报回来，所以按状态清的确认句必带"在线的 {s} 台会跳过"。
 * - `devIds`（显式多选 / 单台）**可以删在线的** —— 操作者指着某一行、逐个勾的，
 *   意图无歧义。手机丢了还在线，要立刻弄死它，为此先"让那台手机断开连接"是荒谬的。
 *   所以显式删除的后果句**不提"跳过"**，只说明白"删了会怎样"。
 *
 * ## 失败必须带原因
 *
 * 照 DSH `presentation.ts:63-70` 的 `停用失败：{reason}` / `启用失败：{reason}` /
 * `删除失败：{reason}`。静默的失败会让人以为按钮坏了，比报错更难排查。
 * 提示行放在**面板顶部**：停用失败了，消息却出现在最下面那张配对卡上，用户不会往那儿看。
 */
window.__ModuleLoader__.load({
  id: '@dsh-mobile/connector',

  factory(require) {
    const React = require('react')
    // `react-dom` 在平台的 PLATFORM_MODULES 里（`client/web/src/platform.ts:9`），
    // 与 react 同级的基线外部 —— 弹框用它挂到 body（主面板是根级区域，
    // 不会被带 transform 的祖先带跑）。
    const ReactDOM = require('react-dom')
    const h = React.createElement
    const { useCallback, useEffect, useRef, useState } = React

    const STATUS = '/api/dsh-mobile/status'
    const PAIR = '/api/dsh-mobile/pair'
    const TRANSPORT = '/api/dsh-mobile/transport'
    const ENABLED = '/api/dsh-mobile/devices/enabled'
    const REMOVE = '/api/dsh-mobile/devices/remove'

    /** 侧边栏条目与主面板共用的 id（标准槽用字符串键，不 branded）。 */
    const PANEL_ID = 'dsh-mobile'

    const NS = 'settings.dshMobile'
    const zh = {
      title: '手机连接',
      // 侧边栏入口（`sidebar.panellist`，order 5：插件 0 之下、自动化任务 10 之上）。
      // 走标准列表槽、带 order —— 不硬编码位置，别的插件同样注册进来各自排序。
      entry: '手机',
      // 传输面**按方式分开关**（2026-10-17 用户：「不是有两中方式为啥就开关？
      // 后面我要是再加新的方式也就一个开关吗？」）。每个通道一个开关，
      // 加新方式时这个列表自动变长（数据来自 GET /transport），不为它改形状。
      transportTitle: '传输方式',
      allStart: '全部启动',
      allStop: '全部停止',
      channelRunning: '运行中',
      channelStopped: '未运行',
      channelStart: '启动',
      channelStop: '停止',
      failedChannel: '{action}失败：{reason}',
      transportNote: '两条通道各自独立：停一条不碰另一条。停传输不清凭据、不动身份，再启动不用重扫。',
      close: '关闭',
      pairedAt: '配对于',
      // **重新配对 = 换凭证、替换旧行**（2026-10-17 用户："为啥每次扫都是一个
      // 新设备"）：手机重新扫码时自报旧 pairingId，电脑侧按它替换同一行
      // （换密钥/换令牌，配对于保留首次时刻）。首配（没有旧行）才写新行。
      // 取舍：.agents/notes/implemented/2026-10-17-repair-replaces-device-row.md
      pairNote: '同一台手机重新扫码会替换它在这台电脑上的旧记录（换新密钥与新令牌，配对于保留首次配对的时刻）—— 记录不再随重配攒行；换一台手机或首次配对才会新增一行。',
      // 连接态（桥接拨通了吗）与设备态（这台在跑吗）是两问，用词因此不同：
      // 前者答"我的手机连上了吗"，后者照 DSH 的状态词（`locales.ts:54,63`）。
      online: '在线',
      offline: '离线',
      running: '运行中',
      idle: '未运行',
      foreground: '前台',
      background: '后台',
      disabled: '已停用',
      neverSeen: '从未交互',
      justNow: '刚刚',
      minutesAgo: '{n} 分钟前',
      hoursAgo: '{n} 小时前',
      daysAgo: '{n} 天前',
      // 界面词：停用 / 启用 / 删除（DSH `locales.ts:199-201`）。
      disable: '停用',
      enable: '启用',
      remove: '删除',
      removeSelected: '删除所选',
      selectedCount: '已选 {n} 台',
      cancel: '取消',
      cleanRevoked: '清掉已停用记录（{n}）',
      clearAll: '清空全部记录（{n}）',
      showRevoked: '已停用 {n} 台 · 展开',
      hideRevoked: '收起已停用',
      pair: '出配对码',
      pairing: '出码中…',
      scanHint: '用手机 App 的「扫一扫」扫它',
      expiresIn: '{t} 后过期',
      expired: '二维码已过期，重新出码',
      noDevices: '还没有设备配对过。',
      loadFailed: '读取失败',
      // ---- 确认对话框：标题问句 + 一句后果 + 确认键（照 DSH `confirmUninstall`）----
      // **后果句逐字对上新行为**：2026-10-15 事故里确认框写"已吊销记录"而实际删的
      // 是离线记录。这里每一处都写清"到底会发生什么"。
      confirmDisableTitle: '停用「{name}」？',
      confirmDisableDescription: '那台手机下次重连就会失败,需要重新配对才能恢复。记录仍会保留。',
      confirmRemoveTitle: '删除「{name}」？',
      confirmRemoveDescription: '那台手机需要重新配对。',
      // 显式删除**可以删在线的**（见文件头），所以在线那台不是"不会删除"，
      // 而是"它在用，删了就得重新配对"——"跳过"只属于按状态批量。
      confirmRemoveOnlineDescription: '这台在线,正在使用。删除后它需要重新配对。',
      confirmRemoveSelectedTitle: '删除所选的 {n} 台设备？',
      // 有在线时说明规模里有几台在用；一台在线都没有就只剩"都要重新配对"。
      confirmRemoveSelectedDescription: '其中 {s} 台在线,正在使用。被删的设备都需要重新配对。',
      confirmRemoveSelectedAllDescription: '被删的那几台手机都需要重新配对。',
      confirmCleanRevokedTitle: '删除已停用的 {n} 台设备？',
      confirmCleanRevokedDescription: '那几台手机需要重新配对。',
      confirmClearAllTitle: '删除全部 {n} 台设备？',
      confirmClearAllDescription: '在线的 {s} 台会跳过。那几台手机需要重新配对。',
      // ---- 失败必须带原因（照 DSH `停用失败：{reason}`）----
      failedDisable: '停用失败：{reason}',
      failedEnable: '启用失败：{reason}',
      failedRemove: '删除失败：{reason}',
      skippedOnline: '已跳过 {n} 台在线设备（正在用的不动）',
    }
    const en = {
      title: 'Mobile link',
      entry: 'Phone',
      // Per-method transport switches (2026-10-17). One switch per channel;
      // a new method grows this list (data from GET /transport) — the shape
      // never changes.
      transportTitle: 'Transport',
      allStart: 'Start all',
      allStop: 'Stop all',
      channelRunning: 'running',
      channelStopped: 'stopped',
      channelStart: 'Start',
      channelStop: 'Stop',
      failedChannel: 'Could not {action}: {reason}',
      transportNote: 'The two channels are independent: stopping one leaves the other alone. Stopping transport keeps credentials and identities — a restart needs no re-pairing.',
      close: 'Close',
      pairedAt: 'Paired',
      // Re-pairing REPLACES the row: the phone reports its previous pairingId,
      // the computer swaps keys and token in place (first pairing time kept).
      pairNote: 'Re-scanning from the same phone REPLACES its previous record on this computer (new keys and token; the first pairing time is kept) — records no longer accumulate; only a first pairing or a different phone adds a row.',
      online: 'online',
      offline: 'offline',
      running: 'running',
      idle: 'idle',
      foreground: 'foreground',
      background: 'background',
      disabled: 'disabled',
      neverSeen: 'never used',
      justNow: 'just now',
      minutesAgo: '{n}m ago',
      hoursAgo: '{n}h ago',
      daysAgo: '{n}d ago',
      disable: 'Disable',
      enable: 'Enable',
      remove: 'Delete',
      removeSelected: 'Delete selected',
      selectedCount: '{n} selected',
      cancel: 'Cancel',
      cleanRevoked: 'Delete disabled records ({n})',
      clearAll: 'Delete all records ({n})',
      showRevoked: '{n} disabled · show',
      hideRevoked: 'hide disabled',
      pair: 'Pair a new phone',
      pairing: 'Issuing…',
      scanHint: 'Scan it with the app',
      expiresIn: 'expires in {t}',
      expired: 'QR expired — issue a new one',
      noDevices: 'No device has paired yet.',
      loadFailed: 'Load failed',
      confirmDisableTitle: 'Disable "{name}"?',
      confirmDisableDescription: 'That phone fails its next reconnect and must pair again to come back. The record is kept.',
      confirmRemoveTitle: 'Delete "{name}"?',
      confirmRemoveDescription: 'That phone will need to pair again.',
      confirmRemoveOnlineDescription: 'This one is online and in use. It will need to pair again after deletion.',
      confirmRemoveSelectedTitle: 'Delete the {n} selected devices?',
      confirmRemoveSelectedDescription: '{s} of them are online and in use. Every deleted device must pair again.',
      confirmRemoveSelectedAllDescription: 'Every deleted phone must pair again.',
      confirmCleanRevokedTitle: 'Delete the {n} disabled devices?',
      confirmCleanRevokedDescription: 'Those phones must pair again.',
      confirmClearAllTitle: 'Delete all {n} devices?',
      confirmClearAllDescription: '{s} online will be skipped. Those phones must pair again.',
      failedDisable: 'Could not disable: {reason}',
      failedEnable: 'Could not enable: {reason}',
      failedRemove: 'Could not delete: {reason}',
      skippedOnline: 'Skipped {n} online device(s) — the one in use is left alone',
    }

    /** 只引用 `--dsw-alias-*`：token 是唯一允许共享的样式依赖（practices.md:35）。 */
    const S = {
      // **`position: relative` 是对话框的定位基准**：见下面 `mask` 的注释。
      wrap: { display: 'flex', flexDirection: 'column', gap: 16, margin: '12px 0', position: 'relative' },
      card: {
        border: '1px solid var(--dsw-alias-border-inverted)',
        borderRadius: 8,
        padding: '12px 14px',
      },
      row: { display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' },
      dot: (color) => ({
        width: 8, height: 8, borderRadius: '50%', background: color, flex: 'none',
      }),
      label: { color: 'var(--dsw-alias-label-secondary)', fontSize: 12 },
      value: { color: 'var(--dsw-alias-label-primary)', fontSize: 13 },
      table: { width: '100%', borderCollapse: 'collapse', fontSize: 13 },
      th: {
        textAlign: 'left', padding: '6px 8px', fontWeight: 500, fontSize: 12,
        color: 'var(--dsw-alias-label-tertiary)',
        borderBottom: '1px solid var(--dsw-alias-border-inverted)',
      },
      td: {
        padding: '6px 8px', color: 'var(--dsw-alias-label-primary)',
        borderBottom: '1px solid var(--dsw-alias-border-inverted)',
      },
      dim: { color: 'var(--dsw-alias-label-caption)' },
      warn: { color: 'var(--dsw-alias-state-warn-label)' },
      err: { color: 'var(--dsw-alias-state-error-primary)' },
      ok: { color: 'var(--dsw-alias-state-success-primary)' },
      btn: {
        font: 'inherit', fontSize: 13, cursor: 'pointer', borderRadius: 6,
        border: '1px solid var(--dsw-alias-border-inverted)',
        background: 'var(--dsw-alias-interactive-bg-hover)',
        color: 'var(--dsw-alias-label-primary)',
        padding: '5px 12px',
      },
      /** 软停用：描边红。可逆，但确实会打断那台手机。 */
      btnDanger: {
        font: 'inherit', fontSize: 13, cursor: 'pointer', borderRadius: 6,
        border: '1px solid var(--dsw-alias-state-error-primary)',
        background: 'transparent',
        color: 'var(--dsw-alias-state-error-primary)',
        padding: '5px 12px',
      },
      /** 硬删：实心红（照 DSH `dangerButton` 把 primary fill 换成 error 的做法）。 */
      btnDangerSolid: {
        font: 'inherit', fontSize: 13, cursor: 'pointer', borderRadius: 6,
        border: '1px solid var(--dsw-alias-state-error-primary)',
        background: 'var(--dsw-alias-state-error-primary)',
        color: 'var(--dsw-alias-label-primary-foreground)',
        padding: '5px 12px',
      },
      btnDisabled: { opacity: 0.5, cursor: 'default' },
      /** 多选浮现栏：不占行高，只在有勾选时出现。 */
      bar: {
        display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap',
        margin: '0 0 8px', padding: '6px 8px', borderRadius: 6,
        background: 'var(--dsw-alias-interactive-bg-active)',
      },
      /** 页面内确认对话框（照 DSH `Modal`：遮罩 + 居中卡片，`Modal.module.css:6-15`）。
       *  **绝对定位于面板自身，不用 `position: fixed`**：本面板渲染在 DSH「插件」页的
       *  组合包详情页里，那一页有滑入过渡、很可能带 `transform`，而 fixed 在带
       *  transform 的祖先里会改成**相对该祖先**定位 —— 对话框会跑位、甚至被裁。
       *  遮罩只盖面板，代价是对话框不会盖住整页；换来的是不会被页面变换带跑。 */
      mask: {
        position: 'absolute', inset: 0, zIndex: 1000,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: 'var(--dsw-alias-bg-mask-1)',
        borderRadius: 8,
      },
      dialog: {
        boxSizing: 'border-box', width: 'min(400px, calc(100vw - 48px))',
        background: 'var(--dsw-alias-bg-layer-2)',
        border: '1px solid var(--dsw-alias-border-inverted)',
        borderRadius: 8, padding: '16px 18px',
      },
      // **这里不能写 `...S.value` / `...S.label`**：`S` 自己还在初始化（TDZ），
      // 向前引用会抛 `Cannot access 'S' before initialization` —— 而 `node --check`
      // 查不出来。要复用就写在组件里（那里 `S` 已经建好了）。
      dialogTitle: {
        margin: '0 0 8px', fontSize: 15, fontWeight: 500,
        color: 'var(--dsw-alias-label-primary)',
      },
      dialogDesc: {
        margin: '0 0 16px', lineHeight: 1.6, fontSize: 12,
        color: 'var(--dsw-alias-label-secondary)',
      },
      dialogFooter: { display: 'flex', justifyContent: 'flex-end', gap: 8 },
      /** 主面板弹框的遮罩：**fixed** —— 面板是框架根级区域，没有带 transform
       *  的祖先（插件页内嵌卡片才需要 absolute，见 `mask` 的注释）。 */
      fixedMask: {
        position: 'fixed', inset: 0, zIndex: 1000,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: 'var(--dsw-alias-bg-mask-1)',
      },
      fixedBox: {
        boxSizing: 'border-box',
        // **宽**：这个弹框里有一张五列设备表（勾选/名称/配对于/最后活跃/状态）
        // 加一排操作钮，520px 下表格挤成一团（2026-10-17 用户原话："你这个UI
        // 你看没搞这么窄干啥"）。留 48px 边距给小屏。
        width: 'min(760px, calc(100vw - 48px))',
        maxHeight: 'calc(100vh - 96px)', overflowY: 'auto',
        background: 'var(--dsw-alias-bg-layer-2)',
        border: '1px solid var(--dsw-alias-border-inverted)',
        borderRadius: 10, padding: '14px 18px 18px',
      },
      dialogHead: {
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        gap: 12, marginBottom: 10,
      },
    }

    const fmtClock = (ms) => (ms ? new Date(ms).toLocaleString() : '—')

    /** 绝对时间（配对时刻）：要认出"哪条是最新那条"，相对时间不够。 */
    const fmtWhen = fmtClock

    /** 相对时间：操作者关心"多久没用了"，不是"哪年哪月"。 */
    function fmtAgo(ms, t) {
      if (!ms) return t('neverSeen')
      const secs = Math.max(0, Math.floor((Date.now() - ms) / 1000))
      if (secs < 60) return t('justNow')
      const mins = Math.floor(secs / 60)
      if (mins < 60) return t('minutesAgo', { n: mins })
      const hours = Math.floor(mins / 60)
      if (hours < 24) return t('hoursAgo', { n: hours })
      return t('daysAgo', { n: Math.floor(hours / 24) })
    }

    /** 倒计时 `m:ss`。到期返回 null（调用方据此清掉二维码）。 */
    function fmtCountdown(expiresAt, now) {
      const left = Math.max(0, Math.floor((expiresAt - now) / 1000))
      if (left === 0) return null
      const m = Math.floor(left / 60)
      const s = left % 60
      return m > 0 ? `${m}:${String(s).padStart(2, '0')}` : `0:${String(s).padStart(2, '0')}`
    }

    /** 异常 → 一句话。失败提示里要带它，不许吞成"操作失败"。 */
    const messageOf = (caught) => (caught instanceof Error ? caught.message : String(caught))

    /**
     * 起停**一条**传输通道。**停 ≠ 卸载**：只收这一条，配对记录与凭据
     * 原样留着，再启动时配对过的手机一条都不用重扫。
     *
     * 跑完必须重拉状态：按钮的"运行中/未运行"要从电脑侧的真值来，
     * 不按本地点击记录乐观翻转 —— 起点失败时按钮会说谎。
     */
    const setChannel = async (id, running, refresh) => {
      try {
        const response = await fetch(`${TRANSPORT}/${encodeURIComponent(id)}/${running ? 'start' : 'stop'}`, { method: 'POST' })
        const body = await response.json()
        if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`)
        await refresh()
      } catch (caught) {
        throw new Error(messageOf(caught))
      }
    }

    /** 管理面板本体（状态 + 启停 + 设备 + 配对）。**只有一个视图** ——
     *  2026-10-17 从插件页卡迁到侧边栏弹框后，'summary' 卡片行那个视图
     *  随入口一起没了，留着就是死代码。 */
    function AdminPanel(props) {
      const t = props.t
      const [status, setStatus] = useState(null)
      const [channels, setChannels] = useState([])
      const [error, setError] = useState('')
      const [qr, setQr] = useState(null)
      const [busy, setBusy] = useState('')
      const [now, setNow] = useState(() => Date.now())
      // **已停用默认收起**：真机联调会攒下几十行停用记录，全展开等于列表永远在长。
      // 用户要看的时候有一行"已停用 N 台 · 展开"。
      const [showRevoked, setShowRevoked] = useState(false)
      // 多选的勾选集。**临时状态**：删完即清，不做"编辑模式"（见文件头）。
      const [selected, setSelected] = useState(() => new Set())
      // 待确认的破坏性动作：{ title, description, confirmLabel, run }。
      // 形状照 DSH `manager-store.ts:286-288,666-671` 的 `pendingConfirm`
      // —— 先存动作再渲染对话框，确认时才真跑。
      const [pending, setPending] = useState(null)
      /** 对话框挂住时记录的"打开前焦点"，关闭后还回去。 */
      const restoreFocus = useRef(null)

      const refresh = useCallback(async () => {
        try {
          // **两个读面一起拉**：status 管设备与连接态，/transport 管按方式的
          // 通道开关。只拉一个的话，另一个面永远停在空态（假数据）。
          const [statusResponse, transportResponse] = await Promise.all([fetch(STATUS), fetch(TRANSPORT)])
          if (!statusResponse.ok) throw new Error(`${t('loadFailed')}：HTTP ${statusResponse.status}`)
          if (!transportResponse.ok) throw new Error(`${t('loadFailed')}：HTTP ${transportResponse.status}`)
          setStatus(await statusResponse.json())
          const transport = await transportResponse.json()
          setChannels(Array.isArray(transport.channels) ? transport.channels : [])
          setError('')
        } catch (caught) {
          // **失败要留声**：静默的空面板会让人以为"没有设备"。
          setError(messageOf(caught))
        }
      }, [t])

      // 首渲染就把状态与通道列表拉回来（面板的唯一数据源）。
      useEffect(() => { refresh() }, [refresh])

      // 有二维码时才需要每秒走字（倒计时）；没有就一个定时器都不挂。
      useEffect(() => {
        if (qr === null) return
        const timer = setInterval(() => setNow(Date.now()), 1000)
        return () => clearInterval(timer)
      }, [qr])

      // 到期自动清掉：留着一张扫不上的图比没有图更糟。
      useEffect(() => {
        if (qr !== null && qr.expiresAt <= now) setQr(null)
      }, [qr, now])

      const pair = async () => {
        setBusy('pair')
        setQr(null)
        setError('')
        try {
          const response = await fetch(PAIR, { method: 'POST' })
          const body = await response.json()
          if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`)
          if (typeof body.svg !== 'string') throw new Error('电脑侧没有返回二维码')
          // SVG 是 UTF-8 文本，用 encodeURIComponent 转 data URI —— btoa 只吃 Latin1。
          setQr({ src: `data:image/svg+xml,${encodeURIComponent(body.svg)}`, expiresAt: body.expiresAt })
          setNow(Date.now())
        } catch (caught) {
          setError(messageOf(caught))
        } finally {
          setBusy('')
        }
      }

      /**
       * 停用 / 启用。**一对布尔端点**（`POST /devices/enabled`，照 DSH
       * `setBundleEnabled(name, enabled)`），不是两个动作。
       *
       * **启用不弹确认**（照 DSH `manager-store.ts:650-661`：`setEnabled` 直接跑，
       * 只有 `uninstall` 走 `pendingConfirm`）—— 启用是可逆的、不破坏任何东西，
       * 给它加一道确认只会训练用户见框就点。停用要弹：它会让那台手机失联。
       */
      const setEnabled = async (device, enabled) => {
        setBusy(device.id)
        try {
          const response = await fetch(ENABLED, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ devId: device.id, enabled }),
          })
          const body = await response.json()
          if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`)
          await refresh()
        } catch (caught) {
          setError(t(enabled ? 'failedEnable' : 'failedDisable', { reason: messageOf(caught) }))
        } finally {
          setBusy('')
        }
      }

      /** 停用要确认：那台手机下次重连就会失败。 */
      const disableOne = (device) => askConfirm({
        title: t('confirmDisableTitle', { name: device.name }),
        description: t('confirmDisableDescription'),
        confirmLabel: t('disable'),
        run: async () => { await setEnabled(device, false) },
      })

      /** 真删除的统一出口：打 `REMOVE`，把跳过的在线台数报出来，成功后清勾选。 */
      const postRemove = async (payload, busyKey) => {
        setBusy(busyKey)
        try {
          const response = await fetch(REMOVE, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify(payload),
          })
          const body = await response.json()
          if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`)
          await refresh()
          if (body.skippedOnline > 0) {
            // 跳过了在线的必须说出来：用户按了"删除所选"却发现自己那台还在，
            // 会以为按钮坏了。
            setError(t('skippedOnline', { n: body.skippedOnline }))
          }
          // 勾选是临时状态：删完即清，不留"选了台已经不在的设备"。
          setSelected(new Set())
        } catch (caught) {
          setError(t('failedRemove', { reason: messageOf(caught) }))
        } finally {
          setBusy('')
        }
      }

      /** 打开确认对话框。`spec.run` 在用户点确认键时才跑。 */
      const askConfirm = (spec) => {
        restoreFocus.current = document.activeElement
        setPending(spec)
      }

      const closeConfirm = () => {
        setPending(null)
        const back = restoreFocus.current
        restoreFocus.current = null
        // 焦点还回去：对话框是被键盘/读屏用户打开的，关掉就该回到原处。
        if (back !== null && typeof back.focus === 'function') back.focus()
      }

      /**
       * 起停**一条**通道。失败带原因显示在面板顶部（照 DSH `停用失败：{reason}`）——
       * 静默的失败会让人以为按钮坏了，比报错更难排查。
       */
      const runChannel = async (channel) => {
        setBusy(`channel:${channel.id}`)
        try {
          await setChannel(channel.id, !channel.running, refresh)
        } catch (caught) {
          setError(t('failedChannel', {
            action: channel.running ? t('channelStop') : t('channelStart'),
            reason: messageOf(caught),
          }))
        } finally {
          setBusy('')
        }
      }

      /**
       * 批量启停（用户的常态是同时开 / 同时关）。**尽力而为**：已经在目标
       * 状态的通道跳过（不重启在跑的），失败的记下原因但继续剩下的 ——
       * 直连没配 `listenPort` 时它起不来，而中转照样该起起来。
       * 批量不设服务端端点：两条各自的成败要能分别看见，一个批量端点只会
       * 把其中一个的失败藏掉（`routes.ts` 文件头）。
       */
      const runAll = async (running) => {
        setBusy(`all:${running ? 'start' : 'stop'}`)
        try {
          let failure = null
          for (const channel of channels) {
            if (channel.running === running) continue
            try {
              await setChannel(channel.id, running, refresh)
            } catch (caught) {
              failure ??= caught
            }
          }
          await refresh()
          if (failure !== null) {
            setError(t('failedChannel', {
              action: running ? t('channelStart') : t('channelStop'),
              reason: messageOf(failure),
            }))
          }
        } finally {
          setBusy('')
        }
      }

      // ---- 派生值：全部只由 `status` 算出来，放在动作前面，免得闭包向前引用 ----
      const devices = status && status.devices ? status.devices : []
      const live = devices.filter((d) => !d.revoked)
      const revoked = devices.filter((d) => d.revoked)
      const deviceById = new Map(devices.map((d) => [d.id, d]))
      const onlineCount = live.filter((d) => d.online).length
      const pairedCount = live.length

      /** 删除一台。在线那台说清"它在用"，但**照样删**（显式点名，见文件头）。 */
      const removeOne = (device) => askConfirm({
        title: t('confirmRemoveTitle', { name: device.name }),
        description: device.online ? t('confirmRemoveOnlineDescription') : t('confirmRemoveDescription'),
        confirmLabel: t('remove'),
        run: async () => { await postRemove({ devIds: [device.id] }, device.id) },
      })

      /** 删除勾选的几台。有在线就报出来，但一台都不跳过。 */
      const removeSelected = (ids) => {
        const online = ids.filter((id) => deviceById.get(id)?.online).length
        askConfirm({
          title: t('confirmRemoveSelectedTitle', { n: ids.length }),
          // 一台在线的都没有时，句子不该出现"其中 0 台在线"。
          description: online > 0
            ? t('confirmRemoveSelectedDescription', { s: online })
            : t('confirmRemoveSelectedAllDescription'),
          confirmLabel: t('remove'),
          run: async () => { await postRemove({ devIds: ids }, 'selected') },
        })
      }

      /** 按状态清。只剩 `revoked` / `all` 两种 scope（`offline` 已删，见 routes.ts）。 */
      const cleanRevoked = () => askConfirm({
        title: t('confirmCleanRevokedTitle', { n: revoked.length }),
        description: t('confirmCleanRevokedDescription'),
        confirmLabel: t('remove'),
        run: async () => { await postRemove({ scope: 'revoked' }, 'revoked') },
      })

      const clearAll = () => askConfirm({
        title: t('confirmClearAllTitle', { n: devices.length }),
        description: t('confirmClearAllDescription', { s: onlineCount }),
        confirmLabel: t('remove'),
        run: async () => { await postRemove({ scope: 'all' }, 'all') },
      })

      // **默认只显示未停用的**；已停用折叠成一行，要看了才展开。
      // 否则列表随每次联调无限变长，而用户 99% 的时间不需要看那些行。
      const visible = showRevoked ? devices : live
      const selectedIds = [...selected].filter((id) => deviceById.has(id))
      const countdown = qr === null ? null : fmtCountdown(qr.expiresAt, now)
      const toggle = (id) => {
        const next = new Set(selected)
        if (next.has(id)) next.delete(id)
        else next.add(id)
        setSelected(next)
      }

      return h(
        'div',
        { style: S.wrap },

        // 失败与提示**放在面板顶部**，不放在某一张卡里：停用/删除失败了，
        // 消息却出现在最下面那张配对卡上，用户根本不会往那儿看。
        error !== '' ? h('p', { key: 'e', role: 'alert', style: { ...S.label, ...S.err, margin: 0 } }, error) : null,

        // ① 状态 —— 最高频的那一问："我的手机连上了吗"
        h(
          'div',
          { key: 'status', style: S.card },
          h(
            'div',
            { style: S.row },
            h('span', { style: S.dot(onlineCount > 0 ? 'var(--dsw-alias-state-success-primary)' : 'var(--dsw-alias-state-idle-primary)') }),
            h('strong', { style: S.value }, onlineCount > 0 ? t('online') : t('offline')),
            h('span', { style: S.label }, `${onlineCount} / ${pairedCount} 台在线`),
          ),
          h(
            'div',
            { style: { ...S.row, marginTop: 6 } },
            h('span', { style: S.label }, '拨向'),
            h('code', { style: { ...S.value, ...S.dim } }, status && status.relayUrl ? status.relayUrl : '未配置中转'),
          ),
          // **传输方式**：每个通道一个开关（2026-10-17 用户：「不是有两中方式
          // 为啥就一个开关？后面我要是再加新的方式也就一个开关吗？」）。
          // 列表来自 `GET /transport` —— 加新方式这里自动长一行，不为它改形状。
          // 取舍：.agents/notes/implemented/2026-10-17-transport-channels-registry.md
          // 批量入口放在最上面：同时开 / 同时关是常态，单条是例外。
          h(
            'div',
            { key: 'transport', style: { marginTop: 10, paddingTop: 10, borderTop: '1px solid var(--dsw-alias-border-inverted)' } },
            h(
              'div',
              { style: S.row },
              h('span', { style: S.label }, t('transportTitle')),
              h('span', { style: { flex: 1 } }),
              h('button', {
                type: 'button',
                style: busy !== '' ? { ...S.btn, ...S.btnDisabled } : S.btn,
                disabled: busy !== '',
                onClick: () => runAll(true),
              }, t('allStart')),
              h('button', {
                type: 'button',
                style: busy !== '' ? { ...S.btn, ...S.btnDisabled } : S.btn,
                disabled: busy !== '',
                onClick: () => runAll(false),
              }, t('allStop')),
            ),
            channels.map((channel) => h(
              'div',
              { key: channel.id, style: { ...S.row, marginTop: 6 } },
              h('span', { style: S.dot(channel.running ? 'var(--dsw-alias-state-success-primary)' : 'var(--dsw-alias-state-idle-primary)') }),
              h('span', { style: S.value }, channel.label),
              h('span', { style: { ...S.label, flex: 1 } },
                `${channel.running ? t('channelRunning') : t('channelStopped')} · ${channel.detail}`),
              h('button', {
                type: 'button',
                style: busy === `channel:${channel.id}` ? { ...S.btn, ...S.btnDisabled } : S.btn,
                disabled: busy !== '',
                onClick: () => runChannel(channel),
              }, channel.running ? t('channelStop') : t('channelStart')),
            )),
            h('p', { style: { ...S.label, margin: '8px 0 0', lineHeight: 1.6 } }, t('transportNote')),
          ),
        ),

        // ② 设备 —— 在线的排最前（服务端已排序）；每台可停用(软)/启用(解禁)/删除(硬)
        h(
          'div',
          { key: 'devices', style: S.card },
          h('h3', { key: 'h', style: { ...S.value, margin: '0 0 8px' } }, '已配对设备'),
          // 多选浮现栏：**只在有勾选时出现**，不改变行本身的交互（见文件头）。
          selectedIds.length === 0
            ? null
            : h('div', { key: 'sel', style: S.bar },
                h('span', { style: { ...S.label, flex: 'none' } }, t('selectedCount', { n: selectedIds.length })),
                h('button', {
                  type: 'button',
                  style: busy === 'selected' ? { ...S.btnDangerSolid, ...S.btnDisabled } : S.btnDangerSolid,
                  disabled: busy !== '',
                  onClick: () => removeSelected(selectedIds),
                }, t('removeSelected')),
                h('button', {
                  type: 'button', style: S.btn, disabled: busy !== '',
                  onClick: () => setSelected(new Set()),
                }, t('cancel')),
              ),
          visible.length === 0
            ? h('p', { key: 'z', style: S.dim }, status === null ? '…' : t('noDevices'))
            : h(
                'table',
                { key: 'tb', style: S.table },
                h('thead', null, h('tr', null,
                  h('th', { style: { ...S.th, width: 28 } }, ''),
                  h('th', { style: S.th }, '名称'),
                  // **配对于**：每次扫码都是一条新记录，用户要能认出"哪条是我现在
                  // 这部手机"（2026-10-17 真机：同一个手机扫了 5 次，5 条同名行，
                  //  用户问"我只有一个手机怎么显示五个"）。
                  h('th', { style: S.th }, t('pairedAt')),
                  h('th', { style: S.th }, '最后活跃'),
                  h('th', { style: S.th }, '状态'),
                  h('th', { style: { ...S.th, textAlign: 'right' } }, ''),
                )),
                h('tbody', null, visible.map((device) => h('tr', { key: device.id },
                  // 行首勾选框。可访问名就是设备名，不另造词。
                  h('td', { style: S.td },
                    h('input', {
                      type: 'checkbox',
                      'aria-label': device.name,
                      checked: selected.has(device.id),
                      disabled: busy !== '',
                      onChange: () => toggle(device.id),
                    }),
                  ),
                  h('td', { style: S.td }, device.name),
                  h('td', { style: { ...S.td, ...S.dim } }, fmtWhen(device.pairedAt, t)),
                  h('td', { style: { ...S.td, ...S.dim } }, device.revoked ? '—' : fmtAgo(device.lastInteractedAt, t)),
                  h('td', { style: S.td },
                    device.revoked
                      ? h('span', { style: S.dim }, t('disabled'))
                      : h('span', { style: device.online ? S.ok : S.dim },
                          `${device.online ? t('running') : t('idle')}${device.online ? ` · ${device.foreground ? t('foreground') : t('background')}` : ''}`),
                  ),
                  // 三个动作分开：**停用**是软的（断连、留记录、可解禁），
                  // **删除**是硬的（抹掉行）。用户说"记录删不了"指的就是只有前者。
                  // **启用不弹确认** —— 它不破坏任何东西（照 DSH）。
                  h('td', { style: { ...S.td, textAlign: 'right', whiteSpace: 'nowrap' } },
                    device.revoked
                      ? h('span', { style: S.row },
                          h('button', {
                            type: 'button',
                            style: busy === device.id ? { ...S.btn, ...S.btnDisabled } : S.btn,
                            disabled: busy !== '',
                            onClick: () => setEnabled(device, true),
                          }, t('enable')),
                          h('button', {
                            type: 'button',
                            style: busy === device.id ? { ...S.btnDangerSolid, ...S.btnDisabled } : S.btnDangerSolid,
                            disabled: busy !== '',
                            onClick: () => removeOne(device),
                          }, t('remove')),
                        )
                      : h('span', { style: S.row },
                          h('button', {
                            type: 'button',
                            style: busy === device.id ? { ...S.btnDanger, ...S.btnDisabled } : S.btnDanger,
                            disabled: busy !== '',
                            onClick: () => disableOne(device),
                          }, t('disable')),
                          h('button', {
                            type: 'button',
                            style: busy === device.id ? { ...S.btnDangerSolid, ...S.btnDisabled } : S.btnDangerSolid,
                            disabled: busy !== '',
                            onClick: () => removeOne(device),
                          }, t('remove')),
                        ),
                  ),
                ))),
              ),
          // 已停用折叠行：默认收起，避免列表无限变长。
          revoked.length > 0
            ? h('div', { key: 'rv', style: { marginTop: 8 } },
                h('button', {
                  type: 'button', style: S.btn,
                  onClick: () => setShowRevoked(!showRevoked),
                }, showRevoked ? t('hideRevoked') : t('showRevoked', { n: revoked.length })),
              )
            : null,
          // 按状态清：**只剩"已停用 / 全部"两种**。"按当前离线批量硬删"已删 ——
          // 它的人口专门命中"暂时离线但还在用"的设备，2026-10-15 事故删掉的正是
          // 用户自己那台（他当时在排查重连，是离线态）。要删具体的几台用上面的多选。
          h('div', { key: 'clean', style: { ...S.row, marginTop: 10, gap: 8, flexWrap: 'wrap' } },
            revoked.length > 0
              ? h('button', {
                  type: 'button',
                  style: busy === 'revoked' ? { ...S.btnDangerSolid, ...S.btnDisabled } : S.btnDangerSolid,
                  disabled: busy !== '',
                  onClick: cleanRevoked,
                }, t('cleanRevoked', { n: revoked.length }))
              : null,
            devices.length > 0
              ? h('button', {
                  type: 'button',
                  style: busy === 'all' ? { ...S.btnDangerSolid, ...S.btnDisabled } : S.btnDangerSolid,
                  disabled: busy !== '',
                  onClick: clearAll,
                }, t('clearAll', { n: devices.length }))
              : null,
          ),
        ),

        // ③ 配对新手机 —— 最低频，所以放最下面
        h(
          'div',
          { key: 'pair', style: S.card },
          h('h3', { key: 'h', style: { ...S.value, margin: '0 0 8px' } }, '配对新手机'),
          h('p', { key: 'd', style: { ...S.label, margin: '0 0 10px' } }, '二维码一次性、5 分钟有效；登记不到中转就不出码。'),
          h('button', {
            key: 'b', type: 'button',
            style: busy === 'pair' ? { ...S.btn, ...S.btnDisabled } : S.btn,
            disabled: busy !== '',
            onClick: pair,
          }, busy === 'pair' ? t('pairing') : t('pair')),
          qr === null
            ? null
            : countdown === null
              ? h('p', { key: 'x', style: { ...S.label, ...S.warn, marginTop: 10 } }, t('expired'))
              : h('div', { key: 'q', style: { marginTop: 10 } },
                  h('img', { alt: '配对二维码', src: qr.src, width: 260, height: 260, style: { display: 'block', background: '#fff', borderRadius: 6 } }),
                  h('p', { key: 'c', style: { ...S.label, margin: '6px 0 0' } }, `${t('scanHint')} · ${t('expiresIn', { t: countdown })}`),
                ),
        ),

        // ④ 确认对话框 —— **页面内 DOM**，不用 `window.confirm`（2026-10-15 事故）。
        // 形状照 DSH `confirmUninstall`（`PluginManagerPage.tsx:1367-1390`）：
        // 标题问句 + 一句后果 + 取消/确认。
        pending === null
          ? null
          : h('div', { key: 'cf', style: S.mask, onClick: closeConfirm },
              h('div', {
                style: S.dialog, role: 'alertdialog', 'aria-modal': true, 'aria-label': pending.title,
                onClick: (event) => event.stopPropagation(),
              },
                h('h4', { style: S.dialogTitle }, pending.title),
                h('p', { style: S.dialogDesc }, pending.description),
                h('div', { style: S.dialogFooter },
                  h('button', {
                    type: 'button', style: S.btn, onClick: closeConfirm,
                  }, t('cancel')),
                  h('button', {
                    type: 'button',
                    style: busy !== '' ? { ...S.btnDangerSolid, ...S.btnDisabled } : S.btnDangerSolid,
                    disabled: busy !== '',
                    onClick: () => {
                      const run = pending.run
                      // 先关框再跑：跑起来面板会转 busy，框挂着会挡住"已跳过在线"那行提示。
                      closeConfirm()
                      void run()
                    },
                  }, pending.confirmLabel),
                ),
              ),
            ),
      )
    }

    /**
     * 侧边栏条目图标（`sidebar.panellist` 的 owner 形状：`{size, active}`）。
     *
     * **内联 SVG，不 require 任何 DSH 包**：控件自己画（practices.md:35）。
     * 形状是一部手机 + 信号弧 —— 与"手机连接"这件事对应。
     */
    function EntryIcon(props) {
      const size = props.size || 18
      const color = props.active ? 'var(--dsw-alias-label-primary)' : 'currentColor'
      return h('svg', {
        width: size, height: size, viewBox: '0 0 16 16', fill: 'none',
        'aria-hidden': true, style: { color, flex: 'none' },
      },
        h('rect', {
          x: 4.25, y: 1.25, width: 7.5, height: 13.5, rx: 1.75,
          stroke: 'currentColor', strokeWidth: 1.3,
        }),
        h('path', { d: 'M6.75 12.15h2.5', stroke: 'currentColor', strokeWidth: 1.3, strokeLinecap: 'round' }),
        h('path', {
          d: 'M1.5 5.5a9 9 0 0 1 13 0M3.6 8.1a6 6 0 0 1 8.8 0',
          stroke: 'currentColor', strokeWidth: 1.3, strokeLinecap: 'round',
        }),
      )
    }

    /**
     * 主面板：**弹框**，不是页面。
     *
     * 2026-10-17 用户定：入口放侧边栏（插件之下、工作区之上，走标准
     * `sidebar.panellist` 列表槽 + order，不硬编码位置），**点开是弹框** ——
     * 管理手机连接是"看一眼 + 一两个动作"的事，不值得占掉整页。
     *
     * 弹框用 `createPortal` 挂到 `document.body`：主面板是框架的根级区域，
     * 不会被带 `transform` 的祖先带跑（插件页那种内嵌卡片才需要 absolute）。
     * 点遮罩或右上角关闭 = `selectPanel(null)`（标准"回会话视图"）。
     */
    function ConnectorPanel(props) {
      const t = props.t
      const close = props.close || (() => {})
      // Esc 关：弹框的标准键。挂在面板上（它在挂载期间一直活着）。
      useEffect(() => {
        const onKey = (event) => {
          if (event.key === 'Escape') close()
        }
        document.addEventListener('keydown', onKey)
        return () => document.removeEventListener('keydown', onKey)
      }, [close])

      return ReactDOM.createPortal(
        h('div', {
          key: 'mask', style: S.fixedMask, onClick: close,
        },
          h('div', {
            key: 'box',
            role: 'dialog', 'aria-modal': true, 'aria-label': t('title'),
            style: S.fixedBox,
            onClick: (event) => event.stopPropagation(),
          },
            // 头：标题 + 关闭。状态与在线数在下面的状态卡里，不在这里重复一遍。
            h('div', { style: S.dialogHead },
              h('strong', { style: { ...S.value, fontSize: 15 } }, t('title')),
              h('button', {
                type: 'button', style: { ...S.btn, padding: '3px 10px' },
                onClick: close,
              }, t('close')),
            ),
            // 体：原有的管理面板（状态 + 启停 + 设备 + 配对）。
            h(AdminPanel, { view: 'page', t }),
            h('p', { style: { ...S.label, margin: '4px 2px 0', lineHeight: 1.6 } }, t('pairNote')),
          ),
        ),
        document.body,
      )
    }

    return {
      inject: ['slots', 'locale', 'layout'],

      apply(ctx) {
        ctx.effect(() => ctx.locale.register(NS, { zh, en }))
        // 关闭面板：标准 API（`selectPanel(null)` = 回会话视图）。
        const closePanel = () => ctx.layout.selectPanel(null)
        /**
         * ① 侧边栏条目 —— 标准列表槽 `sidebar.panellist`，**order 5**：
         * 插件（0）之下、自动化任务（10）之上，正是"插件下面、工作区上面"
         * （面板列表整体在工作区树上方）。别的插件同样往这个槽注册、各自排序，
         * 这里不硬编码任何位置。
         */
        ctx.slots.inject('sidebar.panellist', () =>
          ctx.slots.register(
            {
              name: 'sidebar.panellist',
              id: PANEL_ID,
              order: 5,
              label: () => ctx.locale.bind(NS)('entry'),
              locale: NS,
            },
            EntryIcon,
          ),
        )
        /**
         * ② 主面板 —— 同一个 id，点条目时框架切到它，内容画成弹框。
         * `main` 是 keyed 槽（`ui-layout/src/client/index.ts:73`）。
         */
        ctx.slots.inject('main', () =>
          ctx.slots.register(
            {
              name: 'main',
              key: PANEL_ID,
              locale: NS,
              inject: () => ({ close: closePanel }),
            },
            ConnectorPanel,
          ),
        )
      },
    }
  },
})
