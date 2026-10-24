/// 斜杠命令：一次发送落在哪条方法上，以及命令应答的形状。
///
/// ## 分流只有一处
///
/// 输入栏按下发送时只问一个问题（[sendRouteOf]）：这条文本是命令、是子会话的
/// 消息，还是普通消息？三个落点各一条方法 —— **判断写两遍，就一定会有一条路走错**。
/// `chat_page.dart` 的 `_send()` 因此只调这一个函数，不再自己拼判据。
///
/// ## 为什么子会话没有命令面
///
/// 子会话唯一的写入口是 `subagent.prompt`（宿主对子会话的 `session.prompt` 回
/// `internal: session "…" is owned by subagent routing`，2026-10-21 真机实测），
/// 而 `commands.execute` 要一个**活的 root agent**（`interaction/commands/src/index.ts:361-366`：
/// 它要 `agent.session` 落生命周期事件、要 agent 的 scope 合并命令层）。
/// 所以命令面与 `session.prompt` 是同一侧 —— 子会话那一侧没有它，
/// 子会话里的 `/…` 照旧是一条普通消息。
///
/// ## `matched:false` 按 Web 走
///
/// DSH 的 `execute` 在**语法或名字没解析出来**时回 `undefined`
/// （`interaction/commands/src/index.ts:367-370`，且不落日志），Web 的输入流水线把这种行
/// **退成普通消息**（`ui-conversation/src/client/input/machine.ts:170-175` 的
/// `onAdjudicated`：`outcome === undefined` ⇒ `default-sink`）。手机没有命令目录，
/// 所以"电脑不认识这条命令"这条唯一信号也落到同一个动作上：照普通消息发出去，并说一句。
///
/// **这不是静默降级**：宿主认识时命令会真的跑（`matched:true`，结果落在命令卡上），
/// 只有它不认识时才回退 —— 而那种行在 Web 上本来也是一条消息。
///
/// 取舍（为什么白名单在电脑侧、为什么子会话没有命令面、`matched:false` 为什么回落）
/// 见 `.agents/notes/implemented/2026-10-23-slash-command-execution-surface.md`。
library;

/// 一次发送的落点（每条对应一个方法名，见 `chat_page.dart` 的 `_send()`）。
enum SendRoute {
  /// 普通消息 → `session.prompt`。
  prompt,

  /// 子会话的消息 → `subagent.prompt`（宿主只认这条路）。
  subagentPrompt,

  /// 斜杠命令 → `command.execute`（连接器按白名单放行，契约 §5.7）。
  command,
}

/// 这条文本该走哪条路。
///
/// **`isSubagent` 优先于一切**：子会话里没有命令面（见文件头），所以
/// `/goal …` 在子会话里就是一条普通消息。
///
/// 判据是"以 `/` 开头"，**与 Web 输入状态机的判据逐字一致**
/// （`machine.ts:144-149`：`draft.trim()` 后 `startsWith('/')` 进 `adjudicating`）。
/// 自己再写一个更窄的（比如先切出命令名再比白名单）就是第二份语法 ——
/// 白名单在电脑侧（`connector/src/handlers.ts` 的 `MOBILE_COMMANDS`），手机不抄。
///
/// 文本在这里再 `trim` 一次：调用方给的是草稿快照，而 Web 的判据也是先 trim
/// （`machine.ts:144`）。两边同一个口径，才不会出现"手机上多发一个空格就换了方法"。
SendRoute sendRouteOf({required String text, required bool isSubagent}) {
  if (isSubagent) return SendRoute.subagentPrompt;
  return text.trim().startsWith('/') ? SendRoute.command : SendRoute.prompt;
}

/// 候选菜单里 `/` 那一组的分组标题。
///
/// 宿主 zh 词典的原话（`ui-input-trigger/src/client/locales.ts` 的 `'command'`）——
/// 不另起一个中文（"命令"/"指令"两种说法并存就是两处真值）。
const String kSectionCommands = '指令';

