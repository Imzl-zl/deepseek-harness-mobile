# 新会话提示词：dsh-mobile 手机端 Dart 客户端（第一段：建工程 + core/）

> 用法：整段复制给新会话。它假设对方**没有**本次对话的记忆，所以背景与判据都写全了。

---

## 你的任务

在 `D:\sudy\myproject\dsh-mobile` 落地**手机端 Dart 客户端的 `core/` 层**，
并让 `core/` 在**没有 UI、没有平台代码、没有真机**的情况下跑绿两批外部规格
（**先做第 2 条，它更硬**）：

1. `test/crypto_vectors_test.dart` —— 跑同一批 `protocol/vectors/*.json`（跨端密码学已知答案）
2. `test/fixtures_test.dart` —— 跑同一批 `protocol/fixtures/*.json`（16 条会话层场景）

**这是全仓当前唯一"零进度"的部分，也是所有手机端工作（含真机）的闸门。**
本段**不做** UI、不做三端能力包、不连真机——把 `core/` 做对做绿就是全部目标。

---

## 第 0 步：先读这些（不要凭印象开工）

按顺序读，别跳：

- `memory.md` —— 状态快照 + "下一步"（**注意：真机是手机端整条链的末端，不是下一步**）
- `tools.md` —— 命令与坑点；**Pitfalls 是稳定坑点的唯一出处**
- `AGENTS.md` + `docs/AGENTS.md` + `.agents/notes/AGENTS.md` —— 项目军规
- `docs/subsystems/app-channel-client.md` —— **手机端落地设计（本次的规格源）**
  - §1 分层与依赖方向（`core/` 零平台依赖是硬约束）
  - §2 关键类型（签名级）
  - **§3 的行尾 `\n`** —— 漏了的表现是"两侧都正常、对端什么都没收到"
  - §4 握手、§5.6 幂等、§7 测试策略、§12 配对
- `docs/subsystems/remote-channel.md` —— **唯一协议契约**（§3 帧层、§4 密码学、§5 恢复）
- `docs/subsystems/app-platform-boundaries.md` —— 多端边界（本段只需知道 `core/` 不许有平台分支）
- `connector/src/protocol/` —— 电脑侧已有实现，**是移植源也是对照物**（`frame.ts` / `crypto.ts` / `handshake.ts` / `handshake-frames.ts` / `recovery.ts` / `items.ts`）

---

## 第 1 步：装 Flutter SDK（版本闸门，别装最新）

**本机现状（已核实，2026-10-02）**：

| 项 | 状态 |
|---|---|
| Flutter / Dart | **不在 PATH**，需安装 |
| `adb` | ✅ `D:\soft\platform-tools\adb.exe` |
| JDK | ✅ 21（`JAVA_HOME` 已设） |
| Android SDK | ⚠️ `D:\soft\android-sdk`（platforms/android-36、build-tools 36.0.0、cmdline-tools）**但缺 `emulator` 与 `system-images`** |
| Visual Studio | ✅ VS 18 Community + MSVC + Windows SDK 10.0.26100（**Windows 桌面调试可用**） |
| 虚拟化 | ✅ 已开（模拟器可用） |
| 网络 | ✅ flutter 下载源 / dl.google.com / pub.dev 均可达 |
| 磁盘 | C: 1.39 TB 空闲，D: 623 GB 空闲 |

**⚠️ 版本闸门（硬约束，违反会被门禁或用户拦下）**：
三端共用一条 Flutter 版本线，**上界由鸿蒙 fork 决定 = 基于上游 `3.41.9`**
（见 `docs/subsystems/app-platform-boundaries.md` §4）。
**当前上游 stable 是 3.47.6 —— 不要装它。**

为什么本段（纯 Dart、不碰鸿蒙）也要守：**Dart SDK 的版本决定语言特性与 API 可用性**，
在 3.47 上写的代码可能用了 3.41 没有的 API，等到接鸿蒙时才发现要回改一大片
（`channel-review-notes.md` 记着海底捞"降级 Flutter 版本做 API 适配"就是这个坑）。
锁在 3.41.9 从第一天起就避免这类返工。装：

```powershell
# 已核实可下载（约 1.76 GB，HTTP 200）
# https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.41.9-stable.zip
# 解压到 D:\soft\flutter（路径**不要**含空格或中文）
# 然后把 D:\soft\flutter\bin 加进 PATH
flutter --version      # 必须显示 3.41.9
flutter doctor
```

`flutter doctor` 里 **Android toolchain 的 `ANDROID_HOME` 要指向 `D:\soft\android-sdk`**。
Windows 桌面那条（Visual Studio）**应当全绿**——本段用不到，但下一段调试要用。

**本段只需要 `flutter test`，不需要模拟器、不需要安卓 SDK 补全、不需要真机。**

