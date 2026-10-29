# Agent Note: 连接配置进面板，且"没有令牌"不再把插件锁在门外

Status: implemented

## Problem

「手机」面板原来只看得见状态、能开关两条通道、能管设备与出码，但**看不见也改不了"这台电脑怎么连中转"**：地址、公网明文那一档、直连端口、令牌，全都要手工改 `cordis.patch.yml` 或凭据文件，然后重启 DSH。操作者在面板上看到"未运行"，下一步只能去翻日志与配置文件。

更硬的一条是自锁：令牌记录缺失时，`start-transport` 读记录抛错 → 整个 mount 失败 → 管理面路由没挂上（挂载在令牌读取之后）→ **面板自己 404**。于是"删掉令牌"这个动作一旦做出来，重启后就再也没法在界面里把令牌贴回去。
（`connector/src/index.ts` 的 `validate-config` 只查 `relayTokenRef` 这个**字段**在不在；真正读记录在 `start-transport` 里。）

## Decision

面板顶部加一张「连接」卡（地址 / 公网明文开关 / 令牌 / 直连端口），写面复用 DSH 的两条既有立即生效路径：配置走 `settings.update`（落当前 profile 的 `cordis.patch.yml`），令牌走凭据 seam 的**记录面**（`modifyRecord` / `deleteRecord`）。同时把"凭据里没有连接器令牌"从**拒绝挂载**降级为**只让中转通道起不来**。

准入门槛（可机械判定）：

1. **卡片只碰三格**：`relayUrl` / `allowInsecurePublic` / `listenPort`。patch 里出现第四格（`windowFrames` 之类）就是违约 —— 由 `tests/admin-connection.test.ts` 的 patch 键断言钉住。
2. **地址校验在写入之前，且校验"保存之后的完整状态"**：勾选与地址同一次提交时，结果状态合法就放行，与字段顺序无关（同一用例组）。
3. **一次保存只有一次 `settings.update`**：三次 `mutate` 会让 revision 每次都 +1、第二次必 409 —— 由 `tests/settings-adapter.test.ts` 的 `setFields` 用例钉住（并断言 `mutate`/`replace` 零调用）。
4. **令牌值永不过线**：`GET /connection` 只回 `{configured, writable}`；界面上的令牌框恒为空 —— 由 `tests/client-panel.test.ts` 的 password 空值断言钉住。
5. **没有令牌不得让挂载失败**：`transportStart` 只放过两种缺席 —— `RelayTokenError`（缺令牌）与 `listenPort = 0`（配置明说"不监听"）；其它失败（坏地址、端口被占）照旧整体抛出。由隔离实例实测（面板删令牌 → 重启 DSH → 面板仍能打开 → 贴回令牌 → 中转恢复）。

## Alternatives considered

1. 让 DSH 按 `settings.describe` 的 schema 自动生成表单
   - 最强的理由：零 UI 代码，`autoGenerate` 就是为这件事留的元数据。
   - 为何被否：README 明说"目前没有已发布的客户端这样做"；实测 `describe` 会把该条目 12 个 volatile 字段全摆出来，而这张卡只该有 4 格。手写表单反而是 DSH 设置页的既有惯例。
2. 我们自己读写 `cordis.patch.yml`（自己解析 YAML）
   - 最强的理由：不依赖 `settings` 服务，任何部署都能用；写入格式完全可控。
   - 为何被否：会绕开 `configEditor` 的文件锁、原子写、失败回滚与"home patch / 命令行覆盖"检查（那几条都在 `packages/boot/config-editor/src/index.ts:87-146`），于是"面板写的"和"DSH 写的"变成两条写入路径。
3. 复用手机面的 `settings.describe` / `settings.update`（契约 §5.7 那两张 allowlist）
   - 最强的理由：那两层已经在了，且天然只暴露白名单。
   - 为何被否：白名单里没有本插件自己的 ns（它是给"手机改电脑设置"造的），而浏览器这一侧不是手机；扩白名单等于把手机面撑大。
4. 保存后重启 DSH 让配置生效
   - 最强的理由：最简单，且"重启后一定一致"。
   - 为何被否：loader 已经会在"只有 volatile 字段变了"时把值提交进运行中的引用并发 `loader/volatile-update`（`vendor/loader/src/config/entry.ts:146-150,184,191`），实测一次 `pushDigest` 写入恰好触发一条事件且 fiber 未重挂；重启是多余且打断使用的手段。
5. 令牌只做"替换"，不提供删除
   - 最强的理由：删除的恢复路径在服务器（要重签），干脆不给这个按钮。
   - 为何被否：用户要能把这台电脑的令牌撤下来；而"只做替换"在误配时没有出口。选择做删除，就必须同时做门槛 5，否则自锁。
6. 保存时逐字段 `mutate`（复用手机面的 `setField`）
   - 最强的理由：与手机面同一条写入路径，代码最少。
   - 为何被否：乐观锁比的是本轮读到的 revision，逐次 `mutate` 会让第二次写入带着过期 revision 直接 409。

## Consequences

- 收益：连接问题第一次能在界面里看全并改掉；删令牌后仍能进面板自救；改完地址后**出码、名册上报、端点自报**与拨号用的是同一个当前值（不再是四份快照）。
- 代价：
  - `Assembly` 从"挂载时快照"改成"用时读取"，`pairing-register.ts` / `device-publish.ts` / `endpoints.ts` 的入参跟着从值改成 getter；
  - `endpoint.describe` 变成**总是挂**（否则面板把 `listenPort` 从 0 改成 8790 后，手机拿不到新端点，"开直连"是假动作）；
  - `start-transport` 的失败语义多了一个例外（门槛 5），配置不全就拒绝挂载这条原则从此有了明文例外；
  - `settings.update` 会**整段重写**该条目的 `config:` 块：值全部保留（含 schema 之外的 `approvalTakeover`），但**块内注释会被丢掉**、键序被规范化（`approvalTakeover` 被挪到块首）。这是宿主的写入路径（`packages/boot/config-editor/src/index.ts:110` 的 `document.setIn` 换掉整个 config 节点，挂在该节点上的注释随之消失），不是本层能避免的；行外的注释保留；
  - 新路由 `GET/POST /api/dsh-mobile/connection` 与一条 `AdminDeps.connection` 依赖，所有构造 `AdminDeps` 的测试替身都要补一格；
  - `deviceLimit` 仍是空转字段（全仓只有 schema 提到它），这次没有顺手处理。
