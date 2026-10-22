/// 输入栏与统计条（照 `mock/proto/index.html` 的 `footer.foot`）。
///
/// ## 三条硬规则（`design-and-tech-plan.md` §7.2，踩过坑写死的）
///
/// 1. **附件在卡片内部上方**，不是卡片外单独一行 ——
///    卡片外会被状态行和输入框夹住，视觉上像"被顶上去的一块"。
/// 2. **文字独占一行**，`＋` 和发送键**不进文字行** ——
///    否则占位符被迫折行、模型名被截成 `claude-...`。
/// 3. **控制行左一组（`＋` / 模型·等级 / 权限图标 / 发送模式图标），右边只有发送键**。
///    **这是有意偏离 DSH 桌面**：桌面把模型放 `.trailing`（右侧）和发送键一组；
///    手机主流是左侧集中、右侧单发送。
///    模型 chip 可压缩（上限 62%），权限与发送模式各 34px 恒宽 ——
///    保证长模型名不挤走这两个图标或发送键。
///    发送模式（排队 / 插话）是 2026-10-13 补的第四个控件：DSH 原生就有这个
///    二选一（"繁忙时的发送行为"），而它**只在会话正在跑时才有区别**，是发送
///    当下的选择 —— 放进行控区而不是以后的设置页，理由见 `model/send_mode.dart`。
///
/// ## 统计条在输入卡片**下面**
///
/// 照 DSH `InputBar.tsx:499`：统计与上下文挂在卡片下方，**不顶输入框**。
/// 点它弹 sheet（§7.4）——本版先只显示，sheet 是下一步。
library;

import 'package:flutter/material.dart';

import '../model/permission.dart';
import '../model/send_mode.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import '../theme/dsh_type.dart';

/// 待发送附件（`.attach-rail` 里的一项）。
class PendingAttachment {
  const PendingAttachment({
    required this.name,
    this.icon = 'deliverDoc',
    this.image,
  });

  final String name;
  final String icon;

  /// 图片附件（选到了才有）。`null` = 这一项不是可发送的图片。
  ///
  /// **2026-10-20 之前这里没有它** —— 那时「附件」加的是一个只有名字的
  /// 假芯片（`PendingAttachment(name: '新增文件.txt')`），而 `_send()` 的
  /// `content` 只有文本块，**附件被静默丢弃**。现在图片这条链是真的：
  /// 选到的字节随 `session.prompt` 的 `{type:'image', mediaType, data}`
  /// 一起发出去（DSH 的 `PromptContentPart`，见 `platform/photo_picker.dart`）。
  final PickedImagePart? image;

  /// 它是不是一枚"只有名字、发不出去"的芯片。
  ///
  /// 这种芯片**不许再出现在生产路径上**（2026-10-20 拔掉的那处就是它）；
  /// 留着这个判据是为了让"可发送"与"仅展示"在代码里分得开。
  bool get isInert => image == null;
}

/// 一枚可以直接塞进 `session.prompt` 的图片 part。
///
/// 形状与 DSH 的 `PromptContentPart` 的图片分支逐字一致：
/// `{type:'image', mediaType, data, name?}`
/// （`packages/api/session-controller/src/types.ts:90-98`）。
class PickedImagePart {
  const PickedImagePart({
    required this.mediaType,
    required this.data,
    this.name = '',
    this.byteCount = 0,
  });

  final String mediaType;

  /// 规范 base64（无换行）。
  final String data;

  final String name;

  /// 原始字节数 —— **判"一条消息的合计有没有超一帧"用**
  /// （`kMaxTotalImageBytesForMessage`）。
  ///
  /// 为什么不在 `toWire` 里用 base64 长度反算：那只是估算（末尾填充），
  /// 而"合计超没超"是要下判断的事，估出来的数判断不了。
  final int byteCount;

  /// 发出去的那一段载荷。
  Map<String, Object?> toWire() => {
    'type': 'image',
    'mediaType': mediaType,
    'data': data,
    // `name` 是可选字段（DSH 的 `name?: string`）：空串就不带，
    // 免得电脑侧收到一个空名字。
    if (name.isNotEmpty) 'name': name,
  };
}

