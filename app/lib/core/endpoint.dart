/// 中转地址的统一边界：生产 WSS，显式调试仅允许回环 WS。
library;

import 'errors.dart';

/// 校验中转/直连地址：生产 WSS，显式调试仅允许**非公网**的明文 WS。
///
/// 判据从"仅回环"扩到"回环 + 私网 + CGNAT + link-local + ULA"的取舍见
/// `.agents/notes/implemented/2026-10-14-endpoint-switching-lan-direct.md`：
/// 局域网直连的意义就是低延迟，而握手本身提供双向身份认证
/// （公钥在配对时钉死，契约 §12.1），所以明文的代价是**元数据可见**
/// （帧的大小与时序），不是"能被伪装"。
Uri checkedRelayUri(
  String value, {
  bool allowInsecureLocal = false,
  bool allowQuery = false,
}) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (!allowQuery && uri.hasQuery)) {
    throw const ProtocolException(ErrorCode.badFrame, '中转地址不合法，不能包含凭据或额外参数');
  }
  if (uri.scheme != 'wss' &&
      !(allowInsecureLocal &&
          isPrivateOrLoopback(uri.host) &&
          uri.scheme == 'ws')) {
    throw const ProtocolException(
      ErrorCode.badFrame,
      '必须使用 WSS；明文仅限显式开启的非公网地址（回环 / 私网 / CGNAT / link-local / ULA）',
    );
  }
  return uri;
}

/// 设备升级 URL：`<根>/ws/device?ticket=<票>`（契约 §2 的连接建立）。
///
/// 票**进 URL** 是刻意的：它是为进 URL 而生的一次性凭据（60 秒有效、用过即废），
/// 所以"URL 会进日志"这条风险被压到最小；而设备令牌与主种子**绝不进 URL**。
///
/// `relayUrl` 来自二维码，形如 `ws://host:port`（**不带路径**）。万一带了路径
/// （配置里写过 `/ws/connector`，那是电脑侧拨号用的那条），这里只取 scheme + authority
/// —— 与 [httpBaseOf] 同一条纪律。两处都"丢掉路径"，否则会拼出
/// `/ws/connector/ws/device`（404，而中转对 404 只 `log?.debug`，手机侧看起来像"连不上"）。
String deviceUpgradeUrl(String relayUrl, String ticket) {
  final uri = Uri.parse(relayUrl);
  return '${uri.scheme}://${uri.authority}/ws/device'
      '?ticket=${Uri.encodeQueryComponent(ticket)}';
}

/// 端点种类：决定**怎么拨**，不决定"能不能拨"。
///
/// 两者拨通之后的每一帧都走同一条路（握手、封箱、方法面）——
/// 区别只在"要不要先换一张票"。
enum EndpointKind {
  /// 经中转：每次建连换一张一次性票，拨 `/ws/device?ticket=<票>`。
  relay,

  /// 局域网直连：裸 WS，无票、无路径。
  ///
  /// 鉴权就是 §4.1 的握手本身（未配对设备在 `hello` 处被
  /// `protocol/not-paired` 拒），所以直连面**没有第二层令牌**。
  direct,
}

/// 一个可拨的连接端点。
///
/// **值是身份，不是秘密**：它可以安全地落盘、进日志、显示在设置页上。
/// 与端点相关的秘密只有设备令牌与主种子，而它们在 [PairedCredentials] 里，
/// 不在这里（`platform/pairing_store.dart`）。
class Endpoint {
  const Endpoint({
    required this.kind,
    required this.url,
    this.label = '',
    this.manual = false,
    this.hostId = '',
  });

  final EndpointKind kind;

  /// 拨号地址。`relay` 是中转根地址（`ws://host:port`，不带路径）；
  /// `direct` 是电脑侧直连监听面的完整地址。
  final String url;

  /// 给人看的名字（"同一 WiFi" / "中转" / 网卡名）。空表示让界面自己造一个。
  final String label;

