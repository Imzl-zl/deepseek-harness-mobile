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
  const Endpoint({required this.kind, required this.url, this.label = ''});

  final EndpointKind kind;

  /// 拨号地址。`relay` 是中转根地址（`ws://host:port`，不带路径）；
  /// `direct` 是电脑侧直连监听面的完整地址。
  final String url;

  /// 给人看的名字（"同一 WiFi" / "中转" / 网卡名）。空表示让界面自己造一个。
  final String label;

  /// 稳定标识。**就是 url** —— 同一个地址只有一个端点。
  ///
  /// 不另设 id 字段：那会出现"两个字段谁是身份"的问题，而 url 本身已经唯一。
  /// [operator ==] 与 [hashCode] **同样只按 url**（kind 与 label 是属性，
  /// 不是身份）—— 否则"`contains(endpoint)`"与"按 id 找"会给出不同答案，
  /// 而合并规则用的是后者。
  String get id => url;

  @override
  bool operator ==(Object other) => other is Endpoint && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() =>
      'Endpoint(${kind.name}, $url'
      '${label.isEmpty ? '' : ', $label'})';
}

/// 端点 → JSON。**两端共用一个形状**：连接器的 `endpoint.describe` 应答
/// 与手机的落盘用同一套键，少一处会漂移的地方。
///
/// `label` 可缺：它不是身份，缺了让界面自己造一个。
Map<String, Object?> endpointToJson(Endpoint endpoint) => {
  'kind': endpoint.kind.name,
  'url': endpoint.url,
  if (endpoint.label.isNotEmpty) 'label': endpoint.label,
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
  return Endpoint(
    kind: resolved,
    url: url,
    label: label is String ? label : '',
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

/// 合并端点表：**已知的原位更新（顺序不动），未知的按 kind 插入。**
///
/// 为什么不是"用发现结果整份覆盖"：
/// - 覆盖会抹掉用户手动排的偏好序（把直连放第一位是有意为之）；
/// - 连接器某次少报一个（例如直连刚好在重启）就把手机里的条目删了，
///   而重新学到它要再等一次连接。
///
/// 插入规则：`direct` 排在同 kind 已存条目之前、`relay` 之后 ——
/// 即"同 kind 保持原序，direct 整体先于 relay"。这样第一次发现直连时
/// 它自动成为首选，与"同一局域网延迟低"的意图一致；而用户一旦手动重排，
/// 后续合并只更新字段、不再挪位。
List<Endpoint> mergeEndpoints(
  List<Endpoint> stored,
  List<Endpoint> discovered,
) {
  final merged = List<Endpoint>.of(stored);
  for (final fresh in discovered) {
    final index = merged.indexWhere((e) => e.id == fresh.id);
    if (index >= 0) {
      merged[index] = fresh;
    } else {
      // 找第一个 kind 不同的位置插在它前面：direct 插在第一个 relay 前，
      // relay 追加到末尾。同 kind 的新条目按发现顺序追加。
      final insertAt = merged.indexWhere((e) => e.kind != fresh.kind);
      if (insertAt >= 0) {
        merged.insert(insertAt, fresh);
      } else {
        merged.add(fresh);
      }
    }
  }
  return merged;
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

  final v4 = _parseIpv4(host);
  if (v4 != null) return _ipv4IsPrivate(v4);

  // IPv4-mapped（`::ffff:192.168.1.1`）：按**里面的** IPv4 判。
  // 安卓会报这种地址，按前缀判会把它当成公网而拒掉一个其实在私网里的端点。
  final mapped = RegExp(r'^::ffff:(\d+\.\d+\.\d+\.\d+)$').firstMatch(host);
  if (mapped != null) {
    final inner = _parseIpv4(mapped.group(1)!);
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

/// IPv4 四段；不是 IPv4 文本时返回 `null`。
List<int>? _parseIpv4(String host) {
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
