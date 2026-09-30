# 本机运行模式（Standalone Mode）调研与设计草案

> 调研对象：开源安卓 AI 聊天 App **rikkahub**（本地克隆 `C:\sudy\github\rikkahub`，Kotlin + Jetpack Compose）。
> 方法：**只读代码**，未修改任何文件。所有事实均给 `相对路径:行号`（相对 rikkahub 仓库根）。
> 结论若找不到证据，显式写「未找到」，不做推测。
> 目的：为 `dsh-mobile` 增加第二条路线——**手机不连电脑、自己就能跑**的 AI 客户端模式，与现有「遥控 DSH」模式共存于同一 App。

---

## 0. 一句话结论

rikkahub 是一个**纯端侧**的 AI 客户端：配置（含 API Key）以**明文 JSON** 存在 DataStore，会话存 Room，模型列表来自 provider 的 `/models` 接口 + 内置能力识别表，附件全部**本地处理**（文档本地抽文本、图片转 base64 内联），MCP 只支持 HTTP/SSE（无 stdio），**没有任何引导流程**——不配置就直接在聊天页报「请先选择模型」。它把「思考档位」做成一个**跨 provider 统一的 7 档枚举**（`ReasoningLevel`），在请求构造时按 provider 翻译成各自的字段。这正是我们本机模式最值得抄的一块。

---

## 1. 配置存储

### 1.1 主配置：DataStore Preferences（不是 Room）

| 事项 | 结论 | 证据 |
| --- | --- | --- |
| 存储机制 | `androidx.datastore.preferences` 的 `DataStore<Preferences>` | `app/src/main/java/me/rerere/rikkahub/data/datastore/PreferencesStore.kt:9-17, 80-100` |
| 文件名 | `"settings"` | `PreferencesStore.kt:66`（`SETTINGS_STORE_NAME`）、`:81`（`preferencesDataStoreFile`） |
| 实例管理 | 进程内单例（`@Volatile` + `synchronized`），注释明确「同一文件只能存在一个 DataStore 实例」 | `PreferencesStore.kt:71-78` |
| 序列化 | 每个字段单独 `JsonInstant.encodeToString(...)` 成 **JSON 字符串** 写进一个 Preference key | `PreferencesStore.kt:193-252` |
| 迁移 | `PreferenceStoreV1Migration/V2/V3`，DataStore 声明式迁移 | `PreferencesStore.kt:93-97` |
| 损坏处理 | 备份原文件为 `*.corrupt-<ts>` 后重建为空 | `PreferencesStore.kt:83-92` |
| 读取失败 | 明确**不回退为空配置**（否则默认值会被当用户数据写回、覆盖全部设置），重试 3 次后抛出 | `PreferencesStore.kt:69, 257-266` |
| 写入入口 | `persistSettings()` / `restoreBeforeInitialization()`（后者用于备份恢复，早于 Koin 初始化） | `PreferencesStore.kt:188-252` |

### 1.2 配置容器：`Settings` data class

`PreferencesStore.kt:561-617`。与本机模式直接相关的字段：

| 字段 | 类型 | 行号 |
| --- | --- | --- |
| `providers` | `List<ProviderSetting>` | `PreferencesStore.kt:587` |
| `assistants` | `List<Assistant>` | `:588` |
| `assistantId` | `Uuid`（当前选中助手） | `:586` |
| `chatModelId` / `fastModelId` / `imageGenerationModelId` / `ocrModelId` / `compressModelId` / `translateModeId` | `Uuid` | `:572-584` |
| `favoriteModels` | `List<Uuid>` | `:571` |
| `mcpServers` | `List<McpServerConfig>` | `:593` |
| `searchServices` / `searchCommonOptions` / `searchServiceSelected` | 搜索配置 | `:590-592` |
| `ttsProviders` / `selectedTTSProviderId` / `asrProviders` / `selectedASRProviderId` | 语音 | `:596-600` |
| `modeInjections` / `lorebooks` | 提示词注入 | `:601-602` |
| `quickMessages` | `List<QuickMessage>` | `:603` |
| `networkSetting` | `NetworkSetting`（代理） | `:570` |
| `displaySetting` | `DisplaySetting` | `:569` |
| `webDavConfig` / `s3Config` | 备份目标 | `:594-595` |

持久化/读取对应关系：`providers` 写在 `:218`、读在 `:296`；`assistants` 写在 `:220`、读在 `:297`；`mcpServers` 写在 `:228`。**这些就是同一份 JSON blob 的两端**。

### 1.3 Room 里存什么（只有会话类数据）

`app/src/main/java/me/rerere/rikkahub/data/db/AppDatabase.kt:30-63`，版本 25，8 个实体：

| 实体 | 用途 |
| --- | --- |
| `ConversationEntity` | 会话（含 `nodes`） |
| `MessageNodeEntity` | 消息节点（分支/多候选） |
| `MemoryEntity` | 助手记忆 |
| `FavoriteEntity` | 收藏 |
| `FolderEntity` | 会话文件夹（助手内分组） |
| `ManagedFileEntity` | 受管文件（含 `upload/` 目录与显示名） |
| `GenMediaEntity` | 生成的多媒体 |
| `WorkspaceEntity` | 工作区（proot Linux 环境） |

**结论：provider / model / assistant / API Key 全部不在 Room，全在那个 DataStore JSON blob 里；Room 只放会话与文件元数据。**

### 1.4 加密：**没有**

- 全仓库搜索 `EncryptedSharedPreferences|MasterKey|AndroidKeyStore|KeygenParameterSpec|Cipher\.|javax\.crypto|KeyStore`，**唯一命中**是 AWS SigV4 的 HMAC 签名：`app/src/main/java/me/rerere/rikkahub/data/sync/s3/AwsSignatureV4.kt:8-9`。
- API Key 是 `ProviderSetting` 上的普通 `String` 字段：`ai/src/main/java/me/rerere/ai/provider/ProviderSetting.kt:63`（OpenAI）、`:126`（Google）、`:191`（Claude）。
- 备份 ZIP 直接把 `settings.json`（含明文 apiKey）写进去，无加密：`app/src/main/java/me/rerere/rikkahub/data/sync/BackupManager.kt:44-46`。

> **给我们的直接教训**：rikkahub 的 API Key 是明文落盘的（DataStore 文件 + 备份 ZIP）。我们**不能照抄**这一点——见草案「密钥安全」。

### 1.5 默认值

- `DEFAULT_PROVIDERS`：`app/src/main/java/me/rerere/rikkahub/data/datastore/DefaultProviders.kt:19`
- `DEFAULT_AUTO_MODEL_ID`：`DefaultProviders.kt:17`
- `DEFAULT_ASSISTANT_ID` / `DEFAULT_ASSISTANTS`：`PreferencesStore.kt:783-809`
- 升级时按 id 补齐缺失的默认助手/默认 TTS provider：`PreferencesStore.kt:370-377`
- `Settings.dummy()`（`init=true`）用于「未初始化的初始值，不允许保存」：`PreferencesStore.kt:613-616`

---

## 2. 服务商接入

### 2.1 只有三种 ProviderSetting（协议族），不是几十个厂商类

`ai/src/main/java/me/rerere/ai/provider/ProviderSetting.kt:241-249`：

```
val Types by lazy { listOf(OpenAI::class, Google::class, Claude::class) }
```

`@SerialName`：`"openai"`（`:53`）、`"google"`（`:116`）、`"claude"`（`:181`）。

公共抽象字段：`id / enabled / name / models / balanceOption`（`:27-31`）、`builtIn`（`:33`）。

### 2.2 自定义 OpenAI 兼容端点：字段清单

`ProviderSetting.OpenAI`（`ProviderSetting.kt:52-69`）：

| 字段 | 默认值 | 行号 |
| --- | --- | --- |
| `apiKey` | `""` | `:63` |
| `baseUrl` | `https://api.openai.com/v1` | `:64` |
| `chatCompletionsPath` | `/chat/completions` | `:65` |
| `useResponseApi` | `false`（切到 Responses API） | `:66` |
| `includeHistoryReasoning` | `true` | `:67` |
| `responsesPath` | `/responses` | `:68` |

`ProviderSetting.Google`（`:115-134`）：`apiKey`、`baseUrl`（`.../v1beta`）、`vertexAI`、`useServiceAccount`、`privateKey`、`serviceAccountEmail`、`location`、`projectId`。

`ProviderSetting.Claude`（`:180-195`）：`apiKey`、`baseUrl`（`https://api.anthropic.com/v1`）、`promptCaching`、`promptCacheTtl`（`ClaudePromptCacheTtl` `:16-23`，5m/1h）。

**自定义 header / body 不在 provider 级，而在 model 级与 assistant 级**：

- Model 级：`ai/src/main/java/me/rerere/ai/provider/Model.kt:13-14`（`customHeaders`、`customBodies`）、`:19`（`providerOverwrite: ProviderSetting?`，即「这个模型单独覆盖 provider 配置」）。
- Assistant 级：`app/src/main/java/me/rerere/rikkahub/data/model/Assistant.kt:38-39`。
- 组装时 **assistant 在前、model 在后** 合并：`app/src/main/java/me/rerere/rikkahub/data/ai/GenerationLoop.kt:393-400`。
- 数据结构：`CustomHeader(name, value)`、`CustomBody(key, value: JsonElement)`：`ai/src/main/java/me/rerere/ai/provider/Provider.kt:118-128`。
- 一个注意点：**provider 级没有自定义 header 字段**（`ProviderSetting` 抽象里没有），自定义 header 只能挂 model 或 assistant。

### 2.3 内置 provider 目录（厂商预置）

`DefaultProviders.kt:19-…`，`DEFAULT_PROVIDERS` 列表（均带 `baseUrl`；除标注外都是 `ProviderSetting.OpenAI` 兼容端点）：

| 名称 | baseUrl | 行号 |
| --- | --- | --- |
| OpenAI | `https://api.openai.com/v1` | `:22-23` |
| Gemini | （Google 类型） | `:29` |
| AiHubMix | `https://aihubmix.com/v1` | `:36-37` |
| APIMart | `https://api.apimart.ai/v1` | `:70-71` |
| 硅基流动 | `https://api.siliconflow.cn/v1` | `:94-95` |
| DeepSeek | `https://api.deepseek.com/v1` | `:109-110` |
| 月之暗面 | `https://api.moonshot.cn/v1` | `:121-122` |
| OpenRouter | `https://openrouter.ai/api/v1` | `:134-135` |
| Vercel AI Gateway | `https://ai-gateway.vercel.sh/v1` | `:146-147` |
| 阿里云百炼 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `:159-160` |
| 火山引擎 | `https://ark.cn-beijing.volces.com/api/v3` | `:167-168` |
| 智谱AI开放平台 | `https://open.bigmodel.cn/api/paas/v4` | `:175-176` |
| 阶跃星辰 | `https://api.stepfun.com/v1` | `:183-184` |
| 302.AI | `https://api.302.ai/v1` | `:191-192` |
| 腾讯Hunyuan | `https://tokenhub.tencentmaas.com/v1` | `:211-212` |
| xAI | `https://api.x.ai/v1`（`useResponseApi = true`） | `:219-224` |
| 随想AI网关 | `https://sui-xiang.com/v1` | `:228-229` |
| MaruCode | `https://api.muteki.site/v1`（`useResponseApi = true`） | `:254-278` |
| MiniMax | `https://api.minimaxi.com/anthropic/v1`（**Claude 类型**） | `:282-283` |
| MIMO | `https://api.xiaomimimo.com/v1` | `:290-291` |

