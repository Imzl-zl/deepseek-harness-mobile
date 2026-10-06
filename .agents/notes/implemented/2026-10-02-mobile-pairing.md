# Agent Note: 配对落地 —— 手机侧派生规则由跨端向量钉住，密钥进系统安全存储

Status: implemented（2026-10-02 落地：`core/pairing.dart` + `platform/pairing_store.dart` + `ui/pairing_page.dart`）

## Problem

### 一、配对之前，App 是一个"什么都不能做"的空壳

上一轮安卓端跑通了，但截图显示的是**失败态**（`relay/offline`）——
因为 `BootstrapConfig` 是占位值，App 手里**没有任何可信的电脑身份**。
配对正是"把可信身份从带外搬进来"的那一步（契约 §12.1），缺了它整条链是断的。

### 二、配对的派生规则是"算错了却不报错"的那一类

契约 §12.1 把两个派生定义得很死，而它们**错了不会抛异常**：

- **`pairingId`**：`base64url(HKDF-SHA256(ikm = sha256Hex(code) 的 UTF-8 字节,
  salt = 空, info = "dsh-mobile/v1/pairing", L = 32))`。
  最易错的是 `ikm`：用**码的字节**也能算出一个值，而且**两端各自自洽** ——
  只有互连时才发现 `master` 不同（表现为"配上了但永远连不上"）。
- **设备标识 `devId`**：`base64url(sha256(devPubDh 的 UTF-8 字节)[0..16])`。
  同样易错：哈希**十六进制字符串的字节**还是**公钥原始 32 字节**。
  写错的后果是电脑侧把这台手机当成没见过的设备。
- **SAS**：`sha256("dsh-mobile/v1/sas|" + pcPubEd + "|" + devPubEd)` 前 4 字节
  大端 `mod 10^6` 补零成 6 位。写错的表现是两端显示**不同数字**，
  于是用户合理地怀疑"配错设备了"。

三条的共同点：**没有异常、没有日志、症状出现在离真因很远的地方**。

### 三、主种子的落点有硬下限

契约 §12.2 明令：主种子必须进系统密钥库，**绝不接受"降级成明文 preferences"**。
而它是**唯一**的设备身份秘密 —— 拿到它就能冒充这台设备。

## Decision

### 一、派生规则只有一处实现，且由**跨端向量**钉住

- `core/pairing.dart` 是手机侧**唯一**实现 `pairingId` / SAS / `codeHash` 的地方。
- `app/tools/gen-pairing-vectors.mjs` **调用真实的 `connector/src/pairing.ts`**
  （不是我在 Dart 里重写一遍再对拍 —— 那只能证明"我两次写的一样"）产出期望值，
  写进 `app/test/fixtures/pairing-vectors.json`；
  `app/test/pairing_vectors_test.dart` 逐条断言。
- 四条向量覆盖不同形状：base64url 码、短码、含 `-`/`_` 的码、**非 ASCII**。

### 二、电脑公钥只有一个入口

`PairingOffer.fromQrPayload` 是**唯一**读电脑公钥的地方，
代码里没有任何"从 `presence` 或 `res` 里读公钥"的路径（契约 §12.1 硬规则）。
它同时是外部输入的校验点：字段缺失、非 JSON、公钥非十六进制都在这里带原因拒掉。

### 三、密钥进系统安全存储，且这一层住在 `platform/`

- 用 `flutter_secure_storage`：安卓走 Keystore + AES-GCM/RSA-OAEP，iOS 走 Keychain。
- `iOS` 用 `first_unlock_this_device`：锁屏也能读（后台收推送要读），
  但**不随备份迁移**（设备身份不该被备份复制）。
- `PairedCredentials` 是**值类型**，`core/` 与 `data/` 只认识它，不认识它从哪来。

### 四、准入判据（可机械判定）

1. **派生逐字节一致**：跨端向量全绿（变异校验见下）。
2. **配对请求不带码本身**：只带 `codeHash`（请求经中转）。
3. **凭据缺失即视为未配对**：缺任一字段 → `load()` 返回 `null`（不返回"部分可用"）。
4. **配对前不建连**：`main.dart` 在拿到凭据之前不构造 `SyncClient`。

## Alternatives considered

1. **在 Dart 里手抄一份期望值（不调用 TS 实现）**
   - 最强的理由：不用起 Node，测试自包含。
   - 为何被否：手抄的值**会漂移**，而漂移之后两边都在对着一个错答案自洽 ——
     那正是"跨端向量"要防的事。调真实实现只多一步 `node` 命令，而它把
     "我对契约的理解"换成"电脑侧的实际行为"。
