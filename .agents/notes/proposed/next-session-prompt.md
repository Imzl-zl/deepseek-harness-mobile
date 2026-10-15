# 新会话提示词:继续移动端界面接线

> 用法:新开一个会话,把下面「提示词」整段贴进去。它会先自己求证文档,再开工。

## 提示词(整段复制)

```
我们在做 dsh-mobile —— DSH 的移动端客户端。核心原则一句话:
**DSH Web 上能看的每一个面,背后都有 @Remote 方法或会话投影;接线是照形状透传,不是重新设计。**

第一步(必做,别跳):读下面四个文件,并且**核对里面引用的 DSH 源码行号是否仍指向该内容**
(行号会漂移;对不上就改正,不要照抄):

1. `docs/mobile-surface-roadmap.md` —— 不变量、三扇门、全景清单、接线顺序、
   单方法接线清单(11 步)、已知陷阱。**这是主计划。**
2. `docs/subsystems/remote-channel.md` §5.7 / §5.8 / §9 —— 方法表、DSH 依据、未实现清单。
3. `memory.md` + `tools.md` —— 当前门禁基线、计数、踩过的坑。
4. `.agents/notes/proposed/2026-10-15-phone-surface-inventory.md` —— 哪些面为什么做/不做。

然后按路线图 §3 的顺序接下一个面,**当前是第 1 项:权限切换**:

- 读:`permissions` 投影(已经能通过 `session.projections` 拿到,见
  `app/lib/data/app_model.dart` 的 `_projections`);
- 写:`ctx.commands.execute('/permission <档位>')`,DSH 依据
  `packages/interaction/commands/src/index.ts:263` 的 `@Remote('execute')`
  —— **先读 DSH 源码确认 `/permission` 这个命令的真实名字与参数形状,不要凭猜**;
  也先看 `packages/interaction/permission-presets/src/index.ts:180` 的
  `@Remote('catalog')` 能不能直接给档位清单(能就走它,更直)。

硬规则(违反任何一条就是乱猜):

1. **Web 调哪个,手机就调哪个。** 拿不准先读 `packages/client/ui-*/src/client/*.ts`
   里 Web 的调用点。找不到就写「未找到」,禁止"通常如此"。
2. **形状逐字透传**:不挑字段、不改名、不补默认值、不猜默认值。
3. **真数据接上的同一批里删掉对应的假数据**,不留兜底。
4. 引用 DSH 行为给 `packages/...:行号`。

每个方法照路线图 §4 的 11 步走完(适配层 → handler → 能力位 → 封闭集 → 契约 →
App 数据层 → App UI → 测试 → 四处计数 → 门禁),别跳步。已知陷阱看路线图 §5
(连字符方法名、Dart null-aware element、注释里写 ctx.<键>、测试替身漏成员、
断言完整调用序列、integration_test 不在 flutter test 里……)。

做完自己跑门禁并贴真实输出:
`cd connector; pnpm exec tsc --noEmit && pnpm build && pnpm test`
`cd app; flutter test && dart analyze --fatal-infos lib test integration_test`
`node protocol/verify-fixtures.mjs && node protocol/verify-loopback.mjs && node protocol/verify-vectors.mjs`
`node app/tools/verify-platform-boundary.mjs`

非平凡改动留决策笔记到 `.agents/notes/implemented/`,代码与笔记同批;
被约束的代码入口留一行注释回指笔记。
```

## 附:当前基线(2026-10-15,供核对,若与文档冲突以文档为准)

- 方法面 **15/24**(契约封闭集 24;差额是契约列了没实现的)。
- 门禁:connector **389** / app **464** / relay **75** / 平台边界 **204** /
  protocol 486·26·49 / 原型图标与路径门禁,全绿。
- 服务状态:relay 在 `8787`(可能已退,起来再跑);DSH test profile 在 `8099`(已停);
  `adb devices` 当时为空;App 装在 `d61cf622` 但**无配对凭据**。
- 假数据已清光(文件面板 diff / 轨迹 / 子智能体 / 模型 picker / 统计条);
  保留的只有用户显式触发的「看示例数据」与「演示:接管输入栏」。
