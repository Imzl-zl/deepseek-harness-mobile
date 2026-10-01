# Agent Note: connector 用独立 pnpm 工程，DSH 侧依赖钉 `next` 精确版本

Status: implemented

## Problem

本仓此前没有任何包管理配置（无 `package.json` / `pubspec.yaml` / CI），所有验证都是显式 `node` 脚本。`connector/` 是第一个需要依赖解析、类型检查与测试运行器的产物，所以「怎么建这个工程」是从零开始的一步，而它一旦定下来，lockfile、依赖方向与升级节奏都跟着定型。

真正会咬人的不是选哪个包管理器，而是**版本策略错了没有任何报错**：DSH 的插件兼容性判据是 `peerDependencies` 对 `@deepseek-ai/dsh*` 的范围（`packages/boot/app-boot/src/plugin-compatibility.ts:68`），不匹配的包会被**静默跳过**并记入 `skippedBundles`（`profile.ts:675-681`）；而写 `engines.dsh` 完全不参与判定（`packages/util/package-manifest/README.md:93`）。也就是说版本写错的表现是「插件装上了、清单里也有，但功能不生效」，而不是报错。

第二个坑是 dist-tag：DSH 各包的 `latest` 落后得离谱。2026-10-01 实测 `next` 全是 `0.2.0-rc.2`，而 `latest` 分别是 `dsh-jobs@0.0.1-rc.3`、`dsh-storage@0.0.1-rc.1`、`dsh-user-approval@0.0.1-rc.1`、`dsh-api-session-controller@0.1.2-alpha.2`、`dsh-typert-protocol@0.1.0-rc.6`。按习惯省略 tag 或写 `^` 会装到与 DSH 实例不匹配的版本，且照样静默。

第三件事是文档基线本身已经过期：设计文档与 cookbook 都写 `pnpm@11.7.0`，那是抄 DSH 仓库根的值；而本机实测装的是 `pnpm@11.13.0`。

## Decision

`connector/` 建成**独立的 pnpm 工程**（不是 DSH workspace 的成员，最终以 npm bundle 形式装进目标 profile 的 `node_modules`）；`packageManager` 钉本机真实存在的 `pnpm@11.13.0`；DSH 侧十三个版本（10 个 devDependencies + 3 个 peerDependencies）**全部钉 `0.2.0-rc.2` 精确版本**，peer 不写范围。

准入门槛（可机械判定）：

1. `connector/` 必须是 **npm bundle**：声明 `dsh.bundle.patch` 指向 `cordis.patch.yml`。不能做成动态 Cordis 包——沙箱会 trap 掉 `fetch` / `setInterval` / `require`。
2. **兼容性只看 `peerDependencies`**；禁止依赖 `engines.dsh` 做任何判定。`engines.node` 只表达运行环境要求。
3. DSH 侧版本一律取 **`next` dist-tag**（当前 `0.2.0-rc.2`）；禁止 `latest`，也禁止省略 tag。
4. **peer 写精确版本**，不写 `^` / `~` / 范围。rc 阶段不假设向后兼容。
5. `pnpm exec tsc --noEmit` 通过——空实现也要能编译。
6. `src/protocol/` **不得 import 任何 DSH 类型**，依赖方向单向（`dsh/` → `protocol/`，反向禁止）。
7. 改 `packageManager` 或任一 DSH 版本号时，同步改 `docs/subsystems/connector-and-relay.md` §1.1 与 `docs/cookbook/channel-bootstrap.md` 的基线表——三处不许各自漂移。
8. **第三方构建脚本一律显式记为拒绝**，需要放行时必须先证明缺它就跑不通。pnpm 11 的审批结果记在 `connector/pnpm-workspace.yaml` 的 `allowBuilds`（**不是** package.json；`pnpm.ignoredBuiltDependencies` 是旧写法，pnpm 11 不认，写了不生效），非交互写法是 `pnpm approve-builds '!<pkg>'`。
9. **构建产物路径必须与 package.json 的 `main` / `exports` / `files` 一致**，且由配置文件钉住，不靠工具默认值。判据不是「能编译」，而是 `node -e "import('./lib/index.js')"` 能真正加载出 `apply` 与 `Config`。

## Alternatives considered

