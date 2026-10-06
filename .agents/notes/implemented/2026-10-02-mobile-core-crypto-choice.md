# Agent Note: 手机端 core/ 的落地——选 `cryptography` 包，并把"双侧派生"做成硬判据

Status: implemented（2026-10-02 落地：`app/lib/core/` + `app/test/crypto_vectors_test.dart` + `app/test/fixtures_test.dart`）

## Problem

### 一、"手机端零进度"卡住的不是代码量，是一个没装的环境

`app/` 之前**只有主题层**（两个 dart 文件、连 `pubspec.yaml` 都没有），
而 `memory.md` 把"真机联调"和"手机端 Dart 客户端"并列写成"下一步"——
那是错的（已在本轮之前纠正）：真机是"装 SDK → 建工程 → `core/` → `data/`+`model/`
→ `ui/` → 三端能力包"这条链的**末端**。

### 二、装哪个 Flutter 版本是个有硬约束的决定

`app-platform-boundaries.md` §4 的版本闸门：三端共用一条 Flutter 线，
**上界由鸿蒙 fork 决定 = 基于上游 3.41.9**。而当时上游 stable 已经是 **3.47.6**。
装最新会怎样：本段是纯 Dart、不碰鸿蒙，看起来"无所谓"——
但 **Dart SDK 的版本决定语言特性与 API 可用性**，在 3.47 上写的代码可能用了
3.41 没有的 API，等接鸿蒙时才发现要回改一大片（`channel-review-notes.md`
记着海底捞"降级 Flutter 版本做 API 适配"就是这个坑）。

### 三、AEAD 到底用哪个算法，向量里写死了

`protocol/vectors/aead.json` 的期望值是用 `chacha20-poly1305` 算的
（`protocol/tools/vectors-core.mjs` 里就是 `createCipheriv('chacha20-poly1305', …)`）。
所以 Dart 侧**没有选算法的自由**：必须找一个实现 RFC 7539 的包，
否则 49 项向量一条都对不上。

## Decision

**装 Flutter 3.41.9；密码学用 `cryptography` 包；`core/` 只写纯 Dart 的六层。**

准入门槛（可机械判定）：

1. **版本闸门**：`flutter --version` 必须是 `3.41.9`（不是 3.47.x）。
2. **跨端向量**：`test/crypto_vectors_test.dart` 跑 `protocol/vectors/*.json`，
   Dart 侧算出的值与 TS 侧**逐字节相同**（16 项）。
3. **fixtures**：`test/fixtures_test.dart` 三角色回放 16 条 fixture（494 项断言）。
4. **零平台依赖**：`node app/tools/verify-platform-boundary.mjs` 全绿（40 项）。
5. **不许改规格**：`protocol/verify-fixtures.mjs` / `verify-vectors.mjs` 仍全绿
   —— 证明是 Dart 侧适配了规格，不是反过来。

### 关键取舍一：`cryptography` 而不是自己实现或换算法

已核实（pub.dev API + 文档）：`cryptography 2.9.0` 的
`Ed25519` / `X25519` / `Hkdf` / `Chacha20.poly1305Aead` / `Sha256` **都有纯 Dart 实现**，
`Chacha20.poly1305Aead` 就是 RFC 7539（`nonceLength == 12`、32 字节密钥），
与向量一致。要求 Dart `>=3.3.0`，而 Flutter 3.41.9 自带 Dart 3.11.5 → 兼容。

**不加 `cryptography_flutter`**：它把调用委托给系统 API（Android `javax.crypto` /
iOS CryptoKit），而纯 Dart 单测（桌面 VM）里没有那些 API ——
加了它，本段"没有 UI、没有平台代码也能跑绿"这个判据就不成立了。
性能要等真机阶段再评估（且 `channel-review-notes.md:239` 记着它的加速清单不含 XChaCha20）。

### 关键取舍二：`SecretBox.concatenation()` **不能**用来拼箱容器

`cryptography` 的 `SecretBox.concatenation()` 拼的是 `nonce ‖ 密文 ‖ mac`，
而契约 §3 的容器是 **`base64url(密文 ‖ tag)`，nonce 不上线**
（nonce 由 `fc` 派生）。用错的话单侧测试全绿、真机才断（症状"解不开"）。
所以 `packBox` / `unpackBox` 手工拼，并进了向量断言（`箱容器` / `容器往返` 两条）。

