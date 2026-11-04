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
  id: 'dsh-mobile-connector',

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
    const ADVERTISE = '/api/dsh-mobile/advertise'
    const ENABLED = '/api/dsh-mobile/devices/enabled'
    const REMOVE = '/api/dsh-mobile/devices/remove'
    // 「连接」卡（2026-10-29）：中转地址 / 公网明文开关 / 直连端口 / 令牌。
    // 值的写入走 DSH 的 `settings.update`（落当前 profile 的 cordis.patch.yml），
    // 令牌走凭据记录面 —— 判据全在电脑侧（`src/admin/connection-card.ts`）。
    const CONNECTION = '/api/dsh-mobile/connection'
    /** 查更新（只读；电脑侧代查 npm，见 `src/admin/update.ts`）。 */
    const UPDATE = '/api/dsh-mobile/update'

    /**
     * 读应答体，**失败也要说人话**。
     *
     * 以前各处直接 `await response.json()`：管理面没挂上时 DSH 的共享通道回的是
     * 纯文本 `not found`，`json()` 抛的是 `Unexpected token 'o', "not found" is not
     * valid JSON` —— 用户看到的是**解析器原话**，看不出"接口没挂"（2026-11-01 真机）。
     * 这里统一成 `HTTP <状态>: <正文前 80 字>`，正文不是 JSON 就当错误抛。
     */
    const jsonOf = async (response) => {
      const text = await response.text()
      try {
        return text === '' ? {} : JSON.parse(text)
      } catch {
        throw new Error(`HTTP ${response.status}: ${text.slice(0, 80).trim() || '空应答'}`)
      }
    }

    /**
     * 内置中转（开箱即用的那条）。**电脑侧拨号形状，带 `/ws/connector`**：
     * 连接器自己拼这条路径（`src/transport/relay-link.ts` 的 `base.pathname`），
     * 而手机侧用的是根地址（它自己拼 `/ws-ticket` 与 `/ws/device`）。
     *
     * 写在这里是为了让「连接」卡的中转**是选出来的**：内置那条默认就在，
     * 用户换了自己的之后还能切回来，不用记地址（用户原话：「你这个应该是选择框的吧，
     * 可以选我的，可以自己输入」）。
     */
    const BUILTIN_RELAY_URL = 'wss://dsh.0t0.me/ws/connector'

    /**
     * 从中转拨号地址推导出浏览器控制台地址。
     *
     * 连接器拨的是 `wss://host/ws/connector`，而账号页在中转根上（`/login`）：
     * 只换协议、丢路径，不猜子路径。解析失败 / 空串 → `null`（不渲染链接）。
     * 已登录时 `/login` 会 302 到 `/console`，所以一个链接同时覆盖"注册/登录"与"看用量"。
     *
     * Note: 为什么按 host 推导、为什么链到 /login —— 见
     * `.agents/notes/implemented/2026-11-02-connection-card-opens-relay-console.md`
     */
    const relayConsoleUrlOf = (relayUrl) => {
      try {
        const url = new URL(relayUrl)
        if (url.protocol !== 'wss:' && url.protocol !== 'ws:') return null
        return `${url.protocol === 'wss:' ? 'https:' : 'http:'}//${url.host}/login`
      } catch {
        return null
      }
    }

    /** 侧边栏条目与主面板共用的 id（标准槽用字符串键，不 branded）。 */
    const PANEL_ID = 'dsh-mobile'

    const NS = 'settings.dshMobile'
    const zh = {
      title: '手机连接',
      // 侧边栏入口（`sidebar.panellist`，order 5：插件 0 之下、自动化任务 10 之上）。
      // 走标准列表槽、带 order —— 不硬编码位置，别的插件同样注册进来各自排序。
      entry: '手机',
      // ---- 「连接」卡（2026-10-29）----
      // 这一版把"这台电脑怎么连中转"摆上界面：地址、公网明文那一档、直连端口、令牌。
      // 每一格的写入都不需要重启 DSH（loader 的 `loader/volatile-update` 会通知插件重建通道）。
      connectTitle: '连接',
      versionTitle: '版本',
      versionCheck: '检查更新',
      versionChecking: '查询中…',
      versionNew: '有新版本 {v}',
      versionUpToDate: '已是最新',
      versionUnknown: '查不到最新版本：{reason}',
      versionOpen: '打开 npm 页面',
      channelsTitle: '通道与地址',
      devicesTitle: '已配对设备',
      pairTitle: '配对新手机',
      pairHint: '5 分钟内有效。',
      // 出码时向中转登记失败 = 这张码只有局域网那条路（契约 §12.1 的 lanOnly）。
      // 必须写在二维码旁边：用户出门 / 切流量之后才发现"配不上"就太晚了。
      pairLanOnly: '中转没登记上：这张码只能在同一 WiFi 下使用（跨网或用流量扫它配不上）',
      // **正面也要说**：登记成功时用户需要知道"出门还能用"，而不是只能从"没有警告"去猜。
      pairRelayReady: '两条路都在：同一 WiFi 直连；出门 / 用流量走中转（已登记）。',
      pairRelayOnly: '只有中转这条路（已登记）：不在同一 WiFi 也能扫。',
      thisOne: '本次',
      relayLabel: '中转',
      relayConnected: '已连接',
      relayConnecting: '重连中',
      relayStopped: '未运行',
      relayPublic: '公网',
      relayPrivate: '内网',
      addressLabel: '中转',
      addressPlaceholder: 'wss://relay.example.com/ws/connector',
      addressBuiltin: '内置中转',
      addressCustom: '自定义',
      // 文案必须写明"内容仍端到端加密"：明文的代价只是元数据（契约两档判据的同一句话）。
      allowPublicPlain: '允许公网明文 ws://',
      allowPublicPlainInert: '当前地址是 wss://，这项不生效',
      tokenLabel: '令牌',
      tokenSet: '已设置',
      tokenUnset: '未设置',
      tokenPlaceholder: '留空 = 不改',
      tokenClear: '清除令牌',
      tokenOpenConsole: '去注册 / 登录',
      // 后果句必须写清"会发生什么 + 怎么恢复"：删掉后重建中转通道会立刻断开，
      // 而恢复要在服务器上重签令牌（面板里贴回来即可，不用改文件）。
      tokenClearTitle: '清除连接器令牌？',
      tokenClearDescription: '这台电脑会立刻断开中转；恢复要重新签发令牌并填回。',
      listenLabel: '直连端口',
      listenOff: '停用直连',
      listenPortRequired: '取消「停用直连」后要填端口',
      save: '保存',
      saving: '保存中…',
      reconnecting: '正在重连…',
      settingsUnavailable: '这个部署没有设置服务（settings），无法在这里改配置',
      failedConnection: '保存失败：{reason}',
      failedToken: '令牌没写进去：{reason}（配置已生效）',
      failedClearToken: '清除令牌失败：{reason}',
      // 传输面**按方式分开关**（2026-10-17 用户：「不是有两中方式为啥就开关？
      // 后面我要是再加新的方式也就一个开关吗？」）。每个通道一个开关，
      // 加新方式时这个列表自动变长（数据来自 GET /transport），不为它改形状。
      allStart: '全部启动',
      allStop: '全部停止',
      channelRunning: '运行中',
      channelStopped: '未运行',
      channelStart: '启动',
      channelStop: '停止',
      failedChannel: '{action}失败：{reason}',
      // ---- 上报哪些地址（2026-10-18）----
      // 监听面**按设计枚举全部非内部网卡**（`transport/listener.ts:134-138`：
      // 过滤虚拟网卡靠名字匹配"又脆又漏"）。所以装了 VMware 的机器会多报几条
      // 手机永远拨不通的地址 —— 由用户点名禁用，比猜网卡名可靠。
      advertiseTitle: '上报给手机的地址',
      // 界面词与设备那一段一致：**删除**（= 不再报给手机；网卡还在，可恢复）。
      advertiseHide: '删除',
      advertiseShow: '恢复',
      advertiseShowHidden: '已删除 {n} 条 · 展开',
      advertiseHideHidden: '收起已删除',
      advertiseExtra: '手动添加',
      // **占位不写死 IP**：这一栏只收局域网明文直连（`advertise.ts` 的
      // `assertExtraAddress` 只放 `ws://` + 非公网），所以示例只能是"电脑的
      // 局域网地址"这个形状，不能摆一个别人家网段的 IP 当范例。
      advertiseAddPlaceholder: 'ws://<电脑局域网IP>:8790',
      advertiseAdd: '添加',
      failedAdvertise: '改上报地址失败：{reason}',
      close: '关闭',
      pairedAt: '配对于',
      // **重新配对 = 换凭证、替换旧行**（2026-10-17 用户："为啥每次扫都是一个
      // 新设备"）：手机重新扫码时自报旧 pairingId，电脑侧按它替换同一行
      // （换密钥/换令牌，配对于保留首次时刻）。首配（没有旧行）才写新行。
      // 取舍：.agents/notes/implemented/2026-10-17-repair-replaces-device-row.md
      // 连接态（桥接拨通了吗）与设备态（这台在跑吗）是两问，用词因此不同：
      // 前者答"我的手机连上了吗"，后者照 DSH 的状态词（`locales.ts:54,63`）。
      running: '运行中',
      idle: '未运行',
      foreground: '前台',
      background: '后台',
      // **独占（1:1）**：同一时刻只有一台设备在服务。它与"在线"不是一回事 ——
      // 面板要能指出"就是它占着这台电脑"，那才是新手机连不上的原因。
      serving: '在服务',
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
      // **接管**：占用者正在服务时把它换下来。它走的还是**停用**那条写路径
      // （没有第二条"踢人"接口），所以后果句必须把"会释放什么 / 不会断什么"说全。
      takeOver: '接管',
      confirmTakeOverTitle: '接管这台电脑？（「{name}」正在服务）',
      confirmTakeOverDescription: '接管会停用占用设备；它下次连回来要重新配对。',
      failedTakeOver: '接管失败：{reason}',
      disableSelected: '停用所选',
      selectedAllDisabled: '选中的设备都已停用；要清理记录请到下面「已停用」里删除',
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
      // 处理中的设备：**先停用再删除**（一步到位的删除）。顺序不是界面偏好：
      // 停用会立刻收连接、让那台手机拿到终态；先删行会让它永远收不到"你被移除了"。
      confirmRemoveActiveTitle: '删除「{name}」？它现在还在用。',
      confirmRemoveActiveDescription: '会先停用它（立刻下线、拿到终态），再抹掉这条记录。那台手机必须重新扫码配对。',
      // 显式删除**可以删在线的**（见文件头），所以在线那台不是"不会删除"，
      // 而是"它在用，删了就得重新配对"——"跳过"只属于按状态批量。
      confirmDisableSelectedTitle: '停用所选的 {n} 台设备？',
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
      // ---- Connection card (2026-10-29) ----
      connectTitle: 'Connection',
      versionTitle: 'Version',
      versionCheck: 'Check for updates',
      versionChecking: 'Checking…',
      versionNew: 'Update available: {v}',
      versionUpToDate: 'Up to date',
      versionUnknown: 'Could not check: {reason}',
      versionOpen: 'Open npm page',
      channelsTitle: 'Channels & addresses',
      devicesTitle: 'Paired devices',
      pairTitle: 'Pair a new phone',
      pairHint: 'Valid for 5 minutes.',
      pairLanOnly: 'Not registered with the relay: this code only works on the same Wi-Fi (it will not pair over the internet or mobile data).',
      pairRelayReady: 'Both routes are ready: direct on the same Wi-Fi, or via the relay (registered) when you are away.',
      pairRelayOnly: 'Relay only (registered): it works away from this Wi-Fi too.',
      thisOne: 'this session',
      relayLabel: 'Relay',
      relayConnected: 'Connected',
      relayConnecting: 'Reconnecting',
      relayStopped: 'Stopped',
      relayPublic: 'public',
      relayPrivate: 'private',
      addressLabel: 'Relay',
      addressPlaceholder: 'wss://relay.example.com/ws/connector',
      addressBuiltin: 'Built-in',
      addressCustom: 'Custom',
      allowPublicPlain: 'Allow plaintext ws:// to a public host',
      allowPublicPlainInert: 'No effect on wss://',
      tokenLabel: 'Token',
      tokenSet: 'Set',
      tokenUnset: 'Not set',
      tokenPlaceholder: 'Leave empty to keep',
      tokenClear: 'Clear token',
      tokenOpenConsole: 'Sign up / sign in',
      tokenClearTitle: 'Clear the connector token?',
      tokenClearDescription: 'This computer will disconnect from the relay; reissue a token and paste it back to recover.',
      listenLabel: 'Direct port',
      listenOff: 'Disable direct connections',
      listenPortRequired: 'Enter a port after disabling direct connections',
      save: 'Save',
      saving: 'Saving…',
      reconnecting: 'Reconnecting…',
      settingsUnavailable: 'This deployment has no settings service, so configuration cannot be edited here',
      failedConnection: 'Could not save: {reason}',
      failedToken: 'The token was not stored: {reason} (the rest was saved)',
      failedClearToken: 'Could not clear the token: {reason}',
      // Per-method transport switches (2026-10-17). One switch per channel;
      // a new method grows this list (data from GET /transport) — the shape
      // never changes.
      allStart: 'Start all',
      allStop: 'Stop all',
      channelRunning: 'running',
      channelStopped: 'stopped',
      channelStart: 'Start',
      channelStop: 'Stop',
      failedChannel: 'Could not {action}: {reason}',
      advertiseTitle: 'Addresses reported to the phone',
      advertiseHide: 'Delete',
      advertiseShow: 'Restore',
      advertiseShowHidden: '{n} removed · show',
      advertiseHideHidden: 'hide removed',
      advertiseExtra: 'added',
      advertiseAddPlaceholder: 'ws://<LAN-IP-of-this-PC>:8790',
      advertiseAdd: 'Add',
      failedAdvertise: 'Could not change reported addresses: {reason}',
      close: 'Close',
      pairedAt: 'Paired',
      running: 'running',
      idle: 'idle',
      foreground: 'foreground',
      background: 'background',
      serving: 'serving',
      disabled: 'disabled',
      neverSeen: 'never used',
      justNow: 'just now',
      minutesAgo: '{n}m ago',
      hoursAgo: '{n}h ago',
      daysAgo: '{n}d ago',
      disable: 'Disable',
      enable: 'Enable',
      remove: 'Delete',
      takeOver: 'Take over',
      confirmTakeOverTitle: 'Take over this computer? ("{name}" is serving)',
      confirmTakeOverDescription: 'Taking over disables the current device; it must pair again to come back.',
      failedTakeOver: 'Could not take over: {reason}',
      disableSelected: 'Disable selected',
      selectedAllDisabled: 'Every selected device is already disabled. Use "disabled" below to purge records.',
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
      confirmRemoveActiveTitle: 'Delete "{name}"? It is still in use.',
      confirmRemoveActiveDescription: 'It is disabled first (drops offline at once, gets a terminal state), then the record is removed. That phone must pair again.',
      confirmDisableSelectedTitle: 'Disable the {n} selected devices?',
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
        borderRadius: 10,
        // 卡片用 DSH 的图层底色（`layer-1`）：以前是纯描边，在深色底上像一块虚线框，
        // 视觉层级全靠字重硬撑。
        background: 'var(--dsw-alias-bg-layer-1)',
        padding: '14px 16px',
      },
      /** 分段选择（两档，替代原生 `<select>`：原生弹层没法用 token 上色）。 */
      segment: {
        display: 'inline-flex', flex: 'none',
        border: '1px solid var(--dsw-alias-border-inverted)',
        borderRadius: 8, overflow: 'hidden',
      },
      row: { display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' },
      /** 卡里的分区标题：比正文高一档字重，不再靠 inline 拼。 */
      h3: { margin: '0 0 10px', fontSize: 13, fontWeight: 600, color: 'var(--dsw-alias-label-primary)' },
      /** 卡头：标题 + 右侧动作（保存 / 批量 / 清空都在这条线上，不沉到卡底）。 */
      cardHead: { display: 'flex', alignItems: 'center', gap: 8, margin: '0 0 10px' },
      /** 顶部总览条：中转 / 在线 / 直连三件事一行读完。 */
      hero: {
        display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap',
        padding: '10px 14px', borderRadius: 10,
        background: 'var(--dsw-alias-bg-layer-2)',
        border: '1px solid var(--dsw-alias-border-inverted)',
      },
      sep: { width: 1, height: 16, background: 'var(--dsw-alias-border-inverted)', flex: 'none' },
      /** 字段行：`[标签 64px][控件][值]`，卡内所有行同一套。 */
      field: { display: 'flex', alignItems: 'center', gap: 10, minHeight: 30, flexWrap: 'wrap' },
      fieldK: { width: 64, flex: 'none', fontSize: 12, color: 'var(--dsw-alias-label-tertiary)' },
      /** 列表行：状态点 + 两行文字 + 行尾动作。 */
      rowLine: {
        display: 'flex', alignItems: 'center', gap: 10,
        padding: '8px 0', borderTop: '1px solid var(--dsw-alias-border-inverted)',
      },
      /** 输入框获得焦点：DSH 的焦点环（`--dsw-focus-ring-*` 的等价形态）。 */
      inputFocus: {
        borderColor: 'var(--dsw-alias-state-business-primary)',
        boxShadow: '0 0 0 1px var(--dsw-alias-state-business-primary)',
      },
      /** 空态 / 失败态：同一套造型，只换颜色（不再一处一句散装小字）。 */
      notice: (color) => ({
        display: 'flex', alignItems: 'flex-start', gap: 8,
        padding: '12px 14px', borderRadius: 8, fontSize: 12.5, lineHeight: 1.6,
        color, border: `1px solid ${color}`, background: 'transparent',
      }),
      /** 窄窗下的设备行（表格换成卡片）。 */
      devCard: {
        display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8,
        padding: '10px 2px', borderTop: '1px solid var(--dsw-alias-border-inverted)',
      },
      /** 胶囊（已设置 / 在服务 / 台数）。 */
      pill: (color) => ({
        fontSize: 11, lineHeight: 1.5, padding: '2px 8px', borderRadius: 999,
        color, background: 'transparent', border: `1px solid ${color}`,
      }),
      /** 卡里的小分区（传输方式 / 上报地址）：一条细分隔线 + 一档更弱的标题。 */
      subhead: { margin: '12px 0 6px', fontSize: 12, color: 'var(--dsw-alias-label-tertiary)' },
      dot: (color) => ({
        width: 8, height: 8, borderRadius: '50%', background: color, flex: 'none',
      }),
      label: { color: 'var(--dsw-alias-label-secondary)', fontSize: 12 },
      value: { color: 'var(--dsw-alias-label-primary)', fontSize: 13 },
      table: { width: '100%', borderCollapse: 'collapse', fontSize: 13 },
      th: {
        textAlign: 'left', padding: '4px 8px', fontWeight: 500, fontSize: 11.5,
        color: 'var(--dsw-alias-label-tertiary)',
        borderBottom: '1px solid var(--dsw-alias-border-inverted)',
      },
      td: {
        padding: '7px 8px', color: 'var(--dsw-alias-label-primary)', fontSize: 12.5,
        borderBottom: '1px solid var(--dsw-alias-border-inverted)',
      },
      dim: { color: 'var(--dsw-alias-label-caption)' },
      warn: { color: 'var(--dsw-alias-state-warn-label)' },
      err: { color: 'var(--dsw-alias-state-error-primary)' },
      ok: { color: 'var(--dsw-alias-state-success-primary)' },
      /** 文本/数字输入框（「连接」卡与上报地址那两处共用这一份）。 */
      input: {
        flex: 1,
        minWidth: 0,
        padding: '6px 8px',
        borderRadius: 8,
        border: '1px solid var(--dsw-alias-border-inverted)',
        background: 'transparent',
        color: 'inherit',
        font: 'inherit',
        fontSize: 12,
      },
      btn: {
        font: 'inherit', fontSize: 12.5, cursor: 'pointer', borderRadius: 6,
        border: '1px solid var(--dsw-alias-border-inverted)',
        background: 'var(--dsw-alias-interactive-bg-hover)',
        color: 'var(--dsw-alias-label-primary)',
        padding: '4px 11px', whiteSpace: 'nowrap',
      },
      /** 软停用：描边红。可逆，但确实会打断那台手机。 */
      btnDanger: {
        font: 'inherit', fontSize: 12.5, cursor: 'pointer', borderRadius: 6,
        border: '1px solid var(--dsw-alias-state-error-primary)',
        background: 'transparent',
        color: 'var(--dsw-alias-state-error-primary)',
        padding: '4px 11px', whiteSpace: 'nowrap',
      },
      /** 硬删：实心红（照 DSH `dangerButton` 把 primary fill 换成 error 的做法）。 */
      btnDangerSolid: {
        font: 'inherit', fontSize: 12.5, cursor: 'pointer', borderRadius: 6,
        border: '1px solid var(--dsw-alias-state-error-primary)',
        background: 'var(--dsw-alias-state-error-primary)',
        color: 'var(--dsw-alias-label-primary-foreground)',
        padding: '4px 11px', whiteSpace: 'nowrap',
      },
      btnDisabled: { opacity: 0.5, cursor: 'default' },
      /** 分段里的一个选项（选中的那一档用 active 底色，未选的是透明）。 */
      segBtn: (active) => ({
        font: 'inherit', fontSize: 12.5, cursor: 'pointer', border: 'none',
        padding: '5px 12px',
        background: active ? 'var(--dsw-alias-interactive-bg-active)' : 'transparent',
        color: active ? 'var(--dsw-alias-label-primary)' : 'var(--dsw-alias-label-secondary)',
      }),
      /** 多选浮现栏：不占行高，只在有勾选时出现。 */
      bar: {
        display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap',
        margin: '0 0 8px', padding: '6px 8px', borderRadius: 6,
        background: 'var(--dsw-alias-interactive-bg-active)',
      },
      /** 确认对话框的遮罩：**挂到 body 上 + `position: fixed`**（渲染处用
       *  `ReactDOM.createPortal`，与主面板同一个做法）。
       *
       *  早先这里是 `position: absolute` 于面板自己的 `.wrap` 上，理由是"内嵌页可能
       *  带 transform"。代价是：**清单很长时，对话框钉在内容顶部**——用户滚到下面点
       *  「停用」，框出现在他看不见的地方（用户原话："居然弹框在上面都被遮挡了？
       *  不是屏幕居中？？"）。挂到 body 之后既居中又不会被任何滚动容器裁掉。 */
      mask: {
        position: 'fixed', inset: 0, zIndex: 1000,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: 'var(--dsw-alias-bg-mask-1)',
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
     * 「版本」卡片下面那一句。**四种结论都说实话**：
     * 还没查 / 有新版 / 已是最新 / 查不到（带原话）。
     */
    const versionLine = (t, info) => {
      if (info === null) return ''
      if (typeof info.error === 'string' && info.error !== '') {
        return t('versionUnknown', { reason: info.error })
      }
      if (info.hasUpdate === true && typeof info.latest === 'string') {
        return t('versionNew', { v: info.latest })
      }
      return t('versionUpToDate')
    }

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
        const body = await jsonOf(response)
        if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`)
        await refresh()
      } catch (caught) {
        throw new Error(messageOf(caught))
      }
    }

    /**
     * 设定一条"上报地址"的表态（`hide` / `extra` / `clear`）。
     *
     * 与服务端同一条纪律：**跑完重拉真值**，不按本地点击乐观翻转 ——
     * 校验不过（公网地址、`wss://`）时服务端会 400，而乐观翻转会让界面
     * 显示"已藏掉"而手机照样收到它。
     */
    const setAdvertise = async (url, kind, refresh) => {
      try {
        const response = await fetch(ADVERTISE, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ url, kind }),
        })
        const body = await jsonOf(response)
        if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`)
        await refresh()
        return true
      } catch (caught) {
        throw new Error(messageOf(caught))
      }
    }

    /**
     * 服务端真值 → 表单草稿。
     *
     * `listenDisabled` 由 `listenPort === 0` 推出（`0 = 不监听`，与配置同一语义，
     * `src/config.ts:26-29`）—— 界面**不发明**"上次用的那个端口"。
     */
    const draftOf = (view) => ({
      // **没配置过 ⇒ 预选内置那条**（"开箱即用"不是一句口号）：
      // 空串会让「中转」落在「自定义」+ 空输入框上，用户看到的是"地址没显示"，
      // 还得自己去点一下「内置中转」。配置里已经有别的值（自部署）时原样回填。
      relayUrl: view && view.value ? view.value.relayUrl || BUILTIN_RELAY_URL : BUILTIN_RELAY_URL,
      allowInsecurePublic: Boolean(view && view.value && view.value.allowInsecurePublic),
      listenPort: view && view.value ? String(view.value.listenPort) : '',
      listenDisabled: !view || !view.value || view.value.listenPort === 0,
      tokenInput: '',
    })

    /**
     * 「连接」卡：这台电脑怎么连中转。
     *
     * 四行 + 一个保存键，**只显示白名单那四格**（地址 / 公网明文 / 令牌 / 直连端口）。
     * 电脑侧的 `describe` 会把该条目 11 个 volatile 字段全给出来，全摆上来只是把
     * "改配置"的爆炸半径变大 —— 理由与判据见 `src/admin/connection-card.ts` 文件头。
     *
     * 纯渲染、无 hook：状态在 `AdminPanel` 里（它同时要驱动通道开关与刷新）。
     */
    function ConnectionCard(props) {
      const t = props.t
      const view = props.view
      const draft = props.draft
      const busy = props.busy
      const error = props.error
      const relayChannel = props.relayChannel

      if (view === null) {
        return h('div', { key: 'conn', style: S.card },
          h('h3', { style: S.h3 }, t('connectTitle')),
          h('p', { style: S.dim }, '…'),
        )
      }
      if (view.capable !== true) {
        return h('div', { key: 'conn', style: S.card },
          h('h3', { style: S.h3 }, t('connectTitle')),
          h('p', { key: 'na', style: { ...S.label, ...S.warn, margin: 0, lineHeight: 1.6 } }, t('settingsUnavailable')),
        )
      }

      const status = view.relay.connected
        ? t('relayConnected')
        : view.relay.running ? t('relayConnecting') : t('relayStopped')
      const dotColor = view.relay.connected
        ? 'var(--dsw-alias-state-success-primary)'
        : view.relay.running ? 'var(--dsw-alias-state-warn-label)' : 'var(--dsw-alias-state-idle-primary)'
      const scope = view.relay.public ? t('relayPublic') : t('relayPrivate')
      const plaintext = draft.relayUrl.startsWith('ws:')
      // 「选中转」那两档：等于内置值 = 内置那一档，其余一律算自定义
      // （空串也算自定义：还没填过，得给他输入框）。
      const usingBuiltinRelay = draft.relayUrl === BUILTIN_RELAY_URL
      const consoleUrl = relayConsoleUrlOf(draft.relayUrl)
      const editable = busy !== ''
      const errorOf = (slot) => (error !== null && error.slot === slot ? error.message : null)
      // 焦点环：`adminPanel` 持有"哪一格有焦点"，这里只按名字套样式
      // （不用 `:focus` 伪类 —— 手写 bundle 没有样式表，inline style 碰不到伪类）。
      const ring = (slot) => (props.focused === slot ? S.inputFocus : null)

      return h('div', { key: 'conn', style: S.card },
        // 卡头：标题 + 保存。保存**留在改它的那一行旁边**，不再沉到卡底
        // （用户改完地址要往上/往下找按钮，是最常见的"改了半天没生效"）。
        h('div', { key: 'hd', style: S.cardHead },
          h('span', { style: { fontSize: 13, fontWeight: 600 } }, t('connectTitle')),
          h('span', { style: { flex: 1 } }),
          h('button', {
            type: 'button',
            style: editable ? { ...S.btn, ...S.btnDisabled } : S.btn,
            disabled: editable,
            onClick: props.onSave,
          }, busy === 'connection' ? t('saving') : t('save')),
          busy === 'connection' ? h('span', { style: S.label }, t('reconnecting')) : null,
        ),

        // 冲突/整卡失败放**卡片顶部**：它不属于任何一格，放到某一格下面会让人以为只影响那一格。
        errorOf('card') === null
          ? null
          : h('p', { role: 'alert', style: { ...S.label, ...S.err, margin: '0 0 8px', lineHeight: 1.6 } }, errorOf('card')),

        // ① 中转状态 —— 最高频的一问
        h('div', { style: S.row },
          h('span', { style: S.label }, t('relayLabel')),
          h('span', { style: S.dot(dotColor) }),
          h('span', { style: S.value }, status),
          h('span', { style: S.label }, `· ${scope}`),
        ),
        // 没跑起来时把原因接在下面（缺令牌 / 地址坏 / 端口占）：原因来自通道真值，
        // 不在这里另拼一套说法。
        view.relay.running || !relayChannel
          ? null
          : h('p', { style: { ...S.label, margin: '4px 0 0', lineHeight: 1.6 } }, relayChannel.detail),

        // ② 中转地址：**先选，再（需要时）填**。
        // 内置那条是这个项目自己的中转；「自定义」才出输入框。换回来只要选一下，
        // 不必记得那个域名。
        h('div', { style: { ...S.row, marginTop: 10 } },
          h('span', { style: S.fieldK }, t('addressLabel')),
          // **分段，不用原生 `<select>`**：下拉的弹层是浏览器画的，没法吃 DSH 的
          // token（深色主题下第二项直接看不清），而且多一次点击。
          h('div', { style: S.segment, role: 'group', 'aria-label': t('addressLabel') },
            h('button', {
              type: 'button',
              disabled: editable,
              'aria-pressed': usingBuiltinRelay,
              style: S.segBtn(usingBuiltinRelay),
              onClick: () => props.onDraft({ relayUrl: BUILTIN_RELAY_URL }),
            }, t('addressBuiltin')),
            h('button', {
              type: 'button',
              disabled: editable,
              'aria-pressed': !usingBuiltinRelay,
              style: S.segBtn(!usingBuiltinRelay),
              // 从内置切到自定义时清空：输入框里摆着内置那条，会让人以为改过了。
              onClick: () => props.onDraft({ relayUrl: usingBuiltinRelay ? '' : draft.relayUrl }),
            }, t('addressCustom')),
          ),
          usingBuiltinRelay
            ? h('span', { style: { ...S.value, fontSize: 12, ...S.dim } }, BUILTIN_RELAY_URL)
            : h('input', {
                type: 'text',
                value: draft.relayUrl,
                placeholder: t('addressPlaceholder'),
                disabled: editable,
                onChange: (event) => props.onDraft({ relayUrl: event.target.value }),
                onFocus: () => props.onFocusField('relay'),
                onBlur: () => props.onBlurField(),
                style: { ...S.input, ...ring('relay') },
              }),
        ),
        errorOf('address') === null
          ? null
          : h('p', { role: 'alert', style: { ...S.label, ...S.err, margin: '4px 0 0' } }, errorOf('address')),

        // ③ 公网明文那一档（与手机侧 `net.allow_plaintext_public` 同一判据的电脑侧开关）
        h('label', { style: { ...S.row, marginTop: 6, cursor: plaintext ? 'pointer' : 'default' } },
          h('input', {
            type: 'checkbox',
            checked: draft.allowInsecurePublic,
            disabled: editable || !plaintext,
            onChange: (event) => props.onDraft({ allowInsecurePublic: event.target.checked }),
          }),
          h('span', { style: { ...S.label, flex: 1 } }, t('allowPublicPlain')),
        ),
        plaintext
          ? null
          : h('p', { style: { ...S.label, ...S.dim, margin: '2px 0 0 24px' } }, t('allowPublicPlainInert')),

        // ④ 令牌：**只写不读**。留空=不改；清除是单独的破坏性动作。
        h('div', { style: { ...S.row, marginTop: 10 } },
          h('span', { style: S.fieldK }, t('tokenLabel')),
          h('span', {
            style: S.pill(view.token.configured
              ? 'var(--dsw-alias-state-success-primary)'
              : 'var(--dsw-alias-label-tertiary)'),
          }, view.token.configured ? t('tokenSet') : t('tokenUnset')),
          h('span', { style: { flex: 1 } }),
          consoleUrl === null
            ? null
            : h('a', {
                href: consoleUrl,
                target: '_blank',
                rel: 'noopener noreferrer',
                style: {
                  ...S.btn,
                  textDecoration: 'none',
                  display: 'inline-flex',
                  alignItems: 'center',
                  marginRight: 6,
                },
              }, t('tokenOpenConsole')),
          view.token.configured
            ? h('button', {
                type: 'button',
                style: editable ? { ...S.btnDanger, ...S.btnDisabled } : { ...S.btnDanger, padding: '3px 10px' },
                disabled: editable,
                onClick: props.onClearToken,
              }, t('tokenClear'))
            : null,
        ),
        h('div', { style: { ...S.row, marginTop: 6 } },
          // `type=password` + 空值：浏览器/读屏不会把令牌念出来；`autocomplete` 关掉，
          // 免得密码管理器把这里的"连接器令牌"当成某个网站的登录口令。
          h('input', {
            type: 'password',
            value: draft.tokenInput,
            placeholder: t('tokenPlaceholder'),
            autoComplete: 'new-password',
            disabled: editable,
            onChange: (event) => props.onDraft({ tokenInput: event.target.value }),
            onFocus: () => props.onFocusField('token'),
            onBlur: () => props.onBlurField(),
            style: { ...S.input, ...ring('token') },
          }),
        ),
        errorOf('token') === null
          ? null
          : h('p', { role: 'alert', style: { ...S.label, ...S.err, margin: '4px 0 0' } }, errorOf('token')),

        // ⑤ 直连端口（0 = 停用直连）
        h('div', { style: { ...S.row, marginTop: 10 } },
          h('span', { style: S.fieldK }, t('listenLabel')),
          h('input', {
            type: 'number',
            min: 0,
            max: 65535,
            value: draft.listenPort,
            disabled: editable || draft.listenDisabled,
            onChange: (event) => props.onDraft({ listenPort: event.target.value }),
            onFocus: () => props.onFocusField('port'),
            onBlur: () => props.onBlurField(),
            style: { ...S.input, maxWidth: 120, flex: 'none', ...ring('port') },
          }),
          h('label', { style: { ...S.row, cursor: editable ? 'default' : 'pointer' } },
            h('input', {
              type: 'checkbox',
              checked: draft.listenDisabled,
              disabled: editable,
              onChange: (event) => props.onDraft({
                listenDisabled: event.target.checked,
                // 取消停用但当前是 0：清空端口框，等用户自己填（**不猜默认端口**）。
                ...(event.target.checked || draft.listenPort !== '0' ? {} : { listenPort: '' }),
              }),
            }),
            h('span', { style: S.label }, t('listenOff')),
          ),
        ),
        errorOf('port') === null
          ? null
          : h('p', { role: 'alert', style: { ...S.label, ...S.err, margin: '4px 0 0' } }, errorOf('port')),

      )
    }

    /** 管理面板本体（状态 + 启停 + 设备 + 配对）。**只有一个视图** ——
     *  2026-10-17 从插件页卡迁到侧边栏弹框后，'summary' 卡片行那个视图
     *  随入口一起没了，留着就是死代码。 */
    function AdminPanel(props) {
      const t = props.t
      const [status, setStatus] = useState(null)
      const [channels, setChannels] = useState([])
      const [advertise, setAdvertiseView] = useState(null)
      const [advertiseInput, setAdvertiseInput] = useState('')
      // 被"删除"（= 不上报）的地址默认收起：网卡还在，但它们不该占着列表。
      const [showHiddenAddresses, setShowHiddenAddresses] = useState(false)
      /** 哪一格输入框有焦点（手写 bundle 没有样式表，焦点环只能靠 state 套）。 */
      const [focusedField, setFocusedField] = useState('')
      /** 窄窗：侧边栏弹框在窄屏/手机浏览器上会把设备表压扁，这里收起两列。 */
      const [narrow, setNarrow] = useState(false)
      // ---- 「连接」卡 ----
      /** 电脑侧的真值（`GET /connection`）。`null` = 还没读回来。 */
      const [connection, setConnection] = useState(null)
      /** 表单草稿。**与服务端真值分开**：没保存前界面显示用户改的，保存失败时能被服务端值覆盖回去。 */
      const [draft, setDraft] = useState(null)
      /** 卡内的字段级错误：`{ field, message }`（地址/端口/令牌各报各的）。 */
      const [connectionError, setConnectionError] = useState(null)
      const [error, setError] = useState('')
      const [qr, setQr] = useState(null)
      // 「检查更新」：一次只查一次，结论留在卡片上（不弹框）。
      const [updateInfo, setUpdateInfo] = useState(null)
      const [updateBusy, setUpdateBusy] = useState(false)
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
          // **四个读面一起拉**：status 管设备与连接态，/transport 管按方式的
          // 通道开关，/advertise 管"上报给手机哪些地址"，/connection 管
          // "这台电脑怎么连中转"。只拉一个的话，另一个面永远停在空态（假数据）。
          const [statusResponse, transportResponse, advertiseResponse, connectionResponse] = await Promise.all([
            fetch(STATUS), fetch(TRANSPORT), fetch(ADVERTISE), fetch(CONNECTION),
          ])
          if (!statusResponse.ok) throw new Error(`${t('loadFailed')}：HTTP ${statusResponse.status}`)
          if (!transportResponse.ok) throw new Error(`${t('loadFailed')}：HTTP ${transportResponse.status}`)
          // `/advertise` **不参与硬失败**：它管的是"上报哪些地址"这一节。
          // 读不到（旧版连接器没有这个路由 / 存储还没就绪）就只让那一节空着，
          // 不该让设备管理与配对一起变成错误页 —— 那两个面与它无关。
          setStatus(await statusResponse.json())
          const transport = await transportResponse.json()
          setChannels(Array.isArray(transport.channels) ? transport.channels : [])
          // **读面兜底成空表**：`candidates` 来自监听面的网卡枚举，`listenPort: 0`
          // 时本来就是空的。直接 `.map` 会让整个面板崩成一块白。
          const advertiseBody = advertiseResponse.ok ? await advertiseResponse.json() : {}
          setAdvertiseView({
            advertised: Array.isArray(advertiseBody.advertised) ? advertiseBody.advertised : [],
            hidden: Array.isArray(advertiseBody.hidden) ? advertiseBody.hidden : [],
            candidates: Array.isArray(advertiseBody.candidates) ? advertiseBody.candidates : [],
          })
          // `/connection` 同样**不参与硬失败**（理由同上）。读到了就回填真值；
          // 草稿只在**还没有草稿**时（首次）由真值生成 —— 否则刷新会把用户
          // 正在编辑的地址冲掉，而保存失败时我们已经显式回填过。
          if (connectionResponse.ok) {
            const connectionBody = await connectionResponse.json()
            setConnection(connectionBody)
            // 已有草稿就不动它：自动刷新（停启通道 / 改上报地址后都会重拉）
            // 不能把用户正在编辑的地址冲掉。冲突时由 409 的回执显式覆盖。
            setDraft((current) => (current === null ? draftOf(connectionBody) : current))
          }
          setError('')
        } catch (caught) {
          // **失败要留声**：静默的空面板会让人以为"没有设备"。
          setError(messageOf(caught))
        }
      }, [t])

      // 首渲染就把状态与通道列表拉回来（面板的唯一数据源）。
      useEffect(() => { refresh() }, [refresh])

      // 窄窗判定：`matchMedia` 不存在（测试桩/非浏览器环境）就当宽窗，
      // 不猜一个宽度 —— 那会让测试里的形状随机器变化。
      useEffect(() => {
        if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return
        const query = window.matchMedia('(max-width: 720px)')
        setNarrow(query.matches === true)
        const onChange = (event) => setNarrow(event.matches === true)
        query.addEventListener('change', onChange)
        return () => query.removeEventListener('change', onChange)
      }, [])

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
          const body = await jsonOf(response)
          if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`)
          if (typeof body.svg !== 'string') throw new Error('电脑侧没有返回二维码')
          // SVG 是 UTF-8 文本，用 encodeURIComponent 转 data URI —— btoa 只吃 Latin1。
          setQr({
            src: `data:image/svg+xml,${encodeURIComponent(body.svg)}`,
            expiresAt: body.expiresAt,
            lanOnly: body.lanOnly === true,
            lanAvailable: body.lanAvailable === true,
          })
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
      /**
       * 失败文案。**收成一张表**而不是把键名当参数传：`client-i18n.test.ts` 要求
       * 每个键都出现在一处 `t('…')` 字面量调用里（变量键会被判成"零调用点的废弃键"）。
       */
      const FAIL_TEXT = {
        disable: (reason) => t('failedDisable', { reason }),
        enable: (reason) => t('failedEnable', { reason }),
        takeOver: (reason) => t('failedTakeOver', { reason }),
      }

      /** 单个端点的原始调用（不碰 busy / error）：批量停用要复用它，别复制一遍请求。 */
      const callEnabled = async (devId, enabled) => {
        const response = await fetch(ENABLED, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ devId, enabled }),
        })
        const body = await jsonOf(response)
        if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`)
      }

      const setEnabled = async (device, enabled, failText = enabled ? FAIL_TEXT.enable : FAIL_TEXT.disable) => {
        setBusy(device.id)
        try {
          await callEnabled(device.id, enabled)
          await refresh()
        } catch (caught) {
          setError(failText(messageOf(caught)))
        } finally {
          setBusy('')
        }
      }

      /**
       * **接管**：占用者正在服务，操作者明确要把它换下来。
       *
       * 它**走的是停用那条写路径**（`POST /devices/enabled {enabled:false}`）——
       * 没有第二条"踢人"接口，也不该有（决策 6：不自动抢占，接管是显式动作）。
       * 占用位是 `presence` 的在线记录，所以停用一次就释放（已吊销的行不占位）。
       */
      const takeOver = (device) => askConfirm({
        title: t('confirmTakeOverTitle', { name: device.name }),
        description: t('confirmTakeOverDescription'),
        confirmLabel: t('takeOver'),
        run: async () => { await setEnabled(device, false, FAIL_TEXT.takeOver) },
      })

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
          const body = await jsonOf(response)
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

      /**
       * 查一次更新。**失败也要把原话显示出来** —— 查不到不等于"已是最新"。
       *
       * 结论留在卡片上（不弹框）：这是"看一眼"的事，弹框会挡住下面正在做的事。
       */
      const checkUpdate = async () => {
        setUpdateBusy(true)
        try {
          const response = await fetch(UPDATE)
          const body = await jsonOf(response)
          if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`)
          setUpdateInfo(body)
        } catch (caught) {
          setUpdateInfo({
            current: updateInfo === null ? '—' : updateInfo.current,
            latest: null,
            hasUpdate: false,
            url: null,
            error: messageOf(caught),
          })
        } finally {
          setUpdateBusy(false)
        }
      }

      /** 藏掉 / 恢复上报 / 追加一条地址。失败带原因（不静默）。 */
      const runAdvertise = async (url, kind) => {
        setBusy(`advertise:${url}`)
        try {
          await setAdvertise(url, kind, refresh)
          if (kind === 'extra') setAdvertiseInput('')
        } catch (caught) {
          setError(t('failedAdvertise', { reason: messageOf(caught) }))
        } finally {
          setBusy('')
        }
      }

      /**
       * 打一次 `/connection` 的 POST。
       *
       * **回执里的真值先回填、再判成败**：409（配置在别处改过）与 400 都带着
       * 保存之后的真值，界面据此回到"电脑侧的事实"，而不是停在用户那一版草稿上。
       *
       * @returns 200 时为 true；失败时错误已经落到 `connectionError`（字段级）。
       */
      const sendConnection = async (payload) => {
        setBusy('connection')
        setConnectionError(null)
        try {
          const response = await fetch(CONNECTION, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify(payload),
          })
          const body = await jsonOf(response)
          if (body !== null && typeof body === 'object' && body.view) {
            setConnection(body.view)
            setDraft(draftOf(body.view))
          }
          if (!response.ok) {
            const field = body !== null && typeof body === 'object' && typeof body.field === 'string'
              ? body.field
              : 'body'
            const slot = field === 'relayUrl' ? 'address'
              : field === 'listenPort' ? 'port'
                : field === 'token' ? 'token'
                  : 'card'
            const reason = body !== null && typeof body === 'object' && typeof body.error === 'string'
              ? body.error
              : `HTTP ${response.status}`
            // 令牌那一格的失败**不许**说成"保存失败"：配置那一半确实已经生效了
            // （电脑侧回执里带 `configApplied`），两件事分开报。
            const message = slot !== 'token'
              ? (slot === 'address' || slot === 'port' ? reason : t('failedConnection', { reason }))
              : t(body.configApplied === true ? 'failedToken' : 'failedClearToken', { reason })
            setConnectionError({ slot, message })
            return false
          }
          if (typeof body.relayError === 'string' && body.relayError !== '') setError(body.relayError)
          return true
        } catch (caught) {
          setConnectionError({ slot: 'card', message: t('failedConnection', { reason: messageOf(caught) }) })
          return false
        } finally {
          setBusy('')
        }
      }

      /**
       * 保存「连接」卡。
       *
       * **只发真的变了的键**（地址/开关/端口/令牌各一格）。端口为「停用直连」时发 0。
       * 取消勾选后端口框还是空的话在本层就拦住 —— 发个 0 上去会把"我想开直连"
       * 静默变成"继续不监听"。
       */
      const saveConnection = async () => {
        if (connection === null || draft === null) return
        const payload = { revision: connection.revision }
        const before = connection.value || {}
        if (draft.relayUrl !== (before.relayUrl || '')) payload.relayUrl = draft.relayUrl
        if (draft.allowInsecurePublic !== Boolean(before.allowInsecurePublic)) {
          payload.allowInsecurePublic = draft.allowInsecurePublic
        }
        if (!draft.listenDisabled && !/^\d+$/.test(String(draft.listenPort).trim())) {
          setConnectionError({ slot: 'port', message: t('listenPortRequired') })
          return
        }
        const port = draft.listenDisabled ? 0 : Number(draft.listenPort)
        if (port !== before.listenPort) payload.listenPort = port
        if (draft.tokenInput.trim() !== '') payload.token = { op: 'set', value: draft.tokenInput }

        const touched = 'relayUrl' in payload || 'allowInsecurePublic' in payload
          || 'listenPort' in payload || 'token' in payload
        if (await sendConnection(payload)) {
          if (!touched) return
          // 改了连接参数 ⇒ 电脑侧会重建通道。等真值落地再收工（最多 ~6s）：
          // 否则面板刚点完保存就显示上一秒的"已连接"。
          setBusy('connection')
          try {
            let latest = null
            for (let attempt = 0; attempt < 12; attempt += 1) {
              const response = await fetch(CONNECTION)
              if (!response.ok) break
              latest = await jsonOf(response)
              setConnection(latest)
              // 连上了，或者干脆没在跑（缺令牌/坏地址）—— 两种都是"到头了"。
              if (latest.relay && (latest.relay.connected || !latest.relay.running)) break
              if (attempt < 11) await new Promise((resolve) => setTimeout(resolve, 500))
            }
            if (latest !== null) setDraft(draftOf(latest))
          } finally {
            setBusy('')
          }
        }
      }

      /** 清除令牌：破坏性，走页面内确认框（后果句在 locale 里）。 */
      const askClearToken = () => {
        if (connection === null) return
        askConfirm({
          title: t('tokenClearTitle'),
          description: t('tokenClearDescription'),
          confirmLabel: t('tokenClear'),
          run: async () => {
            await sendConnection({ revision: connection.revision, token: { op: 'clear' } })
            await refresh()
          },
        })
      }

      const setDraftField = (patch) => setDraft((current) => ({ ...(current || {}), ...patch }))

      // ---- 派生值：全部只由 `status` 算出来，放在动作前面，免得闭包向前引用 ----
      const devices = status && status.devices ? status.devices : []
      const live = devices.filter((d) => !d.revoked)
      const revoked = devices.filter((d) => d.revoked)
      const deviceById = new Map(devices.map((d) => [d.id, d]))
      const onlineCount = live.filter((d) => d.online).length
      const pairedCount = live.length

      /** 删除**已停用**的一台（清理）。 */
      const removeOne = (device) => askConfirm({
        title: t('confirmRemoveTitle', { name: device.name }),
        description: t('confirmRemoveDescription'),
        confirmLabel: t('remove'),
        run: async () => { await postRemove({ devIds: [device.id] }, device.id) },
      })

      /**
       * 删除**还在用**的一台 —— **先停用、再删除**，一次点击两步。
       *
       * 为什么不直接删：手机唯一能"知道自己被移除"的通道是换票时的 401 带原因，
       * 而那只在**行还在名册里**时成立（`device-admin.ts` 不变量 2）。先停用一步
       * 让它立刻下线并拿到终态，再抹记录，两条都成立。
       *
       * 为什么界面上要给出这一步：用户原话「连接的都不能删除？那我想删除咋办？」
       * —— 他要的是"我的设备我能删"，而不是"先停用再找地方删"。
       */
      const removeActive = (device) => askConfirm({
        title: t('confirmRemoveActiveTitle', { name: device.name }),
        description: t('confirmRemoveActiveDescription'),
        confirmLabel: t('remove'),
        run: async () => {
          setBusy(device.id)
          try {
            await callEnabled(device.id, false)
            const response = await fetch(REMOVE, {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({ devIds: [device.id] }),
            })
            const body = await jsonOf(response)
            if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`)
            await refresh()
            setSelected(new Set())
          } catch (caught) {
            setError(t('failedRemove', { reason: messageOf(caught) }))
          } finally {
            setBusy('')
          }
        },
      })

      /**
       * 停用勾选的几台。**多选的动作是停用，不是删除**。
       *
       * 删除只允许作用在已停用的行上：手机唯一能"知道被移除"的通道是换票 401 带原因，
       * 而硬删会把撤销记录一起抹掉（那台手机只会一直重试）。批量停用因此顺序调用
       * 同一个单台端点 —— 不新开批量接口（服务端每台仍是一次写入 + 一次名册重发）。
       */
      const disableSelected = (ids) => {
        const active = ids
          .map((id) => deviceById.get(id))
          .filter((device) => device !== undefined && !device.revoked)
        if (active.length === 0) {
          setError(t('selectedAllDisabled'))
          return
        }
        askConfirm({
          title: t('confirmDisableSelectedTitle', { n: active.length }),
          description: t('confirmDisableDescription'),
          confirmLabel: t('disable'),
          run: async () => {
            setBusy('selected')
            try {
              for (const device of active) await callEnabled(device.id, false)
              await refresh()
              setSelected(new Set())
            } catch (caught) {
              setError(t('failedDisable', { reason: messageOf(caught) }))
            } finally {
              setBusy('')
            }
          },
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

      // 总览条用的三个事实：中转状态、直连端口、在线数。读不到就说读不到。
      const relayView = connection === null ? null : connection.relay
      const relayHeroColor = relayView === null
        ? 'var(--dsw-alias-state-idle-primary)'
        : relayView.connected
          ? 'var(--dsw-alias-state-success-primary)'
          : relayView.running
            ? 'var(--dsw-alias-state-warn-label)'
            : 'var(--dsw-alias-state-idle-primary)'
      const relayHeroText = relayView === null
        ? '—'
        : relayView.connected
          ? t('relayConnected')
          : relayView.running ? t('relayConnecting') : t('relayStopped')
      const directPort = connection === null || connection.value === undefined
        ? '—'
        : connection.value.listenPort

      return h(
        'div',
        { style: S.wrap },

        // 失败与提示**放在面板顶部**，不放在某一张卡里：停用/删除失败了，
        // 消息却出现在最下面那张配对卡上，用户根本不会往那儿看。
        error !== ''
          ? h('div', {
              key: 'e', role: 'alert',
              style: S.notice('var(--dsw-alias-state-error-primary)'),
            }, error)
          : null,

        // **总览条**：中转有没有连、几台在线、直连开在哪个端口 —— 一行读完。
        // 以前这些散在两张卡里，要逐块读才知道这台电脑现在健不健康。
        h('div', { key: 'hero', style: S.hero },
          h('span', { style: S.dot(relayHeroColor) }),
          h('span', { style: S.value }, relayHeroText),
          h('span', { style: S.sep }),
          h('span', { style: S.value }, `${onlineCount} / ${pairedCount} 台在线`),
          onlineCount > 0
            ? h('span', { style: S.label }, `· ${onlineCount === 1 ? '正在服务 1 台' : '有设备在线'}`)
            : null,
          h('span', { style: S.sep }),
          h('span', { style: S.value }, `${t('listenLabel')} ${directPort}`),
        ),

        // ⓪ 「连接」—— 这台电脑怎么连中转（地址 / 公网明文 / 令牌 / 直连端口）。
        // 放在最上：出问题时第一件事是"地址对不对、令牌在不在"。
        h(ConnectionCard, {
          key: 'conn-card',
          t,
          view: connection,
          draft: draft || draftOf(connection),
          busy,
          error: connectionError,
          relayChannel: channels.find((row) => row.id === 'relay') || null,
          onDraft: setDraftField,
          onSave: saveConnection,
          onClearToken: askClearToken,
          focused: focusedField,
          onFocusField: setFocusedField,
          onBlurField: () => setFocusedField(''),
        }),

        // ① **通道与地址**：传输方式 + 上报地址合成一张卡。
        // 「拨向哪条路」**不在这里重复**：上面的「连接」卡就是这条事实的唯一位置
        // （两处显示同一件事，迟早一先一后地漂）。
        // 传输方式每个通道一个开关（2026-10-17 用户：「不是有两中方式为啥就一个开关？
        // 后面我要是再加新的方式也就一个开关吗？」），列表来自 `GET /transport`。
        // 批量入口在卡头：同时开 / 同时关是常态，单条是例外。
        // 取舍：.agents/notes/implemented/2026-10-17-transport-channels-registry.md
        h(
          'div',
          { key: 'status', style: S.card },
          h('div', { style: S.cardHead },
            h('span', { style: { fontSize: 13, fontWeight: 600 } }, t('channelsTitle')),
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
          h(
            'div',
            { key: 'transport' },
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

            // **上报给手机哪些地址**：监听面按设计枚举全部非内部网卡
            // （`transport/listener.ts:134-138` 明确不按网卡名过滤），
            // 装了 VMware 的机器会因此多报几条手机永远拨不通的地址。
            // 由用户点名藏掉比猜网卡名可靠；反向也能追加一条不在枚举里的
            // （如 Tailscale 的 100.x）。服务端校验见 `admin/advertise.ts`。
            h(
              'div',
              { key: 'advertise', style: { marginTop: 10, paddingTop: 10, borderTop: '1px solid var(--dsw-alias-border-inverted)' } },
              h('div', { style: S.row },
                h('span', { style: S.subhead }, t('advertiseTitle')),
                h('span', { style: { flex: 1 } }),
                // 被删除（= 不上报）的自报地址默认收起 —— 网卡还在，但它们不该占着列表。
                advertise !== null && advertise.hidden.length > 0
                  ? h('button', {
                      type: 'button',
                      style: S.btn,
                      onClick: () => setShowHiddenAddresses(!showHiddenAddresses),
                    }, showHiddenAddresses
                      ? t('advertiseHideHidden')
                      : t('advertiseShowHidden', { n: advertise.hidden.length }))
                  : null,
              ),
              // 会报给手机的地址：**删除 = 不再上报**（自报的那种，网卡还在，
              // 所以删掉的进下面那排「已删除」，可恢复）。
              advertise === null
                ? null
                : advertise.candidates.map((candidate) => {
                    const hidden = advertise.hidden.includes(candidate.url)
                    // 被删掉的只在展开时才画。
                    if (hidden && !showHiddenAddresses) return null
                    return h('div', { key: `c:${candidate.url}`, style: { ...S.row, marginTop: 6 } },
                      h('span', { style: S.dot(hidden ? 'var(--dsw-alias-state-idle-primary)' : 'var(--dsw-alias-state-success-primary)') }),
                      h('span', { style: S.value }, candidate.label || candidate.url),
                      h('span', { style: { ...S.label, flex: 1 } }, candidate.url),
                      hidden
                        ? h('button', {
                            type: 'button',
                            style: busy === `advertise:${candidate.url}` ? { ...S.btn, ...S.btnDisabled } : S.btn,
                            disabled: busy !== '',
                            onClick: () => runAdvertise(candidate.url, 'clear'),
                          }, t('advertiseShow'))
                        : h('button', {
                            type: 'button',
                            style: busy === `advertise:${candidate.url}` ? { ...S.btnDanger, ...S.btnDisabled } : S.btnDanger,
                            disabled: busy !== '',
                            onClick: () => runAdvertise(candidate.url, 'hide'),
                          }, t('advertiseHide')),
                    )
                  }),
              // 手动追加的地址（不在网卡枚举里）：删掉 = 真从表态里清掉。
              advertise === null
                ? null
                : advertise.advertised
                    .filter((entry) => entry.source === 'extra')
                    .map((entry) => h('div', { key: `x:${entry.url}`, style: { ...S.row, marginTop: 6 } },
                      h('span', { style: S.dot('var(--dsw-alias-state-success-primary)') }),
                      h('span', { style: S.value }, t('advertiseExtra')),
                      h('span', { style: { ...S.label, flex: 1 } }, entry.url),
                      h('button', {
                        type: 'button',
                        style: busy === `advertise:${entry.url}` ? { ...S.btnDanger, ...S.btnDisabled } : S.btnDanger,
                        disabled: busy !== '',
                        onClick: () => runAdvertise(entry.url, 'clear'),
                      }, t('remove')),
                    )),
              h('div', { style: { ...S.row, marginTop: 8 } },
                h('input', {
                  type: 'text',
                  value: advertiseInput,
                  placeholder: t('advertiseAddPlaceholder'),
                  onChange: (event) => setAdvertiseInput(event.target.value),
                  style: S.input,
                }),
                h('button', {
                  type: 'button',
                  style: busy === `advertise:${advertiseInput}` ? { ...S.btn, ...S.btnDisabled } : S.btn,
                  disabled: busy !== '' || advertiseInput.trim() === '',
                  onClick: () => runAdvertise(advertiseInput.trim(), 'extra'),
                }, t('advertiseAdd')),
              ),
            ),
          ),
        ),

        // ② 设备 —— 在线的排最前（服务端已排序）；活跃行可停用(软)/接管，已停用的行可启用(解禁)/删除(清理)
        h(
          'div',
          { key: 'devices', style: S.card },
          // 卡头：标题 + 台数 + **清空全部记录**。批量清理属于"这张卡的事"，
          // 放在标题那一行比压在表格下面更容易找到。
          h('div', { key: 'h', style: S.cardHead },
            h('span', { style: { fontSize: 13, fontWeight: 600 } }, t('devicesTitle')),
            h('span', { style: S.pill('var(--dsw-alias-label-tertiary)') }, String(pairedCount)),
            h('span', { style: { flex: 1 } }),
            devices.length > 0
              ? h('button', {
                  type: 'button',
                  style: busy === 'all' ? { ...S.btnDanger, ...S.btnDisabled } : S.btnDanger,
                  disabled: busy !== '',
                  onClick: clearAll,
                }, t('clearAll', { n: devices.length }))
              : null,
          ),
          // 多选浮现栏：**只在有勾选时出现**，不改变行本身的交互（见文件头）。
          selectedIds.length === 0
            ? null
            : h('div', { key: 'sel', style: S.bar },
                h('span', { style: { ...S.label, flex: 'none' } }, t('selectedCount', { n: selectedIds.length })),
                // 多选的动作是**停用**，不是删除：删除只允许作用在已停用的行上
                // （见 `device-admin.ts` 不变量 2）。停用会立刻收连接、手机拿到终态；
                // 想清理记录就到下面的「已停用」里删。
                h('button', {
                  type: 'button',
                  style: busy === 'selected' ? { ...S.btnDanger, ...S.btnDisabled } : S.btnDanger,
                  disabled: busy !== '',
                  onClick: () => disableSelected(selectedIds),
                }, t('disableSelected')),
                h('button', {
                  type: 'button', style: S.btn, disabled: busy !== '',
                  onClick: () => setSelected(new Set()),
                }, t('cancel')),
              ),
          visible.length === 0
            ? h('div', { key: 'z', style: S.notice('var(--dsw-alias-label-tertiary)') }, status === null ? '…' : t('noDevices'))
            : h(
                'table',
                { key: 'tb', style: S.table },
                h('thead', null, h('tr', null,
                  h('th', { style: { ...S.th, width: 28 } }, ''),
                  h('th', { style: S.th }, '名称'),
                  // **配对于**：每次扫码都是一条新记录，用户要能认出"哪条是我现在
                  // 这部手机"（2026-10-17 真机：同一个手机扫了 5 次，5 条同名行，
                  //  用户问"我只有一个手机怎么显示五个"）。
                  // **窄窗收起这两列**，把时间并进名称那一格（同一份数据，不复制）。
                  narrow ? null : h('th', { style: S.th }, t('pairedAt')),
                  narrow ? null : h('th', { style: S.th }, '最后活跃'),
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
                  // **本次会话那一台标出来**：9 行全叫「我的手机」时，用户没法一眼认出
                  // "哪台是现在我手里这部"（2026-10-17 真机问过"我只有一个手机怎么显示五个"）。
                  h('td', { style: S.td },
                    device.name,
                    device.serving
                      ? h('span', { style: { ...S.label, color: 'var(--dsw-alias-state-success-primary)', marginLeft: 6 } }, t('thisOne'))
                      : null,
                    narrow
                      ? h('div', { style: { ...S.dim, fontSize: 11, marginTop: 2 } },
                          `${fmtWhen(device.pairedAt, t)} · ${device.revoked ? '—' : fmtAgo(device.lastInteractedAt, t)}`)
                      : null,
                  ),
                  narrow ? null : h('td', { style: { ...S.td, ...S.dim } }, fmtWhen(device.pairedAt, t)),
                  narrow ? null : h('td', { style: { ...S.td, ...S.dim } }, device.revoked ? '—' : fmtAgo(device.lastInteractedAt, t)),
                  h('td', { style: S.td },
                    device.revoked
                      ? h('span', { style: S.dim }, t('disabled'))
                      : h('span', { style: device.online ? S.ok : S.dim },
                          // **"在服务"跟着在线态报**：独占 1:1 下多出来的那一档，
                          // 否则操作者只看到"有台设备在线"，分不出是谁占着（新手机连不上的原因）。
                          `${device.online ? t('running') : t('idle')}`
                          + `${device.online ? ` · ${device.foreground ? t('foreground') : t('background')}` : ''}`
                          + `${device.serving ? ` · ${t('serving')}` : ''}`),
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
                            style: busy === device.id ? { ...S.btnDanger, ...S.btnDisabled } : S.btnDanger,
                            disabled: busy !== '',
                            onClick: () => removeOne(device),
                          }, t('remove')),
                        )
                      : h('span', { style: S.row },
                          // 只有**正在服务**的那一行才有"接管"：别的行没有可接管的占用位。
                          device.serving
                            ? h('button', {
                                type: 'button',
                                style: busy === device.id ? { ...S.btn, ...S.btnDisabled } : S.btn,
                                disabled: busy !== '',
                                onClick: () => takeOver(device),
                              }, t('takeOver'))
                            : null,
                          h('button', {
                            type: 'button',
                            style: busy === device.id ? { ...S.btn, ...S.btnDisabled } : S.btn,
                            disabled: busy !== '',
                            onClick: () => disableOne(device),
                          }, t('disable')),
                          // **还在用的那台也能删**（用户原话："连接的都不能删除？"）。
                          // 点下去是"先停用、再删除"两步（见 `removeActive`）——
                          // 顺序保证了那台手机先拿到终态，再丢掉记录。
                          h('button', {
                            type: 'button',
                            style: busy === device.id ? { ...S.btnDanger, ...S.btnDisabled } : S.btnDanger,
                            disabled: busy !== '',
                            onClick: () => removeActive(device),
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
          // 按状态清：**只剩 `revoked` 一种**（`all` 已移到卡头）。
          // "按当前离线批量硬删"早已删掉 —— 它的人口专门命中"暂时离线但还在用"的设备，
          // 2026-10-15 事故删掉的正是用户自己那台。
          revoked.length > 0
            ? h('div', { key: 'clean', style: { ...S.row, marginTop: 8 } },
                h('button', {
                  type: 'button',
                  style: busy === 'revoked' ? { ...S.btnDanger, ...S.btnDisabled } : S.btnDanger,
                  disabled: busy !== '',
                  onClick: cleanRevoked,
                }, t('cleanRevoked', { n: revoked.length })),
              )
            : null,
        ),

        // ③ 版本与更新 —— 只读查询，用户点一下才查（电脑代查 npm，见 admin/update.ts）
        h(
          'div',
          { key: 'version', style: S.card },
          h('div', { key: 'h', style: S.cardHead },
            h('span', { style: { fontSize: 13, fontWeight: 600 } }, t('versionTitle')),
            h('span', { style: S.pill('var(--dsw-alias-label-tertiary)') },
              updateInfo === null ? '—' : updateInfo.current),
            h('span', { style: { flex: 1 } }),
            h('button', {
              key: 'check', type: 'button',
              style: updateBusy ? { ...S.btn, ...S.btnDisabled } : S.btn,
              disabled: updateBusy,
              onClick: checkUpdate,
            }, updateBusy ? t('versionChecking') : t('versionCheck')),
          ),
          h('p', { key: 'd', style: { ...S.label, margin: 0 } }, versionLine(t, updateInfo)),
          updateInfo !== null && updateInfo.hasUpdate && typeof updateInfo.url === 'string'
            ? h('button', {
                key: 'open', type: 'button',
                style: { ...S.btn, marginTop: 8, alignSelf: 'flex-start' },
                onClick: () => window.open(updateInfo.url, '_blank', 'noopener'),
              }, t('versionOpen'))
            : null,
        ),

        // ④ 配对新手机 —— 最低频，所以放最下面
        h(
          'div',
          { key: 'pair', style: S.card },
          // 卡头就是操作行：出码是这张卡唯一的主按钮，放标题右边。
          h('div', { key: 'h', style: S.cardHead },
            h('span', { style: { fontSize: 13, fontWeight: 600 } }, t('pairTitle')),
            h('span', { style: { flex: 1 } }),
            h('button', {
              key: 'b', type: 'button',
              style: busy === 'pair' ? { ...S.btn, ...S.btnDisabled } : S.btn,
              disabled: busy !== '',
              onClick: pair,
            }, busy === 'pair' ? t('pairing') : t('pair')),
          ),
          h('p', { key: 'd', style: { ...S.label, margin: 0 } }, t('pairHint')),
          qr === null
            ? null
            : countdown === null
              ? h('p', { key: 'x', style: { ...S.label, ...S.warn, marginTop: 10 } }, t('expired'))
              : h('div', { key: 'q', style: { marginTop: 10 } },
                  h('img', { alt: '配对二维码', src: qr.src, width: 260, height: 260, style: { display: 'block', background: '#fff', borderRadius: 6 } }),
                  qr.lanOnly === true
                    ? h('p', { key: 'lo', style: { ...S.label, ...S.warn, margin: '8px 0 0' } }, t('pairLanOnly'))
                    : h('p', { key: 'lr', style: { ...S.label, margin: '8px 0 0' } },
                        qr.lanAvailable === true ? t('pairRelayReady') : t('pairRelayOnly')),
                  h('p', { key: 'c', style: { ...S.label, margin: '6px 0 0' } }, `${t('scanHint')} · ${t('expiresIn', { t: countdown })}`),
                ),
        ),

        // ④ 确认对话框 —— **页面内 DOM**，不用 `window.confirm`（2026-10-15 事故）。
        // 形状照 DSH `confirmUninstall`（`PluginManagerPage.tsx:1367-1390`）：
        // 标题问句 + 一句后果 + 取消/确认。
        pending === null
          ? null
          : ReactDOM.createPortal(
            h('div', { key: 'cf', style: S.mask, onClick: closeConfirm },
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
            document.body,
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
