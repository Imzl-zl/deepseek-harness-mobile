/**
 * 管理台错误码 → 人话。
 *
 * ## 为什么单独一张表
 *
 * 2026-11-06 真机：把某个账号设成管理员后，面板上只剩这一个管理员，于是降级被
 * 服务端 409 拒（`server.ts` 的 `last-admin`），而页面把 `data.error` **原样**
 * 弹出来 —— 用户看到的是 `last-admin`，不是「至少要保留一个管理员」。
 *
 * 错误码是**协议细节**，不是文案。所有给操作者看的失败都必须经过这里；
 * 页面只拿 `adminErrorText()` 的结果去 toast。
 *
 * ## 覆盖范围由测试守着
 *
 * `tests/admin-errors.test.ts` 会扫 `admin/routes.ts` 与 `server.ts` 里所有
 * `error: '…'` 字面量，任何一个码没进这张表就红 —— 新加端点时不会漏翻译。
 * 表里多出来的码（别处复用）不影响覆盖断言。
 *
 * Note: 为什么翻译在页面而不是服务端、为什么最后一个管理员要提前禁用 —— 见
 * `.agents/notes/implemented/2026-11-06-panel-detail-feedback.md`
 */

/** 已知错误码的中文文案。键是服务端 `error` 字段的原值。 */
export const ADMIN_ERROR_TEXT: Readonly<Record<string, string>> = {
  'accounts-not-wired': '这个中转没有开账号模式。',
  'admin-ops-not-wired': '管理操作没有接上（装配问题）。',
  'auto-enroll-full': '自动签发的令牌名额已满。',
  'bad-request': '请求格式不对。',
  'bytes-invalid': '用量必须是正整数字节。',
  'channel-not-found': '这条通道已经不存在了。',
  'code-invalid': '验证码不对或已过期。',
  'connector-auth-required': '需要先配置连接器认证。',
  'connector-limit': '这个账号的电脑数已达到上限。',
  'connector-not-found': '这台电脑不在线或不存在。',
  'connectorId-invalid': '电脑 id 不合法。',
  'csrf': '页面已过期，请刷新后重试。',
  'device-limit': '设备数量已达到上限。',
  'deviceId-invalid': '设备 id 不合法。',
  'domains-invalid': '邮箱域名列表不合法。',
  'email-invalid': '邮箱格式不对。',
  'email-taken': '这个邮箱已经注册过。',
  'enroll-failed': '自动签发令牌失败。',
  'from-invalid': '发件人地址不合法。',
  'host-invalid': 'SMTP 主机不能为空。',
  'id-invalid': 'id 不合法。',
  'internal': '中转内部出错，稍后再试。',
  'last-admin': '至少要保留一个管理员。',
  'limit-invalid': '名额上限不合法。',
  'locked-out': '尝试次数太多，稍后再试。',
  'mail-failed': '发信失败。',
  'mail-not-configured': '还没配置 SMTP。',
  'max-accounts-invalid': '注册名额上限不合法。',
  'max-connectors-invalid': '电脑数必须是 1–100 的整数。',
  'method-not-allowed': '这个操作不支持当前请求方法。',
  'mode-invalid': '模式不合法。',
  'name-invalid': '名字不合法（1–40 个字符）。',
  'not-found': '找不到这个对象。',
  'nothing-to-update': '没有要改的字段。',
  'pass-invalid': '密码不合法。',
  'pcId-required': '缺少电脑 id。',
  'persist-failed': '写入配置失败，改动没有保存。',
  'port-invalid': '端口必须是 1–65535 的整数。',
  'quota-invalid': '额度不合法。',
  'rate-limited': '操作太频繁，稍后再试。',
  'registration-full': '注册名额已满。',
  'revoke-first': '请先停用，再删除。',
  'role-invalid': '角色不合法。',
  'status-invalid': '状态不合法。',
  'subject-invalid': '额度主体不合法。',
  'tls-required': 'SMTP 必须开 TLS 或 STARTTLS。',
  'token-exists': '这个 id 已经有活跃令牌了。',
  'token-not-found': '找不到这张令牌。',
  'unauthorized': '登录已失效，请重新登录。',
  'unknown-subject': '不认识的额度主体。',
  'user-not-found': '找不到这个账号。',
}

/**
 * 把服务端应答里的 `error` 翻成一句人话。
 *
 * 空/非字符串 = 没有错误码（例如桥接层只回了 HTTP 状态）→ 只说状态。
 * 未知码**不假装认识**：人话打头，码放括号里当诊断信息，方便报障时对照日志。
 */
export function adminErrorText(code: unknown, status: number): string {
  if (typeof code !== 'string' || code === '') return `操作失败（HTTP ${status}）`
  const text = ADMIN_ERROR_TEXT[code]
  if (text !== undefined) return text
  return `操作失败；错误码 ${code}（HTTP ${status}）`
}
