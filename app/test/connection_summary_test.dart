/// `connectionSummary` 的回归（连接 sheet 与设置页共用的那一套说法）。
///
/// ## 这一组守什么
///
/// 「换 WiFi / 电脑换 IP 后直连失效、自动回落中转」**必须留痕**：
/// 传输层刻意安静重连（不降权、不弹错），所以如果这里也不说，
/// 用户看着"已连接"永远不知道自己在走保底通道 —— 那是这套 UI 存在的理由。
/// 反过来，**没有证据时不编原因**（没拨过 / 上次是通的 → 不提）。
library;

import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:flutter_test/flutter_test.dart';

const _direct = Endpoint(
  kind: EndpointKind.direct,
  url: 'ws://192.168.2.43:8790',
  label: 'Wi-Fi',
);
const _relay = Endpoint(
  kind: EndpointKind.relay,
  url: 'ws://192.168.2.43:8787',
  label: '中转',
);

void main() {
  /// 默认"都没拨过"—— 没有证据就不该有结论。
  ConnectionSummary summary({
    ConnectionStateView state = ConnectionStateView.serving,
    Endpoint? active,
    List<Endpoint> endpoints = const [_direct, _relay],
    Map<String, EndpointAttempt> attempts = const {},
  }) => connectionSummary(
    state: state,
    active: active,
    endpoints: endpoints,
    attemptOf: (e) => attempts[e.id],
  );

  test('kind 与端点行的说法各只有一套', () {
    expect(endpointKindLabel(EndpointKind.direct), '直连');
    expect(endpointKindLabel(EndpointKind.relay), '中转');
    expect(endpointLine(_direct), '直连 · ws://192.168.2.43:8790');
  });

  test('没连上：只给状态，不摆"当前端点"', () {
    // 拨通记录是跨连接保留的，重连中把上一条的赢家说成"当前"会与
    // 顶栏/连接 sheet 的"重连中…"打架。
    final result = summary(state: ConnectionStateView.backoff, active: _direct);
    expect(result.line, '重连中…');
    expect(result.note, isNull);
  });

  test('**每一条端点都拨不通**：诊断跟上（电脑不在线/换了地址的唯一提示）', () {
    // 这是"换 WiFi / 电脑换 IP"在空态与连接 sheet 里的说法。
    final result = summary(
      state: ConnectionStateView.gaveUp,
      active: null,
      attempts: {
        _direct.id: const EndpointAttempt(ok: false, reason: '连接超时'),
        _relay.id: const EndpointAttempt(ok: false, reason: '连接超时'),
      },
    );
    expect(result.line, '连接不上');
    expect(result.note, '2 个端点都拨不通（电脑可能不在线，或换了网络地址）');
  });

  test('有端点从没拨过：不说"都拨不通"（可能是刚启动还没跑完一轮）', () {
    final result = summary(
      state: ConnectionStateView.backoff,
      active: null,
      attempts: {_direct.id: const EndpointAttempt(ok: false, reason: '连接超时')},
    );
    expect(result.note, isNull, reason: '没拨过的那条让"都拨不通"不成立');
  });

  test('没连上且端点表为空：没有诊断可说', () {
    final result = summary(
      state: ConnectionStateView.gaveUp,
      active: null,
      endpoints: const [],
    );
    expect(result.note, isNull);
  });

  test('当前就走首选：不提"为什么"', () {
    final result = summary(active: _direct);
    expect(result.line, '当前连接：直连 · ws://192.168.2.43:8790');
    expect(result.note, isNull);
  });

  test('**回落中转**：带上直连为什么没走（换 WiFi 后的唯一提示）', () {
    final result = summary(
      active: _relay,
      attempts: {
        _direct.id: const EndpointAttempt(ok: false, reason: '连接超时'),
        _relay.id: const EndpointAttempt(ok: true),
      },
    );
    expect(result.line, '当前连接：中转 · ws://192.168.2.43:8787');
    expect(result.note, '直连 ws://192.168.2.43:8790 拨不通（连接超时）');
  });

  test('回落且失败没带原因：地址照说，不编理由', () {
    final result = summary(
      active: _relay,
      attempts: {_direct.id: const EndpointAttempt(ok: false)},
    );
    expect(result.note, '直连 ws://192.168.2.43:8790 拨不通');
  });

  test('回落但首选从没拨过：不说"拨不通"（没证据）', () {
    final result = summary(active: _relay);
    expect(result.note, isNull);
  });

  test('端点表为空：不崩，只给状态', () {
    final result = summary(endpoints: const [], active: null);
    expect(result.line, '已连接');
    expect(result.note, isNull);
  });
}
