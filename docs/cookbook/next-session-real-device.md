# 新会话提示词:做出第一次真机连通(配对 v2)

> 复制下面 `---` 之间的全部内容到新会话。

---

## 任务

把**手机侧 Dart 实现**与**电脑侧真装配**接起来,做出第一次真机连通:
**扫码 → 两段配对 → 连上 → 发一句 / 回一句**。

## 已经做好的(不要重做)

协议与三侧实现都已落地,**门禁全绿**:

| 门禁 | 数字 |
|---|---|
| `node protocol/verify-fixtures.mjs` / `loopback` / `vectors` | 486 / 26 / 49 |
| `node app/tools/verify-platform-boundary.mjs` | 182 |
| `cd app; flutter test` | **340** |
| `cd connector; pnpm exec tsc --noEmit && pnpm build && pnpm test` | **301** |
| `cd relay; pnpm typecheck && pnpm test` | **72** |

**电脑侧那条链已经有端到端证据**:`connector/tests/pairing-e2e.test.ts` 用真中转 + 真握手 +
真 AEAD 跑通了「握手不授权 → 确认才登记 → 令牌只在密文里 → 换票后双向 AEAD → 多设备互不干扰 →
I7 中转换进程后凭名册恢复」。所以**不要**再去改协议或重跑那条用例来"证明"什么。

**要做的是互操作**:手机上那份独立实现能不能跟同一套电脑侧装配对上。

## 前置与起服务(照抄,别改端口)

```powershell
# 1) 中转(改过 relay/src/** 就必须重启它;它没有构建步骤)
cd relay; node src/main.ts --config relay.config.json

# 2) 电脑侧 profile(它自带一个 web UI,端口与用户的 GUI 错开)
dsh --profile dsh-mobile-test --no-open --port 8099

# 3) 手机侧:反向端口 + 屏幕常亮(屏幕灭掉 = 引擎暂停 = 用例永远跑不完且没有原因)
adb reverse tcp:8787 tcp:8787
adb shell svc power stayon true

# 4) 出码(在电脑侧的会话里执行),把打印出的那段 JSON 存进 $qr
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($qr))
cd app
flutter test integration_test/channel_e2e_test.dart -d <真机序列号> `
  --dart-define=DSH_QR_PAYLOAD_B64=$b64
```

**改过 `connector/src/**` 必须先 `pnpm build`**(真加载的是产物 `lib/index.js`)。
**重启 profile 前确认没有旧进程残留** —— 两个进程抢同一身份会让中转不停"新连接顶掉旧连接",
看起来像链路故障,其实是自己踩自己。

## 验收判据

1. `integration_test/channel_e2e_test.dart` **绿**(它真的走 HTTP 换票、真的 WS 升级、
   真的两段配对,并验证设备令牌落进 Keystore)。
2. 手机界面能连上(**不是**"重启后的第一次成功" —— 判据要包含**连续重连 N 次**都成立),
   点开会话、**发一句、回一句**。

做不到就如实说卡在哪一步、证据是什么(命令 + 输出),**不要用"应该可以"代替证据**。

## 上来先查这三处已知缺口(可能就是卡点)

1. **`--issue-token device` 签出的令牌永远换不到票(403)** —— 设备凭据面在**名册**,
   而那个 CLI 往配置摘要表里写 `{kind:'device'}`。真机若卡在 401/403,先看这里。
2. **首配的匿名限流桶是单一全局桶**:刷得快会让所有新设备换票 429(约 10 s 恢复)。
3. `stats.devices` 实为通道数(观测值,低危)。

## 门禁(每次改完都要全绿)

```powershell
node protocol/verify-fixtures.mjs            # 486 项
node protocol/verify-loopback.mjs            # 26 项
node protocol/verify-vectors.mjs             # 49 项
node app/tools/verify-platform-boundary.mjs  # 182 项
node mock/proto/tools/verify-icons.cjs; node mock/proto/tools/verify-tool-paths.mjs
cd connector; pnpm exec tsc --noEmit; pnpm build; pnpm test
cd relay; pnpm typecheck; pnpm test
cd app; flutter test; dart analyze --fatal-infos lib test integration_test
cd app; dart format --output=none --set-exit-if-changed lib test integration_test
```

**改断言必须做一次变异校验**(改坏实现确认变红)。**绝不允许削弱测试让它变绿**。

## 踩过的坑(别再踩)

1. **二维码载荷走 base64 进 `--dart-define`**:它是满是双引号的 JSON,PowerShell 会吃掉引号,
   App 收到 `{v:2,relay:ws://…}` 并报"不是合法 JSON"(那是输入坏,看起来却一样)。
2. **明文放行有两处**:Android 的 `network_security_config.xml`(debug)与 Dart 侧的
   `PairingPage.allowInsecureLocal`(装配点按 `kDebugMode` 传)。只开一处会出现"码认了、票换不了"。
3. **配对是两段**:「连接电脑」只建受限通道,**要点「确认并配对」才会把秘密发出去**;
   少了那一次点击,`onPaired` 永远不回调,看起来像"配对没成功"。
4. **改源码只用编辑工具**,不要用 shell 字符串替换(本仓被这个坑写空过源文件两次)。
   提交前必看 `git status` 完整清单,重点看**意外的文件**。
5. **用 `adb shell input tap` 点 Flutter 界面不可靠**(不暴露 a11y 树);要验交互就写 `integration_test`。
6. `flutter test integration_test/` 会先卸载再装测试包,跑完把正式包装回去。
7. 中转的拒绝**默认不打日志**(要 `DSH_RELAY_DEBUG=1`)。

## 相关文档(改之前先读)

- `docs/subsystems/pairing-v2.md` —— 配对 v2 的不变量(唯一规格源)
- `docs/subsystems/remote-channel.md` §3(帧形状)/ §4.1(握手)/ §12.1(配对全流程)
- `docs/subsystems/connector-and-relay.md` §1.6(连接粒度:每设备一条数据连接)
- `AGENTS.md` §6(项目特定硬规则)+ 各子目录 `AGENTS.md`

非平凡改动**必须留决策笔记**(`.agents/notes/`),与代码**同批提交**。
