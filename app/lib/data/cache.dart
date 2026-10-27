/// 以**源对象身份**为键的单槽缓存。
///
/// ## 它替代了什么
///
/// `AppModel` 里原本有四处同一个形状，各自手写命中判断：
/// `_changedFilesCache` / `_pathsByTurnCache` / `_closingAssistantCache` /
/// `_mentionTableCache`（`(source: …, value: …)` 记录 + `identical(cached.source, source)`）。
///
/// 四处各写一遍的风险不是啰嗦，是**判据会漂**：漏一个 `identical` 就是每次 build 重算整张表，
/// 而重算的结果看起来是对的 —— 只是慢，且没人会想到去查。
///
/// ## 判据是**身份**，不是相等
///
/// `AppModel` 的这些"源"都是投影/列表快照：每次刷新都是**新对象**，
/// 内容一样也该重算（内容一样说明值也一样，重算一次没有坏处；反过来用 `==`
/// 会让"内容相同的两份快照"共用一份派生结果 —— 而它们可能来自不同会话）。
///
/// ## `null` 是有效结果
///
/// 用 [_has] 标记"算过了"，而不是拿 `null` 当"未命中"：
/// 把 null 当未命中会让"没有提及 / 没有改动"这类**合法的空结果**每次重算。
///
/// Note: 取舍见 `.agents/notes/proposed/2026-10-27-ui-state-design.md` §6.B1。
library;

class SourceCache<T> {
  Object? _source;
  T? _value;
  bool _has = false;

  /// 源是 [source] 就返回缓存值，否则用 [build] 重算并缓存。
  T read(Object source, T Function() build) {
    if (_has && identical(_source, source)) return _value as T;
    final value = build();
    _source = source;
    _value = value;
    _has = true;
    return value;
  }

  /// 源是 [source] 时给出缓存值；否则 `null`（调用方据此决定要不要 `read`）。
  ///
  /// 注意与"缓存值是 null"的区别：这里 `null` 一律表示**没命中**。
  T? peek(Object source) {
    if (!_has || !identical(_source, source)) return null;
    return _value;
  }

  /// 丢掉缓存（`dispose` / 换会话时用）。
  void clear() {
    _source = null;
    _value = null;
    _has = false;
  }
}
