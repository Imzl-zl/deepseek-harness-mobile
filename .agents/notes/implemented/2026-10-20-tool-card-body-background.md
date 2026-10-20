# Agent Note: 工具卡展开后的正文包成独立容器（照 DSH `ToolDetails.root`）

Status: implemented（2026-10-20 落地，真机截图确认）

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

两个新 token 的值已查好（`design-platform.css`，**照抄，不许估**）：

| token | 亮色 | 暗色 |
|---|---|---|
| `borderL1`（`--dsw-alias-border-l1`） | `rgba(0,0,0,0.04)` = `0x0A000000`（`:185`） | `rgba(255,255,255,0.06)` = `0x0FFFFFFF`（`:303`） |
| `codeBlock`（`--dsw-alias-markdown-code-block`） | `neutral-bluish-50` = `rgb(249,250,251)` = `0xFFF9FAFB`（`:230` → `:64`） | `neutral-bluish-900` = `rgb(27,27,28)` = `0xFF1B1B1C`（`:348` → `:73`） |

⚠️ 注意 `borderL1` 比 `borderL2`（0.12/0.10）**更淡** —— 它是"最细一档"，
别拿 `borderL2` 顶替，那样边框明显重了。

## 为什么这次仍然没改

查到了证据，但**改它要加两个 token + 改一个 widget + 跑门禁**，
而本轮上下文已在末尾 —— 在最后几步动三层结构、跑不完构建，
留下的就是红树。**下一步开头就能做完**，清单已在上表。

## 落地结果（2026-10-20 当日完成）

照上表改完，真机截图确认：正文成了**独立的圆角块**
（代码块底色 + 0.5px 发丝边框 + 左缩 4px + radius-lg），不再掉出卡片。

同时更正一处**引错出处**的注释：原注释引 `.tool-body { … }`，而
`.tool-body` 这个类**在 DSH 里不存在**（全仓 grep 为零）—— 照一个不存在的类
写实现，就成了"每处都看着有出处、合起来却是另一样东西"，这比没有注释更危险
（它让人停止怀疑）。现在引的是真实存在的
`ui-tool/src/client/tool/components/ToolDetails.module.css` 的 `.root`。

## 剩余风险（如实记）

**深色主题没有眼验**。判据与理由：
- 两个 token 的暗色值取自 `design-platform.css:303`（`border-l1`）与 `:348`
  →`:73`（`markdown-code-block` = `neutral-bluish-900`），是**权威的**；
- 这一对组合本来就是 DSH 自己在暗色下的搭配，所以"暗色下好不好看"
  等价于"DSH 暗色下好不好看"，不需要我们重新判断；
- 几何（margin/radius/border 宽度）与主题无关。

真要眼验时的操作：设置 → 主题 → 深色，然后回到会话点开任意工具卡。

## 判据（定了之后怎么验）

- 若判定要改：改完后 `write` 卡展开时正文应在**同一块底色**内，
  且 `composer_layout_test` / `widget_test` 全绿（它们不量视觉，
  所以真机截图才是判据）。
- 若判定不改：把这条结论写进 `docs/design-and-tech-plan.md` 的工具卡小节，
  免得下次又有人来查一遍。
