# Agent Note: 两处视觉缺陷 —— 空态文字没居中、底部漏出一条 sidebar 色

Status: implemented

## 一、子智能体/任务的空态文字不居中

用户：「子智能体空态文字不居中看着好难受」。

`side_pane.dart` 的 `_JobPanel`：

```dart
if (jobs.isEmpty) {
  return Center(child: Text(emptyText, style: ...));   // ← 没有 textAlign
}
```

`Center` 只把**这个 `Text` 盒子**放到中间；盒子里的多行文本仍按 `start` 对齐。
子智能体那句是「没有子智能体（数据来自会话投影 subagentCatalog）。」——
较长，会折成两行，**折行后每行在盒子内左对齐**，看起来就是没居中。

修法：`textAlign: TextAlign.center` + 左右 24 留白（否则长句贴着边缘折）+ 行高
`20/13`（与其它说明文字一致）。

## 二、页面底部漏出一条 `sidebar` 色（"有一块没覆盖"）

实测（真机 1080×2400，深色，`x=30` 竖向扫描）：
`#151517`（页面）一直到 `y=2341`，**`y=2343` 起到屏幕底是 `#1B1B1C`**
—— 正好是 `c.sidebar` 的暗色值，高度 ≈ `系统导航条 + 6`。

根因：`chat_page.dart` 里输入区外面的包裹层还是 `c.sidebar`：

```dart
Container(
  color: c.sidebar,                                   // ← 罪魁
  padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 6),
```

而输入栏内部（`DshComposer`）此前为了去掉灰带已改成 `bgBase`
（见 `2026-10-20-composer-elevation-soft.md`）。于是：

> **灰带并没有被"去掉"，只是被挤进了底部那条 `padding.bottom + 6` 的缝里。**

`DshComposer` 盖不到那 19dp，露出来的就是外层的 `sidebar`。

修法：外层 `color` 也改 `bgBase`（DSH 里输入区就坐在页面底色上，
外层没有自己的底色）。修后实测 `2330→2399` 全是 `#151517`，缝消失。

## 三、顺带补上的：系统栏外观跟主题走

`lib/` 里此前**完全没有** `SystemChrome` / `AnnotatedRegion`，状态栏与导航栏
外观一直交给系统默认（深色应用 + 浅色系统 = 顶部图标看不清）。

按 SDK 文档（不是猜）：
- `SystemUiMode` 的枚举注释：「If your app targets Android SDK 16 (API 36) or
  later, then the Android system will ignore this value」——本机 API 36、
  `targetSdk` 36，所以那条路无效；
- `SystemUiMode.edgeToEdge` 注释指明系统栏**永久显示在应用之上**，并指向
  `SystemUiOverlayStyle`：「can be used to configure transparent status and
  navigation bars with or without a contrast scrim」。

所以在 `MaterialApp.builder` 里包一层 `AnnotatedRegion<SystemUiOverlayStyle>`：
两条栏都 `Colors.transparent`，`statusBarIconBrightness` /
`systemNavigationBarIconBrightness` 跟随主题，iOS 的 `statusBarBrightness`
按平台习惯给反值。用 `AnnotatedRegion` 而非 `SystemChrome.setSystemUIOverlayStyle`：
前者声明式、随主题生效，后者是命令式全局副作用，主题热切换时会漂移。

**注意**：这条**不是**底部那条缝的原因（缝是我们自己的 `sidebar`），
它修的是"系统栏图标与底色不跟主题"这个独立问题。

## 验证

- 真机（API 36，深色）：底部 `x=30` 从 `2330` 到 `2399` 全程 `#151517`。
- `flutter test 888` / `analyze 0` / `format 0`。
