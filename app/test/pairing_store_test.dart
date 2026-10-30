/// 配对凭据的**分槽**判据（多机第 2 步；**不做旧数据兼容**）。
///
/// 判据来自 `proposed/2026-10-29-one-phone-many-computers.md` 的准入门槛 1、2：
///
/// 1. 两个槽互不影响：配对 A → 配对 B → A 的 `deviceToken` / `masterSeed` 逐字未变，
///    且 `active == B`。
/// 2. 不迁移：只有旧平铺键 `dsh.<field>` 时 `load()` 回 `null`，一个键都不写（没发版）
///    —— 判据是写次数，不是"看起来一样"。
///
/// 这里用内存 [SecureStore] 驱动；真实现是系统密钥库（真机用例才验它）。
library;

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

  group('切换：列表 / activate / 名字缓存（多机第 4 步）', () {
    test('hosts()：只列能用的槽，当前那台排最前', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      await store.save(_credentials(hostA));
      await store.save(_credentials(hostB));

      final hosts = await store.hosts();
      expect(hosts.map((h) => h.hostId).toList(), [
        hostB,
        hostA,
      ], reason: '当前那台最前');
      // 读不到名字时退回短码（前 6 + 后 4）—— 名字可改可重名，短码不会。
      expect(hosts.first.label, 'bbbbbb…bbbb');
      expect(hosts.first.shortCode, 'bbbbbb…bbbb');
    });

    test('半份槽不进列表（点它只会得到"凭据不完整"）', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      await store.save(_credentials(hostA));
      // 造一个只有 pc_sign_pub 的半槽（模拟写一半崩掉）。
      secure.values[PairingStore.slotKey(hostB, 'pc_sign_pub')] = hostB;

      final hosts = await store.hosts();
      expect(hosts.map((h) => h.hostId).toList(), [hostA]);
    });

    test('activate：只改 active（指针），不重写槽、不动别的电脑', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      await store.save(_credentials(hostA));
      await store.save(_credentials(hostB));
      final writesBefore = secure.writes;

      await store.activate(hostA);

      expect(secure.values[PairingStore.activeKey], hostA);
      expect(
        secure.writes,
        writesBefore + 1,
        reason: '切槽只该写一次 active：重写整份槽既浪费也多一次"写一半"的机会',
      );
      _expectSameCredentials((await store.load())!, _credentials(hostA));
      _expectSameCredentials(
        (await store.load(hostId: hostB))!,
        _credentials(hostB),
      );
    });

    test('activate 拒绝半份槽：不让 active 指向读不出的凭据', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      await store.save(_credentials(hostA));

      await expectLater(
        store.activate(hostB),
        throwsA(isA<StateError>()),
        reason: '半个槽被选中 = 启动时有 active 却读不出凭据，那状态没有出路',
      );
      expect(
        secure.values[PairingStore.activeKey],
        hostA,
        reason: 'active 不该被改坏',
      );
    });

    test('电脑名缓存进那一台的槽：列表据此显示名字，clear 时一并删掉', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      await store.save(_credentials(hostA));
      await store.save(_credentials(hostB));

      await store.saveHostName(hostB, '客厅那台');
      final hosts = await store.hosts();
      expect(hosts.first.hostId, hostB);
      expect(hosts.first.label, '客厅那台');
      expect(hosts.first.name, '客厅那台');

      // 名字是槽的一部分（前缀扫描）→ 清槽就没了，不会留在存储里。
      await store.clear(hostId: hostB);
      expect(
        secure.values.containsKey(
          PairingStore.slotKey(hostB, PairingStore.hostNameField),
        ),
        isFalse,
      );
    });
  });

  group('不做旧数据兼容：平铺键 `dsh.<field>` 当作没有', () {
    test('只有旧平铺键时 load() 回 null，且一个键都不写', () async {
      // 协议没发版、没有存量安装：旧形状不识别、不迁移，也不顺手删用户数据。
      final secure = _MemorySecure();
      secure.values['dsh.pc_sign_pub'] = hostA;
      secure.values['dsh.device_token'] = 'token-old';
      final store = PairingStore(secure);
      expect(await store.load(), isNull);
      expect(secure.writes, 0, reason: '不迁移就不该写盘');
      expect(secure.deletes, 0, reason: '不认识的键也不该被删');
      expect(secure.values['dsh.device_token'], 'token-old');
    });

    test('旧平铺键与槽并存：只认槽（不拿旧键补缺字段）', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      // 槽里少 master_seed（不完整）；旧平铺键里恰好有它。
      final a = _credentials(hostA);
      await store.save(a);
      secure.values.remove(PairingStore.slotKey(hostA, 'master_seed'));
      secure.values['dsh.master_seed'] = 'seed-legacy';
      expect(await store.load(), isNull, reason: '槽不完整就是没有，不从旧键拼半份');
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
