# 交接：手机端点选择器 UI（无线直连已通，剩界面）

> **已被取代并归档（2026-10-16）**：本篇的"接下来做什么"三项已全部落地，
> 结论与取舍见 `.agents/notes/implemented/2026-10-16-endpoint-chooser-ui.md`
>（ relay 是否显示的待定问题由用户当场拍板"两个配置两种方式"——两条都显示）。
> 本篇保留为历史交接记录，`archived/` 内冻结。

Status: proposed

## 现在的状态

**真机联调已全程无线化**（2026-10-16 验证，无 USB）：

```
TCP  192.168.2.43:8790   192.168.2.29:41138  ESTABLISHED   ← 手机 ←→ 电脑 直连（WiFi）
TCP  192.168.2.43:8787   192.168.2.43:58755  ESTABLISHED   ← 连接器 → 中转（局域网）
```

冷启动（`force-stop` + 重启）后手机自己连上，`caps.direct=true`、设备 `online/foreground=true`、连接稳定。

## 接下来做什么

**手机端"连接方式"选择器**（用户原话："UI也要有啊，要不然怎么看啊"）。模型层已就绪，只差界面：

- `AppModel.endpoints / activeEndpoint / preferEndpoint`（`app/lib/data/app_model.dart:94-135`）
- `mergeEndpoints`：原位更新 + direct 先于 relay；用户手动重排后只更新字段不挪位（`app/lib/core/endpoint.dart:164-185`）
- `EndpointTransport.connect()` **已按顺序试所有端点**（`app/lib/core/endpoint_transport.dart:89-115`）→ 改序即生效，无需改传输层

建议顺序（我提的，用户未细看，可按判断调整）：
1. 连接 sheet 里加一行"当前连接：直连/中转 + 地址"（一眼能看，不用进设置）；
2. 设置页做端点列表：kind + label + 地址 + 通不通，点一下 `preferEndpoint` 置顶；
3. "换 WiFi 后地址失效"给出提示（现在只会安静重试）。

**一个待定问题**（动手前问用户）：端点列表里**要不要显示 relay 那条**（局域网可用但日常用不到），还是只显示 direct、relay 折叠进"高级"。

## 排期里的 backlog（判据已写好，未做）

- **代码块语法高亮**：DSH 用 shiki，只覆盖 ts/bash/json，首次进入视口才高亮并缓存，未知语言纯文本（`.agents/notes/implemented/2026-10-16-message-body-stays-gfm-markdown.md`）。
- **流式只重排末尾**：DSH `UNSTABLE_TAIL_BLOCKS = 2`（只让末尾两块进流式），当前手机端无分块。
- **归档撤销 toast**：DSH `toast.archivedNotOpenable` / 归档后可撤销（`.agents/notes/implemented/2026-10-16-archive-surface-and-alias-fix.md`）。

## 环境与在跑的东西

- 手机 `d61cf622`，WiFi `192.168.2.29/24`；电脑 WLAN `192.168.2.43/24`（同网段）。
- **两个后台任务是我起的，会话结束它们可能没**：
  - relay：`cd relay; node src/main.ts --config relay.config.json`（`0.0.0.0:8787`）
  - profile：`node <npx>/@deepseek-ai/dsh/lib/bin.js --profile dsh-mobile-test --no-open --port 8099`（DSH web + 连接器，直连监听 `0.0.0.0:8790`）
- 连接器状态面（拿 token 换 cookie 再调）：
  ```powershell
  $t='<启动日志里那个>'; Invoke-WebRequest "http://127.0.0.1:8099/?token=$t" -SessionVariable s
  (Invoke-RestMethod http://127.0.0.1:8099/api/dsh-mobile/status -WebSession $s).caps.direct
  ```
- 出码（不建会话、不花 token）：`POST /api/dsh-mobile/pair`（同一个 session）。
- 手机有 `curl` / `nc`，root 走 KSU：`adb shell 'curl -m5 -sS -o /dev/null -w "%{http_code}" http://192.168.2.43:8790/'` → **426 = 通**。

## 三个静默失败（都花了半小时，判据已进 tools.md）

1. **`~/.dsh/**` 编辑工具会报成功但不落盘** → 用 shell 写 + 当场回读 + 看 mtime，改前备份。
2. **`adb reverse` 僵尸条目**：daemon 重启后 `--list` 照样显示但实际不通 → `--remove-all` 重建 + 手机侧 curl 验。
3. **连接器明文判据只认 loopback**（已修）：手机侧早扩到私网，两边漂一次 → 无线引导被自己的校验器堵死。

## 成本纪律（必须守）

`tools.md:147`：profile 不隔离凭据/会话/存储；**发 prompt 会记在用户官方账号上**。跑真机用例前先问，报一句"约几个轮次"。斜杠命令与 `POST /api/dsh-mobile/pair` 不调模型，可自由跑。

## 门禁基线（2026-10-16）

app `flutter test` **546** / `dart analyze --fatal-infos` 0 / `dart format` 0 / `verify-platform-boundary` **234**；
connector `tsc` 0 / **477 通过 0 失败** / build ✓；protocol **486 / 26 / 49**；
原型 CDP：icons ✓ + verify-proto ✓ + authz 18 / settings 27 / tasks 53 / picker ✓；
`verify-tool-paths` 19 脚本 / 3 规则。远端已同步（main，最新 `6b5f587`）。
