/// 同一会话的投影重读**不并发**：在飞时只攒一次（连来十次也只补一次）。
///
/// ## 为什么需要它
///
/// `turn/end` 与"队列变了"经常挤在同一批事件里，两条信号直接各发一次
/// `session.projections` 会**两个应答乱序落地** —— 后到的旧包会把先到的新包
/// 盖掉（投影包没有版本号可比，手机上分不出谁更新）。合并成"在飞 + 攒一次"
/// 就只有一个应答会落地。
///
/// ## 为什么搬出 `AppModel`
///
/// 它是一格自成体系的状态（在飞集合 + 攒着的集合 + 收尾时补跑），与
/// `AppModel` 的其余部分没有别的耦合；尺寸棘轮（`verify-size.mjs`）要求
/// `app_model.dart` 只降不升，这一格正好可以整体搬走（2026-11-21）。
library;

import 'dart:async';

class ProjectionCoalescer {
  ProjectionCoalescer(this._read);

  /// 真正发一次读取（`AppModel.refreshProjections`）。
  final Future<void> Function(String sid) _read;

  /// 正在飞的会话。
  final Set<String> _inFlight = <String>{};

  /// 在飞期间又被要求重读一次的会话。
  final Set<String> _queued = <String>{};

  /// 请求重读 [sid]：没在飞就立即发，在飞就只记一笔。
  void request(String sid) {
    if (!_inFlight.add(sid)) {
      _queued.add(sid);
      return;
    }
    unawaited(
      _read(sid).whenComplete(() {
        _inFlight.remove(sid);
        if (_queued.remove(sid)) request(sid);
      }),
    );
  }
}
