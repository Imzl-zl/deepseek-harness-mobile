# dsh-mobile-connector

<a href="https://www.npmjs.com/package/dsh-mobile-connector"><img src="https://img.shields.io/npm/v/dsh-mobile-connector" alt="npm"></a>
<a href="https://github.com/Imzl-zl/deepseek-harness-mobile/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="license"></a>
<a href="https://github.com/Imzl-zl/deepseek-harness-mobile/actions/workflows/ci.yml"><img src="https://github.com/Imzl-zl/deepseek-harness-mobile/actions/workflows/ci.yml/badge.svg" alt="ci"></a>

DSH 插件：手机端远程通道的**电脑侧网关**。装进 DSH 后，手机扫码即可连到这台电脑；
不在同一网络时走你自己的公网中转（[怎么搭](https://github.com/Imzl-zl/deepseek-harness-mobile/blob/main/docs/cookbook/relay-on-a-server.md)）。

## 要求

- DSH `0.2.1-rc.3`（`@deepseek-ai/cordis@4.0.5`、`@deepseek-ai/schemastery@3.18.5`）
- Node `^22.19.0 || >=24.0.0`

## 安装

```bash
dsh plugin --profile <名字> add dsh-mobile-connector
```

## 配置

在 DSH 的「手机」面板 →「连接」卡里填中转地址与连接器令牌，保存即生效（不用重启）。
等价的 profile 写法：

```yaml
- id: dsh-mobile-connector
  config:
    relayUrl: wss://relay.example.com/ws/connector
    relayTokenRef: relay-connector   # 指向 DSH 凭据面里的令牌
    listenPort: 8790                 # 局域网直连端口，0 = 不开
    listenHost: 0.0.0.0
```

## 它做什么

- **两条链路**：控制面一条接收路由通知；每台设备再拨一条独立数据连接。
- **端到端加密**：每条连接的密钥现场协商，中转只转发密文与路由元数据。
- **方法白名单**：只暴露列出的方法，审批 / 提问 / 任务走同一条通道。
- **独占 1:1**：同一时刻只服务一台有效设备，被拒的那台会收到占用者名字。

## 链接

[仓库](https://github.com/Imzl-zl/deepseek-harness-mobile) ·
[连接器与中转](https://github.com/Imzl-zl/deepseek-harness-mobile/blob/main/docs/subsystems/connector-and-relay.md) ·
[通道协议](https://github.com/Imzl-zl/deepseek-harness-mobile/blob/main/docs/subsystems/remote-channel.md)

## License

MIT
