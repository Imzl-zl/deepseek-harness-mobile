# Agent Note: 两端各一个「检查更新」，都是只读、都不自动装

Status: implemented

## Problem

两端都没有"我是不是最新版"的入口：

- 电脑侧插件面板只有"当前配置"，装完就再也不知道 npm 上有没有新版；
- 手机 App 只能等用户自己去刷 GitHub Release 页（项目没上任何商店）。

用户原话：「你没给我插件做一个检查更新的能力啊？加一个吧，还有 APP 有自动检查更新吗？」

## Decision

1. **插件**：面板底部一张「版本」卡 —— 显示当前版本（读自己的 `package.json`），
   点「检查更新」问**电脑侧** `GET /api/dsh-mobile/update`，电脑代查
   npm registry 的 `latest`，回 `{current, latest, hasUpdate, url, checkedAt, error?}`。
2. **App**：设置页「关于与连接」加一行「检查更新」；启动时**静默查一次**（不弹窗、
   不打断），结论落在那一行；点它重查并给 toast。查询走 `platform/update_checker.dart`
   问 GitHub Releases 的 `releases/latest`。
3. **两端都不自动下载 / 不自动安装**：这是"查一下"的能力，不是更新器。
4. **查不到 ≠ 已是最新**：失败时 `latest` 为空并带 `error`，界面显示
   「查不到最新版本：<原话>」。平台层不注入 `APP_VERSION` 时本机是 `dev`，
   此时**不参与比对**（否则永远在报有新版）。

准入门槛（可机械判定）：

1. 插件：查到新版 ⇒ 卡片显示「有新版本 x.y.z」+ 一个 npm 页按钮；查不到 ⇒ 显示原因。
2. App：`isNewerVersion('0.2.9','0.2.10')` 为真（按数字段）；预发布不算新。
3. App：`current == 'dev'` ⇒ `comparable == false`、`hasUpdate == false`。
4. 失败结论的 `label` 是「查不到最新版本」，不是「已是最新」。

## Alternatives considered

1. **浏览器直连 npm / GitHub**
   - 最强的理由：不用加服务端路由与平台层。
   - 为何被否：CORS、内网代理、公司网关三件事都会分叉；而"这台机器够不够得着 npm"
     本来就是电脑侧的事实（插件就是它装的）。
2. **用 GitHub Release 当插件的版本真值**
   - 最强的理由：一个源同时覆盖 App 与插件。
   - 为何被否：`v*` 标签是**App** 的版本节奏（`v0.2.3` 里的插件是 `0.1.9`），
     拿它判插件会给出错误结论。插件的真值是 npm 的 `latest`。
3. **装个更新器（自动下载 APK / 自动跑 pnpm add）**
   - 最强的理由：用户一步到位。
   - 为何被否：手机侧要处理"下载 + 未知来源安装 + 签名校验"，插件侧要替用户跑包管理器；
     两头都是新的权限面与失败面。先给"知道有没有新版"，安装仍由用户决定。

## Consequences

- 收益：两端都能一眼回答"是不是最新"；插件顺带把版本号显示在面板上（排错有用）。
- 代价：多一条只读路由（`/api/dsh-mobile/update`）与一个平台层文件；
  App 启动多一次网络请求（失败静默，只记录在设置页那一行）。
- 代价：`APP_VERSION` 必须在构建期注入 —— release.yml 用标签、ci.yml 用短 sha，
  否则本机是 `dev` 且不参与比对。

## 判据

- connector **825 项**全绿（`update.test.ts` 5 条 + `admin-face` 路由表 + 面板卡片）；
- app **1673 项**全绿（`app_update_test.dart` 11 条）；
- `tsc --noEmit` 0、`dart analyze --fatal-infos lib test` 0、boundary 706 项通过。

## 代码入口回指

- 插件：`connector/src/admin/update.ts`、`admin/routes.ts` 的 `UPDATE_PATH`、
  `index.ts` 的 `connectorVersion()`、`client.js` 的「版本」卡与 `checkUpdate`。
- App：`app/lib/core/app_update.dart`、`platform/update_checker.dart`、
  `data/app_model.dart` 的 `checkAppUpdate`、`ui/settings_page.dart` 的那一行；
  `main.dart` 启动时 `unawaited(app.checkAppUpdate())`。
- CI：`.github/workflows/release.yml` / `ci.yml` 的 `--dart-define=APP_VERSION`。
