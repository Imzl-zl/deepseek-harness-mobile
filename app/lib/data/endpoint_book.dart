/// 端点簿：手机侧的**连接地址表**及其附属路由记忆。
///
/// ## 为什么它不在 `AppModel` 里
///
/// 这一簇有 350 行，且是唯一"写盘由别人做"的状态：表变了要落盘、附属记忆变了也要落盘
/// （两条分开，否则每拨一次就重写整张表）。收窄计划把它整簇搬出来
/// （`.agents/notes/proposed/2026-10-27-appmodel-narrowing.md` 第三簇）。
///
/// 搬出来的收益不是行数，而是**判据集中**：剪枝的三条、上限的淘汰顺序、
/// "删了白删"的隐藏集，全部只在这一个文件里，`AppModel` 只剩转发。
///
/// ## 边界
///
/// - 落盘仍然由装配层注入（`onTableChanged` / `onMetaChanged`）：`data/` 不认识平台；
/// - 通知走 [onChange]（装配方传守卫过的 `notifyListeners`）；
/// - 地址**校验**不在这里（`core/endpoint.dart` + 设置页负责），这里只存值 ——
///   两处各判一遍就会漂。
///
/// 行为钉子见 `app/test/endpoint_book_test.dart`（在搬移之前写，搬完必须仍全绿）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;

import '../core/endpoint.dart';

class EndpointBook {
  EndpointBook({
    required List<Endpoint> endpoints,
    String? rememberedEndpointUrl,
    required Set<String> hiddenEndpointIds,
    required Set<String> succeededEndpointIds,
    Future<String?> Function()? myLanIpv4Of,
    Future<void> Function(List<Endpoint>)? onTableChanged,
    Future<void> Function(EndpointMeta)? onMetaChanged,
    required void Function() onChange,
  }) : _endpoints = List<Endpoint>.of(endpoints),
       _rememberedEndpointUrl = rememberedEndpointUrl,
       _hiddenEndpointIds = Set<String>.of(hiddenEndpointIds),
       _succeededEndpointIds = Set<String>.of(succeededEndpointIds),
       _myLanIpv4Of = myLanIpv4Of,
       _onTableChanged = onTableChanged,
       _onMetaChanged = onMetaChanged,
       _onChange = onChange;

  /// 上限保险丝的值。用户自己的删除总是优先于它 —— 它只防"表无限变长"。
  static const int maxEndpoints = 12;

  final Future<void> Function(List<Endpoint>)? _onTableChanged;
  final Future<void> Function(EndpointMeta)? _onMetaChanged;
  final void Function() _onChange;

  /// 读本机 LAN 地址的实现（装配层注入 `platform/lan_address.dart`；
  /// `data/` 不认识 `dart:io`）。
  final Future<String?> Function()? _myLanIpv4Of;

  /// 有序端点表。**序即偏好**：`connect()` 按这个顺序拨，第一个通的赢。
  ///
  /// 它的所有者是这里（界面要读、设置页要改），而拨号方
  /// （`platform/transport_factory.dart` 经 `EndpointTransport`）每次
  /// `connect()` 现读它 —— 所以"发现了一条直连"立刻生效，不用重启 App。
  List<Endpoint> get endpoints => _endpoints;
  List<Endpoint> _endpoints;

  /// 当前拨通的那个端点（`null` = 还没连上）。
  Endpoint? get activeEndpoint => _activeEndpoint;
  Endpoint? _activeEndpoint;

  /// 上次拨通的端点地址（`dialOrder` 的第一优先）。
  String? get rememberedEndpointUrl => _rememberedEndpointUrl;
  String? _rememberedEndpointUrl;

  /// 用户藏掉的端点 id（连接器再报也不加回来）。
  Set<String> get hiddenEndpointIds =>
      Set<String>.unmodifiable(_hiddenEndpointIds);
  final Set<String> _hiddenEndpointIds;

  /// **曾经成功过**的端点 id（不是"上次成功"，是"曾经成功"）。
  final Set<String> _succeededEndpointIds;

