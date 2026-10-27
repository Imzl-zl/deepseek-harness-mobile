/// 连接后落到的第一屏 —— DSH Web「新会话页」的 hero。
///
/// ## 它是什么，不是什么
///
/// DSH 的那个首页**不是"没有会话"，是"已有会话但它是 blank"**
/// （`ui-conversation/src/client/skeleton/ConversationMainPanel.tsx:41-43` 的 `hero`
/// 两个来源，实际走后者），组件树装配在
/// `ConversationContent.tsx:163-170` 的 `composerStack`：
///
/// ```text
/// composerStack(.composerHero)
/// ├─ HeroShell                    ← 本文件（鱼 + 标题 + 预览版徽标）
/// ├─ .heroWorkspaceRow            ← 本文件（工作区 chip + 模式 chip）
/// ├─ [slot] conversation.input.dock
/// └─ InputBar(variant='hero')     ← 已经在页面上，本文件不管
/// ```
///
/// **范围只有这一屏**（用户澄清原话："我说的是刚连上的时候的页面,显示的不是 web 所有页面"）：
/// 左/右侧栏、插件页、设置页、内嵌浏览器都仍然只在电脑上。
///
/// ## 与桌面的差异（全部是"触屏重算"，不是随手改）
///
/// | 项 | 桌面（DSH） | 手机 | 为什么 |
/// |---|---|---|---|
/// | 标题 | 26/32 w500（`HeroShell.module.css:41-43`） | **24/32 w500** | 手机排版刻度顶格就是 24/32（`dsh_theme.dart` 的 `titleLarge`）；不为这一屏新造一档字号 |
/// | chip 高 | `min-height:28px`（`:157`） | **44** | 28px 低于可点下限。Flutter 的 `kMinInteractiveDimensionCupertino = 44.0`（`packages/flutter/lib/src/cupertino/constants.dart:29`）、Material 是 48（`material/constants.dart:27`）—— 取 44 是因为这一屏要并排放两枚 |
/// | 卡片宽 | `max-width` 712–952px（`ConversationRoot.module.css:384-389`） | 撑满可用宽 | 手机上照搬那个像素值等于把卡片缩到屏幕一半 |
/// | 鱼 | 宽 34（`EmptyHero.tsx:104-105`） | **34（不变）** | 它是**标记不是文字**，34px 在手机上仍是个小图形（占宽 8%）；缩它会先于标题失真 |
/// | hover 游动 | SMIL 形变（`EmptyHero.tsx:111-121`） | **不做** | 触屏没有 hover（方案里的既定结论） |
///
/// 尺寸与颜色的其余来源：`.stack` gap 12（`:20`）、`.headline` column-gap 10（`:35`）、
/// 标题与徽标 column-gap 7（`:57`）、徽标 padding 1/7 + 圆角 999 + 等宽 12px（`:62-76`）、
/// chip 内 gap 4 与 `padding 0 8px`（`:152-167`）、文件夹 16px 与 chevron 12px
/// （`EmptyHero.tsx:56-59`）、模式 chip 与工作区 chip **同形**
/// （`AgentPresetSeat.module.css:1-2` 的注释："Geometry mirrors HeroShell's .workspace
/// so the two read as one row"）。
///
/// 徽标**没有开关，无条件渲染**（`EmptyHero.tsx:155`）—— 所以这里也不做条件。
///
/// Note: 为什么落到这一屏、为什么写路径是 `session.create({agentPreset})` —— 见
/// `.agents/notes/implemented/2026-10-17-blank-session-hero.md`。
library;

import 'package:flutter/material.dart';

import '../model/workspace.dart' show kWorkspacePlaceholder;
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

/// 标题字号/行高。见文件头的差异表。
const double kHeroTitleSize = 24;
const double kHeroTitleHeight = 32;

/// 鱼标记的宽度（DSH `EmptyHero.tsx:104-105` 的 `width={34}`）。
const double kHeroFishWidth = 34;

/// chip 的高度：可点下限（文件头有出处），不是 DSH 的 28。
const double kHeroChipHeight = 44;

/// 「探索未至之境」+ 预览版徽标（DSH 的 `HeroShell`）。
class HeroHeadline extends StatelessWidget {
  const HeroHeadline({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // `.headline { column-gap: 10px }`（`HeroShell.module.css:35`）。
        DshIcon('fishLogo', size: kHeroFishWidth, color: c.labelPrimary),
        const SizedBox(width: 10),
        Flexible(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题与徽标 `column-gap: 7px`（`:57`）。
              Flexible(
                child: Text(
                  kHeroHeadline,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: kHeroTitleSize,
                    height: kHeroTitleHeight / kHeroTitleSize,
                    fontWeight: FontWeight.w500,
                    color: c.labelPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              const HeroPreviewBadge(),
            ],
          ),
        ),
      ],
    );
  }
}

/// 标题文案（`ui-conversation/src/client/locales.ts:77` 的 `hero.headline`）。
const String kHeroHeadline = '探索未至之境';

/// 「预览版」徽标。
///
/// DSH 用 `corner-shape: round` 做胶囊，Flutter 没有对应物 —— 这个徽标本来就
/// 是**全圆**（`border-radius: 999px`，`HeroShell.module.css:67`），
/// 所以 `StadiumBorder` 逐字等价，不算近似。
class HeroPreviewBadge extends StatelessWidget {
  const HeroPreviewBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      // `.previewBadge { margin-top: 2px }`（`:64`）—— 上标让它骑在标题右上。
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.fromLTRB(7, 1, 7, 1),
      decoration: BoxDecoration(
        color: c.stateBusinessTertiary,
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.hover, width: 0.5),
      ),
      child: Text(
        // `locales.ts:78` 的 `hero.preview`，**无条件渲染**（`EmptyHero.tsx:155`）。
        '预览版',
        style: TextStyle(
          // `font-family: var(--ds-font-family-code)`（`:71`）—— 等宽是刻意的。
          fontFamily: 'SF Mono',
          fontFamilyFallback: dshMonoFallback,
          fontSize: 12,
          height: 18 / 12,
          fontWeight: FontWeight.w500,
          color: c.labelPrimaryBluish,
        ),
      ),
    );
  }
}

