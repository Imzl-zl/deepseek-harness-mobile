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

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/platform/pairing_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemorySecure implements SecureStore {
  final Map<String, String> values = <String, String>{};
  int writes = 0;
  int deletes = 0;
  int? failWriteAt;
  bool failRead = false;

  @override
  Future<Map<String, String>> readAll() async {
    if (failRead) throw StateError('secure read failed');
    return Map<String, String>.of(values);
  }

  @override
  Future<void> write(String key, String value) async {
    writes += 1;
    if (writes == failWriteAt) throw StateError('secure write interrupted');
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
PairedCredentials _credentials(
  String host, {
  String tag = '',
  String? deviceId,
}) {
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
    devId: deviceId ?? 'dev-$host$tag',
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

Future<String> _deviceCode(PairingStore store) => store.getOrCreateDeviceCode();

Future<String?> _previousPairingId(
  PairingStore store,
  String hostId,
  String pcId,
) => store.previousPairingIdFor(pcSignPubHex: hostId, pcId: pcId);

class _DelayedCredentialWrite extends _MemorySecure {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool holdFirstBlob = true;
  @override
  Future<void> write(String key, String value) async {
    if (holdFirstBlob && key.endsWith('.credentials_v2')) {
      holdFirstBlob = false;
      entered.complete();
      await release.future;
    }
    await super.write(key, value);
  }
}

Map<String, String> _legacyValues(PairedCredentials c) => {
  PairingStore.activeKey: c.pcSignPubHex,
  for (final entry in <String, String>{
    'relay_url': c.relayUrl,
    'pc_sign_pub': c.pcSignPubHex,
    'pc_dh_pub': c.pcDhPubHex,
    'pairing_id': c.pairingId,
    'master_seed': c.masterSeedHex,
    'dev_sign_pub': c.devSignPubHex,
    'dev_dh_pub': c.devDhPubHex,
    'device_token': c.deviceToken,
    'refresh_token': c.refreshToken,
    'pc_id': c.pcId,
    'dev_id': c.devId,
    'endpoints': jsonEncode(c.endpoints.map(endpointToJson).toList()),
    'endpoint_meta': jsonEncode({
      'remembered': c.endpointMeta.rememberedEndpointId,
      'hidden': c.endpointMeta.hiddenEndpointIds.toList(),
      'succeeded': c.endpointMeta.succeededEndpointIds.toList(),
    }),
  }.entries)
    PairingStore.slotKey(c.pcSignPubHex, entry.key): entry.value,
};

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
      final rawA = secure.values[PairingStore.slotKey(hostA, 'credentials_v2')];
      expect(rawA, isNotNull);
      _expectSameCredentials((await store.load())!, a);

      await store.save(b);

      // 当前那台是 B。
      expect(secure.values[PairingStore.activeKey], hostB);
      final active = await store.load();
      expect(active, isNotNull);
      _expectSameCredentials(active!, b);

      // **A 的完整原子凭据逐字未变**，不仅是其中的 token。
      expect(
        secure.values[PairingStore.slotKey(hostA, 'credentials_v2')],
        rawA,
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
      secure.values.addAll(_legacyValues(a));
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

      expect(
        secure.values.keys.where((k) => k.startsWith(PairingStore.keyPrefix)),
        isEmpty,
      );
      expect(await store.load(), isNull);
      expect(await store.load(hostId: hostA), isNull);
    });
  });
  group('安装级设备码与非凭据配对连续性', () {
    test('并发首次读取只创建一个码，重建 Store 仍是同一个码', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      final codes = await Future.wait([_deviceCode(store), _deviceCode(store)]);
      expect(codes.first, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      expect(codes.last, codes.first);
      expect(secure.writes, 1);
      expect(await _deviceCode(PairingStore(secure)), codes.first);
      expect(secure.writes, 1, reason: '重开不应重铸设备码');
    });
    test('两个同名手机的应用安装独立生成设备码', () async {
      final a = await _deviceCode(PairingStore(_MemorySecure()));
      final b = await _deviceCode(PairingStore(_MemorySecure()));
      expect(a, isNot(b));
    });
    test('坏设备码报错且不覆盖存储', () async {
      for (final bad in ['', 'bad-code', 'x' * 21, '!' * 22]) {
        final secure = _MemorySecure()..values['dsh.device_code'] = bad;
        await expectLater(_deviceCode(PairingStore(secure)), throwsStateError);
        expect(secure.values['dsh.device_code'], bad);
        expect(secure.writes, 0);
      }
    });
    test('安全存储读取失败不会当作首装生成新码', () async {
      final secure = _MemorySecure()..failRead = true;
      await expectLater(_deviceCode(PairingStore(secure)), throwsStateError);
      expect(secure.writes, 0);
    });
    test('clearAll 仅清配对秘密，安装码与别的安全记录保留', () async {
      final secure = _MemorySecure();
      const code = 'abcdefghijklmnopqrstuv';
      secure.values['dsh.device_code'] = code;
      secure.values['other.owner'] = 'leave-alone';
      final store = PairingStore(secure);
      await store.save(_credentials(hostA));
      await store.save(_credentials(hostB));
      await store.clearAll();
      expect(secure.values['dsh.device_code'], code);
      expect(secure.values['other.owner'], 'leave-alone');
      expect(
        secure.values.keys.where((k) => k.startsWith(PairingStore.keyPrefix)),
        isEmpty,
      );
    });
    test('旧标识按非当前目标公钥读取，pcId 不符不泄给另一台', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      final a = _credentials(hostA);
      await store.save(a);
      await store.save(_credentials(hostB));
      expect(await _previousPairingId(store, hostA, a.pcId), a.pairingId);
      expect(await _previousPairingId(store, hostA, 'another-pc'), isNull);
      expect(await _previousPairingId(store, 'unknown-host', a.pcId), isNull);
    });
    test('清槽前定位信息持久化，重启后能找旧行但不留秘密', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      final a = _credentials(hostA);
      await store.save(a);
      await store.clear();
      final raw = secure.values['dsh.pairing_hint.$hostA'];
      expect(raw, isNotNull, reason: '清槽不能只留 State 内存快照');
      expect(jsonDecode(raw!), {'pcId': a.pcId, 'pairingId': a.pairingId});
      final reopened = PairingStore(secure);
      expect(await _previousPairingId(reopened, hostA, a.pcId), a.pairingId);
      expect(await reopened.load(hostId: hostA), isNull);
      expect(jsonEncode(secure.values).contains(a.masterSeedHex), isFalse);
      expect(jsonEncode(secure.values).contains(a.deviceToken), isFalse);
    });
    test('clearAll 保留每台目标的定位，安装级码不变', () async {
      final secure = _MemorySecure();
      final store = PairingStore(secure);
      final code = await _deviceCode(store);
      final a = _credentials(hostA);
      final b = _credentials(hostB);
      await store.save(a);
      await store.save(b);
      await store.clearAll();
      final reopened = PairingStore(secure);
      expect(await _deviceCode(reopened), code);
      expect(await _previousPairingId(reopened, hostA, a.pcId), a.pairingId);
      expect(await _previousPairingId(reopened, hostB, b.pcId), b.pairingId);
    });
  });
  group('不可分割凭据的原子覆盖与相邻迁移', () {
    test('同 host 覆盖中断任一实际写点，重读只能完整旧或完整新身份', () async {
      final a = _credentials(hostA);
      final b = _credentials(hostA, tag: '-new');
      final probe = _MemorySecure();
      final probeStore = PairingStore(probe);
      await probeStore.save(a);
      final before = probe.writes;
      await probeStore.save(b);
      final writePoints = probe.writes - before;
      for (var point = 1; point <= writePoints; point += 1) {
        final secure = _MemorySecure();
        final store = PairingStore(secure);
        await store.save(a);
        secure.failWriteAt = secure.writes + point;
        await expectLater(store.save(b), throwsStateError);
        final actual = (await PairingStore(secure).load())!;
        _expectSameCredentials(
          actual,
          actual.masterSeedHex == a.masterSeedHex ? a : b,
        );
      }
    });
    test('完整已发版分槽迁到 v2 blob，删除旧秘密键但保留路由/名字', () async {
      final a = _credentials(hostA);
      final secure = _MemorySecure()..values.addAll(_legacyValues(a));
      secure.values[PairingStore.slotKey(hostA, 'host_name')] = 'A';
      _expectSameCredentials((await PairingStore(secure).load())!, a);
      final blob = secure.values[PairingStore.slotKey(hostA, 'credentials_v2')];
      expect(blob, isNotNull, reason: '完整旧槽须规范化为相邻新格式');
      expect((jsonDecode(blob!) as Map<String, Object?>)['v'], 2);
      for (final field in [
        'master_seed',
        'device_token',
        'pairing_id',
        'dev_dh_pub',
      ]) {
        expect(
          secure.values.containsKey(PairingStore.slotKey(hostA, field)),
          isFalse,
        );
      }
      expect(secure.values[PairingStore.slotKey(hostA, 'host_name')], 'A');
      final writes = secure.writes;
      _expectSameCredentials((await PairingStore(secure).load())!, a);
      expect(secure.writes, writes, reason: '迁移只发生一次');
    });
    test('迁移新 blob 写失败不先删任何旧凭据', () async {
      final a = _credentials(hostA);
      final legacy = _legacyValues(a);
      final secure = _MemorySecure()..values.addAll(legacy);
      secure.failWriteAt = 1;
      await expectLater(PairingStore(secure).load(), throwsStateError);
      expect(secure.values, legacy);
      expect(secure.deletes, 0);
    });
    test('坏新 blob 报错，不回落到完整旧键，也不覆盖修补它', () async {
      for (final raw in ['bad-json', '{"v":3}', '{"v":2}']) {
        final secure = _MemorySecure()
          ..values.addAll(_legacyValues(_credentials(hostA)));
        secure.values[PairingStore.slotKey(hostA, 'credentials_v2')] = raw;
        await expectLater(
          PairingStore(secure).load(),
          throwsA(isA<FormatException>()),
        );
        expect(
          secure.values[PairingStore.slotKey(hostA, 'credentials_v2')],
          raw,
        );
        expect(secure.writes, 0);
        expect(secure.deletes, 0);
      }
    });
  });
  test('真实安全存储调用显式禁止 Android 解密错误时全清', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    Map<dynamic, dynamic>? options;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      options = (call.arguments as Map)['options'] as Map;
      return <String, String>{};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await const FlutterSecureStore().readAll();
    expect(options?['resetOnError'], 'false');
  });
  group('覆盖升级的稳定显示码迁移', () {
    test('当前完整已发版旧槽以实际 hello 设备ID初始化稳定码', () async {
      final deviceId = await deriveDeviceId('f1' * 32);
      final a = _credentials(hostA, deviceId: deviceId);
      final secure = _MemorySecure()..values.addAll(_legacyValues(a));
      final expected = await a.helloDeviceId();
      expect(await _deviceCode(PairingStore(secure)), expected);
      expect(secure.values['dsh.device_code'], expected);
    });
    test('旧槽没有回执ID时以真实本地派生值初始化稳定码', () async {
      final a = _credentials(hostA, deviceId: '');
      final secure = _MemorySecure()..values.addAll(_legacyValues(a));
      final expected = await a.helloDeviceId();
      expect(await _deviceCode(PairingStore(secure)), expected);
    });
    test('一次迁移后重配换鉴权devId也不再更换稳定码', () async {
      final a = _credentials(hostA, deviceId: await deriveDeviceId('f1' * 32));
      final b = _credentials(
        hostA,
        tag: '-new',
        deviceId: await deriveDeviceId('f2' * 32),
      );
      final secure = _MemorySecure()..values.addAll(_legacyValues(a));
      final store = PairingStore(secure);
      final expected = await a.helloDeviceId();
      expect(await _deviceCode(store), expected);
      await store.save(b);
      expect((await store.load())!.devId, b.devId);
      expect(await _deviceCode(PairingStore(secure)), expected);
    });
    test('缺设备码且当前v2坏了时明确报错，不用随机码盖过故障', () async {
      final secure = _MemorySecure()
        ..values.addAll(_legacyValues(_credentials(hostA)));
      secure.values[PairingStore.slotKey(hostA, 'credentials_v2')] = '{"v":2}';
      await expectLater(
        _deviceCode(PairingStore(secure)),
        throwsA(isA<FormatException>()),
      );
      expect(secure.values.containsKey('dsh.device_code'), isFalse);
      expect(secure.writes, 0);
    });
  });
  test('迟到的旧槽迁移不能覆盖同Store已经请求保存的新身份', () async {
    final a = _credentials(hostA);
    final b = _credentials(hostA, tag: '-new');
    final secure = _DelayedCredentialWrite()..values.addAll(_legacyValues(a));
    final store = PairingStore(secure);
    final loading = store.load();
    await secure.entered.future;
    final saving = store.save(b);
    // 事件队列边界：让已排队的内存存储 microtasks 运行完，不以真实时间猜竞态。
    await Future<void>.delayed(Duration.zero);
    secure.release.complete();
    await Future.wait<Object?>([loading, saving]);
    _expectSameCredentials((await store.load())!, b);
  });

  test('坏秘密blob只报安全错误，失败不污染后续保存队列', () async {
    final a = _credentials(hostA);
    final secure = _MemorySecure()..values.addAll(_legacyValues(a));
    secure.values[PairingStore.slotKey(hostA, 'credentials_v2')] =
        '{"device_token":"${a.deviceToken}","v":2, invalid';
    final store = PairingStore(secure);
    FormatException? failure;
    try {
      await store.load();
    } on FormatException catch (error) {
      failure = error;
    }
    expect(failure, isNotNull);
    expect(failure!.source, isNull, reason: '异常对象不能携带含令牌的原始blob');
    expect(failure.toString().contains(a.deviceToken), isFalse);
    await store.save(a);
    _expectSameCredentials((await store.load())!, a);
  });
  test('设备码初始化中的旧槽迁移也共享保存队列', () async {
    final a = _credentials(hostA, deviceId: await deriveDeviceId('f1' * 32));
    final b = _credentials(
      hostA,
      tag: '-new',
      deviceId: await deriveDeviceId('f2' * 32),
    );
    final secure = _DelayedCredentialWrite()..values.addAll(_legacyValues(a));
    final store = PairingStore(secure);
    final getting = store.getOrCreateDeviceCode();
    await secure.entered.future;
    final saving = store.save(b);
    await Future<void>.delayed(Duration.zero);
    secure.release.complete();
    await Future.wait<Object?>([getting, saving]);
    _expectSameCredentials((await store.load())!, b);
    expect(await store.getOrCreateDeviceCode(), await a.helloDeviceId());
  });
}
