# Agent Note: 文件页 —— 只接 `list` / `read`，scope 走宿主的 lookup

Status: implemented

## Problem

抽屉底栏的「文件」一直是一个**点了只弹"还没做"的入口**（`main.dart` 的
`_notYet('文件页')`）。按本仓自己的规则，那是比"没有这一行"更糟的形态
（`settings_page.dart` 文件头："一行点下去只弹'还没做'的假入口"）。

而 DSH 本来就有这一面：`workspaceFiles`（`packages/api/workspace-files/src/index.ts`）
四个 `@Remote` + 一个流 —— `read`（按行分页读文本）、`readBytes`（字节窗）、`stat`、
`list`（直接子级）与 `changes`（`mode:'stream'`）。

## Decision

**只接"看文件"这一屏需要的两个：`list` 与 `read`。**

1. 连接器加两个只读方法 `file.list` / `file.read`（契约 §5.7），响应**逐字段构造**：
   清单给 `{path, entries:[{name, type, size?}], truncated}`，页给 `{text, offset, lines, eof, bytes?}`。
   宿主的 `absolutePath` 与 `version` **不过线**（手机不需要，少一个泄漏面）。
2. **scope 走宿主自己的 lookup**：`ctx.typert.lookups.get('workspaceFileScope').resolve(sessionId)`
   （注册在 `:203-221`，registry 形状 `packages/typert/protocol/src/types.ts:782-825`）。
   不照抄它那三行回退（活 agent 的 `cwd` → `sessionPersistence` 的 header → `sandboxPolicy.workspaceRoot`）——
   拼一份就是第二份真值，手机看到的"工作目录"会与桌面漂。
3. 能力位 `caps.files` = `workspaceFiles` **与** `typert` 都在（`filesAvailable` 一处定义，
   `readCaps` 与挂载点共用）。
4. 路径：手机只发**相对工作区的路径**，根是空串；连接器把它归一成 `.`（宿主对空串回
   `gateway/bad-request`，`:391`）。越界判定全在宿主（`inspect` / `locateFile` 的围栏）。
5. 手机：抽屉「文件」→ 目录浏览（位置行 + 上级 + 行）+ 文本预览（等宽、可选中、
   按行分页 + 「加载更多」）。清单截断要说；三种"没有"分开说。

## Alternatives considered

1. **接 `readBytes` 做图片/二进制预览** —— 最强理由：桌面上"看文件"很多时候是看图。
   被否（本轮）：原样字节走我们这条管道要 ×1.78 再进 8 MiB 的帧（契约 §40），
   接它得先定"多大以内可以传、超了怎么降级"，那是另一个决定；现在接了一半比不接更危险
   （用户会以为"这个文件坏了"）。
2. **接 `changes` 做实时刷新** —— 最强理由：桌面上文件被外部改动会自动刷新。
   被否：那是给手机加一条**订阅面**（新帧 + 订阅生命周期），与"只读预览"不是同一个需求；
   而且预览页是"打开时读一页"，没有常驻的必要。
3. **自己拼 scope（读 header 的 `cwd`）** —— 被否：见 Decision 2（第二份真值）。
4. **手机侧解析路径归属（`..`、绝对路径）** —— 被否：宿主已经用 `inspect` / `locateFile`
   做了围栏；手机再判一遍是两套规则，且必然与宿主的 workspace 根语义不一致。
5. **把目录做成树（一次拉全）** —— 被否：宿主的 `list` 是"直接子级 + 条目上限"，
   一次拉全等于自己造一个索引，且没有"什么时候过期"的答案。

## Consequences

- **收益**：抽屉里那个死入口变成一个能用的只读浏览器；路径与 scope 都与桌面同源。
- **代价**：**逐页读**，长文件要多次点「加载更多」（每次一个请求）。
- **代价**：`file.read` 需要**一个当前会话**（scope 按 sessionId 解析）；没进会话时文件页
  只能显示一句原因。
- **代价**：二进制文件只有宿主那句拒绝（`workspace-file/not-text`），没有本地预览。
- **未做**：写文件（宿主这一面本来也只有读）、图片预览（`readBytes` 那条路另议）。

## 判据

- connector **639 → 645**（`tests/files.test.ts` 6 条）：方法表与幂等键、清单逐字段
  （含 `other` 档与 `truncated`）、空目录 + 空 path 归一成 `.`、`read` 的分页参数与应答、
  宿主抛错原样、caps 有/无（两种缺法）。
- flutter **1211 → 1218**（`test/files_page_test.dart` 7 条）：模型解析两条、目录页
  （根两行 + 点目录的请求路径 + 截断提示）、根目录没有「上级」、老连接器不发请求、
  预览（文本 + 已到末尾）、读失败显示电脑侧原话。
- boundary **383 → 391**（新增 `app/lib/model/workspace_files.dart`、
  `app/lib/ui/files_page.dart`）。
- `pnpm exec tsc --noEmit` 0、`pnpm build` 过、`dart analyze --fatal-infos` 0、`dart format` 0。

## 代码入口回指

- 连接器：`connector/src/dsh/files.ts`（两个面 + scope lookup）、
  `connector/src/dsh/caps.ts` 的 `filesAvailable`、`connector/src/index.ts` 的挂载点、
  `connector/src/handlers.ts` 的 `file.list` / `file.read`（含空 path 归一）、
  `connector/src/protocol/methods.ts`。
- 手机：`app/lib/model/workspace_files.dart`、`app/lib/data/app_model.dart` 的
  `filesAvailable` / `listFiles` / `readFile`、`app/lib/ui/files_page.dart`、
  装配点 `app/lib/main.dart` 的抽屉底栏。
- 契约：`docs/subsystems/remote-channel.md` §5.7 的两行；现状 `docs/subsystems/files-page.md`。
