# Cookbook:把通道从零跑到能连通

目标:新会话照着做完,能拿到一个**装进 DSH、对着同一批 fixtures 跑绿、并且真机连通**的电脑侧插件骨架。
协议契约见 `../subsystems/remote-channel.md`;三侧设计见 `../subsystems/connector-and-relay.md` 与 `../subsystems/app-channel-client.md`;现状事实与行号见 `../channel-review-notes.md`。

**不要跳步。** 第 0–3 步全部不需要真机、不需要 DSH 实例、不需要公网。

---

## 0. 开工前先确认基线是绿的

```powershell
cd D:\sudy\myproject\dsh-mobile
node protocol/verify-fixtures.mjs          # 期望:ALL CHECKS PASSED — 486 项断言，16 条 fixture
node protocol/verify-loopback.mjs          # 期望:ALL CHECKS PASSED — 26 项断言
node app/tools/verify-platform-boundary.mjs # 期望:ALL CHECKS PASSED — 17 项
node mock/proto/tools/verify-icons.cjs     # 改过 mock/proto 才需要
```

判据:三条全绿。**任何一条不绿先修它**,不要在红的基线上开工。

---

## 1. 决定工程形态并留笔记(半小时)

已知基线(2026-09-30 核实,不必再查):

| 项 | 值 |
|---|---|
| 包管理器 | `pnpm@11.13.0`(本机实测值;connector 是独立 bundle,不跟 DSH 根的补丁号) |
| Node | `^22.19.0 \|\| >=24.0.0` |
| DSH 包版本 | 公共 npm 的 **`next` tag = `0.2.0-rc.2`**(`latest` 落后很多,**不要用**) |
| cordis / schemastery | `4.0.4` / `3.18.4`(`latest`) |
| 兼容性判据 | `peerDependencies` 对 `@deepseek-ai/dsh*` 的范围(不是 `engines.dsh`) |
| 插件接入 | `dsh.bundle.patch` → `cordis.patch.yml`(`insert` 4 行) |

1.1 写 `.agents/notes/implemented/<今天>-connector-workspace-shape.md`,记录:本仓库引入第一套 `package.json` / pnpm(属于"流程与工具链"非平凡改动)、选 pnpm 的理由、peer 精确版本的升级代价。

判据:笔记落盘且被 `memory.md` 的"已定案的契约"引用。

---

## 2. 建 `connector/` 骨架

```powershell
mkdir connector; cd connector
pnpm init
pnpm add -D typescript@5.9.3 tsdown@0.22.14 tsx@4.21.0 @types/node@^24
pnpm add -D @deepseek-ai/dsh-agent@next @deepseek-ai/dsh-api-session-controller@next `
  @deepseek-ai/dsh-jobs@next @deepseek-ai/dsh-storage@next `
  @deepseek-ai/dsh-user-approval@next @deepseek-ai/dsh-user-questions@next
```

2.1 `package.json` 按 `../subsystems/connector-and-relay.md` §1.1 的样例补齐(`dsh.bundle.patch`、peerDependencies 精确版本、engines、`packageManager`)。

2.2 写 `cordis.patch.yml`(4 行):

```yaml
- insert:
    - id: dsh-mobile-connector
      name: 'dsh-mobile-connector'
      config: {}
```

2.3 目录按设计文档 §1.2 建空文件(`src/protocol/`、`src/dsh/`、`src/transport/`、`src/store/`、`tests/`)。

判据:`pnpm exec tsc --noEmit` 通过(空实现也要能编译);`node --check` 所有 `.mjs` 工具脚本。

---

## 3. 把参考实现移植成 `src/protocol/`

`protocol/reference/` **不是可搬运的代码**(它是行为基准),但它是逐行可对照的移植源:

| 参考实现 | 目标 | 注意 |
|---|---|---|
| `frame.mjs` | `src/protocol/frame.ts` | AAD 按契约 §3 的规范化拼串;`id`/`sid` 限 ASCII 安全字符集 |
| `bridge.mjs` | `src/protocol/recovery.ts` + `items.ts` + `dedupe.ts` | 快照分页游标 `b:<beforeSeq>`;去重表**持久化**;`itemId` 按契约 §5.2 表 |
| `takeover.mjs` | `src/protocol/takeover.ts` | 判定与排序必须与 fixture 16 完全一致 |
| `relay.mjs` | 不需要 | 中转侧才有;connector 不用 |

3.1 写 `tests/fixtures.test.ts`:读 `../protocol/fixtures/*.json`,用 `src/protocol/` 的实现跑出相同结论。

```powershell
pnpm test
```

判据:16 条 fixture 全绿,**且断言数与 `verify-fixtures.mjs` 一致(486)**。数量对不上说明漏了断言。