另有 `RecommendedProviders.kt`（`RECOMMENDED_PROVIDERS`，被 `ui/pages/setting/SettingProviderPage.kt:71` 引用）。

### 2.4 代理

- 配置字段：`NetworkSetting.proxyUrl / proxyUsername / proxyPassword / userAgent`：`PreferencesStore.kt:619-626`。
- 生效位置：OkHttpClient 构建 + 拦截器：`app/src/main/java/me/rerere/rikkahub/di/DataSourceModule.kt:116-142`（`:181` 另有 `AIRequestInterceptor`）。
- 解析工具：`app/src/main/java/me/rerere/rikkahub/data/network/ProxyConfig.kt:33-90`。
- UI：`app/src/main/java/me/rerere/rikkahub/ui/pages/setting/SettingPreferencesNetworkPage.kt:74-124`（含代理连通性测试 `:390`）。

### 2.5 相关界面文件

| 页面 | 文件 | 关键函数 |
| --- | --- | --- |
| 服务商列表（增删改、拖拽排序、搜索） | `ui/pages/setting/SettingProviderPage.kt` | `SettingProviderPage` `:94`；重排 `:101-106` |
| 服务商详情（配置/模型 两 tab） | `ui/pages/setting/SettingProviderDetailPage.kt` | `SettingProviderDetailPage` `:138`；`SettingProviderConfigPage` `:259`；`SettingProviderModelPage` `:374` |
| 配置表单（apiKey/baseUrl/path/代理无关项） | `ui/pages/setting/components/ProviderConfigure.kt` | apiKey `:219-221`；baseUrl `:233-237`；path `:241-251`；Response API 开关 `:274-279`；Claude prompt caching `:354-374`；Vertex `:474-537` |
| 连通性测试 | `ui/pages/setting/components/ProviderConnectionTester.kt` | — |
| 余额显示 | `ui/pages/setting/components/BalanceOption.kt`、`ui/components/ai/ProviderBalanceText.kt` | `BalanceOption` 结构 `ProviderSetting.kt:9-14` |

---

## 3. 模型管理

### 3.1 `Model` 数据结构（完整字段）

`ai/src/main/java/me/rerere/ai/provider/Model.kt:7-20`：

| 字段 | 类型 | 默认 | 行号 |
| --- | --- | --- | --- |
| `modelId` | `String` | `""` | `:9` |
| `displayName` | `String` | `""` | `:10` |
| `id` | `Uuid` | random | `:11` |
| `type` | `ModelType` | `CHAT` | `:12` |
| `customHeaders` | `List<CustomHeader>` | empty | `:13` |
| `customBodies` | `List<CustomBody>` | empty | `:14` |
| `inputModalities` | `List<Modality>` | `[TEXT]` | `:15` |
| `outputModalities` | `List<Modality>` | `[TEXT]` | `:16` |
| `abilities` | `List<ModelAbility>` | empty | `:17` |
| `tools` | `Set<BuiltInTools>` | empty | `:18` |
| `providerOverwrite` | `ProviderSetting?` | null | `:19` |

枚举：

- `ModelType { CHAT, IMAGE, EMBEDDING }`：`Model.kt:22-27`
- `Modality { TEXT, IMAGE }`：`:29-33`
- `ModelAbility { TOOL, REASONING }`：`:35-39`
- `BuiltInTools { Search("search"), UrlContext("url_context"), ImageGeneration("image_generation") }`：`:41-57`
- `BalanceOption { enabled, apiPath, resultPath }`：`ProviderSetting.kt:9-14`

> **重要事实（易误判）**：`Model` 里**没有** `temperature` / `topP` / `maxTokens` / `contextWindow`。
> - 采样参数与最大输出在 **assistant** 上：`Assistant.kt:24-25`（`temperature`、`topP`）、`:37`（`maxTokens`）。
> - 上下文上限是 **消息条数**（不是 token 数）也在 assistant：`Assistant.kt:26-27`（`contextMessageLimit`，0 = 不限）。
> - 「上下文长度（token）」只存在于内置识别表 `ModelRegistry`（`ModelDsl.kt:15`、`ModelRegistry.kt:726`），**UI 不可编辑、也不参与请求构造**——全仓库仅测试引用 `MODEL_CONTEXT_LENGTH`（`ai/src/test/java/me/rerere/ai/registry/ModelRegistryTest.kt:59-62,138-158`）。

### 3.2 模型列表来源：远端拉取 + 手填（两条都支持）

| 机制 | 说明 | 证据 |
| --- | --- | --- |
| **远端拉取** | `Provider.listModels()` → `GET {baseUrl}/models` | 接口 `ai/.../provider/Provider.kt:18`；OpenAI `providers/openai/OpenAIProvider.kt:58-62`；Claude `providers/claude/ClaudeProvider.kt:247-250`；Google `providers/google/GoogleProvider.kt:126` |
| 拉取时机 | 进入「模型」tab 即自动 `produceState` 拉取（**不是按钮触发**），失败仅打日志 | `SettingProviderDetailPage.kt:390-400` |
| 勾选添加 | 底部 sheet 列出可用模型，支持关键词过滤、全选/取消 | `ModelPicker` `:832-1005`；全选 `:883-898` |
| **手填** | `Button` 打开空 `Model()` 表单，手输 `modelId` + `displayName` + 类型/模态/能力 | `AddModelButton` `:669-753`（`:733` 打开空 Model）；表单 `ModelSettingsForm` `:488`；字段 `:560-617` |
| 内置识别表 | 输入 modelId 时按正则/分词匹配，自动填 `inputModalities`/`outputModalities`/`abilities` | `ModelRegistry.kt:708-724`；调用点 `SettingProviderDetailPage.kt:497-500, 691-699, 940-943`；导入器 `data/sync/importer/CherryStudioProviderImporter.kt:111-113` |

内置识别表覆盖的系列（不逐个列，只给位置）：`ModelRegistry.kt:10`（`object ModelRegistry`），含 GPT/o 系列 `:11-100`、Gemini 系列 `:102-190`、Claude 系列 `:212-258`、Kimi `:427-446`、Qwen `:604` 等；能力辅助函数 `visionInput()` `:762`、`toolAbility()` `:770`、`reasoningAbility()` `:774`、`toolReasoningAbility()` `:778`。
匹配算法（分词 + 序列匹配 + 精确 id 加成 1000）：`ModelDsl.kt:10-29, 149-229`。

### 3.3 参数最终落在哪里

`GenerationLoop.kt:386-402` 一次性组装 `TextGenerationParams`：

```
model, temperature = assistant.temperature, topP = assistant.topP,
maxTokens = assistant.maxTokens, tools, reasoningLevel = assistant.reasoningLevel,
customHeaders = assistant.customHeaders + model.customHeaders,
customBody = assistant.customBodies + model.customBodies, sessionId
```

`TextGenerationParams` 定义：`ai/.../provider/Provider.kt:67-78`。

**结论：生成参数是「助手级」的，模型级只能加 header/body 覆盖；没有「每个模型一套默认参数」。**

---

## 4. 【重点】思考程度 / 推理档位

### 4.1 数据结构：一个跨 provider 的 7 档枚举

`ai/src/main/java/me/rerere/ai/core/Reasoning.kt:6-43`：

| 枚举 | `@SerialName` | `budgetTokens` | `effort` | 行号 |
| --- | --- | --- | --- | --- |
| `OFF` | `"off"` | `0` | `"none"` | `:11-12` |
| `AUTO` | `"auto"` | `-1` | `"auto"` | `:14-15` |
| `LOW` | `"low"` | `1_000` | `"low"` | `:17-18` |
| `MEDIUM` | `"medium"` | `2_000` | `"medium"` | `:20-21` |
| `HIGH` | `"high"` | `8_000` | `"high"` | `:23-24` |
| `XHIGH` | `"xhigh"` | `16_000` | `"xhigh"` | `:26-27` |
| `MAX` | `"max"` | `32_000` | `"max"` | `:29-30` |

- `isEnabled = this != OFF`：`:32-33`
- `fromBudgetTokens(budgetTokens)`：找最接近的档（给「用预算数字」的旧配置做迁移）：`:36-42`

**要点：同一档位同时携带两种表达能力——`budgetTokens`（给 Gemini 的 thinkingBudget）和 `effort`（给 OpenAI/Anthropic 的 effort 字符串）。所以 UI 只需要一个滑杆，provider 层各自取用。**

### 4.2 存在哪、怎么进请求

| 环节 | 位置 |
| --- | --- |
| 存字段 | `Assistant.reasoningLevel: ReasoningLevel = AUTO` — `app/.../data/model/Assistant.kt:36` |
| 请求参数 | `TextGenerationParams.reasoningLevel`（默认 `OFF`）— `ai/.../provider/Provider.kt:74` |
| 组装 | `GenerationLoop.kt:392`（`reasoningLevel = assistant.reasoningLevel`） |
| 全局「快速模型」档位 | `Settings.fastModelReasoningLevel`（默认 `AUTO`）— `PreferencesStore.kt:574`，持久化 `:205`/读取 `:276-278`；用于标题/建议等后台生成 `service/ChatService.kt:854, 906` |
| 翻译模型档位 | `Settings.translateThinkingBudget: Int` — `PreferencesStore.kt:579`；转档 `data/ai/TranslationHandler.kt:54` |
| 写入助手的接口 | `SettingsStore.updateAssistantReasoningLevel()` — `PreferencesStore.kt:495-503` |
| Web API | `web/routes/SettingsRoutes.kt:59-67`、`web/dto/WebDto.kt:93-95` |

### 4.3 UI：哪里选、长什么样

**A. 聊天输入区（主入口）** — `app/src/main/java/me/rerere/rikkahub/ui/components/ai/ReasoningPicker.kt`

- `ReasoningButton`：`ReasoningPicker.kt:50-85`，`ToggleSurface(checked = reasoningLevel.isEnabled)`（`:66-70`）——**按钮的选中态就是「思考是否开启」**，点击弹出 picker。
- `ReasoningPicker`：`:88-199`，`ModalBottomSheet`（`:106-108`）+ 标题/提示（`:123-132`）+ 大图标（`:144-157`）+ 档位名（`:158-161`）+ **一条 0..6 的离散 `Slider`**（`:94-100` 构造，`:164-196` 渲染，`steps = levelCount - 2`）。提交时机是**松手**：`onValueChangeFinished` 取整后回调 `onUpdateReasoningLevel(levels[snappedIndex])`（`:167-171`）。
- 图标映射：`:145-153` 与 `:202-212`（OFF=Idea、AUTO=Idea01、LOW/MEDIUM/HIGH 专用图标，XHIGH/MAX 复用 HIGH 图标）。
- 文案：`:215-223`（`reasoning_off / reasoning_auto / reasoning_light / reasoning_medium / reasoning_heavy / reasoning_xhigh / reasoning_max`）。
- **显示条件**：仅当当前模型带 `ModelAbility.REASONING` 才出现 —— `ui/components/ai/ChatInput.kt:340-349`
  ```
  val model = settings.getCurrentChatModel()
  if (model?.abilities?.contains(ModelAbility.REASONING) == true) { ReasoningButton(...) }
  ```

