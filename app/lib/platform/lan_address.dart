/// 本机在**当前局域网**里的 IPv4。
///
/// ## 它只服务一件事
///
/// 拨号时判"这条直连端点是不是和我同一网段"（`core/endpoint.dart` 的
/// `dialOrder`）—— 换了 WiFi（家 ⇄ 公司）之后，用户列表里另一条地址正躺在
/// **当前**这个网段里，先试它比按顺序瞎试省得多。
///
/// ## 为什么住在 `platform/`
///
/// 要 `dart:io` 的 `NetworkInterface`，而 `core/` 是纯 Dart
/// （`node app/tools/verify-platform-boundary.mjs` 的 `core-no-platform-import`
/// 会拦）。`data/` 也不认识平台，所以它是**注入**进去的一个函数。
///
/// ## 它不是身份、不进日志、不落盘
///
/// 换 WiFi 它自己就变了，缓存起来只为了给排序用一次（见
/// `AppModel.myLanIpv4` 的说明）。**拿不到就返回 `null`**，排序退化成
/// "记住的那条 + 用户顺序" —— 不猜。
library;

import 'dart:io';

/// 取本机 IPv4；拿不到返回 `null`。
///
/// **判据不用网卡名**：Android 上网卡名不可靠（`wlan0` / `ap0` / 厂商自定义名），
/// 而我们只要"一个能代表我在这个网段"的地址。取第一个非回环、非 link-local 的
/// IPv4 —— 手机通常只有一条；有多条（如 VPN）时取枚举到的第一条，
/// 猜错的代价只是排序不理想，那条仍然会被试到。
Future<String?> currentLanIpv4() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final value = address.address;
        // link-local IPv4（169.254/16）：只在 DHCP 失败时出现，不代表任何网段。
        if (value.startsWith('169.254.')) continue;
        // 回环已经由 includeLoopback: false 排除，这里再挡一次不亏。
        if (value.startsWith('127.')) continue;
        return value;
      }
    }
    return null;
  } on Object {
    // 权限受限 / 平台不支持：**如实说不知道**，不编一个地址出来。
    return null;
  }
}