/// hero 上的一枚 chip（工作区 / 模式）。
///
/// 两者**同形**（`AgentPresetSeat.module.css:1-2`），差别只有图标与文案 ——
/// 所以是一个控件，不是两个长得像的控件。
class HeroChip extends StatelessWidget {
  const HeroChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
  });

  /// 左图标：工作区是 `folderClose`/`folderOpen`（`EmptyHero.tsx:55-57`），
  /// 模式是 `agentPreset`（`AgentPresetSeat.tsx:199` 的 `IconAgentPresetOutlineRegular`）。
  final String icon;

  /// 文案。**`null` = 占位态**（DSH 的 `label === undefined` 走
  /// `hero.chooseWorkspace`「选择工作区」，`EmptyHero.tsx:55-58`）。
  final String? label;

  final VoidCallback onTap;

  /// 长按/无障碍用的完整说明（DSH 用 `title` 装描述，`:50`/`:195`）。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final text = label ?? kWorkspacePlaceholder;
    return Tooltip(
      message: tooltip ?? text,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshRadius.sm),
        child: Container(
          // DSH 的 28px 换成可点下限，见文件头的差异表。
          height: kHeroChipHeight,
          // `padding: 0 8px`（`HeroShell.module.css:158`）。
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DshIcon(icon, size: 16, color: c.labelPrimary),
              // `gap: 4px`（`:155`）。
              const SizedBox(width: 4),
              // 长名字省略，不许把 chevron 顶出去（`:185-190` 的 ellipsis）。
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 20 / 13,
                    fontWeight: FontWeight.w500,
                    color: c.labelPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              DshIcon('chevronDown', size: 12, color: c.labelCaption),
            ],
          ),
        ),
      ),
    );
  }
}

/// hero 整块：标题 + 一行两枚 chip。
///
/// **不含输入框** —— 那是页面上已有的 `DshComposer`（DSH 那边同样是
/// `InputBar` 而不是 HeroShell 的一部分，`EmptyHero.tsx:158-160` 的注释：
/// "The composer remains mounted outside this component"）。
///
/// ## 为什么居中，而不是贴底
///
/// 2026-10-19 之前这里写的是 `mainAxisAlignment: MainAxisAlignment.end`
/// （贴输入栏那一端），真机截图里 hero 挤在屏幕最底下、上面一大片空白 ——
/// 用户原话"首页显示在最下面你觉得合乎常理好看吗"。
/// DSH 的判据在 `ConversationRoot.module.css:503-518`：
///
/// ```css
/// /* Hero phase: the composer stack (hero chrome + workspace row + card) is
///    flex-centered in the column; composer phase docks it at the bottom. */
/// .composerHero { align-self: center; padding-bottom: 32px; }
/// ```
///
/// 即 **hero 阶段居中（脚注让整叠略高于真中心），composer 阶段才贴底**。
/// 手机照抄这一条：`MainAxisAlignment.center` + 底部 32。
/// 输入栏本身仍在屏幕最下方（它是另一个控件），不受这一处影响。
class ConversationHero extends StatelessWidget {
  const ConversationHero({
    super.key,
    required this.workspaceLabel,
    required this.presetLabel,
    required this.onPickWorkspace,
    required this.onPickPreset,
    this.workspaceTooltip,
    this.presetTooltip,
  });

  /// 工作区 chip 的文案；`null` = 占位态（清单到了但没有归属，或还没有工作区）。
  final String? workspaceLabel;

  /// 模式 chip 的文案；`null` = 拿不到预设目录（那时也点不开）。
  final String? presetLabel;

  final VoidCallback onPickWorkspace;
  final VoidCallback onPickPreset;

  final String? workspaceTooltip;
  final String? presetTooltip;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // DSH 的 `.composerHero { padding-bottom: 32px }` —— 注释原话
      // "Foot inside the centered box floats the stack a bit above true center"。
      // 手机上同一个量：整叠停在弹性区里、略高于中心。
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        // **居中**（DSH hero 阶段的 `align-self: center`），不是贴底 ——
        // 见类文档里的 CSS 出处与真机截图。
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HeroHeadline(),
          // 标题与 chip 行之间 12（`.stack { gap: 12px }`，`HeroShell.module.css:20`）。
          const SizedBox(height: 12),
          // `.workspaceRow { padding-left: 8px }`（`:145`）—— 桌面是与卡片左缘对齐，
          // 手机照同一个内缩量，两枚 chip 于是与输入卡片的左内边对齐。
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              children: [
                Flexible(
                  child: HeroChip(
                    // 有名字才是"开着"的文件夹（`EmptyHero.tsx:55-57`）。
                    icon: workspaceLabel == null ? 'folderClose' : 'folderOpen',
                    label: workspaceLabel,
                    tooltip: workspaceTooltip,
                    onTap: onPickWorkspace,
                  ),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: HeroChip(
                    icon: 'agentPreset',
                    label: presetLabel,
                    tooltip: presetTooltip,
                    onTap: onPickPreset,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
