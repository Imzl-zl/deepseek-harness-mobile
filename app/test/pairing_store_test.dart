/// 配对凭据的**分槽**与**迁移**判据（多机第 2 步）。
///
/// 判据来自 `proposed/2026-10-29-one-phone-many-computers.md` 的准入门槛 1、2：
///
/// 1. 两个槽互不影响：配对 A → 配对 B → A 的 `deviceToken` / `masterSeed` 逐字未变，
///    且 `active == B`。
/// 2. 迁移幂等：旧平铺键迁一次后 `load()` 与原值逐字相等，**再跑一次不写第二遍**
///    —— 判据是写次数，不是"看起来一样"。
///
/// 这里用内存 [SecureStore] 驱动；真实现是系统密钥库（真机用例才验它）。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/platform/pairing_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemorySecure implements SecureStore {
  final Map<String, String> values = <String, String>{};
  int writes = 0;
  int deletes = 0;

  @override
  Future<Map<String, String>> readAll() async => Map<String, String>.of(values);

  @override
  Future<void> write(String key, String value) async {
    writes += 1;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletes += 1;
    values.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    values.clear();
  }
}

/// 一份确定性的凭据；[tag] 让同一个 host 可以造出"另一份"（验证替换）。
PairedCredentials _credentials(String host, {String tag = ''}) {
  const url = 'ws://relay.example:8787';
  final endpoint = Endpoint(
    kind: EndpointKind.relay,
    url: url,
    label: '中转',
    hostId: host,
  );
  return PairedCredentials(
    relayUrl: url,
    pcSignPubHex: host,
    pcDhPubHex: 'dh-$host$tag',
    pairingId: 'pair-$host$tag',
    masterSeedHex: 'seed-$host$tag',
    devSignPubHex: 'devsign-$host$tag',
    devDhPubHex: 'devdh-$host$tag',
    deviceToken: 'token-$host$tag',
    refreshToken: 'refresh-$host$tag',
    endpoints: [endpoint],
    endpointMeta: EndpointMeta(
      rememberedEndpointId: endpoint.id,
      hiddenEndpointIds: {endpoint.id},
      succeededEndpointIds: {endpoint.id},
    ),
    pcId: 'local',
    devId: 'dev-$host$tag',
  );
}

void _expectSameCredentials(
  PairedCredentials actual,
  PairedCredentials expected,
) {
  expect(actual.relayUrl, expected.relayUrl);
  expect(actual.pcSignPubHex, expected.pcSignPubHex);
  expect(actual.pcDhPubHex, expected.pcDhPubHex);
  expect(actual.pairingId, expected.pairingId);
  expect(actual.masterSeedHex, expected.masterSeedHex);
  expect(actual.devSignPubHex, expected.devSignPubHex);
  expect(actual.devDhPubHex, expected.devDhPubHex);
  expect(actual.deviceToken, expected.deviceToken);
  expect(actual.refreshToken, expected.refreshToken);
  expect(actual.pcId, expected.pcId);
  expect(actual.devId, expected.devId);
  expect(
    actual.endpoints.map((e) => e.id).toList(),
    expected.endpoints.map((e) => e.id).toList(),
  );
  expect(
    actual.endpointMeta.rememberedEndpointId,
    expected.endpointMeta.rememberedEndpointId,
  );
  expect(
    actual.endpointMeta.hiddenEndpointIds,
    expected.endpointMeta.hiddenEndpointIds,
  );
  expect(
    actual.endpointMeta.succeededEndpointIds,
    expected.endpointMeta.succeededEndpointIds,
  );
}

/// 把一份凭据按**升级前的平铺形状**写进存储（`dsh.<field>`，没有 active / 槽）。
void _seedLegacy(_MemorySecure secure, PairedCredentials credentials) {
  void put(String field, String value) {
    secure.values[PairingStore.legacyKey(field)] = value;
  }

  put('relay_url', credentials.relayUrl);
  put(
    'endpoints',
    jsonEncode(credentials.endpoints.map(endpointToJson).toList()),
  );
  // **旧形状的元数据是裸 url**（不是 `hostId|url`）：三份都按 url 写，
  // 迁移后必须解成带归属的 id。
  put(
    'endpoint_meta',
    jsonEncode(<String, Object?>{
      if (credentials.endpointMeta.rememberedEndpointId != null)
        'remembered': credentials.relayUrl,
      'hidden': [credentials.relayUrl],
      'succeeded': [credentials.relayUrl],
    }),
  );
  put('pc_sign_pub', credentials.pcSignPubHex);
  put('pc_dh_pub', credentials.pcDhPubHex);
  put('pairing_id', credentials.pairingId);
  put('master_seed', credentials.masterSeedHex);
  put('dev_sign_pub', credentials.devSignPubHex);
  put('dev_dh_pub', credentials.devDhPubHex);
  put('pc_id', credentials.pcId);
  put('dev_id', credentials.devId);
  put('device_token', credentials.deviceToken);
  put('refresh_token', credentials.refreshToken);
}

