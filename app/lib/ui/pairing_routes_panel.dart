/// 配对页里"这张码有什么 / 此刻哪条通 / 为什么没通"的三块呈现。
///
/// 从 `pairing_page.dart` 抽出来（尺寸预算只降不升）：这三块都是**纯呈现**
/// （无状态、只读入参），与页面自己的流程状态无关；留在页面里会让那一页
/// 越过行数上限，也会让"码里的承诺"和"实测的事实"混在同一段代码里。
///
/// 两块关于路径的卡片分工是硬的：
/// - [PairingOfferRoutes]：**码里写了什么**（出码时的承诺，来自二维码载荷）；
/// - [PairingRoutePicker]：**此刻哪条拨通了**（一次真实受限握手的结果）。
///
/// 把两者合并成一句"这张码能走中转"正是 2026-11-17 之前那类混乱的来源：
/// 承诺与事实永远可能不一致，界面必须分开说。
library;

import 'package:flutter/material.dart';

import '../core/pairing.dart';
import '../core/pairing_flow.dart';
import '../model/route_policy.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

/// **这张码有哪几条路**（扫完就摆出来，不等失败才说）。
///
/// 两件事都在这里说：
/// - 降级码（电脑侧出码时没登记上中转）：**只有局域网**，出不了同一个 WiFi 就配不上；
/// - 两条都在：走哪两条；连接过程中「正在试」跟着 `stage` 走。
class PairingOfferRoutes extends StatelessWidget {
  const PairingOfferRoutes({
    super.key,
    required this.offer,
    required this.busy,
    required this.stage,
  });

  final PairingOffer offer;
  final bool busy;
  final String stage;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final hasLan = offer.lanUrls.isNotEmpty;
    final hasRelay = !offer.lanOnly;
    final routes = <String>[
      if (hasLan) '局域网直连（${offer.lanUrls.length} 个地址）',
      // `lanOnly: false` 的唯一含义就是中转登记成功（契约 §12.1）——
      // 这里明写"已登记"，用户不用从"没有警告"去猜出门能不能用。
      if (hasRelay) '中转（已登记）',
    ];
    final lanOnly = offer.lanOnly;
    return Container(
      key: const Key('pairing-routes'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.sm),
        border: Border.all(color: lanOnly ? c.error : c.borderL2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DshIcon(
                lanOnly ? 'warningTriangle' : 'link',
                size: 16,
                color: lanOnly ? c.error : c.labelSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  lanOnly
                      ? '此码只能在同一 Wi-Fi 下使用（出码时没登记上中转）。'
                      : routes.length > 1
                      ? '这张码有两条路：${routes.join(' · ')}。'
                      : '这张码走：${routes.isEmpty ? '中转' : routes.single}。',
                  key: lanOnly ? const Key('pairing-lan-only') : null,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: lanOnly ? c.labelPrimary : c.labelSecondary,
                  ),
                ),
              ),
            ],
          ),
          if (busy && stage.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '正在试：$stage',
              key: const Key('pairing-stage'),
              style: TextStyle(fontSize: 12, color: c.labelSecondary),
            ),
          ],
          if (!lanOnly && hasLan && hasRelay) ...[
            const SizedBox(height: 6),
            Text(
              '两条都通时，在下面选这次走哪条；选完再确认。',
              style: TextStyle(fontSize: 12, color: c.labelTertiary),
            ),
          ],
        ],
      ),
    );
  }
}

/// 两条路的**实测**结果 + 选择。
///
/// 与 [PairingOfferRoutes]（码里写了什么）分开：那是出码时的承诺，这是拨通与否的事实。
/// 行有三种状态，**说法各不相同**：
/// - `✓` 通了：给出可拨地址，可点（选它）；
/// - `✗` 拨不通：给出原因（换票 409 / 连不上 / 超时），不可点；
/// - `—` 这张码不含这条：说清是"出码时没开/没登记"，**不是拨不通**。
///
/// 第三种正是从前最容易被混成第二种的地方：一张只登记了局域网的码，
/// 显示"中转连不上"会让人去修中转，而那张码本来就没有中转。
class PairingRoutePicker extends StatelessWidget {
  const PairingRoutePicker({
    super.key,
    required this.offer,
    required this.probe,
    required this.selected,
    required this.busy,
    required this.policy,
    required this.onSelect,
  });

