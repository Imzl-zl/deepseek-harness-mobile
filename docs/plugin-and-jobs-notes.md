# DSH 插件体系 与 后台任务(ui-jobs) — 移动端视角源码调查

调查对象：`C:\sudy\github\deepseek-harness`（只读，未修改任何文件）。
调查视角：**手机/移动端要控制电脑上的 DSH**。
每条事实都带 `相对路径:行号`；查不到的写「未找到」，不猜。

## 0. 包存在性核对（先做）

要求核对的三个包在 `packages/client` 下**都存在**：

| 包 | 存在 | 角色 |
|---|---|---|
| `ui-plugin-manager` | 是 | 侧边栏 Plugins 页：安装/启停/卸载 + 插件自定义配置页宿主 |
| `ui-settings-plugins` | 是 | Settings → Built-in plugins 的**外壳**（只提供 tab 栏，自身无内容） |
| `ui-settings-plugin-inventory` | 是 | 只读插件清单 tab |

`packages/client` 下与插件/配置相关的其他包（实际存在）：
`ui-slots`、`ui-renderer`、`modules`、`store`、`connection`、`locale`、`ui-settings`（`configForms` / `settingsSchema` 的提供者）、`ui-settings-general` / `-shell` / `-subagent` / `-agent-loop` / `-web-search` / `-models` / `-session-log`（每个官方插件一个手写配置页）、`ui-primitives`（`ConfigField` / `StateDot` / `TerminalBlock`）。

宿主侧相关包：`packages/boot/plugin-manager`、`packages/boot/app-boot`、`packages/boot/config-editor`、`packages/boot/hmr`、`packages/host/plugin-inventory`、`packages/settings/settings`、`packages/util/package-manifest`、`packages/extensions/*`（cordis 扩展）、`vendor/loader`（Cordis Loader 以 vendored 源码存在）。

---

# A. 插件体系

## A.1 安装与登记

### 从哪来（安装源形式）

安装 spec 共有四种形式，定义在 `packages/boot/plugin-manager/src/install-spec.ts:14-18`：

- `registry` —— npm 包名（可带 `@version`）
- `path` —— 本地目录（**必须是绝对路径**）
- `tarball` —— `.tgz` / `.tar.gz`，本地或 HTTP
- `git` —— `github:` / `gitlab:` / `bitbucket:` / `gist:` 简写、`git://`、`git@host:`、以及 hosted 仓库 URL

判定正则与主机映射见 `packages/boot/plugin-manager/src/install-spec.ts:21-32`；解析与拒绝规则（空 spec、相对路径、非法包名、非 git/tarball 的 URL）见同文件 `:68-91`。所以：**npm 包名、本地绝对路径、GitHub（及其他 git 主机）、tarball 都支持**。

### 安装后登记在什么文件/存储

登记发生在**当前 profile 目录** `<DSH_HOME>/profiles/<name>/`（默认 `~/.dsh/profiles/<name>/`，见 `packages/util/home-paths/src/index.ts:12,61-63,87-91` 与 `packages/boot/app-boot/src/profile.ts:37,169-176`）。落地文件共四个：

| 文件 | 存什么 | 证据 |
|---|---|---|
| `package.json` | `dependencies`（装了哪些包）+ `dsh.profile.bundles`（有序的 bundle 层列表） | 初始化写入 `packages/boot/app-boot/src/profile.ts:251-257`；读取 `:545-559`；写回 `:566-568`；`bundles` 读取 `:662`；选中/取消选中改写 `:715-735`；manager 侧读同一字段 `packages/boot/plugin-manager/src/index.ts:283-284` |
| `cordis.patch.yml` | 用户的 patch 层：行级 `disabled` 覆盖、`insert` 新行、`config` 覆盖 | 文件名 `packages/boot/app-boot/src/profile.ts:40`；模板 `:220-224`；层优先级 `packages/boot/app-boot/src/profile-context.ts:63-74`；行级开关写入 `packages/boot/plugin-manager/src/patch.ts:14-43` |
| `pnpm-workspace.yaml` | hoisted linker + `autoInstallPeers: false`（给树外插件共享同一份 cordis） | `packages/boot/app-boot/src/profile.ts:230-235` |
| 兼容性豁免文件（`PROFILE_COMPATIBILITY_FILENAME`） | 精确 package@version ↔ runtime 版本的豁免 | 常量由 `@deepseek-ai/dsh-app-boot` 导出并在 `packages/boot/plugin-manager/src/index.ts:18` 引入；读取 `:232-235`；变更标记集见 `:793-801` |

「已安装」与「已选中」是两个独立事实：`installed = dependencies.includes(name)`、`enabled = selected.includes(name)`，`packages/boot/plugin-manager/src/index.ts:289-292`。

安装动作本身：`packages/boot/plugin-manager/src/index.ts:461-567`（`installBundle`）——先做 GitHub 连通性检查，再按 registry 计划逐个 `pnpm add`（`:498-522`，`:506`），成功后解析新依赖名、校验 `dsh.bundle`（`:544-545`）、按需写 `dsh.profile.bundles`（`:559-563` 调 `selectBundle`）。失败/取消会回滚 `package.json` 与 `pnpm-lock.yaml`（`:79` `RESTORED_FILES`，`:549-553`）。
移除：`:600-626`（`removeBundle` → `selectBundle(false)` + `pnpm remove`）。

### 谁负责加载

- **宿主编排（组合成 Loader 行）**：`packages/boot/app-boot`。它把 `dsh.profile.bundles` 里每个 bundle 的 `dsh.bundle.patch` 文件按序叠加，再叠 profile 自己的 `cordis.patch.yml`、home patch、命令行 overlay —— 见 `packages/boot/app-boot/src/profile.ts:9-21`（模块文档）、`packages/boot/app-boot/src/profile-context.ts:63-74`、`composeEntries` `packages/boot/app-boot/src/profile.ts:731-738`。
- **真正的 Loader**：`@deepseek-ai/cordis-plugin-loader`，本仓以 vendored 源码存在：`vendor/loader/src/config/entry.ts`（`EntryOptions` 在 `:10-23`）。仓库内没有它的独立包目录。
- **变更/热应用**：`packages/boot/plugin-manager`（写 patch + `reload()`，`:762-765`）、`packages/boot/hmr`（`hmr.runExclusive`，`:756-760`）。
- **只读投影给前端**：`packages/host/plugin-inventory`。
- **浏览器侧加载**：`packages/client/modules`（见 A.6）。

受保护模块（管理自身依赖，不允许通过 patch 关掉）名单：`packages/boot/plugin-manager/src/index.ts:66-76`，判定 `:263-264`、`:744-754`。

---

## A.2 清单（manifest）

**DSH 没有独立的插件清单文件**：插件清单就是 `package.json` 本身，额外信息放在包自己的 `dsh` 字段下。字段定义在 `packages/util/package-manifest/src/types.ts`：

### 字段清单

顶层 `DshPackageManifest`（`packages/util/package-manifest/src/types.ts:8-27`）：

| 字段 | 行 | 含义 |
|---|---|---|
| `name` | `:10` | 发布的 npm 包名 |
| `version` | `:12` | 版本 |
| `description` | `:14` | 摘要（发现/展示） |
| `icon` | `:16` | 相对清单目录的 SVG/PNG/JPEG/WebP，≤256 KiB，realpath 后必须仍在目录内 |
| `private` | `:18` | 禁止发布（本地 profile 用） |
| `dependencies` | `:20` | 随包安装的依赖 |
| `peerDependencies` | `:22` | 由消费方提供的兼容版本（DSH 自己的服务定义包走 peer） |
| `engines` | `:24` | `dsh` / `node` / `npm` 版本范围，见 `DshEnginesManifest` `:56-66` |
| `dsh` | `:26` | DSH 专用声明 |