  /// 用户手填的条目（不是连接器自报的）。
  ///
  /// **它永不被自动剪枝**：用户自己输进来的地址是他的意图，而"连接器这次没报"
  /// 只说明电脑此刻不在那个网络 —— 家里与公司两个地址必须能同时留着。
  ///
  /// 剪枝规则见 `data/endpoint_book.dart` 的 `mergeDiscoveredEndpoints`
  /// （`data/app_model.dart` 上那个同名方法是转发，不是第二份实现）。
  final bool manual;

  /// 这条地址是哪台电脑报的（那台电脑的 Ed25519 公钥 `pcSignPubHex`；空 = 不知道）。
  ///
  /// **不用配对载荷里的 `pcId`**：它是连接器 id，默认就是 `"local"`，两台电脑会撞。
  /// 公钥是配对时钉死的（契约 §12.1），天生唯一。
  ///
  /// **它让"同一台电脑换了地址"与"换了一台电脑"区别得开**：前者要保留
  /// （只是暂时拨不通），后者永远拨不通（对端身份不同，握手必被
  /// `protocol/not-paired` 拒）—— 留着它只会让每一轮拨号多等一个超时。
  ///
  /// 与 [manual] 同一条先例：**只在手机自己的落盘里出现**，连接器的
  /// `endpoint.describe` 不报它（它不知道也不该知道"这台手机曾经连过谁"）。
  final String hostId;

  /// 稳定标识。**就是 url** —— 同一个地址只有一个端点。
  ///
  /// 不另设 id 字段：那会出现"两个字段谁是身份"的问题，而 url 本身已经唯一。
  /// [operator ==] 与 [hashCode] **同样只按 url**（kind 与 label 是属性，
  /// 不是身份）—— 否则"`contains(endpoint)`"与"按 id 找"会给出不同答案，
  /// 而合并规则用的是后者。
  String get id => url;

  /// 换来源标记（合并时保留已存条目的 manual 标记用）。
  Endpoint withManual(bool manual) => Endpoint(
    kind: kind,
    url: url,
    label: label,
    manual: manual,
    hostId: hostId,
  );

  /// 盖上"这条地址来自哪台电脑"（合并时由 `EndpointBook` 用当前凭据的电脑公钥盖）。
  Endpoint withHost(String hostId) => Endpoint(
    kind: kind,
    url: url,
    label: label,
    manual: manual,
    hostId: hostId,
  );

  @override
  bool operator ==(Object other) => other is Endpoint && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() =>
      'Endpoint(${kind.name}, $url'
      '${label.isEmpty ? '' : ', $label'}'
      '${manual ? ', manual' : ''})';
}

/// 端点 → JSON。**两端共用一个形状**：连接器的 `endpoint.describe` 应答
/// 与手机的落盘用同一套键，少一处会漂移的地方。
///
/// `label` 可缺：它不是身份，缺了让界面自己造一个。
/// `manual` 只在**手机自己的落盘**里出现 —— 连接器不知道也不该知道这件事
/// （它是"这台手机信不信这个地址"，不是"电脑有没有这个地址"）。
Map<String, Object?> endpointToJson(Endpoint endpoint) => {
  'kind': endpoint.kind.name,
  'url': endpoint.url,
  if (endpoint.label.isNotEmpty) 'label': endpoint.label,
  if (endpoint.manual) 'manual': true,
  if (endpoint.hostId.isNotEmpty) 'hostId': endpoint.hostId,
};

/// JSON → 端点。认不出返回 `null`（**不猜**：缺 `kind` 或 `url` 的条目
/// 拨不出去，而一个拨不出去的端点会让整条链在很后面才失败）。
Endpoint? endpointFromJson(Object? raw) {
  if (raw is! Map) return null;
  final kind = raw['kind'];
  final url = raw['url'];
  if (kind is! String || url is! String || url.isEmpty) return null;
  final resolved = switch (kind) {
    'relay' => EndpointKind.relay,
    'direct' => EndpointKind.direct,
    _ => null,
  };
  if (resolved == null) return null;
  final label = raw['label'];
  final hostId = raw['hostId'];
  return Endpoint(
    kind: resolved,
    url: url,
    label: label is String ? label : '',
    manual: raw['manual'] == true,
    hostId: hostId is String ? hostId : '',
  );
}

