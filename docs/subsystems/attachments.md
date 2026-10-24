# 图片附件

现状事实。因果取舍见
`.agents/notes/implemented/2026-10-24-attachment-limits-from-dsh.md`。

## 1. 这条链是什么

选图（系统相册 / 拍照）→ 原生侧压到可传输 → 挂进输入栏卡片（**卡片内部上方**，
硬规则 1）→ 发送时变成 `session.prompt` 的 `{type:'image', mediaType, data}` part
（DSH 的 `PromptContentPart`，`packages/api/session-controller/src/types.ts:90-98`）。

「上传文件」不在里面：DSH 的文件 part 要 `receiptId`（`types.ts:98`，来自一次
`uploadFile`），那是另一个方法面，本仓未接。

## 2. 两条上限，两个主人

| 规则 | 数从哪来 | 撞上之后 |
|---|---|---|
| **宿主业务上限** | `imageLimits` 投影（`session-controller/src/list.ts:98-105`；值来自 `attachment/src/index.ts:34-46`，**部署可配**） | 选图时前置拦，说清是哪一条（类型 / 张数 / 单图 / 合计） |
| **通道层预算** | 契约 §40 的**单帧 8 MiB** 与"二进制在线上 ≈1.78 倍"（`connector/src/transport/codec.ts:53,77`）⇒ 原始字节预算 3 MiB（单张与合计各一个） | 选图时前置拦 —— 撞上它不是一条错误，而是**整条连接被关掉** |

顺序：**先问宿主、再问管道**。前者说"这台电脑收不下这样的图"，后者说"这条连接塞不下"，
两句话不同，不该混成一句。

投影缺席（老连接器 / 换会话后新包未到）时**宿主那一条不生效**，靠 DSH 自己拒：
拒绝码（`IMAGES_TOO_LARGE` / `TOO_MANY_IMAGES`）在错误消息里，手机原样显示
（`发送失败：…`），**不翻译、不改写成自家文案**。

## 3. 明确不判的两条

`maxImagePixels` / `maxImageDimension` **只有宿主拒、没有前置判据**：
判它们要把字节解码成图（多一次真实解码），而默认部署下永远不是先撞上的那一条
（3 MiB 的通道预算先到）。字段照解析、判据留空 —— 不假装判了。

## 4. 已知边界

- **选图器的 MIME 过滤是另一句**：系统选择器自己会挡掉不支持的格式，话术与本页的
  `mediaTypes` 判据可能有细微差别；**以宿主的 `mediaTypes` 为准**（它是权威）。
- **换会话的一瞬间**：`imageLimits` 属于会话投影，新包落地前为空 ⇒ 前置拦不生效。
- **压缩在原生侧**（`MainActivity.encodeForTransport`）：手机不重新编码，也不改字节。
