# Agent Note: 市场截图在 connector/screenshots.json 显式声明，图片只留一份

Status: implemented

## Problem

`connector/` 是 monorepo 子包，列表条目指向这个目录；而不声明截图时，市场会退回从 README 抽图，抽图起点落在哪一份 README 上并不明确。`connector/README.md` 里唯一一张界面图是电脑侧的「手机」面板，手机界面一张都抽不到 —— 而这份插件卖的正是「手机上用」。

不把这一层写下来，后来者最容易走的两条弯路是：把 `docs/assets/` 的图复制进 `connector/` 换相对路径（同一批图出现两份真值），或者直接写 `../docs/assets/app-chat.png` —— 列表明确禁止 `..` 越出插件目录，会被判无效。

## Decision

在同一目录放 `connector/screenshots.json`，用 GitHub 托管的绝对地址列出 3 张已有图片；图片不复制、不搬家，只在 `docs/assets/` 存在一份。

准入门槛：

1. 位置：`screenshots.json` 与 `package.json` 同目录（`connector/`），1–8 个条目。
2. 不越界：相对路径不得含 `..` 或以 `/` 开头；因图片在 `docs/assets/`，一律写 `https://raw.githubusercontent.com/...`。
3. 单一真值：图片只存在于 `docs/assets/`，禁止复制进 `connector/`。
4. 不声明 `icon`：仓库内只有 `logo.svg`，列表拒 SVG；没有方形位图就不写，交给作者头像兜底。

## Alternatives considered

1. 什么都不做，靠市场从 README 抽图
   - 最强的理由：零成本、零新格式，列表里 star 前 15 的条目没有一个自带 `screenshots.json`，主流就是这么处理的。
   - 为何被否：抽图起点不确定，且 `connector/README.md` 的唯一界面图是电脑侧面板，手机界面一张都抽不到；这个插件卖的正是「手机上用」。
2. 把 3 张图复制进 `connector/assets/`，改用相对路径
   - 最强的理由：相对路径在仓库里改名立刻可见，不像绝对 URL 那样静默失效 —— 列表已发布的 773 张截图里有 41 张就是这么 404 的。
   - 为何被否：同一批图变成两份真值，改一张要记得改两处；宁可接受绝对 URL 的失效风险，也不接受同一份内容存在第二个落点。
3. 顺手补一张 `icon-180.png`
   - 最强的理由：市场卡片有专属图标，比回退作者头像更像成品；用这个文件名的占已声明 `icon` 条目的 58%。
   - 为何被否：仓库里只有 `logo.svg`，规则拒 SVG，要为此栅格化并提交一张二进制；且 `icon` 的使用面在退潮（全站 9%、最近 200 条 4%、star 前 200 仅 1 个）。等真有方形位图再补。

## Consequences

- 收益：市场详情页拿到 3 张按指定顺序排列的图，手机界面在前；换图推自己仓库即可，不必再走列表的 PR。
- 代价：多出一份「图片清单」需要与 `docs/assets/` 同步，改名会静默 404（绝对 URL 的固有代价）；生效在下次夜间构建，不是即时的。
- `screenshots.json` 是 JSON，没有注释语法，回指放在 `connector/README.md` 的「开发与门禁」一节。
