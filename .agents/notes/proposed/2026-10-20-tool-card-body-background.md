# Agent Note: 工具卡展开后正文掉出卡片底色 —— 待核 DSH 再定

Status: proposed（**只记录现象与缺的证据，未改动代码**）

## 现象

真机（2026-10-20，`（示例）图标为什么不用字体` 会话，`write` 卡）：
点开工具卡后，**标题行有暖色底（`c.roleToolBg`），正文落在页面白底上**，
视觉上像"正文从卡片里掉出来了"。

代码结构（`app/lib/ui/chat_turns.dart:311-320`）：

```dart
Column(children: [
  Material(color: c.roleToolBg, child: InkWell(... 标题行 ...)),
  ...  // 正文是 Material 的**兄弟节点**，不在底色之内
])
```

也就是说这是**当前实现的选择**，不是渲染事故。

## 缺的证据（**已查到，2026-10-20**）

DSH 的 `packages/client/ui-tool/src/client/tool/components/ToolDetails.module.css`
的 `.root` 就是展开后的正文容器：

```css
.root {
  margin: 4px 0 4px 4px;
  border: 0.5px solid var(--dsw-alias-border-l1);
  border-radius: var(--dsw-radius-lg);
  background: var(--dsw-alias-markdown-code-block);
  color: var(--dsw-alias-label-secondary);
  font: var(--dsw-font-xs-13);
  overflow: hidden;
}
```

**结论**：正文在 DSH 里是**独立的一块**（自带边框 + 圆角 + 代码块底色 +
左/上下各 4px 内缩），**不在**工具行那层暖色底内 —— 所以我们现在
"正文是 `Material` 的兄弟节点"这个**方向是对的**，缺的是**这块容器本身**：
我们把它赤裸地放在页面底色上。

## 要补的（下次照这个改，不要重新查）

`chat_turns.dart` 的 `ToolCard` 正文外面包一层：

| 属性 | 值 | 出处 |
|---|---|---|
| `margin` | `EdgeInsets.fromLTRB(4, 4, 0, 4)` | 上面 `.root` 的 `4px 0 4px 4px` |
| `border` | `Border.all(c.borderL1, width: 0.5)` | `--dsw-alias-border-l1`（**本仓还没有这个 token，要加**） |
| `borderRadius` | `DshRadius.lg` | `--dsw-radius-lg` |
| `color` | 代码块底色 | `--dsw-alias-markdown-code-block`（**本仓也没有，要加**） |
| `font` | `--dsw-font-xs-13`（13px 小字） | 同上 |

两个新 token 的值要照 `design-platform.css` 查（`border-l1` 与
`markdown-code-block` 各有明暗两份），**不许估**。

## 为什么这次仍然没改

查到了证据，但**改它要加两个 token + 改一个 widget + 跑门禁**，
而本轮上下文已在末尾 —— 在最后几步动三层结构、跑不完构建，
留下的就是红树。**下一步开头就能做完**，清单已在上表。

## 判据（定了之后怎么验）

- 若判定要改：改完后 `write` 卡展开时正文应在**同一块底色**内，
  且 `composer_layout_test` / `widget_test` 全绿（它们不量视觉，
  所以真机截图才是判据）。
- 若判定不改：把这条结论写进 `docs/design-and-tech-plan.md` 的工具卡小节，
  免得下次又有人来查一遍。
