# 安装级设备码与鉴权代次分离，旧授权按登记快照退役

Status: implemented

## Problem

有效重配生成新密钥是既有安全选择，但将鉴权 devId 当长期显示码，用户每次重配都像多一部手机。旧定位只抓当前电脑的 State 内存：扫另一已存电脑、清槽后重启或回执后退出都会失去关联。成功回执还等第二次点击才持久保存，逐键覆盖同槽又能读出新旧混合凭据。动态按同设备码扫所有记录也不正确：旧身份重连会反向删除后来登记的新身份。

## Decision

安装级 deviceCode 是公开定位/显示信息，不是硬件标识或凭据。唯一持有者是 [PairingStore](<app/lib/platform/pairing_store.dart>)：正常升级缺码用当前完整槽实际 helloDeviceId 初始化，有码后不跟随鉴权轮换；无完整当前槽才随机创建。坏值或读取错误明确失败，不覆盖重建。清配对保留码及按电脑签名公钥分桶的非凭据 hint，目标 pcId 也需一致。

每台电脑的身份、令牌与握手上下文原子写成一个 credentials_v2 JSON。完整已发版分槽沿 v1→v2 规范化后删旧秘密键；坏新 blob 不回落旧键。迁移、保存和相关入口共用同一 Store 操作链，原调用仍收到错误。Android resetOnError=false，避免读取失败默清密钥；成功回执立即 await 保存并进入，不以辅助 SAS/第二次完成点击作为落盘门。保存失败保留同一回执重试。

重新配对继续换鉴权密钥、devId 和令牌，设备码只在加密提交中送给电脑。登记将找旧集合→put→registered 串行执行，并持久记录当时既有旧身份集合 replacesAll；announce 位于该写链外。仅当前有效的新身份正式鉴权后退役它的快照，旧重连不动态扫描同码去删除未来身份。旧格式缺快照才沿原 replaces 关系处理。首次 pairedAt 只作展示，不推断新旧。

## Alternatives considered

- **全手机长期复用同一鉴权密钥**：最强理由是一键同时得到稳定显示和身份；被否是多电脑的 relay 归属按鉴权 devId 单键校验，且同 ID 覆盖配对上下文会破坏旧凭据在回执丢失时仍可用的边界。显示码不应替鉴权作决定。
- **只补当前 previousPairingId 闭包**：最强理由是已有字段、无需新增网络形状；被否是跨电脑/清槽重启仍会漏，而且无法长期区分已确认的手机与一次扫码。
- **按名称、型号或短码归并**：最强理由是清单最短且零迁移；被否是没有持久关联证据，可能清掉另一部仍在用的手机。
- **实时扫描同码所有行并裁掉**：最强理由是不存旧集合、旁支也能收敛；被否是 A 旧重连会删待用 B。登记快照才是代次事实，pairedAt 保留首次值不能替代它。

## Consequences

收益是正常覆盖升级/重配不换显示码，同一安装已知的配对代次能收敛，保存和迟到迁移不再混合或覆回凭据。代价是多了非凭据关联与可选登记快照，并保留轮换窗口旧授权直到新身份真正可用。

deviceCode 可见且可被提交者自报；知道它不能单独获得授权，提交仍须当前有效二维码秘密及候选私钥。能扫码取得新授权的人可申请替换已知定位信息，沿用旧定位字段的信任边界。没有设备码且旧定位已丢的历史行不自动关联。卸载/清应用数据不承诺码延续，也不以采集硬件序列号补洞。

[Store 回归](<app/test/pairing_store_test.dart>) 覆盖原子覆盖/相邻迁移、读取失败、同 Store 竞态和升级显示码；[登记回归](<connector/tests/pairing-endpoint.test.ts>) 覆盖旧重连不删未来行、旁支快照及并发登记；[授权收尾回归](<connector/tests/device-establishment-authorization.test.ts>) 防止已吊销的新身份仍删旧授权。系统原生断电持久性与真实安装历史未在本轮实测。

显示与关联结论取代 [旧显示码决定](<.agents/notes/archived/2026-11-06-device-rows-short-code.md>)、[旧每次重配记录增长决定](<.agents/notes/archived/2026-10-15-new-identity-per-pairing-is-intentional.md>)；鉴权密钥轮换及 [新身份有效前保留旧行](<.agents/notes/implemented/2026-10-28-atomic-repair-keeps-old-device-row.md>) 的边界继续沿用。
