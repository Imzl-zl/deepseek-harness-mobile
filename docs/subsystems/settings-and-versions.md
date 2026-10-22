# 电脑侧设置（`settings.describe` / `settings.update`）

手机能改**三行电脑侧设置**：新会话默认权限、新任务默认模式、上传 Session Log。
值是**电脑侧真值**（不是手机本地偏好 —— 后者见 `docs/subsystems/type-scale.md` 那一类）。

## 1. 方法面

| 方法 | 方向 | 幂等键 | 说明 |
|---|---|---|---|
| `settings.describe` | 手机→电脑 | **无**（读方法） | 请求 `{namespaces: string[]}`，回 `{sections: [{ns, revision, values, secrets:[{path,set}]}]}` |
| `settings.update` | 手机→电脑 | **有** | 请求 `{ns, path: string[], value, expectedRevision?}`，回 `{section}`（**改完**的快照）；过期回 `settings/conflict` |

两个方法的实现在连接器：
- `connector/src/dsh/settings.ts` —— 端口（**读已脱敏、写只发新值**，三条安全规则见文件头）；
- `connector/src/dsh/settings-face.ts` —— 手机这一层的**两张 allowlist**：
  - 可读 ns：`permission` / `agent-preset-registry` / `session-log-deepseek`（问别的**静默跳过**）；
  - 可写字段：`permission.defaultPreset`、`agent-preset-registry.selectedDefault`、
    `session-log-deepseek.enabled` —— 按 **(ns, path)** 逐条放行，越界回 `gateway/bad-request`。
    为什么不是"ns 可写"：`mutate` 能写密钥字段，而 `settings.update` 不是密钥的通道。

`settings` 服务不在时两个方法**都不挂**（`repo.info` 也就不报）—— 与 `job.*` 同一条能力位模型。

## 2. 手机侧

- `AppModel.refreshSettings()` 拉三个 ns（连上时一次）；`updateSetting(ns, path, value)`
  只发新值 + 上一次的 `revision`。冲突时**重读一次并返回 false**（不重试这次写 —— 值可能已被别人改）。
- 设置页三行：

| 行 | 写哪里 | 选项来源 | 拿不到时的样子 |
|---|---|---|---|
| 新会话默认权限 | `permission.defaultPreset` | `permission.catalog` 的 `defaultOptions` | 行在、**点不动**，值照原样显示 |
| 新任务默认模式 | `agent-preset-registry.selectedDefault` | `agentPresets.list` 的名册（`broken` 的已被解析层剔掉） | 同上 |
| 上传 Session Log | `session-log-deepseek.enabled` | — （开关） | 开关在、**禁用** |

## 3. 判据

- 连接器 `connector/tests/settings-face.test.ts`（8 条）：读面 allowlist、写面 (ns,path) allowlist、
  密钥位只有 `{path,set}`、冲突转 `settings/conflict`、越界转 `gateway/bad-request`、
  服务不在时不挂方法。
- 手机 `app/test/settings_sync_test.dart`（5 条）：值落表、只发新值 + 上一个 revision、
  冲突后重读且只发一次、设置页三行的值来自电脑侧、目录缺失时点不动。
- 真机（`d61cf622`，`shots-2026-10-22/`）：`d2-default-set.png`（新任务默认模式 = PTC 模式），
  以及连接器账本里这一条 `settings.update`：
  `{"ns":"agent-preset-registry","revision":1,"values":{"selectedDefault":"ptc"}}`；
  紧接着的 `session.create` 回 **`{"sid":"…","agentPreset":"ptc"}`** ——
  手机**没有**传 `agentPreset`，新会话拿到的就是电脑侧的新默认（`agent-preset-registry` 的
  `defaultId` = `selectedDefault ?? default`，`packages/preset/agent-preset-registry/src/index.ts:75,205,233`）。
  新会话的 hero 上那枚模式 chip 也随之显示「PTC 模式」（`d5-hero-ptc.png`，读的是 `agentPreset` 投影）。

## 4. 两个版本（排错必需）

设置页「关于与连接」并排显示**手机 App 版本**与**电脑侧 DSH 版本**。

- 电脑侧版本走 `repo.info.dshVersion`（连接器 `src/dsh/host-version.ts`），取法从最真到最兜底：
  1. 已加载宿主包的 `package.json`（`@deepseek-ai/dsh-desktop-host`）；
  2. 桌面版的 `<安装目录>/resources/runtime/primary-runtime/runtime.json` 的 `desktopVersion`
     （本机实测路径；发行版之间挪过目录，另一种布局也试）；
  3. 都拿不到 ⇒ **不报这个字段**，手机显示"未读到"。**不拿连接器自己的 `package.json` 版本冒充**
     —— 那是构建期常量，用户升级 DSH 后它不会变。
- 真机（`d61cf622`）：`e2-versions.png` —— App 版本 `dev`、电脑侧 DSH 版本 `0.2.1-rc.2`。
