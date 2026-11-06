# 面板细节四条：版本不必联网、全角数字归一、电脑列是已用/上限、错误码翻人话

Status: implemented

## Problem

2026-11-06 真机一次报了四条各自独立的小问题，都发生在电脑侧「手机」面板与中转管理台：

1. 版本卡打开显示「—」；本机版本读 `package.json` 就有，根本不需要联网。
2. 「改电脑数」填 2 被回「要一个 1–100 的整数」。纯逻辑对 `"2"` 通过，真机输入的不是
   ASCII 2 —— 复现确认是 `U+FF12`（全角 `２`），`trim()` 不救。
3. 默认电脑数 2，用户行却显示 `1 / 1`：那一格是 `activeConnectors / connectors`
   （未吊销令牌 / 全部令牌），而表头写「#电脑」，用户读成「已用 / 上限」。
4. 只剩一个管理员时「降为用户」必然 409，页面把 `last-admin` 原样弹出来。

## Decision

1. **版本**：`GET /api/dsh-mobile/status` 增带 `version`（`connectorVersion()`，读
   `package.json`）；面板打开即显示。`/update`（npm 查询）仍只在点「检查更新」时发生。
2. **全角数字**：归一化收在 `Kit.askValue` 的入口（`normalizeDigits`：全角数字、
   小数点、正负号 → ASCII），校验器只看归一后的值；`spec.numeric` 同时设
   `inputmode="numeric"`。校验失败且原文含非 ASCII 时，错误行附带实际字符与码位
   （`２(U+FF12)`），不再只说「要整数」。
3. **电脑列**：`#电脑` 定为「已用 / 上限」：已用 = `activeConnectors`（未吊销、真正
   占名额的令牌），上限 = `maxConnectors ?? auth.defaultMaxConnectors`，只算一次
   （`computerLimit`），「改电脑数」的初值共用。在线数保留在「#在线」列。
4. **错误码**：新增 `relay/src/admin/errors.ts` 的 `ADMIN_ERROR_TEXT` 与
   `adminErrorText()`；页面 `post()` 一律翻译。只剩一个活跃管理员时「降为用户」
   按钮真 `disabled`，并显示「当前只有一个管理员。要降级它，先把另一个账号设为管理员。」

## Alternatives considered

1. **版本：面板打开时调一次 `/update`**
   - 最强的理由：一个接口拿到 `current` 与 `latest`，客户端不用改两处。
   - 为何被否：打开面板就打 npm 网络，离线/内网时代理还会让整卡失败；本机版本是
     本地事实，不该被网络查询绑架。
2. **全角：在校验器里放宽正则（`/^[0-9０-９]+$/`）**
   - 最强的理由：改动最小，只碰「改电脑数」这一处。
   - 为何被否：归一化是**输入边界**的事，放宽正则会让每个调用方各自处理全角；
     而且 `parseInt('２')` 仍是 `NaN`，后面还得再转一次。收在 Kit 入口只做一次。
3. **电脑列：保持「在线 / 已绑定」，只改表头**
   - 最强的理由：不动数据，表头写清就不会误读。
   - 为何被否：用户要看的是"这个账号还能加几台"，在线/已绑定回答不了；上限已经在
     `row.maxConnectors` 里解析好，直接显示即可，不需要第二列。
4. **错误码：服务端直接回中文文案**
   - 最强的理由：页面零翻译，任何客户端都拿到人话。
   - 为何被否：中转协议与 UI 语言从此耦合；同一个码在 CLI、日志、控制台要三种说法时
     会被迫拆开。码是协议，文案是展示层，翻译放页面/共享表。
5. **最后一个管理员：只靠服务端 409，不做前端禁用**
   - 最强的理由：单一判据，前端永远不会与服务端不一致。
   - 为何被否：服务端判据保留，但"每个必败操作都先让用户点一次再弹错"是坏交互；
     前端按同一份 `role/status` 预判并禁用，是提示不是新判据。

## Consequences

- 收益：版本不再依赖网络；全角输入按用户看到的数字理解；电脑列回答"还能加几台"；
  管理台错误不再是协议码。
- 代价：`status` 多一个字段（老客户端忽略即可）；`Kit.askValue` 多一条归一化规则，
  中文数字（「二」）仍会被拒（有意，不做语义解析）；错误码表要随新码维护 ——
  `admin-errors.test.ts` 扫源码里的 `error: '…'`，漏翻会红。
- 证据：`connector/tests/admin-face.test.ts`（status.version）、
  `connector/tests/client-panel.test.ts`（版本行）、
  `relay/tests/ui-kit.test.ts`（全角 `２` 与码位提示）、
  `relay/tests/admin-users-table.test.ts`（已用/上限）、
  `relay/tests/admin-errors.test.ts`（错误码覆盖与按钮禁用）。
