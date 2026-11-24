# dsh-mobile 项目状态

> 快照 + 最近窗口，**覆盖更新**，不做流水追加。历史在 git 与 `.agents/notes/`；
> 更早的窗口在 `memory/archive/`；稳定命令与坑点在 `tools.md`；现状事实在 `docs/`。

## 现在（2026-11-24 · **v0.2.23 / connector 0.1.30 已发版**）

两个产物与插件都已上线：`dsh-mobile-v0.2.23-arm64-v8a.apk` **27.4 MB**
（`armeabi-v7a` 23.9 / `x86_64` 29.8）+ `dsh-mobile-connector-0.1.30.tgz`（206.3 kB，
npm `latest` = **0.1.30**，带 provenance）。Release notes 已手填（写清"出码地址变了、
斜杠命令删了、排序默认按最近更新"）。`ci` 8m18s / `release` 5m3s 全绿。

**发版踩到一次（已修）**：`publish-connector` 被两个标签各触发一次，`concurrency` 让它们
串行，但后跑那个的**前置幂等检查**在 registry 传播完成前就问了一次 ⇒ 去 publish ⇒
`E409 Cannot publish over previously staged version`。npm 上的结果是对的（0.1.30 正常），
只是多一条红 run。判据改成"publish 失败后重查 30 秒，版本已在就算成功"，
见 `implemented/2026-11-24-publish-idempotency-tolerates-registry-lag.md`。

用户这轮报了两件事：「出码为什么不是当前网络的地址和端口？连不上就报错？」与
「新建会话怎么显示的不是第一个、而是后面？」。两件事的根都是**判据读的是旧状态**。

- **出码 = 此刻枚举到的全部局域网 IPv4**（connector）
  - `Listener.urls` 改成 getter：每次读都重新 `os.networkInterfaces()`，端口仍是**实际绑定**端口
    （以前是监听面启动那一刻的快照 ⇒ 换网后码里还是旧 IP）。
  - `endpoints.ts`：`defaultDirectUrls` 与 `isVirtualMac`/`virtual` **整段删除**；默认集合由
    `autoAdvertisedUrls` 一条判据给出 —— `isLanAddress`（`10/8` / `172.16/12` / `192.168/16`）。
    默认路由只在**排序**上起作用（hint 那条排第一），不再决定"报哪条"。
  - 失败文案收成 `noLanAddressReason` 一处四档（未启动 / 没枚举到 / 没有局域网 IPv4 / 被 hide 删空）。
  - 面板「配对新手机」卡新增一行「此刻可拨：…」（数据源 `GET /api/dsh-mobile/connection` 的
    `direct.lanUrls`，与出码同一份判据）；监听在跑但没地址时**不说**"直连未启动"。
  - **本机实测**（FlClash TUN 开着）：候选 5 条 = TUN `198.18.0.1` / VMware `192.168.40.1`、
    `192.168.235.1` / WLAN `192.168.110.80` / 1 条 IPv6 ⇒ 码里 3 条局域网，hint 仍是 TUN。
- **出码只有一个门**：删掉 `/dsh-mobile-pair` 斜杠命令与 `offerForScanning`（用户原话
  「谁在会话生成？我肯定在插件界面啊」）。它曾绕过 `planPairingOffer`，同一件事两个结论。
- **会话组内顺序 = 最近更新（默认）/ 手动**（app）
  - `model/session_order.dart`（新）+ `device.session_order`；`bucketSessionsByWorkspace` 增
    `order` / `updatedAtOf` 两个**必填**参数（漏传编译不过）；blank 段仍钉组首。
  - 用户一动顺序（拖动落点 / 上移下移）**自动切 `manual`**（唯一一处在 `AppModel.moveSession`）；
    设置页「会话排序」一行可切回「最近更新」。
  - `data/device_prefs.dart`（新）：七项 `device.*` 偏好的唯一持有者与写入口（值 + getter +
    setter + `_persist`），`AppModel` 只留 passthrough。**尺寸棘轮反而降了**：
    `app_model.dart` 5350 → **5250**、`AppModel` 179 → **173** 个方法。
- **配对阶段把码里的 `lan` 全部一起拨**（app）：先通先用、其余含握手中的当场收掉；全灭只给
  一句「局域网不通（试了 N 个地址，是否同一 Wi-Fi？）」，明细进 `debugPrint('[pair] …')`。
- **门禁**：connector **894** · app **1997**（`flutter analyze` 0）· boundary **988** ·
  size PASS（预算下调）· protocol 454/26/49。变异校验 4 次：冻结 `urls` ⇒ 现取 1 红；
  只报一条地址 ⇒ 8 红；并行改串行 ⇒ 1 红；排序改回账本序 ⇒ 5 红；删切档那行 ⇒ 1 红。
- **没做**：真机没验（要重扫码 + 换网才能看全两条）；插件面板在真 React 里的落位仍只到隔离
  实例接口层。用户侧的升级路径：插件 `npm i -g dsh-mobile-connector@0.1.30` 后重启 DSH，
  手机装 v0.2.23 的 APK（应用内更新只对 v0.2.21+ 有效）。

