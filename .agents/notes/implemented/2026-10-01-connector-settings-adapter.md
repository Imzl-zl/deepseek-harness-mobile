# Agent Note: 设置与凭据只暴露安全路径，DSH 的三个危险默认值由适配层挡掉

Status: implemented

## Problem

契约 §7.5 有两条硬规则：**密钥值不回传手机**、**改密钥只发新值**。落到 DSH 时发现
**三个默认行为全都站在危险一侧**，而且都不会报错：

1. **裸 `settings.describe()` 会把 `role('secret')` 字段的明文放进 `value` / `base` / `user`。**
   实现是三元表达式：`value: options?.redactSecrets ? redacted.value : value`
   （`packages/settings/settings/src/index.ts:327-330`）。测试级证据最硬：
   `tests/configuration.spec.ts:254-255` —— 裸调 `describe()` 拿到 `{ token: 'private' }`，
   传 `{ redactSecrets: true }` 后 `JSON.stringify` 里不含 `private`。
   **忘记传参没有任何警告**，表现是一切正常，只是密钥悄悄过了线。
2. **`settings.replace(ns, 从 redacted 文档重建的 section)` 会静默删掉**客户端从没收到过的
   每一个密钥。`settings/src/index.ts:73-80` 明写了这一点：*"a wholesale `replace` rebuilt
   from a redacted document silently deletes every secret the wire never returned"*。
   而「手机改了设置 → 把整份文档写回去」恰好是最自然的实现方式。
3. **DSH 没有「凭据只写不读」模式。** `credentials.resolve` / `readRecord` / `modifyRecord`
   全部返回明文（`packages/credentials/credentials/src/index.ts:183` / `:217` / `:247`），
   `modifyRecord` 的回调直接拿到当前记录。单向性**只存在于 Remote 那一层**
   （`packages/api/settings-controller/src/credentials.ts:64-65` 的类注释
   "Secret values cross in one direction only"），Host 插件有完整读权。

也就是说：三条规则全部依赖「写代码的人记得」——而这三处的默认行为都是不安全的那一侧。

## Decision

`createSettingsPort()` 是设置与凭据进入本插件的**唯一入口**，它只暴露五个方法，
且**端口上不存在一个「要不过滤」的读**：

| 暴露 | 说明 |
|---|---|
| `snapshot(ns)` | 内部固定传 `{ redactSecrets: true }`；返回值里密钥只有 `{ path, set }` |
| `setField(ns, path, value, expectedRevision?)` | 走 `mutate`，**不提供 `replace`** |
| `setSecret(ref, value)` / `unsetSecret(ref)` | 凭据写面 |
| `secretStatus(ref)` | 只回答 `{ configured, writable }` |

**绝不暴露** `credentials.resolve` / `readRecord` / `modifyRecord` —— 它们不出现在任何能到手机的
调用路径上。

准入门槛（可机械判定）：

1. **读设置只有 `snapshot` 一条路**，且它内部硬编码 `redactSecrets: true`；端口类型上
   没有任何参数或重载能关掉过滤。改这一行即等于改安全边界，review 时一眼可见。
2. **写设置只走 `mutate`**。`replace` 不出现在端口上，也不出现在 `src/` 任何地方。
3. **凭据只有 `set` / `unset` / `describe`**；明文返回值的那三个方法不进 `src/`。
4. `config.ts` 里凡涉及密钥的字段必须用 `role('credential-ref')`，**不得**用 `role('secret')`
   承接明文（后者会把明文落进 profile 的 cordis patch 文档）。
5. 服务缺失时**显式抛 `ServiceUnavailableError`**，不静默降级成「什么都不做」。
6. 依赖 DSH 的**类型**来钉住 `redactSecrets` 这个选项名：`describe({ redactSecrets: true })`
   要被编译器按 DSH 的真实签名检查。选项改名时构建失败，而不是静默泄漏。

## Alternatives considered

1. 按约定要求调用方自己记得传 `{ redactSecrets: true }`
   - 最强的理由：不增加抽象，端口就是 DSH 的 `describe` 原样透传；调用方最灵活，
     需要原始值时也拿得到（比如将来做本机模式的密钥回显）。
   - 为何被否：「记得传参」是这个仓库里已经被证明会失效的一类约束——`tools.md` 里那条
     「边界校验自检 10 条 / 实际 13 条」就是同一类问题的前科。而这里的失败代价不是文档数字
     不准，是**用户密钥明文进了手机**。把安全路径做成唯一路径，成本只是少一个参数，
     收益是这类 bug 在类型层面不可能写出来。
2. 写设置用 `replace`（把手机改完的整份文档写回去）
   - 最强的理由：语义最直观——「手机上的这份就是电脑上的那份」，天然处理删除字段的场景；
     而且手机上本来就要渲染一份完整文档，回写整份最省映射代码。
   - 为何被否：`settings/src/index.ts:73-80` 明写会**静默删掉**所有客户端没收到过的密钥。
     而客户端收到的永远是 redacted 文档（这是第 1 条决定的前提），所以「用 redacted 文档
     replace」必然删密钥——不是可能，是必然。删完没有任何报错，用户下次用才发现密钥没了。
     `mutate` 的逐字段 `set` / `unset` 语义正好对应「只发新值」。
3. 给设置/凭据写**结构化类型**，不引入 `@deepseek-ai/dsh-settings` / `dsh-credentials` 依赖
   - 最强的理由：保持 DSH 依赖集小（当时是 6 个 dev + 3 个 peer），也避免每次 DSH 发 rc
     多同步两处版本号。
   - 为何被否：这一层唯一的**安全机制**就是那个选项名。结构化类型意味着 `redactSecrets`
     这个名字由我们自己写死——DSH 哪天改名，我们编译照过、类型照对，而运行时它被当成
     未知选项忽略，密钥明文直接过线。**这里多一个依赖买到的是"选项改名会构建失败"**，
     这是整份设计里性价比最高的一处依赖。
4. 靠 DSH 的 `credentialsController`（Remote 层）提供单向性
   - 最强的理由：那层的类注释明写 "Secret values cross in one direction only — no method
     here returns one"，是 DSH 官方保证过的单向面；接它等于把安全责任交给上游。
   - 为何被否：那一层是给**跨进程的浏览器客户端**用的，它的单向性是**在那个进程边界上**
     成立。我们的插件与 DSH 同进程，拿到的是 `ctx.credentials` 本体 —— 完整的明文读权。
     用 Remote 层意味着为了一个语义绕一大圈通信，而绕过之后读权依然在。单向性只能由
     我们自己的通路保证。

## Consequences

- 收益：三条硬规则各有一个**结构性**保障，而不是三条写在文档里的约定：读设置的过滤
  无法被关掉（端口上没有那个参数）、写设置不可能误删密钥（`replace` 不存在）、
  凭据明文读方法不进 `src/`；`redactSecrets` 选项名由编译器盯着，DSH 改名会构建失败；
  服务缺失是显式异常而不是静默 no-op。
- 代价：DSH 依赖从 6 个 dev 增到 10 个（多了 `dsh-settings` / `dsh-credentials` /
  `dsh-storage-domain` / `dsh-subagent`），每次 DSH 发 rc 要同步的版本号变多；
  端口比 DSH 原 API 窄，将来若真需要在电脑侧读密钥（比如本机模式做密钥迁移），
  必须**改这个文件**而不是绕过它——那是有意的摩擦；`snapshot()` 每次都要重新 describe
  一遍全量设置再 find，没有缓存，高频调用时是浪费（第一版接受，因为配置文件很小）。
