/// 从一次 `tool/call` 推导"这次调用改的是哪个文件"。
///
/// ## 出处（不是我们发明的规则）
///
/// DSH 的 `ui-deliverables/src/client/turn-deliverables.ts:61-77` 的
/// `mutationPath(name, argsRaw)`。它的文件头注释写清了这条数据的性质：
/// > model-free: produced paths come from successful first-party mutation calls
/// > and their recorded file targets
///
/// 也就是说**不需要模型参与** —— 扫工具调用就能得到"这一轮改了哪些文件"。
/// 这正是手机端能自己算出来的那部分（右侧「文件」面板要显示它）。
///
/// ## 只认三个工具（与 DSH 同一份名单）
///
/// `write` / `edit` / `str_replace_editor`，判据是**参数形状**，不是"工具名像
/// 改文件的"。DSH 也强调：Session 的 `tool/call` 是 root call，
/// PTC 派发的子调用不单独进这份定义。
///
/// ## 为什么在投影时算，而不是把 `arguments` 留在条目上
///
/// `write` 的 `arguments` 里**是整个文件内容**。把它挂到 `ToolCallItem` 上等于
/// 把会话里每个写过的文件再存一份（内存翻倍）。这里只抽出一个路径字符串。
library;

import 'dart:convert';

/// 从工具名 + 原始参数 JSON 得出被改的路径；不是变更类调用就给 `null`。
///
/// **纯函数**：单测直接喂 DSH 那几种参数形状。
String? changedPathOf({required String name, required String argumentsJson}) {
  final Object? parsed;
  try {
    parsed = jsonDecode(argumentsJson);
  } on FormatException {
    // 模型给的参数不是合法 JSON：DSH 同样直接返回 null
    //（`turn-deliverables.ts:64-67` 的 try/catch）。
    return null;
  }
  if (parsed is! Map) return null;
  switch (name) {
    case 'write':
      // `return typeof args.content === 'string' ? pathValue(args.file_path) : null`
      return parsed['content'] is String
          ? _pathValue(parsed['file_path'])
          : null;
    case 'edit':
      return _validEditArgs(parsed) ? _pathValue(parsed['file_path']) : null;
    case 'str_replace_editor':
      return _editorMutationPath(parsed);
    default:
      return null;
  }
}

/// `validEditArgs`（`turn-deliverables.ts:150-158`）。
///
/// 五个条件全中才算一次真改动 —— 尤其 `old_string != new_string`：
/// 相同的替换是**不产生改动**的调用，算进去会让面板凭空多一行。
bool _validEditArgs(Map<Object?, Object?> args) {
  final oldString = args['old_string'];
  final newString = args['new_string'];
  final replaceAll = args['replace_all'];
  return oldString is String &&
      oldString.isNotEmpty &&
      newString is String &&
      oldString != newString &&
      (replaceAll == null || replaceAll is bool);
}

/// `editorMutationPath`（`turn-deliverables.ts:90-112`）：按 `command` 分三种，
/// 每种都要它自己的必填参数齐全才算改动。
String? _editorMutationPath(Map<Object?, Object?> args) {
  final path = _pathValue(args['path']);
  if (path == null) return null;
  switch (args['command']) {
    case 'create':
      return args['file_text'] is String ? path : null;
    case 'str_replace':
      final oldStr = args['old_str'];
      final newStr = args['new_str'];
      return oldStr is String &&
              oldStr.isNotEmpty &&
              (newStr == null || newStr is String)
          ? path
          : null;
    case 'insert':
      final insertLine = args['insert_line'];
      return insertLine is int && insertLine >= 0 && args['new_str'] is String
          ? path
          : null;
    default:
      return null;
  }
}

/// `pathValue`（`turn-deliverables.ts:115-117`）：非空白字符串，**原样返回**
/// （不规范化大小写或分隔符 —— 面板显示的就是模型当时给的那个路径）。
String? _pathValue(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;
