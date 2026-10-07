# 新会话提示词：把配对链路补完，做出第一次真机连通

> 复制下面 `---` 之间的全部内容到新会话。

---

## 任务

把 **配对 → 换票 → 升级 → 握手 → 发一句 / 回一句** 这条链补完，做出**第一次真机连通**。
电脑侧插件、中转、手机 App 三侧都要改。

**当前状态：基础设施已通，配对链在 App 侧没写完。**

## 已经做好的（不要重做）

| 环节 | 证据 |
|---|---|
| connector 构建 | `cd connector; pnpm build` → 163 KB `lib/index.js` |
| 插件挂进 profile | `dsh --profile dsh-mobile-test --dump-config` 里有 `dsh-mobile-connector`，**不在 skippedBundles** |
| relay 起来 | `cd relay; node src/main.ts --config relay.config.json` → `ws://127.0.0.1:8787` |
| connector → relay 长连 | `Established` 稳定（TCP 层已验证） |
| 手机 → relay | `adb reverse tcp:8787 tcp:8787` 后，手机 shell 里 `curl 127.0.0.1:8787/ws/connector` 回 **405**（通） |

**profile 与凭据已经配好**，不用重建：
- `~/.dsh/profiles/dsh-mobile-test/package.json`：`@dsh-mobile/connector` link 到 `D:/sudy/myproject/dsh-mobile/connector`
- `~/.dsh/profiles/dsh-mobile-test/cordis.patch.yml`：`relayUrl: ws://127.0.0.1:8787/ws/connector`（**路径必须有**，见"踩过的坑"）
- `~/.dsh/.credentials.yaml` 的 `records` 下有 `dsh-mobile-connector/relay-connector`（连接器令牌）
- `relay/relay.config.json`：connector 令牌 + device 令牌的摘要各一条

起服务的两条命令（**注意别覆盖用户在用的 web profile**）：
```powershell
# 中转（放后台）
cd relay; node src/main.ts --config relay.config.json

# 带插件的 profile（它自带一个 web UI，端口与用户的 GUI 错开）
dsh --profile dsh-mobile-test --no-open --port 8099
```

## 三个真缺口（已读代码确认，不是猜）

### 缺口 1：App 拨号用的是裸 relay 地址

`app/lib/main.dart:447-449`：
```dart
final transport = WebSocketTransport(
  WebSocketTransportOptions(url: credentials.relayUrl),
);
```
`credentials.relayUrl` 是二维码里的 `relay` 字段，值形如 `ws://127.0.0.1:8787`。
而设备要连的是 **`ws://<host>/ws/device?ticket=<ticket>`**（`relay/src/server.ts:150`）。
连根路径的后果：中转回 **404**，App 侧表现为"连不上"，且**日志里没有原因**（中转对 404 只 `log?.debug`）。

### 缺口 2：App 没有"换票"这一步

设备升级前必须先：
```text
POST http://<host>/ws-ticket
  Authorization: Bearer <设备令牌>
  body: { "codeHash": "<sha256(配对码) 的十六进制>" }
→ 201 { "ticket": "...", "expiresAt": <ms> }
```
（`relay/src/http-face.ts:111-128`；可执行规格见 `relay/tests/server.test.ts:79-93` 与 `relay/src/http-face.ts:111`）

全 `app/lib/` 搜不到 `ws/device` / `ticket` / `claim` 任何一处 —— **这一步完全没实现**。
`app/pubspec.yaml` 也**没有 HTTP 客户端依赖**（只有 `web_socket_channel`），要加 `http` 包。

注意：`httpBaseOf(relayUrl)` 的做法参考 `connector/src/pairing-register.ts:33-44` ——
**`ws://` → `http://` 且丢掉路径**（HTTP 端点不在 WS 那条路径上）。两侧要一致。

### 缺口 3（根子）：没有设备令牌，两端都没签发

`/ws-ticket` 要 `Authorization: Bearer <设备令牌>`，但**没有任何地方产生它**：

- 二维码载荷只有 `{v, relay, pcPubEd, pcPubDh, code}`（`connector/src/pairing.ts:168-174`）—— 没有令牌
- 配对回执只有 `{ok: true, devId, sas}`（`connector/src/pairing-endpoint.ts:100`、类型在 `:21-23`）—— 没有令牌
- 中转**没有签名身份**（`relay/src/*.ts` 里搜不到 `ed25519` / `sign` / 私钥）
- 中转摘要表是**启动时从配置读的静态表**（`relay/src/digest-auth.ts:50-66`），运行期不新增

