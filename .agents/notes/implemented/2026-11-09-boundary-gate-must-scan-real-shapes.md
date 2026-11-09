# Agent Note: 边界门禁必须扫真实形态，"全绿"才等于"干净"

Status: implemented

## Problem

`node app/tools/verify-platform-boundary.mjs` 报了两个月的 `ALL CHECKS PASSED`，但其中三条规则**从未可能命中**：

1. `SCAN_DIRS` 里有 `app/packages`，那个目录从来没建过；`walk()` 对不存在的目录静默返回空数组，于是"扫了"这件事没有任何对象。
2. `ui-no-impl-import` 的 `IMPL_SUFFIX` 只认目录形态 `..._ohos/...`。实际写法是文件形态 `platform/notify_android.dart`（`app/lib/platform/notify_factory.dart:11`）。全仓 `_ios/` `_android/` `_ohos/` 形态的 import **一条都没有**，规则活着但永不触发。
3. 按符号匹配的规则（`branch-whitelist` / `no-platform-isohos` / `fallback-not-in-release`）直接在原文上 grep，靠"注释行以 `//` 开头、接不上 `Platform`"这种巧合躲开注释；块注释、行尾注释、跨行拼接都躲不开。能不能放过注释取决于每条规则作者记不记得剥。

后果不是"少报一次"，是**门禁输出被当成事实**：绿色被读成"UI 没有依赖端的实现"，而那句话从来没有被验证过。

## Decision

三条一起改，且**只改这三件**：

1. `SCAN_DIRS = ['app/lib']`（`app/packages` 的豁免一并删掉：没有目录就没有对象）。
2. `IMPL_SUFFIX = /import\s+['"][^'"]*_(ios|android|ohos)(?:\/|\.dart['"])/` —— 目录形态与文件形态都认。
3. 剥注释**只在扫描循环做一次**（`stripComments` 换成等长空白、换行不动），规则拿到的是 `match(code)`；行号仍从同一个串数。

准入门槛（可机械判定）：

1. 变异校验：在 `app/lib/ui/` 任一文件里加一行 `import '../platform/notify_android.dart';`，门禁必须红且**只有** `ui-no-impl-import` 一条；删掉必须回绿。2026-11-09 实测：红 `FAIL 1/848`（`ui-no-impl-import: app/lib/ui/dsh_toast.dart`），删掉回 `ALL CHECKS PASSED — 848 项`。
2. 自检样本必须覆盖实际形态，而不只是"理论反例"：文件形态 import（拦）、`notify_factory.dart` 这种装配点 import（放）、行注释与块注释里的 `Platform.isAndroid`（放）、文档注释里的 `Platform.isOhos`（放）、注释里的兜底实现名（放）。
3. 规则条数仍是 9 条；不得借这次换掉整份脚本。

## Alternatives considered

1. 整体换成 `refs/remotes/pr/6` 的脚本
   - 最强的理由：那份已经把这三件都做了，还顺手把 `fallback-not-in-release` 从"指向不存在的 `registry.dart`"改成指向真实装配点 `notify_factory.dart`，省一轮返工。
   - 为何被否：实测那份在今天的代码上报 **828 项 / 31 条自检**，而 main 是 **843 / 29**。它没有 `data-no-field-name`（2026-11-06 才在 main 落地的那条），换掉等于**静默删掉一条规则**；项数变化还会被后来者读成"这次顺手删了规则"。要那份的语义，就一条一条搬。
2. 每条规则自己调 `stripComments`
   - 最强的理由：规则自洽，单独复制到别的脚本里也对。
   - 为何被否：漏一条就是一条休眠的假绿，而且"注释不算违规"这件事会散在 9 处。剥一次、统一入口，才有"新增规则默认安全"。
3. 这批顺手把 `fallback-not-in-release` 改成扫 `platform/*_factory.dart`
   - 最强的理由：那条规则今天指向的文件不存在，等于永不触发，和这三条是同一类病。
   - 为何被否：它属于 notify 装配的规则重写（新样本、新判据"`kReleaseMode` 必须真的用在分支里"），会和 notify 的 release 行为改动混在一起。先让这批的项数变化只来自"新增自检样本"，那条单独一批做。

## Consequences

- 收益：三条规则从"永远绿"变成会红，且用一次真实变异校验证明了红在哪一行；新增 5 条自检样本后总数 843 → **848**（34 条自检 + 190 文件），文件数不变，说明改的是规则不是扫描面。
- 代价：剥注释现在会把**字符串里的 `//`** 一起抹掉到行尾，因此同一行字符串之后的代码对规则不可见。这是已知的假阴性方向（少报），今天 `app/lib` 里没有任何一行同时含 `://` 与规则记号（实测：`Select-String '://'` 与规则记号取交集为空）。将来若写出 `final u = 'wss://x'; if (Platform.isAndroid) …` 这种一行两事，规则会漏 —— 补真正的词法分析之前，这条限制写在这里，不要当成"已经不会漏"。
- 代价：`match(code)` 的契约从"文件原文"变成"已剥注释的正文"，规则作者不能再假设拿到原文。`data-no-field-name` 的行号依赖"逐字符留白"，这条约束写在 `stripComments` 的注释里。
