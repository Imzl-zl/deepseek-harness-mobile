# 中转里"那台电脑的 id"只认一个来源

- 日期：2026-11-03
- 触发：线上事故 —— 控制台签发的令牌出码永远失败（`没能把这次配对登记到中转`，中转日志 `连接器不在线`）
- 状态：implemented

## 背景

`1bc30b2`（管理台自己签发令牌）给令牌引入了两个 id：

| 字段 | 含义 | 谁在用 |
|---|---|---|
| `Authenticated.id` | 令牌的逻辑 id，吊销/删除按它定位 | 管理台 |
| `Authenticated.connectorId` | 第一次连控制面时由 `?id=` 绑定的**电脑 id** | 路由、名册、名额、登记 |

旧令牌两者相同（`{"id":"local"}`），所以历史上"读 `id`"一直是对的。新令牌的 `id` 是随机的
`tk_…`，只有 `connectorId` 才是 `local`。

`relay/src/http-face.ts` 的登记与名册两处仍写着 `caller.id`，于是：

```
控制面 connector.open connectorId=local     ← 中转确实有这台电脑
HTTP  /pairing/register 按 caller.id=tk_… 查 connectors 表 → 查不到
     → core.ts 抛「连接器不在线」→ 409 → 电脑侧「没能登记到中转」
```

手机侧完全无辜，人也只会看到"中转是不是没开 / 令牌是不是不对"这种误导性文案。

## 决定

**加一个 `connectorIdOf(who)`（`digest-auth.ts`），凡是要找"那台电脑"的地方都走它**
（`connectorId ?? id`），并把散落在 `http-face.ts` / `token-table.ts` / `server.ts` 的
十来处同义表达式全部收进去。

## 被否掉的

- **在 `http-face.ts` 两处就地改成 `caller.connectorId ?? caller.id`**：治好这一次，
  下一个人在新路由里再写一次 `caller.id` 就又犯。同一条规则现在有 12 个副本。
- **让 `token-table` 在认证时把 `connectorId` 直接覆盖到 `id` 上**：会毁掉令牌的吊销/删除
  语义（管理台按 `id` 定位令牌，改了就找不到那一行），而且旧令牌没有 `connectorId`，
  等于要求认证层记住"哪些是新的"，比现在更绕。
- **在 `core.registerPairing` 里做兜底（查不到就按令牌 id 反查）**：`core` 不认识令牌，
  给它加一层"猜身份"的兜底只会把这个不变量埋得更深。

## 代价

- `connectorIdOf` 多了一层函数调用 —— 相对"身份口径只有一处"可以忽略。
- 以后新增任何"按电脑"的路由，都得记得用 `connectorIdOf`；`http-face.test.ts` 里那条
  用例（令牌 id ≠ 电脑 id）是唯一会立刻红的地方，别把它删了。

## 验证

- `relay`：`tsc --noEmit` 0，`node --test` **164** 项全绿；
- 变异校验：把 `http-face.ts` 改回 `caller.id` → 新增用例 1 红；还原 → 全绿；
- 线上：重新构建部署后，用同一张令牌 `POST /pairing/register` 得 **201**（此前恒 409）。
