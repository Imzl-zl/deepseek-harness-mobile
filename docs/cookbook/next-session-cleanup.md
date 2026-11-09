# 新会话提示词：v0.2.13 之后的欠账收尾

> **已收口（2026-11-09）**：下面静态可验的 A–F 全部落地 —— A（门禁唤醒）与 B（notify release
> 即抛）见 `implemented/2026-11-09-boundary-gate-must-scan-real-shapes.md` /
> `2026-11-09-notify-release-throws-instead-of-degrading.md`；C 的四件各一个 PR（#10 任务完成
> 通知 / #11 已回答标题 / #12 文件行号 + 面包屑 / #13 轨迹字段 JSON）；D（条数归口）与
> F（#8 文档漂移）见 `2026-11-09-test-counts-live-in-tools-md.md` /
> `2026-11-09-pr8-doc-drift-verdicts.md`。**`refs/remotes/pr/*` 已删除**，别再按本文的
> `git show refs/remotes/pr/N:<path>` 取参考实现。末尾"需要真机"那两条仍未做。

> 复制下面 `---` 之间的全部内容到新会话。**先做静态可验的,需要真机的放最后。**

---

## 现状（已核实，别重新论证）

- `main` = `abd89d2`；最新发版 **v0.2.13**（`dsh-mobile-v0.2.13.apk` 78.8 MB + `dsh-mobile-connector-0.1.23.tgz`）。手机装的是官方 0.2.13（versionCode 16）；本机 `app/android/key.properties` 与 CI **同一把签名密钥**，官方包可覆盖安装，不用卸载。
- **0 open PR / 0 issue**。9 个 PR：合了 `#2 #3 #9`，关了 `#1 #4 #5 #6 #7 #8`；每个关闭理由都在 PR 评论里（`#4 #5 #8` 的评论已被实测数据修正过）。
- 门禁基线：`flutter test` **1791**；`node app/tools/verify-platform-boundary.mjs` **843（29 条自检 + 190 文件）**；`dart analyze --fatal-infos` 0 issue；`dart format` 0 改动。
- 已实测（Xiaomi 23113RKC6C / Android 16 / API 36 / Flutter 3.41.9）：
  - IME inset **由引擎报给 Dart**，`adjustResize` 与 `adjustNothing` 两档都是 `viewInsets.bottom` 0 → **368 dp（≈921 px）**，窗口 411.4×914.3 dp 不变。→ **不做原生 IME 通道**（`#4`/`#8` 的前提不成立）。
  - 配对页粘贴框聚焦会切 MIUI `com.miui.securityinputmethod`（`FLAG_SECURE` 全屏），**截图整屏黑 ≠ App 黑屏**。
  - 两条已写进 `docs/subsystems/app-platform-boundaries.md` §5。

## 任务（全部静态可验，按顺序做；每步跑完门禁再进下一步）

### A. 门禁唤醒（`#6` 的第一条，**不要整体 cherry-pick**）

文件：`app/tools/verify-platform-boundary.mjs`

1. `SCAN_DIRS` 只留 `['app/lib']` —— `app/packages` 不存在，扫它等于一条永不作废的假绿。
2. `IMPL_SUFFIX` 改认**文件形态**：`/import\s+['"][^'"]*_(ios|android|ohos)(?:\/|\.dart['"])/`（现在的写法 `platform/notify_android.dart` 认不出来，规则等于休眠）。
3. 规则匹配在**去掉注释**的正文上做（注释里写「别 import X」不该算违规），行号仍要对得上。
4. **别整体换脚本**：实测 `refs/remotes/pr/6` 的版本能在今天的代码上跑绿，但报 **828 项 / 31 条自检**，与 main 的 **843 / 29** 不等价（main 有 `data-no-field-name`，它没有）。只把 1–3 搬进今天的脚本，改完把 `memory.md` / `tools.md` 里的项数改成实测值。
5. **变异校验（必做）**：在 `app/lib/ui/` 临时加一行 `import '../platform/notify_android.dart';`，门禁必须变红；删掉恢复绿。把红/绿两段输出贴进会话。

### B. release 下 notify 不允许静默降级（`#6` 的第二条）

文件：`app/lib/platform/notify_factory.dart`