  final PairingOffer offer;
  final PairingProbe? probe;
  final PairingDial? selected;
  final bool busy;

  /// 这台手机的连接方式策略。**它决定哪条被探过** —— 被排除的那条要画成
  /// "按设置未尝试"，不能画成"不通"（那会是另一件事）。
  final RoutePolicy policy;

  final ValueChanged<PairingDial> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      key: const Key('pairing-route-picker'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.sm),
        border: Border.all(color: c.borderL2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '这次走哪条',
            style: TextStyle(fontSize: 12, color: c.labelSecondary),
          ),
          const SizedBox(height: 8),
          _row(context, PairingDial.lan, inCode: offer.lanUrls.isNotEmpty),
          const SizedBox(height: 8),
          _row(context, PairingDial.relay, inCode: !offer.lanOnly),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, PairingDial dial, {required bool inCode}) {
    final c = context.dshColors;
    PairingRouteProbe? result;
    for (final route in probe?.routes ?? const <PairingRouteProbe>[]) {
      if (route.dial == dial) {
        result = route;
        break;
      }
    }
    final ok = result?.ok == true;
    // 策略排除的那条根本没拨过：不能画成"不通"（见 `probePairing` 的 `prefer`）。
    final excluded =
        (dial == PairingDial.lan && policy == RoutePolicy.relayOnly) ||
        (dial == PairingDial.relay && policy == RoutePolicy.directOnly);
    final selectable = ok && !excluded;
    final isSelected = selected == dial;
    // 局域网那一行给**地址总数**：电脑报几条局域网地址，这里就说几条 ——
    // 失败时那句「试了 N 个地址」才对得上（`core/pairing_flow.dart` 的
    // `_lanDownText`）。**仍是一行**：逐条地址一行会把这块面板变成日志。
    final title = switch (dial) {
      PairingDial.lan =>
        offer.lanUrls.isEmpty ? '局域网直连' : '局域网直连（${offer.lanUrls.length} 个地址）',
      PairingDial.relay => '中转',
    };
    final String subtitle;
    if (!inCode) {
      subtitle = dial == PairingDial.lan
          ? '此码不含局域网直连（出码时直连没开）'
          : '此码不含中转（出码时中转没连上）';
    } else if (excluded) {
      subtitle = dial == PairingDial.lan ? '按「只用中转」没有尝试' : '按「只用直连」没有尝试';
    } else if (result == null) {
      subtitle = busy ? '检测中…' : '未检测';
    } else if (ok) {
      subtitle = result.dialUrl.isEmpty ? '已连通' : result.dialUrl;
    } else {
      subtitle = result.failure ?? '拨不通';
    }
    final icon = selectable
        ? 'check'
        : (inCode && !excluded ? 'warningTriangle' : 'link');
    final iconColor = selectable
        ? c.accentBlue
        : (inCode && !excluded ? c.error : c.labelTertiary);
    return Semantics(
      button: selectable,
      selected: isSelected,
      child: GestureDetector(
        key: Key('pairing-route-${dial.name}'),
        onTap: selectable ? () => onSelect(dial) : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(DshRadius.sm),
            border: Border.all(
              color: isSelected ? c.accentBlue : c.borderL2,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DshIcon(icon, size: 16, color: iconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: inCode ? c.labelPrimary : c.labelTertiary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: selectable
                            ? c.labelSecondary
                            : (inCode && !excluded ? c.error : c.labelTertiary),
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Text('已选', style: TextStyle(fontSize: 12, color: c.accentBlue)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 错误框（页首）。
class PairingErrorBox extends StatelessWidget {
  const PairingErrorBox({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.sm),
        border: Border.all(color: c.error),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DshIcon('warningTriangle', size: 16, color: c.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, color: c.error),
            ),
          ),
        ],
      ),
    );
  }
}
