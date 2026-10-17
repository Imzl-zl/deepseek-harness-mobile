# Agent Note: 传输面按"方式"分开关 —— 通道注册表取代一把总开关

Status: implemented

## Problem

2026-10-17 用户原话：「不是有两中方式为啥就一个开关？我是会同时开，同时关，但是
我有时候就想启动一个呢？后面我要是再加新的方式也就一个开关吗？我还明确说了两个
开关吧？」

改前的形状：`connector/src/index.ts` 的 `transportStart`/`transportStop` **一把同时
起停**拨号连接（中转，`transport/relay-link.ts`）与直连监听面
（`transport/listener.ts`）；`ConnectorService.transportRunning()` 一个布尔
（`connection !== null`）；管理面两个端点 `/api/dsh-mobile/transport/{start,stop}`；
UI 一个按钮（`client.js` 状态卡）。加第三种方式（Tailscale、服务器中转）时，
这三处形状都要改。

## Decision

**传输面建模成通道注册表，每个"连接方式"一条通道，各自独立启停。**

1. **注册表**（新模块 `connector/src/transport/channels.ts`）：每条通道 =
   `{id, label, running(), start(), stop(), detail()}`；`createTransportChannels(ports)`
   给出 `channels()` 与 `setChannel(id, running)`。两条通道：`relay`（中转拨号）与
   `direct`（直连监听）。**加一种方式只是往数组加一项** —— 这是"形状不变"的机械保证。
2. **服务面与管理面按注册表枚举**：`ConnectorService` 的 `transportRunning` /
   `startTransport` / `stopTransport` 三个成员**删掉**，换成 `channels()` /
   `setChannel(id, running)`（三者此前没有任何外部消费者，`ctx.provide` 的那个服务面
   只有 caps 被手机读）。管理面 `GET /api/dsh-mobile/transport` 列通道 +
   `POST /api/dsh-mobile/transport/{id}/{start,stop}` 各停各的。
3. **路由按注册表生成，id 不写死在路由表里**：Connection 的 Fetch 路由是**精确路径
   匹配**（`packages/client/connection/src/rpc-host.ts:141` 的
   `fetchRoutes.get(pathname)`），没有路径参数通配，所以 `routes.ts` 在挂载时按
   `deps.channels()` 为每个通道生成一对路由。`tests/admin-face.test.ts` 用**三通道**
   注册表钉住"第三种方式自动多一对路由"。
4. **批量启停不设服务端端点**：用户的常态是同时开 / 同时关，但批量端点会把两条各自
   的成败藏掉一个（`setChannel` 逐个调用才能分别报错）。UI 的顺序调用 + 第一条失败
   原因显示在面板顶部。`listenPort: 0` 时 direct 通道照常列出（detail 写"未配置监听
   端口"），启动即报错 —— 不静默成功。
5. **停一条不碰另一条，这条在代码路径上本来就成立**：两条路各自持独立的 Connection
   对象（`transport/listener.ts` 文件头"为什么不复用拨号那条连接"）。停 relay =
   `relay-link.stop()` 关控制面与它的数据连接；停 direct = `listener.close()` 先停所有
   已接受的连接再关服务端（`tests/listener.test.ts:342` 覆盖）。

**连带效应逐条查清的结论**（写在这里是因为它们决定了"分开关"安不安全）：

- `caps.direct` 由"监听面起没起来"推导（`index.ts` 的 `readCaps(ctx, {direct:
  listener !== null})`）。停 direct ⇒ `caps.direct` 转 false、`endpoint.describe`
  不再报 direct（`endpoints.ts` 的 `listener?.urls` 为空）。但手机**已学到并落盘**
  的 direct 端点不会被删（`mergeEndpoints` 只增不删，`app/lib/core/endpoint.dart:
  164-185`）—— 重连时会先试 direct 失败（一次 10 s 超时）再回落 relay，设置页的
  连接方式显示"直连 拨不通（原因）"（`AppModel.attemptOf` 记账）。**不删端点是对的**：
  直连会恢复，删了反而回不来。
- 停 relay **不碰**已 accepted 的直连；停 direct 由 `listener.close()` 收干净
  （停止接受 + 逐个 stop 已接受的）。
- **presence 不会假掉线**：在线态按连接记账（`presence.ts`，断开即 `offline`），
  停 direct 只关 direct 那些 socket，经 relay 连的设备不受影响；手机会退避重连并
  回落 relay，然后重新 online。管理面看到的离线是**真实**离线。
