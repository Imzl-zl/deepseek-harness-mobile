# Agent Note: 图标抽取器加一条独立来源，并让 Dart 产物自己格式化

Status: implemented

## Problem

新会话页要用 DSH 的鱼 logo,而它不在现有图标集里。做这一件事时暴露了图标管线上的三个缺口:

1. **解析器漏掉一种函数写法**。`FishLogo.tsx` 是
   `export function FishLogo({ size = 24, className }: IconProps) {` —— **没有返回类型注解**,
   而 `parseDefs` 的正则要求 `)` 后面紧跟可选的 `: 类型` 再跟 `{`。中间那个空格让它
   整条匹配不上。症状是**静默漏掉一个图标**,不是报错(第一次跑就报"没有解析到定义",
   因为新加的那条来源有断言兜着;但同样的写法出现在已有的图标文件里就会悄悄少一个)。
2. **DSH 的 `PermissionIcon.tsx` 从 92 行长到 119 行**,多了一个 `PermissionIconAutoReview`
   家族。重跑抽取器才看见 —— 图标集与 DSH 已经漂了一阵。
3. **Dart 产物不是格式稳定的**。`extract-dsh-icons-dart.mjs` 每个图标写一行
   `'名': _IconArt(size, aspect, r'''<svg …/>'''),`,而 `dart format` 对**其中一部分**
   会拆成多行(判据是格式化器自己的,与字符串长度不是简单关系)。98 个图标那版恰好一条都不用拆,
   所以 `dart format --set-exit-if-changed` 一直是绿的;加上第 99、100 个当场就红,
   而红的位置指向一个**头部写着"不要手改"的生成文件**。

## Decision

鱼作为**一条独立的抽取来源**进 `mock/proto/tools/extract-dsh-icons.mjs`
(`DIRECT_ARTWORKS`:没有 `IconXxx` wrapper 的 artwork),解析器补上 `\)\s*`,
`permissionAutoReview` 归入权限图标家族,并且**Dart 生成器产出后自己跑一次 `dart format`**。

准入门槛(可机械判定):

1. **每个新图标都要有 GOLDEN 条目**(默认尺寸 + viewBox),对不上就红。
2. **鱼的形状单独断言**(`verify-icons.cjs` 第 12 节):根 `fill="none"`、颜色挂在
   `<path fill="currentColor">` 上、**全图没有一根 stroke**、只有一个 `<path>`、
   默认宽 24 而高度按 23.16:17.04 算。这四条里任一条被"顺手统一"成别的图标的画法,
   鱼就会变成一块黑或者干脆不显示。
3. **生成物必须在 `dart format --set-exit-if-changed` 下 0 变更**,而且这件事由
   **生成器**保证,不靠人记得补一步。
4. **从源码或文档里抽方法名的正则,服务名段必须写 `[A-Za-z]+`**。
   `agentPresets.list` 是驼峰服务名,而 `[a-z]+` 会让**整条匹配不上** ——
   门禁报"契约定义了 30 个"而表里明明有 31 行。

## Alternatives considered

1. 把鱼的 SVG 手抄进 `app/tools/dsh_icons.template.dart`
   - 最强的理由:一步到位,不用动抽取器,也不用管 DSH 那边的写法差异。
   - 为何被否:那正是"第二个来源"。template 的头部注释写着图标只有一个来源,
     而鱼与其余图标**画法本就不同**(纯填充剪影 vs 描边),手抄一份必然在上游改动时静默漂。
2. 把 `dart format` 留成人工步骤(在 `tools.md` 里写"改图标后记得跑")
   - 最强的理由:生成器不必依赖 Flutter SDK 的位置,产物逻辑保持纯粹。
   - 为何被否:"记得跑一下"这类步骤在本仓已经翻过车(`tools.md` 的方法数曾经
     静默漂移 28 条而没人发现)。而生成器本来就长在 `app/tools/` 下,
     跑它的人一定有 Flutter —— 找不到 `dart` 时**大声失败**,比产出一个过不了门禁的文件好。
3. 让生成器直接产出"已格式化"的形状(把长条目拆成多行)
   - 最强的理由:不依赖任何外部命令,产物完全确定。
   - 为何被否:那等于把 `dart format` 的换行启发式在 JS 里抄一份,格式化器一改版就漂,
     而且漂的方式同样是"门禁红在一个不许手改的文件上"。
4. 把 `permissionAutoReview` 按机械规则命名成 `permissionIconAutoReview`
   - 最强的理由:名字完全由规则推导,不引入第二份名单。
   - 为何被否:四个权限图标是**一个家族**,三个短名一个长名就是陷阱 ——
     写错的那个调用点得到的是断言失败后的一块巨大 ErrorWidget(整个页面变红),
     而 `verify-icons.cjs` 第 12 条存在的理由就是这个失败形态。

## Consequences

- 收益:hero 的鱼来自唯一来源;图标集重新与 DSH 对齐(100 个,含新出现的权限图标);
  "生成物与格式门禁互相打架"这个缺口关掉了。
- 收益:解析器的空格缺口被堵上,而且是**有断言兜着**堵的(新来源解析不到就直接退出)。
- 代价:生成器多了一个对 `dart` 可执行文件的**运行时依赖**,没有它就直接失败并退出 2。
- 代价:`EXPLICIT_NAMES` / `GOLDEN` / `REQUIRED` / `PERMISSIONS` 四张表都要跟着新图标维护 ——
  这是有意的,它们就是"图标集变了要有人看一眼"的那道闸。
- 代价:DSH 再换一种函数写法时,抽取器会**报错而不是静默少一个图标**。
  这是刻意的取舍:报错要人去看一眼,静默少一个图标没人会看。