---

## 第 2 步：建工程（`app/` 现在连 `pubspec.yaml` 都没有）

`app/` 目前**只有主题层**：`lib/theme/dsh_colors.dart` + `dsh_theme.dart`（两个文件）。

```powershell
cd D:\sudy\myproject\dsh-mobile\app
flutter create --platforms=windows,android,ios .
flutter test          # 确认空工程能跑
```

- **加 `windows`**：本段与下一段的调试主要靠它（本机 VS 工具链齐全，且**不需要模拟器/真机**）。
- `flutter create` 会生成 `lib/main.dart` 与 `test/widget_test.dart` —— 保留（下一段要用）。

`pubspec.yaml` 加依赖（本段只加密码学与测试）：

```yaml
dependencies:
  cryptography: ^2.9.0      # 纯 Dart：Ed25519 / X25519 / Hkdf / Chacha20.poly1305Aead / Sha256 全都有
  # 下一段才加：sqflite / 状态管理 / markdown 等
```

**已核实的兼容性**（省你一次试错）：
- Flutter `3.41.9` 自带 **Dart 3.11.5**；
- `cryptography 2.9.0` 要求 Dart `>=3.3.0 <4.0.0` → ✅ 兼容。
- 它**默认走平台实现**（Android `javax.crypto` / iOS CryptoKit），
  平台没有的算法**自动回退纯 Dart** —— 所以 `flutter test`（桌面 VM）也能跑，
  这正是本段判据成立的前提。
- 可选 `cryptography_flutter` 提速，**本段不要加**（它把调用委托给系统 API，
  纯 Dart 单测里没有那些 API；等真机阶段再评估，且注意 `channel-review-notes.md:239`
  记着它的加速清单**不含** XChaCha20）。

**⚠️ 目录纪律**：`flutter create` 会生成 `app/test/`。门禁 `verify-platform-boundary.mjs`
只扫 `app/lib` 与 `app/packages`，**不扫 `app/test`** —— 所以测试里可以 import `dart:io`
读 `../protocol/fixtures/`。这是有意的，别为了"对称"把 fixture 读进 `lib/`。

---

## 第 3 步：写 `core/`（本段的全部产出）

按 `docs/subsystems/app-channel-client.md` §1 的分层，**本段只写 `core/`**：

```text
app/lib/core/
├── frame.dart        帧编解码 + AAD 规范化（契约 §3）  ← 对照 connector/src/protocol/frame.ts
├── crypto.dart       握手派生、HKDF、AEAD、fc 计数器（契约 §4）← 对照 crypto.ts
├── handshake.dart    三帧握手（发起方 = 手机）        ← 对照 handshake.ts / handshake-frames.ts
├── flow.dart         流控窗口与 credit 回执（契约 §4.3）
├── recovery.dart     恢复判定、快照分页（契约 §5.4）
└── items.dart        itemId 推导与 upsert（契约 §5.2）
```

**硬规则（`node app/tools/verify-platform-boundary.mjs` 会拦，17 项必须全绿）**：

- `app/lib/core/` **禁** `dart:io`、**禁** `package:flutter/{services,widgets,material}.dart`、
  **禁** `Platform.` / `defaultTargetPlatform` / `MethodChannel` / `EventChannel`。
- 需要 IO（比如读 fixture）走**注入的接口**，别在 `core/` 里直接开文件。
- 改完 `app/lib/` 必跑：`node app/tools/verify-platform-boundary.mjs`

**三个最容易踩的点（都有前车之鉴）**：

1. **出帧一律以 `\n` 结尾**，且**只在唯一的出帧口（`encodeFrame`）补** —— 别让调用点各自记得。
   漏了的表现是"两侧都正常、对端什么都没收到"（本项目真的踩过，见 `tools.md` 的 Pitfalls）。
2. **AEAD 是 `Chacha20-Poly1305`（IETF / RFC 7539，12 字节 nonce）**，
   nonce = `fc` 的 **96 位大端**（`buf.writeBigUInt64BE(fc, 4)`），不是随机 nonce。
   Dart 侧用 `Chacha20.poly1305Aead()`（`cryptography` 包）—— 已核实它就是 RFC 7539、`nonceLength == 12`。
3. **AAD 是 `[v, t, id, sid, seq, fc].join('|')`**，缺字段用**空串**占位（`connector/src/protocol/frame.ts:271-273`）。
   拼串必须逐字节一致 —— 差一个字符就是"解不开"，而不是报错。

---

## 第 4 步：两批测试（本段的判据）

### 4.1 `test/crypto_vectors_test.dart`（先做这个，它最硬）

跑 `protocol/vectors/handshake.json` 与 `aead.json`。**这两份是机生成的已知答案**，
`node protocol/verify-vectors.mjs` 是参考侧（49 项），Dart 侧必须算出**同样的值**。

