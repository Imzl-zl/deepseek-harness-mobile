# Agent Note: 一台手机配多台电脑（可切换）

Status: proposed

## Problem

手机现在只能记住**一台**电脑。这不是"少一个功能"，而是四处单槽假设串在一起，任何一处单独改都只是把冲突推后：

1. **凭据单槽**：`app/lib/platform/pairing_store.dart:162-176` 是一张平铺的键表（12 个 `dsh.*`），
   `load()`（`:204-243`）只回一份 `PairedCredentials?`，`save()`（`:298-331`）把整组键重写，
   `clear()`（`:362`）是 `deleteAll()`。所以配第二台电脑 = **覆盖**第一台（不是"多一台"，是"换一台"）。
2. **设备身份按配对生成**：`app/lib/ui/pairing_page.dart:244` 每次都 `toHex(randomBytes(32))` 当
   master seed，设备密钥由它派生。第二台电脑看到的是**另一台设备**，这不是缺点（见 Decision 3），
   但意味着"多槽"不能靠"共用一份凭据"糊过去。
3. **电脑侧的 UI 状态是单桶**：`host.*` 前缀（`app/lib/data/ui_state.dart:41-62`）装的是"上次看的
   会话、页签、草稿"这些**属于某台电脑**的东西，而切换电脑时会整段清（`app_model.dart:1306-1310`
   → `ui_state.dart:289-295`）。多机切换要的是"切桶"，不是"删除"。
4. **中转侧的连接器 id**：连接器把自己的 `connectorId` 写进 store meta，默认 `'local'`
   （`connector/src/index.ts:144`，只在首次挂载写一次），它进握手 transcript
   （`connector/src/protocol/handshake-frames.ts:17` 的 `…|hello-ack|ephPubB|pcId|nonceB`）与配对上下文
   （`connector/src/pairing.ts:135`）；而中转的控制面 key 是**令牌的 id**
   （`relay/src/server.ts:209-216` → `digest-auth.ts:27-36`），同一个 id 来了新控制面就把旧的
   `detach` + `close(4000,'replaced')`（`relay/src/server.ts:168-182`）。所以"两台电脑、令牌都签成
   `local`、共用一个中转"会互相踢下线，而症状是"另一台莫名其妙断线"。

**已经有雏形的一层**：端点表按"哪台电脑报的"分桶 —— `Endpoint.hostId`（`app/lib/core/endpoint.dart:122`）
= 那台电脑的 Ed25519 公钥，合并时盖上（`app/lib/data/endpoint_book.dart:133-141`）、拨号时排序
（`endpoint.dart:326-340`）。但它**剪掉别的电脑的自动条目**（`endpoint_book.dart:151-158`），
这在"换电脑"语义下是对的，在"可切回"语义下是错的（切回去要重新发现地址）。

## Decision

分四层，判据是"这条状态属于谁"：

1. **凭据层：按 `hostId` 分槽**。`hostId` 沿用端点表那一个判据（`pcSignPubHex`，`endpoint.dart:113`
   已经写明"不用 `pcId`，两块电脑会撞"）。`PairingStore` 的键从 `dsh.<field>` 变成
   `dsh.pairing.<hostId>.<field>`，外加一条 `dsh.pairing.active`（当前那台）。**master seed 不重生成**：
   换槽是换凭据，身份仍按"每次重新配对生成一份"（保持 `pairing_page.dart:244` 的语义）。
   迁移：首次读取时若只有旧平铺键，读成一台槽、写新键、删旧键（一次、幂等；判据"旧键在且新槽空"）。
   `clear()` 从 `deleteAll()` 改成"删这一台的槽"，新加 `clearAll()` 给"撤销所有配对"用。
2. **切换 = 复用现有装配路径**：换 `_credentials` → 拆连接 → `_assemble(credentials)`
   （`app/lib/main.dart:1202` 起）。不新造第二条装配。**切走的电脑不清凭据、不清它的 `host.*`**。
3. **UI 状态按电脑分桶**：`host.<hostId>.<field>`；切换只切桶、不删除。两个连带条件必须同时满足：
   - `pruneSessions`（`app_model.dart:2690-2696` 在**每次**会话清单刷新后调）只许剪**当前桶** ——
     否则切到 B 时会把 A 的页签与草稿按 B 的会话清单剪掉；
   - 本地 sqflite 的条目按 `sid` 存，`sid` 是 16 字节随机（`connector/src/alias.ts:26,60-61`），
     两台电脑撞 `sid` 的概率可忽略，**不分区**；但"某台电脑的缓存被剪"要能归到那台的桶。
4. **一台电脑一个连接器 id，且必须等于它的令牌 id**。判据不靠"改默认值"（老库仍是 `local`），
   而是三条一起：
   - `DEFAULT_CONNECTOR_ID` 改成随机短 id（只影响新装）；
   - 面板「连接」卡**显示** `connectorId`（只读，它是 transcript 的一部分，改它要重新配对）；
   - 连接器拨控制面时带上 `?id=<connectorId>`，中转比对 `caller.id`，不一致**明确拒绝**
     （现在是"静默按令牌 id 记账"，于是 QR 里的 `pcId` 与中转眼里的 id 可以不是一个值）。

## 准入门槛（落地时逐条可机械判定）

1. **两个槽互不影响**：配对 A → 配对 B → A 的 `deviceToken` / `masterSeed` 逐字未变（真值取自
   `PairingStore.load()`，不是测试里手写的常量），且 `active == B`。
