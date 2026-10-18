/// 设置页 —— 第一版四组：**通用 / 模型 / 连接方式 / 关于与连接**。
///
/// ## 为什么是这四组
///
/// `docs/settings-porting-notes.md` 的第一版分组有 5 组（账号 / 通用 / 模型 /
/// 内置插件 / Agent 预设 / 关于连接），其余组还没搬。**不摆占位行** ——
/// 一行点下去只弹"还没做"的假入口，比没有这一行更糟（用户会以为功能坏了）。
/// 本版落地的判据是**这一行点了真的有作用**：
///
/// - **通用**：四项手机本地偏好（DSH 的"纯 UI 偏好"，§7.1 已论证**有意
///   偏离**存手机本地）。其中"工作步骤展示 / 性能与用量"直接影响对话流与
///   统计条的呈现，"繁忙时发送"就是输入区那个二选一（同一状态两个入口，
///   与 DSH 桌面把它放设置页一致）。
/// - **模型**：只读。当前模型与 provider 目录来自电脑侧真值
///   （`session/modelCatalog` + `modelSelection` 投影），拉取失败的 provider
///   **列出来**（静默丢掉 = "key 没配"在手机上毫无痕迹）。
/// - **连接方式**：端点选择器（`AppModel.endpoints`，序即偏好）。
/// - **关于与连接**：App 版本 + 连接状态。
///
/// 快捷键（无物理键盘）、内置插件 / Agent 预设 / 账号（都要先扩连接器方法面）
/// **不进本版** —— 依据见 `docs/settings-porting-notes.md` §10。
///
/// Note: 为什么只落四组、以及三项通用偏好为何存手机本地（有意偏离 DSH）——
/// 见 .agents/notes/implemented/2026-10-17-settings-page-v1-four-groups.md
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/endpoint.dart';
import '../core/errors.dart';
import '../data/app_model.dart';
import '../model/chat_item.dart';
import '../model/model_catalog.dart';
import '../model/preferences.dart';
import '../model/send_mode.dart';
import '../model/theme_mode.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'connection_summary_block.dart';
import 'dsh_app_bar.dart';
import 'dsh_sheet.dart';

/// App 版本（排错必需：手机侧这一行与电脑侧 DSH 版本互相印证）。
///
/// **没有 `package_info_plus`**：那是一个新依赖，而版本号对设置页只是
/// 一行文字。构建期由 `--dart-define` 注入；没注入时显示 "dev"——
/// 不猜一个版本号。
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

