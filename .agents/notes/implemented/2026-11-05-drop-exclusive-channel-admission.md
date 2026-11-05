# 撤掉独占准入：一台电脑同时服务多台设备

- 日期：2026-11-05
- 触发：用户有两台手机，需要同时连同一台电脑；原话是「同时用那是用户的事我们不能限制」。
- 状态：implemented

## Problem

`proposed/2026-10-29-one-phone-many-computers.md` 把「连接」定成 1:1，同一段里也写着
**独占是一条新增边界，宿主没有**（DSH 的网关服务多个浏览器 client；连接器本来就每 accept
一条装一次、presence 记多台、中转每设备一条数据通道）。这条边界与 `AGENTS.md` 的第一条军规
（宿主语义优先：不新增宿主没有的边界）冲突，代价是"第二台手机连不上"，而需求侧正好相反。

判据：**同时开几台是用户的事**。删掉这条边界，系统回到宿主本来的形状。

## Decision

1. **准入不再判定**：`connector/src/exclusive.ts` 删除；`handshake-driver` 的
   `occupantOf` 选项与拒绝分支删除；`index.ts` 不再构造准入、不再传 `occupantOf`。
2. **`presence.serving()` 删除**：它存在的唯一意义是"此刻在服务的那一台"。多台同时在线时
   它要么骗人要么没用；消费方（管理面）改读 `devices()` 的 `online`。
3. **错误码两端同批删除**：`device/busy`（TS `ERROR_TABLE` / Dart `ErrorCode`）与
   `ClientAction.busyWait`。封闭表 36 → 35；`flow.test.ts` 的计数与
   `error-table-parity.test.ts` 的动作名映射同步。
4. **手机侧"被占用"整条链删除**：`SyncClientProbe.lastConnectBusy`、`_lastConnectBusy` 的
   三处判据、`AppModel.busyOccupant`、`ConnectionStateView.busy` 与「未连接 · 电脑被占用」
   文案、`connectionSummary` 的 `detail` 参数（唯一调用方就是它）。
5. **管理面**：`AdminDeviceRow.serving` 删除，行上只剩 `online`；面板的「在服务」胶囊与
   「接管」按钮删除 —— "接管"本来就是 `POST /devices/enabled {enabled:false}` 的另一个
   确认框，与「停用」重复。
6. **文档同批**：`remote-channel.md` §3.1 / §4.1、`app-channel-client.md` §6.4、
   `connector-and-relay.md`、`ui-state.md` §2（顺手改掉"没有存量"那句 —— 存量已经存在）。

## 被否掉的

- **保留判定但默认放行**：留一个恒真的开关，等于留一段没人敢删的死逻辑。
- **`serving` 留着改成"最近在线的那台"**：那不是使用方需要的语义，还会把"设备在线"变成
  两份真值（`devices()` 与 `serving()`）。
- **把「接管」改成「强制下线」**：已有「停用」走同一条写路径，第二个入口只会让人以为两者不同。

## 仍然成立的不变量

- 停用 / 删除**必须收掉那台设备已建立的连接**（否则旧 socket 还在收发，那台手机一直以为在线）。
- **删除只对已停用的行开放**（先停用 → 手机拿到终态 → 再清理记录）。
- 已停用 / 已删除的行在 `peerOf` 处回 `protocol/not-paired`。

## 验证

- `connector`：`pnpm exec tsc --noEmit` 0；`pnpm test` **832 / 832**（删掉的 13 项是独占用例）；
  `pnpm build` 成功。
- `app`：`dart analyze --fatal-infos lib test` 0；`dart format` 对本批改动的文件无改动。
- **未验**：两台真机同时连同一台电脑的端到端（`memory.md` 待验清单第 1 条）。

## 本批未触及的现状

- `credit` 的 ack 仍没有身份标记（`remote-channel.md` §4.3 引用的未决项）。多设备并存之后
  这条从"理论问题"变成"必须确认"：要么已被"每设备一条数据通道"化解，要么要加 `id` 回显。
  本批不动协议帧 —— 验证优先于改帧。