/// 候选菜单里的一条命令（`repo.info.commands`）。
///
/// **说明来自宿主的命令定义**（`CommandDefinition.description`，
/// `interaction/commands/src/index.ts:79`）—— 连接器从 `ctx.commands` 读，手机不抄：
/// 抄一份文案，DSH 改词时我们这边永远看不到。
///
/// 说明**可以为空**：老连接器只发名字数组（`['goal','plan']`），新连接器才带说明。
/// 两种形状手机都收（见 [parseSlashCommands]），空的就只画名字那一列 —— 不是画一个
/// 空说明占位。
class SlashCommand {
  const SlashCommand({required this.name, this.description});

  /// 命令名（**不带**前导 `/`，宿主的 `CommandDefinition.name` 同形）。
  final String name;

  /// 宿主定义里的那句话；`null` = 这台电脑没给。
  final String? description;
}

/// 解 `repo.info.commands`，**两种形状都收**。
///
/// - 新连接器：`[{name, description?}, …]`；
/// - 老连接器：`['goal', 'plan']`（只有名字）。
///
/// 两种都收是**兼容**，不是两个真值：名单本身永远来自电脑侧（白名单只有一处，
/// `connector/src/handlers.ts` 的 `MOBILE_COMMANDS`），手机只决定"这一行画不画说明"。
/// 认不出的条目**跳过**（不是编一个名字）：一条画不对的命令点下去会跑错东西。
List<SlashCommand> parseSlashCommands(Object? raw) {
  if (raw is! List) return const <SlashCommand>[];
  final rows = <SlashCommand>[];
  for (final entry in raw) {
    if (entry is String) {
      final name = _commandName(entry);
      if (name != null) rows.add(SlashCommand(name: name));
      continue;
    }
    if (entry is Map) {
      final name = _commandName(entry['name']);
      if (name == null) continue;
      final description = entry['description'];
      rows.add(
        SlashCommand(
          name: name,
          description: description is String && description.isNotEmpty
              ? description
              : null,
        ),
      );
    }
  }
  return rows;
}

/// 去掉前导 `/`（宿主的名单自己不带，但连接器是"原样过线"，
/// 两种写法都会出现在线上）。空串 ⇒ `null`。
String? _commandName(Object? raw) {
  if (raw is! String) return null;
  final name = raw.startsWith('/') ? raw.substring(1) : raw;
  return name.isEmpty ? null : name;
}

/// 一条命令的结论（连接器 `command.execute` / `permission.switch` 的应答）。
///
/// 两个方法**同一个形状**：都是 `commands.execute` 的结算
/// （`{commandId, result}` 原样过线，`interaction/commands/src/types.ts:49-54`），
/// 所以解析只有这一处 —— 抄第二份就会有一边先漂。
class CommandOutcome {
  const CommandOutcome({required this.matched, this.kind, this.text});

  /// 电脑侧有没有这条命令。
  ///
  /// `false` 的语义是 DSH 的 `commands.execute` 回 `undefined`
  /// （`interaction/commands/src/index.ts:367-370`：语法或名字没解析出来）——
  /// 与 Web 客户端的推导逐字一致
  /// （`session-controller/src/client/sessions/session.ts:390`）。
  /// 它与 `{kind:'error'}` 是两件事：后者是命令在、但参数不对。
  final bool matched;

  /// DSH 的 `result.kind`：`success` / `error`。
  final String? kind;

  /// DSH 的 `result.text`。**原文照显，不翻译** ——
  /// `unknown preset "yolo" (available: …)` 这种话是电脑侧权威的措辞，
  /// 自己抄一份就会在 DSH 改词时静默分叉。
  final String? text;

  /// 电脑侧真的跑成功了（命令在、且 DSH 回 success）。
  bool get succeeded => matched && kind == 'success';
}

/// 解 `{matched, execution?}`。
///
/// **认不出返回 `null`**（调用方按失败留声），不猜一个"成功"。
CommandOutcome? parseCommandOutcome(Object? raw) {
  if (raw is! Map) return null;
  final matched = raw['matched'];
  if (matched is! bool) return null;
  final execution = raw['execution'];
  if (!matched) return const CommandOutcome(matched: false);
  if (execution is! Map) return null;
  final result = execution['result'];
  if (result is! Map) return null;
  final kind = result['kind'];
  final text = result['text'];
  return CommandOutcome(
    matched: true,
    kind: kind is String ? kind : null,
    text: text is String && text.isNotEmpty ? text : null,
  );
}