### 关键取舍三：`ss1` / `ss2` 是**角色调整后的绝对编号**，不是位置值

这是本轮抓到的**真 bug**，值得单独写下来：

协议里 `ss1` 的定义是「**发起方**临时 × **应答方**静态」。而代码里最自然的写法是
「自己的临时 × 对端的静态」—— 同一个表达式在发起方算出的是 `ss1`，
在**应答方算出的却是 `ss2`**。我最初的实现把位置值直接当协议编号返回，
后果是：**派生的主密钥仍然完全正确**（`ikm` 用的是调整后的顺序），
所以握手会"看起来成功"、AEAD 也能正常解封 —— 只有那两条 `ss1`/`ss2` 断言会红。

`tools.md` 的 Pitfalls 早就记着这一类（"两侧各算一遍的协议，必须有一条真的跑两侧、
比对同一结果的测试"）。本轮的做法是把它变成**硬判据**：向量测试里
`asInitiator` 与 `asResponder` 的**六个字段全部**各自等于向量值，
而不是只验发起方一侧。

## Alternatives considered

1. **装最新 stable（3.47.6）**
   - 最强的理由：新版本 bug 更少、性能更好，而且本段纯 Dart、短期看不出差别。
   - 为何被否：版本闸门的存在理由就是**避免将来的返工**（三端必须共用一条线）。
     现在省下的兼容性判断，将来要在"接鸿蒙"这个最贵的时点还回来。
2. **自己实现 ChaCha20-Poly1305 / X25519 / Ed25519（不引包）**
   - 最强的理由：零依赖，且能精确控制字节级行为（本项目对"两端逐字节一致"很敏感）。
   - 为何被否：密码学手写实现是本项目最不该自研的一块（`channel-review-notes.md`
     的选型结论也是"用维护中的包"）。而"字节级一致"这个诉求由**向量**满足，
     不需要靠自己写实现来满足。
3. **把 `cryptography_flutter` 也加上（提速）**
   - 最强的理由：Android/iOS 走系统实现，快得多（包自报 ChaCha20-Poly1305 约 30 MB/s 纯 Dart）。
   - 为何被否：它让 `core/` 在纯 Dart 单测里跑不起来（系统 API 不存在），
     而"core/ 零平台依赖、能在没有 UI 的情况下跑绿"正是本段唯一的判据。
     等真机阶段单独评估（那时也有真实基准数据了）。
4. **fixtures 的断言数对齐电脑侧的 486**
   - 最强的理由：`connector/tests/fixtures.test.ts` 就是这么做的，对齐了便于发现漏断言。
   - 为何被否：两侧的**角色划分相反**（connector 把手机侧做成替身，Dart 侧把桥接/中转
     做成替身），断言点的自然分布本来就不同；强行凑数会造出无意义的断言。
     改成"断言数 > 300"的下界 + "每个 `expect` 键都必须被走到"，同样能拦住整块遗漏。
5. **把桥接/中转替身放进 `lib/`（好让别的测试复用）**
   - 最强的理由：不用每个测试文件都 import `test/support/`。
   - 为何被否：它们**不是产品代码**（手机端不实现中转，也不实现电脑侧桥接），
     放进 `lib/` 会让"哪些是要发布的东西"变模糊，而且会给 `core/` 引出一堆
     只服务测试的 API。放 `test/support/` 与 `connector/tests/support/` 对称。

## Consequences

- 收益：手机端从"零进度"到**两批外部规格全绿** —— 这是"两端互操作"第一次有真证据
  （此前只有电脑侧 + 一份 TS 替身）。且判据完全不需要 UI、平台代码或真机。
- 收益：`protocol/fixtures` 与 `protocol/vectors` 现在各有**两个独立实现**在跑，
  任何一侧的语义漂移都会被其中一侧抓住。
- 代价：**`app/` 现在有 90 个文件是 `flutter create` 生成的**（android/ios/windows 三端
  脚手架），其中大部分本段用不到。它们必须入库（否则 `flutter run` 跑不起来），
  于是仓库体积与"看一眼 diff"的成本都上去了。