`dsh`（`DshManifest`，`:30-39`）：

| 字段 | 行 | 含义 |
|---|---|---|
| `manifestVersion` | `:32` | 清单格式版本，固定 `1` |
| `bundle` | `:34` | `DshBundleManifest`：`patch` 为一个路径或有序路径数组，`:69-72` |
| `profile` | `:36` | `DshProfileManifest`：`bundles` 有序列表，`:75-78` |
| `client` | `:38` | `DshClientManifest`：浏览器半边声明，`:81-94`（`platform`、`inject`、`immediately`、`external`） |

**没有的字段（明确「未找到」）**：

- 没有 `capabilities` / 能力声明字段 —— 未找到。
- 没有清单级的 `configSchema` / `config schema` 字段 —— 未找到（配置 schema 来自插件运行时导出的 `Config`，见 A.5）。
- 没有 `entry`/`main` 之外的「入口」声明：入口就是 `exports`（Node ESM 标准字段），不是 `dsh` 字段。
- 没有插件间 `dependencies` 之外的依赖解析声明；`dsh.client.inject` 明确是「信息性包名依赖，不是 Cordis 服务注入」（`:84-85`）。

### 展示元数据

- 标题/描述：读 `locale/<lang>.json` 里的 `meta.title` / `meta.description`，`packages/boot/app-boot/src/package-meta.ts:101-122`（`parsed.meta` → title/description，`:115-119`）；语言文件名必须是语言 id（`:104-107`）。
- 回退链：locale → `package.json` 的 `name`/`description` → 最终 title 回退到完整模块 specifier、description 回退到空串（`packages/boot/app-boot/src/package-meta.ts:124-133,155-156`）。
- 图标：从 `package.json.icon` 读出并转成 base64 data URL，`:15-19`（媒体类型表）、`:21-41`（绝对路径/URL/越界/软链/超限都被拒绝）、`:148-171`（`readPluginMeta`）。
- 供模型/作者参考的写法说明：`packages/preset/agent-preset/skills/cordis-plugin-development/references/host-plugin.md:29-45`（注意该文档 `:34` 的 JSON 片段省略了外层文件，实际读取位置是 locale 文件，以 `package-meta.ts:115` 为准）。

### Loader 行的字段

插件「行」不是 manifest 的一部分，而是 patch YAML 里的一条，字段是 `EntryOptions`（`vendor/loader/src/config/entry.ts:10-23`）：`id`（树内稳定 id）、`name`（模块 specifier）、`config`、`group`、`disabled`（可为 `!!js` 表达式，见 `:89-92`）、`inject`。

### 真实清单示例

仓库内**示例插件模板**（`cordis-plugin-development` skill 附带，可直接复制）：

```json
// packages/preset/agent-preset/skills/cordis-plugin-development/templates/decoration/package.json:1-15
{
  "name": "@local/my-decoration",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "exports": { ".": "./index.js", "./client": "./client.js" },
  "dsh": {
    "bundle": { "patch": "./cordis.patch.yml" },
    "client": { "platform": "web", "immediately": true,
      "inject": ["@deepseek-ai/dsh-client-ui-conversation"] }
  }
}
```

配套 patch：`packages/preset/agent-preset/skills/cordis-plugin-development/templates/decoration/cordis.patch.yml:1-3`（一个 `insert` 一个行）。

仓库内**真实 bundle**：`packages/bundle/web-app/package.json:41-50` —— `dsh.bundle.patch` 是**有序数组**（`./cordis.patch.yml` + 4 个 preset patch）。真实带 `config` 的行：`packages/bundle/web-app/presets/standard.patch.yml:5-30`（`id`/`name`/`config`，以及 `disabled: !!js process.platform === 'win32'`）。

---

## A.3 客户端如何「读取已安装插件」

### 通道

客户端的远端调用面是 `ctx.remote`，声明在 `packages/api/gateway/src/client/index.ts:127-129`；每个宿主服务用 `@Remote` 装饰器生成对应命名空间（`packages/boot/plugin-manager/src/index.ts:206`、`packages/host/plugin-inventory/src/index.ts:55`、`packages/api/settings-controller/src/index.ts:86`）。

### 接口 / 方法名 / 返回结构

| RPC | 定义位置 | 返回类型 | 客户端调用点 |
|---|---|---|---|
| `pluginInventory.list()` | `packages/host/plugin-inventory/src/index.ts:70-73` | `PluginInventorySnapshot`（`packages/host/plugin-inventory/src/types.ts:66-75`）：`managementAvailable?` + `entries[]` + `agentPresets?[]` | `packages/client/ui-plugin-manager/src/client/manager-store.ts:773`；`packages/client/ui-settings-plugin-inventory/src/client/index.ts:38` |
| `pluginManager.listPlugins()` | `packages/boot/plugin-manager/src/index.ts:255-272` | `PluginInfo[]`（`packages/boot/plugin-manager/src/types.ts:29-32`）= `PluginInventoryEntry` + `patchId` **或** `readOnlyReason` | `manager-store.ts:786` |
| `pluginManager.listBundles()` | `packages/boot/plugin-manager/src/index.ts:279-319` | `BundleInfo[]`（`types.ts:47-70`）：`name/version/meta/description/enabled/installed/optional/removable/readOnlyReason?/error?/rows[]/overrides[]` | `manager-store.ts:785` |
| `pluginManager.registries()` | `:324-332` | `PluginRegistries`（`types.ts:76-81`） | `manager-store.ts:680` |
| `pluginRegistryProbe.fastest()` | `packages/client/ui-plugin-manager/src/index.ts:50-57` | `string \| null` | `manager-store.ts:689` |
| `settings.describe()` | `packages/api/settings-controller/src/index.ts:97-105` | `SettingsDescribeValue`（`packages/settings/settings/src/types.ts:57-64`）：`writable` + `hasDocument` + `namespaces[]` | `packages/client/ui-settings/src/client/settings-mirror.ts`（`ctx.configForms.describe()`，`config-form.ts:285-287`） |

`PluginInventoryEntry`（`packages/host/plugin-inventory/src/types.ts:17-26`）字段：`entryId`、`moduleName`（Loader 实际 import 的 specifier）、`meta?`（title/description/icon 的本地化元数据）、`enabled`（**含被禁用的祖先组**）、`fiberPhase`。

### 状态有哪些

- **fiber 阶段**：`PluginFiberPhase = 'pending' | 'loading' | 'active' | 'failed' | 'unloading' | null`，`packages/host/plugin-inventory/src/types.ts:8-14`；Cordis `FiberState` → 该字符串/`null` 的完整映射 `packages/host/plugin-inventory/src/index.ts:31-48`（`DISPOSED` → `null`）。
- **启用态**：`enabled: boolean`，`:23-24`。
- **可管理性**：`readOnlyReason: 'management-required' | 'unaddressable'`，`packages/boot/plugin-manager/src/types.ts:9`；计算逻辑 `packages/boot/plugin-manager/src/index.ts:263-270`（受保护模块 / 管理组件自身 → `management-required`；patch 里找不到唯一且名字匹配的行 → `unaddressable`）。
- **bundle 侧的「未安装/未运行/异常」**：`installed`（是否在 profile dependencies）、`optional`（安装自带、默认关）、`removable`、`error.code`（`not-bundle` / `not-removable` / `stop-profile` / `bundle-in-use` / `incompatible-version` / `operation-error`…，`types.ts:22` 是完整 code 联合）。
- **agent preset 行**：`enabled: boolean | 'conditional'` + `condition`（`!!js` 表达式文本）+ `fiberPhase`，`packages/host/plugin-inventory/src/types.ts:29,44-48`。
- **UI 上的标签集**：`disabled` / `conditional` / `presetEnabled` / `failed`，`packages/client/ui-settings-plugin-inventory/src/client/PluginInventorySettingsTab.tsx:335-336`、`:384-385`；状态点只画 `pending|loading|unloading`，`active`/`failed` 不画点，`:221-231`；展开后的「事实表」行 = 模块名 / entryId / 来自哪个 preset / 配置态 / 运行时 phase / disable 条件，`:362-368`、`:411-431`。

