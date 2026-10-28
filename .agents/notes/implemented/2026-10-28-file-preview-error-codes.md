# 文件预览的四类失败：宿主码抬过线，手机按码换文案

- 日期：2026-10-28
- 状态：implemented

## Problem

真机上"有的文件点得开、有的打不开"，而打不开时显示的是一句**中英混排**：

```text
读取失败：not a text file
```

三个独立的事实叠成了这个现象：

1. 文件预览只支持**文本**（`file.read` 按行分页，`workspace-files` 的读法）；
   二进制、超大页、目录、不存在的路径，宿主各回一个码
   （`workspace-file/not-text` / `-too-large` / `-not-regular-file` / `-not-found`）。
2. 桌面按**码**换文案与动作（`packages/client/ui-sidebar-documentpreview/src/client/failure-line.ts:24-56`、
   `locales.ts:27-31`），手机照搬的前提是码能过线。
3. 我们的连接器 `ERROR_TABLE` 里**没有这四个码**，且适配层没抬错误：
   `protocol/methods.ts:361-370` 只保留 `ProtocolError` 自己的码，其余一律归 `internal`。
   于是手机拿到 `internal` + 宿主的英文原话，只能原样拼进中文句子。

## Decision

四处一起改（少一处都会回到"英文尾巴"）：

1. `connector/src/protocol/errors.ts`：`ERROR_TABLE` 增加四个码（`disable-and-annotate`）。
   原先散在 `dsh/workspaces.ts` / `dsh/jobs.ts` 的"宿主码 → 协议错误"逻辑收成
   **一处** `asProtocolError` / `errorCodeOf`（`dsh/jobs.ts` 只留自己的 `job/not-found` 规则）。
2. `connector/src/dsh/files.ts`：`list` / `read` 走 `asProtocolError`。
3. `app/lib/core/errors.dart`：`ErrorCode` 增加同名字符串的四个码（封闭表仍与连接器逐字一致，
   由 `connector/tests/error-table-parity.test.ts` 断言），`docs/subsystems/remote-channel.md` §3.1 同步。
4. `app/lib/model/file_failure.dart`：**按码换文案**（照桌面 zh 文案）；
   其它码保留 `读取失败：{宿主原文}`（桌面 `error.unavailable` 同一句）。

手机没有"用外部程序打开"这条能力（桌面靠 `ui-open-in-app`），
所以对"不是文本 / 太大"只说不能预览，**不假装能打开**。

## Alternatives considered

- **只在 Dart 侧按 `error.message` 猜码**（匹配 `not a text file` 之类的英文）。
  最强理由：不动连接器、不动错误表，改动面最小。
  被否：这是把英文文案当协议用。宿主随时可以改措辞，而我们会在**看起来成功**的情况下
  退回英文原文 —— 判据必须是我们已经有的东西（码）。
- **把这四个码归成 `disable`（能力位语义）而不是 `disable-and-annotate`**。
  最强理由：它读起来像"这台电脑/这个文件不支持"，和"能力位缺失"是同一类。
  被否：能力位是**部署级**（这台电脑有没有文件服务），这四个是**单个文件级**；
  混成 `disable` 会把"这个文件看不了"升级成"文件功能没了"，用户不会再点下一个文件。
- **在连接器里把 `not-text` 翻译成中文再发**。
  最强理由：手机少一层映射，任何客户端都直接可读。
  被否：连接器不是本地化层（桌面也是客户端按码翻译）；把文案写进协议会让
  `zh` 变成唯一的协议语言，且与 §3.1"码 + 客户端行为"的表结构冲突。

## Consequences

收益：四类"读得懂但打不开"的文件在手机上说中文结论；不再出现 `读取失败：<english>`；
`asProtocolError` 收成一处后，将来再加文件面错误码只需改表。

代价：

1. 封闭表从 31 个码变成 35 个（`flow.test.ts` 的数量断言是有意的，已同步更新）。
2. `too-large` 的桌面文案带 `{limit}`（`humanBytes(details.limit)`），而我们的
   `ProtocolException` **不携带 details**，所以手机只说"超过上限"，不显示具体字节数。
   要显示就得给通道加 details 字段 —— 那是一次协议扩展，不在本次范围。
3. `not-text` 在桌面上还提供"用外部程序打开"（`emptyFailureRecourse → 'open'`），
   手机没有这条路；将来要做需要一条新的宿主方法（`ui-open-in-app` 的对等物），属于扩协议。
