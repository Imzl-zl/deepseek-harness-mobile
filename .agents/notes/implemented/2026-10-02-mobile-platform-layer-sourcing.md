# Agent Note: 手机端平台层选型——查一手来源再定，而不是自己发明

Status: implemented（2026-10-02 落地：`app/lib/platform/websocket_transport.dart` + `test/websocket_transport_test.dart`）

## Problem

### 一、我在两处"自己发明"了本该查资料的东西

用户指出这一点时，我回头核了自己的代码，确实有两处：

1. **`_SecureSource`** —— 一个只有一个方法的类，包装 `Random.secure()`。
   它没有任何附加价值（转发一次），只是多一个要维护的东西。
2. **手写 LCG 随机源**（`connection.dart` 里已删的那一版）—— 更糟：
   用 `DateTime.now()` 播种，**引入了一个隐藏的时钟依赖**，让测试结果随时钟漂移。
   而标准库里就有 `Random`，`cryptography` 包里还有 `SecureRandom.system`。

两处的共同点：**都是"想当然"而不是"查过"**。而本项目对 DSH 行为明确要求
"引用必须给行号，查不到就写未找到，禁止猜" —— 这条纪律该同样适用于**选型**。

### 二、本地参考仓库里没有 Dart 代码

`rikkahub`（Kotlin/Compose）、`Agents-Anywhere`、`deepseek-harness` 三个参考仓库
**一个 `.dart` 文件都没有**（实测 `pubspec=0 dart=0`）。
所以"参考成熟设计"这件事只能去**一手来源**：pub.dev 的包文档与**已安装包的源码**。

## Decision

**选型必须有可核实的一手依据；没有依据的抽象层直接删掉。**

准入门槛（可机械判定）：

1. **每个新依赖在 `pubspec.yaml` 的注释里写明"为什么是它"**，并给出核实过的能力
   （不接受"文档说支持"而不写出**核实了哪个签名**）。
2. **关键行为有真 socket 的用例**：`test/websocket_transport_test.dart` 起真的
   `HttpServer` + upgrade，断言升级头真的到了服务端（这是选 `IOWebSocketChannel`
   的**唯一理由**，不验它等于选了个没用的东西）。
3. **删掉无价值的包装层**（`_SecureSource`）。

### 核实一：WebSocket 客户端用 `web_socket_channel`（Dart 官方包）

一手来源：
- <https://pub.dev/packages/web_socket_channel> —— publisher `tools.dart.dev`（Dart 官方），
  1.6k likes / 11M downloads，仓在 `dart-lang/http`；
- 已安装包的源码 `<pub-cache>/web_socket_channel-3.0.3/lib/`。

**关键发现（差点选错）**：跨平台的 `WebSocketChannel.connect`
**不接受 `headers`**，签名是：

```dart
static WebSocketChannel connect(Uri uri, {Iterable<String>? protocols})
//                                        ^^^^^^^^^^^^^^^^^^ 只有 protocols
```

而契约 §2.2 要求连接器令牌走 `Authorization: Bearer` **升级头**（不进 URL ——
URL 会进日志、代理记录、崩溃上报）。所以必须用 `IOWebSocketChannel.connect`：

```dart
factory IOWebSocketChannel.connect(Object url, {
  Iterable<String>? protocols,
  Map<String, dynamic>? headers,        // ← 这个才是我们要的
  Duration? pingInterval,
  Duration? connectTimeout,
  HttpClient? customClient,
})
```

**代价如实记录**：这一层因此是 io 专有的（web 端要另写实现）。
这是**有意的**：手机三端都是 io，而"令牌走哪"是协议决定，
不该为了跨平台把它挪到子协议或首帧。

**`pingInterval` 传 `null`（关掉）**：契约 §2.2 有自己的心跳与半开判定
（`core/keepalive.dart`，60 s / 2 周期），而它判定的依据是**业务帧**的收发时刻。
让 WebSocket 协议层再发一套 ping，会多出一路**不受我们控制**的保活流量 ——
两套心跳并存时，"半开"的判据就不再是我们定义的那一个了。

### 核实二：`SecureRandom` 用包提供的，不自造

一手来源：<https://pub.dev/documentation/cryptography/latest/cryptography/SecureRandom-class.html>
—— `cryptography` 提供 `SecureRandom.system`（系统随机）与 `SecureRandom.fast`
（ChaCha20 实现，快 100 倍）。

所以 `frame.dart` 的 `randomBytes` 用 `SecureRandom.system`，
**并放在 `newFrameId` 旁边**（字符集约束与生成点是同一件事的两端）。

### 核实三：本地存储继续用 `sqflite`（且鸿蒙侧有官方 fork）

一手来源：CPF-Flutter 的 `flutter_sqflite` 仓，**存在 `br_3.41_dev` 分支**
（<https://gitcode.com/CPF-Flutter/flutter_sqflite>）—— 正好对应本仓锁定的
Flutter 3.41 线。这印证了 `app-channel-client.md` §3 与
`app-platform-boundaries.md` 的既定结论（`drift` / `realm` 不在适配清单里）。

**这一条本轮只核实、未落地**（`data/` 层还没做），记在这里免得下次重新查。

## Alternatives considered

