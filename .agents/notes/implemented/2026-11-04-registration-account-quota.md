# Agent Note: 注册名额上限（满了就把入口置灰）

Status: implemented

## Problem

中转一直只有 `registration.mode`（`open` / `closed`）两个状态：**要么不限量，
要么一个人都不许进**。想"放到 50 个人就停"只能靠管理员盯着账号数、到点手动关 ——
而"盯"这件事一定会在某个周末漏掉。

同时有两个容易做错的口径：

- **数 active 用户会漏**：停用（`suspended`）不是注销，账号还在、还能被恢复；
  "停用 → 再注册"会绕过任何只数 active 的上限。
- **只在注册接口拦会晚一步**：用户先收到验证码、填完密码，才在最后一步被拒，
  白等一封信；入口处就该告诉他"名额已满"。

## Decision

1. **配置**：`auth.registration.maxAccounts`（正整数或 `null` = 不限，默认 `null`）。
   管理台「设置」可改，走现有 `POST /admin/api/registration`，保存即写回
   `relay.config.json` 并更新运行时策略，不用重启。
2. **口径**：`COUNT(*) FROM users`，**含 `suspended`**。`db.countUsers()` 就是这一条，
   不另写一个"只数 active"的查询。
3. **三处拦 + 一处 UI**：
   - `GET /api/auth/config` 的 `registration.full`（布尔）；
   - 注册页读到 `full` 就**一进来置灰**（复用 `closed` 那条分支），文案「注册名额已满。」，
     "发送验证码"一起禁掉；`closed` 的文案保持「这台中转已关闭注册。」；
   - `POST /api/auth/email-code` 且 `purpose=register` → 403 `registration-full`；
   - `POST /api/auth/register` → 409 `registration-full`（入口预检 + 插入兜底）。
4. **裁决在事务里**：`db.createUser(input, { maxAccounts })` 把"数一遍 + 插入"放进
   `BEGIN IMMEDIATE … COMMIT`，满了抛 `RegistrationFullError`。入口的预检只负责
   让人早点知道，不是判据 —— 并发注册只有一个能拿到最后一个位置。
5. **`closed` 与 `full` 分开**：`closed` 先判；两者都不影响登录、已登录用户与
   **密码重置**（`relay-accounts.md` §4.1 的原则）。

## Alternatives considered

1. **只数 active 用户**
   - 最强的理由：active 才是"真的在用"，停用的账号不该占名额；管理员停用一个人
     就能立刻腾出一个位置，操作上更直观。
   - 为何被否：停用不是注销 —— 账号还在库里、还能被恢复，而且**恢复不经过名额判定**。
     数 active 会让"停用 → 再注册 → 恢复"变成绕过上限的标准路径，上限名存实亡。
     真要让位就该删除账号（当前产品没有用户自删除，管理员也不该为了腾位删数据）。
2. **管理台新开一个「注册名额」接口**
   - 最强的理由：语义单一，不必动 `/admin/api/registration` 的既有入参。
   - 为何被否：注册策略（开关、域名白名单、名额）是**同一个表单、同一份配置段**，
     拆成两个接口就有两条写回路径与两次审计，还要处理"两个都改了谁后落盘"。
     在既有接口上多一个**必填**字段（`maxAccounts: number | null`，缺字段 400，
     不是"顺手取消上限"）更小，也更容易解释。
3. **邀请码 / 等待名单 / 按邮箱域或 IP 的配额**
   - 最强的理由：真要做"邀请制"，邀请码比一个总数更接近运营意图。
   - 为何被否：这次要的是"到 N 个人就停"这一个数；邀请码与等待名单各是一套新的
     数据模型（谁发的、用没用、排队顺序、过期），与"名额"不是同一件事。按域/按 IP
     的配额还会把"同公司共用出口"变成误伤。先只做总数，语义最小、可逆。
4. **只在注册接口拦（不拦发码）**
   - 最强的理由：一处判据，少两处分支。
   - 为何被否：用户会先收到验证码、填完密码才被拒 —— 白等一封信、白记一个码，
     而"名额已满"本来在他打开注册页时就已知。发码与注册都拦，代价只是两行。
5. **`full` 时整页跳到一个"已满"页**
   - 最强的理由：最不容误解。
   - 为何被否：注册页也是"登录/重置"的同一张壳；整页替换会让人以为整台中转不可用。
     置灰 + 一句「注册名额已满。」说清"只是不能新注册"，登录与找回密码照旧。

## Consequences

- 收益：到上限自动停，不靠人盯；口径含 suspended，"停用→再注册"绕不过去；
  并发注册不会因为预检与插入之间的空隙多进一个人。
- 代价：`AuthConfig.registration` 多一个必填字段，三处测试配置字面量要跟着补
  （类型检查会拦，不会静默漏）；`createUser` 多一条带事务的路径。
- 代价：名额是**全局一个数**，不区分邮箱域 / IP / 邀请人；要"留几个位置给朋友"
  只能手动调大或临时关闭。按域/按 IP 的配额这次**有意不做**。
- 机制上的边界：单实例 + `node:sqlite` 同步执行已经让并发注册不会交错，事务是
  把这条判据写进数据库（而不是依赖"Node 是单线程"这个巧合）；多实例部署下
  SQLite 也不是共享存储，仍然需要外部数据库 —— 与既有的单实例边界一致。
- UI 的判据是 `registration.full`（服务端每次现算），页面**不缓存**：管理员改大
  名额后刷新注册页即可继续。

## 判据

- `cd relay; pnpm typecheck` → 0。
- `cd relay; node --test` → **173 条全绿**（新增 `accounts-registration-quota.test.ts` 7 条：
  未满 / 满了发码 403 与注册 409 / 含 suspended / 并发只进一个 / closed×full 交叉 /
  重置密码与已登录不受影响 / 配置解析；`accounts-face.test.ts` 补注册页两档置灰的 HTML 判据；
  `admin-face.test.ts` 补 `maxAccounts` 必填与三个非法值；`example-config.test.ts` 补样例默认 `null`）。
- 变异校验：把 `db.createUser` 事务里的 `count >= maxAccounts` 改成永假，**恰好并发那条红**
  （本次实测 1 红 / 6 绿）—— 顺序请求由入口预检拦住，只有并发能证明事务真的在裁决。

## 代码入口回指

- `relay/src/accounts/config.ts` 的 `registration.maxAccounts`。
- `relay/src/accounts/db.ts` 的 `RegistrationFullError` 与 `createUser`（事务）。
- `relay/src/accounts/face.ts` 的 `registrationFull()`、`/api/auth/config`、
  `/api/auth/email-code`、`/api/auth/register`。
- `relay/src/accounts/config-write.ts` 的 `setRegistrationInConfig`。
- `relay/src/admin/routes.ts` 的 `AdminStateView.auth`、`AdminOps/AdminApi.setRegistration`
  与 `/admin/api/registration`；`relay/src/admin/page.ts` 的注册卡与名额输入；
  `relay/src/ui/auth-page.ts` 的 closed / full 两档置灰。
- 现状：`docs/subsystems/relay-accounts.md` §2 / §4.1 / §5 / §8 / §9。
