# App 多电脑：添加不拆当前、切换先连新再拆旧（0.2.9）

- 日期：2026-11-05
- 触发：用户要求的真实问题——手机上加另一台电脑时当前电脑会断；切换时出现"两边都断"的窗口。
  用户明确：**轮流看可以**（不要求双在线），但"链接那台时不要把这台弄断"。
- 状态：implemented（app 0.2.9+4，基于我们自己的 `review-fixes-20261104` 分支）

## 问题（改之前）

- 「添加电脑」→ `_addHost` → `_enterPairing('')` → `_reassembleUnpaired()`：
  一进配对页就把当前 `AppModel` dispose 掉，**当前那台立刻掉线**；取消也回不来。
- `_switchTo`/`_onPaired`：先 `_app?.dispose()` 再 `app.start()` ——
  新旧之间有一个"两边都没连"的窗口，且失败时旧那台已经被拆了。

## Decision

1. **添加不拆当前**：`_addHost` 只置 `_addingHost = true` 并打开配对页，不调用
   `_reassembleUnpaired`；取消只关页面，当前连接原样在线（并 toast 告知）。
2. **切换/配对成功：先连新、再拆旧**：把 `previousApp?.dispose()` 移到
   `await app.start()` 之后；`_switchTo` 失败时把旧 `AppModel` 与凭据槽 `active`
   装回去，留在原来那台并说明原因。
3. 添加成功给一句"可在「切换电脑」里来回切"；取消给一句"当前电脑保持连接"。

## 边界（用户已确认）

- **不做双在线**：切换完成后旧那台仍会断开（用户选择"轮流看"）。
- 双在线需要按 host 池化 `AppModel`/`SyncClient`（core 层改造），本版不做。

## 验证

- `flutter analyze --no-pub`：No issues；
- 构建：`flutter build apk --release --target-platform android-arm64`（debug keystore，
  与手机现有包同证书，可覆盖安装）；
- 真机验收（待装）：A 连接中 → 添加 B（配对新电脑）→ A 在配对期间保持在线；
  取消 → A 仍在；配好 B → 切 B（先连后拆）；切回 A 不需要重扫。