/// 解 `endpoint.describe` 的应答：`{ endpoints: [{kind, url, label?}, …] }`。
///
/// 认不出返回空表（**不猜**）：一个拨不出去的端点会让整条链在很后面才失败。
/// 连接器侧的同名实现见 `connector/src/endpoints.ts` 的 `describeEndpoints`。
List<Endpoint> parseEndpointList(Object? raw) {
  if (raw is! Map) return const [];
  final list = raw['endpoints'];
  if (list is! List) return const [];
  final out = <Endpoint>[];
  for (final entry in list) {
    final endpoint = endpointFromJson(entry);
    if (endpoint != null) out.add(endpoint);
  }
  return out;
}

/// 合并端点表：**已知的原位更新（顺序不动），未知的追加到末尾。**
///
/// 为什么不是"用发现结果整份覆盖"：
/// - 覆盖会抹掉用户手动排的偏好序（把直连放第一位是有意为之）；
/// - 连接器某次少报一个（例如直连刚好在重启）就把手机里的条目删了，
///   而重新学到它要再等一次连接。
///
/// **为什么未知的追加到末尾，而不是按 kind 插队**：曾经 `direct` 被插到第一个
/// `relay` 之前，于是"用户把中转设为首选"会在连接器报出一个**新**直连时被
/// 悄悄挤到第二位 —— 用户的选择被自动发现冲掉了。而"同一 WiFi 优先直连"
/// 这个意图现在由 [dialOrder] 在**拨号时**按真实网段判断，不需要靠插入位置表达。
///
/// 已知条目原位更新时**保留已存的 [Endpoint.manual] 标记**：用户手填的地址
/// 被连接器也报了一次之后不能变成"自报的"，否则它会被剪枝规则误删。
List<Endpoint> mergeEndpoints(
  List<Endpoint> stored,
  List<Endpoint> discovered,
) {
  final merged = List<Endpoint>.of(stored);
  for (final fresh in discovered) {
    final index = merged.indexWhere((e) => e.id == fresh.id);
    if (index >= 0) {
      final kept = merged[index];
      merged[index] = Endpoint(
        kind: fresh.kind,
        url: fresh.url,
        label: fresh.label.isEmpty ? kept.label : fresh.label,
        manual: kept.manual,
        // 连接器**不报** hostId（它不知道这台手机连过谁）；报里空着就沿用已存的，
        // 否则一处漏盖会让"换了一台电脑"判不出来。
        hostId: fresh.hostId.isEmpty ? kept.hostId : fresh.hostId,
      );
    } else {
      merged.add(fresh);
    }
  }
  return merged;
}

/// 两个 IPv4 地址**前向匹配的八位组个数**（不是 IPv4 就是 0）。
///
/// 判"是不是同一网段"用 **>= 3（同一 /24）**，不用"同 /16"：
/// 这台机器同时有 `192.168.1.4`（WiFi）与 `192.168.2.41`（以太网），
/// 按 /16 会把它们判成同一网段，于是"在 WiFi 上却先去拨以太网那条" ——
/// 正好是这套排序要避免的事。家用 / 公司分配基本都是 /24，代价可接受：
/// 判错的只是**顺序**，那条仍然会被试到。
int subnetScore(String myIpv4, String endpointUrl) {
  final mine = _ipv4(myIpv4);
  final theirs = _ipv4OfUrl(endpointUrl);
  if (mine == null || theirs == null) return 0;
  var score = 0;
  for (var i = 0; i < 4; i += 1) {
    if (mine[i] != theirs[i]) break;
    score += 1;
  }
  return score;
}

/// 同一 /24 就算"同网段"（理由见 [subnetScore]）。
bool sameSubnet(String myIpv4, String endpointUrl) =>
    subnetScore(myIpv4, endpointUrl) >= 3;