### 变更推送

`plugin-manager/changed`、`plugin-manager/install-log`、`plugin-manager/install-state` 三个事件在转发白名单里：`packages/api/remotes/src/remote-events.ts:42-44`；客户端订阅 `packages/client/ui-plugin-manager/src/client/index.ts:88-90`。`settings/document-updated` 同样在白名单 `:45`。

---

## A.4 能控制什么

| 能力 | 是否支持 | 宿主 RPC（位置） | 客户端调用点 |
|---|---|---|---|
| **行级（组件级）启停** | **支持** | `pluginManager.setPluginEnabled(id: PluginEntryId, enabled)` `packages/boot/plugin-manager/src/index.ts:424-435`，写 profile patch 的 `disabled` 覆盖 `packages/boot/plugin-manager/src/patch.ts:14-43` | `manager-store.ts:640` |
| bundle 级启停 | 支持 | `setBundleEnabled(name, enabled)` `:442-448`（改 `dsh.profile.bundles`，`:715-735`） | `manager-store.ts:624` |
| 卸载 | 支持 | `removeBundle(name)` `:600-626` | `manager-store.ts:632` |
| 安装 | 支持 | `inspect(spec, options?, signal?)` `:340-417` → `installBundle(spec, options?)` `:461-567` | `manager-store.ts:871`、`:902` |
| 取消安装 | 支持（只能取消「下载中」，不能取消「应用包」阶段） | `cancelInstall(requestId)` `:584-594`，返回 `cancelled \| too-late \| not-running` | `manager-store.ts:1015` |
| 找回安装结果 | 支持 | `waitForInstall(requestId)` `:574-577` | `manager-store.ts:920` |
| 安装源（registry）切换 | 支持 | `registries()` `:324-332`；`inspect`/`installBundle` 的 `options.registry`（`types.ts:148`、`:355`） | 选择记忆在浏览器：`createSnapshotStore(..., { persist: { name: 'dsh.plugin-manager.install-registry' } })` `manager-store.ts:517-519`；README 说明「registry choice is this browser's — it lives in `localStorage`」`packages/client/ui-plugin-manager/README.md:153` |
| 允许 pnpm build script | 支持（**需要显式二次确认**） | `InstallBundleOptions.approvedBuilds` `types.ts:146`；`approveBuilds` + `readPendingBuilds` `index.ts:473-476`、`:528-535` | `manager-store.ts:903`；UI `PluginManagerPage.tsx:1143-1151` |
| 版本兼容豁免 | 支持 | `listVersionExemptions()` `:231-235`、`setVersionExemption(...)` `:244-250` | 未在前端找到调用点（未找到前端入口） |
| **配置读写** | 支持，但**不在 pluginManager** | `settings.describe` `packages/api/settings-controller/src/index.ts:97-105`、`settings.update` `:115-122`、`settings.replace` `:132-139`、`settings.mutate` `:151-158`、`settings.openSettingsDocument` `:166-185` | `ctx.configForms.get(ns)` `packages/client/ui-settings/src/client/config-form.ts:293-302`；`mutate(ops, expectedRevision)` `:134-153` |

拒绝路径：不可寻址的行会抛 `ManagementFailure(row.readOnlyReason)`，`packages/boot/plugin-manager/src/index.ts:428-429`；`ChangeResult.application` 的取值集合是 `applied | restart-required | overridden | failed | cancelled`（`types.ts:114`），即「改了就生效 / 需要重启 / 被更高层覆盖 / 失败 / 被取消」四种结果 + 一种未变。

---

## A.5 配置是否有 schema —— **A.5 结论（关键）**

**结论：有 schema，是 Schemastery（`@deepseek-ai/schemastery` 的 `z`），以 `schema.toJSON()` 信封原样过线；不是 JSON Schema，也不是 zod。但只覆盖声明了 `.volatile()` 的字段。**

### 类型定义位置

- 插件侧声明方式：`export const Config = z.object({...})`（或用 `static Config`），见作者文档 `packages/preset/agent-preset/skills/cordis-plugin-development/references/host-plugin.md:51-54`。
- 真实例子：`packages/boot/plugin-manager/src/index.ts:178-187`

  ```ts
  static Config: z<Config> = z.object({
    pnpmCommand: z.string().default('pnpm'),
    outputBytes: z.number().step(1).min(1).default(16384), ...
  })
  ```

- 过线类型：`SettingsNamespaceView.schema` —— 注释写明「Serialized schemastery schema envelope (`schema.toJSON()`); rehydrate with `new Schema(json)`」，`packages/settings/settings/src/types.ts:27-28`。
- 线上构造点：`packages/settings/settings/src/index.ts:302-340`，`schema: form.toJSON()` 在 `:326`；命名空间 key 就是**该插件行的 Loader entry id**（`entry.options.id`），`:315`。
- 客户端能 rehydrate + validate：`packages/client/ui-settings/src/client/schema.ts:50-52`（`new Schema(json)`）、`:60-67`（用 rehydrate 出来的 schema 校验草稿）、`:75-84`（按路径解析节点）。
- 秘密字段：结构式脱敏 + `secrets: {path, set}[]` 只报「是否已设置」，`packages/settings/settings/src/types.ts:10-15,37-38`；脱敏在宿主 `packages/settings/settings/src/index.ts:323-330`。

### 关键限制 1：只发 volatile 字段

`volatileForm(schema)` 只保留声明了 `.volatile()` 的子树；没有 volatile 字段的行直接**不出现**在 `describe()` 结果里：
`packages/settings/settings/src/schema.ts:33-47`（volatileForm）、`packages/settings/settings/src/index.ts:308-309`（`form === undefined` → 跳过）。
文档确认：`packages/settings/settings/README.md:12`「Edit fields that plugins declare with `.volatile()`」、`:33`「**Forms expose only volatile fields** from active, uniquely addressed profile entries. **Ordinary configuration remains editable through Cordis configuration files.**」

### 关键限制 2：通用表单渲染器**不存在**

- 宿主**是**给了开关：`autoGenerate`，默认 `true`，`packages/settings/settings/src/index.ts:312`，线上字段 `packages/settings/settings/src/types.ts:23-24`（「Generate a page if no custom page is registered for this instance」）。
- 但 README 明确写：`packages/settings/settings/README.md:39`「Each form reports `autoGenerate`, enabled by default, for clients that build pages from the schema; **no shipped client does so yet.**」
- 实测复核：在 `packages/client` 的**源码**（排除 `tests`）里 grep `autoGenerate` —— **零命中**（只有测试 fixture 里出现）。
- 决策记录（两次否决通用渲染器）：
  - `.agents/notes/archived/architecture/2026-07-30-web-config-plane.md:31`「**A generic schema-driven form renderer** — implemented first, then replaced: field truth without visual hierarchy produced an ugly, unusable card…」
  - 同文件 `:30`「Serving JSON Schema over the wire — …converting to JSON Schema loses exactly the role annotations the credential control and secret redaction key on.」
  - `.agents/notes/archived/feature/2026-08-10-web-plugin-configuration.md:37`「**A generic schema-driven form renderer.** Declined again … field truth without a presentation vocabulary produced an unusable card. Three plugins of hand-written controls cost about the same and read better…」

### 另一条「JSON Schema」路径：存在，但客户端拿不到