- `Platform.isAndroid` → `AndroidNotify()`；非 Android 且 `!kReleaseMode` → `MemoryNotify()`；非 Android且 release → `throw UnsupportedError(...)`。
- 测试：`kReleaseMode` 是编译期常量，行为测不了；按仓里已有的做法（`app/test/assembly_invariants_test.dart:330` 读源码形状）加**源码形状断言**，并在注释里写明为什么不是行为测试。**别**为了可测把判断挪到运行时变量。
- 跑 `cd app; dart analyze --fatal-infos lib test; flutter test`。

### C. `#8` 的四件功能（各开小 PR，按这个顺序）

参考实现**只读**：`git show refs/remotes/pr/8:<path>`（fork 分支，落后 main 20+ 提交，**只抄语义，不抄结构**）。

1. **后台任务完成通知**：job 结束 → 本地通知；按 `jobId` 去重；30 分钟窗口。挂现有的 `AppServices` / 通知端口，不新起通道。
2. **问答「已回答」标记**（聊天流里那个）：注意 `app/lib/ui/takeover.dart:559` 的「已回答 · 选项」是接管卡状态，**别覆盖它**。
3. **文件预览行号 + 目录面包屑**：`app/lib/ui/files_page.dart` 一带；行号语义与 `model/diff.dart` 的 `DiffLine` 别混。
4. **Trajectory 原始 JSON**：投影字段级展示，标题必须注明「非原始 payload」。

每件：代码 + 测试 +（改流程时）决策笔记；跑 `dart analyze` / `flutter test` / 边界门禁。

### D. 计数归口（`#7`）

三处对不上：`README.md:92` **1779**、`memory.md:100` **1791**、`tools.md:120` **1762**。收成一处（数字只住 `tools.md`），其余改成指向。

### E. 仓库整理

- 删已关 PR 的远端分支：`docs/counts-main`、`feat/add-second-host`、`fix/android-ime-insets`、`fix/app-platform-boundary`（先用 `gh pr list --state all` 复核对应 PR 都是 CLOSED/MERGED）。
- 删本地临时引用 `refs/remotes/pr/*`（6 个）——**先把 A/C/F 需要的内容取完**。
- 删完 `git fetch --prune`，贴 `git branch -r`。

### F. 补核一块之前没评估的（`#1`/`#8` 里的「评审五条 + 文档漂移」）

从 `refs/remotes/pr/8` 取 `docs/`、`AGENTS.md`、`README.md` 的改动，逐条判「今天还成立吗」：成立的挑出来做，不成立的写清为什么不成立。**这一块之前没逐条核过，别假设它没用。**

## 明确不做（有证据）

- **原生 IME 通道**：两档实测都报 insets（见上）。
- **应用内下载安装 APK**：安全边界未评审（安装器验签 + 下载完整性）。
- **整体换 `refs/remotes/pr/6` 的脚本**：覆盖不等价（A.4）。

## 需要真机 / 第二台电脑（先不做，留到最后）

- **「添加电脑」的端到端**（v0.2.13 新入口）：配对 A → 添加电脑 → 配 B → 切回 A，A 的会话与草稿还在。需要第二台电脑或同一台电脑的第二个身份。
- 做法：隔离实例 `DSH_HOME=D:\tmp\dsh-e2e` + `dsh --profile mobile-e2e --port 0 --no-open`；出码用 `D:\tmp\dsh-e2e\qr2.ts`（参数：token、输出 png、base URL）。**不要**动 `~/.dsh` 的全局连接器 —— 那是全局一份身份与中转会话，两个连接器同开会互相顶掉、登记被 `forgetConnector` 抹掉（症状是手机报 `409 pairing-unavailable`）。

## 验收

```powershell
cd app; dart format --output=none --set-exit-if-changed lib test integration_test
cd app; dart analyze --fatal-infos lib test integration_test
cd app; flutter test
node app/tools/verify-platform-boundary.mjs
node protocol/verify-fixtures.mjs; node protocol/verify-loopback.mjs; node protocol/verify-vectors.mjs
cd connector; pnpm exec tsc --noEmit; pnpm build; pnpm test
cd relay; pnpm typecheck; node --test
```

数字对不上先查是不是自己改的，**不改断言凑数**。

## 纪律

- 决策笔记与代码同批提交（`.agents/notes/`），被约束的代码入口留一行回指。
- 改行为先改 `docs/`，别让两边漂。
- **不要乱关 PR、不要在没证据时写结论**：写「实测」必须带命令与输出；推断要标明是推断。