/// 拨号顺序：**记住的那条先试 → 同网段的次之 → 其余按用户排的顺序。**
///
/// ## 为什么是这个顺序
///
/// - **记住的那条先试**：同一台电脑很少换地址（DHCP 租约 / 固定分配），
///   上次通了这次大概率还通，先试它是最省的。
/// - **同网段的次之**：只有"记住的那条拨不通"才需要这一步 —— 换了地点
///   （家 ⇄ 公司）时，用户列表里另一条地址正躺在**当前**这个网段里。
///   这一步要的是 `myIpv4`，而它是**当前**的真实地址，所以换网后自动对。
/// - **其余按用户排的顺序**：用户的手动排序在"都不是同网段"时就是唯一依据。
///
/// 它**不删任何条目**：排序只是尝试顺序，全试完仍然全失败才是真失败。
///
/// [myIpv4] 拿不到（移动网络、权限受限）时退化成"记住的 + 用户顺序" —— 不猜。
List<Endpoint> dialOrder(
  List<Endpoint> endpoints, {
  String? myIpv4,
  String? rememberedEndpointUrl,
}) {
  if (endpoints.length <= 1) return List<Endpoint>.of(endpoints);

  Endpoint? remembered;
  if (rememberedEndpointUrl != null) {
    for (final endpoint in endpoints) {
      if (endpoint.url == rememberedEndpointUrl) {
        remembered = endpoint;
        break;
      }
    }
  }

  final inSubnet = <Endpoint>[];
  final rest = <Endpoint>[];
  for (final endpoint in endpoints) {
    if (remembered != null && endpoint.url == remembered.url) continue;
    if (myIpv4 != null && sameSubnet(myIpv4, endpoint.url)) {
      inSubnet.add(endpoint);
    } else {
      rest.add(endpoint);
    }
  }
  return <Endpoint>[?remembered, ...inSubnet, ...rest];
}

/// 端点表的**附属状态**：拨号顺序要用的那几样路由记忆。
///
/// 它们与端点表分开存：每次拨通都会改"记住的那条"，而整张表不需要重写。
/// 三者都**不含秘密**（就是地址与集合），所以落盘不需要加密存储。
class EndpointMeta {
  const EndpointMeta({
    this.rememberedEndpointUrl,
    this.hiddenEndpointIds = const {},
    this.succeededEndpointIds = const {},
  });

  /// 上次拨通的地址（`dialOrder` 的第一优先）。
  final String? rememberedEndpointUrl;

  /// 用户藏掉的端点 id（连接器再报也不加回来）。
  final Set<String> hiddenEndpointIds;

  /// 曾经成功过的端点 id（剪枝的豁免依据）。
  final Set<String> succeededEndpointIds;
}

/// 点名连接的结论（成功，或失败原因）。
///
/// 与 [EndpointAttempt] 分开：那个是"每轮拨号的账"（跨连接保留，供界面显示通不通）；
/// 这个是"用户刚点的那一次"的结论 —— 一次点名只产生一个，用户关掉就没了。
class EndpointRequestResult {
  const EndpointRequestResult({
    required this.endpoint,
    required this.ok,
    this.reason,
  });

  final Endpoint endpoint;
  final bool ok;

  /// 失败原因（`ok = true` 时为 `null`）。
  final String? reason;
}

/// 解出 IPv4 四段；不是 IPv4 文本时返回 `null`。
List<int>? _ipv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return null;
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return null;
    out.add(value);
  }
  return out;
}

/// 从端点 url 里取 IPv4（IPv6 与域名一律返回 `null` —— 不猜）。
List<int>? _ipv4OfUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  var host = uri.host;
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  return _ipv4(host);
}

/// 一次**拨号**的结果（`EndpointTransport` 每试一个端点报一次）。
///
/// 它是**事实的记录，不是状态的推断**：`ok = false` 只说明"这一轮没拨通"，
/// 而端点会不会恢复是另一件事 —— 所以 `endpoint_transport.dart` 据此**不降权**
/// （失败过的端点下一轮仍在原位置）。设置页的"通不通"读它；
/// **没有拨号记录就没有结论**，不猜、也不主动探测。
class EndpointAttempt {
  const EndpointAttempt({required this.ok, this.reason});

  /// 这一轮拨通了（WS 已建立；握手还没开始）。
  final bool ok;