- 宿主能把 Schemastery 投影成 **JSON Schema 2020-12**：`packages/boot/app-boot/src/config-schema/types.ts:1-60`（`ConfigSchemaDump` 带 `$defs` + `x-cordis`），导出 `generateConfigSchema` 于 `packages/boot/app-boot/src/index.ts:30`。
- 消费者只有 CLI：`apps/cli/src/dump-config-schema.ts`（grep 全仓 `generateConfigSchema` 的唯一运行时消费者）。
- 另有**给 agent 的工具**（不是给手机的 RPC）：`cordis_inspect_query` 的 `Config.listConfigs`，实现 `packages/extensions/tool-cordis/src/config.ts:98-119`，按 entry id 返回该行的自包含 JSON Schema（`:113-119`），文档见 `packages/preset/agent-preset/skills/cordis-plugin-development/SKILL.md:30-31`。这条路径只有模型能走，浏览器/手机不经手。

### 所以手机能不能用通用表单渲染插件配置

**能，但只在很窄的条件下、且要自己写渲染器**：只有那些在 `Config` 里声明了 `.volatile()` 的行，才会通过 `remote.settings.describe()` 暴露 `schema`（Schemastery `toJSON()` 信封）+ `value` + `base` + `user` + `revision` + `secrets`，并可用 `remote.settings.update/replace/mutate` 写回（写是**路径寻址**的，`{op:'set'|'unset', path[]}`，所以不会误删没拿到的 secret 字段）。其余插件的配置**根本不在线上**，手机无从渲染；且 DSH 官方客户端明确不做这件事（每个官方插件配一个手写页面包：`ui-settings-shell` / `ui-settings-agent-loop` / `ui-settings-subagent` / `ui-settings-web-search` 等，见 `packages/client/ui-plugin-manager/README.md:60`）。

现成的渲染积木只有一个「受控输入」组件，**不带 schema**：`packages/client/ui-primitives/src/ConfigField.tsx:6-27`（props 是 `label/value/secret/choices/disabled/overridden/invalid/onChange/onReset`，注释 `:29`「Render a field **without owning its schema**, draft, or persistence」）。

---

## A.6 插件贡献 UI 的机制 —— **A.6 结论（关键）**

**结论：插件 UI 是「浏览器里跑的 React 组件 + slot 注册表」，由宿主 `/plugins` 路由把插件的 `client.js` 送到浏览器后执行。没有任何服务端渲染或协议化的 UI 描述，所以手机端无法渲染插件自己的界面，除非手机本身就在跑这个 Web 客户端。**

### 链路

1. **声明**：`package.json` 的 `dsh.client`（`platform: 'web'`、`inject?`、`immediately?`、`external?`），类型 `packages/util/package-manifest/src/types.ts:81-94`；解析/校验 `packages/client/modules/src/client/manifest.ts:161-177`。
2. **宿主扫描**：`packages/client/modules` 的 Node 半边扫描所有 enabled Loader 行里声明了 `dsh.client` 的包，把每个声明编成 boot graph，并通过 `/plugins` 提供每个 bundle。`platform !== 'web'` 的行被跳过；声明了 `dsh.client` 却没导出 `./client` 的行**直接抛错**：`packages/client/modules/src/index.ts:841-847`。综述见 `packages/client/modules/README.md:12,34`。
3. **浏览器加载（懒）**：执行一个插件 bundle 只是**注册一个 factory**；模块体副作用（含 CSS 注入）在首次 materialize 时才跑：`packages/client/modules/README.md:12,66-68`。模块解析顺序 = 平台种子表 → 已记忆记录 → boot-graph 行 → 已注册 factory。
4. **共享模块**：React / Cordis / 静态 UI 库由 shell 冻结的 `PLATFORM_MODULES` 种子表提供，插件不得自带第二份 React；非基线运行时导入必须在 `dsh.client.external` 里精确声明：`packages/client/modules/README.md:46`。
5. **slot 注册表**：`packages/client/ui-slots`。`SlotMap` 是空的接口，靠 `declare module` 合并由各个消费包扩充 —— `packages/client/ui-slots/src/index.ts:26`、README `:56`。四种 kind：`single` / `list` / `keyed` / `chain`，README `:28`。
6. **注册 = 插件把 React 组件放进 slot**：`SlotCore.register(options, component)`，`packages/client/ui-slots/src/index.ts:1203`；往**未声明**的 slot 注册会在加载期抛错（fail loud）：`:1204-1207`；同一 cell 同 priority 的重复注册也抛错：`:1215-1240`。`kind: 'list'` 需要 `id`，`keyed` 需要 `key`，`chain` 需要 `select`。
7. **跟随声明时机**：`ctx.slots.inject(key, callback)`，`packages/client/ui-renderer/src/client/registry.ts:209`，用 `ctx.effect` 绑到声明生命周期（`:242`）——所以注册方不需要 import 声明方。
8. **渲染**：父组件调 `renderSlot(key, ownerProps, opts)`，例：`packages/client/ui-plugin-manager/src/client/PluginManagerPage.tsx:483`。

### 真实例子（插件注册进别的包的 slot）

- `packages/client/ui-jobs/src/client/index.ts:35-52` —— 把 `JobListAction` 注册进 `conversation.session.header.actions`，`id: 'job-list'`、`order: 20`，并通过 `inject` 传业务面（`ctx.jobs.*`）。
- `packages/client/ui-settings-plugin-inventory/src/client/index.ts:56-62` —— 注册进 `settings.plugins.tab`，id `'all'`。
- `packages/extensions/ui-cordis/src/client/slots.ts:23-37` —— 一个**扩展包**声明自己的 keyed slot `tool.view.cordis`（供运行时动态客户端代码注册）。

### 插件自己的配置页也是 slot

Plugins 页把三个「插件自带配置」的位置留出来，注册方拿到的是 `{ view: 'page' | 'summary', form?: { state, mutate } }`：

- `plugins.item`（list，官方插件卡片 + 详情页主体）
- `plugins.bundle.config`（keyed by 包名，bundle 详情页中部）
- `plugins.row.config`（keyed by `<包名>#<rowId>`，行详情页主体）
- 另有 `plugins.detail.actions` / `plugins.detail.badge` / `plugins.detail.section`（list，带 `subject`）

声明与 props：`packages/client/ui-plugin-manager/src/client/slot-contract.ts:75-121`；`form` 的形状 `:124-130`（`state: ConfigFormSnapshot` + `mutate`）；注册示例 `packages/client/ui-plugin-manager/README.md:62-68`、`:76-82`。实现要点：「页面拥有者提供 `form.state` 和 `form.mutate(operations, expectedRevision)`…自定义页面拥有自己的草稿与校验展示，可复用 `ui-primitives` 的 `ConfigField`」`packages/client/ui-plugin-manager/README.md:108`。

**结论**：所谓「插件的配置界面」不是一个数据描述，而是**一段必须在这个 Web 客户端里执行的 React 代码**。手机端要显示它，等价于手机端要跑 DSH 的 Web 客户端。

---

## A.7 给移动端的结论

### (a) 手机**可以**做且值得做的插件操作

1. **只读清单 + 状态**：`pluginInventory.list()`（`packages/host/plugin-inventory/src/index.ts:70-73`）就够了，含 entryId、moduleName、本地化 title/description/icon、enabled、fiberPhase。这是最划算的一屏。
2. **bundle 列表 + 版本/安装态/可移除性**：`pluginManager.listBundles()`（`:279-319`）→ `name/version/description/enabled/installed/optional/removable/rows`。
3. **行级与 bundle 级开关**：`setPluginEnabled(entryId, enabled)`（`:424-435`，**真正的组件级开关**）、`setBundleEnabled(name, enabled)`（`:442-448`）。二者都返回 `ChangeResult.application`，手机必须能把 `restart-required` / `overridden` / `failed` 讲清楚（`types.ts:114`）。
4. **看安装进度与日志**：订阅 `plugin-manager/install-log`（chunk 带 argv/cwd/stream/exitCode，`types.ts:212-226`）与 `install-state`（`installing` 带第几次 registry / `applying` / `cancelling`，`types.ts:199-205`、白名单 `remote-events.ts:43-44`）。
5. **安装 / 卸载（带二次确认）**：`inspect` → `installBundle` → `removeBundle`（`:340-417`、`:461-567`、`:600-626`）。
6. **通用 schema 表单（仅 volatile 字段）**：`settings.describe` / `update` / `replace` / `mutate`（`settings-controller/src/index.ts:97-158`），schema 用 `new Schema(json)` rehydrate 后校验（`ui-settings/src/client/schema.ts:50-67`）。
7. **插件目录元数据展示**：title/description/icon（`package-meta.ts:148-171`）。

