# Agent Note: 存储 schema 收敛到一处，按写入特征拆两个域

Status: implemented

## Problem

实现 `store/` 时对着设计文档逐条核对，发现**同一套 schema 被写在两个地方，且四处不一致**：

| 项 | `connector-and-relay.md` §1.4 | `remote-channel.md` §8.1 |
|---|---|---|
| `meta` 字段 | `{ schema, connectorId, relayUrl, aliasVersion }` | `{ schema, connectorId, relayUrl, connTokenSecretRef }` |
| 设备公钥 | `{ edPub, dhPub, … revokedAt? }` | `{ idPub(32B), edPub(32B), … revoked? }` |
| 别名 | 一个域两个 map | 两个域 |
| `takeover` | 有 `kv:takeover` | **缺失** |

这不是文档笔误那么简单：两侧都"看起来完整"，实现者会照就近那一节写，于是 TS 侧与 Dart 侧
可能按两套字段名落盘，而症状是**跨端读不出对方的设备表**——不是报错，是配对后认不出设备。

另一个问题在依赖的语义里：storage domain 的写入走**单写链**
（`packages/storage/storage-domain/src/domain.ts:263-270` 的 `enqueue`：入队 → 先落盘 →
再改内存 → 再发 `domain/changed`），也就是同一个域里的写是**串行**的。而契约 §1.4 对两类数据
的要求正好相反：`dedupe` / `lastPersisted` **必须同步落盘**（它们决定正确性，滞后就会在崩溃后
重放），`windows` 是 16 MiB 的增量缓冲、巨型写会长时间占住写链。放进同一个域，
一次 `windows` 大写就把后面的 `dedupe` 写堵在队列里——而「同步落盘」这条纪律恰恰是靠不被堵兑现的。

## Decision

**§8.1 是存储 schema 的唯一出处**；`connector-and-relay.md` §1.4 只保留使用纪律（迁移时机、
批量落盘节奏、落盘失败降级），不再复述表结构。

字段层面的裁定：

- 设备公钥用 **`edPub` + `dhPub`**（照 §4.1：种子派生 Ed25519 身份签名密钥与 X25519 静态 DH
  密钥）。§8.1 原来的 `idPub` 含义含糊，容易被读成"身份公钥"而与签名密钥混起来。
- `meta` 取两节的**并集**：`connTokenSecretRef`（§8.1，中转鉴权要用）+ `aliasVersion`
  （§1.4，§5.7 明写 `repo.info` 要报它）。并集在这里是安全的，因为两个字段各有明确消费者；
  但这是**一次性调和**，之后只有 §8.1 一处可改。
- `takeover` 表保留（§6.2 的仲裁判定需要每个设备的档位与最近交互时间）。
- 别名用一个域的两个表（`by_sid` / `by_session`），而不是两节各自的写法。

**按写入特征拆两个域**：`dsh_mobile_core`（global meta + devices + aliases + dedupe + takeover，
小、正确性关键、同步写）与 `dsh_mobile_windows`（windows，大、可批量、可丢）。

**业务 schema 版本与介质格式版本分开**：逐代迁移按 `meta.schema` 做；
`defineDomain` 的 `version` / `compatibleVersions` 是**介质格式**的版本，两者互不代表。

准入门槛（可机械判定）：

1. 表结构只在契约 §8.1 出现一次；`connector-and-relay.md` §1.4 不得再列出字段。
2. 域名与表名匹配 `^[a-z][a-z0-9_]*$`（**不允许连字符**，`packages/storage/storage/src/backend.ts:10`）；
   注意 `CredentialKey` 的规则**相反**（要求连字符、不允许下划线）。
3. `global` 必须写成 `{ schema, initial }`，且 **schema 不得接受 `null`**（null 是后端
   「从未写过」的哨兵，可空的 global 重开时会被静默当成没写过）。