/// 一次发送的 `session.prompt.content`。
///
/// **纯函数**：把"输入栏里现在有什么"翻成线上载荷。抽出来是为了能直接断言
/// 形状（否则要驱动整个 ChatPage 才测得到，而那种测试查不出"少带了图片"
/// 这种错 —— 它只看有没有异常）。
///
/// 形状照 DSH 的 `PromptContentPart[]`
/// （`packages/api/session-controller/src/types.ts:90-98`）：
/// 文本是 `{type:'text', text}`，图片是 `{type:'image', mediaType, data, name?}`。
///
/// **图片排在文本之前**：模型先看到图、再读提示词，这是本仓的读法
/// （数组顺序本身 DSH 没有强制）。**只有带图片的附件才进 content** ——
/// 不可发送的（`isInert`）留在输入栏里，不假装发出去。
///
/// **空文本不发那一段**：`text` 为空时（"只发一张图"）content 里就没有
/// text part。发一个 `{type:'text', text:''}` 给电脑侧只是噪音。
List<Map<String, Object?>> promptContentOf({
  required String text,
  required List<PendingAttachment> attachments,
}) => [
  for (final attachment in attachments)
    if (attachment.image case final image?) image.toWire(),
  if (text.isNotEmpty) {'type': 'text', 'text': text},
];

/// 普通会话的输入框占位符。
///
/// **照抄 DSH 原文**（`packages/client/ui-conversation/src/client/locales.ts:20`
/// 的 `placeholder.default`）：半角逗号 + 空格（`任务, / 调用`），不是全角逗号。
/// 全角逗号更宽 —— 在 320px 屏上会让这段**更早折行**，
/// 而它本来就已接近放不下（实测 15px 需 345px、可用 282px）。
/// 文档 §7.2 写明"短屏由 CSS 自然折行，**不手动截断**"。
const String kComposerHintDefault = '发消息或创建任务, / 调用指令, @ 文件或对话';

/// **新会话页（hero）的占位符**，与普通会话只差前半句
/// （`locales.ts:23` 的 `placeholder.hero`）。
///
/// 两套文案都是半角逗号；DSH 在 hero 变体上把它换成"描述你想要构建的内容"，
/// 因为那一屏的动作是"开一个新任务"而不是"接着说"。
const String kComposerHintHero = '描述你想要构建的内容, / 调用指令, @ 文件或对话';

/// 输入栏（含附件轨 + 文字行 + 控制行）。
class DshComposer extends StatelessWidget {
  const DshComposer({
    super.key,
    required this.controller,
    required this.attachments,
    required this.modelName,
    required this.reasoningLabel,
    required this.access,
    required this.sendMode,
    required this.sending,
    required this.onSend,
    required this.onAttach,
    required this.onPickModel,
    required this.onPickAccess,
    required this.onRemoveAttachment,
    this.onPickReasoning,
    this.enabled = true,
    this.running = false,
    this.onStop,
    this.hintText = kComposerHintDefault,
  });

  /// 占位符。默认是普通会话那句；hero（blank 会话）传 [kComposerHintHero]。
  final String hintText;

  final TextEditingController controller;

  /// 附件（**卡片内部上方** —— 硬规则 1）。
  final List<PendingAttachment> attachments;

  final String modelName;

  /// 推理等级（显示成 `· 高`）；**`null` = 没有等级**。
  ///
  /// **2026-10-19 起它是独立的一枚 chip**，不再跟在模型名后面
  /// （用户原话：「模型选择，思考程度选择分开」）。换模型与换推理等级是
  /// **两个动作**，挤在一枚 chip 里要点开才知道哪一半可点。
  ///
  /// 与 DSH Web 的 `effortLabel` 同一条规则（`ModelSelect.tsx:488` 的
  /// `{effortLabel !== undefined && …}`）：没有等级就不占位 ——
  /// 390px 屏上那一枚约 40px。
  final String? reasoningLabel;

  /// 点那枚独立的推理等级 chip（`null` = 不可点，chip 仍显示当前值）。
  final VoidCallback? onPickReasoning;

  /// 当前权限档的展示值（图标 + 文案 + 是否告警色）。
  ///
  /// **从电脑侧真值来**（`permissions` 投影的 `currentValue`，经
  /// `model/permission.dart` 的 `permissionChipOf` 归一）—— 曾经这里是
  /// 一个三档手抄枚举，点完只改本地字段，与电脑侧无关。
  final PermissionChip access;