契约写的流程（`docs/subsystems/remote-channel.md:565-566`）：
> 3. 电脑侧校验配对码,记录设备公钥并回执;**中转签发设备令牌**。身份判定由电脑侧做,中转只转发与记账。
> 4. 手机把主种子与刷新令牌写入系统安全存储;**中转只存令牌摘要**。

中转的 `devices` 表（同文件 `:456`）有 `token_hash, refresh_hash` 两列 —— 所以**设计上中转要落这张表**，但这套**两端都没实现**。这是契约领先于实现，不是配置问题。

## 设计要点（请照这个方向，但你有权做得更好）

### 设备令牌怎么签发：让**连接器**签，中转只存摘要

理由：中转**不该有签名身份**——它是转发器，不该能凭空造出"我是某台设备"的凭据。
而连接器是**身份判定的那一端**（契约原文："身份判定由电脑侧做，中转只转发与记账"）。

建议的流程（不新增协议帧，用**已有的 HTTP 端点**）：

1. 手机 `pair` 帧经中转到达连接器（**这一步现在就能通**：`pair` 无 `sid`，靠出码登记路由）
2. 连接器校验配对码、落设备行（现有逻辑，`connector/src/pairing-endpoint.ts`）
3. 连接器**生成设备令牌 + 刷新令牌**（两条 128 位随机，与配对码同规格：`connector/src/pairing.ts` 的 `random(PAIRING_CODE_BYTES)`）
4. 连接器把 **令牌摘要 + pairing_id + 设备公钥** 交给中转（新增一个 HTTP 端点，如 `POST /devices`，用**连接器令牌**鉴权）
5. 连接器在回执里**明文**带上设备令牌 + 刷新令牌（回执本来就是明文 `pair-ack`，且此时还没有会话密钥）
6. 手机把 `主种子 + 设备令牌 + 刷新令牌` 写进**系统安全存储**（`app/lib/platform/pairing_store.dart`，flutter_secure_storage）；**不进 sqflite**（契约 §8.3 `:475`）
7. 手机之后 `POST /ws-ticket`（设备令牌 + `codeHash`）换票 → `ws://…/ws/device?ticket=…` 升级

### ⚠️ 一个必须先想清楚的设计问题：**重连怎么办**

`/ws-ticket` 要求带 `codeHash`，而**配对码是一次性的**：认领即从登记表移除
（`relay/src/pairing-registry.ts:76-88`、契约 §12.1"被认领(claim)即从登记表移除"）。
所以**第二次连接不能再用换票那条路**。

而契约说"**重连是常态,不是异常路径**"（`remote-channel.md:67`），退避 1→30 s（`:510`）。
你必须决定并写下理由：已配对设备的**重连**走哪条路。至少两个方向：

- **A**：`/ws-ticket` 对"已配对设备"放宽 —— 不需要 `codeHash`，只要设备令牌有效，就按中转 `devices` 表里的归属直接发票（`binding` 落库而不是只在内存）；
- **B**：另开一条只认设备令牌的升级路径。

注意中转现在的 `binding` 是**纯内存**的（`relay/src/core.ts:140` `binding.set`），
且**连接器断开就清**（`core.ts:113-116`）、**设备断开也清**（`core.ts:125`）。
按契约 I7"中转可被清空后重启,已配对设备仅凭电脑侧数据收敛"（`:25`），
**归属不该只活在中转内存里** —— 中转重启后设备必须能自己回来。

### 安全约束（照 `AGENTS.md` §6 与契约 §12.2，逐条都要有测试）

- **只信任二维码带出的电脑公钥**：不接受任何网络下发的 `pcPubEd`/`pcPubDh`（§12.1 硬规则）。这条已实现，**不要破坏**（`app/lib/main.dart:460-467` 的注释在钉它）。
- **令牌只存摘要**：中转侧落库的是 `token_hash`/`refresh_hash`，**明文只出现在回执那一次**。连接器侧也一样（对照 `connector/src/store/index.ts` 的 `devices` 表）。
- **配对码只存哈希**：已有（`connector/src/pairing.ts:153`）。别把码写进日志。
- **未授权绝不生效**：设备令牌无效 → 401；票无效/过期/用过 → 401（已有，`relay/src/tickets.ts:114-125`）。
- **票一次性 + 60 s**：已有（`relay/src/tickets.ts`）。票值**不进 URL 日志**这件事别破坏。
- **不引入静默降级**：任何"失败就当成功"的路径都不要。这仓的 `AGENTS.md` 有 debug-first 纪律。

## 实施顺序（每步都要有可跑的验收）