### (b) 手机**做不到 / 不该做**的

1. **渲染插件自己的界面** —— 做不到。插件 UI 是浏览器 bundle 里的 React 组件 + slot 组合（A.6），没有任何协议化的 UI 描述；渲染它 = 在手机上跑 DSH 的 Web 客户端。**这是最硬的一条**。
2. **通用表单覆盖全部配置** —— 做不到。只有 `.volatile()` 字段上线（`settings/src/schema.ts:33-47`、`settings/src/index.ts:308-309`、README `:33`）；非 volatile 配置只有改 Cordis 配置文件一条路。
3. **指望 `autoGenerate` 帮你渲染** —— 不该做。字段存在且默认 true（`settings/src/index.ts:312`），但**没有任何出货客户端消费它**（README `:39`；client 源码 grep 零命中），DSH 自己在两次 note 里否决了通用渲染器（`2026-07-30-web-config-plane.md:31`、`2026-08-10-web-plugin-configuration.md:37`）。你要做就是从零做，而且要自己处理「视觉层级 / 高级字段分组 / 数组项卡片」这些被明确点名为失败原因的问题。
4. **静默批准 pnpm build script** —— 不该做。`approvedBuilds` 是一个会执行任意包脚本的权限（`types.ts:146`、`index.ts:473-476`），DSH 桌面端为此专门做了「列出确切包名 + 说明持久权限范围 + 一次批准整组」的确认界面（`ui-settings-plugin-inventory/README.md:30`）。手机端必须保留同等强度的显式确认。
5. **把安装/卸载做成一次点击** —— 不该做。它们会改电脑上的 `package.json` / `pnpm-lock.yaml` / `cordis.patch.yml` 并跑 pnpm（`index.ts:79,470-567,621-625`），失败还会回滚文件；且 `readOnlyReason` 行本来就不允许改（`:263-270`、`:428-429`）。
6. **`pluginManager` 里找配置读写** —— 没有。配置不在 pluginManager，只在 `settings.*`（A.4 表格）。

### (c) 降级方案

1. **「配置只读展示」**：手机显示 `title/description/icon/version/enabled/fiberPhase/rows[]`，配置只显示 `describe()` 返回的 `value`（并把 `secrets` 渲染成「已设置/未设置」两个状态，`settings/src/types.ts:37-38`），编辑入口留给电脑。
2. **通用 schema 表单只对 volatile 字段开**：能渲染就渲染（rehydrate + validate 现成），其余字段显示「该字段需在电脑上编辑」，并且**必须**显式说明「只有标为可在运行中修改的字段能在这里改」——否则用户会以为改不到就是坏了。
3. **「在电脑上打开」**：
   - 宿主已有 `settings.openSettingsDocument`（`settings-controller/src/index.ts:166-185`），但它打开的是**电脑上的原生编辑器**（`packages/api/settings-controller/src/index.ts:13` `openNativeTextFile`）——手机点它只会让电脑弹窗，**可以**利用这点（手机当遥控器：「在你的电脑上打开配置文件」），但要明确告诉用户去哪里看。
   - 对插件自定义 UI：提供「在电脑端打开插件页」的深链/提示（`ctx.pluginNavigation.openBundle(packageName)` 是客户端内部导航，见 `ui-plugin-manager/README.md:110`；跨设备需要你自己造 URL 或二维码），不要在手机里伪造插件页面。
4. **给插件作者一条正路**：如果希望手机能配置你的插件，就让配置字段声明 `.volatile()` 并在 schema 里写 `description`；这会让它自动出现在 `settings.describe()` 的 `schema` 里（`settings/src/index.ts:326`）。
5. **安装类操作做「两段 + 可在电脑上接管」**：手机发起时给出 registry 选择与取消（`cancelInstall`，返回 `too-late` 时明确告知「已进入应用阶段，无法取消」，`:584-594`），日志用 `install-log` 流式展示，失败时提示「到电脑上查看完整日志」。

---

## A.8 UI 参考：三个包各是什么

### `ui-plugin-manager` —— 侧边栏 Plugins 页（**操作台 + 配置页宿主**）

- 摘要：管理 profile 的 bundle 与其行，开关、安装、看 pnpm 输出、停止、卸载；插件自己注册配置页（`packages/client/ui-plugin-manager/README.md:14`）。
- 挂载点：侧边栏 `plugins` 条目 + `main` 面板，通过 `ctx.slots.inject()` 注册（README `:100`）。
- store 字段：`PluginManagerController` 拥有 bundle 视图、busy keys、notices、install progress、卸载确认；每次读先问 inventory 是否有 profile 管理能力，再把 `listBundles` 与 `listPlugins` join 成「每个 bundle 一个视图，行携带活 entry 的 enabled 与 fiberPhase」（README `:104`；实现 `manager-store.ts:773-786`）。
- 页面结构（`packages/client/ui-plugin-manager/src/client/PluginManagerPage.tsx`，1482 行）：
  - 顶层 `PluginManagerPage`：`:1252-1482`
  - 卡片清单的筛选与分组：`:1280-1283`（排除内建 profile bundle；`mine` = 已装/非可选；`official` = 可选且未装），`:1319-1329`（`renderGroup`：组标题 + 数量），`:1428-1429`（Official 组在前，Installed 组在后）
  - 卡片：`PackageCard` `:382-421`（图标、标题、描述、`statusBeta` / `statusProblem` 标签、开关）
  - 详情页：`PackageDetail` `:543-630`（面包屑、版本 Tag、`pkg.error` 原因、`readOnlyReason` 原因 `:606-607`、bundle 配置 slot `:611-612`）
  - 行的分区与行内元素：`RowsSection` `:194-274`（>10 行给过滤框 `:212-225`；每行 = 图标 + 标题 + 描述 + rowId/moduleName 代码块 + 状态文本 `:237-253`）
  - 行详情：`RowDetail` `:495-541`（`plugins.row.config` 的 page/summary `:524,528`）
  - 安装向导：`InstallDialog` `:780-1220`（spec 输入、registry 选择器 `:995-1067`、guide 折叠 `:963-983`、向导阶段 `:1106-1220`、build 批准块 `:1143-1151`、`installRetry` `:1183`）
  - 卸载确认：`ConfirmDialog` `:1226-1245`
  - 空/加载/失败态：`:1362-1388`
- 本包自己声明的配置 slot：`src/client/slot-contract.ts:75-121`。
- 已知限制（对手机同样成立）：页面刷新会丢掉跟踪中的安装请求与输出；一次只能装一个；无版本选择器；registry 选择是本浏览器 localStorage 的；每次 registry 读取都会跑 pnpm —— `README.md:148-154`。

### `ui-settings-plugins` —— Settings → Built-in plugins 的**外壳**（无自己的内容）

- 摘要：只是一个 shell，拥有导航条目和 tab 行，每个 tab 由别的插件注册；只读清单包注册了其中唯一一个 tab。官方插件的配置在侧边栏 Plugins 页，由各自的伴随包注册页面 —— `packages/client/ui-settings-plugins/README.md:12`、`:28-30`。
- 实现：`PluginsSettingsSection` `packages/client/ui-settings-plugins/src/client/PluginsSettingsSection.tsx:33-119`；tab 数据来自 `settings.plugins.tab` 贡献（`PluginsSettingsTabEntry = {id, order, label}` `:11-15`）；只有一个贡献时直接当页面渲染 `:57-58`；tab 首次选中后保持挂载以保留草稿/搜索/快照 `:44-51`；键盘左右/Home/End `:78-91`。
- **手机端不要照它做**（它自己不渲染任何东西）。

