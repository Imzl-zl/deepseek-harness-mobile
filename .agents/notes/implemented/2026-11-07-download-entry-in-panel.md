# Agent Note: 插件面板里给出 App 的下载入口

Status: implemented

## Problem

插件装完、面板打开，「配对新手机」这一步的下一步是**手机上装 App** —— 但 App 不在 npm 上，
也不在电脑上，用户手里很可能还没有。README 里有下载地址，可他此刻正盯着面板，
回头去翻仓库是多余的一跳（2026-11-07 用户原话：需要放一个下载 App 的链接，要不然不知道从哪下载）。

## Decision

1. 「配对新手机」卡在「出配对码」下面加一行：**还没装手机 App？〔下载最新版〕**，
   按钮把 `https://github.com/Imzl-zl/deepseek-harness-mobile/releases/latest` 开在新标签页。
2. 指向 `releases/latest` 而不是钉某个版本：Release 资产名带版本号，钉版本就得跟着改代码；
   `latest` 永远是最新一版，和面板「版本」卡的「检查更新」是同一个出口。
3. 入口只放在**配对**这张卡上，不再往总览/版本卡重复一遍 —— 同一件事只说一次。

## Alternatives considered

1. **只在 README 里写清楚**
   - 为何被否：用户走到面板那一刻才是"缺 App"的时刻；README 只能覆盖"先读文档"的人。
2. **做成二维码（把 APK 地址编成码）**
   - 为何被否：扫码装 APK 要走系统下载器 + 未知来源授权，比点一下链接再传过去更绕；
     而且手机若已经能扫码，说明人就在电脑边上，直接点链接更快。

## Consequences

- 插件版本提到 **0.1.22**（面板文案与按钮属于插件产物，不升版用户拿不到）。
- `client-i18n` 的 zh/en 键集合同步加了 `noAppHint` / `downloadApp`（少一个键那半边界面就是 undefined）。
- README 重排了一次：**下载**单独成节，App 与插件两条路径各自给出口。
