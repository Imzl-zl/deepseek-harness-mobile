# Agent Note: 带密钥的三方链路 —— 卡在握手的哪一步

Status: proposed（一条用例 `skip` 指向本篇；本轮已落地的是**共用夹具** `tests/support/relay-process.ts`）

## 已经就位的（本轮产出）

- **共用夹具 `tests/support/relay-process.ts`**：`startRelayProcess(t, tokens)` 起真的中转子进程、
  读回端口、收尾清理；`waitFor` 一并抽出。抽出来的理由是**两处用例都要它**，
  而"临时目录 + SIGTERM + 解析启动行"写两遍必然分叉（那类分叉的症状是偶发失败，最难查）。
  传输缝用例仍用它；带密钥的三方用例是第二个消费者。
- **带密钥三方用例的骨架**（`tests/relay-keyed-three-party.test.ts`，当前 `skip`）：
  手机替身（`createPhone` + `phoneSealBox`/`phoneOpenBox`）带票连中转、
  连接器侧真连接层 + 真握手驱动器 + 真密码器（`peerOf` 直接给手机的公钥与 `pairingId`，
  **故意不走配对流程** —— 配对本身有独立用例，这里要钉的是"握手与 AEAD 能否经中继跑通"）。
  写它的过程中踩到并修掉的两处：`nonceA` 必须是 **32 字节 hex**（不是 base64url）、
  `PhoneFrameHeader` 没有 `v` 字段（`{t, fc, id?, sid?, seq?}`）。

## 现象

跑到 `await waitFor('连接器握手成立', () => established === 1)` 时超时（约 8.8 秒）。
也就是说：设备侧发了 `hello`，但**连接器的握手没有成立**（`established` 一直是 0）。

## 下一步（按成本排序）

1. **`DSH_RELAY_DEBUG=1` 跑同一条用例**：中转会把"电脑侧帧 → 投给谁 / 设备侧帧 → 投给谁 /
   丢弃原因"逐条打出来（第 44 轮补的留声）。一次运行就能判断是
   **`hello` 没到连接器**、**`hello-ack` 没回到设备**，还是**回到了但手机没接受**。
2. 若 `hello-ack` 回程断了：查 `noSidByRequestId` 的登记与清理时机 ——
   设备侧无 `sid` 帧会登记（第 47 轮），而**每一次回帧都会把它删掉**
   （`noSidByRequestId.delete(requestId)`）。握手是**多轮**的（hello → hello-ack → confirm），
   所以这里可能有一个真问题：**同一对连接上的第二次无 `sid` 帧找不到关联**。
   若确认如此，修法是把"删掉"改成"保留到对端断开"（`id` 关联不是一次性的，
   它标识的是一次**交互**，而握手正是两次往返）。
3. 若 `hello` 没到连接器：查中转的绑定是否在设备升级时就建立（`claimTicket` 在换票那一步 ✓，
   而用例里换票发生在升级之前 ✓）。

**第 2 条是我当前的判断（未证实）**：它符合"设备侧登记了、回帧删掉了、第二次就没了"的形状，
而 `hello` → `hello-ack` → `confirm` 恰好是两次往返。下一轮先用 debug 日志证实或否掉它。

## 为什么本轮停在这里

上面第 1 步要跑一次带 debug 的用例（约 10 秒）并读输出，第 2 步要改 `core.ts` 的关联生命周期
并补用例 —— 而本轮上下文已到极限。**树是绿的（connector 261 项 + 1 跳过、relay 42 条）**，
证据与下一步都写在这里。