### `ui-settings-plugin-inventory` —— 只读清单 tab（**手机端最该照的**）

- 摘要：列出 agent preset（默认展开）与折叠的全局清单；卡片显示本地化标题/描述、稳定 entry id、启用态、来源、运行时状态、disable 条件、发现失败 —— `packages/client/ui-settings-plugin-inventory/README.md:12`。
- 读接口：首次选中才懒读 `ctx.remote.pluginInventory.list()`，激活期不读 —— README `:28`；实现 `src/client/index.ts:30`（`inject = ['slots','locale','remote','remote.pluginInventory','modules']`）、`:38`（调用）、`:56-62`（注册 tab）。
- 结构（`src/client/PluginInventorySettingsTab.tsx`，602 行）：
  - 卡片组件 `:124-179`（标题 + 描述最多两行 + entryId code chip `:169-171` + 展开详情）
  - 事实表 `CardFacts` `:181-219`（entryId、模块名、以及若干 `[label, value]` 对）
  - 状态点 `PhaseDot`：只对 `pending|loading|unloading` 显示，`active`/`failed` 不显示 `:221-231`；标签 `StateTag` `:247-250`
  - preset 行展开的事实：来自哪个 preset / 配置态 / 运行时 / disable 条件 `:362-368`
  - 全局行展开的事实：preset 提供说明 + 「在 preset 中查看」跳转 + 配置态 + 运行时 `:411-431`
  - 组与搜索：preset 组 `:490-565`（含 preset 切换器 `:502-528`）、全局组 `:567-590`、搜索框 `:474-486`、空/无匹配 `:486-487`、客户端同步失败与重试 `:439-452`
- 已知限制：一次 mount 一个快照（不订阅 Loader 变化）；**两个平面都只读**，不写入任何启用态 —— README `:98-99`。

### 手机端该照哪个

- **只读清单照 `ui-settings-plugin-inventory`**：分组（preset / 全局）+ 搜索 + 卡片（标题/描述/entryId/状态点/标签）+ 展开看事实 —— 这套信息密度与交互在窄屏上直接可用。
- **操作子集照 `ui-plugin-manager`**，但只搬：bundle 卡片 + 开关 + 详情页的「版本/描述/原因/行清单」+ 安装向导的阶段与日志。
- **不要搬** `ui-plugin-manager` 的 slot 配置页宿主（`plugins.item` / `plugins.bundle.config` / `plugins.row.config`）——那是给「在浏览器里跑的插件代码」准备的，手机里没有这些东西可以渲染（A.6）。
- **不要照 `ui-settings-plugins`**：它本身没有内容。

---

# B. 后台任务（ui-jobs）

## B.1 数据模型

`JobView`（`packages/jobs/jobs/src/view.ts:65-100`，一次读取一个新对象，绝不暴露活的 registry 状态）：

| 字段 | 行 | 说明 |
|---|---|---|
| `id` | `:67` | registry 分配的 `<kind>-N` |
| `kind` | `:73` | 生产者种类，**开放字符串**（浏览器 bundle 只看到自己编译期合并的 `JobKindMap`） |
| `label` | `:75` | 生产者给的一行标签 —— **「命令」就是它**（`JobSpec.label` 注释原文「the command; the delegation description」，`packages/jobs/jobs/src/types.ts:129`）。**没有独立的 `command` 字段（未找到）** |
| `owner?` | `:77` | 所属 session；没有 owner = 任何调用者可见 |
| `outputLimitBytes?` | `:79` | 生产者给「面向模型的完整通知/读取」的字节上限（**不影响观察者**，`types.ts:139-143`） |
| `status` | `:81` | 见 B.2 |
| `progress?` | `:83` | 活进度行（`3/10`），结案时清空 |
| `detail?` | `:85` | 终态原因（`exit code: 3`），kill 的 reason 会并入 |
| `startedAt` | `:87` | epoch ms，注册时间 |
| `finishedAt?` | `:89` | epoch ms，结案时间；活着时不存在 |
| `output` | `:99` | `{ total, earliest, spillPaths? }` —— `total` = 下一块起始偏移；`earliest` = 最老的保留字节（>0 表示头部被裁过）；`spillPaths` 是当前仍在的完整流文件 |

输出块 `JobChunk`：`at`（绝对偏移，永不移动）、`text`、`channel?`、`gapBefore?` —— `packages/jobs/jobs/src/view.ts:49-58`；channel 取值 `stdout | stderr | log`（`log` 只给观察者，模型读不到），`:40-46`。

终态 `JobOutcome`：`status: 'completed' | 'killed' | 'failed'`、`detail?`、`result?`（一次性返回给模型的返回值）—— `packages/jobs/jobs/src/types.ts:16-31`。
生产者声明 `JobSpec`：`kind`、`label`、`owner?`、`outputLimitBytes?`、`output?`（拉取源）、`run(job)` —— `:126-158`。

## B.2 状态机

- 状态联合：`JobStatus = 'running' | 'stopping' | 'completed' | 'killed' | 'failed'` —— `packages/jobs/jobs/src/view.ts:19`。
- 语义（同文件 `:14-18` 注释）：`running` → 可选 `stopping` → **恰好一个终态**；生产者特有事实放在 `progress` / `detail`。
- 结案原因 `JobSettleCause = 'producer' | 'kill' | 'teardown'` —— `packages/jobs/jobs/src/types.ts:192`。
- 事件：`registered | progress | stopping | removed | settled | output` —— `types.ts:200-226`；`settled` 额外带 `cause` 与 `awaited`。

### 用户可见文案

中文词典 `packages/client/ui-jobs/src/client/locales.ts`：

| 文案 | 行 |
|---|---|
| `status.running` 运行中 / `stopping` 正在停止 / `completed` 已完成 / `killed` 已取消 / `failed` 已失败 | `:22-26` |
| `section.live` 进行中 / `section.settledCount` 已结束 {count} / `section.clear` 清空 | `:13-15` |
| `count.live.*` `{count} 个后台任务运行中` / `count.idle.*` `{count} 个后台任务` | `:8-11` |
| `output.gap` `……较早的输出已丢弃……` / `output.error` `实时输出流中断：{error}` | `:32-33` |
| `kill.stop` 停止任务 {label} / `kill.confirm` 再次点击确认停止 / `kill.confirmAction` 确认停止 / `kill.failed` 停止失败 | `:18-21` |
| `terminal.signal` 信号 {signal} / `terminal.exitCode` 退出码 {code} / `terminal.noExitCode` **未正常退出** / `terminal.running|failed|done` / 复制 / （无输出） | `:34-46` |
| 时长 `duration.seconds|minutes|hours` + `duration.title.live` 已运行 / `.done` 耗时 | `:27-31` |

**`killed before exit`：未找到** —— 全仓（含 `.md`、`.json`）grep 该字符串零命中。终止原因的实际来源是生产者写进 `JobOutcome.detail` 的文本（`types.ts:19-24` 举例 `exit code: 3`），以及人类 kill 时宿主统一写入的 reason `cancelled by the user`（`packages/api/job-controller/src/index.ts:125`）。

## B.3 操作

