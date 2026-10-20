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

### 回执从哪来：**进程内有现成入口**（2026-10-20 查清）

- `packages/client/file-upload/src/index.ts:105`：
  ```ts
  @Remote('upload')
  upload(agent: Agent, request: EncodedFileUploadRequest, signal: AbortSignal): Promise<FileUploadValue>
  ```
  **挂着 `@Remote('upload')`** —— 它本身就是个 Remote 方法。
- 同文件 `:118` 还有 `uploadStream({sessionId, data: AsyncIterable<Uint8Array>, signal?, name?})`
  —— **自己按 `sessionId` 解析 agent**（`:126` `resolveAgent`），调用方不需要 Agent。
- 载荷与返回值（`file-upload/src/types.ts`）：
  ```ts
  interface EncodedFileUploadRequest { readonly data: string /* canonical base64 */; readonly name?: string }
  interface FileUploadValue { readonly receiptId: FileUploadReceiptId; readonly file: FileAttachmentRef }
  ```
  **`{data, name?}` 与我们手机侧已有的 base64 完全对得上**，返回里就有 `receiptId`。

- 回执的使用：`session-controller/src/commands.ts`
  - `resolve(agent, receiptId)`（`:338`）
  - `bindPrompt(agent, receiptIds, requestId)`（`:349`）
  - `retirePrompt(agent, source.rpcId)`（`:477`）
  - 暂存按 **Session** 建索引（`file-upload/src/index.ts:59` 的
    `WeakMap<Session, Map<FileUploadReceiptId, StagedFileUpload>>`）
  - 没为这个会话上传过就报 `'File was not uploaded for this session.'`（`commands.ts:574`）

**所以连接器只要一段薄封装**：`ctx.get('fileUploads')` →
`uploadStream({sessionId, data, name})` → 返回 `{receiptId}`。
不需要去 POST 自己的 HTTP 路由（`http-route.ts` 那条是给浏览器用的）。

### 连接器侧的接线点（已定位，避免开工时重新摸）

1. `dsh/caps.ts` 的 `OPTIONAL_SERVICES` **必须加 `'fileUploads'`** ——
   那份清单是**服务键的登记处**，`tests/layering.test.ts` 的
   `service-key-registered` 会盯（拼错一个键就是永远 false 的能力位）。
2. handler 不直接碰 DSH 服务，而是经 `HandlerDeps`（`handlers.ts:56`）里的端口
   （现有先例：`SessionsPort` 在 `connection-scope.ts:55`）。
   所以要么加 `FilesPort`，要么把上传能力挂到已有的某个端口上 —— **开工先定这个**。
3. 契约文档先行：`docs/subsystems/remote-channel.md` §5.7 方法表 +1 行，
   再动代码（本仓纪律：文档是基线）。

### 手机侧还缺什么

1. **体积预算**：二进制在线上放大约 **1.78 倍**（JSON base64 ×1.33，
   `box` 的 base64url 再 ×1.33），单帧上限 **8 MiB**
   （`connector/src/transport/codec.ts:53,77`）⇒ 原始字节预算 3 MiB。
   **文件不能像图片那样靠重编码压小**（重编码会毁掉非图片文件）——
   超了只能拒，并把话说清楚。传大文件需要给这条链路加分片，那是协议变更。
2. **选文件的系统入口**：`ACTION_OPEN_DOCUMENT`（SAF，**不需要权限**），
   在 `dsh/photo-picker` 旁边再加一个 method（同一个自写通道的模式）。
3. **非图片的媒体类型**：图片只认 png/jpeg/webp/gif；文件那一条的 `mediaType`
   由宿主自己判，手机不需要白名单（但要把选到的 MIME 如实带上）。
4. **界面**：`PendingAttachment` 现在只剩图片一种载荷，要加 file 变体
   （`{type:'file', receiptId}`），并且**上传是异步的** —— 需要一个"上传中/失败"
   的状态，不能像图片那样选完就完事。

## 为什么现在不做

它不是"再写几十行"：连接器端口 + 契约文档 + handler + 宿主调用 + 原生选择器 +
上传状态与界面 + 两边的测试，是**两三个完整回合**的量。
本轮末尾已经判断过一次"不在长会话尾巴上开新工程" ——
在半截状态提交，正是第 6 类教训（`3979191` 那个残缺提交）的形状。

## 参考实现（2026-10-20 查证，rikkahub）

D:\sudy\github\rikkahub 的附件管线是**三步**，与我们该走的三步同构：

| 步骤 | rikkahub | 我们 |
|---|---|---|
| 选 | `ActivityResultContracts.OpenDocument()`（SAF，**不申请权限**） | 同（`ACTION_OPEN_DOCUMENT`） |
| 落地 | `FilesManager.saveManagedFromUri(folder, uri, displayName, mimeType)` —— **拷贝进 App 托管目录**并写 `ManagedFileEntity` 进 Room | 读字节 → `ctx.fileUploads.uploadStream` → 拿 `receiptId` |
| 引用 | 消息里存本地受限文件 id，可跨消息复用 | `{type:'file', receiptId}`，**按 Session 作用域**（不可跨会话复用） |

差异要点：**"拷贝归谁"不同** —— rikkahub 自己保管那份副本（本地优先），
我们的副本由 DSH 宿主保管（`stagedFiles` 也是按 Session 建的 `WeakMap`）。
所以我们的界面要表达的是"已上传到电脑侧的这份会话"，不是"本地文件"。

rikkahub 的 `saveManagedFromUri` 用 `getFileMimeType(uri) ?: "application/octet-stream"`
兜底 MIME —— 与我们 `MainActivity` 里 `contentResolver.getType(uri)` 的兜底同形。

## 开工顺序（下次照这个走）

1. 在 `docs/subsystems/remote-channel.md` §5.7 定下 `attachment.upload` 的签名
   （建议 `{sid, name, data(base64)}` → `{receiptId}`，幂等键与 `session.prompt` 同款）。
2. 连接器：`FilesPort` + handler + `OPTIONAL_SERVICES` 加键 + 测试（假端口）。
3. 手机：通道加 `pickFile`（SAF）→ `AppModel.uploadAttachment` → `PendingAttachment`
   的 file 变体 → 上传中的状态 → 发送时打 `{type:'file', receiptId}`。
4. 判据：选一个 >3 MiB 的文件要**被拒且说清原因**；正常文件发送后，
   消息气泡旁出现附件计数（与图片同一条显示路径）。
