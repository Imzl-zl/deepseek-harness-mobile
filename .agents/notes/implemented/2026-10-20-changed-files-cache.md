perf(app): changedFiles 每次 build 扫 3 遍全表 → 按条目同一性缓存

## 缺陷（我上一批引入的）

`AppModel.changedFiles` 要**扫全部条目**，而它**每次 build 都会被问**：

- `_sideHeader()`（`chat_page.dart:546`）里问了**两次**（`.isEmpty` 与 `.length`）
- `_fileBody()`（`:550`）又问了**一次**

⇒ 每次 build 三次全表扫描。八千条事件的会话里，流式输出期间每秒几十帧，
就是每秒几十万次无效判断。

## 修法

1. **`AppModel` 里缓存**，失效判据用**列表同一性**：
   `SessionStore` 每次归并都换成新的 `List.unmodifiable`
   （`session_store.dart:118`），所以 `identical` 为假等于"条目真的变了"。
   **故意不加 `revision` 计数** —— 那会多一个可能与真实状态漂移的真值，
   而列表同一性没有漂移的余地。
   结果用 `List.unmodifiable` 包起来：它是拿去渲染的，谁也别想改。
2. `_sideHeader()` 改成**只取一次**（`_fileHeader(changed)`）：缓存虽是 O(1)
   命中，但在热路径上让成本取决于"缓存命中没有"没有意义。
3. 顺手删掉一段早已过时的注释（它还写着"等文件面板接上真的 deliverables 再从
   数据里取标题与统计"，而下一句已经说"表头由真的改动数据决定" —— 自相矛盾）。

## 验证

- `widget_test.dart` 新增一条：两次取 `changedFiles` **是同一个实例**
  （`identical` 为真），内容正确，且 `clear()` 抛 `UnsupportedError`。
- **一处变异验证**：去掉缓存短路 → 该条红。
- `flutter test 883` 全绿；真机行为不变（面板内容、复制路径都没动）。
