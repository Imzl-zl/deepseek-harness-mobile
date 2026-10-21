# docs 文档标准

## 结构分层

- `architecture.md`:骨干预览,只做总导航,不写具体类型细节。
- `subsystems/`:子系统规范,承载真实类型声明与契约。
- `cookbook/`:操作实操,每步带编号和精确验证命令。
- `postmortem/`:事故复盘,真实踩雷记录、时间线、止血措施。

一事一归宿:上层只放单行链接,细节永远下沉到专属目录。

## 去废话守则

1. 只记当下事实,严禁「以前 / 现在 / 不再 / 改名为」这类变迁叙述。历史属于 git 和 `.agents/notes/`。
2. 严禁人肉手抄生成物:能由源码或 AST 推导的 API 列表、配置清单必须由代码生成,文档只负责圈定插槽。
3. 文档里的代码块必须能真实编译或运行通过。
4. 字数上限与超限处置:**下沉迁移 → 精简浓缩 → 申请提额**,按此顺序,不允许先删约束。

## 本仓 `docs/` 的现状文档

| 文档 | 职责 |
|---|---|
| `design-and-tech-plan.md` | 设计与技术基线(总纲):定位、架构、技术栈、设计 token、逐屏规格、授权与动效规则 |
| `settings-porting-notes.md` | 设置项逐项搬运清单(42 项:搬 / 只读 / 不做 / 必须分叉) |
| `plugin-and-jobs-notes.md` | 插件体系与后台任务的移动端边界(含插件页为何无法通用渲染、Schemastery 过线范围) |
| `standalone-mode-notes.md` | 本机运行模式(不连电脑)调研与设计草案 |
| `subsystems/remote-channel.md` | 远程通道子系统规范:信封、配对与鉴权、端到端加密、修订号与恢复语义、存储边界、推送与前台优化 |
| `channel-review-notes.md` | 远程通道方案评审:优越性对照、DSH 侧关键事实与行号、协议待补六条、平台侧事实、可复现实测与证据等级 |
| `mobile-surface-roadmap.md` | 移动端界面接线路线图:不变量(手机=Web 的接口透传,不重新设计)、三扇门、全景清单、接线顺序、单方法接线清单、已知陷阱 |
| `subsystems/connector-and-relay.md` | 电脑侧桥接与中转的落地设计:工程配置与版本基线、目录与生命周期、存储 schema、中转接口与限流、里程碑 |
| `subsystems/app-channel-client.md` | 手机端通道客户端设计:core 分层与签名、连接/订阅状态机、渲染性能对策、三端能力包、UI 接线点、测试策略 |
| `cookbook/channel-bootstrap.md` | 开工实操:从零到真机连通的编号步骤与精确验证命令 |
| `cookbook/relay-on-a-server.md` | 在服务器上用 Docker 跑中转(公网 wss):令牌签发、compose、Caddy、连接器与手机两端验证 |
| `subsystems/app-platform-boundaries.md` | 手机端多端边界:核心零平台分支、三个能力包、可机械判定的边界规则与校验命令 |
| `subsystems/blank-session-hero.md` | 新会话页(blank 会话的 hero):落到这一屏的条件、结构、三样数据与标签链、写路径、有意偏离、验证 |
| `subsystems/subagent-page.md` | 子智能体页:目录树(直接子级 + 展开才懒加载)、三态、行规格、子会话头部条与切换、一次性/未知的只读状态框、已知差异 |
| `subsystems/trajectory-page.md` | 轨迹页:每轮一行的数据面(turnOutline + 本轮用时)、迷你条编码、条目详情 sheet、为什么没有甘特/调用明细、有意偏离 |

## 引用纪律

- 引用 DSH 行为必须给 `packages/...:行号`;行号会漂移,改文档时**顺手核对被引行**是否仍指向该内容。
- 查不到就写「未找到」,禁止以"通常如此"代替证据。
- 四份文档互相引用时用相对路径 + 章节号,不用绝对路径。
- 引用非本仓参考实现(Agents-Anywhere / DSH / rikkahub)时给绝对路径:`仓库根\相对路径:行号`。

## 字数预算

- `design-and-tech-plan.md` ≤3,000 词(当前约 2,990,已到上限;新增内容一律先下沉到专项文档)
- 分析类文档(`*-notes.md`)≤5,500 词
- 本文件 ≤1,320 词
