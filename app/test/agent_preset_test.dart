/// Agent 预设目录的解析与显示名（`agentPresets.list` → 手机侧那枚模式 chip）。
///
/// 守两件事，都是"错了不会报错、只会显示错东西"的那一类：
///
/// 1. **显示名的两条规则是分开的**：内置四档走本地化字典，
///    **用户自建的元数据永不翻译** —— 判据是 `name == null && id 在内置表里`
///    （DSH `display.ts:53-55`）。合成一个就会把用户自己起的名字换掉。
/// 2. **`broken` 的行不进选择器**，但它**不是"没拿到目录"** ——
///    两者在界面上都是空列表，而正确表现一个是"筛掉一个坏项"、
///    另一个是"明说拿不到"。连接器整包透传，过滤在这一层做。
library;

import 'package:dsh_mobile/model/agent_preset.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一份够真的应答：四个内置（**不发布 name**）+ 一个自建 + 一个坏的。
/// 形状照连接器 `{available, roster:{presets:[…]}}`，行形状照 DSH 的 `AgentPresetRow`。
Map<String, Object?> rosterReply({
  bool available = true,
  List<Map<String, Object?>>? presets,
}) => {
  'available': available,
  'roster': {
    'presets':
        presets ??
        [
          {'id': 'standard', 'isDefault': true},
          {'id': 'ptc', 'isDefault': false},
          {'id': 'minimal', 'isDefault': false},
          {'id': 'cordis', 'isDefault': false},
          {
            'id': 'team-review',
            'isDefault': false,
            'name': 'Team Review',
            'description': 'Review-only composition.',
          },
          {
            'id': 'half-built',
            'isDefault': false,
            'broken': 'missing tool: nope',
          },
        ],
  },
};

void main() {
  group('解析目录', () {
    test('四个内置 + 一个自建进选择器，坏的那行被筛掉', () {
      final roster = parseAgentPresetRoster(rosterReply());

      expect(roster.available, isTrue);
      expect(
        roster.options.map((o) => o.id),
        ['standard', 'ptc', 'minimal', 'cordis', 'team-review'],
        reason:
            '`broken` 有值的行不进选择器（Web 的 `presetOptions` 同样只留 broken === undefined）',
      );
      expect(roster.defaultId, 'standard', reason: 'isDefault 那一行就是部署默认');
    });

    test('available:false（服务不在 / 读不到）→ 明说，不给空名单当真', () {
      // 与 `permission.catalog` 同一条纪律：`available:false` 是"拿不到目录"，
      // 不是"没有预设"。界面据此说「拿不到预设目录」而不是摆一个空选择器。
      final roster = parseAgentPresetRoster({'available': false});
      expect(roster.available, isFalse);
      expect(roster.options, isEmpty);
    });

    test('形状不对（不是 Map / 缺 roster / presets 不是数组）→ available:false，不猜', () {
      for (final bad in <Object?>[
        null,
        'nope',
        <Object?>[],
        {'available': true},
        {'available': true, 'roster': 42},
        {
          'available': true,
          'roster': {'presets': 'nope'},
        },
      ]) {
        final roster = parseAgentPresetRoster(bad);
        expect(roster.available, isFalse, reason: '形状不对就是"拿不到"，不是"没有预设"：$bad');
        expect(roster.options, isEmpty);
      }
    });

    test('没有 id 的行跳过（不拿空串当预设名）', () {
      final roster = parseAgentPresetRoster(
        rosterReply(
          presets: [
            {'id': '', 'isDefault': false},
            {'id': 'standard', 'isDefault': true},
          ],
        ),
      );
      expect(roster.options.map((o) => o.id), ['standard']);
    });
  });

  group('显示名', () {
    test('内置四档走本地化字典（DSH 的四个中文名逐字）', () {
      final roster = parseAgentPresetRoster(rosterReply());
      expect(roster.displayNameOf('standard'), '标准模式');
      expect(roster.displayNameOf('ptc'), 'PTC 模式');
      expect(roster.displayNameOf('minimal'), '极简模式');
      expect(roster.displayNameOf('cordis'), '创造模式');
      // 描述也来自同一份字典。
      expect(roster.options.first.displayDescription, contains('处理代码'));
    });

    test('用户自建的元数据永不翻译（哪怕名字叫 standard）', () {
      // 判据是"没有自定义 name **且** id 在内置表里"（`display.ts:53-55`）。
      // 一个自己起名 `standard` 的预设会发布 `name`，于是它是"自建"，
      // 走它自己的名字 —— 把两半判据合成一半就会在这里露馅。
      final roster = parseAgentPresetRoster(
        rosterReply(
          presets: [
            {'id': 'standard', 'name': '我的标准', 'isDefault': true},
          ],
        ),
      );
      expect(roster.displayNameOf('standard'), '我的标准');
    });

    test('目录里没有的 id 直接显示 id（照 AgentPresetLabel，不隐藏也不猜）', () {
      final roster = parseAgentPresetRoster(rosterReply());
      expect(roster.displayNameOf('some-other'), 'some-other');
      expect(roster.has('some-other'), isFalse);
    });

    test('自建没有描述就是 null —— 界面照 Web 显示「暂无描述。」', () {
      final roster = parseAgentPresetRoster(
        rosterReply(
          presets: [
            {'id': 'mine', 'name': '我的'},
          ],
        ),
      );
      expect(roster.options.single.displayDescription, isNull);
      expect(kNoPresetDescription, '暂无描述。');
    });
  });

  group('当前会话的预设（agentPreset 投影）', () {
    test('string 就取它；null / 缺键 / 非字符串都是"没记过"', () {
      expect(parseAgentPresetValue({'agentPreset': 'ptc'}), 'ptc');
      expect(parseAgentPresetValue({'agentPreset': null}), isNull);
      expect(parseAgentPresetValue({'agentPreset': 42}), isNull);
      expect(parseAgentPresetValue({}), isNull);
      expect(parseAgentPresetValue(null), isNull, reason: '还没读到投影时不能猜一个档');
      expect(parseAgentPresetValue({'agentPreset': ''}), isNull);
    });
  });

  group('内置文案表', () {
    test('四个 id 与 DSH 的 BUILT_IN_PRESET_KEYS 一一对应，不多不少', () {
      // 多一个 id 会让一个**用户自建**的预设被当成内置（于是名字被换成字典里那句）；
      // 少一个会让内置的那档显示成 id。
      expect(kBuiltInPresetCopy.keys.toList()..sort(), [
        'cordis',
        'minimal',
        'ptc',
        'standard',
      ]);
    });
  });
}