**B. 助手设置页** — `ui/pages/assistant/detail/AssistantBasicPage.kt:480-482`（`reasoningLevel = assistant.reasoningLevel`，`onUpdate(assistant.copy(reasoningLevel = level))`）。

**C. 后台/快速模型** — `ui/pages/setting/SettingModelPage.kt:125-127`（`fastModelReasoningLevel`）与组件 `:194-235`。

**D. 翻译模型** — `ui/pages/setting/SettingModelPromptPage.kt:54-55`（`translateThinkingBudget` ↔ `ReasoningLevel`）与组件 `:104-127`。

**E. 模型能力开关（决定上面这些 UI 是否出现）** — 模型编辑表单里的 `ModalAbilitySelector`：`SettingProviderDetailPage.kt:1114`，调用点 `:611-617`。

### 4.4 支持哪些 provider（请求侧翻译表）

所有翻译都**先过一道能力闸门**：模型必须带 `ModelAbility.REASONING`。

**OpenAI Chat Completions**（`ai/.../providers/openai/ChatCompletionsAPI.kt:271` 闸门，`:273-416` 按 `host` 分派）：

| host | 发什么 | 行号 |
| --- | --- | --- |
| `openrouter.ai` | `reasoning.effort`；OFF→`none`；AUTO→`enabled: true`；其余→`level.effort` | `:274-283` |
| `dashscope.aliyuncs.com`（百炼） | `reasoning_effort`（AUTO 时不发） | `:285-291` |
| `ark.cn-beijing.volces.com`（豆包） | `thinking.type = disabled/enabled` | `:293-298` |
| `api.mistral.ai` | **不支持**（注释明示） | `:300-302` |
| `chat.intern-ai.org.cn`（书生） | `thinking_mode = isEnabled` | `:304-308` |
| `api.siliconflow.cn` | `enable_thinking = isEnabled`，且**只对硬编码模型清单生效** | `:310-343`（清单 `:313-339`） |
| `aiping.cn` | `enable_thinking` | `:345-347` |
| `open.bigmodel.cn`（智谱） | `thinking.type` | `:349-353` |
| `api.xiaomimimo.com` / `token-plan-cn.xiaomimimo.com` | `thinking.type` | `:355-361` |
| `api.moonshot.cn`（Kimi） | `thinking.type`；K2.6 且开启时加 `thinking.keep = "all"` | `:363-372` |
| `api.deepseek.com` | `thinking.type` + `reasoning_effort`（MEDIUM/HIGH→`high`，MAX→`max`） | `:374-386` |
| `integrate.api.nvidia.com` | `reasoning_effort`（deepseek-v4 与非 v4 两套映射） | `:388-403` |
| `opencode.ai` | `reasoning_effort = level.effort` | `:405-409` |
| **其它（自定义兼容端点）** | `reasoning_effort = level.effort`（AUTO 时不发） | `:411-415` |

**OpenAI Responses API** — `ai/.../providers/openai/ResponseAPI.kt:239-253`（`reasoning.effort`，AUTO 时不设；并请求 `reasoning.encrypted_content` `:252`）。

**Anthropic Claude** — `ai/.../providers/claude/ClaudeProvider.kt:478-501`（闸门 `:478`）：
- OFF → `thinking.type = "disabled"`（`:480-482`）
- AUTO → `thinking = {type: adaptive, display: summarized}`（`:484-489`）
- 其余 → 同上 + `output_config.effort = level.effort`（`:491-499`）
- 备注：思考开启时**不下发 `temperature`**（`:450`）；注释说明旧的 `type=enabled + budget_tokens` 在 Opus 4.7+ 已不支持（`:476-477`）。

**Google Gemini** — `ai/.../providers/google/GoogleProvider.kt:355-387`（闸门 `:355`）：
- 固定 `thinkingConfig.includeThoughts = true`（`:357`）
- AUTO → 不设参数（`:363`）
- OFF → Gemini 3 系列发 `thinkingLevel = "minimal"`；非 Pro 发 `thinkingBudget = 0` 且 `includeThoughts = false`（`:365-372`）
- 其余 → Gemini 3 系列 `thinkingLevel = low/medium/high`；否则 `thinkingBudget = level.budgetTokens`（`:374-384`）

### 4.5 思考内容的回读与展示

- 消息部件：`UIMessagePart.Reasoning`（`ai/.../ui/UIMessagePart.kt:114-121`），带 `reasoningType`：`ReasoningType { reasoning_text, summary_text }`（`:63-70`）。
- 流式解码：Chat Completions `providers/openai/ChatCompletionsStreamDecoder.kt:99-117`（读 `reasoning_content` / `reasoning` / `reasoning_details`）；Responses `ResponseApiStreamDecoder.kt:55-82, 99-121`（`reasoning_summary_text.delta` / `reasoning_text.delta`）；Claude `ClaudeProvider.kt:794-800`（thinking + signature 元数据）；Google `GoogleStreamDecoder.kt:129-137`。
- 元数据（跨轮回传）：`ai/.../ui/MessageMetadata.kt:33-38`（OpenAI `reasoning_id` + `encrypted_content`）、`:79-84`（OpenRouter `reasoning_details`）。
- 展示开关：`DisplaySetting.showThinkingContent`、`autoCloseThinking` — `PreferencesStore.kt:662-663`。

### 4.6 这一条的直接结论（回答「rikkahub 里到底怎么选」）

1. **怎么选**：聊天输入区一个「灯泡」按钮（仅带 REASONING 能力的模型可见）→ 底部 sheet 里一条 **7 档离散滑杆**：关 / 自动 / 轻 / 中 / 重 / 更高 / 最大。松手即写回**当前助手**的 `reasoningLevel`。同样的控件也出现在助手设置页，以及「快速模型」「翻译模型」两处。
2. **存哪**：`Assistant.reasoningLevel`（助手级，默认 `AUTO`）；`Settings.fastModelReasoningLevel`、`Settings.translateThinkingBudget` 两处全局。
3. **支持哪些 provider**：**OpenAI 兼容（含自定义端点）、OpenAI Responses、Anthropic Claude、Google Gemini** 四大协议全覆盖。但 OpenAI 兼容路径是**按 baseUrl 的 host 硬编码分派**（`:273-416`），已知厂商各有专属字段（`enable_thinking` / `thinking.type` / `thinking_mode` / `reasoning_effort`），**未知 host 走 `reasoning_effort` 兜底**；`api.mistral.ai` 明确不支持；siliconflow 还额外限制在硬编码模型清单内。
4. **能力闸门**：必须是 `ModelAbility.REASONING` 模型（内置识别表自动判定，或用户手勾）。
5. **UI 文件**：`app/src/main/java/me/rerere/rikkahub/ui/components/ai/ReasoningPicker.kt`。

---

## 5. 文件上传 / 附件

### 5.1 选择入口（相册 / 拍照 / 视频 / 音频 / 文档）

`app/src/main/java/me/rerere/rikkahub/ui/components/ai/ChatAttachmentPicker.kt`

| 动作 | 实现 | 行号 |
| --- | --- | --- |
| 抽象动作集 | `ChatAttachmentPickerActions { onTakePicture, onPickImage, onPickVideo, onPickAudio, onPickFile }` | `:33-39` |
| **拍照** | `ActivityResultContracts.TakePicture` + `FileProvider`（`cacheDir/camera_<uuid>.jpg`） | `:67-94` |
| 拍照后裁剪 | 若 `displaySetting.skipCropImage == false` 走 `useCropLauncher` | `:56-66, 69-77` |
| **相册** | `ActivityResultContracts.GetMultipleContents()` + `"image/*"` | `:107-139, 190` |
| 相册裁剪 | 单图且未跳过裁剪 → 存临时 jpg → `launchImageCrop`；HEIF/HEIC 先转 JPEG | `:97-106, 114-135`（HEIF `:119-120`） |
| 视频 | `GetMultipleContents()` + `"video/*"` | `:141-147, 191` |
| 音频 | `GetMultipleContents()` + `"audio/*"` | `:149-155, 192` |
| **文档** | `ActivityResultContracts.OpenMultipleDocuments()` + `arrayOf("*/*")` | `:157-186, 193` |
| 类型过滤 | 逐个 `isAllowedFileType(fileName, mime)`，不合法则 toast 拒绝 | `:163-179` |

### 5.2 允许的文件类型

`app/src/main/java/me/rerere/rikkahub/utils/ChatUtil.kt`