/// 设置页（从抽屉底栏「设置」 push 进来）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.app,
    required this.themeMode,
    required this.onThemeMode,
  });

  final AppModel app;

  /// 当前主题模式（三档，含"跟随系统"）。
  final DshThemeMode themeMode;

  /// 换主题。真值在 `ThemeController`（落盘 + 通知），这一层只转发。
  ///
  /// 返回 `Future`：切主题要**落盘**（`meta` 表），而 `_pickEnum` 的
  /// `onPicked` 统一收 `Future<void> Function(T)`（其它偏好也都是异步落盘的）。
  /// 用 `ValueSetter` 会让类型不匹配，也会让"落盘失败了"无处可等。
  final Future<void> Function(DshThemeMode) onThemeMode;

  @override
  Widget build(BuildContext context) {
    // **主题三件提成局部变量**：下面的 `builder: (context, _) => ListView(...)`
    // 是箭头函数体，而箭头体里 `widget.x` 不总被解析（实测报
    // `Undefined name 'widget'`）。提成本地变量既绕开这点，读起来也短。
    final themeMode = this.themeMode;
    final onThemeMode = this.onThemeMode;
    return Scaffold(
      backgroundColor: DshColors.bgBase,
      appBar: AppBar(
        backgroundColor: DshColors.sidebar,
        foregroundColor: DshColors.labelPrimary,
        // 图标照原型设置页的返回键（`chevronLeft`）—— 与顶栏同一套按钮，
        // 不引 Material 的默认返回箭头（那会多一套视觉）。
        leading: DshAppBarButton(
          icon: 'chevronLeft',
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text(
          '设置',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: DshColors.labelPrimary,
          ),
        ),
      ),
      // **整页听 `AppModel`**：端点表、拨号记录、连接状态、偏好都会变，
      // 不监听就等于列表永远停在首帧（与 `main.dart` 听抽屉同一条理由）。
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            // 与连接 sheet 顶部同一块。**在设置页它是入口**：
            // 点一下换一条并直接连（会断当前连接），右边图标只重连。
            // 下面的队列只管排序与管理，点行不再触发重拨。
            ConnectionSummaryBlock(
              connection: connectionSummary(
                state: app.connection,
                active: app.activeEndpoint,
                endpoints: app.endpoints,
                attemptOf: app.attemptOf,
              ),
              onTap: () => pickEndpointToConnect(context, app),
              onReconnect: () => reconnectNow(context, app),
              reconnecting: app.connection == ConnectionStateView.connecting,
            ),
            const _SectionTitle('通用'),
            // **主题（浅 / 深 / 跟随系统）** —— 2026-10-19 加。
            //
            // DSH 的 `design-platform.css` 一上来就有两套（浅色是 `:root`、
            // 深色是覆盖块），我们原先只落了深色；现在补齐，入口放在
            // "只影响这台手机的呈现"那一组里 —— 主题正是这么一类设置。
            _PrefRow(
              icon: 'dark',
              label: '主题',
              value: themeMode.label,
              onTap: () => _pickEnum<DshThemeMode>(
                context: context,
                title: '主题',
                values: DshThemeMode.values,
                labelOf: (v) => v.label,
                current: themeMode,
                onPicked: onThemeMode,
              ),
            ),
            _PrefRow(
              icon: 'checklist',
              label: '工作步骤展示',
              value: app.transcriptView.label,
              onTap: () => _pickEnum<TranscriptView>(
                context: context,
                title: '工作步骤展示',
                values: TranscriptView.values,
                labelOf: (v) => v.label,
                current: app.transcriptView,
                onPicked: app.setTranscriptView,
              ),
            ),
            _PrefRow(
              icon: 'gauge',
              label: '性能与用量',
              value: app.performanceUsage.label,
              onTap: () => _pickEnum<PerformanceUsage>(
                context: context,
                title: '性能与用量',
                values: PerformanceUsage.values,
                labelOf: (v) => v.label,
                current: app.performanceUsage,
                onPicked: app.setPerformanceUsage,
              ),
            ),
            _PrefRow(
              icon: 'queue',
              label: '繁忙时发送',
              value: app.sendMode.label,
              onTap: () => _pickEnum<SendMode>(
                context: context,
                title: '繁忙时的发送行为',
                values: SendMode.values,
                labelOf: (v) => v.label,
                current: app.sendMode,
                onPicked: app.setSendMode,
              ),
            ),
            const _PrefNote(
              '这三项只影响这台手机的呈现，不同步到电脑（DSH 桌面把它们存在'
              '电脑上，那是跨浏览器跟随；手机只有自己看，这是有意偏离）。',
            ),
            const _SectionTitle('模型'),
            _ModelSection(app: app),
            const _SectionTitle('连接方式'),
            const _EndpointNote(),
            if (app.endpoints.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Text(
                  '还没有端点。配对成功后，这里会列出可拨的地址。',
                  style: TextStyle(
                    fontSize: 13,
                    color: DshColors.labelSecondary,
                  ),
                ),
              )
            else
              _EndpointCard(app: app),
            if (app.hiddenEndpointIds.isNotEmpty) _HiddenEndpoints(app: app),
            const SizedBox(height: 8),
            _AddEndpointButton(app: app),
            const _SectionTitle('关于与连接'),
            _PrefRow(
              icon: 'info',
              label: 'App 版本',
              value: kAppVersion,
              onTap: () => _copy(context, kAppVersion),
            ),
            _PrefRow(
              icon: 'globe',
              label: '连接状态',
              value: connectionLabel(app.connection),
              onTap: () {},
            ),
          ],
        ),
      ),
    );
  }

  /// 复制到剪贴板（版本号一行）。
  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制')));
  }
}

