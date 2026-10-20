# DSH 设置项 → 手机端 搬运清单

> 目的:核对并修正 `docs/design-and-tech-plan.md` §7.5 的设置项清单,产出逐项处置。
> 方法:**只读源码**,未修改 `D:\sudy\github\deepseek-harness` 下任何文件。
> 证据约定:路径相对 DSH 仓库根(即 `D:\sudy\github\deepseek-harness\`);中文文案**照抄** `locales.ts`,不改写。
> 找不到证据的显式写「未找到」。bridge 能力核对对象:`D:\sudy\github\Agents-Anywhere`。

---

## 0. 先修正一个结构性前提(影响整张表)

§7.5 说「分组照搬 DSH `settings.section` / `settings.general.item`」——这句是对的,但 §7.5 把**六个不同平面**混成了一个「设置页」。实测注册点如下:

| 平面 | 注册 slot | 证据 |
|---|---|---|
| 设置页导航 | `settings.section` | `packages/client/ui-settings/src/client/contract/slots.ts:57` |
| 通用页内的行 | `settings.general.item` | `packages/client/ui-settings/src/client/contract/slots.ts:92` |
| 插件页内的 tab | `settings.plugins.tab` | `packages/client/ui-settings/src/client/contract/slots.ts:66` |
| **侧边栏** Plugins 面板(不在设置里) | `main` + `plugins.item` | `packages/client/ui-plugin-manager/src/client/index.ts:65,109-127` |
| 设置页头部动作 | `settings.action` | `packages/client/ui-settings/src/client/contract/slots.ts:39` |
| 引导浮层 | `settings.onboarding` / `shell.overlay` | `packages/client/ui-settings/src/client/contract/slots.ts:77` |

**`settings.section` 只有 5 个**,按 order 排序:

| id | order | 文案 | 注册点 |
|---|---|---|---|
| `account` | -10 | 账号与余额 | `packages/client/ui-settings-account/src/client/index.ts:294` |
| `general` | 0 | 通用设置 | `packages/client/ui-settings-general/src/client/index.ts:231-238` |
| `models` | 10 | 模型 | `packages/client/ui-settings-models/src/client/index.ts:138-148` |
| `plugins` | 15 | 内置插件 | `packages/client/ui-settings-plugins/src/client/index.ts:76-83` |
| `agent-presets` | 20 | Agent 预设 | `packages/client/ui-agent-preset/src/client/index.ts:223-226` |

**`通用设置` 页里的 12 行**,按 order:权限(-20)、语言(0)、外观(10)、字号(11)、工作步骤展示(12)、显示代码工作视图(15)、快捷键(16)、网页链接(17)、繁忙时发送(20)、性能与用量(30)、Session Log(90)、当前版本(100)。
证据:`ui-permission-presets/.../index.ts:162`、`locale/.../index.ts:618`、`ui-theme/.../index.ts:458,474`、`ui-chat/.../apply.ts:136,159,170`、`ui-settings-general/.../index.ts:77,85`、`ui-shortcuts/.../index.ts:43`、`ui-conversation/.../apply.ts:172`、`ui-settings-session-log/.../index.ts:37`。

**终端 / Agent 循环 / 子智能体 / 网页搜索 不在这里。** 它们注册在侧边栏 Plugins 面板的 `plugins.item` 上(order 10/20/30/40):`ui-settings-shell/.../index.ts:50-51`、`ui-settings-agent-loop/.../index.ts:47-48`、`ui-settings-subagent/.../index.ts:85-89`、`ui-settings-web-search/.../index.ts:57-58`。§7.5 说「按对应 section 搬」是**错的**。

---

## 1. A 组:通用设置(`settings.section` id=`general`)

| 分组 | 设置项(中文文案 + 源码 key) | 证据(路径:行号) | 控件形态 | 取值来源 | 手机端处置 | 理由 |
|---|---|---|---|---|---|---|
| 通用 | **外观**(`appearance.title`;值 `浅色`/`深色`/`跟随系统`) | 文案 `packages/client/ui-theme/src/client/locales.ts:5-8`;控件 `ui-theme/src/client/AppearanceRow.tsx:42-62`;存储 `ui-theme/src/theme-settings.ts:9,41-44` | 三选一分段 | DSH 存 **Host**(ns `ui-theme`,字段 `preference`);手机应改为**本地 UI 偏好** | **搬** | 纯渲染偏好,三选一分段在窄屏天然合适。注意:DSH 存在 Host 是为了跨浏览器跟随;手机端画面只有手机自己看,存本地更对(改了不影响电脑) |
| 通用 | **字号大小**(`fontSize.title`,说明 `fontSize.description` = "仅影响会话内容的字号") | 文案 `ui-theme/src/client/locales.ts:9-13`;控件 `ui-theme/src/client/FontSizeRow.tsx:35-70`;范围 `ui-theme/src/theme-settings.ts:24-30`(10–22px,默认 14) | 数字步进器(±1) | DSH 存 **Host**(ns `ui-theme`,字段 `fontSize`) | **搬** | 步进器完美适配小屏。但**必须改语义**:DSH 是"会话内容 px",手机正文还要跟系统动态字号,建议做成"正文缩放系数"而非固定 px |
| 通用 | **语言**(`language.title`) | 文案 `packages/client/locale/src/locales/settings.ts:5`;控件 `locale/src/client/LanguageRow.tsx:30-66`;取值 `locale/src/locale-settings.ts:15`(仅 `zh`/`en`) | 下拉菜单 | DSH 存 **Host**(ns `locale`,字段 `preference`);手机应改为**本地 UI 偏好** | **搬** | 下拉二选一。手机端语言是 App 自身偏好,且我们可能要多于 zh/en |
| 通用 | **工作步骤展示**(`settings.transcript.title`,说明"选择希望看到多少工具调用细节";值 `简洁`/`标准`/`详细`/`完全展开`) | 文案 `packages/client/ui-chat/src/client/locale.ts:103-108`;控件 `ui-chat/src/client/settings/TranscriptViewRow.tsx:37-48`;存储 ns `ui-chat` 字段 `transcriptView` `ui-chat/src/chat-settings.ts:6,60-65` | 四选一(菜单/分段) | DSH 存 **Host**(ns `ui-chat`) | **搬** | 纯展示密度,与轨迹/工具行渲染直接对应,手机端同样需要 |
| 通用 | **性能与用量**(`settings.performance.title`,说明"选择性能与用量信息展示的详细程度";值 `简洁`/`详细`) | 文案 `ui-chat/src/client/locale.ts:95-98`;控件 `ui-chat/src/client/settings/PerformanceUsageRow.tsx:31-45`;存储 ns `ui-chat` 字段 `performanceUsage` `ui-chat/src/chat-settings.ts:61-62` | 二选一 | DSH 存 **Host**(ns `ui-chat`) | **搬** | 对应 §7.4 的三个统计 sheet 的信息量,手机端同样可选 |
| 通用 | **权限**(`title`=`权限`,说明 `description`="选择新会话的默认权限模式";值 `仅可查看`/`工作区内修改`/`完全权限`) | 文案 `packages/client/ui-permission-presets/src/client/locales.ts:8-19`;控件 `ui-permission-presets/src/client/PermissionRow.tsx:41-128`;写 `permission.defaultPreset` `ui-permission-presets/src/client/settings-store.ts:19,124-128`;机器值 `presentation.ts:4,15-19` | 下拉 + **风险确认门**(勾选+启用) | **需要下发到电脑**(Host ns `permission`) | **必须分叉** | 连电脑模式:这是电脑侧真实沙箱档位,搬(须连 §7.10 的风险门一起搬,`RiskConfirmation` 在 `PermissionRow.tsx:105-125`)。本机运行模式:手机没有 workspace/命令执行(`standalone-mode-notes.md:852` 明确不做 proot shell),"工作区内修改"无从谈起 → 本机模式**隐藏**。另注意:`auto`(Auto review)只在**当前会话**门里出现(`locales.ts:53-59`),不在默认可选里(`presentation.ts:15-19`) |
| 通用 | **繁忙时的发送行为**(`settings.enter.title`,说明"智能体运行时 Enter 键和发送按钮的行为;Cmd/Ctrl+Enter 使用另一行为";值 `排队发送`/`插话发送`) | 文案 `packages/client/ui-conversation/src/client/locales.ts:73-76`;控件 `ui-conversation/src/client/settings/EnterBehaviorRow.tsx:39-60`;存储 ns `ui-conversation` 字段 `busyEnter` `ui-conversation/src/submission-settings.ts:6,27-29` | 二选一 | DSH 存 **Host**(ns `ui-conversation`);此偏好**决定调哪个 bridge 方法** | **已搬**(2026-10-13) | 这是少数"UI 偏好同时穿过协议"的项:`排队发送` → `session.startTurn`,`插话发送` → `session.steer`(两者 bridge **都已实现**:`dsh-bridge/src/bridge-service.ts:368,378`)。手机端**不扩方法面**:`session.prompt` 一个方法带 `mode` 参数(`connector/src/handlers.ts` 收 `'queue'|'steer'`)。**位置与 DSH 一致**:在设置页「通用」组,输入栏不摆图标(装完就不动的东西不值得占一颗 34px)。运行中的模式仍看得见 —— 发送键此时是**停止**;有草稿时它的 tooltip 说「排队发送 / 插话发送」。插话项在非运行态禁用。偏好落手机本地 `meta` 表(`AppModel.kSendModeKey`;**不同步到电脑** —— `settings.*` 方法面本期未接)。取舍见 `.agents/notes/implemented/2026-10-13-send-mode-queue-or-steer.md` |
| 通用 | **网页链接默认打开方式**(`settings.links.title`,说明"对话中网页链接的打开位置";值 `应用内侧边栏`/`默认浏览器`) | 文案 `packages/client/ui-chat/src/client/locale.ts:99-102`;控件 `ui-chat/src/client/settings/LinkOpeningRow.tsx:30-46`;存储 ns `ui-chat` 字段 `linkOpening` `ui-chat/src/chat-settings.ts:61` | 二选一 | DSH 存 **Host**(ns `ui-chat`) | **搬** | 设置项本身要搬,但**选项值必须改写**:`应用内侧边栏` 是 DSH 桌面内置浏览器插件(`ui-sidebar-browser`)的概念,手机没有侧边栏 → 换成"应用内浏览器 / 系统浏览器"。另 `LinkOpeningRow.tsx:33` 在浏览器能力不存在时整行隐藏,手机端保留等价逻辑 |
| 通用 | **显示代码工作视图**(`developerTools.title`,说明"开启后,显示轨迹、本轮代码差异,可选择完整的 Agent 预设切换") | 文案 `packages/client/ui-settings-general/src/client/locales.ts:31-33`;控件 `ui-settings-general/src/client/DeveloperToolsRow.tsx:24-36`;存储 ns `ui-settings` 字段 `enabled`,**默认 true** `ui-settings/src/developer-tools-settings.ts:5,14-16` | 开关 | DSH 存 **Host**(ns `ui-settings`) | **搬** | 开关形态最适合小屏。但**有坑**:关掉会隐藏轨迹与本轮 diff,而轨迹是 §7.3 的核心屏 → 手机端要么保持默认开、要么把"轨迹"从该开关的控制范围里摘出来(DSH 里轨迹确实受它控制) |
| 通用 | **快捷键**(`title`=`快捷键`,说明"查看和编辑当前可用的快捷键和输入操作") | 文案 `packages/client/ui-shortcuts/src/client/locales.ts:2-35`;控件 `ui-shortcuts/src/client/Reference.tsx:52`;存储 `packages/client/shortcuts/src/client/storage.ts:6,18-19`(**localStorage** `dsh.keybindings.v1` / 桌面 `userData/keybindings.json`) | 录键器 + 列表 + 冲突提示 | **本地**(浏览器 localStorage / 桌面文件) | **不做** | **有意偏离 §7.5 的分组**(§7.5 把它归"纯 UI 偏好→搬")。理由:①手机没有物理键盘,整套 `应用操作`/`菜单与弹层`/`审批区域` 分组(`locales.ts:32`)映射的是桌面 UI 供体;②录键保护是桌面原生能力(`native-failed` = "无法启用桌面录键保护",`locales.ts:28`);③键位表里 `Mod+/`、`Mod+Shift+,` 这类(`locales.ts:5`)在触屏无对应。**手机端的对应物是手势自定义**,那是另一个功能,不在设置项搬运范围 |
| 通用 | **在使用官方模型 API 时上传 Session Log**(`title`;说明 `description`="帮助改进 DeepSeek 模型与产品") | 文案 `packages/client/ui-settings-session-log/src/client/locales.ts:11-12`;控件 `ui-settings-session-log/src/client/UploadRow.tsx:26-38`;ns `session-log-deepseek` 字段 `enabled` `ui-settings-session-log/src/client/index.ts:27,29` | 开关 | **需要下发到电脑**(Host ns `session-log-deepseek`) | **必须分叉** | 连电脑模式:只有电脑侧 DSH 的会话日志才是被上传对象 → 搬开关(需下发)。本机运行模式:被上传的是**手机自己的对话**,而且官方 API 只在用 DeepSeek 官方模型时成立 → 语义完全不同,且涉及隐私必须单独文案。bridge 当前**无**对应方法(见 §4) |
| 通用 | **当前版本**(`general.currentVersion`="当前版本:{version}") | 文案 `packages/client/ui-settings-general/src/client/locales.ts:30`;注册 `ui-settings-general/src/client/index.ts:84-86`;组件 `ui-settings-general/src/client/CurrentVersionRow.tsx:10` | 纯文本行 | 电脑端 DSH 版本 | **搬** | 只读文本行,手机端应当显示**两个版本**:电脑端 DSH 版本 + 手机 App 版本(排错必需)。方案 §11 的兼容性风险靠这行兜 |
| 通用 | **打开配置文件**(`openDocument`="打开配置文件") | 文案 `ui-settings-general/src/client/locales.ts:27`;注册 `ui-settings-general/src/client/index.ts:220-228`;实现 `packages/api/settings-controller/src/index.ts:167-179`(`openTextFile`) | 设置页头部按钮 | **需要下发到电脑**(Host 动作) | **搬** | DSH 的 `openSettingsDocument` 打开的是**电脑上的原生编辑器**。手机点它 = 让电脑弹窗,这正好是"遥控器"用法(与 `plugin-and-jobs-notes.md:306` 结论一致)。**需扩 bridge**(当前无此方法)。注意 `index.ts:102-104` 只在 loopback 下注册这个按钮 |

---

## 2. B 组:模型(`settings.section` id=`models`)

整组共同前提:DSH 的 provider 配置分别写在各自 ns,凭据走**独立的 `credentials` 域**;读半侧已按 `role('secret')` 脱敏(`packages/api/settings-controller/src/index.ts:71-74,103`),`CredentialInfo` 结构**没有能装密钥值的字段**(`packages/credentials/credentials/src/types.ts:62-74`),写只有 `set`/`unset`(`settings-controller/src/credentials.ts:100-118`)。

| 分组 | 设置项(中文文案 + 源码 key) | 证据(路径:行号) | 控件形态 | 取值来源 | 手机端处置 | 理由 |
|---|---|---|---|---|---|---|
| 模型 | **提供商 添加/编辑/删除**(`add`=`添加模型提供商`,`addMode`=`添加方式`,`addCatalog`=`第三方模型提供商`,`addCustom`=`自定义模型 API`) | 文案 `packages/client/ui-settings-models/src/client/locales.ts:138-145`;控件 `ui-settings-models/src/client/ModelsSection.tsx`(节注册 `index.ts:138-148`) | 列表 + 详情表单 | **需要下发到电脑**(多个 provider ns) | **必须分叉** | 连电脑模式:列的是电脑上 DSH 的提供商,手机能增删改(需扩 bridge)。本机模式:列的是**手机自己**的 provider,存手机本地(`standalone-mode-notes.md:797-799`)。两者数据源、密钥归属、连通性测试全不同,不能共用一套状态 |
| 模型 | **API 密钥**(`keyInput`=`API 密钥`;`keyStored`="已配置——输入新值可替换";`keyEnvLocked`="由启动环境提供(只读)") | 文案 `ui-settings-models/src/client/locales.ts:158-162,187-189`;控件 `ui-settings-models/src/client/ProviderEditor.tsx:382-389`;写 `ui-settings-models/src/client/operations.ts:88-95`;格式校验 `ui-settings-models/src/client/apiKey.ts:51-57` | 密码输入框(只写) | **需要下发到电脑**(`credentials.set`) | **必须分叉** | 见 §5 专章。连电脑模式:**只发新值,永不回传**(源码已强制,不是我们要不要做的问题)。本机模式:密钥存手机平台密钥库(`standalone-mode-notes.md:765-771`) |
| 模型 | **自定义提供商字段**:`Provider ID`(`customRoute`,说明 `customRouteHint`)/`显示名称`(`customDisplayName`)/`API 协议`(`customApi`;值 `OpenAI Chat Completions`/`OpenAI Responses`/`Anthropic Messages`) | 文案 `ui-settings-models/src/client/locales.ts:209-219`;控件 `ui-settings-models/src/client/CustomProviderCard.tsx:213-262`;校验 `locales.ts:211-213` | 短输入 + 下拉 | **需要下发到电脑** | **必须分叉** | 字段本身手机可编辑(短输入+下拉各 3 项,小屏无压力)。分叉原因同 B1:同一张表单在两种模式下写往不同存储。DSH 的"其余字段在 `cordis.patch.yml`"(`locales.ts:195`)**不要搬** —— 手机上没有编辑 YAML 的合理形态 |
| 模型 | **API 地址**(`baseUrl`=`API 地址`;`baseUrlDefault`=`提供商默认`;`deepSeekEndpointHint`="请填写兼容 Anthropic Messages 协议的 API 地址。") | 文案 `ui-settings-models/src/client/locales.ts:164-167`;控件 `ProviderEditor.tsx:429-438`、`CustomProviderCard.tsx:242-250` | URL 输入 | **需要下发到电脑** | **必须分叉** | 短 URL 输入手机可编辑。本机模式下这是"手机直连 provider"的关键字段(`standalone-mode-notes.md:798`),连电脑模式下是电脑的出口配置 |
| 模型 | **模型目录**:`模型 ID`(`modelId`)/`显示名称`(`modelName`)/`上下文窗口`(`contextWindow`)/`最大输出 token 数`(`maxTokens`)/`输入类型`(`modelInputTypes`;值 `文本`/`图片`) | 文案 `ui-settings-models/src/client/locales.ts:173-183`;控件 `ui-settings-models/src/client/ModelListEditor.tsx`、`ModelRow.tsx:68-70`;容量校验 `locales.ts:193-196` | 可增删的列表 + 每项短输入 + 两个勾选 | **需要下发到电脑** | **必须分叉** | 手机编辑没问题(短输入+勾选)。分叉原因:连电脑模式的目录会影响电脑上模型选择器,本机模式是手机自己的目录。`输入类型` 要跟 bridge 的图片能力对齐(`contracts/dsh-bridge/1.0/README.md:36-37`:仅 png/jpeg/webp/gif) |
| 模型 | **获取可用模型**(`fetchModels`)与**恢复默认模型**(`resetModels`) | 文案 `ui-settings-models/src/client/locales.ts:171,198-208`;控件 `ModelListEditor.tsx:339,352`;实现 `ui-settings-models/src/client/operations.ts:102-107`(`remote.llm.discoverModels`) | 按钮 + 勾选列表 + 搜索 | **需要下发到电脑** | **必须分叉** | 连电脑模式:拉的是电脑上 DSH 的适配器列表。本机模式:手机直接请求 provider 的 `/models`(`standalone-mode-notes.md:799`)。**注意** `fetchModels` 在连电脑模式下泄漏电脑出网行为,第一版可只读 |
| 模型 | **DeepSeek 账号**(`deepSeekAccount`=`DeepSeek 账号`) | 文案 `ui-settings-models/src/client/locales.ts:126`;控件 `ui-settings-models/src/client/ModelsSection.tsx:235-236` | 卡片(特殊 provider) | **需要下发到电脑** | **必须分叉** | 连电脑模式:这是电脑上登录的 DSH 账号,手机改不了也不该改。本机模式:手机自己走 DeepSeek 账号或自己的 Key(`standalone-mode-notes.md:782-788` 表格)。**绝不能**因为本机模式要存 Key 就放松连电脑模式不存 Key |

---

## 3. C 组:Agent 预设(`settings.section` id=`agent-presets`)

| 分组 | 设置项(中文文案 + 源码 key) | 证据(路径:行号) | 控件形态 | 取值来源 | 手机端处置 | 理由 |
|---|---|---|---|---|---|---|
| Agent 预设 | **预设列表 + 设为新任务默认**(`nav`=`Agent 预设`;`setDefault`=`设为新任务默认`;`inUse`=`新任务默认`;内置四档 `标准模式`/`PTC 模式`/`极简模式`/`创造模式`) | 文案 `packages/client/ui-agent-preset/src/client/locales.ts:73-92`;控件 `ui-agent-preset/src/client/AgentPresetSection.tsx:98-149`;写 `agent-preset-registry` ns 字段 `selectedDefault` `ui-agent-preset/src/client/settings-store.ts:16,32` | 卡片列表 + 单选 | **需要下发到电脑**(Host ns `agent-preset-registry`) | **必须分叉** | 连电脑模式:搬到手机上有意义(卡片列表在窄屏可读,单选清晰),得下发到电脑。本机模式:我们的对应物是"助手(Assistant)"(`standalone-mode-notes.md:800`),字段与语义完全不同 → 不能共用一套 UI 与数据 |
| Agent 预设 | **查看配置**(`view`=`查看配置`) | 文案 `ui-agent-preset/src/client/locales.ts:81`;控件 `AgentPresetSection.tsx:146-167`(Modal + 只读文本) | 只读长文本弹层 | **需要下发到电脑**(读) | **只读** | 预设配置是整段结构化文本,手机行内编辑没有合理形态(§7.5 自己也定了这条通则)。照 DSH 做只读弹层即可,手机上加"复制" |
| Agent 预设 | **让 Agent 帮我创建预设模式**(`creatorDraft`) | 文案 `ui-agent-preset/src/client/locales.ts:101`;控件 `AgentPresetSection.tsx:84-95` | 按钮(开新会话) | **需要下发到电脑** | **不做** | 这是"开一个会话让 Agent 写插件/预设"的入口,属于创造模式工作流。第一版手机端会话创建流程还没到这个复杂度,且失败面(需要看代码 diff/文件)在手机上体验差 → 砍 |

---

## 4. D 组:插件(两个不同平面)

### D-1 设置页内的「内置插件」(id=`plugins`,order=15)

| 分组 | 设置项(中文文案 + 源码 key) | 证据(路径:行号) | 控件形态 | 取值来源 | 手机端处置 | 理由 |
|---|---|---|---|---|---|---|
| 内置插件 | **插件列表 tab**(`tab`=`插件列表`;`search`=`搜索插件`) | 文案 `packages/client/ui-settings-plugin-inventory/src/client/locales.ts:5,13`;注册 `ui-settings-plugin-inventory/src/client/index.ts:56-59`;外壳 `ui-settings-plugins/src/client/PluginsSettingsSection.tsx:33-119` | 只读列表 + 搜索 | **需要下发到电脑**(`pluginInventory.list`) | **搬** | 最划算的一屏(与 `plugin-and-jobs-notes.md:284,339` 结论一致):列表+搜索+卡片,窄屏直接可用。**当前 bridge 无此方法,需扩** |
| 内置插件 | **会话插件 / 全局插件 分组**(`presetTitle`=`会话插件`/`globalTitle`=`全局插件`) | 文案 `ui-settings-plugin-inventory/src/client/locales.ts:16,22`;分组渲染 `PluginInventorySettingsTab.tsx:490-590` | 分组列表 + 预设切换器 | **需要下发到电脑** | **搬** | 分组语义(预设提供 vs 全局共用)对判断"这个插件哪来的"很关键,手机上照样需要。预设切换器(`switcherLabel` `locales.ts:19`)在手机上改成底部 sheet 选择 |
| 内置插件 | **状态标签**(`enabledTag`/`disabledTag`/`conditionalTag`/`presetEnabledTag`/`failedTag`)与**运行状态**(`active`=`运行中`/`pending`=`等待依赖`/`loadingPhase`=`加载中`/`failed`=`启动失败`/`unloading`=`卸载中`) | 文案 `ui-settings-plugin-inventory/src/client/locales.ts:29-44` | 标签/状态点 | **需要下发到电脑** | **搬** | 纯展示,信息密度低,手机可读。照 `PhaseDot`/`StateTag` 的做法(只对过渡态显示状态点,`PluginInventorySettingsTab.tsx:221-250`) |

### D-2 侧边栏「插件」面板(`main` + `plugins.item`,**不在设置页里**)

| 分组 | 设置项(中文文案 + 源码 key) | 证据(路径:行号) | 控件形态 | 取值来源 | 手机端处置 | 理由 |
|---|---|---|---|---|---|---|
| 插件面板 | **启用/停用(bundle 级)**(`enableToggle`=`启用 {name}`) | 文案 `packages/client/ui-plugin-manager/src/client/locales.ts:47`;实现 `ui-plugin-manager/src/client/manager-store.ts:624`(`setBundleEnabled`) | 开关 | **需要下发到电脑** | **搬** | 开关是小屏最合适的形态。**必须**把 `restartNotice`("更改将在下次启动生效" `locales.ts:23`)、`overriddenNotice`(`locales.ts:24`)讲清楚,否则用户以为开关坏了。**需扩 bridge** |
| 插件面板 | **启用/停用(组件级 row 开关)**(`partToggle`=`启用组件 {name}`) | 文案 `ui-plugin-manager/src/client/locales.ts:41`;实现 `manager-store.ts:640`(`setPluginEnabled`) | 开关(嵌套在插件详情) | **需要下发到电脑** | **搬** | 这是"真正的组件级开关"(`plugin-and-jobs-notes.md:286`)。手机端放进插件详情的展开区 |
| 插件面板 | **安装插件**(`installTitle`=`添加插件`;`installSpecLabel`=`包名或地址`;`installDescription`="输入插件的包名、GitHub 仓库地址或本地目录路径。") | 文案 `ui-plugin-manager/src/client/locales.ts:56-59`;实现 `manager-store.ts:902`(`installBundle`) | 短输入 + 安装向导 + 进度流 | **需要下发到电脑** | **搬** | 与 §7.5 的结论一致(通道认证做死即可,不单独加二次审批)。但**必须**照搬 `installGuideSafety` 文案("请确认插件来源可信。插件在本机以你的权限运行…" `locales.ts:70`)与两段确认。**本地目录路径**这一形态手机上无意义(手机没有电脑的文件系统选择器)→ 手机上只保留"npm 包名 / Git 地址"两种 |
| 插件面板 | **卸载插件**(`uninstall`=`卸载`;`confirmUninstallTitle`=`卸载「{name}」？`) | 文案 `ui-plugin-manager/src/client/locales.ts:54,176-178`;实现 `manager-store.ts:632` | 按钮 + 确认弹层 | **需要下发到电脑** | **搬** | 破坏性但有明确确认文案,手机可承载。保持二次确认 |
| 插件面板 | **安装源**(`registryToggle`=`安装源`;值 `默认安装源`/`npm 官方源`/`中国大陆镜像源`/`自定义地址`) | 文案 `ui-plugin-manager/src/client/locales.ts:72-80`;实现 `manager-store.ts:680` | 下拉 + 自定义 URL 输入 | DSH 侧实现在电脑;但**选择本身存在浏览器 localStorage**(`plugin-and-jobs-notes.md:331`) | **搬** | 四选一 + 可选 URL 输入,小屏无压力。手机端这份选择应存**手机本地**(每个设备各自的网络环境不同,这比 DSH 存 localStorage 更合理) |
| 插件面板 | **安装脚本批准**(`installApprovalTitle`=`需要允许安装脚本`;`installApproveAndRetry`=`允许这些脚本并重试`) | 文案 `ui-plugin-manager/src/client/locales.ts:168-172`;实现 `manager-store.ts:920` | 展示确切包名 + 一次批准整组 | **需要下发到电脑** | **搬** | `plugin-and-jobs-notes.md:297` 明确"手机端必须保留同等强度的显式确认"。照搬 `installApprovalConsequence`("允许后,脚本会以你的权限在本机运行,授权保存在当前 profile,之后不再询问。") |
| 插件面板 | **插件配置(schema 表单)**(`configureRow`=`配置 {name}`) | 文案 `ui-plugin-manager/src/client/locales.ts:52`;通道 `settings.describe/update/mutate`(`packages/api/settings-controller/src/index.ts:98-158`) | 通用表单(仅 volatile 字段) | **需要下发到电脑** | **只读** | `plugin-and-jobs-notes.md:295-296` 已查实:只有 `.volatile()` 字段过线,且**没有出货客户端消费 `autoGenerate`**,通用表单渲染器不存在。手机端只显示 `describe()` 的 `value`,编辑入口留给电脑。**必须**显式写"只有标为可在运行中修改的字段能在这里改",否则用户以为坏了(同 `:304`) |
| 插件面板 | **终端**(`title`=`终端`,说明"限制每条命令最多能跑多久、最多输出多少内容。";字段 `命令超时（毫秒）`/`单流输出上限（字节）`) | 文案 `packages/client/ui-settings-shell/src/client/locales.ts:32-37`;ns `bash-sandbox`/`pwsh-sandbox` `ui-settings-shell/src/client/shell-card-controller.ts:10,12`;注册 `index.ts:50-51` | 两个数字输入 | **需要下发到电脑** | **必须分叉** | 连电脑模式:控制电脑上的命令执行上限 → 搬(数字输入小屏合适)。本机运行模式:我们不做 shell(`standalone-mode-notes.md:852`)→ 整页隐藏 |
| 插件面板 | **Agent 循环**(`title`=`Agent 循环`;`maxParallel`=`并行工具调用数`,说明"同一步内最多同时运行多少个可并行的调用。") | 文案 `packages/client/ui-settings-agent-loop/src/client/locales.ts:29-32`;ns `agent-loop` 字段 `maxParallelToolCalls` `agent-loop-card-controller.ts:13,45`;注册 `index.ts:47-48` | 数字输入 + 恢复默认 | **需要下发到电脑** | **必须分叉** | 连电脑模式:控制电脑上 Agent 的并发派发 → 搬。本机模式:我们自己实现的 agent 循环,默认值/上限含义不同 → 需要独立的默认值 |
| 插件面板 | **子智能体**(`subagentTitle`=`子智能体`;`subagentMaxDepth`=`最大递归深度`;`subagentMaxActive`=`子智能体并行数量上限`;`subagentModelSelectionToggle`=`允许 Agent 为子智能体选择模型`) | 文案 `packages/client/ui-settings-subagent/src/client/locales.ts:72-89`;ns `subagent` + `subagent-model-selection-settings` `ui-settings-subagent/src/client/index.ts:50`、`subagent-model-selection-card-controller.ts:9`;注册 `index.ts:85-89` | 数字输入 + 开关 + 模型多选 | **需要下发到电脑** | **必须分叉** | 连电脑模式:完整搬(数字/开关/多选都适合小屏)。本机模式:第一版不做子代理编排 → 整页隐藏。注意模型多选列表依赖电脑的模型目录 |
| 插件面板 | **网页搜索**(`title`=`网页搜索`;`apiKey`=`API Key`;`baseUrl`=`接口地址`;`maxUses`=`单次请求最多搜索次数`) | 文案 `packages/client/ui-settings-web-search/src/client/locales.ts:37-46`;ns `web-search-deepseek` `web-search-card-controller.ts:25,34-41`;凭据引用 `DEEPSEEK_API_KEY` `:28`;注册 `index.ts:57-58` | 密钥输入 + URL + 数字 | **需要下发到电脑**(密钥走 credentials) | **必须分叉** | 连电脑模式:配置电脑侧搜索提供方(密钥 `apiKeyHint`="不写入设置文件。留空表示保持当前密钥。" `locales.ts:40` —— 与我们的密钥原则同构)。本机模式:手机自己配搜索服务(`standalone-mode-notes.md:806` 标为分叉) |

---

## 5. E 组:账号(id=`account`,order=-10)

| 分组 | 设置项(中文文案 + 源码 key) | 证据(路径:行号) | 控件形态 | 取值来源 | 手机端处置 | 理由 |
|---|---|---|---|---|---|---|
| 账号 | **账号与余额**(`nav`=`账号与余额`;`signedIn`=`已登录 DeepSeek`;`balance`=`充值余额`;`bonusBalance`=`赠金余额`;`signIn`=`登录`;`signOut`=`退出登录`;`topUp`=`充值`) | 文案 `packages/client/ui-settings-account/src/client/locales.ts:53-70`;注册**仅在已登录时**`ui-settings-account/src/client/index.ts:289-296`;组件 `AccountSection.tsx:84-100` | 卡片(头像/余额/登录态) | **需要下发到电脑** | **必须分叉** | 连电脑模式:这是**电脑上** DSH 的账号与余额,手机只应只读展示;`退出登录` 会打断电脑上正在跑的任务(`signOutRunningDescription`="当前有进程正在执行中…将会打断进程" `locales.ts:57`)→ 手机端第一版**不给**退出。本机模式:账号概念变成手机自己的 provider Key(`standalone-mode-notes.md:782-788`),完全不同。**可选增强**:DSH 登录本来就给"复制登录链接"(`copyLink` `locales.ts:46`),可以把这个链接转发到手机,让手机在任意浏览器完成登录 —— 但需扩 bridge |

---

## 6. F 组:设置外壳 / 引导(非设置项,但 §7.5 未区分)

| 分组 | 设置项(中文文案 + 源码 key) | 证据(路径:行号) | 控件形态 | 取值来源 | 手机端处置 | 理由 |
|---|---|---|---|---|---|---|
| 外壳 | **桌面更新**(`desktop.update.available`=`新版本`;`desktop.update.ready`=`安装并重启`) | 文案 `packages/client/ui-settings-general/src/client/locales.ts:7-24`;载体判定 `ui-settings-general/src/client/index.ts:89-90`(`globalThis.dshDesktop`) | 徽标 + 更新流程 | 桌面原生桥 | **不做** | 只在桌面 App 存在(`dshDesktop` 载体),手机端不可能也不该更新电脑上的 DSH。§7.5 已写"当前版本",但没提这组更新 UI,应显式排除 |
| 外壳 | **预览版说明**(`welcomeTitle`=`预览版说明`) | 文案 `packages/client/ui-settings-models/src/client/locales.ts:228-231`;注册 `ui-settings-models/src/client/index.ts:149-154` | 一次性弹层 | 本地已读标记 | **不做** | 桌面首次运行的产品说明,与手机端无关 |
| 外壳 | **首次引导:添加 API Key**(`onboardingTitle`=`添加一个 API Key 开始使用`) | 文案 `ui-settings-models/src/client/locales.ts:232-237`;注册 `ui-settings-models/src/client/index.ts:155-159` | 引导步骤(settings.onboarding) | 本地状态 | **不做** | 手机端会有自己的首启动流程(模式选择 + 设备配对,见 `standalone-mode-notes.md:796`),DSH 这套不适用 |
| 长文本 | **系统提示词 / MCP JSON / Skill / 自定义 header** | **未找到** —— 在 `packages/client` 全部 `settings.section` / `settings.general.item` / `plugins.item` / `settings.plugins.tab` 注册点中 grep `prompt`/`mcp`/`skill` **零命中**;`系统提示词` 仅作为**展示**出现(`ui-chat/src/client/locale.ts:112-113`、`ui-trajectory/src/client/locales.ts:99`、`ui-conversation/src/client/locales.ts:70`);`ui-skill` 只注册工具调用视图(`ui-skill/src/client/index.ts:81-82,161`) | — | — | **不做** | **这是 §7.5 的一处概念错误**:§7.5 说"长文本(系统提示词、MCP JSON、Skill)仍建议全屏编辑器",把它们当成 DSH 的设置项。**DSH 客户端根本没有这些设置界面**(未找到)——它们活在预设定义、`cordis.patch.yml`、MCP 客户端配置与 skill 文件里。真正有"助手系统提示词"和"MCP 服务器"的是**本机运行模式**(`standalone-mode-notes.md:800,803`),那属于本机模式范围,不是"搬 DSH 设置" |

---

## 7. 四类特别标注

### 7.1 纯 UI 偏好 —— **§7.5 的一个关键事实错误**

§7.5 把「外观、语言、字号、网页链接打开方式、繁忙时发送行为」当作"纯 UI 偏好"。**在 DSH 里它们全部存在电脑上**(Host user-settings 文档),不是浏览器本地:

| 项 | 存储位置 | 证据 |
|---|---|---|
| 外观 / 字号 | Host ns `ui-theme`(`settings.yaml`) | `packages/client/ui-theme/src/theme-settings.ts:1,9,41-44` |
| 语言 | Host ns `locale` | `packages/client/locale/src/locale-settings.ts:1,6,30-32` |
| 网页链接 / 工作步骤展示 / 性能与用量 | Host ns `ui-chat` | `packages/client/ui-chat/src/chat-settings.ts:1,6,60-65` |
| 繁忙时发送行为 | Host ns `ui-conversation` | `packages/client/ui-conversation/src/submission-settings.ts:1,6,27-29` |
| 显示代码工作视图 | Host ns `ui-settings` | `packages/client/ui-settings/src/developer-tools-settings.ts:1,5,14-16` |
| **快捷键** | **纯本地**:localStorage `dsh.keybindings.v1` / 桌面 `userData/keybindings.json` | `packages/client/shortcuts/src/client/storage.ts:6,18-19`;`ui-shortcuts/src/client/locales.ts:25` |

**含义**:六项里只有快捷键是真正"纯本地"。DSH 把其余五项放 Host 是为了**跨浏览器跟随**(换浏览器/换机器配置跟着走)。手机端结论:**这五项应该存手机本地**(手机屏幕只有手机自己看,改了不该影响电脑),这是**有意偏离 DSH** 而非"照搬"。副作用:手机上改了字号,电脑上不变 —— 这符合直觉,但要在设计文档里写死,避免以后有人"修"成同步。
(唯一例外:`繁忙时的发送行为` 虽是 UI 偏好,但它的取值直接决定调 `session.startTurn` 还是 `session.steer`,`dsh-bridge/src/bridge-service.ts:368,378` 两者都有。)

### 7.2 需要下发到电脑的(附 bridge 核对)

**当前 `dsh-bridge` 1.0 已实现的方法**(`D:\sudy\github\Agents-Anywhere\dsh-bridge\src\bridge-service.ts:292-426`):
`initialize`、`runtime.getConfig`、`runtime.getCapabilities`、`catalog.listModels`、`catalog.listPermissions`、`session.list`、`session.getSnapshot`、`session.getState`、`session.getNotices`、`session.getCapabilities`、`session.createAndStart`、`session.startTurn`、`session.steer`、`session.interrupt`、`session.updateSelections`、`session.listCommands`、`session.executeCommand`、`session.respondInteraction`、`ping`。

> **别把这份清单与我们的契约方法表混起来**:上面是 **Agents-Anywhere 的 bridge**(另一个项目)的方法面,
> 命名与形状都由它自己定;我们的通道方法在 `subsystems/remote-channel.md` §5.7,且已逐条标注
> **DSH 侧的真实依据**。两者的 `session.*` 只是名字像,不是同一套东西
> (例如 bridge 的 `session.respondInteraction` 对应我们契约里没有独立方法的审批/提问投影)。

**⚠️ 契约与实现有落差,选型前必须确认用哪一份**:
- `contracts/dsh-bridge/1.0/schemas/request.schema.json:11-20` 的 `method` 枚举里**有** `catalog.listAgentPresets`,但 `dsh-bridge/src/bridge-service.ts` 的 switch 里**没有**这个 case —— 它只实现在另一个包 `dsh-bridge-next/src/host/dsh-runtime/router.ts:108`。
- 契约里也**有** `runtime.sync.subscribe`/`ack`/`unsubscribe`/`refresh`(`request.schema.json:13`),但当前 `dsh-bridge` 源码 grep `runtime.sync` **零命中** —— 该能力同样只在 `dsh-bridge-next`(`contracts/dsh-bridge/1.0/README.md:100-164` 描述的正是 next 的实现)。

**含义**:`runtime.getConfig` 返回的 `config` 是 **bridge 插件自己的配置**(`bridge-service.ts:294-305`,内容为 `maxListLimit`/`maxFrameBytes` 等,见 `:92-113`),**不是 DSH 的用户设置**。别把 `runtime.getConfig` 误当成"读设置"的入口 —— 读设置必须新扩 `settings.*`。

另外:即便设了 `readOnly`,bridge 的写路径白名单(`bridge-service.ts:914-918`)目前只放 `session.steer`/`interrupt`/`updateSelections`/`executeCommand`/`respondInteraction`,新增写方法要一并加进这个判定。


| 我们的设置项 | 需要的 bridge 能力 | 当前状态 |
|---|---|---|
| 权限(新会话默认权限模式) | 读:`catalog.listPermissions` ✅;改**默认值**(`permission.defaultPreset`):无 | **需扩 bridge**(按会话改可用 `session.updateSelections` ✅ `bridge-service.ts:390`) |
| 模型/提供商 CRUD | 读:`catalog.listModels` ✅(只有目录,不含 provider 配置);provider 增删改:无 | **需扩 bridge** |
| API 密钥 | `credentials.describe`/`set`/`unset` 在 DSH 侧存在(`settings-controller/src/credentials.ts:83,100,113`),**bridge 不暴露** | **需扩 bridge**(建议照抄这三个方法名) |
| Session Log 上传 | 无 | **需扩 bridge** |
| 插件清单 / 启停 / 安装 / 卸载 / 安装源 / 脚本批准 | 无 | **需扩 bridge** |
| 插件配置 / Agent 预设查看配置(`settings.describe`) | 无 | **需扩 bridge** |
| Agent 预设默认值 | `catalog.listAgentPresets` 仅存在于 `dsh-bridge-next` | **需扩 bridge**(或确认切到 next) |
| 终端 / Agent 循环 / 子智能体 / 网页搜索 | 无 | **需扩 bridge** |
| 打开配置文件 | 无 | **需扩 bridge** |
| 外观/语言/字号/链接/发送行为 | 不需要(手机本地) | 无需 bridge |

**bridge 扩展的落点很明确**:`dsh-bridge/src/bridge-service.ts:120-133` 的 `static inject` 目前注入的是
`agents, sessions, sessionPersistence, attachments, llm, agentDefaultModel, commands, permissionPresets, sessionTitle, approval, userQuestions, workspaceRegistry` —— **不含 `settings` 与 `credentials`**。要读写设置,就是往这个数组加 `'settings'`、`'credentials'`(`packages/settings/settings/src/index.ts:231` 注册名 `settings`;`packages/credentials/credentials/src/index.ts:172` 注册名 `credentials`),然后按 `settings-controller` 的做法暴露 `describe/update/replace/mutate` 与 `credentials.describe/set/unset`。

### 7.3 长文本类

DSH 客户端**没有**系统提示词 / MCP JSON / Skill / 自定义 header 的设置界面(见 §6 F4,未找到)。
因此手机端不存在"这些设置项要只读还是全屏编辑器"的问题 —— 它们不属于"搬 DSH 设置"的范围。
第一版真要碰长文本,只有 Agent 预设的「查看配置」(`ui-agent-preset/.../AgentPresetSection.tsx:146-167`)与插件配置的 `value` 展示(§4 D-9),两者一律**只读 + 全屏 + 可复制**。

### 7.4 「API 密钥值不回传手机」的源码核对

**结论:该原则不仅可行,而且正是 DSH 自己在用的模式 —— 由源码强制,不依赖我们的自觉。**

1. 读半侧已经脱敏,且**结构上装不下密钥值**:
   `SettingsController` 的每次远程读都带 `redactSecrets: true`(`packages/api/settings-controller/src/index.ts:71-74,103`);`CredentialInfo` 的三个字段是 `configured`/`source`/`writable`,注释明确 "never the value. The view has no slot a value could ride in"(`packages/credentials/credentials/src/types.ts:62-74`)。
2. 写半侧是**单向**的:
   `credentials.set`/`unset` 有写无读,注释 "The value crosses the wire in this direction only: no read path returns it."(`packages/api/settings-controller/src/credentials.ts:60-66,92-105`)。
3. 界面文案与之一致:
   `keyStored`="已配置——输入新值可替换"、`keyEnvLocked`="由启动环境提供(只读)"(`packages/client/ui-settings-models/src/client/locales.ts:161-162`);输入框每次打开都是空的,留空 = 保持原值(`apiKey.ts:45-51`)。
4. **对应接口**:手机端要做的就是让 bridge 暴露这三个方法 —— `credentials.describe(refs)`(读"已配置/未配置"三态)、`credentials.set(ref, value)`(只发新值)、`credentials.unset(ref)`。这与设计文档 §7.5 第 **366** 行的表述完全同构。
5. **附带收益**:`web-search-deepseek` 的 `apiKeyHint`="不写入设置文件。留空表示保持当前密钥。"(`ui-settings-web-search/src/client/locales.ts:40`)说明这套模式在 DSH 内不止模型密钥一处,可以统一处理。

---

## 8. 统计

逐项统计(按 §1–§6 的表行计数,**含** 7.1 节的纯 UI 偏好与 §6 的外壳行):

| 处置 | 数量 | 列表 |
|---|---|---|
| **搬** | **19** | **A 组(10)**:外观、字号大小、语言、工作步骤展示、性能与用量、繁忙时的发送行为、网页链接默认打开方式、显示代码工作视图、当前版本、打开配置文件。<br>**D 组(9)**:插件列表 tab、会话/全局插件分组、状态标签与运行状态、bundle 级启用/停用、组件级启用/停用、安装插件、卸载插件、安装源、安装脚本批准 |
| **只读** | **2** | Agent 预设·查看配置;C 组外 —— 插件配置(schema 表单) |
| **不做** | **6** | 快捷键;让 Agent 帮我创建预设模式;桌面更新;预览版说明;首次引导(添加 API Key);长文本类(系统提示词 / MCP JSON / Skill / 自定义 header —— **源码中不存在,故不构成设置项**) |
| **必须分叉** | **15** | **A 组(2)**:权限、Session Log 上传。<br>**B 组(7)**:提供商、API 密钥、自定义提供商字段(Provider ID/显示名称/API 协议)、API 地址、模型目录、获取可用/恢复默认模型、DeepSeek 账号。<br>**C 组(1)**:Agent 预设列表与默认值。<br>**D 组(4)**:终端、Agent 循环、子智能体、网页搜索。<br>**E 组(1)**:账号与余额 |
| **合计** | **42** | 行数校验:通用 13 + 模型 7 + Agent 预设 3 + 插件 14 + 账号 1 + 外壳 4 = 42 |

---

## 9. §7.5 的写错 / 漏掉之处(汇总)

1. **把六个平面混成一个"设置页"**。「子代理 / agent-loop / 终端 / 网页搜索」写的是"按对应 section 搬"—— 错:它们注册在侧边栏 Plugins 面板的 `plugins.item` 上(`ui-settings-shell/.../index.ts:50-51` 等),**不在设置页导航里**。
2. **§7.5:354 的"分组照搬 `settings.section`"漏了账号页**。`account` 是 order=-10 的第一项(`ui-settings-account/.../index.ts:294`),且**只在已登录时注册**(`:289-296`)。
3. **"纯 UI 偏好"的存储位置写反了**(见 §7.1):外观/语言/字号/链接/发送行为在 DSH 里都存电脑,只有快捷键是本地。原文说这些"只影响手机/浏览器,不需要电脑参与"——"不需要电脑参与"是对的,"DSH 里存在本地"是错的。
4. **"长文本(系统提示词、MCP JSON、Skill)仍建议全屏编辑器"把不存在的东西当成设置项**(见 §6 F4)。DSH 客户端**没有**这些设置界面(未找到);它们属于本机运行模式的"助手/MCP"范畴。
5. **`ui-settings-plugins` 与 `ui-plugin-manager` 被当成一件事**。前者是设置页里的"内置插件"外壳(id=`plugins`,order=15),内含唯一一个只读 tab(`ui-settings-plugin-inventory/.../index.ts:56-59`);后者的安装/启停/卸载在**侧边栏面板**(`PANEL_ID='plugins'`,`ui-plugin-manager/.../index.ts:65,109-127`)。§7.5:363 把两者写成一句"插件(ui-plugin-manager,全量可管理)…内置插件列表",会让人以为一页全包。
6. **§7.5:363 漏了「安装脚本批准」**(`installApprovalTitle`="需要允许安装脚本")这一项。它是插件安装里唯一会执行任意包脚本的权限,已有专门的显式确认界面,不能省(`plugin-and-jobs-notes.md:297`)。
7. **§7.5:356 漏了「显示代码工作视图」会连带隐藏轨迹**。关掉后轨迹与本轮 diff 一起消失(`ui-settings-general/.../locales.ts:33`),而轨迹是 §7.3 的核心屏 —— 要么保持默认开,要么在手机端解耦。
8. **§7.5:366 的权限项混淆了两层**。(a)"新会话默认权限模式"=`permission.defaultPreset`(`ui-permission-presets/src/client/settings-store.ts:19,124-128`);(b)"当前会话权限"是输入栏的 `/permission` 浮层(ns `permission.access`,`ui-permission-presets/.../locales.ts:42-60`)。两者文案与写入目标都不同。另外 `auto`(Auto review,含 `EXP` 徽标)只属于 (b),不在默认可选里(`presentation.ts:15-19`)。
9. **§7.5:366 的选项值不能照抄**:"应用内侧边栏"是桌面内置浏览器插件概念,手机没有侧边栏(见 A8)。
10. **§7.5:367 的"只读"只提到冲突检测,漏了状态机**。插件页/配置页实际有四种态:`readOnly`("本部署的设置为只读。")、`unavailable`("该插件当前未加载,暂时无法配置。")、`overridden`/`重置`("已覆盖"/"恢复默认")、以及保存失败的 `saveFailed`(`ui-settings-shell/.../locales.ts:38-45`、`ui-settings-subagent/.../locales.ts:65-71`)。手机端若只做"只读"两态会漏掉"插件没加载"这一常见情况。
11. **§7.5 没提一个决定性的既有约束**:DSH 对**非 loopback 浏览器是不给写设置的** —— `const persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory'`(`packages/client/ui-settings/src/client/index.ts:39`),memory 模式下所有写被直接拒绝(`packages/client/ui-settings/src/client/config-form.ts:175`),表单永久 `unavailable`(`config-form-types.ts:30-33`)。这说明"手机改电脑设置"在 DSH 当前设计里是被**有意关闭**的路径。我们的 bridge 是 DSH 插件(有完整 ctx),可以绕开这个 web 层限制直接调 `ctx.settings`,但必须知道:这不是"补个 RPC"那么简单,而是**扩展一个 DSH 明确设了边界的面**,要按 `settings-write-path-integrity` / `config-plane-boundaries` 的约束来做。
12. **文档互引用章节引用,不用行号** —— 行号会随文档增删漂移(本仓"密钥不回传"原则按 §7.5 引用,`design-and-tech-plan.md` 与 `standalone-mode-notes.md` 同此)。
13. **§7.5:371 说"AA 现有 dsh-bridge 主要是会话向,没暴露设置/模型/插件读写"—— 结论对,但漏了一个更省事的既有接口**。`settings-controller` 已经实现好完整的 `settings.describe/update/replace/mutate` + `credentials.describe/set/unset`(`packages/api/settings-controller/src/index.ts:98-158`、`credentials.ts:83-118`),而且**读半侧已按 `role('secret')` 脱敏**(`:71-74,103`)。bridge 要做的主要是**转发**这些既有 Remote 方法,而不是从零设计设置协议。这比 §7.5 暗示的工作量小一档。
14. **契约与实现有落差,选型必须先拍**。`contracts/dsh-bridge/1.0/schemas/request.schema.json` 里列了 `catalog.listAgentPresets` 与 `runtime.sync.*`,但 `dsh-bridge/src/bridge-service.ts` 的 switch(`:292-426`)**都没有实现** —— 它们只在 `dsh-bridge-next`(`dsh-bridge-next/src/host/dsh-runtime/router.ts:108`)。别按契约枚举估工作量,要按实际要用的那份实现估。另:`runtime.getConfig` 返回的是 **bridge 插件自己的配置**(`bridge-service.ts:294-305`),不是 DSH 用户设置,别误用。

---

## 10. 一句话结论

第一版设置页只做 **5 组**:①**通用设置**(外观/字号/语言/工作步骤展示/性能与用量/网页链接/繁忙时发送 —— 全部手机本地;权限 + Session Log 视模式决定是否下发)、②**模型**(分叉:连电脑模式读为主 + 只发新值改密钥,本机模式手机自持)、③**内置插件**(只读清单 + 搜索分组,照 `ui-settings-plugin-inventory`)、④**Agent 预设**(列表 + 设为默认,查看配置只读)、⑤**关于/连接**(当前版本、连接状态、在电脑上打开配置文件、**连接方式**)。**连接方式是手机侧面**:DSH 没有对应设置项(端点是手机本地拨号表,`AppModel.endpoints`,序即偏好),所以它不占 42 项里的任何一行,只挂在第⑤组;实现见 `.agents/notes/implemented/2026-10-16-endpoint-chooser-ui.md`。**快捷键、子智能体、Agent 循环、终端、桌面更新、首次引导不进第一版**;插件安装/启停放到"插件面板"作为第二阶段,且必须先扩 bridge。