  /// 拨不通的原因（`ok = true` 时为 `null`）。
  final String? reason;

  @override
  bool operator ==(Object other) =>
      other is EndpointAttempt && other.ok == ok && other.reason == reason;

  @override
  int get hashCode => Object.hash(ok, reason);

  @override
  String toString() => 'EndpointAttempt(${ok ? 'ok' : 'fail'}, $reason)';
}

/// 主机是不是"非公网"（回环 / 私网 / CGNAT / link-local / ULA）。
///
/// 明文 `ws://` 只允许这一类；公网必须 `wss`（契约 §2）。
/// 判据从"仅回环"扩到这里的取舍见
/// `.agents/notes/implemented/2026-10-14-endpoint-switching-lan-direct.md`。
///
/// **不碰 `dart:io`**（`core/` 禁它，`verify-platform-boundary.mjs` 会拦），
/// 所以地址分类是手写的；只覆盖协议与部署里真会出现的族。
bool isPrivateOrLoopback(String host) {
  if (host.isEmpty) return false;
  // 主机名只有这一个算非公网（其余一概当公网 —— 宁可严一格）。
  if (host == 'localhost') return true;

  final v4 = _ipv4(host);
  if (v4 != null) return _ipv4IsPrivate(v4);

  // IPv4-mapped（`::ffff:192.168.1.1`）：按**里面的** IPv4 判。
  // 安卓会报这种地址，按前缀判会把它当成公网而拒掉一个其实在私网里的端点。
  final mapped = RegExp(r'^::ffff:(\d+\.\d+\.\d+\.\d+)$').firstMatch(host);
  if (mapped != null) {
    final inner = _ipv4(mapped.group(1)!);
    return inner != null && _ipv4IsPrivate(inner);
  }

  // IPv6 只取前两个字节：我们关心的三个前缀都只看这两位
  //（`fe80::/10` / `fc00::/7`）。**`::1` 例外**：它的前两位是 `00 01`，
  // 前缀法判不出来，所以单独认。
  if (host == '::1' || host == '0:0:0:0:0:0:0:1') return true;

  final v6 = _parseIpv6Prefix(host);
  if (v6 != null) return _ipv6PrefixIsPrivate(v6);

  return false;
}

bool _ipv4IsPrivate(List<int> b) {
  // 回环 127/8
  if (b[0] == 127) return true;
  // 私网 10/8
  if (b[0] == 10) return true;
  // 私网 172.16/12
  if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
  // 私网 192.168/16
  if (b[0] == 192 && b[1] == 168) return true;
  // CGNAT 100.64/10（Tailscale 用它）
  if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true;
  // link-local 169.254/16
  if (b[0] == 169 && b[1] == 254) return true;
  return false;
}

/// IPv6 的前两个字节。只够分类，不够寻址 —— 这里只做分类。
///
/// IPv4-mapped **不在这里处理**：它按里面的 IPv4 判（见 [isPrivateOrLoopback]），
/// 而 `::ffff:` 的前两位是 `ff ff`，按前缀判会把私网映射地址当成公网。
(int, int)? _parseIpv6Prefix(String host) {
  if (!host.contains(':')) return null;

  // 取第一段。`::` 开头时第一段是空的，实际前缀从 `::` 后面那段起。
  var head = host;
  if (head.startsWith('::')) {
    head = head.substring(2);
  }
  final firstGroup = head.split(':').first;
  if (firstGroup.isEmpty) return (0, 0);
  final value = int.tryParse(firstGroup, radix: 16);
  if (value == null || value < 0 || value > 0xffff) return null;
  return (value >> 8, value & 0xff);
}

bool _ipv6PrefixIsPrivate((int, int) p) {
  final (hi, lo) = p;
  // 整个 :: 未指定地址（`::` 的前两位是 00 00）
  if (hi == 0 && lo == 0) return true;
  // link-local fe80::/10
  if (hi == 0xfe && (lo & 0xc0) == 0x80) return true;
  // unique-local fc00::/7
  if ((hi & 0xfe) == 0xfc) return true;
  return false;
}
