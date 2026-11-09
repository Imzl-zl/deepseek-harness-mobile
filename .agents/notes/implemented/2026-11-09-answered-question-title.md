# Agent Note: 已回答的问答在聊天流里叫「问答 · 已回答」，不显示工具名

Status: implemented

## Problem

一次 `ask_user_question` 答完之后，那条 `ToolCallItem` 会一直留在会话流里，标题是工具名
`ask_user_question`。用户看到的是一个函数名：既看不出"这里发生过一次问答"，也看不出
"已经答过了"。接管卡上那句「已回答 · <选项>」是答完就撤的瞬时回执
（`ui/takeover.dart:559`），历史里没有任何标记。

## Decision

聊天流里，**已完成**的 `ask_user_question` 卡片标题显示「问答 · 已回答」；其余工具、
以及运行中 / 失败的问答，标题照旧是工具名。

准入门槛（可机械判定）：

1. 判据只有一处：`name == askUserQuestionTool && status == ToolCallStatus.completed`，只作用在聊天流的卡片标题上（`ui/chat_page.dart` 的 `_TurnView`）。
2. 接管卡那句「已回答 · <选项>」不动：`takeover_test.dart` 仍按原样断言。
3. 测试用 `projectEvent`（`test/projection_fixture.dart`，身份按生产规则算）造出**已回答**的条目，断言标题文案出现、工具名消失；另有 `bash` 反面对照证明规则不外溢。

## Alternatives considered

1. 在投影里把 `ToolCallItem.name` 改成「已回答」
   - 最强的理由：所有消费者一处生效，UI 不用记这条规则。
   - 为何被否：`name` 是数据，不是文案 —— `AppModel` 的提问判据就按 `item.name == 'ask_user_question'` 认（`data/app_model.dart:3199`），改它等于把展示文案塞进数据层，并顺手拆掉那个判据。
2. 保留工具名，另加一个"已回答"徽标
   - 最强的理由：信息更全 —— 既知道用的是哪个工具，也知道答过了。
   - 为何被否：这一行的标题位就是工具名，右边是参数摘要，宽度预算已经按"名字最多 55%"分配（`_ToolCardState.build`）；再塞一个徽标要么挤掉摘要，要么让长 MCP 名更早变成省略号。而"问答"本来就是工具名的语义。
3. 运行中也换标题（「问答 · 待回答」）
   - 最强的理由：状态更完整，历史里三种状态一眼可辨。
   - 为何被否：运行中的提问由接管卡负责（输入栏上方），聊天流里那一条还没有答案 —— 标"已回答"是错的，标"待回答"则是把接管卡的话再说一遍。

## Consequences

- 收益：历史里一眼看出"这是一次问答、而且答过了"；工具函数名不再直接暴露给用户。
- 代价：想按工具名找这一条（复制/搜索）时找不到 `ask_user_question` —— 目前没有按标题搜索的功能，若将来加，得记得这条标题被改写过。
- 代价：文案是硬编码中文；将来做多语言时要把它抽出去（`ToolCard` 不知道"问答"这回事）。
- 代价：判据钉在 `ToolCallStatus.completed` 上。若将来出现"已回答但工具报错"的形态，这条不会生效 —— 那时应当显式加一条判据，而不是把 `completed` 放宽成"不算 running"。

## 来源

语义来自 @williamking-art 的 #8 `8e2c94a`（"P1-3 已回答问答在聊天流标记为「问答 · 已回答」"）。
按当时 main 的结构重写（`_TurnView` + `projection.dart` 的 `askUserQuestionTool`），不是 cherry-pick。
原始提交在 `refs/pull/8/head`。