已核实的形状：

- `handshake.json`：`input{info, pairingId, seedA, seedB, ephSeedA, ephSeedB, nonceA, nonceB}`、
  `expected{pubA, pubB, ephPubA, ephPubB, ss1, ss2, ss3, master, kA2B, kB2A}`、
  另有 `identity{masterSeed, expected}` 与 `signature{fields, transcript, signerEdSeed, sig}`
- `aead.json`：`vectors[]{name, fc, aad, plaintext, key, ciphertext, tag, box}` + `tamper[]{...}`

**这一批跑绿的意义比 fixtures 大**：它是"两端互操作"的唯一硬证据。
（`connector/tests/support/phone.ts` 那个手机替身是照契约重写的**第二份 TS 实现**，
它证明"协议两侧自洽"，**不能替代** Dart 侧跑同一批向量。）

**⚠️ 注意角色**：电脑侧永远是**应答方**（`responder`），手机是**发起方**（`initiator`）。
`ss1` = 发起方临时 × 应答方静态 —— **角色不同拼接顺序不同**，而顺序反了**不会报错**，
只会两侧各算出一把主密钥、AEAD 永远解不开（`tools.md` 的 Pitfalls 有完整记录）。
所以**必须有一条"双侧派生"用例**：Dart 算发起方、拿 TS 的期望值比对，而不是只验单侧输入输出。

### 4.2 `test/fixtures_test.dart`

跑 `protocol/fixtures/*.json`（16 条）。**别自己设计消费方式 —— 照着
`connector/tests/fixtures.test.ts` 移植**，它是同一批 fixtures 在电脑侧的对应物，
头部注释已写明角色划分与判据口径。

已核实的形状：

- 每条 fixture = `{name, why, bridge, relay, device, steps, expect}`，是**三角色场景脚本**；
- `steps[].op` 的完整集合（17 种）：`append` / `redeliver` / `hello` / `ack` / `ackSeq` /
  `snapshotPage` / `relayEvictAll` / `relayRestart` / `bridgeTrim` / `bridgeRestart` /
  `sendTwice` / `setTransient` / `ask` / `answer` / `rebuildPending` / `live` / `takeover`；
- `expect` 的完整键集合（14 种）：`recovery` / `items` / `itemCount` / `bridgeItemCount` /
  `deviceCursor` / `requests` / `transient` / `pending` / `duplicates` / `gaps` /
  `liveIgnored` / `takeover` / `converged` / `relayRoutingKeysOnly`。

**角色划分（关键）**：fixtures 跑的是**三角色回放**，而 Dart 侧只实现其中**一个**角色：

| 角色 | Dart 侧 | 说明 |
|---|---|---|
| 手机（`device`） | ✅ **本次的产品代码**（`core/`） | `since` / `received` / `upsert` / `applyAnswer` 这些行为是你要写的 |
| 中转（`relay`） | ❌ 测试替身 | 照 `connector/tests/support/relay.ts` 移植成 Dart 测试替身 |
| 桥接（`bridge`） | ❌ 测试替身 | 照 `connector/tests/fixtures.test.ts` 里的对应物移植（`createBridge` 那一侧） |

也就是说：**Dart 侧的 `core/` 只负责"手机看到一次恢复应答之后做什么"**
（增量 upsert / 快照分页拼接 / 幂等去重 / 空洞判定 / 待审批重建 / `live` 不入账），
中转与桥接在测试里是替身。这与 `app-channel-client.md` §2 的
`RecoveryOutcome`（`ApplyDelta` / `NeedSnapshot` / `SnapshotPage`）正好对上。

参考侧判据：`node protocol/verify-fixtures.mjs` = **486 项断言 / 16 条 fixture**。
`connector/tests/fixtures.test.ts` 断言数**等于** 486（它逐条对齐）。
**Dart 侧是否要凑到 486 由你判断并写进笔记** —— 优先保证"每一条 fixture 的每个 `expect` 键都被断言到"，
数量对齐是手段不是目的；但如果你的结构与 connector 侧同形，凑到 486 是最省事的自检。

---

## 硬约束（违反会被门禁或用户拦下）

- 改 `app/lib/` 或 `app/packages/` 后必跑 `node app/tools/verify-platform-boundary.mjs`（**17 项**）。
- **改源码只用编辑工具，不用 shell 字符串替换**（shell 出错是静默的，已两次把源文件写空）。
- 提交前必看 `git status` **完整清单**，重点是意外的文件（空的、消失的、没见过的）。
- 非平凡改动必须留决策笔记，**代码与笔记同批提交**（格式见 `decision-notes` 技能）。
- 引用 DSH 行为必须给 `packages/...:行号`；查不到就写「未找到」，**禁止猜**。
- 仓库内路径一律从 `import.meta.url` 派生，不许硬编码盘符。
- **不许为了让测试过而改 `protocol/` 的规格** —— 那是两侧共用的真值源。Dart 侧要适配规格，不是反过来。

