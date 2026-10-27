/// 幂等键的唯一生成处。
///
/// ## 为什么要有这个文件
///
/// 全仓原本有 **16 处**手写 `'x-${DateTime.now().microsecondsSinceEpoch}'`。
/// 这个形状有两个坑：
///
/// 1. **同一微秒里可能撞**：两次紧挨着的写（比如连续点两次）拿到同一个键时，
///    宿主按 `rpcId` 去重（`packages/api/session-controller/src/commands.ts:602-614`）——
///    第二次写会被当成重发**静默丢掉**，用户看到的是"点了没反应"。
/// 2. **前缀是散落的字符串**：去重表与服务端日志靠前缀认来源，拼错没有编译期检查。
///
/// 所以这里做两件事：前缀仍由调用方给（每个动作一个），**唯一性由计数器保证**。
///
/// Note: 取舍见 `.agents/notes/proposed/2026-10-27-ui-state-design.md` §6.B3。
library;

/// 进程内的单调计数器（只保证"同一进程内不撞"）。
int _seq = 0;

/// 生成一个幂等键：`<prefix>-<微秒>-<序号>`。
///
/// 序号跟在时间后面而不是取代它：时间戳让排错时能看出"什么时候发的"，
/// 序号保证同一微秒里的两次调用也不同。
String newRequestId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_seq++}';
