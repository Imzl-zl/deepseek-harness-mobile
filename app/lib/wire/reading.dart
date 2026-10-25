/// 线上载荷的解码内核：**三态、可计数、只有一处出声**。
///
/// 这一层不认任何具体事件或方法 —— 它只定义"读到了 / 不归我 / 读不出来"这三种结局，
/// 以及读不出来时唯一的出口。具体形状在：
///
/// - `wire/events.dart` —— 会话事件（`ev` 帧的 `type` + `data`）
/// - `wire/rpc/*.dart` —— RPC 应答（一个方法族一个文件，形状出处写 `connector/...:行号`）
///
/// ## 为什么需要三态（而不是可空）
///
/// `null` 在消费方已经被"这条载荷与我要找的东西无关"占用了（例如 `user/message` 里
/// 绝大多数都不是提问答复）。让它同时表示"我读不懂"，就会出现 2026-10-25 那种形态：
/// 事件到了、不报错、卡不开、日志干净。
///
/// ## 为什么出声只有一个出口
///
/// 出声这件事一旦能被忘记，就一定会有地方忘。[valueOrReport] 把"计数 + 交付"绑在一起：
/// 调用方拿到的 `null` 只剩一个含义。只有"失败马上会更响"的地方（`items.dart` 的
/// `itemIdOf` 缺身份直接抛）才允许用 [valueOrNull]。
///
/// ## 为什么这一层是纯 Dart
///
/// `items.dart` 至今零 Flutter 依赖（`flutter test` 之外也能跑）。打印由**装配点**装进来
/// （`main.dart` 在 `kDebugMode` 下接 `debugPrint`），这一层不决定往哪儿写。
///
/// Note: 设计取舍与七个批次的搬运顺序见 `.agents/notes/proposed/2026-10-25-wire-design-review.md`。
library;

// ---------------------------------------------------------------------------
// 读取结果：三态，不是可空
// ---------------------------------------------------------------------------

/// 一次解码的结果。**没有"可空"这一档**：`null` 说不清"不是我要找的东西"还是"形状读不出来"。
sealed class WireReading<T> {
  const WireReading();
}

/// 读出来了。
final class WireOk<T> extends WireReading<T> {
  const WireOk(this.value);

  final T value;
}

/// 这条载荷不是这个 decoder 管的（例如 `assistant/message` 里没有交互信息）。
///
/// **不是错误**：绝大多数载荷都会落到这一档。
final class WireSkip<T> extends WireReading<T> {
  const WireSkip();
}

/// 形状读不出来：字段缺失、类型不对、JSON 坏。**这是要命的，必须响**。
///
/// [detail] 是给人看的一句话（哪个字段、期望什么、实际什么），不是给机器判的码 ——
/// 它唯一的用途是让下一次"卡不出现"能在五分钟内定位。
final class WireBad<T> extends WireReading<T> {
  const WireBad(this.detail);

  final String detail;
}

/// 形状读不出来的唯一出口。
///
/// 计数是给回放用例与排错用的（`badCount == 0` 才说明线上的形状没漂）；
/// 打印由**装配点**装进来 —— 这一层不决定往哪儿写。
///
/// 为什么默认什么都不打也不等于"静默降级"：**计数照加**，而回放用例与排错面板读的是计数；
/// 打不打印只是给人看的第二层。App 不打 logcat（`tools.md` 记过），所以真正可用的判据是计数。
class WireDiagnostics {
  WireDiagnostics._();

  static int _bad = 0;

  /// 累计的形状错误条数（`reset()` 之后重新计）。
  static int get badCount => _bad;

  /// 换成别的出口（装配点接 `debugPrint`、测试收集、排错面板）。
  static void Function(String event, String detail)? sink;

  static void reset() {
    _bad = 0;
  }

  static void report(String event, String detail) {
    _bad += 1;
    sink?.call(event, detail);
  }
}

/// 把一次读取落到值上：[WireBad] 在这里**统一出声**，调用方只处理"有没有值"。
///
/// 为什么不让调用方各自 `switch`：出声这件事一旦可以被忘记，就一定会有地方忘
/// （这正是 2026-10-25 的形态）。收在这里之后，`null` 的含义重新变回"这条不是我要的"。
T? valueOrReport<T>(WireReading<T> reading, String event) {
  switch (reading) {
    case WireOk<T>(:final value):
      return value;
    case WireSkip<T>():
      return null;
    case WireBad<T>(:final detail):
      WireDiagnostics.report(event, detail);
      return null;
  }
}

/// 只取值，**不出声** —— 给"读不出来马上就会更响地失败"的调用方（`items.dart` 的
/// `itemIdOf` 缺身份时直接 `throw StateError`，那是比一行打印更强的信号）。
///
/// 除这一种情形外一律用 [valueOrReport]：能安静返回 `null` 的地方，它必然会安静。
T? valueOrNull<T>(WireReading<T> reading) {
  switch (reading) {
    case WireOk<T>(:final value):
      return value;
    case WireSkip<T>():
    case WireBad<T>():
      return null;
  }
}
