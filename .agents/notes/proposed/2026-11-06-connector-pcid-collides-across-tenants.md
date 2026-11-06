# connector 的 `pcId` 默认 `local`：多租户中转上必然撞车

Status: proposed

## 事实

- 连接器的 `pcId` 默认值是**字面量 `local`**，首次运行时写进存储，之后一直读它
  （`connector/src/index.ts:169` 的 `DEFAULT_CONNECTOR_ID`，`index.ts:508-523` 的迁移）。
  它参与握手 transcript，**换一次 = 所有已配对设备的握手全部验签失败**（`index.ts:166-168`）。
- 中转在账号模式下把令牌的 `connectorId` 绑成电脑首连时报的 `?id=`，之后 `?id=` 必须一致
  （`docs/subsystems/relay-accounts.md:57`），并且**启动时校验每个 `connectorId` 只有一条记录**
  （`relay/src/token-table.ts:157-162`）。
- 中转的通道与名册都按 `(connectorId, deviceId)` 键控（`relay/src/server.ts` 的 `attachData`
  校验 `binding.connectorId === caller.id`）。

## 症状（2026-11-06 生产实测）

`dsh.0t0.me` 上四个账号各自在控制台签过令牌。其中两个账号的电脑都用默认 `local` 连过，
于是配置里出现两条 `connectorId: "local"`。中转重启时**拒绝启动**：

```
配置里的令牌摘要表不可用：令牌摘要表里有两个条目指向同一个连接器（local）：拒绝启动，先修配置
```

旧进程还在跑时看不出来 —— 启动校验只跑一次，运行期认证按摘要查表，跟 `connectorId` 无关。
所以这是一颗**只在重启时引爆**的雷：谁重启谁中招。

## 为什么不能只改中转

把 `byConnector` 的键换成 `(userId, connectorId)` 能修掉启动校验，但修不了运行期：
通道映射、`attachData` 的归属校验、名册都以 `connectorId` 作为连接器身份。两个租户都叫
`local` 时，"这条数据面属于谁"仍然是歧义。所以**必须让 `pcId` 全局唯一**。

## 两条候选

1. **新装默认值换成随机 id**（如 `pc-` + 12 字节 base64url），老装机保留 `local`。
   代价：老装机仍然会撞（只能靠控制台「重置绑定」手工让路）；新装机一次写死，不再复发。
   好处：不改协议、不改中转、老设备不受影响。
2. **`pcId` 由 `pcSignPubHex` 派生**（设备身份已有的那对密钥）。好处：一台电脑一个稳定 id，
   天然唯一、可重算；代价：升级时所有老装机的 `pcId` 都会变 —— 等价于"全部重新配对"。

## 现在的处置

- 生产配置已把其中一条的 `connectorId` 清掉（令牌保留，下次首连再绑），中转恢复。
- cookbook `relay-on-a-server.md` §6.6 加了"重启前先检查令牌表"这一步与冲突检测命令。
- 真正的修复等选型；`DEFAULT_CONNECTOR_ID` 上的注释要一并改成新口径。