- **单条重启失败（端口被占）**：`startListener` 抛（`listener.ts:163`），新端点
  catch 后回 400 + 原话（照 `routes.ts` 的 `badRequest`），通道保持"未运行"。
  挂载期仍保持"大声失败"（`start-transport` 步抛 ⇒ 整次挂载回滚）—— 那是配置错误，
  与运行期操作分开，这条没有改。

## Alternatives considered

1. **保留一把总开关，UI 上做成两个按钮调同一个起/停**
   - 最强的理由：服务端零改动；"同时开同时关"的常态体验不变。
   - 为何被否：两个按钮调同一个函数 = 假开关（点"只停直连"中转也跟着断），正是
     用户明确否掉的"点了没反应"。且第三种方式到来时照样要改三处形状。
2. **`POST /api/dsh-mobile/transport` 一个端点，`{id, running}` 放 body**
   - 最强的理由：完全动态，任何通道 id 都不用改路由表；比路径参数更简单。
   - 为何被否：任务书明确 prescribe 了 `/transport/{id}/{start,stop}` 路径形状，
     而它可以在不牺牲动态性的前提下做到（路由按注册表生成）。REST 形状也让
     "起/停是两个动作"在 URL 上可见，与"状态变更只能是 POST"的纪律同源。
3. **服务端批量端点 `POST /transport/{start,stop}`（不带 id）**
   - 最强的理由：一次请求原子地起停全部，UI 少一个循环。
   - 为何被否：两条通道各自的成败必须能**分别**报回界面（直连没配 listenPort 时
     它起不来，而中转照样该起）。批量端点要么把其中一个的失败吞掉，要么发明一套
     "部分成功"的回执形状 —— 都比 UI 的顺序调用复杂。
4. **`listenPort: 0` 时 direct 通道不列出**
   - 最强的理由：列表更干净，只有"存在的方式"才出现。
   - 为何被否：① "可见子集"是第二套真相（UI 显示规则 vs 实际能力），迟早漂移；
     ② 用户问"为啥只有一个开关"时，把没配的那种方式**藏起来**正好答反了他的问题；
     ③ 列出 + detail 写清"未配置监听端口" + 启动报错，三处都在说同一句真话。

## Consequences

- 收益：两个方式两个开关，互不影响；第三种方式到来时注册表加一项，管理面路由与
  UI 开关自动跟上（有测试钉住）；单条通道的失败带原因显示，不再"整把开关假成功"；
  `ConnectorService` 少三个从来没有消费者的成员。
- 代价：
  - 管理面端点从 6 个变成 9 个（4 个按通道生成 + GET 列表），`admin-face.test.ts`
    的端点清单断言随之改。
  - **status 端点不再回 `transportRunning`**：按方式分开关后"整条传输在不在跑"
    没有单一答案，真相在 `GET /transport`。留着它就是第二套会漂移的真相。
  - 停 direct 后，手机已学的 direct 端点仍会先拨一次（10 s 超时）才回落 ——
    这是"端点不删"的已知代价，设置页有"拨不通 + 原因"兜底解释。
  - 挂载期仍是"两条一起起、任一条失败整次挂载回滚"，与运行期的按通道控制
    不对称（配置错误 vs 操作错误的区别，如实记录在此）。
  - **真机抓到的装配顺序 bug（2026-10-17，已修 + 有源码断言）**：管理面原先挂在
    `createTransportChannels` **之前**，而按通道的起停路由是挂载时一次性生成的 ——
    那时的 `channels()` 还是空数组，4 个 POST 路由根本没注册上；GET /transport 是
    基础路由，面板看起来一切正常，点"停止"才 404。修法是把 `mountAdminFace` 移到
    传输 section 之后，并加一条源码顺序断言（`admin-face.test.ts`）。这类"装配接错
    不报错"的故障单测抓不到（deps 是静态替身），与 Dart 侧
    `assembly_invariants_test.dart` 同一条纪律。

## 代码回指

- `connector/src/transport/channels.ts`（注册表本体）
- `connector/src/index.ts`（两条通道的端口、服务面、管理面接线）
- `connector/src/admin/routes.ts`（按通道生成路由）
- `connector/client.js`（每通道一个开关 + 批量入口）
- `connector/tests/transport-channels.test.ts` / `admin-face.test.ts` /
  `client-panel.test.ts`（不变量：互不打扰、未知 id、失败带原因、形状不变）