1. 钉文档原本写的 `pnpm@11.7.0`（与 DSH 仓库根完全一致）
   - 最强的理由：工具链与参考项目逐位对齐，照抄参考插件的 lockfile 行为与 workspace 语义时不会冒出「本机 pnpm 不同」的差异；而且文档不用改，零返工。
   - 为何被否：connector 是**独立 npm bundle**，不是 DSH workspace 成员，它与 DSH 之间只通过 peer 版本号和最终产物 `lib/` 耦合，pnpm 补丁号一致买不到任何功能。代价却是实打实的：`packageManager` 一钉，pnpm 的 `manage-package-manager-versions` 就会去 corepack 下载 11.7.0，本机装的是 11.13.0，于是每次动依赖都多一次网络往返，离线直接失败。而 `11.7.0` 这个值本来就是「抄 DSH 根」的结果，从没为 connector 论证过——文档写它就等于把一个没被论证过的数字当成约束。
2. 干脆省略 `packageManager` 字段
   - 最强的理由：没有任何版本冲突，什么 pnpm 都能跑，最省事，也不用改文档。
   - 为何被否：lockfile 格式与解析行为跟 pnpm 大版本绑定，省掉这个字段等于放弃锁的可复现性。而「装进别人 profile 的插件」恰恰是最需要可复现的场景——不同人用不同 pnpm 解析出不同的依赖树，会变成一类只能靠重装解决的偶发问题。
3. 改用 npm 或 yarn
   - 最强的理由：npm 随 Node 自带（本机 11.17.0），零额外安装；生态最通用，别人 clone 下来不用先装包管理器就能跑。
   - 为何被否：DSH 侧的参考插件与 Agents-Anywhere 的 connector 都是 pnpm 工作区，npm 在 workspace 与 peer 解析上的语义与之有差异——而这一步的整个方法就是「照参考实现的形状」，换包管理器等于在对照移植时凭空多一层翻译成本。同时本机 pnpm 已装（11.13.0），选 npm 并没有省下安装成本，只省下了一个本来就不存在的步骤。
4. DSH 侧依赖写范围（如 `^0.2.0-rc.2`）而不是精确版本
   - 最强的理由：DSH 发 rc 补丁时不用改 `package.json`，少一次手工同步，升级摩擦最小。
   - 为何被否：兼容性判据是 peer 的比较语义，而这个语义**尚未逐行核实**（设计文档 §1.1 自己标了「第一次装进 profile 时按里程碑 2 确认」）。在语义未确认的前提下写范围，等于主动引入「装到了 rc.3、然后被静默跳过」这一整类不确定性；而静默跳过没有报错、排查成本高。rc 阶段本来就不该假设向后兼容，宁可每次手工同步九处版本号，也不要一个查不出来的静默失败。

## Consequences

- 收益：connector 的依赖解析可复现（`packageManager` + lockfile 都进仓）；DSH 版本策略有明文判据，同时避开 `latest` 落后与 peer 静默跳过这两个坑；`src/protocol/` 不依赖 DSH 类型这条单向依赖有门槛可机械检查；文档基线与本机实测重新对齐，`pnpm@11.7.0` 这个未经论证的数字不再当约束用。
- 代价：本仓从此有了第一套包管理配置与 lockfile，`tools.md`「本仓库没有 `package.json` / CI，所有命令都是显式脚本」这条现状事实随之失效（已同步改）；DSH 每次发 rc 都要手工同步十三处版本号，且**改一处要同步三个文件**（package.json / 设计文档 §1.1 / cookbook 基线表），漏一处就是三处漂移；peer 的精确比较语义仍未逐行核实——在第一次装进 profile（里程碑 2）之前，这套策略只是「照参考插件的形状」得来的经验，不是实测结论。第十处 devDependency（`dsh-subagent`）与设置/凭据那三个包是接第 4 步适配层时按实际用到的类型追加的，取舍见 `.agents/notes/implemented/2026-10-01-connector-settings-adapter.md`。
- 落地时实测到的两处工具链陷阱（已进 `tools.md` Pitfalls，此处只记结论）：**其一**，pnpm 11 的构建脚本审批闸拦的是**每一次 `pnpm exec` / `pnpm run`**，不只是 install——`esbuild`（经 `tsx` 传入的传递依赖）未获批准时连 `pnpm exec tsc --noEmit` 都跑不起来，极易误判成「依赖装坏了」；而实测把它记为拒绝后 `tsx` / `esbuild` 照常可用（平台包 `@esbuild/win32-x64` 是独立安装的，postinstall 只做校验），所以严守「默认拒绝」没有付出功能代价。**其二**，tsdown 在 `platform: 'node'` 时 `fixedExtension` 默认 true，产物是 `dist/index.mjs`，与设计文档声明的 `lib/index.js` 对不上——若不核对，装上 profile 后 `main` / `exports` 会指向一个不存在的文件，而这类失败只会在里程碑 2 装进 profile 时才暴露。两处都说明：**「能编译」不等于「能用」，产物路径要拿真实加载来验**。