4. 「尚未配置」用一个**合法值**表达（这里是空串），由生命周期在挂载时校验并拒绝服务；
   不许用缺字段或 null 表达"没有"。
5. 业务 schema 迁移**逐代**做，不写跳代分支；高于当前版本一律拒绝启动（`connector/unsupported`）。
6. 正确性关键的小表不得与 `windows` 同域。

## Alternatives considered

1. 保留两处描述，以先写成的 §1.4 为准
   - 最强的理由：§1.4 在生命周期那一节，读它的人正好是要实现 store 的人，就近可读；
     改动面也最小——只要把 §8.1 那五行删掉即可。
   - 为何被否：§1.4 讲的是**怎么用**（迁移时机、落盘节奏），把字段定义塞进去会让它同时承担
     两件事；而「存储边界与 schema」那一节的职责本来就是定义 schema，让它空着、
     把定义留在使用说明里，等于把真值源放在错误的层级。而且 §1.4 那一版少
     `connTokenSecretRef`，而中转鉴权离不开它。
2. 一个域装全部表
   - 最强的理由：`store.open()` 在 §1.3 里是**一个**生命周期步骤，一个域对应一次 open/close，
     迁移也只有一个版本号；实现与心智负担都最小。
   - 为何被否：单写链的语义（见 Problem）让 `windows` 的巨型写会堵住 `dedupe` 的同步写，
     而"同步落盘"正是 §1.4 明写的纪律。真出问题时症状会非常难查——去重表看起来在写，
     只是偶尔落后几十毫秒，而崩溃恰好发生在那几十毫秒里就是重复执行一次用户指令。
     拆域的代价只是多一次 `open()`。
3. 直接用 storage domain 的 `version` 兼作业务 schema 版本
   - 最强的理由：少一个版本号，`compatibleVersions` 那套机制还能白拿一部分兼容性处理，
     迁移逻辑可以省掉。
   - 为何被否：那个 `version` 描述的是**介质格式**（后端怎么存这一坨 JSON），
     与「我们有哪些业务字段、字段语义变没变」是两件事。介质格式没变而业务字段重构
     （比如 `aliasVersion` 从数字改成对象）是完全可能的，那时 `version` 不动、
     而必须迁移；反过来介质换布局时业务 schema 可能一个字没变。混用会让迁移在错误的时机触发。
4. 为了不引 zod，用结构化类型描述 schema
   - 最强的理由：`domainTable(schema)` 只用到 `ZodType` 的一小部分，手写一个最小接口就能过编译，
     少一个运行时依赖，也就不用处理"两份 zod"那摊事。
   - 为何被否：`defineDomain` 会在**模块加载期**用真 schema 做校验（名字规则、version、
     global 非空），而后端在读盘时会用 `safeParse` 逐条校验并配合 `invalidRecords: 'backup-and-skip'`。
     结构化类型骗得过编译器，骗不过运行时——`domainTable` 拿到一个没有 `safeParse` 的假对象，
     会在第一次读盘时炸。这不是"少一个依赖"，是"少一层真实校验"。

## Consequences

- 收益：存储 schema 只有一处可改，跨端漂移的结构性来源被移掉；正确性关键的写不再被
  大对象写堵住；「业务 schema 版本」与「介质格式版本」分开后，迁移在正确的时机触发；
  `defineDomain` 的三条规则（名字、version、global 非空）在模块加载期就拦，
  测试里"能 import 成功"本身就是一条断言。
- 代价：多了一个域、多一次 `open()`/`close()`，`store` 的生命周期从一步变成两步；
  `meta` 取两节并集是我替文档做的裁定，若后续有人认为 `aliasVersion` 该换成别的字段，
  必须改 §8.1 而不是再写一处；「未配置」用空串表达意味着 schema 无法在类型层面区分
  "已配置"与"未配置"，这个判断被推到了挂载期的校验里——漏做那一步校验就会拿空
  `connectorId` 去连中转。