1. **先写测试**，照仓里的老规矩：`relay/tests/` 与 `connector/tests/` 都有现成的 node:test 用例，照着写。
   - 先补一条**端到端配对测试**：连接器在线 → 出码登记 → 手机 `pair` → 连接器回执带设备令牌 → 手机换票 → 升级 → 双向转发。这条测试要通过**真 HTTP + 真 WS**（照 `relay/tests/server.test.ts` 的写法）。
   - 这条测试会**先红**，然后你实现到它绿。
2. **中转**：加"连接器登记设备"的端点 + `devices` 落库（`token_hash`/`refresh_hash`）+ 重连路径（你选的那个方案）。
3. **连接器**：配对成功时签发设备令牌 + 刷新令牌，交摘要给中转，回执带明文。
4. **App**：加 `http` 依赖 → 写 `core/` 的换票（**纯 Dart，零平台依赖** —— `app/tools/verify-platform-boundary.mjs` 会拦 `dart:io`）→ `platform/` 里做 HTTP 实现 → 拼 `/ws/device?ticket=` → `PairingStore` 加两个字段（设备令牌 + 刷新令牌）。
   - **`core/` 不许出现 `dart:io` / `package:flutter`**：边界校验脚本会拦，跑 `node app/tools/verify-platform-boundary.mjs`。
5. **真机验证**：`adb reverse` → App 里粘贴二维码 → 看状态胶囊从「未连接」变绿 → 发一句 → 电脑侧收到、回一句。

## 门禁（每次改完都要全绿）

```powershell
node protocol/verify-fixtures.mjs            # 486 项
node protocol/verify-loopback.mjs            # 26 项
node app/tools/verify-platform-boundary.mjs  # 165 项
cd connector; pnpm exec tsc --noEmit; pnpm test
cd relay; pnpm test
cd app; flutter test                          # 273 项
cd app; dart analyze --fatal-infos lib test integration_test
cd app; dart format --output=none --set-exit-if-changed lib test integration_test
```

**改断言必须做一次变异校验**（改坏实现确认变红）。**绝不允许削弱测试让它变绿。**

真机集成测试（**用真机，不要用模拟器 —— 它在这台机器上反复崩**）：
```powershell
adb devices      # 真机是 d61cf622（Redmi 23113RKC6C / Android 16 / arm64）
cd app; flutter test integration_test/ui_flow_test.dart -d d61cf622
```

## 踩过的坑（别再踩）

1. **`relayUrl` 必须带 `/ws/connector` 路径**。少了它中转回 404，症状是"TCP 连上又立刻断、日志无输出"。
2. **profile 的 link 路径**：曾经指向 `C:\sudy\...` 而仓库在 `D:\sudy\...`，插件根本没解析到。改完用 `--dump-config` 确认。
3. **别动用户在用的 `web` / `desktop` profile**，也别 kill 掉 19387 端口的 GUI（那是用户当前的会话）。测试 profile 用 **8099**。
4. **`dsh plugin --profile <新名字> add` 会顺带创建那个 profile** —— 探测时会留下垃圾 profile，用完删掉。
5. **改源码只用编辑工具，不要用 shell 字符串替换**：shell 出错是静默的，本仓已被这个坑写空过两次源文件（见 `docs/postmortem/`）。提交前必看 `git status` 完整清单，重点看**意外的文件**。
6. **用 `adb shell input tap` 点 Flutter 界面不可靠**（Flutter 不暴露 a11y 树，`uiautomator` 看不到元素）。要验交互就写 `integration_test`（它按元素找，不按坐标）。
7. **`flutter test integration_test/` 会先卸载再装测试包**，跑完要把正式包装回去。
8. 中转的拒绝**默认不打日志**（`log?.debug`，要 `DSH_RELAY_DEBUG=1` 才看得见）。排查时先开它。

## 交付判据

**真机上发一句、电脑侧收到、回一句、手机显示** —— 以及那条端到端测试绿。
做不到就如实说卡在哪一步、证据是什么（命令 + 输出），**不要用"应该可以"代替证据**。

## 相关文档（改之前先读）

- `docs/subsystems/remote-channel.md` §12（配对全流程）、§4.1（握手）、§8（存储边界）
- `docs/cookbook/channel-bootstrap.md` §5（真机连通）
- `docs/channel-review-notes.md`（DSH 侧事实与行号）
- `AGENTS.md` §6（项目特定硬规则）+ 各子目录 `AGENTS.md`

非平凡改动**必须留决策笔记**（`.agents/notes/`），与代码**同批提交**。