| 操作 | 接口 | 位置 |
|---|---|---|
| **停止/取消** | RPC `job.kill({sessionId, jobId})` → `{outcome: 'requested' \| 'already-finished'}` | 宿主 `packages/api/job-controller/src/index.ts:109-127`；registry `JobRegistry.kill(id, caller?, reason?)` `packages/jobs/jobs/src/index.ts:150-160`；客户端 `ctx.jobs.kill` `packages/api/job-controller/src/client/service.ts:123-125`；UI 两段确认 `packages/client/ui-jobs/src/client/JobListAction.tsx:441-458` |
| **清空** | **没有 RPC** | 前端只是本地隐藏（`clearedKeys` 客户端 Set）：`JobListAction.tsx:334-336`、`:467-476`，且注释明说「client-side hide only; the registry keeps its records」。registry 有 `remove(id, caller)`（`packages/jobs/jobs/src/index.ts:175-183`）但**未暴露**给 `job` 命名空间 —— `packages/api/job-controller/src/types.ts` 里只有 list/follow/kill |
| **查看输出** | 流式 RPC `job.follow({sessionId?, jobId, from?})` | 宿主 `packages/api/job-controller/src/index.ts:90-96`；帧类型 `packages/api/job-controller/src/types.ts:72-90`；客户端 `ctx.jobs.observe(sessionId, id)` `packages/api/job-controller/src/client/service.ts:136-143`；累加状态 `.../client/model.ts:126-179` |
| **列表** | 流式 RPC `job.list({sessionId})`，整集替换 | 宿主 `packages/api/job-controller/src/index.ts:75-78`；`streamJobRows` `.../src/rows.ts:26-53`（开流一帧，之后每次生命周期提交合并 `flushMs` 后一帧；**输出追加不刷新列表**，`rows.ts:13-19`）；客户端 `ctx.jobs.watchRows` `client/service.ts:127-134` |
| **重试** | **未找到** | `job` 命名空间没有 retry；registry 也没有。UI 里的 `installRetry`（`PluginManagerPage.tsx:1183`）属于插件安装，与作业无关 |
| 等待结案（仅模型侧） | `JobRegistry.wait(id, timeoutMs, caller?, signal?)` | `packages/jobs/jobs/src/index.ts:162-173` |

补充：kill 的访问围栏是 owner session —— 看不到的行会变成 `RemoteError('job/not-found')`（`job-controller/src/index.ts:113-121`）；人类 kill 不消耗模型的完成通知，owning agent 仍会收到（`job-controller/src/index.ts:99-106`）。

## B.4 输出怎么拿

**流式，不是快照**：`job.list` 与 `job.follow` 都是 `@Remote({ mode: 'stream' })`（`packages/api/job-controller/src/index.ts:75,90`）。

- 开流时先给一帧 `opened`，携带 `job.output.earliest` / `total` 和第一个 `output` 帧的起点 `from` —— `packages/api/job-controller/src/observe.ts:68-70`。
- 之后是合并过的 `output` 批帧，最后在「已结案且 drain 完」时给一帧 `status`，然后流正常关闭 —— `observe.ts:81-85`；类型 `types.ts:63-71`（注释说明 status 与 output 走同一条流，避免结算与输出通道竞争）。
- 非消费式：观察者的读取**不移动模型的游标** —— `observe.ts:30-34`；从任意偏移续读：请求带 `from`，宿主校验必须是非负安全整数（`observe.ts:47-49`）。

### 上限与截断（必须知道的三层 + 一层）

1. **每帧软上限**：默认 64 KiB，`DEFAULT_OBSERVE_MAX_FRAME_BYTES = 64 * 1024`（`job-controller/src/index.ts:32`），配置项 `observeMaxFrameBytes`（`:46-49`）；**单个大于预算的 chunk 整块发出**（`observe.ts:12-17`、`:96-132`）。
2. **ring 保留**：活着的作业保留 **256 KiB**（`DEFAULT_RETAIN_BYTES = 256 * 1024`，`packages/jobs/jobs-local/src/index.ts:36`），结案后裁到 **16 KiB**（`DEFAULT_SETTLED_RETAIN_BYTES = 16 * 1024`，`:39`）。头部裁剪见 `packages/jobs/jobs-local/src/ring.ts:76-93`（整块丢弃；单块超限时只留 UTF-8 安全尾巴并置 `gapBefore`，`:84-91`）。读在保留窗口之下返回 `lossy: true` 而**不是错误**：`ring.ts:111`。
3. **模型侧上限**：`outputLimitBytes` 只约束「面向模型的完整通知与读取」，与 ring 保留无关（`packages/jobs/jobs/src/types.ts:139-143`）；模型读取的裁剪实现在 `packages/jobs/tool-jobs/src/index.ts:87-142`。
4. **客户端渲染尾巴**：`RENDER_TAIL_LIMIT = 128 * 1024`（UTF-16 码元），超出就切片并置 `gapBefore: true`，且不会切在代理对中间 —— `packages/api/job-controller/src/client/model.ts:16`、`:155-162`。

结案时 ring 会被裁到 `max(settledRetainBytes, total - modelCursor)`（先把模型还没读的留下），模型的首次终态读取之后才裁到 settled cap —— `packages/jobs/jobs-local/src/index.ts:594-598`、`:442-449`。

## B.5 `JobListAction.tsx`（559 行）界面结构

`packages/client/ui-jobs/src/client/JobListAction.tsx`

- **入口形态**：会话头部的一个按钮（slot `conversation.session.header.actions`，`id: 'job-list'`，`order: 20` —— `src/client/index.ts:35-52`）。**没有任何作业时返回 `null`**，整个控件不出现：`:460`。
- **触发按钮**：`:507-527` —— 运行中时左侧一个 ongoing 状态点 `:524`，中间计数文案，右侧 chevron。计数文案按「有活作业 → `{n} 个后台任务运行中`；否则 → `{总可见数} 个后台任务`」选择 key：`:462-465`。
- **弹层**：`ul.menu`，`:530`。
- **分组（两段）**：
  - 活作业段：段头 `section.live`（纯文本，不折叠）：`:531-534`
  - 已结束段：段头是一个按钮（chevron + `已结束 {count}`，可折叠）+ 一个「清空」按钮：`:535-552`；默认展开策略 = 用户显式切换优先，否则「只有存在活作业时才折叠」：`:352`；清空只影响本地：`:467-476`
- **行内元素（两种布局）**：
  - **活行**（两行式）：第一行 label（`title` 提示全文）；第二行 `kind` + `detail ?? status` + 时长；右侧 chevron：`:203-222`
  - **已结束行**（单行）：状态点 + `kind` + label + `detail ?? status` + 时长 +（可观察时才有）chevron：`:223-238`
  - 时长：`formatDuration` 最多两个相邻单位（时/分/秒），`:116-124`；`title` 用 `已运行 {d}` 或 `耗时 {d}`：`:195-202,30-31`
- **展开后显示什么**（`:287-308`）：一个面板，依次是
  1. `gapBefore` → 「……较早的输出已丢弃……」（`:290`）
  2. 流错误 → 「实时输出流中断：{error}」（`:291-293`）
  3. `TerminalBlock`：`command = job.label`、`output = view.text`、`running = live`、`maxLines = Infinity`（面板自己滚动，不做中部折叠）、`runStateDot = false`（状态点已在上一行）：`:294-305`
- **徽标与状态点**：
  - `dotState(status)`：`running → ongoing`、`stopping → warning`、`completed → done`、`killed → warning`、`failed → error`；注释说明 `stopping` 与 `killed` 共用 attention 色，因为两者都表示「因请求而结束或正在结束」：`:82-96`
  - `StateDot` 来自 `@deepseek-ai/dsh-client-ui-primitives`（`:5-7`），用在行首 `:206,225` 与触发按钮 `:524`
  - 状态文案 `statusLabel`：`:98-108`
  - 「可展开」判定 `isObservable = 活的 || output.total > 0`：`:67-69`；活行恒为可观察
