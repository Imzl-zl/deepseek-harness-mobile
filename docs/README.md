# 文档地图

先看这一页。三分钟看懂它怎么跑，再决定读哪份。

## 30 秒看懂

```
手机 App  ⇄ 电脑插件（连接器）⇄ DeepSeek Harness
   │            ⇅
   └── 可选：中转（公网 wss，只转发密文）
```

- **两条路**：同一 WiFi / Tailscale 走 **直连**（电脑的 8790 端口）；出门在外走 **中转**
  （默认内置 `wss://dsh.0t0.me`，可以换成自己的）。
- **配对一次就够**：扫码把电脑公钥钉在手机里，之后换网络只是换地址，不用重扫。
- **端到端加密**：握手后每一帧都封箱，中转只看见密文和路由元数据。
- **一台手机记多台电脑**，同一时刻只服务一台。

## 我想……

| 我要做的事 | 看这里 |
|---|---|
| 装上、连上、发第一句话 | 根目录 [`README.md`](../README.md) 的「下载」与「快速开始」 |
| 自己部署中转（有域名 / 只有 IP） | [`cookbook/relay-on-a-server.md`](cookbook/relay-on-a-server.md) |
| 手机和电脑点对点直连（不经服务器） | [`cookbook/direct-p2p.md`](cookbook/direct-p2p.md) |
| 从零跑通开发环境 + 真机 | [`cookbook/channel-bootstrap.md`](cookbook/channel-bootstrap.md) |
| 改手机端界面 | [`design-and-tech-plan.md`](design-and-tech-plan.md) §7，再改 `mock/proto/` 与 `app/` |
| 改通道协议 | [`subsystems/remote-channel.md`](subsystems/remote-channel.md)，先改 `protocol/fixtures/` |
| 加一个设置项 | [`settings-porting-notes.md`](settings-porting-notes.md) |
| 加一个平台（iOS / 鸿蒙） | [`subsystems/app-platform-boundaries.md`](subsystems/app-platform-boundaries.md) |
| 发版 / 签名 | [`cookbook/release.md`](cookbook/release.md) |
| 搞清楚某个古怪写法为什么这样 | 仓库根的 `.agents/notes/`（因果），不是 `docs/`（现状） |

## 连不上时按顺序查

1. **电脑在跑吗**：DSH 侧边栏「手机」面板的「连接」卡有状态；直连端口默认 8790。
2. **同一网络吗**：手机和电脑在同一个 WiFi 才走直连；换网后端点表会自动重排。
3. **中转通吗**：面板里中转地址、令牌是否成立（`docs/subsystems/pairing-v2.md`）。
4. **配对还在吗**：卸载 App / 清数据会丢凭据，只能重扫。

前三步的判据都在 `docs/subsystems/connector-and-relay.md` 与
`docs/subsystems/app-channel-client.md`；`memory.md` 里是最近踩到的坑。

## 文档分工

| 目录 | 回答什么问题 |
|---|---|
| `design-and-tech-plan.md` | 设计与技术基线（总纲）：定位、token、逐屏规格、授权规则 |
| `subsystems/` | 每个子系统的规格与契约（通道、配对、各页面） |
| `cookbook/` | 一步步怎么做：部署、配对、发版、穿透 |
| `postmortem/` | 真实事故与止血措施（血泪史只在这里） |
| `architecture.md` | 代码骨架与子系统索引（给改代码的人） |
| `channel-review-notes.md` | 通道方案评审证据与 DSH 侧行号 |

`docs/AGENTS.md` 是这些文档的写作规则；根 `AGENTS.md` 是硬约束；
`tools.md` 是命令与门禁条数的唯一出处。

## 改代码前

```pwsh
node protocol/verify-fixtures.mjs        # 通道协议（两侧实现必须相等）
cd connector; pnpm exec tsc --noEmit; pnpm build; pnpm test
cd app; dart format --output=none --set-exit-if-changed lib test; dart analyze --fatal-infos lib test; flutter test
node app/tools/verify-platform-boundary.mjs
```

完整清单、断言条数与浏览器门禁见 [`tools.md`](../tools.md)。
