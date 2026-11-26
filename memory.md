# dsh-mobile 项目状态

> 覆盖快照；正式契约在 docs，因果在决策笔记，稳定命令在 tools。

## 现在（2026-11-26 · v0.2.25 / connector 0.1.32 已正式发布）

用户在问「可以发版吧」后要求直接执行，已提交/推送本轮两项改动并公开发行。未安装到运行profile、未重启用户DSH、未改两部手机或真实设备表。

- 发行提交 283a6dbc86f935394ea19c6700d46360be57023b（两个提交：43de918 表格滚动条、283a6db 工作区行）；App v0.2.25（基础28）与connector-v0.1.32两个annotated tag均指向它。
- [发行页](https://github.com/Imzl-zl/deepseek-harness-mobile/releases/tag/v0.2.25) 非draft/非prerelease，三APK与TGZ全部uploaded；notes已手写本版内容与「插件需同升0.1.32」要求。
- APK体积：arm64 **28,802,492B / 27.5MiB**、v7a25,049,132B、x64 31,227,322B；TGZ207,856B。
- 三APK实际code**本轮未实测**（CI日志无aapt抽码步骤）：按上版规律预计 v7a1028 / arm642028 / x644028，**装机时应回读确认**，不要把预计写成实测。
- npm **latest=0.1.32**，provenance已published。
- **重复发布run仍有一次E409**（本次45747831392）：`connector-v0.1.32`那条45747831437先成功（35s），`v*`那条晚到撞「Cannot publish over previously staged version」。npm实际0.1.32可读、latest已指向它。不要把该红run说成版本未发布，也不宣称发布run全绿。

## 本轮主要修复

- **表格横向滚动条压住最后一行**：根因是表格那层`Scrollbar`把`MediaQuery.padding`当自身padding（`material/scrollbar.dart:360`），条按`widgets/scrollbar.dart:610`被底部安全区顶进内容（inset34实测压33px）、按`:603,408`被左右安全区错位并缩短。修法：`DshMarkdown`对整棵子树`removePadding(removeLeft/right/bottom)`，`tablePadding.bottom`4→8让出条高。回归5条，变异4项全红。
- **工作区行三个动作**：`workspace.rename`/`workspace.delete`（宿主`workspace-controller/src/index.ts:119,129`，都是`@Remote`）+组头「＋」在该组内新建会话；两个新建入口共用`_newSessionIn`。标题原样发不trim（trim/判空/重名是宿主`commands.ts:74-87`的事）。新增错误码`workspace/name-conflict`两侧同步、契约§3.1补齐。
- **明确不做「在文件夹中显示」**：宿主确有`openWorkspacePath(reveal)`（`session-controller/src/index.ts:347-354`），但它在电脑弹文件管理器、远程用户看不到结果（用户原话「我是远程，你就是打开了我又看不了」）。

## 验证与构建

- connector **944/944**、tsc0、build通过；App **2040/2040**、analyze0。
- 协议454/26/49、boundary994、size、图标均PASS。
- [同SHA CI100](https://github.com/Imzl-zl/deepseek-harness-mobile/actions/runs/45747098021) success后才推tag；[Release](https://github.com/Imzl-zl/deepseek-harness-mobile/actions/runs/45747831452) success。
- 尺寸棘轮本轮**提了三处**（app_model 5250→5320、main 1950→1995、session_drawer 1400→1650），各在表内写明原因；同时把`DshGroupAction`抽去`ui/dsh_group_action.dart`做了一次真削减。方法数54→56、错误码35→36、`repo.info`金样方法清单+2四处同步。


## 未验证与恢复边界

- 真机摄像头扫码、两手机覆盖安装/原生断电、真实当前GUI React端到端未验；缺口已写Release notes，不宣称秒扫/生产毫秒。
- 已开始名册HTTP不主动abort，热改参数非跨存储原子快照；FIFO最终新全量收敛，状态暂时滞后明示。
- 无code且旧定位已丢的历史行不能按名称/型号/短码自动归并；卸载/清应用数据不保证码延续。
- v2迁移后不能直接降装旧APK；如异常保留应用数据，前滚同证书/高code/兼容v2修复。撤回发行曝光与数据恢复是不同步骤，详见 [发行恢复](<docs/cookbook/release.md#L186-L203>)。

## 知识归宿与后续

[配对连续性](<docs/subsystems/pairing-v2.md>)、[存储](<docs/subsystems/remote-channel.md>)、[手机持久化](<docs/subsystems/app-channel-client.md>)、[设备管理](<docs/subsystems/connector-and-relay.md>)为真值；原因在11-24三篇implemented笔记和 [ABI计数查证](<.agents/notes/implemented/2026-11-25-split-apk-version-code-verification.md>)。

下一步：在手机原安装上覆盖升级 v0.2.25，并把电脑插件更新到 0.1.32（**只升 App 不升插件时，工作区改名/删除会回 `connector/unsupported`**，功能不可用但不损坏数据）；随后验工作区行三个动作与宽表滚动条在真机上的表现。真机摄像头扫码、两手机覆盖安装/原生断电、真实当前GUI React端到端仍未验；不要宣称秒扫或生产毫秒。