- **停止按钮**：只在 `running` 行出现（`:495-502`）；两段确认，armed 态 3 秒自动解除（`KILL_ARM_MS` `:53`，`:423-430`），armed 时按钮变宽成带文字「确认停止」的 pill（`:280-283`），失败态保留 4 秒（`KILL_FAILED_MS` `:56`）；点击流程 `pressKill` `:441-458`（**已受理的 kill 保持 pending**，等权威 jobs 帧把行翻成 `stopping` 才移除按钮，注释 `:449-453`）
- **排序**：活作业按 `startedAt` 升序在前；已结束按 `finishedAt` 降序在后，同毫秒回落到 startedAt 升序（保证不依赖宿主 map 迭代顺序）：`:158-166`
- **观察流按可见性开关**：只有展开的那一行才 `observe(sessionId, id)`，收起/关弹层/卸载即停 —— `:397-404`；弹出层的视口适配 `:371-393`；Escape 关闭并回焦 `:478-483`

## B.6 给移动端的建议：后台任务页怎么排

1. **列表分两组，活组永远在上面，结算组可折叠且默认只在「没有活任务」时展开。** 依据：现有排序与折叠策略 `JobListAction.tsx:158-166`、`:352`；窄屏上把「进行中」顶到第一屏是这套排序唯一的理由。
2. **行内只放四个元素：状态点 + `kind` + `label` + `detail ?? status`（外加时长）。** 依据：已结算行的单行布局 `:223-238`；`detail` 优先于状态词是因为它信息量更大（`exit code: 3` vs `已完成`，`:71-74`）。竖屏不要照活行的两行式（`:203-222`），除非宽度允许。
3. **详情不用「跳页」，用行内展开，展开即订阅。** 依据：现有实现就是行内面板（`:287-308`）+「展开才开 `job.follow`，收起即关」（`:397-404`）。手机尤其要这样：`job.follow` 是流，按需开关才不会在后台持续拉流。
4. **展开面板必须显式渲染 `gapBefore` 与流错误两种提示。** 依据：`:290-293`，配合三层截断（每帧 64 KiB `job-controller/src/index.ts:32`；ring 256 KiB/16 KiB `jobs-local/src/index.ts:36,39`；客户端渲染尾 128 KiB `client/model.ts:16`）——手机上很容易看到不完整输出，不提示就会被当成程序出错。
5. **「清空」要按「仅本机隐藏」实现，并在 UI 上别承诺删除。** 依据：现在就是客户端 `clearedKeys` 本地隐藏，registry 仍保留记录，稍后新结案会重新出现（`JobListAction.tsx:334-336`、`:467-476`）。
6. **停止用两段确认 + 等权威帧同步状态，不要在 RPC 返回时就乐观更新。** 依据：`pressKill` 在 kill 被受理后仍保持 pending，理由写在 `:449-453`（HTTP 单次响应与 jobs 控制流没有跨通道顺序保证）。
7. **运行中提醒（手机特有，可选）**：数据源用 `job.list` 的整集帧（`rows.ts:13-19`：只在注册/进度/stopping/结案/移除时刷新，**单纯的输出追加不刷新**，所以是个安静且省电的信号源），配合 `JobView.status` 只在 `running|stopping` 计数（`JobListAction.tsx:59-61`）。不要在手机上用 `job.follow` 做提醒——那是给「有人在看」准备的。
8. **不要做「重试」按钮**：`job` 命名空间没有重试接口（B.3），要做只能在电脑上重新发起。

---

# C. 插件页面能不能在手机上"通用适配"？——结论

> 这一节回答一个产品判断问题，证据来自插件 slot 契约与 Schemastery 序列化。

## C.1 插件页面无法通用渲染（结构性限制，不是工作量问题）

插件页 = **注册进 slot 的 React 组件**，由宿主把插件 `client.js` 送进浏览器执行。

- `packages/client/ui-plugin-manager/src/client/slot-contract.ts:75-121` —— 插件的界面贡献全是 slot 声明：`plugins.item`、`plugins.bundle.config`、`plugins.row.config`、`plugins.detail.actions` / `.badge` / `.section`。
- 同文件 `:124-130`（`PluginConfigViewProps`）—— slot 拿到的是 **`view: 'summary' | 'page'` + `state`/`mutate` 活对象**，即"给 React 组件传参"，**不是给客户端一份可渲染的页面描述**。仓库内没有任何 JSON 页面结构 / 布局 DSL 供非 React 客户端消费。
- 反证：官方插件**一个插件一个伴随包**地写手写配置页（`ui-settings-general` / `-shell` / `-subagent` / `-agent-loop` / `-web-search` / `-models` / `-session-log`），就是因为没有通用渲染器。

**推论**：让手机渲染任意插件页 ≡ 在手机上跑 DSH Web 客户端。这不是"适配多少个插件"的数量问题，而是**换运行时**的问题。所以"插件那么多、页面那么多，不可能一个一个适配"这个判断是**对的**，而且理由比"工作量大"更根本 —— 通用适配在架构上不存在。

## C.2 但配置有**一条真实的通用路径**：Schemastery schema 会过线

配置走的是 **Schemastery**（`@deepseek-ai/schemastery`）序列化信封，**不是 JSON Schema**：

- 过线类型：`packages/settings/settings/src/types.ts:27-28` —— "Serialized schemastery schema envelope (`schema.toJSON()`); rehydrate with `new Schema(json)`"。
- 线上构造：`packages/settings/settings/src/index.ts:302-340`，`schema: form.toJSON()` 在 `:326`；命名空间 key = 该插件行的 Loader entry id（`:315`）。
- 客户端可 rehydrate / 校验 / 按路径取节点：`packages/client/ui-settings/src/client/schema.ts:39-80`（`SettingsSchemaService.rehydrate` / `validate` / `nodeAtPath`）。
- 序列化结果**带 UI 元数据**：`vendor/schemastery/src/index.ts:115`（`required`）、`:126`（`description`，支持多语言字典）、`:391`（`disabled` / `collapse` / `hidden` / `loose`）、`:403-411`（`badges`：deprecated / experimental）。**够渲染出一个像样的表单**（类型 + 必填 + 说明 + 折叠 / 禁用）。

**四条必须写进产品说明的限制**：

1. **只有 `volatile` 字段会过线**。`packages/settings/settings/src/schema.ts:33-47` + `settings/src/index.ts:308-309`：没有 `.volatile()` 字段的行**根本不出现在** `describe()` 结果里。README `packages/settings/settings/README.md:33` 原文："Forms expose only volatile fields… Ordinary configuration remains editable through Cordis configuration files."
2. 宿主确实提供 `autoGenerate`（默认 true，`settings/src/index.ts:312`），但 README `:39` 明说 "…for clients that build pages from the schema; **no shipped client does so yet.**" —— **没有任何出货客户端消费它**，别指望白拿。
3. 写回走路径寻址的 `settings.update/replace/mutate`（`packages/api/settings-controller/src/index.ts:97-158`），所以**不会误删手机上没拿到的 secret**。
4. 现成积木只有一个**不带 schema** 的受控输入组件 `ConfigField`（`packages/client/ui-primitives/src/ConfigField.tsx:6-27`）—— 通用渲染器要自建。

## C.3 落到产品上的三条策略

1. **不做"插件页面适配"这件事**。手机端只做插件**管理**（清单 / 状态 / 启用停用 / 安装卸载 / 日志），插件自己的页面给「在电脑端打开」。
2. **配置分两档**：`volatile` 字段 → 手机用通用表单（自建 Schemastery 渲染器）；其余 → **只读展示 + 标明"需在电脑上编辑"**，不装作能用。
3. **给插件作者一条正路**：字段声明 `.volatile()` 并写 `description`，就自动进入手机端表单 —— 把"能不能在手机上配"变成插件作者的一个显式选择，而不是我们逐个人肉适配。

> 这条与设计文档 §12 的结论一致，并补上了 schema 机制与限制的源码证据。
