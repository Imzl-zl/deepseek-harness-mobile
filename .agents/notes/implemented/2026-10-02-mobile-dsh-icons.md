# Agent Note: 图标只有一个来源 —— DSH 的 98 个图标机生成进 Flutter，并加门禁拦住 Material 图标

Status: implemented（2026-10-02 落地：`app/lib/theme/dsh_icons.dart` 机生成 + `no-material-icons` 门禁）

## Problem

### 一、我自己破坏了"图标只有一个来源"

项目硬规则写得很清楚（`AGENTS.md`）：图标走 DSH 的 98 个图标
（`mock/proto/icons.js`，由 `extract-dsh-icons.mjs` 从 DSH 源机生成），
而且"改基线要同步改落地端，**不允许两边各自漂移**"。

但我在写 Flutter UI 时**随手用了 11 个 Material 图标**：
`Icons.refresh` / `Icons.send` / `Icons.cloud_off` / `Icons.shield_outlined` …

后果不是崩溃，而是**原型与 App 长得不一样** —— 同一件事（刷新、发送、审批）
在两边显示成不同的图形，而这正是那条硬规则要防的。

### 二、图标字体（IconData）表达不了这套图标

第一直觉是"把 98 个图标做成图标字体"。量完发现不行，这套图标里有三样
字体表达不了的东西，而它们在 DSH 里都是有意义的视觉区分：

| 特性 | 用到的图标 | 数量 |
|---|---|---|
| **`<mask>`** | `archiveOff`（斜杠是挖空出来的） | 1 |
| **`opacity`** | `compact`、`folderOpen`（同色两层叠出层次） | 2 |
| **描边 + 填充混合** | 250 个 `<path>` 里大部分是描边 | 多数 |

去掉 `<mask>` 的 `archiveOff` 就是**另一个图标**（"归档"而不是"已归档"）。

## Decision

### 一、机生成 Dart，与原型**同一份来源**

`app/tools/extract-dsh-icons-dart.mjs` 读 `mock/proto/icons.js`，产出
`app/lib/theme/dsh_icons.dart`（98 个图标 + `DshIcon` widget）。

**手抄一份 Dart 表是不行的**：那等于开第二个来源，而两边偏差**不会报错**。

实现放在 `app/tools/dsh_icons.template.dart`（一个普通 Dart 文件，带 `@@…@@` 占位符）。
**不把 Dart 源码写成 JS 模板字符串**：Dart 的文档注释里全是反引号，
塞进模板字符串会直接语法错误（踩过一次）。

### 二、颜色在**编译期**替换，不交给 `currentColor`

98 个图标**全部**用 `currentColor`，而 `flutter_svg` 对它支持有已知缺口
（flutter/flutter#158680、dnfield/flutter_svg#31）。
与其赌渲染器行为，不如在生成期就换成字面色值 ——
代价是一次字符串替换，收益是"颜色一定生效"不再依赖第三方实现细节。

### 三、按**默认尺寸烘焙**，缩放交给 `viewBox`

`icons.js` 的模板里有 `%%E:strokeWidth + 3%%` 这类算术表达式
（`archiveOff` / `microphone` / `treeCorner`），它们在 `size` 变化时
**会算出不同的几何**（实测：`treeCorner` 的 `x="8"` 在 size=20 时变成 `x="16"`）。

所以"让 Dart 填尺寸"要么得在 Dart 里重写那个求值器，要么几何错位。
而两者都不必要：**SVG 自己会缩放** —— 根节点有 `viewBox`，
只换 `width`/`height`、留着 `viewBox`，渲染器就等比缩放整幅图形。

### 四、门禁：`ui/` 不许出现 `Icons.*`

新增规则 `no-material-icons`（只适用于 `app/lib/ui/`）。
它**去掉注释后再匹配**，因为"说明为什么不用它"是好代码 ——
本项目在 `core-no-platform-import` 上踩过同一个坑（按正文 grep 会惩罚把规则写进代码的人）。

### 五、准入判据（可机械判定）

1. **98 个图标全部能构建**：`dsh_icons_test.dart` 逐个构建一遍
   （防"只有常用的那几个是好的"）。
2. **真的能渲染**：把 SVG 喂给 `flutter_svg` 并断言无异常 ——
   它解析失败时**不抛异常**（画成空白），所以"字符串长得对"不算证据。
3. **`ui/` 里没有 `Icons.*`**：门禁 + 变异校验。
4. **颜色真的进了 SVG**：断言产物里没有 `currentColor`。

## Alternatives considered