/// 选一个枚举值（底部 sheet，行结构照 §7.9）。
Future<void> _pickEnum<T>({
  required BuildContext context,
  required String title,
  required List<T> values,
  required String Function(T) labelOf,
  required T current,
  required Future<void> Function(T) onPicked,
}) async {
  final picked = await showDshSheet<T>(
    context: context,
    title: title,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final value in values)
          DshPickerRow(
            name: labelOf(value),
            selected: value == current,
            onTap: () => Navigator.of(context).pop(value),
          ),
      ],
    ),
  );
  if (picked != null) await onPicked(picked);
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 2),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: DshColors.labelSecondary,
        ),
      ),
    );
  }
}

/// 一行偏好（`[图标 + 名称] [当前值]`）。
class _PrefRow extends StatelessWidget {
  const _PrefRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: DshIcon(icon, size: 18, color: DshColors.labelSecondary),
      title: Text(
        label,
        style: const TextStyle(fontSize: 14, color: DshColors.labelPrimary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 13, color: DshColors.labelCaption),
          ),
          const SizedBox(width: 4),
          const DshIcon(
            'chevronRight',
            size: 14,
            color: DshColors.labelTertiary,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// 偏好组下方的一行小字（说清这一组的边界）。
class _PrefNote extends StatelessWidget {
  const _PrefNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          height: 17 / 11,
          color: DshColors.labelTertiary,
        ),
      ),
    );
  }
}

/// 模型组：只读展示电脑侧真值 + 拉取失败的 provider。
class _ModelSection extends StatelessWidget {
  const _ModelSection({required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    final catalog = app.modelCatalog;
    final current = app.currentModel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PrefRow(
          icon: 'sparkle',
          label: '当前模型',
          value: current == null
              ? '未选择'
              : '${catalog?.displayNameOf(provider: current.provider, model: current.model) ?? current.label} · ${current.provider}',
          onTap: () {},
        ),
        if (catalog != null)
          _PrefRow(
            icon: 'listPen',
            label: '可用模型',
            value:
                '${catalog.allEntries.length} 个 · '
                '${catalog.groups.length} 个 provider',
            onTap: () {},
          ),
        // **拉取失败的 provider 必须列出来**：静默丢掉 = "key 没配"在手机上
        // 毫无痕迹，而用户看到的是"我的 provider 不见了"。
        for (final failure
            in catalog?.failures ?? const <ModelCatalogFailure>[])
          _PrefRow(
            icon: 'warningTriangle',
            label: '${failure.name} 拉取失败',
            value: failure.message,
            onTap: () {},
          ),
        const _PrefNote(
          '提供商与密钥的增删改在电脑上做（DSH 的模型设置页）。'
          '密钥值不回传手机，这一版也不从手机改。',
        ),
      ],
    );
  }
}

/// 连接方式组上方的一行小字。
class _EndpointNote extends StatelessWidget {
  const _EndpointNote();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Text(
        '拨号顺序：上次连上的那条先试 → 和你现在同一 WiFi 的次之 → 其余按这里的顺序。'
        '所以换地点通常不用重扫码；拨不通会自动顺延。'
        '点一行可以设为首选或删除，也可以手填一个地址。',
        style: TextStyle(fontSize: 12, color: DshColors.labelTertiary),
      ),
    );
  }
}

class _EndpointCard extends StatelessWidget {
  const _EndpointCard({required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    final endpoints = app.endpoints;
    if (endpoints.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: DshColors.layer1,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      // **可拖动排序**：队列的顺序就是自动拨号的优先级，拖比"点一下置顶"精确
      // （用户原话："队列最好可以拖动换位置"）。
      //
      // `shrinkWrap` + `NeverScrollable`：这张卡嵌在外层 `ListView` 里，
      // 它自己不该再滚 —— 否则内层滚动会吃掉外层的拖动与页面滚动。
      child: ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: endpoints.length,
        onReorder: (oldIndex, newIndex) async {
          // `ReorderableListView` 的 `newIndex` 是"插入位置"，向下拖时要减一。
          final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
          await app.moveEndpoint(oldIndex, target);
        },
        itemBuilder: (context, index) => Column(
          key: ValueKey(endpoints[index].id),
          mainAxisSize: MainAxisSize.min,
          children: [
            // 分隔线画在**行前面**而不是行里：拖动时它跟着行一起走，
            // 而"行与行之间的线"是静态的。
            if (index > 0) Divider(height: 1, color: DshColors.border()),
            _EndpointRow(app: app, endpoint: endpoints[index], index: index),
          ],
        ),
      ),
    );
  }
}

