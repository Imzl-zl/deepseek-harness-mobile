# 缺实现就崩，别让用户等到"该响没响"

- 日期：2026-11-04
- 触发：巡检发现 `fallback-not-in-release` 休眠（指向不存在的 `registry.dart`、只认旧兜底名）；据"修"的指示叫醒它
- 状态：implemented

## 背景

2026-09-30 的三层拆分决策里写得很清楚：**兜底实现在 release 构建里被选中即启动 fail-fast，
不得静默降级**（`.agents/notes/archived/2026-09-30-capability-packages-over-per-platform-dirs.md`）。

代码实际是：

```dart
NotifyPort createNotifyPort() =>
    Platform.isAndroid ? AndroidNotify() : MemoryNotify();
```

也就是：iOS / 鸿蒙的 **release** 构建会拿到 `MemoryNotify` —— 通知组件永远"成功"，
但什么都没有发出去。**这类缺陷没有任何日志会指出来**，表现是"到了该提醒的时候静默"。

而本该拦它的那条规则也休眠着：路径指向不存在的 `app/lib/platform/registry.dart`，
兜底名字只认 `InMemory` / `NullPush` / `Noop`（现在叫 `MemoryNotify`）。
规则和数据同时失效，于是谁都没发现。

## 决定

1. **代码收敛到已定决策**：

```dart
NotifyPort createNotifyPort() {
  if (Platform.isAndroid) return AndroidNotify();
  if (!kReleaseMode) return MemoryNotify();
  throw UnsupportedError('这一端还没有通知实现（C1 能力必须每端实现）…');
}
```

2. **规则改写并唤醒**：扫 `app/lib/platform/<能力>_factory.dart`，出现兜底族
   （`Memory*` / `InMemory*` / `NullPush` / `Noop*`）就必须有守卫。

## 被否掉的

- **保持现状、只把休眠标注在文档里**：那是把"没人守"写成"我们知道没人守"。C1 早就定了，
  不执行只是没做完，不是新决定。
- **用 `kDebugMode` 做守卫**：`flutter run --profile -d windows`（性能调试）会直接崩。
  profile 不是发货产物；`kReleaseMode` 才是"用户手里那一份"的准确判据。
- **让 `MemoryNotify` 自己在构造里抛**：`test/notice_test.dart` 直接 `MemoryNotify()` 当替身用，
  抛在构造里会把整套通知语义测试打死。兜底本身没错，错的是在 release 里选中它。
- **只改代码、不醒规则**：下一个 `<能力>_factory.dart` 还会静默降级，而门禁看不见。
- **守卫判据只查"有没有 `kReleaseMode` 这个词"**：变异校验当场证明会被
  `import 'package:flutter/foundation.dart' show kReleaseMode;` 这一行骗过（见下）。

## 代价

- 非安卓平台在 **release** 下启动即崩 —— 这是有意的：iOS / 鸿蒙开工前必须先把 `notify` 实现补上，
  否则连"打个包跑起来看看"都做不到。debug / profile 不受影响。
- **这批改动没被工具链验证**：本机没有 Dart / Flutter SDK（`where dart` / `where flutter` 均为空），
  `dart analyze` 与 `flutter test` 都没跑。改动本身很小（一个 import + 一个 if 链），
  但"没跑就是没跑"，如实记在这里。

## 验证

- `node app/tools/verify-platform-boundary.mjs` → **720 项全绿**（31 条自检 + 164 个 Dart 文件）。
- **变异校验（第一次失败，暴露了规则自己的假阴性）**：删掉 `if (!kReleaseMode)`、只留
  doc 注释里的 `kReleaseMode` 字样 → 规则**仍然全绿**。原因：守卫检查匹配的是"出现这个词"，
  而 `import … show kReleaseMode;` 就是一行代码。
- **修好判据后重做**：守卫必须**用在分支里**（`kReleaseMode ? …` 或 `if (!kReleaseMode)`）。
  再删守卫 → **恰好 1 条红**：

  ```
  fallback-not-in-release: app/lib/platform/notify_factory.dart
    → 命中「装配点引用了兜底实现（MemoryNotify）但没有 release 守卫」
  ```

  还原 → 720 全绿。
- 把这个假阴性钉成常驻样本：`import … show kReleaseMode;` + 无守卫 → 必须红。
  （自检从 25 → 31 条，其中 4 条是这条规则的。）