- 代价：`cryptography` 是本项目的第一个 Dart 依赖，它自己又拉进 `crypto` / `ffi` /
  `typed_data`。供应链面变大（但都是 pub.dev 上的高下载量包）。
- 代价：fixtures 的三角色回放**在 Dart 侧重写了一遍桥接与中转替身**（约 350 行）。
  这是"两侧各跑同一批 fixtures"的必然成本；好处是两侧的替身互为对照
  （如果哪天两侧对同一条 fixture 得出不同结论，说明契约有歧义）。
- **仍未做**：`data/` + `model/`（DTO 与 store 接口）、`ui/` 逐屏、三端能力包、
  `sync_client.dart`（连接状态机与订阅管理 —— 它需要真实 transport，属于下一段）。
  真机仍在整条链末端。
- **未修的既有缺口**（本轮查实，与本段无关）：`relayUrl` 是挂载硬前置
  （`connector/src/index.ts:217-225`），所以"纯直连、不配中转"挂不起来；
  二维码里的地址永远是中转（`pairing.ts:170`）。两条都挡着"直连真机联调"。

## 落地时改动的文件

| 文件 | 做了什么 |
|---|---|
| `app/`（90 个文件） | `flutter create --platforms=windows,android,ios .` 建出工程；加 `cryptography` |
| `app/lib/core/frame.dart` | **新增**：帧类型 + AAD 规范化 + 行级编解码（含 `\n` 规则） |
| `app/lib/core/crypto.dart` | **新增**：HKDF / 身份派生 / 会话密钥 / AEAD / nonce / 重放守卫 |
| `app/lib/core/handshake.dart` | **新增**：三帧编解码 + transcript 从字段拼 |
| `app/lib/core/items.dart` | **新增**：itemId 推导 + upsert 排序 |
| `app/lib/core/recovery.dart` | **新增**：`DeviceSession`（接收规则、分页拼接）+ `decideRecovery` |
| `app/lib/core/flow.dart` | **新增**：流控窗口 + `credit` 编解码 |
| `app/test/crypto_vectors_test.dart` | **新增** 16 项：跨端已知答案（含双侧派生、篡改拒绝、分帧） |
| `app/test/fixtures_test.dart` | **新增**：16 条 fixture 三角色回放（494 项断言） |
| `app/test/support/fake_roles.dart` | **新增**：桥接与中转的测试替身（移植自 connector 侧） |
| `app/tools/verify-platform-boundary.mjs` | **改**：两条规则从"按正文 grep"改成"只认 import 指令"（见下） |

证据：`flutter test` **18 项全绿**（16 向量 + fixtures + 1 个 `flutter create` 自带的 smoke）；
`flutter analyze` 0 问题；`verify-platform-boundary.mjs` **40 项**全绿；
`protocol/verify-fixtures.mjs` 486 / `verify-loopback.mjs` 26 / `verify-vectors.mjs` 49 全绿
（**证明没改规格去迁就实现**）。

**四处变异校验**：① `deriveSessionKeys` 去掉角色调整 → 向量测试 1 项红（正是双侧断言）；
② `encodeFrame` 不补换行 → 1 项红；③ `_upsert` 去掉重复/空洞判定 → fixtures 2 项红；
④ 快照收口时丢掉分页期间缓存的事件 → fixtures 3 项红（正是 fixture 12）。

### 附带修掉：边界门禁的一个误报（结构性）

`core-no-platform-import` / `ui-no-platform-import` 原本按**正文** grep `dart:io`，
于是 `core/frame.dart` 文件头那句「本文件是纯 Dart：不许 import `dart:io`」
被**自己**判成违规 —— 等于**惩罚把规则写进代码**，而每个 `core/` 文件都会想提这件事。

改成只认 `import` / `export` 指令本身（正则 `^[ \t]*(?:import|export)\s+['"]…`，
注释行天然放过），并补 3 条自检样本：两条"说明规则的注释要放过"、
一条"真 import 仍要拦"。门禁从 19 项升到 40 项（自检 13→16）。
变异校验：把正则退回按正文 grep → 3 项红（含两条新自检）。