class _EndpointRow extends StatelessWidget {
  const _EndpointRow({
    required this.app,
    required this.endpoint,
    required this.index,
  });

  final AppModel app;

  final Endpoint endpoint;

  /// 在队列里的位置（拖动排序用）。
  final int index;

  @override
  Widget build(BuildContext context) {
    // 「当前连接」只在**真的在服务态**时给：拨通记录是跨连接保留的，
    // 重连中把上一条连接的赢家标成"当前"会和顶栏/连接 sheet 的说法打架
    //（那边此时说的是"重连中…"）。同一个事实只有一套说法。
    final isActive =
        app.connection == ConnectionStateView.serving &&
        app.activeEndpoint?.id == endpoint.id;
    final isFirst = app.endpoints.first.id == endpoint.id;
    final (status, statusColor) = _statusOf(isActive);
    // **正在按用户点名连接**时这一行暂时不可删：连接正在进行，删掉它会让
    // 失败回落的落点消失。
    final isRequested = app.requestedEndpoint?.id == endpoint.id;

    return InkWell(
      // **点一行 = 设为首选**（回到 2026-10-18 之前的口径）。
      //
      // 曾经改成"点一行立刻重连"，用户当场否掉："当前连接点击弹框选择连接方式
      // 直接连接就挺好啊……干嘛非要在队列上点？"——对：队列是**顺序与清单**，
      // 在逐行点击上挂"立刻断当前连接"这种副作用，会在管理偏好时不断打断连接。
      // 所以"换一条并立刻连"归顶部那块，「重连」归它右边的图标，这里只管顺序。
      onTap: () => _preferThis(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // 拖动柄：队列的顺序就是拨号优先级，**拖比"点一下置顶"精确**
            // （用户原话："队列最好可以拖动换位置"）。
            //
            // **命中区 44×44**：图标本体只有 18px，而 `ReorderableDragStartListener`
            // 的手势范围就是它的 child 尺寸 —— 直接拿图标当柄等于让手指去戳一个
            // 1/3 指甲盖大小的东西（真机上拖不动就是这个原因）。
            ReorderableDragStartListener(
              index: index,
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: DshIcon(
                    'chevronsUpDown',
                    size: 18,
                    color: DshColors.labelTertiary,
                  ),
                ),
              ),
            ),
            DshIcon(
              endpoint.kind == EndpointKind.direct ? 'link' : 'globe',
              size: 18,
              color: DshColors.labelSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    endpointKindLabel(endpoint.kind),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: DshColors.labelPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _addressLine(),
                    maxLines: 2,
                    style: const TextStyle(
                      fontSize: 12,
                      color: DshColors.labelSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status,
                    style: TextStyle(fontSize: 12, color: statusColor),
                  ),
                ],
              ),
            ),
            // **恒占位的勾位**（§7.9）：首选徽标与空位同宽 ——
            // 否则"选中才渲染"会让整行文字在置顶瞬间横移。
            SizedBox(
              width: 40,
              child: isFirst
                  ? const Center(
                      child: Text(
                        '首选',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: DshColors.accentBlue,
                        ),
                      ),
                    )
                  : null,
            ),
            SizedBox(
              width: 36,
              child: IconButton(
                tooltip: '更多',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: isRequested ? null : () => _onMore(context),
                icon: const DshIcon(
                  'ellipsis',
                  size: 18,
                  color: DshColors.labelSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 地址行：url + 连接器自报的名字（网卡名等）+ 来源。
  ///
  /// **来源不单独占一列**：选择类列表的行是「名称 / 其下标签组」+ 勾位
  /// （`AGENTS.md` §7.9），第三列会让整行在"手填/自动"之间横移。
  /// 它属于"这个地址是什么"的一部分，所以跟着地址走。
  String _addressLine() {
    final parts = <String>[endpoint.url];
    if (endpoint.label.isNotEmpty) parts.add(endpoint.label);
    if (endpoint.manual) parts.add('手填');
    return parts.join(' · ');
  }

  /// 状态文案与颜色。**全部来自真实拨号记录**，没有记录就说"还没试过"。
  (String, Color) _statusOf(bool isActive) {
    if (app.requestedEndpoint?.id == endpoint.id) {
      return ('正在用这条连接…', DshColors.accentBlue);
    }
    if (isActive) return ('当前连接', DshColors.stateSuccess);
    final attempt = app.attemptOf(endpoint);
    if (attempt == null) return ('还没试过', DshColors.labelCaption);
    if (attempt.ok) return ('拨通过', DshColors.labelTertiary);
    final reason = attempt.reason?.isNotEmpty == true
        ? '：${attempt.reason}'
        : '';
    return ('拨不通$reason', DshColors.error);
  }

  /// **点一行 = 设为首选**（只改顺序，不动当前连接）。
  Future<void> _preferThis(BuildContext context) async {
    final isFirst = app.endpoints.first.id == endpoint.id;
    if (isFirst) {
      _toast(context, '已经是首选');
      return;
    }
    await app.preferEndpoint(endpoint);
    if (!context.mounted) return;
    _toast(context, '已设为首选，下次自动连接时优先');
  }

  /// 行尾「⋯」：把这个端点**立刻连上**，或者删掉。
  ///
  /// "立刻连"放在这里而不是整行：整行已经是"设首选"，两种点击意图挤在同一行
  /// 会让人不敢点（用户原话见 [_EndpointRow] 的注释）。
  Future<void> _onMore(BuildContext context) async {
    final isActive =
        app.connection == ConnectionStateView.serving &&
        app.activeEndpoint?.id == endpoint.id;
    final action = await showDshSheet<String>(
      context: context,
      title: endpointKindLabel(endpoint.kind),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DshPickerRow(
            name: '现在用这条连',
            tags: [if (isActive) '已经在用这一条' else '会断开当前连接，只试这一条'],
            selected: isActive,
            icon: 'refresh',
            enabled: !isActive,
            onTap: () => Navigator.of(context).pop('connect'),
          ),
          DshPickerRow(
            name: '删除这个端点',
            tags: [endpoint.manual ? '手填的地址，删了就没了' : '删掉后连接器再报也不会加回来'],
            selected: false,
            icon: 'trash',
            onTap: () => Navigator.of(context).pop('remove'),
          ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;

    if (action == 'connect') {
      await _connectNow(context);
      return;
    }
    if (action == 'prefer') {
      await _preferThis(context);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: DshColors.layer1,
        title: const Text('删除这个端点？'),
        content: Text(
          '${_addressLine()}\n\n'
          '这只是从这台手机上移除一条路由，不影响配对 ——'
          '凭据还在，随时可以手填地址加回来。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除', style: TextStyle(color: DshColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await app.removeEndpoint(endpoint);
    if (!context.mounted) return;
    _toast(context, '已删除');
  }

  /// **用这个端点立刻连接**（点名）。
  ///
  /// 失败会自动回到自动队列 —— 所以 toast 要**说清发生了什么**，
  /// 而不是只报"失败"：用户得知道"我选的那条没通，现在的连接是怎么来的"。
  Future<void> _connectNow(BuildContext context) async {
    if (app.onReconnect == null) {
      _toast(context, '这条连接不支持点名拨号');
      return;
    }
    final label = endpointKindLabel(endpoint.kind);
    _toast(context, '正在用「$label」连接…');
    final ok = await app.useEndpointNow(endpoint);
    if (!context.mounted) return;
    if (ok) {
      _toast(context, '已连上「$label」');
      return;
    }
    final reason = app.endpointRequestResult?.reason;
    _toast(
      context,
      reason == null || reason.isEmpty
          ? '这条没连上，已回到自动选择'
          : '这条没连上（$reason），已回到自动选择',
    );
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 「已隐藏」—— 用户删掉的自报端点。
///
/// **必须有个地方看得见**：删掉之后连接器每次连上都会再报它，
/// 我们只是把它挡在表外；不显示的话用户会以为"删了但还在"，
/// 也没法反悔。
class _HiddenEndpoints extends StatelessWidget {
  const _HiddenEndpoints({required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    final hidden = app.hiddenEndpointIds;
    if (hidden.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        onTap: () async {
          final id = await showDshSheet<String>(
            context: context,
            title: '已隐藏的端点（${hidden.length}）',
            body: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final url in hidden)
                  DshPickerRow(
                    name: url,
                    tags: const ['点一下放回来'],
                    selected: false,
                    icon: 'unarchive',
                    onTap: () => Navigator.of(context).pop(url),
                  ),
              ],
            ),
          );
          if (id == null) return;
          await app.unhideEndpoint(id);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text(
            '已隐藏 ${hidden.length} 条端点 · 点这里放回来',
            style: const TextStyle(
              fontSize: 12,
              color: DshColors.labelTertiary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 「+ 添加端点」—— 手填一个地址。
///
/// ## 校验在这里，不在 `data/`
///
/// 允许什么地址是**安全边界**（`core/endpoint.dart` 的 `checkedRelayUri`：
/// 公网必须 wss、明文只限非公网）。`AppModel.addManualEndpoint` 只存值 ——
/// 两处各判一遍就会漂。
///
/// **直连只收 `ws://`**：电脑侧监听面刻意不终结 TLS（`connector/src/transport/
/// listener.ts` 的"不终结 TLS"），所以直连地址就是明文；写成 `wss://` 反而拨不通。
class _AddEndpointButton extends StatelessWidget {
  const _AddEndpointButton({required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => _add(context),
        icon: const DshIcon('plus', size: 16, color: DshColors.accentBlue),
        label: const Text('添加端点'),
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final added = await showDialog<Endpoint>(
      context: context,
      builder: (context) => const _AddEndpointDialog(),
    );
    if (added == null || !context.mounted) return;
    await app.addManualEndpoint(added);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已添加，下次重连会试它')));
  }
}

/// 填地址的小对话框（kind + url）。
class _AddEndpointDialog extends StatefulWidget {
  const _AddEndpointDialog();

  @override
  State<_AddEndpointDialog> createState() => _AddEndpointDialogState();
}

class _AddEndpointDialogState extends State<_AddEndpointDialog> {
  EndpointKind _kind = EndpointKind.direct;
  final _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _input.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '填一个地址');
      return;
    }
    try {
      // 过安全边界：公网必须 wss、明文只限非公网。
      checkedRelayUri(raw, allowInsecureLocal: kDebugMode);
      if (_kind == EndpointKind.direct) {
        if (!raw.startsWith('ws://')) {
          setState(() => _error = '直连是明文 ws://（电脑侧监听面不终结 TLS）');
          return;
        }
        if (!isPrivateOrLoopback(Uri.parse(raw).host)) {
          setState(() => _error = '直连地址必须是局域网 / 回环地址');
          return;
        }
      }
    } on ProtocolException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    Navigator.of(context).pop(Endpoint(kind: _kind, url: raw));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: DshColors.layer1,
      title: const Text('添加端点'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final kind in EndpointKind.values) ...[
                ChoiceChip(
                  label: Text(endpointKindLabel(kind)),
                  selected: _kind == kind,
                  onSelected: (_) => setState(() {
                    _kind = kind;
                    _error = null;
                  }),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _input,
            autofocus: true,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: _kind == EndpointKind.direct
                  ? 'ws://192.168.1.4:8790'
                  : 'wss://relay.example.com',
              hintStyle: const TextStyle(fontSize: 12),
              errorText: _error,
              errorMaxLines: 2,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 8),
          Text(
            _kind == EndpointKind.direct
                ? '直连不走中转、不要票：填电脑侧直连监听面的地址。'
                : '中转要换票：填中转的根地址（不带路径）。',
            style: const TextStyle(
              fontSize: 11,
              color: DshColors.labelTertiary,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }
}
