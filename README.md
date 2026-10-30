<p align="center"><img src="docs/assets/logo.svg" width="96" height="96" alt="DSH Mobile"></p>

<h1 align="center">DSH Mobile</h1>

<p align="center">把 DeepSeek Harness 装进手机：手机端 App + 电脑侧连接器 + 公网中转。</p>

<p align="center">
  <a href="https://github.com/Imzl-zl/deepseek-harness-mobile/actions/workflows/ci.yml"><img src="https://github.com/Imzl-zl/deepseek-harness-mobile/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
  <img src="https://img.shields.io/badge/node-%E2%89%A522.19-3c873a" alt="node">
  <img src="https://img.shields.io/badge/flutter-3.41.9-54c5f8" alt="flutter">
</p>

手机与电脑之间是一条**端到端加密**的通道；中转只转发密文与路由元数据，不持有密钥、不解析会话内容。

## 组成

| 目录 | 是什么 | 入口 |
|---|---|---|
| `app/` | Flutter 手机端：连接层 + 会话界面 | `flutter build apk` |
| `connector/` | DSH 插件：电脑侧网关（拨号 / 监听 / 转发） | 装进 DSH |
| `relay/` | 公网中转（独立 Node 服务，无构建步骤） | `docker compose up -d` |
| `protocol/` | 通道协议：握手、AEAD、流控、恢复、向量 | `node protocol/verify-*.mjs` |

## 三条链路

```text
手机 ──直连（同局域网 / Tailscale）──> 电脑（插件监听面）
手机 ──中转（密文，端到端加密）────> 电脑（控制面 + 数据面）
手机 ──一次性二维码配对（配对秘密不过网）
```

## 快速开始

**电脑侧**：`dsh plugin --profile <名字> add dsh-mobile-connector`（或本地路径 `./connector`），然后在「手机」面板 →「连接」卡填中转地址与令牌，保存即连。

**中转（可选，公网用）**：`cd relay && docker compose up -d --build`，签发连接器令牌 `--issue-token connector <id>`，细节见 [在服务器上跑中转](docs/cookbook/relay-on-a-server.md)。

**手机端**：`cd app && flutter build apk --debug`，装上后用电脑出码的二维码配对。

## 安全模型

- 身份在电脑侧判定；手机只信任**二维码里带出的电脑公钥**。
- 每连接新密钥（前向保密）；配对秘密一次性、不进中转。
- 中转只存摘要（连接器令牌 / 设备令牌 / 管理令牌都是 `sha256`），只记元数据。
- 明文 `ws://` 仅限私网或用户显式确认；公网请自行用反代终结 TLS。

## 开发与门禁

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | 通道协议 454 / 26 / 49 项 |
| `cd relay && pnpm typecheck && node --test` | 中转，132 项 |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 插件，773 项 |
| `cd app && dart analyze --fatal-infos lib test integration_test && flutter test` | 手机端 |

本仓库的 CI 跑同一组命令，见 [`.github/workflows/ci.yml`](.github/workflows/ci.yml)。断言数变化要同批更新此表。

## 文档

- [通道协议](docs/subsystems/remote-channel.md) · [配对 v2](docs/subsystems/pairing-v2.md)
- [连接器与中转](docs/subsystems/connector-and-relay.md) · [手机端通道客户端](docs/subsystems/app-channel-client.md)
- [部署中转](docs/cookbook/relay-on-a-server.md) · [发版流程](docs/cookbook/release.md)

## 友链

<a href="https://linux.do" title="Linux.do —— 友善的技术社区"><img src="docs/assets/linuxdo.svg" height="40" alt="Linux.do"></a>

## License

[MIT](LICENSE)
