# 架构审查：独占准入撤除（S0）与六个待处理 PR

- 日期：2026-11-06
- 触发：用户要按已定的目标架构（七层 + HostScope / 键空间三分 / AppServices）审 1 个已落地分支 + 6 个 PR
- 状态：proposed（审查结论；本批只落 S0 的文案/测试/文档，架构部分是路线）
- 范围：`fix/drop-exclusive-admission @ e42e600`（37 文件 +181/−1100）；`refs/pr/1,4,5,6,7,8-head`；已并入 main 的 #2 / #3

## 一、S0（撤掉独占准入）判定：改后合

代码层通过：无恒真开关、无兜底分支、`refusalReason` 全仓 0 引用、错误码两端 35 且
`error-table-parity` / `flow.test.ts` 实跑绿、`pnpm test` 832/832、`dart analyze --fatal-infos lib test` 无 issue。
必改的是**文案、注释、计数与缺测试**，不动协议与结构。

### 已在本批修掉的（逐条对应提交）

| 项 | 位置 | 修法 |
|---|---|---|
| 11 处注释仍在解释已删的「占用位 / 接管」 | `connector/src/admin/device-admin.ts:94-97,156-157,182-184`、`connector/src/index.ts:861-863,1339-1340`、`connector/src/presence.ts:125`、`connector/client.js:517,1695,1761-1762`、`connector/tests/client-panel.test.ts:17,350`、`connector/tests/device-admin.test.ts:71` | 理由换成不依赖独占的那一条：已吊销的连接不能继续收发帧 |
| 停用确认文案说"下次重连就会失败" | `connector/client.js:326` | 实际是**立刻断开**（`device-admin.ts:184` → `index.ts:864-866`），文案与英文版同改 |
| 总览条 `N / M 台在线 · 有设备在线` 重复 | `connector/client.js:1541-1544` | 删掉后半句（它原本只用来区分"1 台在服务"） |
| 「停用/删除必须收连接」零测试 | ~~`connector/tests/device-admin.test.ts`（`disconnected` 只有夹具无断言）~~ | **初判有误，已复核更正**：`device-admin.test.ts:236-262` 有 4 条断言（停用 / 解禁不踢 / 删已停用 / 按状态批量只踢真删掉的），`presence.test.ts:84-102` 另覆盖"两台同时在线、一台离开不影响另一台"。真正的缺口只剩"两台同时在线时停用 A，B 仍在"这一版，见下 |
| 「A 先答、B 再答 → not-pending」零测试 | `connector/tests/` 无跨设备用例 | 用真实 `createInteractionPort + createInteractionFace` 补 |
| `tools.md:265` 错误码门禁写「数必须 36」 | 实际 `flow.test.ts:105` 断言 35 | 改 35 并指向断言行 |
| `memory.md:330` 仍把 `occupantOf → 4003 → busy-wait` 写成现状 | 整条链已删 | 删该段 |
| `remote-channel.md:244` 举例仍是「占用者是谁」；「≤120 字节截断」的实现已删 | `close-reason.ts` 已删 | 写明说明形态的当前唯一生产者是中转（`rate-limited quota`），连接器只产码 |
| `connector-and-relay.md:175` 说电脑侧发 `4003 + 协议码/说明` | 连接器现在只发码 | 同上 |
| `app-channel-client.md` §6.4 把「装配层按 hostId 持有一池实例」「切换不拆旧的」写成当下事实 | 本分支 `app/lib/main.dart:617` 仍是 `_app?.dispose()` | 改回事实（换槽 + 重新装配，旧的会被 dispose），池化降级为 S4 的目标 |

### 判为"可接受、不补"的两条

1. **「本次会话那一台」标记的损失**：那个标记挂在 `serving` 上，是 1:1 的副产物，不是
   "我手里这部"的真信号。识别需求已有现成答案：行上的「最后活跃」（`client.js:1746,1771`）
   与「前台/后台」（`:1777`）。补一格新字段 = 新增宿主没有的边界。
2. **`credit` ack 无身份标记**：已被"每设备一条数据通道 + 每连接一个发送窗口"实际化解 ——
   `connector/src/transport/relay-link.ts:128-164`（按 `channelId` 建、URL 带 `dev`）、
   `connector/src/transport/connection.ts:272`（每连接一个 `SendWindow`，重连重建）、
   `app/lib/core/connection_resources.dart:48`（手机侧同样每连接一份）、
   `connector/src/protocol/flow.ts:63-71`（ack 过箱认证、确认的是本连接自己的 `fc`）。
   **结论：不加 `id` 回显**，`remote-channel.md §4.3` 的未决项关闭。

### 一处前提修正（写进文档，避免以后按错的模型想问题）

"A 先答、B 必须收到 `interaction/not-pending`"只对一半：A 答完时 B 是被**会话事件**
（`approval/decided` / `tool/result`）把卡关掉的；`not-pending` 只在 B **迟一步再点答**时出现
（`interaction-claims.ts:196-202` → `interaction-face.ts:344-350`）。两条路都要有测试。

## 二、六个 PR

决定性事实：`git merge-base main refs/pr/8-head` = **7f461f8（2026-11-03）**，
`git log refs/pr/8-head..main` = **23 个提交**，其中含 `bda574b(#2)`、`f4cdf79(#3)`、
`4dcacc4` 抬线 DSH 0.2.2-rc.1、`9e574b7/26de539/f2487ca` 目标条、`b45436d` 载荷合并写。
所以 `main...pr/8-head` 那 82 个文件是**相对旧基线**的差异，直接合会回退这 23 个提交在重叠文件里的改动。

