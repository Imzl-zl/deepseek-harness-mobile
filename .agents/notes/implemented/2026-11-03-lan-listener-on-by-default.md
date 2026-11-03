# Agent Note: 局域网直连默认就开（推翻 10-31 的"默认不监听"）

Status: implemented

## Problem

2026-11-03 用户原话：「局域网的也能启动啊」。

现场：`listenPort` 默认 `0`，直连通道挂在「未运行 · 未配置监听端口（listenPort: 0）」，
点「启动」直接回 `DIRECT_UNCONFIGURED`。也就是**装完插件后这条路默认不存在**，
必须先想清楚"要开直连"、再填一个端口、再点启动。

这与本次的主线（装完即用、不要改配置）冲突：中转要令牌、直连要端口，两条路都要配置，
那"开箱即用"就只剩下"面板能打开"。

## Decision

`listenPort` 默认 **8790**、`listenHost` 默认 **0.0.0.0**；没配时由
`listenPortOrDefault()` / `listenHostOrDefault()` 在**读取处**兜底（与 `relayUrl` 同一条教训：
schema 默认值到不了运行时的 volatile 引用）。

- **显式 `0` 仍然是"关"**：卡片里的「停用直连」写的就是 `0`，这一格反了就关不掉。
- **端口被占不再拖垮挂载**：`transport/startup.ts` 的 `startDirect` 失败只留声
  （`onDirectTolerated` → `directError` →「连接」卡 `detail`）。默认端口一开，两台 DSH
  就会抢 8790，而"抢不到口"正是最需要打开面板改端口的时刻。

## Alternatives considered

1. **保持默认关，只让「启动」按钮在没填端口时用 8790 起一次**
   - 最强的理由：不改变"默认敞开的端口操作者不会预期"这条既有判断，风险最小。
   - 为何被否：那仍然要用户点一次；而重启后又回到关着的状态 —— 用户看到的是"上次明明开了"。
2. **默认开，但监听地址仍留 127.0.0.1**
   - 最强的理由：不暴露到网络。
   - 为何被否：手机连不进来，等于没开 —— 这是"看起来配了、实际没用"的假旋钮。
3. **默认开且端口写死、不允许改**
   - 最强的理由：最省事。
   - 为何被否：端口冲突是真实存在的（本机就同时跑着测试 profile 的 8790）。

## Consequences

- 收益：装完插件两条路都自己起来 —— 中转（有令牌就通）、直连（0.0.0.0:8790）。
- 代价：**每台机器多一个监听端口**。它不是开放的门（连接要过设备身份握手，未配对的对端
  握不上手），但确实是开着的窗；Windows 首次运行会弹防火墙授权。
- 代价：两台 DSH 在同一台机器上会抢 8790 —— 后起的那台直连停在未运行、原因写在卡片上，
  面板照常可用。
- 代价：推翻了 `tests/listener-config.test.ts` 原来那条"默认敞开是唯一不可接受的方向"；
  用例连同注释一起改成新方向，理由写在那里。

## 判据

- `pnpm test` 831 项全绿；`tsc --noEmit` 0。
- **隔离实例实测（真进程、零配置、0.1.14）**：
  - OS 层 `Get-NetTCPConnection -State Listen -LocalPort 8790` → `0.0.0.0:8790`；
  - `GET /api/dsh-mobile/status` → `caps.direct = true`；
  - `GET /api/dsh-mobile/connection` → `value.listenPort = 8790`，`direct.running = true`；
  - `GET /api/dsh-mobile/transport` → 直连通道 `running: true`，`detail: "0.0.0.0:8790"`。

## 代码入口回指

- `connector/src/config.ts` 的 `DEFAULT_LISTEN_PORT` / `DEFAULT_LISTEN_HOST` 与两个 `*OrDefault`。
- `connector/src/index.ts` 的 `listenPortInUse()` / `listenHostInUse()` 与 `directError`。
- `connector/src/transport/startup.ts` 的 `onDirectTolerated`。
- `connector/tests/listener-config.test.ts`、`tests/transport-startup.test.ts`。