3.2 做一次变异校验(改断言时必须做):

```powershell
# 把 protocol/ 复制到临时目录,注入破坏,确认变红
# 三条已知基线见 ../subsystems/remote-channel.md §14.3
```

---

## 4. 接 DSH 适配层(`src/dsh/`)

按 `../subsystems/remote-channel.md` §2.2 的适配表逐项接,每项一个文件:

| 文件 | 取自 DSH | 验收 |
|---|---|---|
| `sessions.ts` | `sessionController.follow/page/prompt/cancel` | `seq` 直接当修订号;`page()` 用于快照分页 |
| `interaction-client.ts` / `interaction-claims.ts` | `typertGateway` 的 `$events` 转发流(owner client)+ 在途 claim | 参与判定走 `takeover.ts`;回话只用 `allowed-once` / `rejected`;不参与就 `next`(原生委托) |
| `jobs.ts` | `ctx.jobs` | **按 owner 过滤**(`list` 会把无主任务并进每个会话) |
| `subagents.ts` | `listChildren` / `listDescendants` | `activity` 只表达驻留 |
| `settings.ts` | `ctx.settings` / `ctx.credentials` | 密钥**只有写面**;`describe` 不含值 |
| `caps.ts` | 服务存在性 | 能力位给手机置灰用 |

判据:`grep -r "packages/" src/dsh/` 里的每条 DSH 行为都带 `packages/...:行号` 注释;`src/protocol/` 不 import 任何 DSH 类型(依赖方向单向)。

---

## 5. 装进 profile(挂载验证);真机连通要等第 6 步整条链做完

```powershell
# 1) 装插件(以 DSH CLI 实际帮助为准)
dsh plugin --profile <name> add <connector 本地路径>

# 2) 确认没被跳过:检查 skippedBundles 报告(profile.ts:118 reportSkippedBundles)
```

判据:插件出现在清单里且**未被记入 `skippedBundles`**;若被跳过,99% 是 peer 版本不匹配。

**这一节能验到的是"能挂载",不是"能连通"。** `--dump-config` 只证明服务在树里有提供者;
真正连上要等**第 6 步的手机端**落地 —— 没有 App,就没有任何一端能发起握手。
本节的"跑通"是第 6 步之后的验收项,不是现在可做的一步。

**接线到哪一步了**(看这一句就够):连接层已经完整 —— 三帧握手、会话密钥、
每一种业务帧的 AEAD 封箱/解封、§4.3 的流控(W=128、收到即回 `credit`、满窗只压 `ev`/`live`),
连接级 e2e 用手机侧的**独立实现**双向跑通过;方法面与 §5.6 的幂等管道也在。
**方法面清单只认契约 §5.7**（不在这里手抄一份；当前实现 **31/35**，未实现的 4 个见 §5.8）。
**缺服务的部署里对应方法根本不在表里**（`job.*` 要 `jobs` 与 `jobController`；
`endpoint.describe` 要配了 `listenPort` 且监听面起得来；`session.projections` 要 `sessionProjections`）。
其余回 `connector/unsupported`。
配对(§12.1)在代码层面已闭合:电脑侧出码(斜杠命令 `dsh-mobile-pair`,**登记不成就绝不出码**)
→ 手机带 `codeHash` 换票 → 经中转转发 → 电脑侧校验并落设备行 → 明文回执;
`relay/` 已可运行(`node relay/src/main.ts --config <json>`,配置里只放令牌摘要)。
**带密钥的三方链路已 e2e**:`connector/tests/relay-keyed-three-party.test.ts` ——
手机替身带票连中转 → 握手(真签名与真 transcript)→ 发一句(真 AEAD)→ 收一句,
握手三帧无 `sid`(靠 ticket 绑定路由)、业务帧带 `sid`(靠归属表路由),两条路穿过同一个中继进程。
入站 `persisted`(手机报落盘水位)已接:电脑侧据此裁剪每个会话的增量缓冲,
**只有全部配对设备都确认过的区间才裁**(§5.5)。

所以下面 5.1 的"发一句 / 回一句"缺的**不是"客户端本身"这一件事,而是第 6 节整条链**
(建工程 → `core/` → `data/`/`model/` → `ui/` → 能力包)。**第 5 节现在做不完**,
它的"跑通"是第 6 节之后的验收项 —— 写在这里是为了留下**判据与顺序**,不是让人现在去跑。

5.1 先用 Tailscale 直连做第一跳(契约 §14.6 的顺序):

```text
手机(或笔记本上的临时客户端) ⇄ Tailscale ⇄ 电脑侧 connector
```

判据:发一句 / 回一句跑通(前置:第 6 节的手机端)。

