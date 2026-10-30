# dsh-mobile-connector

DSH 插件：手机端远程通道的**电脑侧桥接**。装进 DSH 后，手机扫码即可连到这台电脑；
也可以只走局域网/Tailscale 直连（不经过公网中转）。

## 安装

```bash
dsh plugin --profile <名字> add dsh-mobile-connector
# 或者用本地路径/打包产物：
dsh plugin --profile <名字> add ./connector
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

中转怎么搭、令牌怎么签：见仓库的 `docs/cookbook/relay-on-a-server.md`。

## 兼容性

`peerDependencies` 锁在 DSH `0.2.1-rc.3`（`@deepseek-ai/cordis@4.0.5`、
`@deepseek-ai/schemastery@3.18.5`）。宿主升级后要先核对这几条再升级本包。

## 许可

MIT
