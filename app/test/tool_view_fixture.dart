/// 测试里造"工具专用视图"的**唯一入口**：meta 与正文都走生产的那份解码。
///
/// `model/tool_view.dart` 现在收 `ToolResultMeta`（解好的值），而夹具要保持**原始协议
/// JSON**（`data.meta` / `data.message.content`）—— 所以这里把两条解码接上：
/// `meta` 走 `WireEventFields.toolMeta`，正文走同一个端口解出的消息块 + `textOfContent`。
/// 于是测试仍然跑在解码器上，`tool_views_test.dart` 的调用点一个字符没改
/// （与 `projection_fixture.dart` 的转发版同一手法）。
library;

import 'package:dsh_mobile/data/projection.dart' show textOfContent;
import 'package:dsh_mobile/model/tool_view.dart'
    as views
    show ToolResultView, toolResultViewOf;
import 'package:dsh_mobile/wire/event_fields.dart' show WireEventFields;

/// 同 `model/tool_view.dart` 的 `toolResultViewOf`，但直接收**原始结果载荷**。
views.ToolResultView? toolResultViewOf({
  required String name,
  required Object? data,
}) {
  const fields = WireEventFields();
  return views.toolResultViewOf(
    name: name,
    meta: fields.toolMeta(data),
    text: textOfContent(fields.message('tool/result', data).blocks),
  );
}