电脑侧**接受连接**的那一半已就绪(`docs/subsystems/connector-and-relay.md` §1.7):配 `listenPort`
即监听,每 accept 一条就装配一次;TLS 由 Tailscale(`tailscale serve`)或反向代理终结,插件只监听明文 WS。
`connector/tests/listener.test.ts` 已用手机替身在真 socket 上跑通握手与双向 AEAD ——
**但那证明的是"电脑侧 + 替身",不是"两端跑通"**:替身是照契约重写的第二份 TS 实现,
真正的互操作要等 Dart 侧跑同一批 `protocol/vectors`(第 6 节第 3 步)。

5.2 接上中转后**复跑同一组用例**(契约 §14.2 的回环在真实中转下也要过)。

---

## 6. 手机端(前置:装 Flutter SDK **并建出工程**)

`memory.md` 记录本机 PATH 上没有 Flutter/Dart。`app/` 目前**只有主题层**(`lib/theme/` 两个
dart 文件),**连 `pubspec.yaml` 都没有** —— 所以第一步是"建工程",不是"往现有工程里加代码":

```powershell
cd app
flutter create --platforms=ios,android .   # 建出 pubspec.yaml 与各端目录
flutter test                               # 确认空工程能跑
```

再按 `../subsystems/app-channel-client.md` 的 §1 分层落地(顺序即依赖方向):

1. `core/` 先写 `frame` / `crypto` / `recovery` / `items`(纯 Dart,零平台依赖);
2. `test/fixtures_test.dart` 跑同一批 `protocol/fixtures`;
3. `test/crypto_vectors_test.dart` 跑 `protocol/vectors/`(跨端互操作);
4. `data/` + `model/`(DTO、store 接口、会话模型);
5. `ui/` 逐屏(`design-and-tech-plan.md` §7)+ `platform/` 装配点;
6. 三端能力包(`secure_store_*` / `notify` / `live_surface` / `keepalive`)最后接。

判据:第 2、3 步在**没有 UI、没有平台代码**的情况下全绿——这正是 `core/` 零平台依赖的意义。
**这两步是全仓当前性价比最高的一步**:它们不需要 UI、不需要平台代码、不需要真机,
而且一旦跑绿,"协议两侧互操作"这件事才算真的有了证据(第 5 节的替身不算)。
**第 5 节的真机连通要等本节第 4、5 步**(有 UI 能发起握手);安卓 SDK 也只有到那时才需要。

---

## 7. 中转(`relay/`)

**起它**(`relay/` 是独立服务,不需要构建;导入写 `.ts`,直接跑在 Node 的类型剥离下):

```powershell
cd relay
pnpm install                                                   # only ws is a runtime dep
node src/main.ts --config ./relay.config.example.json --issue-token connector home-pc
# ↑ 令牌只显示这一次;写进配置的是它的 sha256 摘要(配置里没有令牌)
node src/main.ts --config relay.config.json                    # 启动并打印生效的限流值
node src/main.ts --config relay.config.json --revoke-token connector home-pc
```

配置字段:`port` / `host` / `tokens`(摘要表) / `rateLimit`(`capacity` + `refillPerSecond`;
不配则用默认 60 与每秒 6 —— **默认生效**,因为默认敞开的转发器是隐患)。
`tokens` 为空时**拒绝启动**(引导路径是先签发再启动)。样例见 `relay.config.example.json`,
并有一条用例真的拿它启动一次(样例坏了会让操作者以为是自己改错)。

按 `../subsystems/connector-and-relay.md` §2 落表、接口与 `window` 有界窗口。上线前置:

- **不变量**:中转代码里不得出现按事件内容分支的逻辑;删掉 `window` 全表后重启,已配对设备重连仍收敛;
- 限流(**HTTP 与 WS 升级两条路都限,按身份不按 IP**)/ 吊销(**软吊销**:`revokedAt` 留行,重签即轮换)/ 审计按 §2.4;
- 合规:ICP 备案、PIPL 告知与最小化、厂商推送账号与模板报备;
- 容量:按 §2.5 的估算做一次压测(**空闲连接数、转发吞吐、窗口内存**三项),不许拿估算当结论。

---

## 8. 每次改动的固定动作

```powershell
node protocol/verify-fixtures.mjs            # 改 protocol/ 或两侧 protocol 层后必跑
node protocol/verify-loopback.mjs            # 同上
node app/tools/verify-platform-boundary.mjs  # 改 app/lib 或 app/packages 后必跑
```

- 改断言 → 必须做一次变异校验并记录结果;
- 协议有变动 → **先改 fixtures,再改两侧实现**;
- 任何 DSH 行为断言 → 带 `packages/...:行号`,查不到就写「未找到」。