- `ALLOWED_MIME_TYPES`：text/* 若干、json、pdf、doc/docx、**xls/xlsx**、ppt/pptx、epub（`:35-45`）
- `ALLOWED_FILE_EXTENSIONS`：txt、md、csv、json、js、ts、py、kt、java、go、rs、sh、yml、toml…（`:47-57`）
- `isAllowedFileType()`：MIME 命中、或 `text/*`、或扩展名命中（`:59-63`）

> **一个真实缺口（值得注意）**：picker **允许** xls/xlsx（mime 在 `:40-41`），但文本抽取的 `when` 分支只处理 pdf/docx/pptx/epub，其余一律 `file.readText()`（`DocumentAsPromptTransformer.kt:77-83`）。即 **xlsx 会被当纯文本读取**，结果是乱码/二进制噪声，而不是表格内容。我们没有找到任何 xlsx 分支（未找到）。我们做本机模式时要么补 xlsx 解析，要么在 picker 里就拒绝它。

### 5.3 落盘位置

- 统一复制进 `filesDir/upload`：`data/files/FilesManager.kt:105-140`（`createChatFilesByContents`，目标目录 `:107`、`:129` 登记 `folder = FileFolders.UPLOAD`）
- 目录常量：`FileFolders { UPLOAD="upload", SKILLS="skills", BUILTIN_SKILLS="builtin_skills", FONTS="fonts", TOOL_OUTPUTS="tool_outputs" }` — `FilesManager.kt:513-518`
- 元数据入库（Room `managed_files`）：`FilesManager.kt:129`、`data/db/entity/ManagedFileEntity.kt`

### 5.4 文档怎么处理：**本地抽文本后注入 prompt**（不上传原文件）

`app/src/main/java/me/rerere/rikkahub/data/ai/transformers/DocumentAsPromptTransformer.kt`

- 遍历 `UIMessagePart.Document`，读出文本，包成 `<UploadFile name="…">```…```</UploadFile>`，**插到 parts 第 0 位**：`:24-38`（`:37` 是 `add(0, UIMessagePart.Text(prompt))`）
- 按 MIME 分派：`application/pdf` → `PdfParser.parserPdf`（`:46-48, 78`）；docx → `DocxParser.parse`（`:50-52, 79`）；pptx → `PptxParser.parse`（`:54-56, 80`）；epub → `EpubParser.parse`（`:58-60, 81`）；**其它一律 `file.readText()`**（`:82`）
- 失败兜底为 `[ERROR, failed to read file: …]` 文本（`:84-86`），不中断
- 解析器实体在独立 Gradle 模块：`document/src/main/java/me/rerere/document/PdfParser.kt`、`DocxParser.kt`、`PptxParser.kt`、`EpubParser.kt`；PDF 走捆绑的 MuPDF native（`document/src/main/jniLibs/arm64-v8a/libmupdf_java.so`）
- 额外：文档同时被映射成工作区路径 `/upload/<name>`，供 workspace 工具直接读原文件（`:62-68`）；工作区提示词声明 `/upload` 只读（`data/ai/transformers/WorkspaceReminderTransformer.kt:107`）

### 5.5 图片怎么发：**base64 内联，无 provider Files API**

- `ai/src/main/java/me/rerere/ai/util/FileEncoder.kt:52-81` `encodeBase64()`：`file://` → 压缩后转 `data:<mime>;base64,...`（`:54-68`），`data:` 原样（`:70-74`），`http` 直接给 URL（`:75-78`）
- 压缩策略：**强制 JPEG、quality 85、maxDimension 10000、maxPixels 16M**，GIF 保持原样（`:117-159`）；EXIF 方向归一（`:161-196`）
- Google 走 `inlineData`（`ai/.../providers/google/GoogleProvider.kt:743-768`；解析 `:624-627`）
- 视频/音频同样 base64 化：`FileEncoder.kt:83-115`
- **未找到**任何「上传到 provider Files API」的调用（搜 `uploadFile|filesApi|FileApi|/upload/` 仅命中本地目录与测试）

### 5.6 输入区预览与删除

- `app/src/main/java/me/rerere/rikkahub/ui/components/ai/AttachmentChips.kt`
- `MediaFileInputRow`：横向滚动一行 chips（`:47-144`）；图片用 `AsyncImage` 缩略图（`:89-94`），视频/音频/文档用图标 chip（`:101-138`）
- 删除：`removePart()`（`:59-64`）从 `state.messageContent` 移除，且按 `shouldDeleteFileOnRemove` 决定是否删磁盘文件（`:61-63`）
- chip 本体：`AttachmentChip`（`:147-190`），右上 `Cancel01` 图标可点（`:174-187`）
- 展示名解析（把本地文件名换成管理显示名）：`:214-233`
- **未找到**附件数量上限或体积上限的校验（只有图片压缩的像素上限）

### 5.7 其它相关

- OCR 转换器：`data/ai/transformers/OcrTransformer.kt:56-99`（对 `file://` 图片走 OCR 模型）
- 文件管理页：`ui/pages/setting/SettingFilesPage.kt`、`data/db/dao/ManagedFileDAO.kt`
- 附件在选择时也会进 `ChatInputState`（`ui/hooks/…`），发送时由转换器链处理

---

## 6. MCP / 工具

### 6.1 传输：只有 **SSE** 和 **Streamable HTTP**，没有 stdio

`app/src/main/java/me/rerere/rikkahub/data/ai/mcp/McpConfig.kt`

- `sealed class McpServerConfig`（`:62-95`）
  - `SseTransportServer`（`@SerialName("sse")`，只有 `url`）：`:72-82`
  - `StreamableHTTPServer`（`@SerialName("streamable_http")`，只有 `url`）：`:84-94`
- 公共选项 `McpCommonOptions { enable, name, headers: List<Pair<String,String>>, tools: List<McpTool>, oauth }`：`:9-15`
- OAuth 2.1（动态客户端注册 + token 刷新，含脱敏 `toString`）：`:23-51`
- 工具缓存 `McpTool { enable, name, description, inputSchema, needsApproval }`：`:53-60`
- 取 url 的辅助扩展：`:97-102`
- **结论：Android 上无 stdio 是合理的，只支持远程 MCP。**（与我们的形态一致：手机不可能拉起本地 stdio 子进程）

### 6.2 配置与连接

- 全局列表存 `Settings.mcpServers`（`PreferencesStore.kt:593`，持久化 `:228`）
- 管理界面：`ui/pages/setting/SettingMcpPage.kt`
  - 列表 `:117`；新建默认 `StreamableHTTPServer`（`:160`）
  - 传输类型切换（0=Streamable HTTP / 1=SSE）：`:616-643`
  - URL 输入与校验：`:665-695`
  - 自定义 header 增删改：`:707-818`
  - 工具列表与 `needsApproval` 开关：`:838-899`
  - JSON 导入：`:1004-1025`
- 客户端实现：`data/ai/mcp/McpManager.kt`（自建 OkHttp `:47`）、`McpSessionRegistry.kt`、`McpStatus.kt`、`McpOAuthCoordinator.kt`

### 6.3 工具如何暴露给模型

`app/src/main/java/me/rerere/rikkahub/data/ai/tools/ChatToolFactory.kt:38-95`，一次生成的全部工具集：

| 来源 | 条件 | 行号 |
| --- | --- | --- |
| 记忆工具 | `assistant.enableMemory` | `:44-58` |
| 外部联网搜索工具 | `assistant.enableWebSearch && BuiltInTools.Search !in model.tools` | `:59-61`（判定 `:21-23`） |
| **本地工具** | 按 `assistant.localTools` | `:62` |
| 近期会话检索 | `assistant.enableRecentChatsReference` | `:63-65` |
| 工作区工具 | `assistant.workspaceId` 且 shell 状态 READY | `:66, 97-108` |
| Skills 工具 | `assistant.enabledSkills` 非空 | `:67-74` |
| **MCP 工具** | 全部可用 MCP 工具，命名 `mcp__{server}__{tool}`，`needsApproval` 透传 | `:76-94` |

工具调用审批状态机：`UIMessagePart.Tool.approvalState` + `ToolApprovalState { Auto, Pending, Approved, Denied, Answered }`（`ai/.../ui/UIMessagePart.kt:11-43, 182-216`）。

### 6.4 内置本地工具清单

`app/src/main/java/me/rerere/rikkahub/data/ai/tools/local/LocalToolOption.kt:7-38`：

`javascript_engine`、`time_info`、`clipboard`、`tts`、`ask_user`、`screen_time`、`calendar`、`chart_display`

实现文件（`data/ai/tools/local/`）：`JavascriptTool.kt`、`TimeInfoTool.kt`、`ClipboardTool.kt`、`TextToSpeechTool.kt`、`AskUserTool.kt`、`ScreenTimeTool.kt`、`CalendarTool.kt`、`ChartDisplayTool.kt`；聚合器 `LocalTools.kt`。
默认值：`Assistant.localTools = listOf(LocalToolOption.TimeInfo)`（`Assistant.kt:41`）。

### 6.5 服务端（provider 侧）内置工具

`Model.tools: Set<BuiltInTools>`（`Model.kt:18`）：`Search`、`UrlContext`、`ImageGeneration`（`Model.kt:41-57`）。UI：`BuiltInToolsSettings`（`SettingProviderDetailPage.kt:1322`）。聊天页搜索模式切换会直接改 model 的 `tools`（`ui/pages/chat/ChatPage.kt:367-383`）。

### 6.6 工具开关的层级

- 每助手：`mcpServers: Set<Uuid>`（`Assistant.kt:40`）、`localTools`（`:41`）、`enableWebSearch`（`:42`）、`enabledSkills`（`:49`）
- 每模型：`abilities`（TOOL/REASONING，决定能否用工具）、`tools`（用哪些服务端内置工具）
- 单工具级：`McpTool.needsApproval`（`McpConfig.kt:59`）

---

## 7. 助手 / 会话模型

### 7.1 `Assistant` 完整字段

`app/src/main/java/me/rerere/rikkahub/data/model/Assistant.kt:15-54`

| 字段 | 类型 | 默认 | 行号 |
| --- | --- | --- | --- |
| `id` | `Uuid` | random | `:17` |
| `chatModelId` | `Uuid?` | null（null → 用全局默认模型） | `:18` |
| `name` | `String` | `""` | `:19` |
| `avatar` | `Avatar` | `Dummy` | `:20` |
| `useAssistantAvatar` | `Boolean` | false | `:21` |
| `tags` | `List<Uuid>` | empty | `:22` |
| `systemPrompt` | `String` | `""` | `:23` |
| `temperature` | `Float?` | null | `:24` |
| `topP` | `Float?` | null | `:25` |
| `contextMessageLimit` | `Int` | 0（不限；超出阶梯截断） | `:26-27` |
| `streamOutput` | `Boolean` | true | `:28` |
| `enableMemory` | `Boolean` | false | `:29` |
| `useGlobalMemory` | `Boolean` | false（共享记忆） | `:30` |
| `enableRecentChatsReference` | `Boolean` | false | `:31` |
| `messageTemplate` | `String` | `"{{ message }}"` | `:32` |
| `presetMessages` | `List<UIMessage>` | empty | `:33` |
| `quickMessageIds` | `Set<Uuid>` | empty | `:34` |
| `regexes` | `List<AssistantRegex>` | empty | `:35` |
| **`reasoningLevel`** | `ReasoningLevel` | `AUTO` | **`:36`** |
| `maxTokens` | `Int?` | null | `:37` |
| `customHeaders` / `customBodies` | `List<CustomHeader>` / `List<CustomBody>` | empty | `:38-39` |
| `mcpServers` | `Set<Uuid>` | empty | `:40` |
| `localTools` | `List<LocalToolOption>` | `[TimeInfo]` | `:41` |
| `enableWebSearch` | `Boolean` | false | `:42` |
| `workspaceId` | `Uuid?` | null | `:43` |
| `background` / `backgroundOpacity` / `useGradientBackground` | `String?` / `Float` / `Boolean` | null / 1.0 / false | `:44-46` |
| `modeInjectionIds` | `Set<Uuid>` | empty | `:47` |
| `lorebookIds` | `Set<Uuid>` | empty | `:48` |
| `enabledSkills` | `Set<String>` | empty | `:49` |
| `enableTimeReminder` / `timeReminderIntervalMinutes` | `Boolean` / `Int` | false / 60 | `:50-51` |
| `allowConversationSystemPrompt` | `Boolean` | false（允许会话覆盖系统提示词） | `:52` |
| `allowConversationPromptInjection` | `Boolean` | false | `:53` |

配套类型：`QuickMessage { id, title, content }`（`:56-61`）、`AssistantMemory { id: Int, content }`（`:63-67`）、`AssistantRegex { id, name, enabled, findRegex, replaceString, affectingScope, visualOnly }`（`:75-84`）。

### 7.2 会话如何绑定助手

- `Conversation.assistantId: Uuid`（**非空、必填**）：`app/.../data/model/Conversation.kt:16-18`
- 解析：`Settings.getAssistantById(id)` — `PreferencesStore.kt:744-746`；当前助手 `getCurrentAssistant()` — `:740-742`（找不到就取第一个）
- 调用点：`service/ChatService.kt:402, 606, 1207`；`ui/pages/chat/ChatList.kt:263-264`；`ui/hooks/UseAssistant.kt:31`
- 会话还可覆盖：`customSystemPrompt`（`Conversation.kt:27`，受 `allowConversationSystemPrompt` 授权）、`modeInjectionIds` / `lorebookIds`（`:28-29`，受 `allowConversationPromptInjection` 授权）
- 助手切换会写回全局选中助手：`ChatService.kt:287`、`ChatDrawerVM`/`ChatVM.kt:168-175`
- 模型选择优先级：`assistant.chatModelId ?: settings.chatModelId` — `PreferencesStore.kt:736-737`、`ChatInput.kt:172`

### 7.3 助手管理界面

| 页面 | 文件 |
| --- | --- |
| 助手列表 | `ui/pages/assistant/AssistantPage.kt:81` |
| CRUD / 复制 | `ui/pages/assistant/AssistantVM.kt:33`（add）、`:44`（remove）、`:70`（copy）、`:59`（清理头像文件） |
| 助手详情（入口卡 7 项） | `ui/pages/assistant/detail/AssistantDetailPage.kt:93-145` |
| 基础（模型绑定 / 温度 / topP / maxTokens / 思考档位 / 上下文条数） | `ui/pages/assistant/detail/AssistantBasicPage.kt`（思考档位 `:480-482`） |
| 提示词 / 注入 / Lorebook | `ui/pages/assistant/detail/AssistantPromptPage.kt`、`AssistantExtensionsPage.kt` |
| 记忆 | `ui/pages/assistant/detail/AssistantMemoryPage.kt` |
| 请求覆盖（custom headers / bodies） | `ui/pages/assistant/detail/AssistantRequestPage.kt:79-101` |
| MCP 绑定 | `ui/pages/assistant/detail/AssistantMcpPage.kt` |
| 本地工具 | `ui/pages/assistant/detail/AssistantLocalToolPage.kt` |
| 导入（从别的 App） | `ui/pages/assistant/detail/AssistantImporter.kt` |

---

## 8. 本地能力

### 8.1 聊天记录存储与搜索

- 存储：Room（`ConversationEntity` / `MessageNodeEntity`），见 §1.3。
- **全文检索**：SQLite **FTS5 虚拟表** `message_fts`，建表在 `data/db/AppDatabaseFactory.kt:38`。
  - 索引维护 + 查询：`data/db/fts/MessageFtsManager.kt`（重建 `:35-41`、清空 `:57-61`、`search()` `:64-93`）
  - 查询用 `text MATCH jieba_query(?)`（`:86`）+ `simple_snippet(...)`（`:84`），即**中文分词**（自定义分词器 `data/db/fts/SimpleDictManager.kt`）
  - 可按助手过滤：`MessageFtsManager.kt:91`
- 标题级 LIKE 搜索：`data/db/dao/ConversationDAO.kt:36-46`
- 搜索 UI：`ui/pages/search/SearchVM.kt:148`（`conversationRepo.searchMessages`）、页面 `ui/pages/search/`、路由 `Screen.MessageSearch`（`RouteActivity.kt:527`）

### 8.2 导入 / 导出 / 备份

两种完全不同的东西，别混：

**(a) 单对象导出/导入（mode injection、lorebook）**
- 格式：`ExportData { version, type, data }` JSON — `data/export/ExportSerializer.kt:19-23`
- 导入导出框架（含 SAF 文件选择、分享 intent、缓存目录写文件）：`data/export/ExportHooks.kt:25-160`
- 兼容 SillyTavern 世界书导入：`ExportSerializer.kt:145-204`

**(b) 全量备份（ZIP）**
- `data/sync/BackupManager.kt:37-73`：ZIP 内含 `settings.json`（**含明文 API Key**）+ 可选 SQLite 快照（`includeDatabase`）+ 可选 `upload/`、`skills/`、`fonts/`（`includeFiles`）
- DB 快照工具：`data/sync/DatabaseBackup.kt`
- 恢复：先 staged 到 `noBackupFilesDir/backup-restore`，校验 + 旧 schema 迁移，再原子发布（`BackupManager.kt:75-139`）；**在 Koin/Room 初始化之前应用**（`RikkaHubApp.kt:59-69`、`BackupManager.kt:163-168`）
- 云端目标：WebDAV（`data/sync/webdav/WebDavClient.kt`、`WebDavSync.kt`）、S3（`data/sync/s3/S3Client.kt`、`AwsSignatureV4.kt`、`S3Config.kt`）
- 迁移/导入器（从别的 App 搬家）：`data/sync/importer/ChatboxImporter.kt`、`CherryStudioProviderImporter.kt`
- UI：`ui/pages/backup/BackupPage.kt` + `tabs/ImportExportTab.kt`、`S3Tab.kt`、`WebDavTab.kt`、`ReminderTab.kt`
- **备份无加密**（`BackupManager.kt:44-46` 直接写 `settings.json`）

### 8.3 TTS / STT

- 独立 Gradle 模块 `speech/`
- **TTS provider**：`speech/src/main/java/me/rerere/tts/provider/TTSProviderSetting.kt`；实现有 System（系统 TTS）、OpenAI、Gemini、MiniMax、Groq、FishAudio、ElevenLabs、Qwen、Step、Volcengine、MiMo、XAI（`speech/.../provider/providers/*.kt`）
- TTS 引擎：`tts/controller/TtsController.kt`、`TtsSynthesizer.kt`、`AudioPlayer.kt`、`TextChunker.kt`（长文分块）
- 默认 TTS provider：系统 TTS + AiHubMix `gpt-4o-mini-tts`（`PreferencesStore.kt:811-824`）
- **ASR（语音输入）**：`speech/src/main/java/me/rerere/asr/`；provider 有 DashScope、MiMo、OpenAI Realtime、Step、Volcengine（`asr/providers/*.kt`）；配置类 `ASRProviderSetting.kt`；状态机 `ASRState.kt`
- UI：`ui/pages/setting/SettingSpeechPage.kt`、`ui/pages/setting/components/TTSProviderConfigure.kt`、`ASRProviderConfigure.kt`；输入区 `ui/components/ai/AsrButton.kt`、hook `ui/hooks/ASR.kt`；语音模式 `ui/pages/chat/VoiceMode.kt`
- TTS 也可作为**模型可调用的本地工具**（`TextToSpeechTool.kt` + `LocalToolOption.Tts`）

### 8.4 联网搜索

- 独立 Gradle 模块 `search/`，选项枚举 `search/src/main/java/me/rerere/search/SearchService.kt:143-320`
- 支持的引擎（`@SerialName`）：`bing_local`（`:176`）、`zhipu`（`:182`）、`doubao`（`:189`）、`tavily`（`:197`）、`exa`（`:205`）、`searxng`（`:212`）、`linkup`（`:223`）、`brave`（`:231`）、`metaso`（`:238`）、`ollama`（`:245`）、`perplexity`（`:252`）、`firecrawl`（`:261`）、`jina`（`:268`）、`bocha`（`:277`）、`rikkahub`（`:285`）、`grok`（`:293`）、`tinyfish`（`:303`）、`serper`（`:310`）、`custom_js`（`:317`）；另有 `global`/`custom` 选项（`:364, :367`）
- 对应实现文件：`search/src/main/java/me/rerere/search/*SearchService.kt`
- 配置字段：`searchServices` / `searchCommonOptions` / `searchServiceSelected`（`PreferencesStore.kt:590-592`），共用 HTTP 客户端注入 `SearchService.kt:71-81`
- 每个助手独立开关：`Assistant.enableWebSearch`（`Assistant.kt:42`）；也可用模型自带的服务端搜索（`BuiltInTools.Search`，见 §6.5）
- 聊天页搜索按钮：`ui/components/ai/SearchPicker.kt`、`ChatPage.kt:354-384`；设置页 `SettingSearchPage.kt` / `SettingSearchDetailPage.kt`

### 8.5 提示词注入

- 数据结构：`sealed class PromptInjection`（`Assistant.kt:152-199`）
  - `ModeInjection`：基于模式开关（`:166-177`）
  - `RegexInjection`：基于关键词/正则匹配（世界书），字段含 `keywords`、`useRegex`、`caseSensitive`、`scanDepth`、`constantActive`（`:182-198`）
- 注入位置 `InjectionPosition`：`BEFORE_SYSTEM_PROMPT` / `AFTER_SYSTEM_PROMPT` / `TOP_OF_CHAT` / `BOTTOM_OF_CHAT` / `AT_DEPTH`（`Assistant.kt:128-144`）
- `Lorebook`：一组 `RegexInjection`（`:204-211`）
- 触发与排序逻辑：`isTriggered()` `:219-240`、`extractContextForMatching()` `:249-256`、`getTriggeredInjections()` `:265-272`
- 默认注入：`DEFAULT_MODE_INJECTIONS`（Learning Mode）`PreferencesStore.kt:828-834`
- 绑定：助手级 `modeInjectionIds` / `lorebookIds`（`Assistant.kt:47-48`），会话级 `modeInjectionIds` / `lorebookIds`（`Conversation.kt:28-29`）
- UI：`AssistantExtensionsPage.kt`、`AssistantPromptPage.kt`、`ui/pages/extensions/`、`Screen.Prompts`（`RouteActivity.kt:495`）

### 8.6 快捷消息（Quick Messages）

- 数据：`QuickMessage { id, title, content }` — `Assistant.kt:56-61`
- 绑定：`Assistant.quickMessageIds: Set<Uuid>` — `Assistant.kt:34`（V3 迁移把它从助手内嵌改为全局表 + id 引用：`data/datastore/migration/PreferenceStoreV3Migration.kt:23-106`）
- 解析：`Settings.getQuickMessagesOfAssistant(assistant)` — `PreferencesStore.kt:748-749`
- 管理页：`ui/pages/extensions/QuickMessagesPage.kt:52`（CRUD，含 `QuickMessageCard` `:165`、`EditQuickMessageDialog` `:222`）；VM `QuickMessagesVM.kt:19-52`
- 输入区快速插入：`ui/components/ai/ChatInput.kt:750-786`（`QuickMessageButton`，点击 `state.appendText(content)` `:769`）
- 多选绑定 sheet：`ui/components/ai/ExtensionContent.kt:154-185`
- 全局设置里删掉时会级联清理助手的 id 引用：`QuickMessagesVM.kt:44-53`

### 8.7 其它值得知道的本机能力

- **Workspace（proot Linux rootfs）**：`WorkspaceEntity` / `WorkspaceDAO` / `data/ai/tools/WorkspaceTools.kt`（17KB）；UI `Screen.Workspaces` / `WorkspaceTerminal` / `WorkspaceFileEditor`（`RouteActivity.kt:503-515`）。这是 rikkahub「本机跑 shell」的重资产，我们**第一版不做**（见草案）。
- **Skills**：`data/files/SkillManager.kt`、`SkillsTools.kt`、内置 skill 资源 `app/src/main/assets/builtin_skills/`
- **内置 Web 服务器**：`service/WebServerService.kt`、`web/routes/*`、设置项 `webServerEnabled/port/jwt/accessPassword/localhostOnly`（`PreferencesStore.kt:604-608`）
- **Suggestion（回复建议）**：`Settings.enableSuggestion` / `suggestionPrompt`（`PreferencesStore.kt:580-581`）
- **标题自动生成 / 压缩上下文 / OCR / 翻译**：各自有成对的 modelId + prompt（`PreferencesStore.kt:576-585`）

---

## 9. 无网络 / 无服务端时的表现（首启动）

| 问题 | 结论 | 证据 |
| --- | --- | --- |
| 有引导流程吗 | **没有**。搜 `Onboarding|SetupPage|WelcomePage|firstRun` 无页面命中 | **未找到** |
| 启动落到哪 | 直接落 **聊天页**（新建会话或上次会话），无配置门禁 | `RouteActivity.kt:256-267` |
| Application 启动做什么 | 只做：应用备份恢复 → 启 Koin → 通知渠道 → 崩溃处理 → 清理临时文件/工具输出/工作区临时目录 → 工作区完整性检查 → 同步受管文件 → 解压内置 skills → 按设置启 Web 服务器 → launchCount++ | `RikkaHubApp.kt:55-109` |
| 默认 provider 状态 | 内置 20 个 provider 全部预置、`apiKey = ""`、`models = []` | `DefaultProviders.kt:19-…`、`ProviderSetting.kt:63` |
| 「未配置」怎么判定 | `Settings.isNotConfigured() = providers.all { it.models.isEmpty() }` | `PreferencesStore.kt:717` |
| 未配置时的提示 | 设置页顶部显示红色告警卡 `ProviderConfigWarningCard`，点按钮跳「服务商」页 | `ui/pages/setting/SettingPage.kt:142-146`、`:380-417` |
| 未选模型时发消息 | 直接拦下并 toast `"请先选择模型"`，不发生网络请求 | `ui/pages/chat/ChatPage.kt:385-389` |
| 模型解析失败 | `getCurrentChatModel()` 返回 null | `PreferencesStore.kt:736-737` |
| 语音模式同理 | `chat_page_voice_select_model` | `ui/pages/chat/VoiceMode.kt:71` |
| 有本地/免费/离线模型吗 | **未找到**。没有端侧 LLM、没有内置 demo provider；仅有 `Ollama` 作为**联网搜索**服务（`SearchService.kt:245`），不是本地推理 | **未找到** |

**净结论**：rikkahub 首启动是「空壳可用但发不出消息」——聊天 UI 全在，但在你手工加 provider + API Key + 至少勾一个模型之前，任何发送都被拦下。它**不强制**你走向导，只在一个不显眼的地方（设置页顶部）给告警。这一点我们**应该改进**（见草案「模式切换」）。

---

# 设计草案：dsh-mobile「本机运行模式」

> 原则：**只基于上面查到的 rikkahub 事实来设计**，不凭空造概念。凡是我们**不照抄**的地方（尤其是明文存 Key），明确写出来。
> 范围：只写**数据模型 + 界面清单**，不写代码实现。

## A. 模式切换

### A1. 首启动（一次选择，可改）

rikkahub 的问题是没有首启动选择（`RouteActivity.kt:256` 直接落聊天页，配置不足只靠设置页告警卡 `SettingPage.kt:142`）。我们**必须加一个首启动页**，因为两个模式的**能力边界完全不同**（一个要配对电脑，一个要你自己有 Key）。

首启动流程（两屏）：

1. **模式选择页**（新页，无 rikkahub 对应物）
   - 选项 A：「连接电脑上的 DSH」→ 走已有的配对流程（二维码/配对码），保留 `docs/design-and-tech-plan.md` 定下的通道原则。
   - 选项 B：「本机运行」→ 直接进「加服务商」流程（参考 `SettingProviderPage.kt:94` 的列表 + 新建表单 `ProviderConfigure.kt`）。
   - 选项 C（**建议**）：「先看看」→ 进入只读的会话列表，顶部一条常驻提示条，与 rikkahub 的 `ProviderConfigWarningCard`（`SettingPage.kt:380-417`）同构但**更靠前、更显眼**。
2. **本机模式首次配置页**（若选 B）：服务商 → API Key → 「获取可用模型」→ 勾选 → 完成。抄 rikkahub 的两步：配置表单（`ProviderConfigure.kt:219-251`）+ 模型勾选 sheet（`SettingProviderDetailPage.kt:832`）。

**关键差异**：rikkahub 是「配置藏在设置里，不配就发不出去」；我们是「首启动就问清楚」，因为「连电脑」和「本机跑」对用户来说是两个产品。

### A2. 之后在哪切

- 设置页顶部一个模式切换项（当前模式 + 「切换」按钮）。
- **切换不清数据**（见 E 节），但要在切换时给一句明确说明：本机模式的会话不会同步到电脑；连电脑模式的密钥不在手机上。
- 会话列表加一个模式标记（分组或 badge），避免用户混淆自己正在跟谁说话。

## B. 配置数据模型

### B1. Provider（服务商）

对齐 `ProviderSetting`（`ProviderSetting.kt:26-249`），但**加一条 rikkahub 没有的能力**：provider 级自定义 header（rikkahub 只能挂 model/assistant，`ProviderSetting` 抽象里没有，见 §2.2）。

| 字段 | 类型 | 是否加密 | 示例值 | rikkahub 对应 |
| --- | --- | --- | --- | --- |
| `id` | UUID | 否 | `a1b2…` | `ProviderSetting.id:27` |
| `displayName` | string | 否 | `DeepSeek` | `name:29` |
| `protocol` | enum | 否 | `openai_chat` / `openai_responses` / `anthropic` / `gemini` | 对应 `Types`（`ProviderSetting.kt:243-248`）+ `useResponseApi:66` |
| `baseUrl` | string | 否 | `https://api.deepseek.com/v1` | `baseUrl:64` |
| `chatCompletionsPath` | string | 否 | `/chat/completions` | `:65` |
| `responsesPath` | string | 否 | `/responses` | `:68` |
| **`apiKey`** | string | **是（Keystore）** | `sk-…` | `apiKey:63`（**rikkahub 明文，我们不抄**） |
| `apiKeyRef` | string | 否 | `provkey_<uuid>` | 新增：密钥库里条目的别名，DB 只存引用 |
| `customHeaders` | list | 否（值里的密钥走 ref） | `[{"X-Title":"dsh-mobile"}]` | 新增（rikkahub 仅 model/assistant 级） |
| `enabled` | bool | 否 | `true` | `enabled:28` |
| `builtIn` | bool | 否 | `false` | `builtIn:33` |
| `promptCaching` / `promptCacheTtl` | bool / enum | 否 | `true` / `1h` | Claude 专有：`:193-194` |
| `proxyRef` | string? | 否 | `proxy_default` | rikkahub 代理是全局的（`ProxyConfig.kt:41-60`），我们按 provider 可选覆盖 |

### B2. Model（模型）

对齐 `Model`（`Model.kt:7-20`），**但补齐 rikkahub 缺失的用户可编辑上下文窗口**（rikkahub 的 `MODEL_CONTEXT_LENGTH` 只在识别表里、UI 不可编辑、也不参与请求，见 §3.1）。

| 字段 | 类型 | 是否加密 | 示例值 | rikkahub 对应 |
| --- | --- | --- | --- | --- |
| `id` | UUID | 否 | `m-…` | `Model.id:11` |
| `providerId` | UUID | 否 | `a1b2…` | 隐含在 `ProviderSetting.models` 里 |
| `modelId` | string | 否 | `deepseek-chat` | `:9` |
| `displayName` | string | 否 | `DeepSeek Chat` | `:10` |
| `type` | enum | 否 | `chat` / `image` / `embedding` | `ModelType:22-27` |
| `inputModalities` | list | 否 | `["text","image"]` | `:15` |
| `outputModalities` | list | 否 | `["text"]` | `:16` |
| `abilities` | list | 否 | `["tool","reasoning"]` | `:17`（决定思考滑杆与工具是否可用） |
| `builtInTools` | list | 否 | `["search"]` | `:18` + `BuiltInTools:41-57` |
| **`contextWindow`** | int? | 否 | `131072` | 新增（rikkahub 有值但不可编辑不生效） |
| **`maxOutputTokens`** | int? | 否 | `8192` | 新增（rikkahub 只有助手级 `maxTokens:37`） |
| `customHeaders` / `customBodies` | list | 否 | — | `:13-14` |
| `providerOverride` | object? | 否 | — | `:19`（单模型覆盖 provider） |
| `source` | enum | 否 | `fetched` / `manual` | rikkahub 两者都有：`:390-400`（拉取）/ `:733`（手填） |

### B3. Assistant（助手）

对齐 `Assistant`（`Assistant.kt:15-54`），**第一版裁剪**：去掉 workspace / 背景图 / regex 后期处理 / lorebook（见 G 节「明确不做」）。

| 字段 | 类型 | 是否加密 | 示例值 | rikkahub 对应 |
| --- | --- | --- | --- | --- |
| `id` | UUID | 否 | `as-…` | `:17` |
| `name` | string | 否 | `默认助手` | `:19` |
| `avatar` | enum/ref | 否 | `dummy` | `:20` |
| `modelId` | UUID? | 否 | `m-…`（null = 用全局默认） | `chatModelId:18` |
| `systemPrompt` | string | 否 | `你是…` | `:23` |
| `temperature` | float? | 否 | `0.7` | `:24` |
| `topP` | float? | 否 | `0.95` | `:25` |
| `maxTokens` | int? | 否 | `4096` | `:37` |
| **`reasoningLevel`** | enum | 否 | `auto` | `:36` + `ReasoningLevel`（`Reasoning.kt:7-43`） |
| `contextMessageLimit` | int | 否 | `0` | `:26-27` |
| `streamOutput` | bool | 否 | `true` | `:28` |
| `enableMemory` | bool | 否 | `false` | `:29` |
| `mcpServerIds` | list | 否 | `[]` | `mcpServers:40` |
| `localTools` | list | 否 | `["time_info"]` | `:41` |
| `enableWebSearch` | bool | 否 | `false` | `:42` |
| `quickMessageIds` | list | 否 | `[]` | `:34` |
| `presetMessages` | list | 否 | `[]` | `:33` |
| `messageTemplate` | string | 否 | `"{{ message }}"` | `:32` |
| `modeInjectionIds` | list | 否 | `[]` | `:47` |
| `customHeaders` / `customBodies` | list | 否 | `[]` | `:38-39` |
| `tags` | list | 否 | `[]` | `:22` |

**第一版明确不要的字段**（ri 有我们不做）：`workspaceId:43`、`background`/`backgroundOpacity`/`useGradientBackground:44-46`、`regexes:35`、`lorebookIds:48`、`enabledSkills:49`、`enableTimeReminder`/`timeReminderIntervalMinutes:50-51`、`enableRecentChatsReference:31`、`allowConversationSystemPrompt`/`allowConversationPromptInjection:52-53`、`useAssistantAvatar:21`、`useGlobalMemory:30`。

### B4. 存储分工（对齐 rikkahub 的分层）

| 数据 | 存哪 | 理由（rikkahub 已验证可行） |
| --- | --- | --- |
| Provider / Model / Assistant / McpServer / 搜索配置 | **DataStore(Preferences) 单 JSON blob**，或我们已有的等价配置层 | `PreferencesStore.kt:193-252`（字段独立 JSON 串） |
| **API Key** | **平台密钥库**，DB 只存 `apiKeyRef` | rikkahub 明文（`ProviderSetting.kt:63`），我们改掉 |
| 会话 / 消息节点 / 文件元数据 / 记忆 | **Room**（对齐 `AppDatabase.kt:30-40` 的实体划分） | 已验证：会话与配置分家 |
| 消息全文检索 | Room + **FTS5** 虚拟表 | `AppDatabaseFactory.kt:38`、`MessageFtsManager.kt:64-93` |
| 附件文件 | App 私有目录 `files/upload/` | `FilesManager.kt:107,513-518` |

## C. 密钥安全

### C1. 三平台正确做法

| 平台 | 机制 | 存什么 |
| --- | --- | --- |
| Android | **Android Keystore**（生成不可导出的 AES 密钥）+ EncryptedSharedPreferences / 自管加密的 DataStore | `apiKeyRef` → 密文 |
| iOS | **Keychain**（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，禁 iCloud 同步） | 同上 |
| 鸿蒙 | **密钥库（HUKS）** | 同上 |

要点：
- 密钥**只存在于设备安全硬件/密钥库**，不出现在普通 plist / SharedPreferences / 明文 JSON。
- 配置层只持 `apiKeyRef`（别名），UI 回显时用掩码（`sk-••••1234`），**不回显明文**。
- 备份**默认不含密钥**。若用户显式勾选「备份包含密钥」，则必须用用户口令派生密钥加密（对齐 rikkahub 的**反面教材**：`BackupManager.kt:44-46` 把含 Key 的 `settings.json` 明文打进 ZIP）。

### C2. 与本项目已定原则的差异（重要）

`docs/design-and-tech-plan.md` §7.5 已定：

> 「**API 密钥不回传手机**：手机能加/改/删提供商与密钥，但**密钥值不下发手机**；改密钥只发新值（经中转端到端加密）。手机不需要看到密钥本身。」（`docs/design-and-tech-plan.md §7.5`）

本机模式与它的关系：

| | 连接电脑模式 | 本机模式 |
| --- | --- | --- |
| 密钥归属 | **电脑上的 DSH**（手机只发新值） | **手机自己**（手机是唯一持有者） |
| 手机是否落盘密钥 | **否**（原则见 `design-and-tech-plan.md §7.5`；`design-and-tech-plan.md §2 安全底线` 亦要求长期凭据进 Keychain/Keystore/鸿蒙密钥库） | **是，但必须进平台密钥库** |
| 中转/端到端加密 | 需要（`design-and-tech-plan.md §2 安全底线`） | **不需要**（没有中转，直连 provider） |
| 风险面 | 通道被攻破 | 设备被攻破 / 恶意 App 读取 / 备份泄露 |
| 撤销方式 | 电脑端吊销设备 | 用户在 provider 后台吊销 Key |

**不能混淆的一点**：不能因为「本机模式要存 Key」就放松「连接电脑模式不存 Key」。两个模式在**同一台手机上共存**时，Keychain 里只应有本机模式的 Key，**绝不能出现 DSH 的凭据**。UI 上也要让用户看得出这个区别（例如钥匙图标 + 「仅存于本机安全存储」的说明文案）。

## D. 界面清单（本机模式）

| # | 页面 | 必须包含 | rikkahub 参考 | 复用/分叉 |
| --- | --- | --- | --- | --- |
| 1 | **模式选择（首启动）** | 两个模式的卡片 + 各一句边界说明；「本机运行」进入 #2 | **无对应物**（rikkahub 无引导，`RouteActivity.kt:256`） | 新增，仅本机/连接共用一次 |
| 2 | **服务商列表** | 列表 + 搜索 + 拖拽排序 + 新建/删除 | `SettingProviderPage.kt:94`（重排 `:101-106`） | 分叉（连接模式下是只读/不可见，见 E） |
| 3 | **服务商编辑** | 名称 / 协议 / baseUrl / path / **API Key（写入即入密钥库）** / 自定义 header / 代理 / 连通性测试 / 余额 | `SettingProviderDetailPage.kt:259` + `ProviderConfigure.kt:219-251` + `ProviderConnectionTester.kt`（余额 `BalanceOption.kt`） | 分叉 |
| 4 | **模型管理** | 「获取可用模型」勾选（自动拉 `/models`）+ 手填 + 能力勾选（工具/思考）+ 上下文窗口/最大输出 | `SettingProviderDetailPage.kt:374-485`（拉取 `:390-400`）、`ModelPicker:832`、`AddModelButton:669`、`ModelSettingsForm:488`、`ModalAbilitySelector:1114` | 分叉 |
| 5 | **助手列表 / 助手设置** | 名称、头像、模型绑定、系统提示词、温度/topP/maxTokens、**思考档位**、MCP 绑定、本地工具、快捷消息、预设消息 | `AssistantPage.kt:81`、`AssistantDetailPage.kt:93-145`、`AssistantBasicPage.kt:480-482`（思考档位）、`AssistantMcpPage.kt`、`AssistantLocalToolPage.kt` | **可共用**（助手概念两模式都需要） |
| 6 | **参数面板（聊天内）** | 模型切换、**思考档位滑杆**、联网搜索开关、附件入口 | `ReasoningPicker.kt:88-199`（7 档滑杆）、`ModelList.kt`/`ChatInput.kt:309`、`SearchPicker.kt`、`ChatAttachmentPicker.kt` | **可共用**（但需按模式决定可见性，见 E） |
| 7 | **附件预览/删除** | 输入区 chips、缩略图、删除、文档解析状态 | `AttachmentChips.kt:47-144` | **可共用** |
| 8 | **MCP 服务器管理 + 助手绑定** | 名称/传输(SSE/Streamable HTTP)/URL/自定义 header/工具列表/需审批开关 | `SettingMcpPage.kt:117-1025`（传输 `:616-643`） | **可共用**（连接模式下 MCP 在电脑侧，这里应隐藏） |
| 9 | **快捷消息管理** | 标题 + 内容 CRUD，助手多选绑定 | `QuickMessagesPage.kt:52`、`ExtensionContent.kt:154-185` | **可共用** |
| 10 | **提示词注入 / Lorebook** | 位置、内容、优先级、关键词/正则、深度 | `AssistantPromptPage.kt`、`AssistantExtensionsPage.kt`（结构 `Assistant.kt:152-211`） | 第一版本机模式**可缓做**，见 G |
| 11 | **搜索服务配置** | 引擎选择 + 各引擎 Key + 通用选项 | `SettingSearchPage.kt` / `SettingSearchDetailPage.kt`（枚举 `SearchService.kt:143-320`） | 分叉（连接模式下搜索在电脑侧） |
| 12 | **TTS / ASR 配置** | provider 选择、音色、语速 | `SettingSpeechPage.kt`、`TTSProviderConfigure.kt`、`ASRProviderConfigure.kt` | **可共用** |
| 13 | **备份 / 导入导出** | 本机备份（**默认不含密钥**）、单助手/单注入导出 JSON、导入 | `ui/pages/backup/BackupPage.kt`、`ExportHooks.kt:25-160`、`ExportSerializer.kt:19-32` | 分叉（连接模式的备份对象是电脑端） |
| 14 | **模式切换入口** | 设置页顶部：当前模式 + 切换 + 说明 | 参考告警卡位置 `SettingPage.kt:142-146` | 新增 |

**显式不做参考的页面**：`ui/pages/extensions/workspace/`、`Screen.WorkspaceTerminal`（`RouteActivity.kt:511`）——proot shell 不在本机模式范围。

## E. 与「连接电脑」模式的关系

### E1. 可共用的页面（助手/会话语义与后端无关）

| 页面 | 为什么能共用 |
| --- | --- |
| 会话列表 / 会话详情（聊天） | 两模式都是「一问一答 + 工具调用」，DSH 的轨迹/diff 渲染是加法（见 `design-and-tech-plan.md §7.3/§7.6`） |
| 助手列表 / 助手设置 / 助手详情 | `Assistant` 的模型绑定、系统提示词、思考档位、本地工具在两模式语义一致（`Assistant.kt:15-54`） |
| 参数面板（思考滑杆、模型切换） | `ReasoningLevel` 是**客户端**概念，本机模式直接翻译给 provider；连接模式下可作为「发给 DSH 的意图」。需注意连接模式下最终由 DSH 决定（见 `design-and-tech-plan.md` §7.5「模型与密钥」） |
| 附件选择 / 预览 | 纯本地 UI（`ChatAttachmentPicker.kt`） |
| 快捷消息 | 纯本地数据（`QuickMessagesPage.kt`） |
| TTS / ASR | 纯本地（`speech/` 模块） |
| 聊天记录搜索 | 本地 FTS（`MessageFtsManager.kt`） |

### E2. 必须分叉的页面

| 页面 | 连接电脑模式 | 本机模式 |
| --- | --- | --- |
| **服务商 / 密钥** | 显示电脑端的 provider，**密钥值不下发手机**（`design-and-tech-plan.md §7.5`）；只读 + 改密钥只发新值 | **完全本地**：手机持有 Key、写入平台密钥库 |
| **模型管理** | 目录来自电脑端 DSH | 本地「获取可用模型」+ 手填（`SettingProviderDetailPage.kt:390-400`） |
| **MCP / 工具执行地** | 工具在电脑上执行 | 工具必须在手机上执行（仅 HTTP/SSE MCP，`McpConfig.kt:63-95`）+ 本地工具（`LocalToolOption.kt:7-38`） |
| **搜索 / TTS / ASR 凭据** | 电脑侧有 Key，手机不需要 | 手机自己配 Key |
| **备份 / 数据边界** | 备份对象是电脑端 | 备份本机数据，**默认不含密钥** |

### E3. 会话数据是否混在一起

**建议：同一张表，字段区分，UI 分组展示。** 理由与做法：

1. 会话结构天然包含 `assistantId`（`Conversation.kt:18`），我们再加一个 `mode` 字段（`remote` / `local`）即可。
2. 不用两张表，因为「会话列表 / 搜索 / 收藏 / 文件夹」的查询逻辑完全共用（rikkahub 的 `ConversationDAO.kt:15-46` + FTS `:64-93` 都是单表假设）。
3. UI 上**必须可见**：会话列表按模式分组（或加 badge），否则用户会搞不清「这条会话刚才是电脑跑的还是手机跑的」。
4. **助手不共享**：`assistantId` 指向的助手需要带模式归属（本机助手不能绑定电脑端的远端模型目录）。做法：助手表加 `mode` 字段，或在会话创建时按模式过滤可选助手。
5. **MCP / 搜索 / provider 配置不共享**：两套独立配置（同一 DataStore 不同 key）。

## F. 明确不做（第一版）

为防范围失控，以下**明确不做**：

1. **不做端侧本地推理**（不内置 LLM、不做 GGUF/llama.cpp）。rikkahub 也没有（§9「未找到」）；本机模式的定位是「手机直连云端 provider」。
2. **不做 workspace / proot shell**（不搬 `WorkspaceTools.kt`、`Screen.WorkspaceTerminal`）。这是 rikkahub 的重资产，且与「手机不能跑重任务」的现实冲突。
3. **不做 stdio MCP**（rikkahub 也没有，`McpConfig.kt:63-95` 只有 SSE/Streamable HTTP）。
4. **不做 Skills**（不搬 `data/files/SkillManager.kt` + `enabledSkills`）。
5. **不做助手 regex 后处理 / 背景图 / 渐变背景 / 时间提醒注入**（`Assistant.kt:35,44-46,50-51`）。
6. **不做 Lorebook / SillyTavern 世界书导入**（`Assistant.kt:204-211`、`ExportSerializer.kt:145-204`）。
7. **不做「获取余额」**（`BalanceOption`、`BalanceOption.kt`）——非核心，且各家接口不稳定。
8. **不做内置 Web 服务器 / 分享链接 / 从别的 App 导入 provider**（`service/WebServerService.kt`、`CherryStudioProviderImporter.kt`、`ChatboxImporter.kt`）。
9. **不做图片生成 / 视频生成 / 嵌入模型**（`ModelType.IMAGE/EMBEDDING`、`videogen/` 模块）。第一版只做 `chat`。
10. **不做多模态输入的完整支持**：第一版图片可发（base64，抄 `FileEncoder.kt:52-81`），视频/音频不发（虽然 rikkahub 支持，`ChatAttachmentPicker.kt:141-155`）。
11. **不做云同步备份**（不搬 WebDAV/S3，`data/sync/webdav/`、`data/sync/s3/`）；第一版只做本地 ZIP 导出/导入。
12. **不做按 host 硬编码的 provider 特化矩阵**（不抄 `ChatCompletionsAPI.kt:273-416` 那 14 个分支）——第一版只实现**通用 `reasoning_effort` 兜底** + 我们确定要支持的少数几家（见 H 风险 1）。

## G. 风险与开放问题

1. **思考档位在各家的语义不等价（最大风险）**
   rikkahub 用一个 7 档枚举硬映射到 14 个 host 分支（`ChatCompletionsAPI.kt:273-416`），且：
   - `api.mistral.ai` 明确不支持（`:300-302`）；
   - siliconflow 限定硬编码模型清单（`:313-339`）；
   - Gemini 上 OFF 档对 Pro 与 Flash 行为不同（`GoogleProvider.kt:365-372`）；
   - Claude 上 AUTO 与 HIGH 都发 `adaptive`，只差 `output_config.effort`（`ClaudeProvider.kt:484-499`）；
   - Gemini 3 用 `thinkingLevel`（字符串），其它 Gemini 用 `thinkingBudget`（token 数），**同一档位对应两种完全不同的量纲**（`GoogleProvider.kt:374-384`）。
   **开放问题**：我们第一版要不要照抄这张矩阵？建议**只做兜底 + 3 家白名单**（DeepSeek、Anthropic、Gemini），其余走 `reasoning_effort`；并在 UI 上标注「该服务商对档位的翻译可能与预期不同」。
2. **UI 是否要暴露「自动」档**
   rikkahub 的 `AUTO` 是个特殊档（各 provider 分支里都有 `if (level != AUTO)` 的特判）。它语义模糊（「不设置参数」而非「让模型自己定」）。**开放问题**：我们要不要干脆去掉 AUTO，只留 6 档？去掉会让「不想管」的用户被迫做选择。
3. **「获取可用模型」不一定可靠**
   rikkahub 是进页面就自动拉 `/models`（`SettingProviderDetailPage.kt:390-400`），失败只打日志。不是所有兼容端点都实现 `/models`。**必须保留手填路径**（`AddModelButton:669`）。
4. **文档解析的能力上限（且 rikkahub 有个已知缺口）**
   rikkahub 只做 4 类本地解析（pdf/docx/pptx/epub）+ 其它 `readText()`（`DocumentAsPromptTransformer.kt:77-83`）。**但它的 picker 允许 xls/xlsx**（`ChatUtil.kt:40-41`），于是表格会被当纯文本读进 prompt——见 §5.2 的说明。扫描版 PDF 也需要额外 OCR 通道（`OcrTransformer.kt:56-99` 走的是「另一个模型」）。**开放问题**：第一版是否补 xlsx（真解析）？是否要做 OCR？至少不要重复「允许但解析不了」这个坑。
5. **与 DSH 体验不一致之处（用户可感知）**
   - 工具集不同：本机模式只有 HTTP MCP + 8 个本地工具（`LocalToolOption.kt:7-38`）；DSH 有插件/子代理/文件系统/命令执行。
   - 无 diff / 无交付物、无轨迹、无权限模式（`design-and-tech-plan.md §7.6/§7.7` 的富内容是 DSH 侧产出的）。
   - 无「电脑上跑代码」能力，长任务体验差距明显。
   - **建议**：在本机模式会话顶部常驻一句能力说明，避免用户以为「手机也能像电脑一样干活」。
6. **附件体积与超时**
   rikkahub 图片压缩到 16M 像素、JPEG q85（`FileEncoder.kt:117-159`），**未找到**附件数量/体积上限（§5.6）。多张图 base64 内联会显著放大请求体。**开放问题**：我们需要自己定数量与体积上限。
7. **两模式共存时的数据边界**
   会话表带 `mode` 字段后，跨模式迁移会话（把本机会话「升格」到 DSH 跑）是有需求但很危险的：助手绑定、工具集、上下文都会不一致。**建议第一版禁止跨模式迁移**。
8. **连接电脑模式的密钥原则不能因为本机模式而放松**
   一旦我们在同一份配置层里既存「本机 Key（密钥库）」又想放「DSH 凭据」，很容易顺手把 DSH 凭据也存下来。**必须显式隔离**（见 C2 表格）。
9. **`providerOverwrite` 与 `customBodies` 的爆炸半径**
   rikkahub 允许任意的 `CustomBody(key, value: JsonElement)`（`Provider.kt:124-128`）直接塞进请求体，能覆盖任何字段。这是灵活性也是事故源（比如覆盖 `messages`）。**开放问题**：我们是开放任意 JSON，还是只开放白名单 key？

## H. 落地顺序建议（最小可用）

1. **配置层 + 密钥库**：Provider/Model/Assistant 三张数据结构（B1-B3）+ Keychain/Keystore/HUKS 接入 + `apiKeyRef` 间接层。
2. **首启动模式选择** + 设置页模式切换（A1/A2）。
3. **服务商/模型管理页**（D2/D3/D4，抄 `SettingProviderDetailPage.kt` 的两 tab 结构）。
4. **聊天主链路**：模型解析（`assistant.modelId ?: global`，对齐 `PreferencesStore.kt:736-737`）+ 流式 + 未配置时的拦截提示（对齐 `ChatPage.kt:385-389`，但**提前到首启动**）。
5. **思考档位**：`ReasoningLevel` 7 档 + 滑杆 UI（`ReasoningPicker.kt:88-199` 同构）+ 三家 provider 翻译 + 兜底 `reasoning_effort`。
6. **附件**：图片（base64 + 压缩）、文档（pdf/docx/txt 本地抽文本 + `<UploadFile>` 注入，抄 `DocumentAsPromptTransformer.kt:24-38`）。
7. **MCP（Streamable HTTP / SSE）+ 本地工具（先做 time_info / clipboard / tts）**。
8. **助手设置 + 快捷消息 + 会话搜索（FTS）**。
9. **本地备份导出（不含密钥）**。

---

## 附：证据索引（按调研项）

| 调研项 | 主证据 |
| --- | --- |
| 1 配置存储 | `data/datastore/PreferencesStore.kt:66,75-100,193-252,561-617`；`data/db/AppDatabase.kt:30-63`；`data/sync/s3/AwsSignatureV4.kt:8-9`（唯一 crypto） |
| 2 服务商接入 | `ai/.../provider/ProviderSetting.kt:26-249`；`data/datastore/DefaultProviders.kt:17-291`；`ui/pages/setting/SettingProviderDetailPage.kt:259-372`；`components/ProviderConfigure.kt:219-251`；`di/DataSourceModule.kt:116-142` |
| 3 模型管理 | `ai/.../provider/Model.kt:7-57`；`ai/.../registry/ModelRegistry.kt:10,708-780`；`ui/.../SettingProviderDetailPage.kt:374-485,488-660,669-753,832-1005,1114`；`data/ai/GenerationLoop.kt:386-402` |
| 4 思考程度 | `ai/.../core/Reasoning.kt:7-43`；`data/model/Assistant.kt:36`；`ui/components/ai/ReasoningPicker.kt:46-223`；`ui/components/ai/ChatInput.kt:340-349`；`providers/openai/ChatCompletionsAPI.kt:271-416`；`providers/claude/ClaudeProvider.kt:478-501`；`providers/google/GoogleProvider.kt:355-387`；`providers/openai/ResponseAPI.kt:239-253` |
| 5 文件上传 | `ui/components/ai/ChatAttachmentPicker.kt:33-195`；`utils/ChatUtil.kt:34-63`；`data/ai/transformers/DocumentAsPromptTransformer.kt:15-88`；`document/src/main/java/me/rerere/document/*.kt`；`ai/.../util/FileEncoder.kt:52-159`；`ui/components/ai/AttachmentChips.kt:47-190`；`data/files/FilesManager.kt:105-140,513-518` |
| 6 MCP / 工具 | `data/ai/mcp/McpConfig.kt:9-102`；`ui/pages/setting/SettingMcpPage.kt:117-1025`；`data/ai/tools/ChatToolFactory.kt:21-108`；`data/ai/tools/local/LocalToolOption.kt:7-38` |
| 7 助手 / 会话 | `data/model/Assistant.kt:15-211`；`data/model/Conversation.kt:16-36`；`PreferencesStore.kt:736-749`；`ui/pages/assistant/detail/AssistantDetailPage.kt:93-145` |
| 8 本地能力 | `data/db/fts/MessageFtsManager.kt:35-93`；`data/db/AppDatabaseFactory.kt:38`；`data/sync/BackupManager.kt:37-168`；`data/export/ExportSerializer.kt:19-32`；`speech/.../TTSProviderSetting.kt`、`speech/.../asr/ASRProviderSetting.kt`；`search/.../SearchService.kt:143-320`；`ui/pages/extensions/QuickMessagesPage.kt:52` |
| 9 首启动 | `RouteActivity.kt:256-267`；`RikkaHubApp.kt:55-109`；`PreferencesStore.kt:717`；`ui/pages/setting/SettingPage.kt:142-146,380-417`；`ui/pages/chat/ChatPage.kt:385-389` |
| 本项目已有原则 | `docs/design-and-tech-plan.md §2 安全底线、§7.5`（§7.5，密钥不回传手机在 `:313`） |