void main() {
  const hostA =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const hostB =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  group('分槽：一台电脑一个槽，配对第二台不覆盖第一台', () {
    test('配对 A → 配对 B：A 的令牌与主种子逐字未变，active 变成 B', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      final a = _credentials(hostA);
      final b = _credentials(hostB);

      await store.save(a);
      expect(secure.values[PairingStore.activeKey], hostA);
      expect(
        secure.values[PairingStore.slotKey(hostA, 'device_token')],
        'token-$hostA',
      );

      await store.save(b);

      // 当前那台是 B。
      expect(secure.values[PairingStore.activeKey], hostB);
      final active = await store.load();
      expect(active, isNotNull);
      _expectSameCredentials(active!, b);

      // **A 还在，且逐字未变**（不是"看起来像"）。
      expect(
        secure.values[PairingStore.slotKey(hostA, 'device_token')],
        'token-$hostA',
      );
      expect(
        secure.values[PairingStore.slotKey(hostA, 'master_seed')],
        'seed-$hostA',
      );
      final againA = await store.load(hostId: hostA);
      expect(againA, isNotNull);
      _expectSameCredentials(againA!, a);
    });

    test('端点表与路由记忆按槽隔离（各写各的）', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      final a = _credentials(hostA);
      final b = _credentials(hostB);
      await store.save(a);
      await store.save(b);

      await store.saveEndpoints(
        hostId: hostA,
        endpoints: [
          const Endpoint(
            kind: EndpointKind.direct,
            url: 'ws://a:1',
            hostId: hostA,
          ),
        ],
      );
      await store.saveEndpointMeta(hostId: hostA, meta: const EndpointMeta());

      final againA = (await store.load(hostId: hostA))!;
      final againB = (await store.load(hostId: hostB))!;
      expect(againA.endpoints.map((e) => e.url), ['ws://a:1']);
      expect(againB.endpoints.map((e) => e.url), ['ws://relay.example:8787']);
      expect(againA.endpointMeta.rememberedEndpointId, isNull);
      expect(againB.endpointMeta.rememberedEndpointId, isNotNull);
    });
  });

  group('迁移：旧平铺键 → 槽，一次性且幂等', () {
    test('迁一次后 load() 与原值逐字相等；旧键消失；第二次不写盘', () async {
      final secure = _MemorySecure();
      final legacy = _credentials(hostA);
      _seedLegacy(secure, legacy);
      expect(secure.writes, 0);

      final store = PairingStore(secure);
      final loaded = await store.load();
      expect(loaded, isNotNull);
      _expectSameCredentials(loaded!, legacy);

      expect(secure.values[PairingStore.activeKey], hostA);
      expect(
        secure.values[PairingStore.slotKey(hostA, 'device_token')],
        'token-$hostA',
      );
      expect(
        secure.values.keys.where((k) => !k.startsWith(PairingStore.keyPrefix)),
        isEmpty,
        reason: '旧平铺键必须删掉，否则下次还会再搬一遍',
      );

      final writesAfterMigration = secure.writes;
      final again = await store.load();
      expect(again, isNotNull);
      _expectSameCredentials(again!, legacy);
      expect(
        secure.writes,
        writesAfterMigration,
        reason: '迁移幂等：判据是写次数，不是"看起来一样"',
      );
    });

    test('新槽已有值时不覆盖（半迁移以槽为准），但旧键仍要清掉', () async {
      final secure = _MemorySecure();
      final legacy = _credentials(hostA);
      _seedLegacy(secure, legacy);
      // 模拟"槽写了一半就崩"：槽里已有一条不同的 relay_url。
      secure.values[PairingStore.slotKey(hostA, 'relay_url')] = 'ws://slot:1';

      final store = PairingStore(secure);
      final loaded = await store.load();

      expect(loaded?.relayUrl, 'ws://slot:1', reason: '槽优先，不拿旧键覆盖');
      expect(
        secure.values.containsKey(PairingStore.legacyKey('relay_url')),
        isFalse,
        reason: '旧键该清掉（其余字段仍按缺失从旧键补齐）',
      );
      expect(
        secure.values[PairingStore.slotKey(hostA, 'master_seed')],
        'seed-$hostA',
        reason: '槽里没有的字段从旧键补',
      );
    });

    test('没有旧键也没有槽 ⇒ null（不编一份凭据）', () async {
      final store = PairingStore(_MemorySecure());
      expect(await store.load(), isNull);
    });
  });

  group('清理：clear 只删这一台，clearAll 才撤销全部', () {
    test('clear(hostA)：A 的槽全删，B 与 active 不动', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      await store.save(_credentials(hostA));
      await store.save(_credentials(hostB));

      await store.clear(hostId: hostA);

      expect(
        secure.values.keys.where(
          (k) => k.startsWith('${PairingStore.keyPrefix}$hostA.'),
        ),
        isEmpty,
      );
      expect(secure.values[PairingStore.activeKey], hostB);
      expect(await store.load(hostId: hostA), isNull);
      _expectSameCredentials((await store.load())!, _credentials(hostB));
    });

    test('clear() 删当前那台，并把 active 清掉（不自动挑另一台）', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      await store.save(_credentials(hostA));
      await store.save(_credentials(hostB));

      await store.clear();

      expect(await store.load(), isNull);
      expect(secure.values[PairingStore.activeKey], isNull);
      // A 是更早的槽：**不自动顶上**（"谁接管"是用户决定，不是我们的）。
      expect(await store.load(hostId: hostA), isNotNull);
    });

    test('clearAll()：全清，任何槽都读不到', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      await store.save(_credentials(hostA));
      await store.save(_credentials(hostB));

      await store.clearAll();

      expect(secure.values, isEmpty);
      expect(await store.load(), isNull);
      expect(await store.load(hostId: hostA), isNull);
    });
  });
}
