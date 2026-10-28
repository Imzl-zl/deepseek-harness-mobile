# 文件页

现状事实。因果取舍见
`.agents/notes/implemented/2026-10-24-workspace-file-browser.md`，
方法表见 `remote-channel.md` §5.7 的 `file.list` / `file.read`。

## 1. 它是什么

抽屉底栏「文件」→ 工作区目录浏览 + 文本预览。数据来自宿主的
`workspaceFiles`（`packages/api/workspace-files/src/index.ts`）：

| 手机上的事 | 连接器方法 | 宿主方法 |
|---|---|---|
| 列一个目录 | `file.list` `{sid, path}` | `workspaceFiles.list(scope, path, signal)`（`:303-329`） |
| 读一页文本 | `file.read` `{sid, path, offset?, limit?}` | `workspaceFiles.read(scope, path, range, signal)`（`:233-247`） |

**scope 由宿主自己的 `workspaceFileScope` lookup 按 sessionId 解析**（`:203-221`）：
活会话取 header 的 `cwd`，否则 `sessionPersistence.stat` 的 header，再退
`sandboxPolicy.workspaceRoot`。连接器不自己拼 `{sessionId, workspaceRoot}` ——
拼一份就是第二份真值。

## 2. 路径规则

- `path` 是**相对工作区的路径**，根是空串（手机发空串，连接器归一成 `.` —— 宿主对空串回
  `gateway/bad-request`，`:391`）；
- 子项路径 = `父路径 + '/' + name`（宿主 `list` 的注释同一句，`types.ts:110-115`）；
- **越界（`..`、绝对路径、符号链接）由宿主判**，手机不解析归属。

## 3. 不做什么

- **`readBytes` 不接**：原样字节会撞我们这条管道的单帧预算（契约 §40）。要看图片得先量帧。
- **工作区 `changes` 流（`mode:'stream'`）不订**：改动记录走独立的一次性方法
  `file.changes` / `file.diff`（`changes-card.md`），不是给文件页加订阅。
- **不写文件**：宿主这一面本来也只有读（`stat` / `list` / `read` / `readBytes`）。
- 非普通文件（`type: 'other'`）列出来但**不给点**：宿主 `read` 也会拒。

## 4. 界面

- 顶栏：返回 + 「文件」+ 刷新（从当前目录重读）。
- 位置行：当前路径（根显示「工作区根」）+「上级」（根目录时没有）。
- 行：图标 + 名字 + 大小（普通文件且后端报得出才显示）；目录点一下进去，文件点一下进预览。
- 清单被宿主的条目上限截断时**明说**（「只列出了前面一部分」）—— 不假装列全。
- 三种"没有"分开说：**没有文件服务**（老连接器，不发请求）/ **这个目录是空的** / **读取失败**
  （显示电脑侧原话）。
- 预览页：等宽字体、可选中复制；按行分页，`eof` 之前有「加载更多」；底部报已读行数
  （到末尾时写「共 N 行（已到末尾）」）。

## 5. 能力位

`repo.info.caps.files`（连接器侧 `filesAvailable(ctx)`：`workspaceFiles` 与 `typert`
两个键俱在才 true，**与挂不挂这两个方法读同一个函数**）。

## 6. 已知边界

- **需要一个当前会话**：scope 按 sessionId 解析，没进任何会话时列不了目录（连接器回
  `internal` 说清"这个会话没有工作目录"）。
- **预览只读一页**：默认页由宿主的 `maxLines` / `maxBytes` 定；很长的大文件要按「加载更多」
  逐页读，且每次翻页都是一次请求。
- **只读文本**：宿主对四种"读得懂但打不开"各回一个码，手机按码换文案
  （`app/lib/model/file_failure.dart`，照桌面
  `ui-sidebar-documentpreview/src/client/failure-line.ts:24-35` 与 `locales.ts:27-31`）：

  | 码 | 手机显示 |
  |---|---|
  | `workspace-file/not-text` | 该格式文件暂时无法预览 |
  | `workspace-file/too-large` | 单页内容超过上限，无法读取 |
  | `workspace-file/not-found` | 找不到这个文件 |
  | `workspace-file/not-regular-file` | 该路径不是普通文件，没有可显示的内容 |

  这四类**不重试**（`disable-and-annotate`，§3.1）。桌面在 `not-text` / `too-large`
  上还提供"用外部程序打开"；手机没有这条能力，所以只说不能预览。
  其它码保留 `读取失败：{宿主原文}`（桌面 `error.unavailable` 同一句）。