2. **做相机扫码（而不是粘贴）**
   - 最强的理由：真机体验好得多，而二维码本来就是给人扫的。
   - 为何暂不做：相机权限 + 扫码库属于**三端能力包**（`packages/`），
     而它们的判据是 C1"App 不在前台也要工作吗" —— 扫码显然不是，
     但它仍要三端各写一份（三套权限与相机 API）。
     粘贴**功能等价**（二维码里就是一段 JSON）、零权限、零依赖、且**可测**。
     扫码作为增量加在 `pairing_page.dart` 上，不影响下面的逻辑。
3. **主种子回落成 preferences（当安全存储不可用时）**
   - 最强的理由：至少 App 能用，不会因为插件问题变成砖头。
   - 为何被否：契约 §12.2 把这条写死为下限（"绝不回落成明文 preferences"）。
     而"安全存储不可用"是**真故障**，该如实报错，不该静默降级 ——
     降级的代价是设备身份可被任何能读到 App 数据的人复制。
4. **把 `deriveDeviceId` 放进 `core/`**
   - 最强的理由：它是纯函数，属于"协议算法"。
   - 为何被否：它描述的是**电脑侧怎么算这个 id**（配对时的分配行为），
     而不是双方对等的协议算法。放 `platform/` 与 `pairing_store.dart` 同处，
     让"配对知识"聚在一起；协议算法（握手/AEAD）仍在 `core/crypto.dart`。
     代价是它不能进 `core/` 的单测 —— 由跨端向量覆盖（更合适）。

## Consequences

- 收益：**配对的派生不再可能悄悄写错**。四条跨端向量把"我对契约的理解"
  换成了"电脑侧的实际行为"。
- 收益：App 从"永远连不上"变成**可用**：配对一次之后凭据在设备上，
  重启直接进会话列表（不重复配对 —— 重复会换 `pairingId`，
  电脑侧记的是旧的那个，表现为"这台设备不见了"）。
- 代价：多一个依赖 `flutter_secure_storage`（它带平台代码）。
  这是**必须是插件**的一类：密钥库是平台能力，纯 Dart 拿不到。
- 代价：`app/tools/` 多了两个脚本（一个生成向量、一个出真载荷）。
  前者的产物进仓库（fixture），后者的产物不进。
- **已知缺口（如实记录）**：三端能力包 `packages/secure_store_*` **还没做**。
  当前用 `flutter_secure_storage`，**满足安卓阶段**的要求；
  但契约 §12.2 明确它对鸿蒙**不够**（"适配清单里的 ohos fork 未见 HUKS 说明，
  不能推断密钥由 HUKS 保护"），鸿蒙开工时须自写 platform channel 接 HUKS,
  并在"X25519 协商不可用"时走"HUKS 的 AES 密钥包裹主种子"的降级路径。
  本文件的接口不变。
- **仍未做**：`data/store.dart`（sqflite 本地库）、`ui/adaptive/`、
  保活与推送、真实中转地址（当前载荷里的 `relay` 是示例值）。

## 落地时改动的文件

| 文件 | 做了什么 |
|---|---|
| `app/lib/core/pairing.dart` | **新增**：二维码解析、`codeHash`/`pairingId`/SAS 派生 |
| `app/lib/platform/pairing_store.dart` | **新增**：凭据值类型 + 安全存储读写 + `deviceId` 推导 |
| `app/lib/ui/pairing_page.dart` | **新增**：配对页（粘贴 → 解析 → 显示 SAS → 确认） |
| `app/lib/main.dart` | **改**：改为"配对门"，凭据缺失时不建连 |
| `app/test/pairing_vectors_test.dart` | **新增**：跨端向量断言（4 条 × 4 项） |
| `app/test/fixtures/pairing-vectors.json` | **新增**（生成物）：由 TS 实现产出 |
| `app/tools/gen-pairing-vectors.mjs` | **新增**：调 `connector/src/pairing.ts` 产期望值 |
| `app/tools/make-pairing-qr.mjs` | **新增**：出真载荷（给设备喂数据用） |
| `app/integration_test/pairing_flow_test.dart` | **新增**：真机验安全存储（纯单测验不了插件） |
| `app/pubspec.yaml` | **改**：加 `flutter_secure_storage`（写明为什么必须用它） |

证据：`flutter test` **147 项全绿**；`dart analyze --fatal-infos` 0 问题；
`dart format --set-exit-if-changed` 0 文件；`verify-platform-boundary.mjs` **104 项**；
`protocol` 486/26/49 全绿。

**变异校验**（一处）：把 `pairingId` 的 `ikm` 从"哈希的 UTF-8 字节"改成
"码本身的字节" → 向量立刻红，且报出两个不同的 base64url 值 ——
正是"两端各自自洽、互连时才发现"的那个症状。
