# Agent Note: `session.prompt` —— 第一个写方法，两个"键"的位置要分清

Status: implemented

## Problem

`session.prompt` 是第一个**写方法**，也是幂等管道（I8）第一个真正的用户。三处必须在动手前定清楚：

1. **幂等键在哪一层？** 契约 §5.6 说写操作都带 `requestId`（请求顶层），而方法面的
   `IDEMPOTENT_METHODS` 判据也是按它来的。
2. **谁负责去重？** 我们的两阶段表（桥接自建）与 DSH 自己的 `rpcId` 判据各管一段。
3. **内容与错误码**：`content` 是内联文本/图片；DSH 会回 `session/attachment-invalid` 这类
   **不在我们封闭错误码表里**的码 —— 该不该给它开新码？

## Decision

- **`requestId` 从 `DispatchContext` 取，不从 `params` 取**。它在请求顶层（`decodeRequest` 读的就是顶层），
  而方法面已经把它放进上下文（`methods.ts:108-112`）。写成 `requireString(params, 'requestId')`
  是**残留的坏形状**：真机上表现为"每次写操作都 `protocol/bad-frame`"，而这轮 e2e 正好抓到它
  （`promptBox.count` 是 0，说明请求压根没到端口）。留一条兜底校验（缺键即 `bad-frame`），
  因为 handler 也会被单测直接调用。
- **内容只做形状校验**（非空数组、每项是带 `type` 的对象）：文本还是图片、图片能不能被当前模型接受
  是 DSH 的判据。**不**替它判，也不给它的错误码开新码 —— 我们的表是封闭的，那些错误归 `internal`，
  但**消息原样透传**（`methods.ts:181`），所以用户照样看得到"模型不支持图片输入"这种原因。
- **两层去重各管一段**，且都保留：我们的两阶段表管"桥接侧不重复执行"，
  DSH 的 `hasPromptRequest`（会扫会话事件日志，`commands.ts:602-614`）管"同一条消息不落两次"。
  前者让重发**便宜**（命中即回上次结果），后者让重发**安全**（下游认得出重复）。
- `mode` 只接受 `queue` / `steer`，默认 `queue`。

准入门槛（可机械判定）：

1. **同一个 `requestId` 发两次（真方法面 + 真幂等）→ 底层端口只被调用一次**，第二个应答是重放
   （内容相同、`id` 是这一次的）。
2. `requestId` 缺失 / 空 → `bad-frame`；`content` 非数组 / 空 / 元素没有 `type` → `bad-frame`；
   `mode` 不在两个取值里 → `bad-frame`；`sid` 未知 → `session/not-found`。
3. `mode` 与内容原样递给端口（`('dsh-1', requestId, content, mode)`）。

## Alternatives considered

1. 给 DSH 的错误码在我们表里开新码（例如 `session/attachment-invalid`）
   - 最强的理由：手机能按码显示精确文案，不必解析消息字符串。
   - 为何被否：那要把 DSH 的一整张错误表搬进我们的契约并跟着它漂移（§3.1 现在是封闭的、
     每个码都有明确的客户端行为）。而"消息原样透传"已经够手机显示原因；
     真机上如果发现某个码需要**分支行为**（不只是文案），再为它一个人开码，那时判据清楚得多。
2. 在 handler 里自己判"这个模型收不收图片"
   - 最强的理由：能提前给出更友好的错误，不必等 DSH 拒。
   - 为何被否：那要复述 DSH 的模型能力判据（`model.inputModalities`、`llm.resolveModelInfo`），
     又是一处会漂移的副本。DSH 已经在 `prompt` 里做了这件事（`commands.ts` 的 `admit`）。
