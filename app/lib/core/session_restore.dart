/// 冷启动时把**本地库里的水位**装回连接层（契约 §5.7 的 `since` / §8.3 的本地库）。
///
/// ## 它解决什么
///
/// 冷启动时内存里什么都没有，所以打开会话必然整窗重放（真机实测 `ev` 147 KB）。
/// 而手机其实**手里有内容**：`items` 表存着上次落下去的条目，`cursors` 表存着水位 ——
/// 只是这条链一直**只写不读**（`itemsOf` / `allCursors` 零调用方）。
/// 接上之后：读回条目 → 界面立刻有内容 → `since` 取条目自己的 `seq` 上界
/// → 电脑侧只补之后的。
///
/// ## 三条一致性判据（缺一条就会"显示的东西不真"）
///
/// 1. **水位取内容的上界，不取计数器**：`cursors.last_seq` 在"事件因空洞没入库、
///    却照样落了盘"时可能超前于条目 —— 拿它当 `since` 就是声称"我有到 N"而界面没有。
///    所以 `since = max(读回条目的 seq)`，读不到条目就**根本不调这里**（保持 0）。
/// 2. **条目不会重复也不会串行**：条目身份是 DSH 的 `itemId`（§5.2），
///    电脑侧重放同一段时按 `itemId` upsert ⇒ 不会出现两份；重放的是**别的历史**
///    （会话日志被改写）时，那些旧条目会与新窗口并存 —— 这是"不完整"，不是"不真"，
///    处理方式写在 `docs/subsystems/remote-channel.md` §5.4 规则 5。
/// 3. **本地条目属于一台电脑**：`sid` 是电脑侧分配的不透明别名，换一台电脑可能撞名。
///    所以盘上的键带电脑前缀（`<hostId>/<sid>`），由装配点套的作用域决定（`data/host_scope.dart`
///    与 `data/scoped_store.dart`）—— 这一层拿到的 `sid` 已经是**本机**的短名，
///    它不需要知道作用域存在。
///
/// ## 为什么不塞进 `SyncClient`
///
/// 同 `snapshot_call.dart`：那个端口有几十个测试替身 `implements`，
/// 加只有真实现才有意义的成员会让它们全都编不过。
library;

import 'sync_client.dart';

/// 能把本地库的水位装回连接层的口（真实现与 `FakeSyncClient` 有）。
abstract interface class SessionRestorer {
  /// 本地库里的条目已经回到界面，连接层据此把水位置成 [since]。
  void restoreSessionFromStore(String sid, {required int since});
}

/// `SyncClient` 上的恢复口（调用方只认这个扩展）。
extension SessionRestore on SyncClient {
  /// 冷启动：本地库里的条目已经回到界面，把水位装回连接层。
  ///
  /// **只在真读到条目之后调**（见文件头判据 1）；`since` 必须取那些条目的 `seq` 上界。
  void restoreSession(String sid, {required int since}) {
    final client = this;
    if (client is SessionRestorer) {
      (client as SessionRestorer).restoreSessionFromStore(sid, since: since);
    }
  }
}
