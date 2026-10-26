# 即时提示收成一个组件：看得见结果的成功不弹

- 日期：2026-10-26
- 状态：已落地
- 相关：`implemented/2026-10-26-offline-is-not-missing-file-service.md`（同日真机文案修复）

## Problem

App 里 13 处直接 `ScaffoldMessenger.showSnackBar`：默认样式是深色横条，在浅色主题里
尤其突兀；而且各处的语气不统一——切模型成功也弹一条"已切到 X"，可模型名就在输入栏上，
用户原话是"黑色的选择成功弹窗又丑又多余"。

## Decision

**一个组件 `DshToast`，一条判据**：

- **结果在屏幕上直接看得见** ⇒ 成功不弹（切模型成功：模型名与推理档就在输入栏）。
- **结果看不见** ⇒ 成功也弹（切端点、重连、队列编辑、已复制、已添加）——
  否则用户无法确认"刚才那下成了没有"。
- **失败一律弹**，用 `DshToastKind.error`（错误图标、5 秒、红色描边）。

样式用主题 surface（`layer2`）+ 圆角 + 浮起，不再用默认深色横条；全 app 只有一个出口。

## Alternatives considered

1. **保留各处 `showSnackBar`，只统一主题（`snackBarTheme`）**。
   最强理由：改动最小，一处主题覆盖全部。
   被否：只看样式解决不了"成功该不该弹"的分歧；13 处各自决定语气，下次还会漂。
2. **所有成功都不弹，只弹失败**。
   最强理由：最安静，界面只被失败打断。
   被否：切端点、队列编辑这类"屏幕不会自己告诉你结果"的动作会变成"点了没反应"——
   用户明确说过："有的成功了不直观，看不出来你肯定还是要的"。
3. **引一个 toast 库**。
   最强理由：动画/排队/无障碍都现成。
   被否：需求只有"一条浮动提示 + 两种语气"，一个 60 行的组件就够；多一个依赖不值。

## Consequences

- 收益：全 app 一个出口，语气与样式不会再各自漂；模型切换不再有一条多余的黑条。
- 代价：新增 `app/lib/ui/dsh_toast.dart`，各调用点必须记得按"结果看不看得见"选语气；
  这是文字判据，测试只能钉住个别点（模型切换成功不出提示）。
- 代价：`DshToast` 依赖 `ScaffoldMessenger`，没有 messenger 的上下文（极少）静默不弹。

## 代码入口回指

- `app/lib/ui/dsh_toast.dart`（唯一出口与规则）
- `app/lib/ui/chat_page.dart`（切模型：成功不弹、失败弹）
- `app/lib/ui/connection_summary_block.dart`、`queue_dock.dart`、`settings_page.dart`、
  `archive_sheet.dart`、`main.dart`（全部改走 `DshToast`）