1. **直接用 `dart:io` 的 `WebSocket`（不加依赖）**
   - 最强的理由：零依赖，而且 `web_socket_channel` 内部就是用它。
   - 为何被否：`closeCode` / `closeReason` / `ready` 要自己从事件对象里解析，
     而"建连完成"这个信号在裸 API 上不直观（`onopen` 与 `ready` 的时序差别是
     本项目踩过的那类坑）；且 web 端要另写一套。用官方包装换来结构化的事件与跨平台，
     成本是一个纯 Dart 依赖。
2. **用跨平台的 `WebSocketChannel.connect`（不用 io 专有入口）**
   - 最强的理由：跨平台最干净，将来 web 调试不用换实现。
   - 为何被否：**它不接受 `headers`**（已核实源码）。而令牌必须走升级头 ——
     要迁就它就得改协议（令牌挪到子协议或首帧），那是**为了一个客户端库改契约**，
     方向反了。所以改成"这一层 io 专有"，并把代价写进文件头。
3. **给 `randomBytes` 保留一层自己的包装类**
   - 最强的理由：调用点短一点，且将来换随机源只改一处。
   - 为何被否：它只有一个方法、只转发一次 —— **没有附加价值**。
     而"换随机源只改一处"这个诉求由 `frame.dart` 里的一个顶层函数满足了
     （调用点是 `randomBytes(n)`，不是某个对象的实例方法）。
4. **自己写 LCG（第一版真的这么写了）**
   - 最强的理由：避免 `dart:math` 依赖，"让随机在代码里看得见"。
   - 为何被否：**`DateTime.now()` 播种 = 隐藏的时钟依赖**，测试结果随时钟漂移；
     而"看得见"这个目的用一行 `SecureRandom.system` 与一段注释就能达到。
     更根本的是：随机源不该由我们发明，那是标准库与密码学包的职责。

## Consequences

- 收益：`platform/` 首次落地，而且**关键能力（升级头）有真 socket 的用例**盯着 ——
  将来有人"顺手换回跨平台 connect"，那条用例会立刻红（变异校验证实）。
- 收益：删掉一个无价值的包装层；随机源改由 `cryptography` 提供。
- 代价：**这一层是 io 专有的**（web 端要另写实现）。如实记录在文件头，
  而不是假装跨平台。
- 代价：多一个 Dart 依赖（`web_socket_channel`，它又拉进 `web_socket` / `web`）。
  已核实用的是官方包，供应链面可接受。
- 代价：`pubspec.yaml` 的注释变长（每个依赖一段"为什么"）。这是**刻意的**：
  本项目已经吃过"两处来源"的苦，而选型理由是"代码装不下的为什么"那一类。
- **仍未做**：`data/`（DTO + sqflite store）、`model/`、`ui/` 逐屏、三端能力包。
  真机仍在整条链末端。

## 落地时改动的文件

| 文件 | 做了什么 |
|---|---|
| `app/lib/platform/websocket_transport.dart` | **新增**：真实 WSS 传输（`IOWebSocketChannel` + 升级头 + 原始片） |
| `app/test/websocket_transport_test.dart` | **新增** 6 项：真 socket 验升级头 / 原始片 / 一行一帧 / 建连失败 / close 幂等 / 关闭码 |
| `app/lib/core/frame.dart` | **改**：`randomBytes` 用 `SecureRandom.system`（删掉自己包装的 `_SecureSource`） |
| `app/lib/core/sync_client_impl.dart` | **改**：删掉 `_SecureSource`，改用 `frame.dart` 的 `randomBytes` |
| `app/pubspec.yaml` | **改**：加 `web_socket_channel` 并写明选型依据（含"跨平台那个不接受 headers"） |

证据：`flutter test` **138 项全绿**；`dart analyze --fatal-infos` 0 问题；
`dart format --set-exit-if-changed` 0 文件；`verify-platform-boundary.mjs` **74 项**全绿
（`platform/` 是 `branch-whitelist` 规则明确允许碰平台的层）。

**两处变异校验**：① 把 `headers` 改成 `null`（模拟"换回跨平台 connect"）→ 1 项红
（升级头那条）；② `_closeQuietly` 改回 `await sink.close()` → 1 项红，
**红的方式是 20 s 测试超时**（正是"建连失败后卡死"的症状）。

### 附带修掉一个真根因（读包源码找到的）

**建连失败后卡死**：我最初把建连失败的清场写成 `await channel.sink.close(...)`，
而 3 s 的 `connectTimeout` 变成了 30 s 的测试超时。

**根因**（读 `adapter_web_socket_channel.dart` 得到，不是猜的）：
`AdapterWebSocketChannel` 只在 ``webSocketFuture.then(...)`` 里订阅内部流，
而**连不上时那段从不执行** —— 走的是 `onError` 分支，它 `completeError` 之后
只 `addError` + 关闭那个 **local** sink，**从不订阅 foreign sink**。
于是 `sink.close()` 返回的 Future **永远不会完成**。

修法：清场是**礼节**（连接本来就没建起来），`unawaited(...)` 发出去、不等它。
教训写进 `tools.md`：**"库的 Future 永远不完成"这类前提，只能读源码确认，
不能从签名推断** —— 签名上 `Future<void> close()` 看起来完全正常。
