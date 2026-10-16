# Agent Note: 真机改走无线局域网直连（`listenPort` 打开）+ 两处静默失败

Status: implemented

## Problem

用户原话："**我要的是局域网内啊哥？你搞的连线的有啥用？连着线我不能在电脑用吗？？？我要的是无线的啊？？**"

当时的状态：手机唯一能连的是**环回中转** `ws://127.0.0.1:8787` —— 那条地址只在 USB 上通过
`adb reverse tcp:8787 tcp:8787` 才成立，**拔线即断**。而"无线"这条路其实早就实现了
（2026-10-14 的 `endpoint-switching-lan-direct`），缺的只是**电脑侧没开直连监听面**：

- profile 的 `cordis.patch.yml` 里 `listenPort: 0`（注释写着"0 = 只走中转（本机验证走中转就够）"）
  → 连接器压根不起监听面（`connector/src/index.ts:789` 的 `if (listenPort !== 0)`）；
- 于是 `caps.direct = false`、`endpoint.describe` 不报任何 `direct` 端点
  （`connector/src/index.ts:592` 的"没有监听面就不给"）；
- 手机只能在端点表里留着那条死掉的环回地址，反复 `Connection refused`。

## Decision

1. **打开直连监听面**：profile 的 `cordis.patch.yml` 改成 `listenPort: 8790` +
   **`listenHost: 0.0.0.0`**（默认是 `127.0.0.1`，`connector/src/config.ts:54-55`，漏了就"起了但手机连不进"）。
2. **relay 保持只绑回环**（`relay/relay.config.json` 的 `host: 127.0.0.1`）——它对"同一 WiFi"不是必需的，
   而它一旦暴露到局域网就多一个明文入口；要暴露应该是**显式**决定（见下面"遗留"）。
3. **引导一次即可**：端点表的 `direct` 那条是**连上之后**由 `endpoint.describe` 学到的
   （`connector/src/endpoints.ts:48-60`，direct 先于 relay），所以第一次仍要走一次 relay；
   学到的地址会落盘，之后**拔 USB 也能连**。
4. **验收判据是硬证据**：电脑侧 `netstat` 出现 `192.168.2.43:8790 ← 192.168.2.29:39170 ESTABLISHED`
   （手机 WiFi 地址连进来），而不是"界面上看着像连上了"。

## Alternatives considered

1. **继续用 `adb reverse`（USB）**。
   - 最强的理由：零配置，今天就能用。
   - 为何被否：这正是用户否掉的东西 —— 插着线的手机等于没离开电脑，移动端的意义没了。
2. **把 relay 也绑 `0.0.0.0`，重新配对时二维码直接带局域网地址**。
   - 最强的理由：这样**引导本身**也能无线完成（不必先插一次线），彻底去掉 USB 依赖。
   - 为何被否（这一轮）：要重新配对（出二维码、会建一个会话），而"发 prompt/建会话花用户的钱"这条纪律
     要求先问；且当前需求（"现在要能无线连"）用第 3 条就能满足。**遗留项，等用户点头再做。**
3. **让 App 支持手填/切换端点**（用户问的"手机端怎么没有这个配置"）。
   - 最强的理由：地址变了（换 WiFi / DHCP）时用户能自救，不必重新配对。
   - 为何被否（这一轮）：`AppModel` 的 `endpoints`/`activeEndpoint`/`preferEndpoint` 都在，
     但 UI 是新功能（设置页现在还是 stub），不属于"现在连不上"这件事。**遗留项。**

## Consequences

- 收益：手机**不插线**可用（已真机验证：撤掉 `adb reverse`、重启 App，仍绿点 + 会话列表，
  电脑侧看到来自 `192.168.2.29` 的 ESTABLISHED）；防火墙也一并被这条证据证了，无需额外规则。
- 代价：电脑侧在局域网上多了一个明文 `ws://0.0.0.0:8790` 监听面。鉴权仍是 §4.1 的握手本身
  （未配对设备在 `hello` 处被 `protocol/not-paired` 拒），代价是**元数据可见**（帧大小与时序）——
  与 `2026-10-14-endpoint-switching-lan-direct` 里记的取舍同一条。
- **遗留**：① 电脑 IP 变了或手机换了 WiFi 时，若旧直连地址失效，仍会卡一次引导（需要 USB 或局域网可达的 relay）；
  ② 手机端的端点选择器 UI 未做。
- **两个静默失败（这次花了大量时间，判据已进 `tools.md`）**：
  1. **`adb reverse` 僵尸条目**：adb daemon 重启后 `--list` 照样显示，但手机上没人监听。
     修法 `--remove-all` 再建，并从**手机侧** `curl` 验（405 = 中继在应答）。
  2. **编辑工具写 `~/.dsh/**` 报成功却不落盘**：`edit` 返回 Updated file，而 mtime 与内容纹丝不动。
     我因此误判了三轮（以为 relay 未起 / 以为 `Volatile` 被覆盖 / 以为插件没读配置）。
     修法：这类文件用 shell 写 + 当场回读，改前备份。这条已写进根 `AGENTS.md` §6。