  /// 本机在**当前局域网**里的 IPv4（`null` = 还不知道 / 拿不到）。
  String? get myLanIpv4 => _myLanIpv4;
  String? _myLanIpv4;

  /// 每个端点**最近一次拨号**的结果（端点 id = url → 结果）。
  ///
  /// 由传输层报事实（`EndpointTransport.onAttempt`，装配在 `main.dart`），
  /// 这里只记账。设置页的"通不通"读它：**没有记录就没有结论**。
  final Map<String, EndpointAttempt> _attempts = {};

  EndpointAttempt? attemptOf(Endpoint endpoint) => _attempts[endpoint.id];

  /// 端点表的附属状态（落盘用）。
  EndpointMeta get endpointMeta => EndpointMeta(
    rememberedEndpointUrl: _rememberedEndpointUrl,
    hiddenEndpointIds: _hiddenEndpointIds,
    succeededEndpointIds: _succeededEndpointIds,
  );

  /// 报一次"这条连接走的是哪个端点"。
  ///
  /// **顺带记住它**：拨号顺序的第一优先就是"上次拨通的那条"
  /// （见 `core/endpoint.dart` 的 `dialOrder`）。同一台电脑很少换地址，
  /// 先试它最省 —— 而"换地点之后同网段优先"是它失败之后的第二手。
  void reportActiveEndpoint(Endpoint endpoint) {
    final movedOn = _activeEndpoint?.id != endpoint.id;
    _activeEndpoint = endpoint;
    final newlySucceeded = _succeededEndpointIds.add(endpoint.id);
    final memoryMoved = _rememberedEndpointUrl != endpoint.url;
    _rememberedEndpointUrl = endpoint.url;
    if (!movedOn && !newlySucceeded && !memoryMoved) return;
    _onChange();
    if (newlySucceeded || memoryMoved) {
      // 落盘是旁路：调用方是同步语义，不能 await。
      unawaited(_onMetaChanged?.call(endpointMeta) ?? Future<void>.value());
    }
  }

  /// 把连接器自报的端点并进表里（`endpoint.describe` 的结果）。
  ///
  /// **合并而不是覆盖**：覆盖会抹掉用户手动排的偏好序，而连接器某次少报一个
  /// （例如直连刚好在重启）就把手机里的条目删了。规则见 `core/endpoint.dart`
  /// 的 `mergeEndpoints` —— 已知的原位更新，未知的按 kind 插。
  ///
  /// **合并后剪枝**：连接器不再自报、且本机拨过并失败的条目删掉。两个条件
  /// 同时成立才删 —— ① 这次 describe 没报它；② 本机拨过且记录是失败。
  /// （2026-10-17 真机：三个拨不通的 IPv6 地址让冷启动每个等满超时，合计 30 秒。）
  Future<void> mergeDiscoveredEndpoints(
    List<Endpoint> discovered, {
    String? hostId,
  }) async {
    // **盖上"来自哪台电脑"**：连接器不报这个（它不知道这台手机连过谁），
    // 而剪枝要靠它区分"同一台电脑换了地址"与"换了一台电脑"。
    final currentHost = hostId ?? '';
    final stamped = <Endpoint>[
      for (final endpoint in discovered)
        endpoint.hostId.isEmpty && currentHost.isNotEmpty
            ? endpoint.withHost(currentHost)
            : endpoint,
    ];
    // 用户藏掉的条目**不再加回来**（否则设置页的"删除"删了白删）。
    final visible = stamped
        .where((e) => !_hiddenEndpointIds.contains(e.id))
        .toList();
    final merged = mergeEndpoints(_endpoints, visible);
    final reported = visible.map((e) => e.id).toSet();

    final kept = merged.where((e) {
      if (e.manual) return true; // 用户手填的：永不自动删
      // **别的电脑报的地址永不留**：换过电脑之后它们只会让每一轮拨号多等一个
      // 超时（对端身份不同，握手必被 `protocol/not-paired` 拒），而"曾经成功过"
      // 恰恰是它们最容易被留下的理由。手填的除外（那是用户明确要的）。
      if (currentHost.isNotEmpty &&
          e.hostId.isNotEmpty &&
          e.hostId != currentHost) {
        return false;
      }
      if (reported.contains(e.id)) return true; // 连接器还在报：留
      // **成功过的永不删**：它只是"此刻不在那个网络"。
      if (_succeededEndpointIds.contains(e.id)) return true;
      // 剩下的只删"从没成功过 + 这次拨过并失败"（IPv6 轮换出来的旧地址）。
      return _attempts[e.id]?.ok != false;
    }).toList();

    final bounded = _boundedByCap(kept);
    // 成功集只留表里还在的 id：换电脑裁掉的条目不该在"曾经成功"里留名
    // （否则同名地址再次出现时会被当成"成功过"而逃过剪枝）。
    _succeededEndpointIds.retainAll(bounded.map((e) => e.id));
    var metaChanged = false;
    if (_rememberedEndpointUrl != null &&
        !bounded.any((e) => e.url == _rememberedEndpointUrl)) {
      _rememberedEndpointUrl = null;
      metaChanged = true;
    }
    if (_sameEndpointTable(bounded, _endpoints)) {
      if (metaChanged) await _onMetaChanged?.call(endpointMeta);
      return; // 没有变化：不落盘、不通知（否则每次重连都会写一次存储）
    }
    _endpoints = bounded;
    _onChange();
    await _onTableChanged?.call(bounded);
    if (metaChanged) await _onMetaChanged?.call(endpointMeta);
  }