1. **做成图标字体（`IconData` / `flutter_icon_font`）**
   - 最强的理由：渲染最快（一个字形的开销），且 Flutter 原生支持 `Icon`。
   - 为何被否：表达不了 `<mask>` / `opacity` / 描边填充混合（见上表）。
     为 3 个图标改成位图、其余做字体，等于**两套图标机制** —— 而"哪张图走哪条路"
     会变成一个没人记得住的规则。更根本的是：DSH 的图标是**描边画**，
     字体化要做轮廓布尔运算，那是把矢量图形的正确性押在一次离线转换上。
2. **用 `flutter_svg` 直接渲染，颜色留给 `currentColor`**
   - 最强的理由：不用在生成期做替换，SVG 串就是上游原样，最"忠实"。
   - 为何被否：`flutter_svg` 对 `currentColor` 有已知缺口（两个 issue）。
     而 98 个图标**全部**依赖它 —— 赌注太大，收益只是省一次字符串替换。
3. **把尺寸留成占位符，让 Dart 填**
   - 最强的理由：一张表支持任意尺寸，产物更小。
   - 为何被否：`%%E:` 表达式在 size 变化时算出不同几何（实测），
     于是 Dart 侧得重写那个求值器 —— 那是把上游的实现细节抄一遍，
     而它一旦与上游不同步，图标就会**悄悄画歪**（没有报错）。
4. **只在 UI 里手写 11 个图标对应的 DSH 名字（不做机生成）**
   - 最强的理由：11 个比 98 个小得多，手写"看得见"。
   - 为何被否：那还是两个来源 —— App 里那 11 个会与原型漂移，
     而漂移不报错。而且下一屏需要新图标时，又会有人"顺手"恢复这个做法。
     机生成的成本是一次 60 行的脚本，收益是**结构上不可能漂移**。

## Consequences

- 收益：**原型与 App 的图标定义上不可能漂移**（同一份 `icons.js`）。
- 收益：**门禁拦住了回归**。变异校验：把 `send` 换回 `Icons.send` → 门禁立刻红。
- 收益：`dsh_icons.dart` 是生成物（83 KB / 333 行），
  98 个图标里有 3 个的"表达式几何"由 JS 求值器算准，Dart 侧不碰表达式。
- 代价：多一个依赖 `flutter_svg`（它带 `vector_graphics` 等 9 个传递依赖）。
  这是**必须有**的一类：图标是 SVG，而 Flutter 核心不含 SVG 渲染。
- 代价：`dsh_icons.dart` 在仓库里（83 KB）。它是生成物但不该 gitignore —
  与 `mock/proto/icons.js` 同理：**它是"可复现的产物"，而不是"构建中间物"**，
  进仓库让 CI/评审能看到它的变化。
- **仍未做**：图标**选择的语义**（哪个屏用哪个图标）。`DshIcon` 只管画，
  选哪个是各屏的事。当前 UI 里 11 处选择是我按 DSH 语义挑的，
  完整的逐屏对照要等 UI 做全（`design-and-tech-plan.md` §7 的逐屏规格）。

## 落地时改动的文件

| 文件 | 做了什么 |
|---|---|
| `app/lib/theme/dsh_icons.dart` | **新增（生成物）**：98 个图标 + `DshIcon` widget |
| `app/tools/extract-dsh-icons-dart.mjs` | **新增**：读 `mock/proto/icons.js` 产出 Dart |
| `app/tools/dsh_icons.template.dart` | **新增**：Dart 侧实现（带 `@@…@@` 占位符） |
| `app/test/dsh_icons_test.dart` | **新增** 9 项：数量/结构/颜色/尺寸/比例/渲染/逐个构建 |
| `app/tools/verify-platform-boundary.mjs` | **改**：加 `no-material-icons` 规则 + 4 条自检 + `firstCodeUse` 辅助 |
| `app/lib/ui/{chat_page,pairing_page,session_list_page}.dart` | **改**：11 个 Material 图标换成 DSH 图标 |
| `app/pubspec.yaml` | **改**：加 `flutter_svg` |

证据：`flutter test` **156 项全绿**（新增 9 项图标）；
`dart analyze --fatal-infos` 0 问题；`verify-platform-boundary.mjs` **113 项**
（22 条自检）；图标测试里"98 个逐个构建"一次跑完无线程异常。

**两处变异校验**：① 把 `send` 换回 `Icons.send` → 门禁红并指名文件；
② 上一版测试里我把 `treeCorner` 的默认尺寸**猜成 10**（实际是 8）→ 测试红 ——
那条失败暴露的是**我的猜测**，而它顺带查出了"尺寸替换会误伤静态坐标"
（`archiveOff` 有 6 处 `="16"`）这个真问题。