  /// 发送模式（排队 / 插话，DSH 的"繁忙时的发送行为"）。
  ///
  /// **只用于 tooltip 文字**（"排队发送 / 插话发送"）：改它的入口在设置页
  /// 「通用」，行控区那颗图标 2026-10-19 按用户要求移除（"设置中有，
  /// 这个也不经常更换设置，占位置"）。
  final SendMode sendMode;

  final bool sending;

  /// 是否可输入（没连电脑/没会话时置灰）。
  final bool enabled;

  /// 会话是否正在跑（决定主键是"停止"还是"发送"，照 Web 的 `primaryStops`）。
  final bool running;

  /// 「停止」（打断当前轮次）。**running 且没有草稿时才用主键触发它** ——
  /// 与 Web 逐字一致（`InputBar.tsx:323` 的
  /// `primaryStops = running && (empty || blocked)`）：有草稿时主键仍然是发送，
  /// 那句话按当前发送模式排队/插进去。
  final VoidCallback? onStop;

  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onPickModel;
  final VoidCallback onPickAccess;

  final void Function(PendingAttachment item) onRemoveAttachment;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final type = context.dshType;
    // **"有没有草稿"包括可发送的附件**（2026-10-20 修）。
    //
    // 原来只看文字：`controller.text.trim().isNotEmpty` —— 于是
    // **选了照片但没打字时发送键是灰的，发不出去**。而"只发一张图"
    // 是完全正常的用法（DSH 的 `content` 本来就是 part 数组，可以没有文本 part）。
    //
    // `isInert` 的（只有名字、没有字节）不算：那种根本发不出去，
    // 让它点亮发送键只会变成一个发出去什么都没带的动作。
    final hasText = controller.text.trim().isNotEmpty;
    final hasImage = attachments.any((item) => !item.isInert);
    final hasDraft = hasText || hasImage;
    final canSend = enabled && !sending && hasDraft;
    // **主键在运行中且没有草稿时是"停止"**（Web 的 `primaryStops`）。
    final stops = running && !hasDraft && onStop != null;
    return Container(
      // **底色是页面底色，不是 `sidebar`**（2026-10-20 用户反馈
      // "会话页面和输入框背景这一块设计不和谐"）。
      //
      // DSH 的输入栏 `.root` **没有声明背景**（`InputBar.module.css:2-11`：
      // 只有 `padding`），卡片直接坐在页面底色上、靠 `box-shadow` 浮起来。
      // 我们原来给它垫了一条 `c.sidebar` 灰带 —— 于是底部像一个**独立的栏**，
      // 与上面的会话区断开。真机量到的正是这样：
      // 页面 `#FFFFFF` / 灰带 `#F1F3F5` / 卡内 `#FFFFFF`。
      color: c.bgBase,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Container(
        // `.composer { padding:6px 6px 6px 8px; border-radius:24px }`
        padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
        decoration: BoxDecoration(
          // **`composer` 而不是 `layer1`**：DSH 用的是专用 token
          // `--dsw-specific-input-major`（`InputBar.module.css:62`）。
          // 亮色下它也是白 —— 所以"看得见"靠下面那层阴影，不是底色差。
          color: c.composer,
          borderRadius: BorderRadius.circular(24),
          // **`elevation-soft`**（`gradient-shadow-text.css:33,38-39`）：
          //   0 0 0 0.5px <border-l2>,
          //   0 4px 16px rgba(0,0,0,0.03),
          //   0 0 24px  rgba(0,0,0,0.03)
          // 第一层是**发丝环**：DSH 的 `.card` 明确写 `border: 0`，并注释
          // "描边由 elevation 发丝线画，不占布局"（`InputBar.module.css:55-63`）。
          // 少这三层，白卡在白底上就是一块看不出来的白。
          boxShadow: [
            BoxShadow(color: c.borderL2, spreadRadius: 0.5),
            const BoxShadow(
              color: Color(0x08000000),
              blurRadius: 16,
              offset: Offset(0, 4),
            ),
            const BoxShadow(color: Color(0x08000000), blurRadius: 24),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- 附件轨：**卡片内部最上方**（硬规则 1）----
            if (attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final item in attachments)
                      // **入场的淡入 + 微缩放**（2026-10-20）：选完图芯片会
                      // 立刻出现在卡片里，硬蹦出来读作"闪了一下"。
                      //
                      // 用 `TweenAnimationBuilder` 而不是给每个芯片加
                      // `AnimationController`：它自带"首次构建时跑一遍"，
                      // 不需要为一次性的入场维持 7 个控制器。
                      // 时长/曲线与发送键那次换形态同一个（160ms / easeOutCubic），
                      // 两处动画节奏一致才不会显得杂。
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0, end: 1),
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        builder: (context, t, child) => Opacity(
                          opacity: t,
                          child: Transform.scale(
                            scale: 0.92 + 0.08 * t,
                            child: child,
                          ),
                        ),
                        child: _AttachmentChip(
                          item: item,
                          onRemove: () => onRemoveAttachment(item),
                        ),
                      ),
                  ],
                ),
              ),

            // ---- 文字行：**独占一行**（硬规则 2）----
            TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 6,
              // 输入文字按**内容字号**缩放（DSH 的 `${…}` 正文档，
              // `--dsh-content-font-size`）—— 用户调大字号就是要看清自己打的字。
              style: TextStyle(fontSize: type.body, color: c.labelPrimary),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hintText,
                hintStyle: TextStyle(
                  fontSize: type.body,
                  color: c.labelTertiary,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 8,
                ),
              ),
              onSubmitted: (_) {
                if (canSend) onSend();
              },
            ),

            // ---- 控制行：左一组 / 右只有发送（硬规则 3）----
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      // `＋`：38×38 圆钮。
                      _RoundIconButton(
                        icon: 'plus',
                        tooltip: '添加文件或调用指令',
                        onPressed: enabled ? onAttach : null,
                      ),
                      const SizedBox(width: 6),
                      // **权限 chip 在模型 chip 之前**（2026-10-19 用户原话：
                      // 「模型和这个权限换一下位置」）。图标 34px 恒宽 ——
                      // 硬规则 3 的后半句：长模型名不许把它挤走。
                      _IconChip(
                        key: const Key('composer-access'),
                        icon: access.icon,
                        tooltip: access.label,
                        isWarn: access.warn,
                        onPressed: enabled ? onPickAccess : null,
                      ),
                      const SizedBox(width: 6),
                      // 模型 chip：**图标 + 模型名**，可压缩、上限 62%。
                      //
                      // 上限不能省：`Flexible` 只表示"可以被压"，不表示"最宽多少" ——
                      // 没有上限时它会**吃满**左组剩余宽度（长模型名尤其明显），
                      // 而原型 `#chipModel { max-width: 62% }` 是明确写了上限的。
                      // 实测：`claude-opus · 高` 在 1080px 宽的屏上被拉成一整条，
                      // 看起来像"模型是个很宽的选择器"，与胶囊形态不符。
                      //
                      // **图标 + 名字而不是裸名字**（照 rikkahub 的
                      // `ModelSelectorButton(onlyIcon = true)`，`ChatInput.kt:309-313`）：
                      // 真机上模型名是 `step-5-preview · max` 这种 20+ 字符的 id，
                      // 光靠文字就把左组吃掉一半；加一枚图标让"这是模型选择器"
                      // 在名字被省略号截掉之后仍然认得出。推理等级跟在名字后面
                      // （`· max`），它是同一个选择的第二半。
                      //
                      // 图标取 `database`：DSH Web 的模型触发器用的就是它
                      // （`ui-model-selection/src/client/ModelSelect.tsx:484` 的
                      // `IconDataOutlineRegular`，抽取进我们图标集时叫 `database`）。
                      // **不新造字形**：`verify-icons.cjs` 只放行集合内的 100 个。
                      // **`Flexible(loose)` + `Align(widthFactor: 1.0)`**（2026-10-19）：
                      // 单 `Flexible` 不够 —— `_Chip` 里的 `Container` 在 `0..X`
                      // 约束下会取 **X**（Flutter 的 `Container` 有界时用 biggest），
                      // 于是 chip 仍撑满、权限 chip 不动、"省宽度"没发生。
                      // `Align(widthFactor: 1.0)` 让 Align 的宽 = 子的宽，
                      // 而 `Flexible(loose)` 允许它小于分配宽 —— 两者一起才收缩。
                      // 长名字仍被这里的 maxWidth 截断（约束没丢）。
                      // 上限取**左组剩余空间的 62%**（不是整行的 62%）。
                      //
                      // 2026-10-19 权限挪到模型之前、等级分成独立一枚之后，
                      // 左组固定件变成 `＋ 38 + 权限 34 + 等级 34` = 106px。
                      // **再按整行的 62% 卡模型**，模型可用宽只剩
                      // `62% − 106px`，长模型名会比改布局前更早被省略号截断
                      // （实测：`deepseek-v4.1-flash-pro-preview-2026` 越过上限）——
                      // 那不是"更克制"，是把名字挤没了。原型
                      // `#chipModel { max-width: 62% }` 的口径是"占所在容器 62%"，
                      // 所以按**剩余空间**取。
                      Flexible(
                        fit: FlexFit.loose,
                        child: LayoutBuilder(
                          builder: (context, constraints) => Align(
                            alignment: Alignment.centerLeft,
                            widthFactor: 1.0,
                            child: ConstrainedBox(
                              // 测试用锚点：量"模型 chip 实际占多宽"
                              // （`composer_layout_test.dart` 的几何判据）。
                              key: const Key('composer-model-chip'),
                              constraints: BoxConstraints(
                                maxWidth: constraints.maxWidth * 0.62,
                              ),
                              child: _Chip(
                                onPressed: enabled ? onPickModel : null,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    DshIcon(
                                      'database',
                                      size: 13,
                                      color: c.labelSecondary,
                                    ),
                                    const SizedBox(width: 5),
                                    // 模型名：**`Flexible(loose)` 而不是 tight**。
                                    //
                                    // 2026-10-19 实测三个形态（最小复现逐层量）：
                                    // - `Flexible`（默认 tight）→ Text 被拉到
                                    //   "Row 宽 − 其他子宽"，而 Row 在 `0..X` 下取 X，
                                    //   chip 从 91.25 涨到 308.75（内容宽只要 271）；
                                    // - 裸 `Text`（无 flexible）→ Text 收到 `0..X`
                                    //   后取 X，chip 反而涨到 529（越过上限）；
                                    // - `Flexible(loose)` → 内容窄时不撑满、内容宽时
                                    //   压到上限，**两个诉求同时成立**。
                                    Flexible(
                                      fit: FlexFit.loose,
                                      child: Text(
                                        modelName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: c.labelPrimary,
                                        ),
                                      ),
                                    ),
                                    // 推理等级**不在这里**了：2026-10-19 起它是
                                    // 独立的一枚 chip（见左组后面的那一枚）。
                                    const SizedBox(width: 2),
                                    DshIcon(
                                      'chevronDown',
                                      size: 12,
                                      color: c.labelCaption,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // **推理等级 chip**（2026-10-19 从模型名后面分出来，
                      // 用户原话「模型选择，思考程度选择分开」）。
                      //
                      // **有等级才显示**（DSH Web 的 `effortLabel` 条件渲染）。
                      // 图标用 `slidersTwo` 而不是模型那枚 `database`：
                      // 两枚 chip 挨着，同图标会让人以为"一个选择器的两半"。
                      if (reasoningLabel != null)
                        _IconChip(
                          key: const Key('composer-reasoning'),
                          icon: 'slidersTwo',
                          tooltip: '推理等级：$reasoningLabel',
                          onPressed: onPickReasoning,
                        ),
                      // **「忙时发送」图标已移除**（2026-10-19，用户原话
                      // "输入框下的忙时发送行为没必要吧，设置中有，这个也不经常
                      // 更换设置，占位置"）：它是**装完就不动的偏好**，而设置页
                      // 「通用」里一直有同一选择（`settings_page.dart` 的发送模式行）。
                      // 运行时要改也有出路：发送键在 running 且没草稿时是**停止**键，
                      // 有草稿时 tooltip 直接说"排队发送 / 插话发送"——
                      // 当前模式看得见，不必再占一颗 34px 的图标位。
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                // 右侧**只有**发送键（运行中且没草稿时它是**停止**键）。
                _SendButton(
                  key: const Key('composer-primary'),
                  // **停止键不受"空草稿"门限**：它的启用判据是"有没有停止出口"
                  // （照 Web 的 `primaryDisabled = primaryStops ? stop === undefined
                  // : empty || disabled || …`，`InputBar.tsx:325`）——
                  // 否则运行中正想停的时候，那颗键永远是灰的。
                  enabled: stops || canSend,
                  sending: sending,
                  stops: stops,
                  // tooltip 里带当前发送模式（排队 / 插话）：**模式只在设置页改**，
                  // 而行控区那颗图标已移除（2026-10-19，用户原话"设置中有，
                  // 不经常更换，占位置"）。长按/无障碍时用户仍要知道这句话会怎样，
                  // 而 tooltip 是它唯一的出口。
                  tooltip: stops
                      ? '停止'
                      : running
                      ? (sendMode == SendMode.steer ? '插话发送' : '排队发送')
                      : '发送',
                  onPressed: stops ? (onStop ?? onSend) : onSend,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 附件 chip（可删）。
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.item, required this.onRemove});

  final PendingAttachment item;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: c.layer2,
        borderRadius: BorderRadius.circular(DshRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DshIcon(item.icon, size: 13, color: c.labelSecondary),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.labelSecondary),
            ),
          ),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: onRemove,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: DshIcon('closeFill', size: 12, color: c.labelTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 38×38 圆钮（`.ctools > .ib`）。
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final String icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final button = SizedBox(
      width: 38,
      height: 38,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: DshIcon(
              icon,
              size: 18,
              color: onPressed == null ? c.labelTertiary : c.labelSecondary,
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 文字 chip（`.chip`：`min-height:32`、`border-radius:16`）。
///
/// ## 为什么底色用 `Container` 而不是 `Material`
///
/// 2026-10-19 实测（最小复现逐层加）：`Material` 天生把
/// `constraints.maxWidth` 吃满 —— 同一结构套一层 `Material`，chip 宽从
/// **91.3（内容宽）变成 496.0（外层上限）**，且 `Align(widthFactor: 1.0)`
/// 救不回来（它只在该子自己不撑满时有效，而 `Material > InkWell` 链撑满）。
///
/// 后果是"没有推理等级时 chip 应该更窄"这条**完全失效**（用户反馈
/// "模型占那么大"）。所以底色改用 `Container(decoration:)`（按内容宽排），
/// 点击反馈由 `InkWell` 的水波纹改成……没有水波纹了：`InkWell` 必须有
/// `Material` 祖辈，而这里刻意不用 `Material`。
/// **代价是有意的** —— chip 点了立刻开 sheet，反馈是"sheet 出现了"，
/// 而 DSH Web 的 chip 也只有 CSS transition（`ui-model-selection` 的
/// `.trigger` 没有水波纹）。
class _Chip extends StatelessWidget {
  const _Chip({required this.child, this.onPressed});

  final Widget child;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return GestureDetector(
      onTap: onPressed,
      // **这个 `Container` 不带 `constraints`**（2026-10-19 实测）：
      // `BoxConstraints(minHeight: 32)` 的宽度方向是 `0..Infinity`，
      // Container 收到 `0..上层maxWidth` 时自己的宽会取 **maxWidth** ——
      // 最小复现里加一层带 minHeight 的 Container，chip 从 91.3 变 496.0。
      // `min-height: 32` 改由 padding 的纵向值 + 文字行高自然达到
      // （12px 字号 × 1.2 + 上下 padding ≈ 30，接近 32；真要精确就把
      // minHeight 加到**调用方**那层 ConstrainedBox 上 —— 那里已有 maxWidth，
      // 加 minHeight 不影响宽度）。
      child: Container(
        // **不要 `alignment`**（2026-10-19 实测，最后一处）：
        // `Container(alignment: …)` 会让 Container **撑满父宽**再把 child 对准到
        // 边界（探针：同结构加 `alignment` 从 398 变 496）。chip 里的内容
        // 本来就该按内容宽排（`Row(mainAxisSize.min)`），垂直居中由
        // `ConstrainedBox(minHeight)` + Row 的 `crossAxisAlignment` 负责。
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.layer2,
          borderRadius: BorderRadius.circular(16),
        ),
        child: child,
      ),
    );
  }
}

/// 图标 chip（`.chip--icon`：**34px 恒宽**）。
class _IconChip extends StatelessWidget {
  const _IconChip({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.isWarn = false,
  });

  final String icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool isWarn;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final chip = Material(
      // 危险档用告警底（`.chip--icon.is-warn { background: var(--warn-bg) }`）。
      color: isWarn ? c.roleToolBg : c.layer2,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          // 恒宽：长模型名不会把它挤走（硬规则 3）。
          width: 34,
          height: 34,
          child: Center(
            child: DshIcon(
              icon,
              size: 16,
              color: isWarn ? c.roleTool : c.labelSecondary,
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// 发送键（`.send`：38×38、圆、accent 底）。
///
/// [stops] 为真时它是**停止**键（运行中且没有草稿，照 Web 的 `primaryStops`）：
/// 同一颗纽子、同一个位置，图标从纸飞机换成停止方块 —— 用户在当前上下文中
/// 唯一要做的那件事就是它，不另加一颗钮。
class _SendButton extends StatelessWidget {
  const _SendButton({
    super.key,
    required this.enabled,
    required this.sending,
    required this.onPressed,
    this.stops = false,
    this.tooltip,
  });

  final bool enabled;
  final bool sending;

  /// 这一按是"停止"而不是"发送"。
  final bool stops;

  /// 无障碍名（发送 / 排队发送 / 插话发送 / 停止）。
  final String? tooltip;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final button = SizedBox(
      width: 38,
      height: 38,
      child: Material(
        // 停止键用告警底：它是"打断一次正在跑的轮次"，与普通发送区分开。
        color: enabled ? (stops ? c.roleTool : c.accentBlue) : c.layer2,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          child: Center(
            // **发送 ⇄ 停止 ⇄ 转圈 之间淡入 + 缩放**（2026-10-20）。
            //
            // 照 rikkahub 的 `AnimatedVisibility(enter = fadeIn() + scaleIn(),
            // exit = fadeOut() + scaleOut())`
            // （`ui/components/ai/ChatInput.kt:391-402`）—— 用户原话
            // 「它的动画也挺丝滑…可以参考优秀的设计」。
            //
            // 为什么值得动画：这三个形态是**同一个按键的不同含义**，
            // 硬切会读成"按钮被换掉了"（尤其"运行中 → 停止"那一下，
            // 颜色也从蓝变橙）；淡入缩放读成"同一个键换了含义"。
            //
            // **只动图标，不动底色**：`Material` 的底色承载 `InkWell` 的水波，
            // 把它换成 `AnimatedContainer` 会让水波被盖住（水波画在 Material 上、
            // 在 child 下面）。取舍：水波要留着，底色就瞬时切。
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: sending
                  ? SizedBox(
                      key: const ValueKey('sending'),
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: c.onAccent,
                      ),
                    )
                  : DshIcon(
                      stops ? 'stopFill' : 'paperPlane',
                      // key 让 `AnimatedSwitcher` 认出"换形态了"。
                      key: ValueKey(stops ? 'stop' : 'send'),
                      size: 18,
                      color: enabled ? c.onAccent : c.labelTertiary,
                    ),
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 统计条（`.stats`：在输入卡片**下方**）。
///
/// 三项（照 Web 的 composer dock，`ui-conversation/src/client/skeleton/InputBar.tsx:520-525`：
/// `conversation.composer.dock` 槽 = 排队条 + 统计 pill + ContextMeter）：
/// `⏱ N 轮 M 步 · X tok/s` / `🗄 302K tok · 缓存命中 96%` / `◔ 96%`。
/// 每项可点（弹 sheet）。
///
/// ## 布局：**单行 + 横向滚动**（2026-10-17 用户定案）
///
/// 三项的宽度都随数字变：轮次从 1 到十几、token 从 3 位到 4 位、
/// 百分比从 1 位到 3 位。真机（1080×2400 @420dpi = **411.4dp**）实测三项合计
/// **632.6dp**，而可用宽度只有 **391.4dp** —— 差 237dp。
///
/// 走过的两条路都不对：
/// - `Row`（无滚动）：超屏时把末项**整块裁掉**（release 里没有溢出条纹，
///   只是看不见）—— 真机"上下文百分比不显示"就是这么来的；
/// - `Wrap`：放不下就换行，但**哪一项掉到第二行随数字漂**，同一条统计条
///   时高时低，看着像布局坏了。
///
/// 横滚与前者不同：读数**滑得到**，不是被裁掉。代价是"没滑之前看不全"，
/// 这是用户明确接受的取舍。取舍见
/// `.agents/notes/implemented/2026-10-17-topbar-single-row-and-stats-scroll.md`。
class DshStatsBar extends StatelessWidget {
  const DshStatsBar({
    super.key,
    this.turnText,
    this.usageText,
    this.contextPercent,
    this.onTapTurn,
    this.onTapUsage,
    this.onTapContext,
  });

  final String? turnText;
  final String? usageText;

  /// 上下文占用百分比（0~100）；`null` = 不显示。
  final int? contextPercent;

  final VoidCallback? onTapTurn;
  final VoidCallback? onTapUsage;
  final VoidCallback? onTapContext;

  /// 相邻两枚 chip 之间的距离。
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    if (turnText == null && usageText == null && contextPercent == null) {
      // 三项都没有时**整条不显示** —— 空条会白占一行高度。
      return const SizedBox.shrink();
    }
    final chips = <Widget>[
      if (turnText != null)
        _StatChip(icon: 'gauge', text: turnText!, onTap: onTapTurn),
      if (usageText != null)
        _StatChip(icon: 'database', text: usageText!, onTap: onTapUsage),
      if (contextPercent != null)
        _StatChip(
          leading: _ContextRing(percent: contextPercent!),
          text: '$contextPercent%',
          onTap: onTapContext,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
      // `SingleChildScrollView` 的 viewport 撑满可用宽度，于是整条**从左边起**排
      // （`Wrap` 会收缩到内容宽、再被外层 `Column` 居中，一枚 chip 时看着悬在中间）。
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // **点击不受影响**：横滑由滚动的拖动识别器接管，原地按一下仍归 chip 的
        // `InkWell`（手势竞技场按"有没有移动"分派）。`stats_bar_layout_test.dart`
        // 用例真点一次钉住这条。
        child: Row(
          children: [
            for (var i = 0; i < chips.length; i += 1) ...[
              if (i > 0) const SizedBox(width: _gap),
              chips[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// 上下文占用小环（照 Web `ContextMeter.tsx:119-129`：14px 环 + 百分比）。
///
/// 底色是轨道，前景弧长按百分比走 —— 它是"还有多少余量"的一眼线索，
/// 纯文字百分比给不出这个。
class _ContextRing extends StatelessWidget {
  const _ContextRing({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return SizedBox(
      width: 13,
      height: 13,
      child: CustomPaint(
        painter: _RingPainter(
          fraction: (percent.clamp(0, 100)) / 100,
          track: c.layer3,
          fill: c.roleContext,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.fraction,
    required this.track,
    required this.fill,
  });

  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.16;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, 3.141592653589793 * 2, false, trackPaint);
    if (fraction <= 0) return;
    final fillPaint = Paint()
      ..color = fill
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    // 从 12 点方向开始顺时针（照 Web 的 `rotate(-90 7 7)`）。
    canvas.drawArc(
      rect,
      -3.141592653589793 / 2,
      3.141592653589793 * 2 * fraction,
      false,
      fillPaint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.track != track ||
      oldDelegate.fill != fill;
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.text, this.icon, this.leading, this.onTap});

  final String text;

  /// 图标名（走 `DshIcon`）；与 [leading] 二选一。
  final String? icon;

  /// 自绘前导（上下文环）；与 [icon] 二选一。
  final Widget? leading;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final iconName = icon;
    return Material(
      color: c.layer1,
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (iconName != null) ...[
                DshIcon(iconName, size: 12, color: c.labelCaption),
                const SizedBox(width: 4),
              ],
              if (leading != null) ...[leading!, const SizedBox(width: 4)],
              // **不压缩**：横滚容器给的是**无界宽度**，`Flexible` 在这里会直接
              // 抛 `RenderFlex children have non-zero flex but incoming width
              // constraints are unbounded`；而"放不下"这件事已经归滚动管了 ——
              // 单项再长也只是多滑一点，不会被裁掉。
              Text(
                text,
                maxLines: 1,
                // **11px**：这三项的数字都会变宽（四位数 token、三位数
                // 百分比、十几轮），字号大一点就得多滑一下。
                style: TextStyle(fontSize: 11, color: c.labelCaption),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
