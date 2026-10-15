# Agent Note: 审批探针的靶子必须落在 `workspace-write` 档，且钉在专用工作区

Status: implemented

## Problem

2026-10-13 第三次真机拿到一组自相矛盾的证据：审批探针的 `user/message`
**落盘了**（所以步骤 ④ 的回读判据满足、帧没丢、连接器没拒收），
`session.list` 给的 `running` 是 false，连接诊断一路 `serving`、`send` 全 true，
**但 `approval/asked` 永远不来，手机上永远没有卡**。

当时的两个猜测都被证据推翻或悬空：

- 「靶子会话的工作区目录已不存在」—— 路径查错了，目录在（`docs/cookbook/` 里已撤回）。
- 「靶子会话存的模型不是测试 profile 的渠道」—— 方向可能对，但**解释不了
  为什么连一次 `turn/start` 都没有**：渠道不对的表现是轮次起来后报错，
  不是轮次从不开始。

真正的原因一直躺在靶子会话自己的日志里，只是没人去读那三个字端。

## Decision

靶子会话的权限档必须让审批**真的会被问**。`danger-full-access` 预设带的是
`approval/policy: never`，那一档下审批根本不问，探针直接跑成功。

判据（可机械判定）：按帧解压靶子会话的 `session.v4.jsonl.zstd`，
`permission/preset` = `workspace-write`、`sandbox/mode` = `workspace-write`、
`approval/policy` = `ask` 三个字端都在。少一个就当靶子没准备好，不开跑。

DSH 侧依据（只读参考源码 `D:\sudy\github\deepseek-harness`）：

- 预设表 `packages/interaction/permission-presets/src/index.ts:193-196`：
  `danger-full-access` = `{ sandbox: 'danger-full-access', approval: 'never' }`，
  描述原文 "Full file access **without approval prompts**"。
- 同文件 `:189-192`：`workspace-write` = `{ sandbox: 'workspace-write', approval: 'ask' }`，
  描述原文 "Write inside the workspace and permitted temporary directories;
  **wider retries require approval**"。
- 审批服务 `packages/interaction/user-approval/src/index.ts:139-141`：
  `'never'` auto-rejects every ask **without prompting**；
  `:138` `'ask'` delegates to the composed answerers。
- 写路径 `packages/interaction/permission-presets/src/index.ts:252-276`：
  `/permission <preset>` 是 "the one write path a web client uses"。
  切档会往会话里补一条 `agent/inbox/spliced`
  （"The approval policy changed from ... to ..."），可按它确认切成功了。
- 探针为什么真会越权：`packages/shell/pwsh-sandbox/README.md:141`
  "the ambient temp root is **never granted**"（`workspace-write` 只授予工作区
  与会话私有 temp 子目录 `<temp>\dsh-<hash>`），e2e 用例名就是
  `ambient temp and escape denied`（`tests/acl.e2e.ts:97`）。
  写 `C:/Windows/Temp` 被拒 → 模型带 `sandbox_permissions` 重试 →
  那一下才弹审批（`packages/shell/tool-bash/README.md:70`）。

顺带定掉靶子的另外两条判据，都落在
`app/integration_test/interaction_real_device_test.dart`：

1. **工作区用 `session.list` 的 `cwd` 钉死**。连接器早已把它过线
   （`connector/src/handlers.ts` 的 `session.list`），手机侧此前丢掉了它 ——
   于是"靶子必须在专用工作区"这条判据无从表达，只能满清单挑，
   探针就会落进用户其他项目的会话。手机侧 `SessionSummary.cwd` 补上，
   `null` 就是"不知道"，空串也当没有（空串会让按工作区匹配静默失败）。
2. **渠道只排序、不过滤**。`modelSelection` 投影的初值是
   `{ lastUsed: null, pending: null }`（`packages/api/session-controller/src/model-selection-projection.ts:61`），
   而 `next = pending ?? lastUsed` —— 一条从没跑过轮次的新会话**投影给不出值**，
   连接器于是不发 `model` 字段。把"必须匹配渠道"当成硬判据会让靶子一个都挑不到。
   所以分三档：已知是目标渠道最优、不知道次之、**已知不是目标渠道排到最后**。

## Alternatives considered

1. 让连接器把权限档也过线（新投影 / 新字段），手机侧自己判
   - 最强的理由：判据从"跑之前人工确认"变成"用例自己断言"，
     换一台机器、换一个 profile 都不会再踩；这一步现在是全文唯一没有
     自动化保护的地方。
   - 为何被否：`session.list` 现在不带它，DSH 侧的 `permissions` 投影挂在
     `sessionProjections` 上、按 `Session` 对象读，和 `modelSelection` 是两套接法；
     为一次真机联调扩协议面，收益集中在测试基建而不是产品行为上。
     真值来源（会话日志的三个字端）已经在电脑侧，按帧解压就能验，
     不需要为它改线上契约。**这条留作真缺口，不是"已排除"。**
2. 建一条专用的 `workspace-write` 测试会话，从根上避开默认档
   - 最强的理由：干净，不依赖"记得切档"这个动作。
   - 为何被否：这个 profile **新建会话的默认访问模式就是「完全权限」**
     （Web UI 实测），所以"建一条专用的"并不能避开它，只是把切档这件事
     从"用现成会话"挪到"建完再切"。切档这一步省不掉。
3. 把探针改成读工作区内的文件，让它不需要审批
   - 最强的理由：完全不碰权限档，探针在任何档下都能跑。
   - 为何被否：那就不是"审批转手机"了。这一步验的恰恰是
     **电脑侧等一个决定、手机上能替它做**，不越权就没有决定可做。

## Consequences

- 收益：第三次真机"探针落盘了但卡片没出现"有了单一根因，而且它可机械判定
  （解压会话日志看三个字端），不再是"再跑一次看看"。
  靶子挑选也从"满清单里挑一个顺眼的"变成"钉在工作区 + 排序"，
  顺带不再消耗用户其他项目的会话。
- 代价：**跑之前多一步手工动作**（在靶子会话的访问模式菜单里选
  「工作区内修改」，等价于 `/permission workspace-write`），
  漏了就是又一次三分钟白等。这一步没有自动化保护，是上面 Alternatives 第 1 条
  记下的真缺口。另外 `cwd` 上了线，`session.list` 的行多一个字段 ——
  老连接器不发它，手机侧按 `null` 处理，不猜。
