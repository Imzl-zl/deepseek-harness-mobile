# 手机端多端边界(iOS / 安卓 / 鸿蒙)

结论:**三层,每层判据不同**。

- **第一层 共享内核**(协议、恢复引擎、本地库、领域模型、状态机)——共享,且**禁止分叉**。
- **第二层 共享信息架构与品牌呈现**(视觉体系、逐屏结构、时间线/甘特/diff 等复杂渲染)——共享,但**系统紧耦合控件一律跟平台惯例**。
- **第三层 每端专属表达**——凡"App 不在前台也要存在"的能力,**必须每端实现**。这一层是本产品的体验上限所在,不是"以后再说"的优化项。

判据见 §3;取舍理由与三条被否方案见 `.agents/notes/proposed/2026-09-30-experience-first-three-layer-split.md`。通道契约见 `remote-channel.md`。

## 1. 结构

```text
app/
├── lib/
│   ├── core/       纯 Dart 零平台依赖:通道客户端、流帧解析、恢复引擎、消息 reducer
│   ├── data/       DTO / 协议编解码、存储与密钥的注入接口
│   ├── model/      领域模型(session / item / job / notice)
│   ├── theme/      DSH token(三端唯一颜色与字体来源)
│   ├── ui/         逐屏 widget(信息架构与品牌呈现)
│   │   └── adaptive/   ★ 系统紧耦合控件的平台惯例实现,业务 UI 只调这一层
│   ├── platform/   ★ 唯一装配点:选择各能力的实现,不写业务
│   └── main.dart
├── packages/       ★ 按能力切,不按端切
│   ├── secure_store/ (+_ios/_android/_ohos)   系统密钥库
│   ├── notify/       (+_ios/_android/_ohos)   通知:投递、分类、可操作按钮
│   ├── live_surface/ (+_ios/_android/_ohos)   不在前台时的持续表达(见 §2)
│   ├── widgets/      (+_ios/_android/_ohos)   主屏 / 锁屏入口(可选)
│   └── keepalive/    (+_android)              前台服务(可选,尽力而为)
├── ios/ android/ ohos/   壳工程;各端原生代码只住在这里
└── tools/                多端边界校验脚本
```

按能力切而不是按端切:"一个端一个目录"会让"支持第四个平台"变成复制整个 app,而三份 UI 必然漂移。**平台差异的爆炸半径必须限制在 `packages/` 与 `ui/adaptive/` 之内。**

## 2. 第三层的真相:三端体验并不对等(已核实)

这是本节最重要的事实——**不能承诺三端一致的"锁屏看进度"**,因为三个平台给的上限不同:

| 体验目标 | iOS | 安卓 | 鸿蒙 NEXT |
|---|---|---|---|
| **App 未运行/被强杀时,服务端仍能刷新展示** | **能**。官方原文:"life cycles aren't tied to the host app's process, so they'll stay if the app is force quit" | **通知本体可更新,但投递受限**:force-stop 后 FCM 投递不到(大陆还只能用厂商通道) | **实况窗能**("保证实况窗不依赖应用进程的存活"),但本场景不满足其准入条件(见下行) |
| **跑动中持续显示进度** | **支持**。Live Activity 最长活跃 **8 小时**,锁屏最多 **12 小时**;载荷 ≤ **4KB**;可用 push-to-start 在 App 未启动时创建 | **受限**。`Notification.ProgressStyle` 是 API 36(Android 16)新增;而 Live Update 的使用标准明文 **"Don't allow activities triggered by other parties to generate Live Updates"** | **不支持**。实况窗 PROGRESS 场景官方限定"**用户手动开启**的文件上传/下载、资源导入导出",并明确**不适用后台自动任务**;且 Push Kit 创建仅支持 10 个场景、**不含 PROGRESS** |
| **通知上直接审批** | 支持(通知 action;空间充足最多 10 个、受限时 2 个) | 支持(官方称可 "often without opening an activity") | 未核实(未取到通知按钮/`wantAgent` 官方文档) |
| **主屏/锁屏入口** | 锁屏小组件 + Live Activity 锁屏常态 | 通知锁屏展示 + 小组件(周期刷新 ≥30 分钟) | 服务卡片(可 Push 刷新,但"其他"垂类每日仅 **5 条**) |
| **关键节点通知** | 支持 | 支持 | 支持,但**未申请自分类权益时默认资讯营销类:静默、每日 2 条**(只有"新闻"类是 5 条) |

由此产生三条**必须写进产品**的设计决定:

1. **iOS 是唯一能"锁屏常驻看进度"的一端**,把它做到最好:Live Activity 承载当前任务;更新按**状态变化**推送而不是定时推送(官方承认存在"每小时预算",但**未公布条数**,所以不能按固定频率设计)。超过 8 小时的任务:活动到期后系统自动结束,**降级为普通通知**,完成时再提醒——不要承诺"通宵任务全程挂在锁屏上"。
2. **安卓的 Live Update 有合规闸门**:只对**在本机发起的任务**(用户在手机上点了开始或批准)使用提升通知;电脑上启动的任务一律用普通进度通知 + 通知操作按钮。这条同时是合规要求与可机械判定的规则(任务的发起端是 phone 还是 computer)。
3. **鸿蒙不做"跑动中进度"**:实况窗在准入与场景两侧都排除了本场景,服务卡片的每日额度也撑不住进度刷新。鸿蒙端只做**关键节点通知**(开始 / 待审批 / 完成 / 失败),并且**必须申请"服务与通讯类"权益**(工作是 WORK 场景),否则默认静默且每日 2 条。

依据:iOS [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)、[Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)、[10 questions with the Live Activities team（2023-03-20）](https://developer.apple.com/news/?id=qpqf1gru);Android [Progress-centric notifications](https://developer.android.com/about/versions/16/features/progress-centric-notifications)、[Create live update notifications](https://developer.android.com/develop/ui/compose/notifications/live-update)、[About notifications](https://developer.android.com/develop/ui/compose/notifications)、[FGS 超时](https://developer.android.com/develop/background-work/services/fgs/timeout);鸿蒙 [Live View Kit 简介](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/liveview-introduction)、[实况窗生命周期](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/liveview-faq-3)、[ArkTS 卡片 Push 刷新](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/arkts-ui-widget-update-by-push)、[申请推送场景化消息权益](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-apply-right)。

## 3. 判据(可判定或可留痕)

1. **C1(机器判定)该能力是否需要在 App 不在前台或已被杀时工作?** 是 ⇒ 必须每端实现,归 `packages/<能力>_<端>/` + 壳工程原生代码;**禁止试图用共享 UI 实现**。
2. **C2(机器判定)该控件是否是用户凭肌肉记忆操作的系统紧耦合控件?**(导航转场、返回手势、下拉刷新、文本选择菜单、分享面板、开关/选择器/对话框/进度指示、触觉反馈) 是 ⇒ 必须跟平台惯例:能用官方自适应构造器就用,官方没有的进 `ui/adaptive/`,业务 UI 只调这一层。
3. **C3(评审留痕)该组件的复杂度是否高到三端重写会显著抬升不一致风险?**(流式 Markdown、时间线/甘特、diff 渲染、轨迹投影) 是 ⇒ 留在共享层。**按复杂度划边界,不按平台划边界。**
4. **C4(评审留痕)该元素是否承载产品识别度与信息架构?** 是 ⇒ 共享,且禁止按端改。
5. **C5(禁止项)不得因为"这样写更快"而分叉;也不得因为"看起来整齐"而把 C2 类控件强行统一。**
6. **C6 每个平台必须有一名 advocate**,持有该平台的惯例清单并对其体验负责。

`lib/core`、`lib/data`、`lib/model` 不得出现 `dart:io`、`package:flutter/services.dart`、`widgets.dart`、`material.dart`、`Platform.`、`defaultTargetPlatform`、`MethodChannel`、`EventChannel`;**平台分支只允许出现在 `packages/*`、`lib/platform/` 与 `lib/ui/adaptive/`**;`ui/adaptive/` 只放"选哪个平台实现"的控件,不放业务。

### 3.1 官方已自动适配的(不用自己管)

页面转场、返回手势(Android 返回键 / iOS 边缘滑动)、滚动物理与 overscroll、滚动条、图标方向、字体、触觉反馈、文本编辑手势。

一个容易做错的地方:**`MaterialPageRoute` 本身就是"platform-adaptive transition"**,转场由 `PageTransitionsTheme` 按 `TargetPlatform` 选 builder → **不要自己切 `CupertinoPageRoute`**。本次扫描的 5 个主流 Flutter 项目里,`CupertinoApp` 与 `CupertinoPageRoute` 出现次数**均为 0**。UI 里判断平台用 `Theme.of(context).platform`(官方口径:`dart:io.Platform` 只在"确实需要知道当前平台、且不允许被覆盖"时用)。

### 3.2 官方只有 7 个 `.adaptive()` 构造器

`Switch` / `Slider` / `CircularProgressIndicator` / `RefreshIndicator` / `Checkbox` / `Radio` / `AlertDialog`。清单之外**没有** `AppBar`、`TextField`、底部导航、`ListTile`、`SegmentedButton`、`NavigationBar`。

→ 这就是 `ui/adaptive/` 必须由我们自己维护的原因:官方的自适应脚手架包 `flutter_adaptive_scaffold` 已于 **2025-05 停止更新并标记 discontinued**,且没有官方接续方案(社区替代包的采用量差两到三个数量级)。**这一层是我们的资产,不是从框架白拿的。**

### 3.3 官方明确要求"设计期决策"的项(框架不会替你适配)

官方原话是这些"need to be answered at design time rather than implementation time":AppBar 样式与动作、TextField 装饰、底部导航形态(tab 平行栈 vs drawer 侧向导航——官方承认这会产生"entirely different app experiences")、对话框选项数、bottom sheet vs action sheet、segmented control。

**这一类的答案由产品定,不由平台定。** 我们的答案已定在 `design-and-tech-plan.md`(信息架构与逐屏规格),不因平台不同而改。

## 4. 版本闸门

- **三端共用一条 Flutter 版本线,上界由鸿蒙 fork 决定**:CPF-Flutter 当前稳定分支基于上游 **3.35.7**,其规划表把 3.44 排在 2026/09、3.47 排在 2026/12(页面自标"预估")。**不允许 iOS/安卓单独升到更新版本**——否则 Dart 侧 import 会分叉。
- **禁止 `Platform.isOhos`**:CPF 官方 FAQ 明确它会**导致 `flutter run` / `flutter build har` / `flutter attach` 失败**。判断鸿蒙一律用 `defaultTargetPlatform == TargetPlatform.ohos`;若同一份代码还要能用上游 SDK 编译,用 `Platform.operatingSystem == 'ohos'`(明确不是 `Platform.isOhos`)。此条有门禁(§6)。
- **Flutter 3.47 起 Material / Cupertino 已拆成独立包**(`material_ui` / `cupertino_ui`),而鸿蒙 fork 是否包含该拆分**未找到证据** → 这也是"锁一条版本线"的第二个理由。

## 5. 已知缺口(必须自己处理)

- **iOS 返回手势 + `PopScope`**:`canPop:false` 时 iOS 边缘返回手势不触发 `onPopInvoked`(flutter#138624,open,P2,91 reactions)。我们的抽屉手势与全屏页正走在这条路径上 → 真机验收必测。
- **Android 预测性返回**:必须在 manifest 开 `enableOnBackInvokedCallback`,用 `PopScope` + `onPopInvokedWithResult`;自定义转场要自己覆盖 `handleCommitBackGesture`(flutter#184653,open)。
- **自定义文本选择菜单**:官方只提供默认路径的 `AdaptiveTextSelectionToolbar`;自绘选择区等于两端各实现一遍。
- **系统"减弱动效"**:本次未找到跨端官方等价 API(LocalSend 的做法是三端各写一条原生通道) → 按 C1 处理,进能力包。
- **鸿蒙侧已知问题**(CPF 官方 FAQ 索引):`Platform.isOhos` 构建失败、TabBar/TabBarView 手势冲突、输入框长按无法粘贴、安全避让区异常、混淆导致白屏 → 鸿蒙端必须在真机过一遍这份清单。

## 6. 验证

- `node app/tools/verify-platform-boundary.mjs` —— 静态扫描 `lib/` 与 `packages/`,拦 §3 的 import 与分支规则,外加 **§4 的 `Platform.isOhos` 禁令**。脚本自带规则自检,因此 `lib/` 还没有代码时也不是空转。
- 共享 UI 的适配正确性**不能靠"看起来一致"验收**:按 §3.1 的白名单逐项确认"确实是框架自动适配的"、按 §3.2 确认 7 个控件用了 `.adaptive()`、按 §5 的缺口清单在真机上过一遍返回手势与预测性返回。
- 三端专属表达**必须在真机上验收**(锁屏、强杀后、通知上操作),模拟器与调试构建不作数:iOS 的调试构建与线上在推送预算上行为不同,安卓的 force-stop 只能在真机复现。

## 7. 重新评估条件

若产品形态变成**手势与延迟敏感的自绘工具**(Figma / Linear 那一类,UI 本身就是产品),第一、二层应重新评估为"每端原生 UI、只共享核心"。本产品不是那一类:它的体验上限在"不在前台时的表达",不在自绘 UI。
