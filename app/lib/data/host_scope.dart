/// 一台电脑的**存储作用域**（不可变值）。
///
/// ## 为什么是值对象，而不是一个可变的 `setHostScope`
///
/// 条目表的键是 `sid`（会话别名），而 `sid` 由**每台电脑各自分配**，两台电脑撞名完全
/// 可能（`main.dart` 里那句"别名空间互不相干"说的就是这件事）。所以"这条记录属于哪台
/// 电脑"必须随每一次读写一起给，而不是"装配时设一次、之后靠记得先调"。
///
/// 后者（`setHostScope` 那一类可变字段）的问题是**隐式时序契约**：任何一次读写之前忘了
/// 调，症状不是崩溃而是"读到别处的内容"—— 那是本项目最贵的一类 bug。作用域改成构造时
/// 注入之后，"没设"这种状态在类型上就不存在。
///
/// ## 它不认识的
///
/// 它不知道盘上的表长什么样（那是 `ItemStore` 实现的事），也不认识 sqflite。
/// 它只回答两件事：**"这个键归我吗"**与**"给它加上/去掉前缀"**。
library;

import 'store.dart' show kScopeSep;

/// 一台电脑的存储作用域。`hostId` 是那台电脑的 Ed25519 公钥（`pcSignPubHex`）。
final class HostScope {
  const HostScope(this.hostId) : assert(hostId != '', '作用域必须有电脑身份');

  /// 那台电脑的身份（配对时钉死的公钥，不是地址也不是 `pcId`）。
  final String hostId;

  /// 给一个**本机键**（会话别名 / 条目 id / `requestId`）加上这台电脑的前缀。
  String keyOf(String plain) => '$hostId$kScopeSep$plain';

  /// 这个键是不是这台电脑的。
  bool owns(String key) => key.startsWith('$hostId$kScopeSep');

  /// 去掉前缀；不是这台电脑的键原样返回（调用方应先判 [owns]）。
  String plainOf(String key) =>
      owns(key) ? key.substring(hostId.length + kScopeSep.length) : key;
}