  /// 上限保险丝：条目超 [maxEndpoints] 时，从**末尾**淘汰"从没成功过、
  /// 且不是手填"的条目。
  ///
  /// 为什么是末尾：新发现的端点追加在末尾，而用户手动排在前面的顺序
  /// 是他的意图 —— 淘汰从后往前才不动它。**手填的豁免**：那是用户明确要的。
  List<Endpoint> _boundedByCap(List<Endpoint> entries) {
    if (entries.length <= maxEndpoints) return entries;
    final out = List<Endpoint>.of(entries);
    var index = out.length - 1;
    while (out.length > maxEndpoints && index >= 0) {
      final endpoint = out[index];
      final evictable =
          !endpoint.manual && !_succeededEndpointIds.contains(endpoint.id);
      if (evictable) {
        out.removeAt(index);
      }
      index -= 1;
    }
    // 全是"成功过"或"手填"的（不常见的极端）：宁可超限也不删用户要的。
    return out;
  }

  /// 两张端点表是否**完全一样**（url + label + manual + kind + hostId；顺序也算）。
  ///
  /// 不能用 `contains`：它只比 url，于是"label 变了""manual 标记变了"
  /// 都会被当成"没有变化"而不落盘。
  bool _sameEndpointTable(List<Endpoint> a, List<Endpoint> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i].url != b[i].url ||
          a[i].label != b[i].label ||
          a[i].manual != b[i].manual ||
          a[i].kind != b[i].kind ||
          a[i].hostId != b[i].hostId) {
        return false;
      }
    }
    return true;
  }

  /// 刷新本机 LAN 地址。
  ///
  /// **在"拨不通"之后才调**（见 [reportEndpointAttempt]）：用户的原话是
  /// "连接失败才会查下自己 IP"。平时不必付这个代价，而真正需要它的那一刻
  /// ——换了地点、记住的那条拨不通—— 正好就是失败的那一拍。
  Future<void> refreshMyLanIpv4() async {
    final read = _myLanIpv4Of;
    if (read == null) return;
    String? next;
    try {
      next = await read();
    } on Object {
      return; // 读不到就是不知道（不猜），排序退化成"用户顺序"
    }
    if (next == _myLanIpv4) return;
    _myLanIpv4 = next;
    _onChange();
  }

  /// 用户手填一条端点。
  ///
  /// **地址校验由调用方做**（设置页走 `checkedRelayUri` + `isPrivateOrLoopback`）：
  /// `data/` 只存值，不判安全边界 —— 那是 `core/endpoint.dart` 的职责。
  Future<void> addManualEndpoint(Endpoint endpoint) async {
    final manual = endpoint.withManual(true);
    // 之前藏过的话，这次是用户明确要它 —— 顺手解除隐藏。
    _hiddenEndpointIds.remove(manual.id);
    final next = List<Endpoint>.of(_endpoints);
    final index = next.indexWhere((e) => e.id == manual.id);
    if (index >= 0) {
      next[index] = manual; // 已经是它：只把标记刷成手填
    } else {
      next.add(manual);
    }
    _endpoints = next;
    _onChange();
    await _onTableChanged?.call(next);
    await _onMetaChanged?.call(endpointMeta);
  }

  /// 删一条端点。
  ///
  /// 连接器自报的**进隐藏集**（否则下次 `describe` 又把它加回来，删了白删）；
  /// 手填的直接从表里去掉（没有"会被报回来"的问题）。
  Future<void> removeEndpoint(Endpoint endpoint) async {
    final next = _endpoints.where((e) => e.id != endpoint.id).toList();
    if (!endpoint.manual) _hiddenEndpointIds.add(endpoint.id);
    _succeededEndpointIds.remove(endpoint.id);
    _endpoints = next;
    if (_rememberedEndpointUrl == endpoint.id) _rememberedEndpointUrl = null;
    _onChange();
    await _onTableChanged?.call(next);
    await _onMetaChanged?.call(endpointMeta);
  }

  /// 把藏掉的端点放回来（设置页的"已隐藏"区用）。
  Future<void> unhideEndpoint(String id) async {
    if (!_hiddenEndpointIds.remove(id)) return;
    _onChange();
    await _onMetaChanged?.call(endpointMeta);
  }

  /// 拖动换位置（队列的顺序就是自动拨号的优先级）。
  ///
  /// 参数是**表下标**，且 [newIndex] 已经是"移动后的目标下标"（调用方负责把
  /// `ReorderableListView` 的"插入位置"换算成它）。越界即忽略。
  Future<void> moveEndpoint(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= _endpoints.length) return;
    if (newIndex < 0 || newIndex >= _endpoints.length) return;
    final reordered = List<Endpoint>.of(_endpoints);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    _endpoints = reordered;
    _onChange();
    await _onTableChanged?.call(reordered);
  }

  /// 手动挑一个端点当首选（设置页用）。**只改顺序，不删条目**。
  Future<void> preferEndpoint(Endpoint endpoint) async {
    final index = _endpoints.indexWhere((e) => e.id == endpoint.id);
    if (index < 0) return;
    final reordered = <Endpoint>[
      _endpoints[index],
      ..._endpoints.where((e) => e.id != endpoint.id),
    ];
    if (listEquals(reordered, _endpoints)) return;
    _endpoints = reordered;
    _onChange();
    await _onTableChanged?.call(reordered);
  }

  /// 记一次拨号结果。**同一个结果不重复通知**：退避重连时每一轮都会把
  /// 所有端点重报一遍，不判重会让界面每隔几秒重建一次。
  void reportEndpointAttempt(Endpoint endpoint, EndpointAttempt attempt) {
    if (_attempts[endpoint.id] == attempt) return;
    _attempts[endpoint.id] = attempt;
    _onChange();
    // **拨不通才去查本机 IP**：这一拍正是"换了地点、记住的那条不通"的时刻，
    // 而下一轮重连的 `dialOrder` 需要新网段才能把同网段那条排上来。
    if (!attempt.ok) unawaited(refreshMyLanIpv4());
  }

  /// 清掉某个端点的拨号记录（点名连接前用：别把上一次的失败当这一次的）。
  void clearAttempt(String endpointId) {
    if (_attempts.remove(endpointId) != null) _onChange();
  }
}
