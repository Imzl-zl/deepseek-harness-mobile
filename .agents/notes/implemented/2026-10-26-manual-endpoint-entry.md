# Agent Note: 换网连不上时给"手动填地址"，且不自动拨

Status: implemented

## Problem

用户回家换了 WiFi，手机里存的电脑地址（上一张 WiFi 的 IP）全部拨不通，而当时界面上只有
「重新配对」一条出路 —— 等于**换次网络就要重扫码**。设备凭据与地址本来无关，重配对是过度动作。

原来的自动路径只覆盖"表里还有一条能通"：`dialOrder`（`core/endpoint.dart:248-276`）按
"记住的 → 同网段 → 用户顺序"把整张表试一遍；`endpoint.describe` 也要**连上之后**才学新地址。
一条都不通时，自动路径无从下手。

设置页本来就有「添加端点」对话框（含安全边界：直连只收 `ws://` 且必须是局域网/回环），
但连不上的那一刻用户看不到它。

## Decision

1. 把设置页那个对话框抽成共用件 `ui/add_endpoint_dialog.dart`（设置页与连接 sheet 同一份）。
2. 连接操作 sheet 增加「手动填写电脑地址」一行（三处入口共用这个 sheet，所以空态、
   抽屉连接行、顶栏状态点都能到）。
3. **填完只加进表，不自动拨**：由用户在「换个连接方式」里选它才连。

## Alternatives considered

1. **填完立刻自动拨**
   - 最强的理由：少一步，用户刚填完就想连。
   - 被否（用户当场否决）：「我肯定手动去连接啊」。自动拨意味着一次误输就打断现有连接、
     还会写"记住的那条"；而"什么时候连"是用户的动作。与设置页那句
     「已添加，下次重连会试它」也一致。
2. **把环回地址当永久兜底（USB / adb reverse）**
   - 最强的理由：测试与调试时最省事。
   - 被否（用户当场否决）：环回只是**调试通道**；真实使用是局域网，回环永远连不上电脑。
     把它当产品兜底是错的。
3. **重配对**
   - 最强的理由：一条已知可用路径，不用做新界面。
   - 被否：换网络不是换电脑；凭据与地址无关，重配对清掉凭据纯属多余，还要用户走到电脑前扫码。

## Consequences

- 收益：换网络只需填一次新地址，配对关系与设备令牌都保留。
- 收益：对话框只有一份实现（安全边界一处判）。
- 代价：用户得知道电脑当前的局域网地址（设置页/连接 sheet 的「当前连接」块会显示）；
  填错时不会自动拨，因此也不会"悄悄断掉"现有连接。
- 代价：地址表仍可能积累旧条目（不自动清理，避免删掉"下次回公司还要用"的那条）。

## 代码入口回指

- `app/lib/ui/add_endpoint_dialog.dart`（共用对话框）
- `app/lib/ui/connection_actions_sheet.dart`（`onManualEndpoint` 行）
- `app/lib/ui/connection_summary_block.dart`（`addEndpointOnly`）
- `app/lib/ui/chat_page.dart`（sheet 接线）
- `app/test/manual_endpoint_test.dart`、`docs/subsystems/app-channel-client.md` §6.1