2. **迁移幂等**：旧平铺键的存量 ==> 一次迁移后 `load()` 与原值逐字相等，再跑一次不写第二遍
   （判据：写次数，不是"看起来一样"）。
3. **切回来不掉状态**：A 的 `host.*`（last_session / 页签 / 草稿）在"切到 B 再切回 A"之后仍在，
   且 B 的清单刷新**没有**剪掉 A 的键（对 `pruneSessions` 直接断言，不靠界面）。
4. **id 不一致必须响**：`?id=` 与令牌 id 不同时中转回 4xx 并给出可读原因；连接器侧显示为
   "中转拒绝了这个连接器 id"，不是"一直重连"。
5. **端点不再丢**：切到 B 之后 A 报过的自动条目仍在表里（顺序排在 B 之后），切回 A 首拨命中它。
6. **不许新增定时器/重试策略**：切换是用户动作，失败就如实报（宿主没有"自动挑一台电脑"这回事）。

## Alternatives considered

1. **共用一份凭据，靠"同一个 master seed"连多台电脑**
   - 最强的理由：凭据层零改动 —— 一台手机一套身份，哪台电脑都认它；`devId` 两端同一算式
     （`pairing_store.dart:143-158`），共用 seed 在密码学上完全成立。
   - 为何被否：那要求**配对时复用已有 seed**，即改 `pairing_page.dart:244` 的"每次新生成"语义，
     而那条语义是安全属性（换电脑 = 换身份，旧电脑的令牌泄露不牵连新电脑）。而且两台电脑会有
     同一个 `devId`、各自名册一行，任何"这台设备在哪台电脑上"的判断都要再加一维 —— 省下的是存储
     改造，付出的是身份语义。
2. **凭据不分槽，只把 `relayUrl` / 端点表做成"多台电脑的集合"，连接时现选**
   - 最强的理由：手机侧只留一份"设备身份 + 令牌"，切换只是换地址，UI 状态完全不用动。
   - 为何被否：`deviceToken` **是每台电脑签的**（`connector/src/device-publish.ts` 把摘要报名册，
     `relay` 按 `(connectorId, deviceId)` 归户，`relay/src/core.ts:53,106-109`），一份令牌在另一台
     电脑上不认。所以"只换地址"根本连不上，方案不成立。
3. **连接器 id 靠"改默认值"解决冲突**
   - 最强的理由：一行改动，新装的机器天然不撞。
   - 为何被否：老库的 `connectorId` 已经写成 `'local'` 并且**只有首次挂载才写**（`index.ts:398`
     `migrated.connectorId === '' ? DEFAULT` ），改默认值对存量无效；而"令牌 id 与连接器 id 是否
     一致"这件事今天**没有任何一处校验**，改默认值也不会补上。
4. **让中转给每台连接器分配 id（控制面握手时下发）**
   - 最强的理由：id 由唯一的权威（中转）给，两端不可能不一致，运营者也不用记两处。
   - 为何被否：控制面是**单向通知通道**（`relay/src/server.ts:178` 收到任何 message 就
     `close(1008,'control channel is notification only')`），要下发就得改协议形状；而"令牌 id
     就是连接器 id"这条已经在 `digest-auth.ts:27-36` 成立，我们缺的只是**比对**，不是新机制。
5. **多机用"多开 App / 多用户"绕过去**
   - 最强的理由：零代码。
   - 为何被否：安卓上同一包名只能装一个，工作资料里再装一份等于要求用户会用它；而配对凭据在
     `flutter_secure_storage` 的**设备级**密钥库（`pairing_store.dart:180-192`，iOS 那边特意
     `first_unlock_this_device`），复制到另一份也解读不了。

## Consequences

- 收益：一台手机可以记住多台电脑并随时切回；`host.*` 与端点表从"单桶 + 剪枝"变成"分桶 + 保留"，
  两处第一次有了同一个归属维度（`hostId`）；连接器 id 的冲突从"静默踢下线"变成一条可读的拒绝。
- 代价（凭据层）：`PairingStore` 的 12 个常量键变成"前缀 + 槽"，`save/load/clear` 全部要走
  "先算 hostId 再读写"；迁移代码要活一段时间（旧键 → 新槽），而 `clear()` 的语义变了 ——
  "撤销配对"与"忘掉这一台"成了两个动作，界面必须分开表达。
- 代价（UI 状态）：`host.*` 全量键要按 hostId 重排，`pruneSessions` 必须带桶参数 —— 这是本轮
  唯一会碰 `ui_state.dart` 既有迁移逻辑的地方（`docs/subsystems/ui-state.md` 的三类主人不变，
  但 `host.*` 从"一段"变成"一棵"）。
- 代价（中转）：`?id=` 是 relay ↔ connector 的协议面改动，要同步
  `docs/subsystems/connector-and-relay.md` 与 `docs/subsystems/pairing-v2.md`，并新增一条拒绝用例；
  老版本连接器不带 `?id=` 时中转必须继续接受（否则升级即断），"兼容"因此多一条分支 ——
  这条分支的生命周期要在落地时写死（例如下个 minor 删）。
- 代价（产品面）：手机上的"我的电脑"从一个变成列表，`main.dart:578` 那类写死的
  `'我的电脑'` 文案要跟着换成电脑名；连接失败的原因要能说清"是哪一台连不上"。
- 仍未解决（本轮不碰）：**同一台手机在同一台电脑上配两次**仍然走 `replaces`（
  `implemented/2026-10-17-repair-replaces-device-row.md`），与"多台电脑"是两个维度，别混。