---

## 完成判据（本段交付）

1. `flutter --version` 显示 **3.41.9**（不是 3.47.x）。
2. `cd app && flutter test` 全绿，且包含：
   - `test/crypto_vectors_test.dart` 覆盖 `handshake.json` 与 `aead.json` 的**全部**向量
     （含 `tamper` 的负向用例：改 AAD / 改密文必须解不开）；
   - `test/fixtures_test.dart` 覆盖 16 条 fixture 且结论与参考侧一致。
3. `node app/tools/verify-platform-boundary.mjs` **17 项全绿**（`core/` 零平台依赖）。
4. `node protocol/verify-fixtures.mjs` / `verify-vectors.mjs` 仍全绿（**证明你没改规格去迁就实现**）。
5. 决策笔记落盘（至少记：选 `cryptography` 包的理由与被否方案、版本闸门锁 3.41.9 的代价）。
6. `memory.md` / `tools.md` 同步（若新增了稳定命令或坑点）。

**做完这一段，"协议两侧互操作"才第一次有了真证据。** 下一段才是 `data/` + `model/`，
再下一段 `ui/`，最后能力包 —— 真机在整条链的末端。

---

## ⚠️ 两个已知缺口（本段不受影响，但"直连跑通"之前必须先补）

**本段（纯 `core/` + `flutter test`）完全不受这两条影响**，但它们是"两条路径都通"的拦路石，
新会话**不要以为连接器已经万事俱备**（我在 memory.md 里曾把这点说轻了）：

1. **`relayUrl` 是挂载的硬前置**：`connector/src/index.ts:217-225` 的 `validate-config` 里，
   `relayUrl` 或 `relayTokenRef` 为空就**抛错拒绝挂载**。所以"纯直连、不配中转"**目前挂不起来** ——
   要用直连得先让 `validate-config` 接受"只配了 `listenPort`"这种形态。
2. **二维码里的地址永远是中转**：`connector/src/pairing.ts:170` 写的是 `relay: options.relayUrl`，
   而 `index.ts:369` 传进去的也是 `relayUrl`。所以手机扫码后拿到的是**中转地址**，
   直连拓扑下它需要的是**电脑的地址**（`listenHost:listenPort`，且外部已终结 TLS）。

**这两条是"直连真机联调"的前置，不是本段的前置。** 本段做完后，建议按这个顺序推进：
`data/`+`model/` → `ui/`（能在 Windows 桌面上跑起来）→ 补上面两条 → 直连联调 → 能力包。

---

## 关于"不用真机也能调试吗"（答：能，而且本段就是纯 `flutter test`）

四层调试，**前三层都不需要真机**：

| 层 | 怎么调 | 本机可行性 |
|---|---|---|
| **纯 Dart 逻辑** | `flutter test`（含本段的 fixtures/vectors） | ✅ **本段的全部目标** |
| **Windows 桌面跑整个 App** | `flutter run -d windows` | ✅ VS 18 + MSVC + Windows SDK 已齐 |
| **安卓模拟器** | `flutter emulators --create` + `flutter run` | ⚠️ 需先补 `emulator` + `system-images`（约 1–2 GB，`sdkmanager` 已就位） |
| **真机** | USB 调试（`adb` 已就位）或无线调试 | 末端才需要 |

**关键结论**：`flutter run -d windows` 能跑**完整的 Dart 逻辑 + 大部分 UI**，
`sqflite` 也有 `sqflite_common_ffi` 在桌面跑（`app-channel-client.md` §7 的存储测试策略就是这么写的）。
所以 UI 与状态机的调试**不需要真机，甚至不需要模拟器**。

**只有这三件事必须真机**（`app-platform-boundaries.md:103` 已写明，模拟器与调试构建不作数）：
① 三端专属表达（iOS Live Activity / 安卓通知操作 / 鸿蒙关键节点）；
② 推送在锁屏与强杀后的行为；③ 安卓 force-stop 与厂商通道。
这三件都在**最后**，且属于"验收"而不是"开发"。

**真机调试需要什么环境**（等你走到那一步）：
- 安卓：装好 `platform-tools`（✅ 已有）+ 手机开 USB 调试；或 `adb pair` 无线调试。
  **鸿蒙要另装 DevEco Studio + CPF-Flutter 的 OHOS SDK**（那是独立一套，且要过 §13 的适配清单）。
- iOS：**需要一台 Mac + Xcode**（本机是 Windows，做不到）—— 这是硬限制，不是配置问题。
