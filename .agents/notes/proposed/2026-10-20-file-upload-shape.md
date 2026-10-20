# Agent Note: 「上传文件」怎么做 —— 调研结论与开工条件

Status: proposed（未开工；形状已查清，缺的是一个能连真机的回合）

## 为什么单列这一项

用户 2026-10-19：「比人家的上传点击弹框有拍照，图片，上传文件啥的」。
「拍照」「照片」两条已经做真（`implemented/2026-10-20-photo-attachment-pipeline.md`）。
**「上传文件」仍然不做**，而 `＋` 菜单里也没有它 —— 因为还没有通路，
摆上去就是又一排"点了没用"的假入口（第 7 类教训）。

## 已知的形状（不是猜的）

### 手机侧要发的东西

`PromptContentPart` 的文件分支要**回执**，不是字节：

```ts
| { readonly type: 'file'; readonly receiptId: Branded<'file-upload-receipt-id'> }
```
`packages/api/session-controller/src/types.ts:98`。同处 `:88` 的注释说
回执来自"a `uploadFile` call on the same Session"。

### 回执从哪来：**HTTP 路由 + 流式收件**，不是 Remote 方法

- `packages/client/file-upload/src/http-route.ts` —— 有路由实现；
  `:31` 读 `sessionId`、`:35` 读 `name`（都从 query 拿）。
- `packages/client/file-upload/src/index.ts` —— 宿主服务
  `Host file-upload service: streamed intake and Session-owned staged receipts.`
  它注册成 `ctx.fileUploads`（`:64` `super(ctx, 'fileUploads')`），
  暴露的用法在 `session-controller/src/commands.ts` 里能看到：
  - `resolve(agent, receiptId)`（`:338`）
  - `bindPrompt(agent, receiptIds, requestId)`（`:349`）
  - `retirePrompt(agent, source.rpcId)`（`:477`）
  - 暂存的收件按 **Session** 建索引（`index.ts:59`
    `stagedFiles = new WeakMap<Session, Map<FileUploadReceiptId, StagedFileUpload>>()`）
  - 未为这个会话上传过就报 `'File was not uploaded for this session.'`（`commands.ts:574`）

**这决定了实现位置**：不能像图片那样内联进 `session.prompt` —— 文件必须先
"进站"拿到回执。连接器跑在宿主进程里，所以它可以**直接调进程内的
`ctx.fileUploads`**（而不是去 POST 自己的 HTTP 路由）。

### 手机侧还缺什么

1. **连接器新方法**（契约 §5.7 方法表 +1）：形如
   `attachment.upload {sid, name, mediaType?, data(base64)}` → `{receiptId}`；
   内部转成宿主的进站调用，返回回执。**这是唯一需要动契约的地方。**
2. **体积预算**：二进制在线上放大约 **1.78 倍**（JSON base64 ×1.33，
   `box` 的 base64url 再 ×1.33），单帧上限 **8 MiB**
   （`connector/src/transport/codec.ts:53,77`）⇒ 原始字节预算 3 MiB。
   **文件不能像图片那样靠重编码压小** —— 超了只能拒，并把话说清楚。
   若将来需要传大文件，得给这条链路加分片，那是协议变更。
3. **选文件的系统入口**：`ACTION_OPEN_DOCUMENT`（SAF，**不需要权限**），
   走我们已有的自写通道模式（`dsh/photo-picker` 旁边再加一个 method）。
4. **非图片的媒体类型**：图片只认 png/jpeg/webp/gif；文件那一条的 `mediaType`
   由宿主自己判，手机不需要白名单（但要如实把选到的 MIME 带上）。

## 为什么现在不做

它不是"再写几十行"：连接器新方法 + 契约文档 + 宿主进站调用 + 原生选择器 +
体积策略 + 测试，是**一个完整回合**的量。而本轮末尾已经做过一次"开新工程"
的判断 —— 在半截状态提交，正是第 6 类教训（`3979191` 那个残缺提交）的形状。

## 开工时先做的三件事

1. 读 `packages/client/file-upload/src/index.ts` 的**完整**公开面
   （本笔记只确认了 `resolve` / `bindPrompt` / `retirePrompt` 三个用法点，
   没有读到"创建回执"的那个入口 —— 那是开工第一步要找的东西）。
2. 确认回执的作用域：**按 Session**（`WeakMap<Session, …>`），
   所以"在 A 会话上传的文件不能拿去 B 会话发"这件事要在界面上说清。
3. 先把 `attachment.upload` 的方法签名写进
   `docs/subsystems/remote-channel.md`，再动代码（文档先行是本仓纪律）。