## 上一窗口（2026-11-22 · v0.2.22 / connector 0.1.29）

- 子智能体目录四态（`never/loading/ready/error` + `panelVisible` 触发 + 在飞键 `(key,sid)`）；
  命令面 = 宿主命令表（删 `MOBILE_COMMANDS` 白名单）；`/` 菜单补技能段（`skill.catalog` +
  `caps.skills`，技能不是命令）。踩到一次两个标签并发 publish ⇒ `concurrency` 串行化。
- 用户报的「新建会话闪一下回旧会话」**未复现**，仍缺带 RPC 轨迹的诊断包。

## 下一步

1. **真机验收**（v0.2.23 + 0.1.30）：清数据全新配对（无中转、TUN 开着）→ 通；换 WiFi 后
   不重启连接器重出码 → 码里是新地址；新建会话发一句 → 仍在组首。
2. **看防火墙**：若新码地址对、手机仍「连接不上」，下一站是 Windows 防火墙/网络配置文件
   （8790 入站是否放行、网络是否被判成"公用"）—— 这一条这次没验，别先怀疑地址。
3. 数据面收敛剩余项、多设备并发准入真机复验、状态语义 A–H 四条、改动卡/差异真机复验
   （见上一版 memory 的清单，未变）。
4. 大改后巡检 `docs/` 与代码漂移（本轮已清 4 处：`remote-channel.md` §5.7/§12.1、
   `pairing-v2.md` §3、`session-ordering.md` §1.5、`direct-p2p.md`、`connector-and-relay.md`）。

## 门禁（改代码后必须全绿，项数以 `tools.md` 为准）

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | 通道协议（三条都全绿） |
| `node app/tools/verify-platform-boundary.mjs` | 多端边界（规则自检 + 全量扫描） |
| `node app/tools/verify-rpc-single-caller.mjs` | `app/lib`（`wire/` 外）零 `call<` |
| `node mock/proto/tools/verify-{icons.cjs,tool-paths.mjs}` | 图标集 / 24 个工具脚本无硬编码盘符 |
| `cd app && flutter test` | 手机端全量（约 2 分钟） |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format` | 各 0 |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + 全量 |
| `cd relay && pnpm typecheck && node --test` | 类型 + 全量 |

**改断言必须做一次变异校验**（故意破坏不变量，确认恰好那几条红，条数写进提交）。
**尺寸棘轮只降不升**（`app/tools/verify-size.mjs`）：要加东西先搬，不要抬预算。

## 八条教训

1. **投影信封**：`session.projections` 回 `{kind, asOfSeq, values}`，手机要 `values`。
2. **模型目录是对象**（`{default, routableProviders, groups, failures}`）不是数组。
3. `session/select-model` **没有"不能写"约束**：别把测试纪律升成产品约束。
4. **"空"有两种表达**：`items.isEmpty` 漏了 `OtherItem`；`usage == null` 漏了"字段齐全但全零"。
5. **判据要能区分"没命中"与"没实现"**：先一行 `debugPrint` 确认回调跑了，再怀疑手势。
6. **一个功能一次提交完整**；**生产路径上的假数据最容易漏**（不报错、不空屏，只是名字/数字是编的）。
7. **线上预算按帧算**：二进制 `N` → JSON base64 → box 再 base64url ≈ `1.78N`。
8. **判据必须读现况，不读缓存**：这轮两个 bug（出码地址 / 列表顺序）都是"读上次的状态"。

## 真机联调的成本纪律

- 隔离实例：`$env:DSH_HOME='D:\tmp\dsh-mobile-home'` + `dsh --profile dsh-mobile-test`；`--profile`
  只隔进程/插件/端口，**凭据/会话/存储共用** → 跑之前报轮次并拿到准。装 App 用 `adb install -r`
  （`flutter install` 会先卸载，配对凭据在私有目录里）。
- 出码走 `POST /api/dsh-mobile/pair`（命令没了）；二维码是 `svg` 字段。

## 仍未注意就会翻车

- **改源码只用编辑工具**（shell 替换静默出错）；`dart format` 会重排文件，之后再编辑要重读。
- **同一件事只有一处判据**（出码 / 重建哪条通道 / 面板读什么）：已有同名模块 + 回归用例，
  别在 `index.ts` 再写；坑点见 `tools.md`。

## 已知缺口（仍在）

- 计划审查卡手机上不存在（**有意**，契约 §15）；连接卡保存后只轮询 6 秒判连上；「清空全部
  记录」会把还在用的离线设备一起删；旧历史合并载荷修不回来（要 `session.page` 重放，未做）。

## 已落地索引（近期，完整见 `.agents/notes/implemented/`）

- 2026-11-24 出码地址现取 + 全给 / 出码只留面板 / 会话排序两档 / 配对并行拨
- 2026-11-20..22 更新下载通道 / 命令面=宿主 / 技能段 / 子智能体四态
- 2026-11-13..19 出码只写活着的路、配对新机先探两条、blank 钉组首
- 2026-10-29..11-12 连接卡、端点剪枝、装配回归网、轨迹/目标条、a11y 四批、尺寸棘轮
