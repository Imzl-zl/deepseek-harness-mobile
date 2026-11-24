# dsh-mobile 项目状态

> 覆盖快照；正式契约在 docs，因果在决策笔记，稳定命令在 tools。

## 现在（2026-11-25 · v0.2.24 / connector 0.1.31 已正式发布）

用户在已知真机/真实GUI缺口后明确要求发版，已提交/推送本轮修复并公开发行。未安装到运行profile、未重启用户DSH、未改两部手机或真实设备表。

- 发行提交 f07b0378cc15cc98aebfbfd56a239e5de2e5c161；App v0.2.24（基础27）与connector-v0.1.31两个annotated tag均指向该提交。
- [发行页](https://github.com/Imzl-zl/deepseek-harness-mobile/releases/tag/v0.2.24) 非draft/非prerelease，三APK与TGZ全部uploaded。
- APK体积：arm64 **28,736,956B / 27.4MiB**、v7a25,032,748B、x64 31,227,322B；TGZ207,647B。
- 三APK实际code **v7a1027 / arm642027 / x644027**，versionName0.2.24，包名io.github.imzlzl.dsh_mobile；aapt/apksigner每项exit0。
- 同v0.2.23发行证书 SHA256 c0a552257833d3d1f0b7ae9da94885e783f7fb361646390d39d8b6172519acdb，RSA4096/v2签名通过；不要求卸载覆盖更新。
- npm **latest=0.1.31**，Trusted Publisher首run成功，SLSA v1 provenance已核验；未手动重发或修改已发内容。
- **重复发布run仍有一次E409**：第二标签run45446419975的前置/30秒重查未见registry传播，首次run45446419955已成功且npm实际0.1.31可读取。不要将该红run说成版本未发布，也不宣称所有发布run都绿。
- 后续仅SDK版本code解释/回归维护提交30bd46c；其CI99成功。生产计数策略未改，基础27与ARM64实际2027不同来自Flutter拆ABI偏移，不是漏参。

## 本轮主要修复

- 真实未升级WebSocket的close不等待不存在的回执，在途HttpClient可取消；迟到connect不复活握手。
- 路径探测逐条真实握手即反馈，任一允许路径可确认；秘密仍等用户确认。SVG自带标准4码元静区，回归不补边。
- 安装级deviceCode长期保存，正常升级缺码取当前完整槽实际helloDeviceId，重配/清配对保留；鉴权密钥/devId/令牌仍轮换，不采硬件ID。
- 旧定位按目标电脑公钥/pcId读，clear前持久非凭据hint；credentials_v2单原子JSON，与迁移/保存单写链；坏新blob/读错不默清、Android resetOnError:false。
- 成功回执立即await保存，取消额外完成落盘门；保存重试不重新提交秘密。
- 登记串行捕获旧集合replacesAll；有效新身份业务鉴权才裁当代快照，旧重连不删除未来行。
- 设备deleteMany一批一次提交，本地应答不等公网/无关读面；名册FIFO有pending/synced/error/deferred日志与面板状态。
- 连接卡保存不盯无关relay额外5.5s；明确撤销4003/not-paired及时给手机终态，普通停止1000不清凭据。

## 验证与构建

- 本轮fresh发行前14门禁全绿（141.608秒），冻结751个source/test/config文件哈希前后相同；App2026/2026、发行源码connector938/938、relay183/183，format421files0changed/analyze0。
- 协议454/26/49、boundary988、size/rpc/图标/工具路径均PASS；关键回归先红后绿和内存变异有效。
- [同SHA CI98](https://github.com/Imzl-zl/deepseek-harness-mobile/actions/runs/45442484193) success后才推tag；[Release27](https://github.com/Imzl-zl/deepseek-harness-mobile/actions/runs/45446420026) success。
- 追加同ABI发行计数捕获回归后当前main connector **940/940**，tsc0；[维护CI99](https://github.com/Imzl-zl/deepseek-harness-mobile/actions/runs/45448421650) success。
- 四项下载SHA256与GHdigest/size一致；[资产核验](<app/build/release-meta/downloads/task10-verified-assets.json>)、[包manifest](<app/build/release-meta/downloads/task10-tgz-package.json>)在忽略生成目录。TGZ确含lib/client、deviceCode/replacesAll/schedule和roster反馈。

## 未验证与恢复边界

- 真机摄像头扫码、两手机覆盖安装/原生断电、真实当前GUI React端到端未验；缺口已写Release notes，不宣称秒扫/生产毫秒。
- 已开始名册HTTP不主动abort，热改参数非跨存储原子快照；FIFO最终新全量收敛，状态暂时滞后明示。
- 无code且旧定位已丢的历史行不能按名称/型号/短码自动归并；卸载/清应用数据不保证码延续。
- v2迁移后不能直接降装旧APK；如异常保留应用数据，前滚同证书/高code/兼容v2修复。撤回发行曝光与数据恢复是不同步骤，详见 [发行恢复](<docs/cookbook/release.md#L186-L203>)。

## 知识归宿与后续

[配对连续性](<docs/subsystems/pairing-v2.md>)、[存储](<docs/subsystems/remote-channel.md>)、[手机持久化](<docs/subsystems/app-channel-client.md>)、[设备管理](<docs/subsystems/connector-and-relay.md>)为真值；原因在11-24三篇implemented笔记和 [ABI计数查证](<.agents/notes/implemented/2026-11-25-split-apk-version-code-verification.md>)。

下一步由用户在原安装上覆盖升级v0.2.24并将电脑连接器更新0.1.31，验两手机码/重配回收/删除反馈；不先卸载或清数据。新建会话闪回未复现、数据面剩余收敛与多设备/状态/差异面真机复验仍保留。当前默认会话最近更新排序与出码全部现取LAN IPv4未变。