| PR | 判定 | 理由 | 归到 |
|---|---|---|---|
| #8 | **改后合** | 基线落后 23 提交 + CONFLICTING + check-runs=0；主体方向（每电脑一实例池 + 存储分域）对，实现形状与目标架构冲突；夹带无人审的应用内装 APK 通道 | S2/S3/S4 |
| #1 | **关** | `merge-base --is-ancestor` = true，两提交是 #8 的祖先，文件级差集 0 | 随 #8 |
| #4 | **关** | IME 方案已被 #8 自己的笔记真机否掉（`viewInsets.bottom` 恒 0，见 `implemented/2026-11-04-ime-insets-on-android-15.md:26-31`） | S3 |
| #5 | **部分合** | 9 文件里 7 个被 #8 覆盖；独有 `app/test/add_host_cancel_invariant_test.dart` 要按池化后的结构重写保留 | S4 |
| #6 | **关** | 两条改动全在 #8 且 #8 的门禁更严（认文件形态 + 剥注释防"只留 import"骗过规则）；要抢时间就 cherry-pick 两个文件 | S0/S3 |
| #7 | **关** | 只是文档项数归口，`tools.md` 部分已在 #8 | S0 |
| #2 / #3 | 已并入 main | 回归确认见下 | — |

### #2 的回归洞（就地记为部署前提）

`relay/src/accounts/session.ts:90-99` 在 `trustProxy=true` 时**无条件**信 `X-Real-IP` / XFF 首段，
没有代理地址白名单；而 `docs/cookbook/relay-on-a-server.md:297` 的样例就写着 `"trustProxy": true`。
§3 那种"公网 IP + 明文 8787"的部署（同文档 `:74,82`）下，任何人伪造该头即可绕开按人限流、
连续失败锁定与匿名管理桶。**判据：不是代码要改，是 cookbook 要写死前提** —— 只有 8787 只绑回环
（§4.2 那种）时才允许 `true`。

## 三、15 条缺陷复核的结论摘要

成立 15 条，其中 4 条要改口径（细节见审查记录，不在此重复）：

- 第 1 条：Android 安装器强制验签，"零签名校验"≠"可被换成任意 App"；真缺的是"装的就是它声称的那个"
  与镜像路径的完整性，加上 `downloadApk` 直写最终文件（无 `.part`+rename）。
- 第 9 条：镜像 87 行、**7 个包升版（14 行±）**，不是 14 个包。
- 第 14 条：`wire→core` 实际 **0**（"×38"对得上的是 `data→model`，方向允许）；
  `ui/dsh_diff.dart:33` 不是 import，是 `class DiffLine` —— 那正是 S1 要搬去 `model/` 的对象。
- 第 15 条：行数复核实测 `app_model` 4399/4348、`chat_page` 5004/4991、`sync_client_impl` 1922；
  "17 个职责簇 / ChatPageState 2713 行"未逐条复核。

## 四、本轮要落的架构步（S1、S2）

S1（去环）与 S2（作用域）是目标架构里**不依赖 #8** 的两步，本批按这个顺序做：

1. **S1**：`DiffLine` 归 `model/`（消 `model→ui`×2）；`fieldOf` 下移（消 `model→data`×1）；
   `kUiScaleSteps` 下移（消 `theme→model`×1）。`core→wire`×2 与 `data→wire`×21 留到下一批：
   它要的是"core 声明、wire 实现"的依赖倒置，动的是热路径，单独一批做并单独留笔记。
2. **S2**：`HostScope` 不可变 + `ScopedItemStore` 装饰器（`ItemStore` 接口不认识 host，
   作用域构造时注入，**禁止 `setHostScope`**）；键空间三分 `schema.*` / `device.*` / `host.<id>.*`，
   `clear()` 按桶正写；迁移 v2→v3 把旧行归到 `local_items.host` 记着的那台。
   **没有那个键就什么都不做**（全新安装 / 从没装配过凭据 —— 两种情况下都不存在"该归给谁"的
   旧数据；实际落地的判据与此同，见 `implemented/2026-11-06-s2-host-scope-and-buckets.md`）。

S3（AppServices 汇总通知/前台服务）、S4（HostSessions 注册表）、S5（AppModel 切片 / chat_page 拆文件）
不在本轮：S3/S4 依赖池化先落地，S5 是最后做且必须单独评审。

## 五、落地状态（2026-11-06 02:20）

- **S0 五项已落**：`c30637d`（死注释 + 停用文案）、`5cf0973`（两台设备并发三条判据）、
  `dc8a53e`（文档收口）。
- **S1 已落**：`ff78552`（DiffLine）、`5340f54`（字号值域）、`dd2ff4f`（JSON 取值助手）。
  `model→ui` / `model→data` / `theme→model` 三条反向 import 实测为 0。
- **S2 已落**：`34fbae9`（HostScope + 装饰器 + 迁移 v2→v3 + 键空间三分）。
- **仍未做**：S3 / S4 / S5；`core→wire`×2 与 `data→wire`×21 的依赖倒置。
- 门禁现状：connector 835 / app 1750 / boundary 748 / `dart analyze --fatal-infos` 0。

## 六、未验证

- 两台真机端到端（两台同时进服务态、A 答后 B 撤卡、吊销 A 不动 B）：设备 `d61cf622`
  处于 `unauthorized`（USB 调试授权没过），本轮无法驱动真机。
- #8 的 `flutter test` 1685 与 check-runs：旧基线上的自述，本仓未复跑。
