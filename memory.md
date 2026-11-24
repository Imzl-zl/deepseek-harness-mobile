# dsh-mobile 项目状态

> 覆盖快照；正式契约在 docs，因果在决策笔记，稳定命令在 tools。

## 现在（2026-11-25，用户已明确授权发行，发布门禁进行中）

已发布状态当前仍是 v0.2.23 / connector 0.1.30；准备发行 App v0.2.24（本地+27，CI run number覆盖）/ connector 0.1.31。用户在已知真机/真实GUI缺口后明确请求发版；不安装到profile、不重启现有服务、不改两部手机或真实设备表。HEAD 起点73b233f，正在复验后提交/推送正确标签；CI/release/npm及资产签名核验成功前不宣称已上线。

用户报扫码难、检测连接无反馈、两个手机攒很多设备和删除高延迟，本轮确认并修复：

- 原生 WebSocket 尚未升级时的 close Future 无完成者，成功配对被输家收尾扣住；现在每次自持 HttpClient 可取消，未就绪不等关闭回执，迟到 connect 不启动握手。
- 探测先前等两条全返回才显示；现在每条真实受限握手完成即呈现，任一允许路径可确认，取消其他候选与旧代次；确认前仍不发秘密。
- 二维码自身静区从两码元修为标准四码元；独立解码回归使用实际完整 SVG，不裁边或替它补白边。
- 稳定安装级 deviceCode 与鉴权身份分离；正常覆盖升级首次取当前完整槽实际 helloDeviceId，之后重配/清配对保留。鉴权密钥/devId/令牌仍换，不读硬件码。
- 旧定位按目标电脑签名公钥读取并核对 pcId；清槽前持久非凭据 hint。每台电脑身份/令牌/上下文原子 credentials_v2 JSON，完整已发版分槽相邻迁移，坏新 blob 不回落旧键。
- Store 迁移/保存/读取写入口有单写链；Android resetOnError=false。读取失败有启动错误与手动重试，不默清或重建。成功回执立刻 await 保存，去掉额外完成落盘门；保存重试只用同一回执。
- 登记找旧集合→put→registered 串行；replacesAll 是登记时旧身份快照。有效新身份业务鉴权才裁旧，旧A/B重连不删未来C；名册在链外调度。
- 删除批量用宿主 deleteMany 一次提交；本地操作不等远程名册，所有设备写失败在HTTP边界返回原文。名册共用FIFO、独立 pending/synced/error/deferred 状态与日志；面板明确反馈并可刷新。
- 设备状态读面不等无关 connection/advertise，旧读取迟到不覆回新清单。连接保存采用后端settle回执，删掉盯relay的额外5.5秒轮询。
- 明确撤销/已知失效身份关闭是4003/protocol/not-paired，手机得到终态不依赖中转上传窗口；普通停止仍1000不误清凭据。

## 验证（本轮新鲜执行）

- App全量 **2026/2026**（53秒，backend timeout60s）；Dart analyze --fatal-infos lib/test/integration_test **0 issues**。
- connector全量 **938/938**，typecheck/build均exit0；完整三门禁15.565秒。实际Node24.21.0、加载pnpm11.28.5，带 --pm-on-fail=ignore 避免自动下载工程pin版本。
- 协议 **454 / 26 / 49**；多端边界 **988**；尺寸棘轮PASS（根State预算48→47）；wire外零RPC、图标与工具路径门禁PASS；git diff --check通过。
- 真 socket/真实 Flutter Widget 的挂起地址、即时确认、即时保存、同回执重试、关闭终态、密文设备码均有红→绿。
- Store32条与配对/endpoint/schema44条局部回归；登记写链、批删除、发布FIFO/latest状态均做过内存变异，破坏不变量准确红且磁盘源码未变。

## 未验证与真实限制

- **未真机验收**：ADB无设备；摄像头光学识别、安装覆盖/原生断电持久以及两手机实际历史未实测，不宣称秒扫或生产删除毫秒。
- **未真实React/当前GUI冒烟**：Chrome可连但已有GUI需认证；现装frontend的React/ReactDOM在vendor而非可resolve运行包，隔离依赖/导出契约未取得。未用React桩冒充DOM验证，未起替代服务。
- 已发出的名册HTTP不主动abort；热改地址/令牌不是跨存储原子快照，旧queued投影可先暂时到新relay，随后FIFO新全量收敛；不新增重试/超时/accepted-count策略。
- 历史无deviceCode且旧定位已丢的行不能自动归并，不按名字/型号/短码删除。清配对保留非凭据码/hint，卸载/清应用数据不承诺码延续。

## 正式真值与笔记

- 契约：[首配连续性](<docs/subsystems/pairing-v2.md>)、[通道存储](<docs/subsystems/remote-channel.md>)、[手机持久化](<docs/subsystems/app-channel-client.md>)、[管理与名册](<docs/subsystems/connector-and-relay.md>)。
- 因果：[配对取消/进度](<.agents/notes/implemented/2026-11-24-pairing-cancellation-and-progress.md>)、[稳定码/快照](<.agents/notes/implemented/2026-11-24-stable-device-code-and-pairing-continuity.md>)、[本地提交/名册](<.agents/notes/implemented/2026-11-24-device-admin-local-commit-and-roster-sync.md>)；两篇旧显示/增长决定已标注取代并移archived，结论未改。

## 上一窗口保留事项

- v0.2.23 出码地址是此刻全部局域网IPv4，默认路由只排序，斜杠出码入口已删；会话排序默认最近更新，手动移动切manual。
- 未复现新建会话闪回旧会话，仍需带RPC轨迹的诊断包。
- 数据面收敛剩余项、多设备真机准入、状态语义与差异面真机复验仍待完成。
- 计划审查卡手机上有意不做；清空全部记录仍可能清掉在用的离线设备，后果与确认未更改。

## 下一步

1. 用修复源码构建同包同签名更新进行真机验收；**本轮未构建/发布APK**，不要把本地测试当已上线。
2. 两手机分别验证正常覆盖升级码不变、重配新连接后已关联旧行退役、删除立即给本地结果且后台状态可查。
3. 若需发版，先做上述真机和真实GUI验收；不能因全量单测绿跳过现场链路。
