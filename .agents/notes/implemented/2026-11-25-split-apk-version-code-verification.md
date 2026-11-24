# 拆包 APK 的实际编号按同 ABI 比较，保留 SDK 偏移与基础运行计数

Status: implemented

## Problem

旧正式 ARM64 APK 用实际 aapt 读得 versionCode=2026，而 GitHub 发行工作流基础运行号是26。将基础编号与实际APK编号当同一值，曾得到“新基础27不能覆盖2026”的错误调查假设。锁定Flutter SDK源码明确说明拆包为ABI_VERSION×1000+基础versionCode，ARM32/ARM64/x86_64映射1/2/4。旧job命令同时使用split-per-abi与GITHUB_RUN_NUMBER，并未漏传。问题是校验解释，不是生产编号策略缺失。

## Decision

保留原工作流的基础运行计数和Flutter原生拆ABI偏移，不改生产构建行为。实际升级门禁按相同ABI读取新旧APK的版本、包名和证书；基础27三架构预期1027/2027/4027，发布完成仍以真正产物为准。原错误假设测试已用外部SDK规范纠正，不能宣称两个错误红灯证明了生产缺陷。

[发行校验回归](<connector/tests/release-version.test.ts>) 以 [正式APK捕获](<connector/tests/fixtures/android-release-baseline-v0.2.23.json>) 的元数据及SDK偏移规范为外部期望，避免重抄实现常量。SDK精确依据为 `packages/flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt:607–626` 与 `FlutterPluginConstants.kt:37–42`。

## Alternatives considered

- **手工给基础号再加2000**：最强理由是让ARM64数字立即超过旧包；被否是SDK已加该偏移，再加会双重编码且对其它ABI含义错误。
- **只因为2026/26差异就移除运行号覆盖、改manifest为2027**：最强理由是单文件计数直观；被否是差异来自SDK拆包语义，当前工作流正确，改基础号会无谓跳升所有ABI，不能作为根因修复。
- **仅看源码运行号不验APK**：最强理由是快且不用下载；被否是最终签名与实际版本是可安装升级的契约，必须验产物。

## Consequences

收益是保留正确发行流程并明确基础/实际版本区别，不强迫用户卸载。代价是发行时须读取三个APK，测试captured基准仅守住已知旧版并不能替代真实新产物验证。调查假设被否定是正常结果，不将文档误读包装成程序修复。
