/**
 * 管理面页面：**单文件、内联、无外链**（中转没有构建步骤，见 `relay/Dockerfile`）。
 *
 * ## 它是一套独立产品的控制台，不是宿主的插件页
 *
 * 中转是独立服务（`node src/main.ts`），与 DSH 的 UI 没有共享运行时、也不该借它的
 * 视觉 token。所以这套配色与排版是**自成一体的**：深色海军底 + 青绿强调色，
 * 左边一列分区导航（概览 / 用户 / 连接器 / 通道 / 用量 / 令牌 / 动态），右边是内容区。
 * 跟随系统亮暗（两套变量），图标是内联 SVG，没有任何外部资源。
 *
 * ## 两种进入方式
 *
 * 1. **管理员账号会话**：先在 `/login` 登录，再打开 `/admin` 自动识别（cookie + CSRF）。
 * 2. **break-glass 令牌**：没有账号模式或会话失效时，粘贴 `--issue-admin` 签发的令牌。
 *
 * 数据接口两种都认；写操作在会话模式下要带 `X-CSRF-Token`。
 *
 * 账号模式的用户、额度与电脑归属在「用户」分区；没有 `auth` 段时该分区显示未启用。
 *
 * ## 曲线是真数据
 *
 * 概览里那条 60 分钟曲线来自 `metering.traffic()` —— 服务端按分钟累计的真实转发
 * 字节（60 个整数，滚动窗口），不是抽样也不是估算。
 *
 * ## 凭据怎么带
 *
 * 会话走 HttpOnly cookie；令牌模式存 `sessionStorage`，每次 `fetch` 放进
 * `Authorization` 头。页面没有外链脚本可读它。
 *
 * Note: 为什么轮询而不是 WS/SSE、为什么独立凭据 —— 见
 * `.agents/notes/implemented/2026-10-30-relay-admin-panel.md`；账号与首连绑定见
 * `.agents/notes/implemented/2026-11-02-relay-accounts-and-connector-binding.md`。
 */
export const ADMIN_PAGE = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DSH 中转 · 控制台</title>
<style>
:root{
  --bg:#0a0d12; --panel:#10141b; --panel2:#151a23; --line:#1e2530; --line2:#2a3341;
  --ink:#e9eef6; --ink2:#b7c1cf; --ink3:#8592a6; --cap:#68758a;
  --accent:#2dd4bf; --accent-ink:#06231f; --accent-soft:rgba(45,212,191,.12);
  --ok:#34d399; --warn:#fbbf24; --bad:#fb7185;
  --shadow:0 18px 40px rgba(0,0,0,.35);
}
@media (prefers-color-scheme:light){
  :root{
    --bg:#f5f7fa; --panel:#ffffff; --panel2:#f0f3f7; --line:#e4e9f0; --line2:#cbd5e1;
    --ink:#0f172a; --ink2:#334155; --ink3:#64748b; --cap:#94a3b8;
    --accent:#0d9488; --accent-ink:#ffffff; --accent-soft:rgba(13,148,136,.10);
    --ok:#059669; --warn:#d97706; --bad:#e11d48;
    --shadow:0 10px 30px rgba(15,23,42,.08);
  }
}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--ink);
  font:14px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans SC",sans-serif;
  -webkit-font-smoothing:antialiased}
button{font:inherit;color:inherit;cursor:pointer;background:none;border:0}
input{font:inherit}
[hidden]{display:none!important}
a{color:inherit;text-decoration:none}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:6px}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px}
.num{font-variant-numeric:tabular-nums}
.cap{font-size:12px;color:var(--cap)}

/* ---------------- 登录 ---------------- */
.login{min-height:100%;display:grid;place-items:center;padding:24px;
  background:
    radial-gradient(760px 420px at 18% 0%,var(--accent-soft),transparent 70%),
    radial-gradient(600px 360px at 92% 108%,rgba(124,140,255,.12),transparent 70%),
    var(--bg)}
.login-card{width:min(400px,100%);background:var(--panel);border:1px solid var(--line);
  border-radius:18px;padding:32px 30px 26px;box-shadow:var(--shadow)}
.mark{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;
  background:var(--accent-soft);border:1px solid color-mix(in srgb,var(--accent) 35%,transparent)}
.mark svg{width:22px;height:22px;stroke:var(--accent)}
.login-card h1{font-size:20px;margin:18px 0 6px;letter-spacing:.2px;font-weight:660}
.login-card .sub{margin:0 0 22px;color:var(--cap);font-size:13px}
.field{display:block;margin:0 0 16px}
.field span{display:block;font-size:12px;color:var(--ink3);margin:0 0 7px}
.field input{width:100%;padding:11px 13px;border:1px solid var(--line2);border-radius:10px;
  background:var(--bg);color:var(--ink);outline:none;transition:border-color .12s,box-shadow .12s}
.field input::placeholder{color:var(--cap)}
.field input:focus{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
.primary{width:100%;padding:11px 13px;border-radius:10px;background:var(--accent);
  color:var(--accent-ink);font-weight:650;transition:filter .12s}
.primary:hover{filter:brightness(1.05)}
.error{margin:14px 0 0;padding:9px 11px;border-radius:9px;font-size:13px;
  background:color-mix(in srgb,var(--bad) 14%,transparent);
  border:1px solid color-mix(in srgb,var(--bad) 35%,transparent);color:var(--bad)}
.hint{margin:18px 0 0;color:var(--cap);font-size:12px;line-height:1.7}
.hint code{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11.5px;
  background:var(--panel2);border:1px solid var(--line);border-radius:5px;padding:1px 5px}

/* ---------------- 控制台骨架 ---------------- */
.app{display:flex;min-height:100%}
.side{width:232px;flex:none;display:flex;flex-direction:column;gap:18px;
  padding:20px 14px;background:var(--panel);border-right:1px solid var(--line);
  position:sticky;top:0;height:100vh}
.brand{display:flex;align-items:center;gap:10px;padding:0 6px}
.brand .mark{width:30px;height:30px;border-radius:9px}
.brand .mark svg{width:18px;height:18px}
.brand b{display:block;font-size:14px;letter-spacing:.2px}
.brand span{display:block;font-size:11px;color:var(--cap);letter-spacing:.06em;text-transform:uppercase}
nav{display:flex;flex-direction:column;gap:2px}
nav a{display:flex;align-items:center;gap:10px;padding:8px 10px;border-radius:9px;
  color:var(--ink2);font-size:13.5px;transition:background .12s,color .12s}
nav a:hover{background:var(--panel2)}
nav a.active{background:var(--accent-soft);color:var(--accent);font-weight:600}
nav em{margin-left:auto;font-style:normal;font-size:11px;color:var(--cap);
  font-variant-numeric:tabular-nums}
.sidefoot{margin-top:auto;display:flex;flex-direction:column;gap:8px;padding:0 6px}
.pill{display:inline-flex;align-items:center;gap:7px;height:26px;padding:0 10px;border-radius:999px;
  border:1px solid var(--line2);background:var(--panel2);font-size:11.5px;color:var(--ink3);
  align-self:flex-start}
.dot{width:7px;height:7px;border-radius:50%;background:var(--cap);flex:none}
.pill.ok .dot{background:var(--ok);box-shadow:0 0 0 3px color-mix(in srgb,var(--ok) 18%,transparent)}
.pill.bad .dot{background:var(--bad);box-shadow:0 0 0 3px color-mix(in srgb,var(--bad) 18%,transparent)}
.sidefoot .cap{font-size:11px;line-height:1.6}

.main{flex:1;min-width:0;display:flex;flex-direction:column}
.topbar{position:sticky;top:0;z-index:9;display:flex;align-items:center;gap:12px;
  padding:16px 24px;background:color-mix(in srgb,var(--bg) 86%,transparent);
  backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.topbar h1{margin:0;font-size:17px;font-weight:650;letter-spacing:.2px}
.topbar p{margin:2px 0 0;font-size:12px;color:var(--cap)}
.grow{flex:1}
.ghost{height:30px;padding:0 12px;border:1px solid var(--line2);border-radius:9px;
  font-size:12.5px;color:var(--ink2);background:var(--panel);
  transition:border-color .12s,color .12s}
.ghost:hover{border-color:var(--accent);color:var(--accent)}
a.ghost{display:inline-flex;align-items:center;text-decoration:none}
.content{padding:24px;max-width:1180px;width:100%;margin:0 auto;display:flex;
  flex-direction:column;gap:16px}

/* ---------------- 组件 ---------------- */
.kpis{display:grid;gap:14px;grid-template-columns:repeat(4,minmax(0,1fr))}
.kpi{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:14px 16px}
.kpi .v{font-size:26px;font-weight:660;letter-spacing:.2px;font-variant-numeric:tabular-nums}
.kpi .k{margin-top:2px;font-size:12px;color:var(--cap)}
.kpi.accent .v{color:var(--accent)}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;min-width:0;overflow:hidden}
.card > header{display:flex;align-items:baseline;gap:10px;padding:15px 18px 10px}
.card h2{margin:0;font-size:12.5px;font-weight:600;color:var(--ink3);letter-spacing:.05em}
.card .meta{margin-left:auto;font-size:11.5px;color:var(--cap);font-variant-numeric:tabular-nums}
.card .body{padding:0 18px 16px}
.chart{padding:2px 0 0}
.spark{width:100%;height:96px;display:block}
.spark .line{fill:none;stroke:var(--accent);stroke-width:2;vector-effect:non-scaling-stroke;
  stroke-linejoin:round;stroke-linecap:round}
.spark .area{fill:color-mix(in srgb,var(--accent) 16%,transparent);stroke:none}
.chart-foot{display:flex;gap:16px;margin-top:8px;font-size:12px;color:var(--cap)}
.chart-foot b{color:var(--ink2);font-weight:600;font-variant-numeric:tabular-nums}

table{width:100%;border-collapse:collapse}
th{font-size:11px;font-weight:500;letter-spacing:.06em;color:var(--cap);text-align:left;
  padding:0 10px 8px;border-bottom:1px solid var(--line);white-space:nowrap}
td{padding:10px;border-bottom:1px solid var(--line);white-space:nowrap;color:var(--ink2)}
tbody tr:last-child td{border-bottom:0}
tbody tr{transition:background .12s}
tbody tr:hover td{background:var(--panel2)}
th.r,td.r{text-align:right}
td.id{color:var(--ink)}
.empty{padding:28px 10px;text-align:center;color:var(--cap);font-size:12.5px}
.bar{display:inline-block;vertical-align:middle;width:92px;height:4px;border-radius:999px;
  background:var(--line2);overflow:hidden}
.bar i{display:block;height:100%;background:var(--accent)}
.bar i.warn{background:var(--warn)}
.bar i.bad{background:var(--bad)}
.btn{height:26px;padding:0 10px;border:1px solid var(--line2);border-radius:7px;font-size:12px;
  color:var(--ink2);background:transparent;transition:border-color .12s,color .12s,background .12s}
.btn:hover{border-color:var(--accent);color:var(--accent);background:var(--accent-soft)}
.btn.danger:hover{border-color:var(--bad);color:var(--bad);
  background:color-mix(in srgb,var(--bad) 12%,transparent)}
.btn + .btn{margin-left:6px}
.tag{display:inline-flex;align-items:center;gap:6px;height:22px;padding:0 9px;border-radius:999px;
  font-size:11.5px;border:1px solid var(--line2);color:var(--ink3)}
.tag.ok{color:var(--ok);border-color:color-mix(in srgb,var(--ok) 38%,transparent);
  background:color-mix(in srgb,var(--ok) 10%,transparent)}
.tag.bad{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 38%,transparent);
  background:color-mix(in srgb,var(--bad) 10%,transparent)}
.two{display:grid;gap:16px;grid-template-columns:repeat(2,minmax(0,1fr))}
.kv{display:flex;flex-direction:column;gap:8px;font-size:13px;color:var(--ink2)}
.kv .row{display:flex;gap:10px}
.kv .row span:first-child{color:var(--cap);min-width:64px}
.hintline{margin:10px 0 0;font-size:12px;color:var(--cap);line-height:1.6}
@media (max-width:1080px){ .kpis{grid-template-columns:repeat(2,minmax(0,1fr))} .two{grid-template-columns:1fr} }
@media (max-width:860px){
  .app{flex-direction:column}
  .side{width:auto;height:auto;position:static;flex-direction:row;align-items:center;
    gap:12px;padding:10px 14px;overflow-x:auto}
  .brand span{display:none}
  nav{flex-direction:row;gap:4px}
  nav a{padding:6px 9px;font-size:13px}
  nav em{display:none}
  .sidefoot{display:none}
  .topbar{padding:12px 14px}
  .content{padding:14px}
  .card .body{overflow-x:auto}
}
@media (prefers-reduced-motion:reduce){ *{transition:none!important} }

/* ---------- editorial skin（覆盖上面的旧 token） ---------- */
:root{
  --display:Georgia,"Times New Roman","Songti SC","Noto Serif SC",serif;
  --mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  --bg:#f4f1ea; --panel:#fffdf8; --panel2:#ebe6db; --line:#ddd6c8; --line2:#c6bdab;
  --ink:#171614; --ink2:#3d3932; --ink3:#6d675c; --cap:#8b8477;
  --accent:#e8451f; --accent-ink:#fff8f2; --accent-soft:rgba(232,69,31,.10);
  --ok:#1f7a4d; --warn:#a86a00; --bad:#b3261e;
  --shadow:none;
}
@media (prefers-color-scheme:dark){:root{
  --bg:#121110; --panel:#1a1816; --panel2:#231f1c; --line:#332f2a; --line2:#4a443c;
  --ink:#f3eee4; --ink2:#d8d0c2; --ink3:#a69d8e; --cap:#8a8173;
  --accent:#ff5a2f; --accent-ink:#1a0c08; --accent-soft:rgba(255,90,47,.12);
  --ok:#5bd39a; --warn:#e0a33a; --bad:#ff7a6b;
}}
body{background:var(--bg);color:var(--ink);font:14px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans SC",sans-serif}
.login{background:var(--bg);padding:24px}
.login-card{width:min(380px,100%);background:transparent;border:0;border-top:1px solid var(--line2);
  border-radius:0;padding:32px 0 0;box-shadow:none}
.login-card h1{font-family:var(--display);font-size:34px;font-weight:500;margin:20px 0 6px}
.login-card .sub{font-size:10px;letter-spacing:.14em;text-transform:uppercase;color:var(--cap);margin:0 0 24px}
.login-card .mark{background:var(--accent);border-color:var(--accent)}
.login-card .mark svg{stroke:var(--accent-ink)}
.login-card input{width:100%;height:44px;border:0;border-bottom:1px solid var(--line2);border-radius:0;
  background:transparent;color:var(--ink);font:inherit;font-size:15px;outline:none}
.login-card input:focus{border-color:var(--accent);box-shadow:none}
.login-card .primary{width:100%;height:42px;background:var(--accent);border:1px solid var(--accent);
  border-radius:0;color:var(--accent-ink);font-size:10.5px;letter-spacing:.1em;text-transform:uppercase}
.login-card .hint{color:var(--cap);font-size:11.5px}
.app{background:var(--bg)}
.side{width:240px;background:var(--panel);border-right:1px solid var(--line);padding:28px 20px}
.brand b{font-family:var(--display);font-size:19px;font-weight:500;letter-spacing:-.01em}
.brand span{font-size:9px;letter-spacing:.18em;text-transform:uppercase;color:var(--cap)}
.brand .mark{background:var(--accent);border-color:var(--accent)}
.brand .mark svg{stroke:var(--accent-ink)}
nav{margin-top:26px;counter-reset:nav}
nav a{display:flex;align-items:center;gap:12px;padding:10px 0;border-top:1px solid var(--line);
  border-radius:0;color:var(--ink3);font-size:13px}
nav a:before{counter-increment:nav;content:counter(nav,decimal-leading-zero);width:18px;
  font-family:var(--mono);font-size:9.5px;color:var(--cap)}
nav a:last-child{border-bottom:1px solid var(--line)}
nav a:hover{background:transparent;color:var(--ink)}
nav a.active{background:transparent;color:var(--accent);font-weight:600}
nav a.active:before{color:var(--accent)}
nav em{font-family:var(--mono);font-size:10px;color:var(--cap)}
.sidefoot{border-top:1px solid var(--line);padding-top:16px}
.pill{height:24px;border-radius:0;border:1px solid var(--line2);background:transparent;
  font-size:9px;letter-spacing:.08em;text-transform:uppercase;color:var(--ink3)}
.topbar{padding:32px 40px 20px;background:var(--bg);border-bottom:1px solid var(--line);backdrop-filter:none}
.topbar h1{font-family:var(--display);font-size:40px;font-weight:500;line-height:1;letter-spacing:-.02em}
.topbar p{font-size:9.5px;letter-spacing:.14em;text-transform:uppercase;color:var(--cap)}
.ghost{height:32px;border:1px solid var(--line2);border-radius:0;background:transparent;
  font-size:10px;letter-spacing:.08em;text-transform:uppercase;color:var(--ink2)}
.ghost:hover{background:var(--ink);border-color:var(--ink);color:var(--panel)}
.content{padding:28px 40px 64px;max-width:1180px;gap:24px}
.kpis{grid-template-columns:repeat(4,minmax(0,1fr));gap:0;border-top:1px solid var(--line);
  border-bottom:1px solid var(--line)}
.kpi{background:transparent;border:0;border-right:1px solid var(--line);border-radius:0;padding:20px}
.kpi:last-child{border-right:0}
.kpi .v{font-family:var(--display);font-size:42px;font-weight:500;line-height:1}
.kpi .k{font-size:9.5px;letter-spacing:.12em;text-transform:uppercase;color:var(--cap)}
.card{background:transparent;border:0;border-top:1px solid var(--line);border-radius:0;
  box-shadow:none;overflow:visible}
.card > header{padding:16px 0 10px}
.card h2{font-size:10px;letter-spacing:.16em;text-transform:uppercase;color:var(--cap)}
.card .body{padding:0 0 12px}
th{font-size:9px;letter-spacing:.14em;text-transform:uppercase;color:var(--cap);padding:0 8px 8px}
td{padding:12px 8px;border-bottom:1px solid var(--line);font-size:13px}
tbody tr:hover td{background:var(--accent-soft)}
.btn{height:30px;border:1px solid var(--line2);border-radius:0;background:transparent;
  font-size:9.5px;letter-spacing:.08em;text-transform:uppercase}
.btn:hover{background:var(--ink);border-color:var(--ink);color:var(--panel)}
.btn.danger{border-color:var(--bad);color:var(--bad)}
.btn.danger:hover{background:var(--bad);color:var(--panel)}
.tag{border-radius:0;font-size:9px;letter-spacing:.08em;text-transform:uppercase;height:20px;
  padding:0 7px;background:transparent}
.bar{height:2px;border-radius:0}
.spark .line{stroke:var(--accent)}
.spark .area{fill:var(--accent-soft)}
.two{gap:24px}
.kv .row{padding:9px 0;border-bottom:1px solid var(--line)}
.kv .row:last-child{border-bottom:0}
.kv .row span:first-child{font-size:9.5px;letter-spacing:.12em;text-transform:uppercase;color:var(--cap)}
.hintline{font-size:11.5px;color:var(--cap)}
a.ghost{display:inline-flex;align-items:center;text-decoration:none}
a.btn{display:inline-flex;align-items:center;text-decoration:none}
.settings-grid{display:grid;grid-template-columns:1fr 1fr;gap:0 28px}
.settings-grid .full{grid-column:1/-1}
.field{display:block;margin:0 0 18px}
.field > span{display:block;font-size:10px;letter-spacing:.14em;text-transform:uppercase;
  color:var(--cap);margin:0 0 6px}
.input{width:100%;height:42px;padding:0;border:0;border-bottom:1px solid var(--line2);border-radius:0;
  background:transparent;color:var(--ink);font:inherit;font-size:14px;outline:none}
.field input.input{width:100%;height:42px;padding:0;border:0;border-bottom:1px solid var(--line2);
  border-radius:0;background:transparent;color:var(--ink);font:inherit;font-size:14px;outline:none}
.input:focus,.field input.input:focus{border-color:var(--accent);box-shadow:none}
.check{display:flex;gap:8px;align-items:center;font-size:12px;color:var(--ink3);margin:0 0 18px}
.check input{accent-color:var(--accent)}
.seg{display:inline-flex;border:1px solid var(--line2)}
.seg button{height:34px;padding:0 16px;border:0;border-right:1px solid var(--line2);
  background:transparent;color:var(--ink3);font-size:10px;letter-spacing:.08em;text-transform:uppercase}
.seg button:last-child{border-right:0}
.seg button.on{background:var(--ink);color:var(--panel)}
@media (max-width:1080px){.kpis{grid-template-columns:repeat(2,minmax(0,1fr))}.two{grid-template-columns:1fr}.settings-grid{grid-template-columns:1fr}}
@media (max-width:860px){
  .side{width:auto;flex-direction:row;align-items:center;gap:10px;padding:10px 12px;overflow-x:auto;flex-wrap:nowrap}
  .brand{flex:none}
  .brand span{display:none}
  nav{flex-direction:row;flex-wrap:nowrap;margin-top:0;gap:0}
  nav a{border-top:0;border-bottom:2px solid transparent;padding:8px 10px;white-space:nowrap}
  nav a:before,nav em{display:none}
  nav a:last-child{border-bottom:2px solid transparent}
  .sidefoot{display:none}
  .topbar{position:static;padding:16px}
  .topbar h1{font-size:30px}
  .content{padding:14px}
}
</style>
</head>
<body>

<div id="login" class="login">
  <form id="login-form" class="login-card" autocomplete="on">
    <div class="mark">
      <svg viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round">
        <rect x="3" y="4" width="6" height="6" rx="1.6"/><rect x="15" y="14" width="6" height="6" rx="1.6"/>
        <path d="M9 7h4a2 2 0 0 1 2 2v1"/><path d="M15 17h-4a2 2 0 0 1-2-2v-1"/>
      </svg>
    </div>
    <h1>DSH 中转</h1>
    <label class="field">
      <span>管理令牌</span>
      <input id="token" type="password" name="token" autocomplete="current-password"
             placeholder="令牌" spellcheck="false">
    </label>
    <button id="login-btn" class="primary" type="submit">登录</button>
    <p id="login-error" class="error" hidden></p>
    <p style="margin:14px 0 0;font-size:12px"><a href="/login" style="color:var(--cap)">账号登录</a></p>
  </form>
</div>

<div id="app" class="app" hidden>
  <aside class="side">
    <div class="brand">
      <div class="mark">
        <svg viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round">
          <rect x="3" y="4" width="6" height="6" rx="1.6"/><rect x="15" y="14" width="6" height="6" rx="1.6"/>
          <path d="M9 7h4a2 2 0 0 1 2 2v1"/><path d="M15 17h-4a2 2 0 0 1-2-2v-1"/>
        </svg>
      </div>
      <div><b>DSH 中转</b><span>relay console</span></div>
    </div>
    <nav id="nav">
      <a href="#/overview" data-view="overview">概览<em id="n-overview"></em></a>
      <a href="#/users" data-view="users">用户<em id="n-users"></em></a>
      <a href="#/connectors" data-view="connectors">连接器<em id="n-connectors"></em></a>
      <a href="#/channels" data-view="channels">通道<em id="n-channels"></em></a>
      <a href="#/usage" data-view="usage">用量<em id="n-usage"></em></a>
      <a href="#/tokens" data-view="tokens">令牌<em id="n-tokens"></em></a>
      <a href="#/events" data-view="events">动态<em id="n-events"></em></a>
      <a href="#/settings" data-view="settings">设置</a>
    </nav>
    <div class="sidefoot">
      <span id="pill" class="pill"><i class="dot"></i><span id="pill-text">连接中…</span></span>
      <div class="cap" id="uptime">—</div>
    </div>
  </aside>
  <div class="main">
    <header class="topbar">
      <div>
        <h1 id="view-title">概览</h1>
        <p id="view-sub"></p>
      </div>
      <div class="grow"></div>
      <a id="to-console" class="ghost" href="/console">我的电脑</a>
      <button id="refresh" class="ghost" type="button">刷新</button>
      <button id="logout" class="ghost" type="button">退出</button>
    </header>
    <div class="content" id="view"></div>
  </div>
</div>

<script>
(function () {
  var TOKEN_KEY = 'dsh.admin.token'
  var NS = 'http://www.w3.org/2000/svg'
  var loginEl = document.getElementById('login')
  var appEl = document.getElementById('app')
  var tokenInput = document.getElementById('token')
  var errorEl = document.getElementById('login-error')
  var pill = document.getElementById('pill')
  var pillText = document.getElementById('pill-text')
  var viewEl = document.getElementById('view')
  var titleEl = document.getElementById('view-title')
  var subEl = document.getElementById('view-sub')
  var uptimeEl = document.getElementById('uptime')
  var timer = null
  var lastState = null
  var sessionMode = false

  var VIEWS = {
    overview: ['概览', '这台中转此刻在做什么'],
    users: ['用户', '账号、电脑归属与额度'],
    connectors: ['连接器', '已连上来的电脑（控制面）'],
    channels: ['通道', '正在转发的一对一连接'],
    usage: ['用量', '按账号看用量、额度与电脑/设备'],
    tokens: ['令牌', '谁能连这台中转'],
    events: ['动态', '最近发生在这台中转上的事（只记元数据）'],
    settings: ['设置', '注册与发信']
  }

  var EVENT_LABELS = {
    'connector.open': '电脑连上',
    'connector.close': '电脑断开',
    'connector.id-mismatch': '身份不一致',
    'connector.error': '控制面错误',
    'roster.applied': '名册更新',
    'roster.refused': '名册被拒',
    'ticket.issued': '换票',
    'ticket.rejected': '换票被拒',
    'channel.open': '通道建立',
    'channel.close': '通道关闭',
    'admission.rejected': '准入拒绝',
    'channel.error': '通道错误',
    'delivery.failed': '投递失败',
    'quota.rejected': '超限',
    'admin.action': '管理操作'
  }

  function describe(detail) {
    var parts = []
    if (detail.connectorId) parts.push(detail.connectorId)
    if (detail.deviceId) parts.push(detail.deviceId)
    if (detail.subject) parts.push(detail.subject)
    if (detail.action) parts.push(detail.action)
    if (detail.code) parts.push('关闭码 ' + detail.code)
    if (detail.reason) parts.push(detail.reason)
    if (detail.used !== undefined && detail.limit !== undefined) parts.push(bytes(detail.used) + ' / ' + bytes(detail.limit))
    else if (detail.bytes) parts.push(bytes(detail.bytes))
    if (detail.actor) parts.push('操作人 ' + detail.actor)
    return parts.join(' · ')
  }

  function viewOf() {
    var hash = (location.hash || '').replace('#/', '')
    return VIEWS[hash] ? hash : 'overview'
  }
  function token() { return sessionStorage.getItem(TOKEN_KEY) || '' }
  function csrf() {
    var match = document.cookie.match(/(?:^|; )dsh_relay_csrf=([^;]+)/)
    return match ? decodeURIComponent(match[1]) : ''
  }
  function headers() {
    if (sessionMode) return {}
    var value = token()
    return value === '' ? {} : { authorization: 'Bearer ' + value }
  }
  function el(tag, text, className) {
    var node = document.createElement(tag)
    if (text !== undefined) node.textContent = text
    if (className) node.className = className
    return node
  }
  function svgEl(tag, attrs) {
    var node = document.createElementNS(NS, tag)
    Object.keys(attrs).forEach(function (key) { node.setAttribute(key, attrs[key]) })
    return node
  }
  function btn(text, onClick, danger) {
    var node = el('button', text, 'btn' + (danger ? ' danger' : ''))
    node.type = 'button'
    node.addEventListener('click', onClick)
    return node
  }
  function table(headers2, rows, emptyText) {
    if (rows.length === 0) return el('div', emptyText || '暂无数据', 'empty')
    var table = el('table')
    var head = el('tr')
    headers2.forEach(function (name) {
      var numeric = typeof name === 'string' && name.charAt(0) === '#'
      head.appendChild(el('th', numeric ? name.slice(1) : name, numeric ? 'r' : ''))
    })
    var thead = el('thead'); thead.appendChild(head); table.appendChild(thead)
    var tbody = el('tbody')
    rows.forEach(function (cells) {
      var row = el('tr')
      cells.forEach(function (value, index) {
        var numeric = headers2[index] && headers2[index].charAt(0) === '#'
        var td = el('td', undefined, numeric ? 'r num' : '')
        if (headers2[index] === 'id') td.className = 'id mono'
        if (value instanceof Node) td.appendChild(value)
        else td.textContent = value
        row.appendChild(td)
      })
      tbody.appendChild(row)
    })
    table.appendChild(tbody)
    return table
  }
  function bytes(n) {
    if (typeof n !== 'number') return '—'
    if (n >= 1073741824) return (n / 1073741824).toFixed(1) + ' GB'
    if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB'
    if (n >= 1024) return (n / 1024).toFixed(1) + ' KB'
    return n + ' B'
  }
  /** 用量条：只在有上限时调用；满 100% 红、80% 黄。 */
  function usageBar(used, limit) {
    var bar = el('span', undefined, 'bar')
    var fill = el('i')
    var ratio = limit === null || limit <= 0 ? 0 : Math.min(100, Math.round(used * 100 / limit))
    fill.style.width = ratio + '%'
    if (limit !== null && used >= limit) fill.className = 'bad'
    else if (limit !== null && ratio >= 80) fill.className = 'warn'
    bar.appendChild(fill)
    return bar
  }
  function duration(ms) {
    var seconds = Math.max(0, Math.round(ms / 1000))
    if (seconds < 90) return seconds + ' 秒'
    if (seconds < 5400) return Math.round(seconds / 60) + ' 分'
    if (seconds < 172800) return Math.round(seconds / 3600) + ' 小时'
    return Math.round(seconds / 86400) + ' 天'
  }
  function ago(ts) { return duration(Date.now() - ts) + '前' }
  function setPill(state, text) {
    pill.className = 'pill' + (state === 'ok' ? ' ok' : state === 'bad' ? ' bad' : '')
    pillText.textContent = text
  }
  function post(path, body) {
    var requestHeaders = Object.assign({ 'content-type': 'application/json' }, headers())
    if (sessionMode) requestHeaders['x-csrf-token'] = csrf()
    return fetch(path, {
      method: 'POST',
      credentials: 'same-origin',
      headers: requestHeaders,
      body: JSON.stringify(body || {})
    }).then(function (response) {
      if (response.status === 401) { toLogin('登录已失效，请重新输入令牌'); return null }
      return response.json().catch(function () { return {} }).then(function (data) {
        if (!response.ok) { alert((data && data.error) || ('操作失败 HTTP ' + response.status)); return null }
        return data
      })
    }).catch(function () { toLogin('连不上中转'); return null })
  }

  function toLogin(message) {
    if (timer !== null) { clearInterval(timer); timer = null }
    appEl.hidden = true
    loginEl.hidden = false
    errorEl.textContent = message || ''
    errorEl.hidden = !message
    if (document.activeElement !== tokenInput) tokenInput.focus()
  }
  function toApp() {
    loginEl.hidden = true
    appEl.hidden = false
    if (timer === null) timer = setInterval(refresh, 2000)
  }
  function refresh(force) {
    fetch('/admin/api/state', { credentials: 'same-origin', headers: headers() }).then(function (response) {
      if (response.status === 401) {
        toLogin(sessionMode ? '账号会话已失效，请重新登录（或输入管理令牌）' : '令牌无效或已过期')
        return null
      }
      if (!response.ok) { setPill('bad', 'HTTP ' + response.status); return null }
      return response.json()
    }).then(function (state) {
      if (!state) return
      toApp()
      setPill('ok', '已连接')
      var first = lastState === null
      lastState = state
      // 设置页有未保存的输入：2 s 轮询不能把表单重画掉。保存成功后传 true 强制重画。
      if (first || force === true || viewOf() !== 'settings') render(state)
    }).catch(function () { setPill('bad', '连不上中转') })
  }

  function sparkline(values) {
    var width = 600
    var height = 90
    var max = Math.max.apply(null, values.concat([1]))
    var points = []
    for (var index = 0; index < values.length; index += 1) {
      var x = values.length === 1 ? 0 : index * width / (values.length - 1)
      var y = height - 3 - values[index] / max * (height - 8)
      points.push(x.toFixed(1) + ',' + y.toFixed(1))
    }
    var svg = svgEl('svg', { viewBox: '0 0 ' + width + ' ' + height, preserveAspectRatio: 'none', class: 'spark' })
    svg.appendChild(svgEl('path', { class: 'area', d: 'M0,' + height + ' L' + points.join(' L') + ' L' + width + ',' + height + ' Z' }))
    svg.appendChild(svgEl('polyline', { class: 'line', points: points.join(' ') }))
    return svg
  }

  function render(state) {
    var activeTokens = state.tokens.filter(function (row) { return !row.revokedAt }).length
    var view = viewOf()
    document.querySelectorAll('#nav a').forEach(function (link) {
      link.className = link.getAttribute('data-view') === view ? 'active' : ''
    })
    titleEl.textContent = VIEWS[view][0]
    subEl.textContent = VIEWS[view][1]
    uptimeEl.textContent = '运行 ' + duration(state.uptimeMs) + ' · 每 2 秒刷新'
    document.getElementById('n-overview').textContent = ''
    document.getElementById('n-users').textContent = String((state.users || []).length)
    document.getElementById('n-connectors').textContent = String(state.totals.connectors)
    document.getElementById('n-channels').textContent = String(state.totals.channels)
    document.getElementById('n-usage').textContent = state.auth
      ? String(state.users.length)
      : (state.quota ? String(state.quota.rows.length) : '')
    document.getElementById('n-tokens').textContent = String(activeTokens)
    document.getElementById('n-events').textContent = String(state.events.length)
    viewEl.textContent = ''

    if (view === 'users') {
      if (!state.auth) {
        var emptyCard = el('section', null, 'card')
        var emptyHead = el('header'); emptyHead.appendChild(el('h2', '账号模式未启用')); emptyCard.appendChild(emptyHead)
        var emptyBody = el('div', null, 'body')
        emptyBody.appendChild(el('div', '在 relay.config.json 里加 auth 段并重启，才会有用户。', 'empty'))
        emptyCard.appendChild(emptyBody)
        viewEl.appendChild(emptyCard)
        return
      }
      var userKpis = el('div', undefined, 'kpis')
      ;[
        ['账号数', state.users.length, ''],
        ['注册', state.auth.registration === 'open' ? '开放' : '关闭', ''],
        ['默认电脑数', state.auth.defaultMaxConnectors, ''],
        ['默认额度', state.auth.defaultQuotaBytes === null ? '不限' : bytes(state.auth.defaultQuotaBytes), '']
      ].forEach(function (item) {
        var box = el('div', undefined, 'kpi ' + item[2])
        box.appendChild(el('div', String(item[1]), 'v'))
        box.appendChild(el('div', item[0], 'k'))
        userKpis.appendChild(box)
      })
      viewEl.appendChild(userKpis)

      var usersCard = el('section', undefined, 'card')
      var usersHead = el('header')
      usersHead.appendChild(el('h2', '用户'))
      usersHead.appendChild(el('span', state.users.length + ' 个', 'meta'))
      usersCard.appendChild(usersHead)
      var usersBody = el('div', null, 'body')
      usersBody.appendChild(table(
        ['邮箱', '操作', '角色', '状态', '#电脑', '#在线', '#设备', '本月用量', '最近登录'],
        state.users.map(function (row) {
          var actions = el('div')
          actions.appendChild(btn(row.status === 'active' ? '停用' : '恢复', function () {
            if (row.status === 'active' && !confirm('停用 ' + row.email + '？它名下所有连接会立刻断开')) return
            post('/admin/api/users/status', {
              id: row.id,
              status: row.status === 'active' ? 'suspended' : 'active'
            }).then(refresh)
          }, row.status === 'active'))
          actions.appendChild(btn(row.role === 'admin' ? '降为用户' : '设为管理员', function () {
            post('/admin/api/users/role', {
              id: row.id,
              role: row.role === 'admin' ? 'user' : 'admin'
            }).then(refresh)
          }))
          actions.appendChild(btn('改电脑数', function () {
            var current = row.maxConnectors === null ? state.auth.defaultMaxConnectors : row.maxConnectors
            var next = prompt('这个账号最多几台电脑（1–100）', String(current))
            if (next === null) return
            var value = parseInt(next, 10)
            if (!isFinite(value)) { alert('要一个整数'); return }
            post('/admin/api/users/limits', { id: row.id, maxConnectors: value }).then(refresh)
          }))
          actions.appendChild(btn('改额度', function () {
            var current = row.quotaBytes === null ? '' : (row.quotaBytes / 1073741824).toFixed(2)
            var next = prompt('本月额度（GB）；留空 = 不限', current)
            if (next === null) return
            if (next.trim() === '') {
              post('/admin/api/users/limits', { id: row.id, quotaBytes: null }).then(refresh)
              return
            }
            var value = parseFloat(next)
            if (!isFinite(value) || value <= 0) { alert('要一个正数'); return }
            post('/admin/api/users/limits', { id: row.id, quotaBytes: Math.round(value * 1073741824) }).then(refresh)
          }))
          actions.appendChild(btn('重置', function () {
            if (!confirm('把 ' + row.email + ' 的本期用量归零？')) return
            post('/admin/api/quota/reset', { subject: 'user:' + row.id }).then(refresh)
          }))
          var usageCell = el('div')
          usageCell.appendChild(el('div',
            bytes(row.usedBytes) + (row.quotaBytes === null ? ' / 不限' : ' / ' + bytes(row.quotaBytes)),
            'num'))
          if (row.quotaBytes !== null) usageCell.appendChild(usageBar(row.usedBytes, row.quotaBytes))
          return [
            row.email,
            actions,
            row.role === 'admin' ? '管理员' : '用户',
            row.status === 'active' ? '正常' : '已停用',
            row.activeConnectors + ' / ' + row.connectors,
            String(row.online),
            String(row.devices),
            usageCell,
            row.lastLoginAt ? ago(row.lastLoginAt) : '—'
          ]
        }),
        '还没有账号'
      ))
      usersCard.appendChild(usersBody)
      viewEl.appendChild(usersCard)
      return
    }

    if (view === 'overview') {
      var kpis = el('div', undefined, 'kpis')
      ;[
        ['在线连接器', state.totals.connectors, ''],
        ['活跃通道', state.totals.channels, ''],
        ['名册行数', state.roster.devices, ''],
        ['有效令牌', activeTokens + ' / ' + state.tokens.length, 'accent']
      ].forEach(function (item) {
        var box = el('div', undefined, 'kpi ' + item[2])
        box.appendChild(el('div', String(item[1]), 'v'))
        box.appendChild(el('div', item[0], 'k'))
        kpis.appendChild(box)
      })
      viewEl.appendChild(kpis)

      var chartCard = el('section', undefined, 'card')
      var chartHead = el('header')
      chartHead.appendChild(el('h2', '近 60 分钟转发'))
      chartHead.appendChild(el('span', '共 ' + bytes(state.traffic.total), 'meta'))
      chartCard.appendChild(chartHead)
      var chartBody = el('div', undefined, 'body chart')
      chartBody.appendChild(sparkline(state.traffic.perMinute))
      var foot = el('div', undefined, 'chart-foot')
      var peak = Math.max.apply(null, state.traffic.perMinute.concat([0]))
      var peakLine = el('span'); peakLine.appendChild(document.createTextNode('峰值 ')); peakLine.appendChild(el('b', bytes(peak))); foot.appendChild(peakLine)
      var last = state.traffic.perMinute[state.traffic.perMinute.length - 1] || 0
      var lastLine = el('span'); lastLine.appendChild(document.createTextNode('这一分钟 ')); lastLine.appendChild(el('b', bytes(last))); foot.appendChild(lastLine)
      chartBody.appendChild(foot)
      chartCard.appendChild(chartBody)
      viewEl.appendChild(chartCard)

      var two = el('div', undefined, 'two')
      var online = el('section', undefined, 'card')
      var onlineHead = el('header'); onlineHead.appendChild(el('h2', '在线的电脑')); onlineHead.appendChild(el('span', String(state.totals.connectors), 'meta')); online.appendChild(onlineHead)
      var onlineBody = el('div', undefined, 'body')
      onlineBody.appendChild(table(['连接器', '#连接时长', '#最后心跳'], state.connectors.map(function (row) {
        return [row.connectorId, duration(Date.now() - row.since), ago(row.lastPongAt)]
      }), '还没有电脑连上来 — DSH 一开就会自己连'))
      online.appendChild(onlineBody)
      two.appendChild(online)

      var summary = el('section', undefined, 'card')
      var sumHead = el('header'); sumHead.appendChild(el('h2', '名册与令牌')); summary.appendChild(sumHead)
      var sumBody = el('div', undefined, 'body')
      var kv = el('div', undefined, 'kv')
      ;[
        ['名册', state.roster.devices + ' 行（有归属 ' + state.roster.bound + ' 行）'],
        ['每台电脑', Object.keys(state.roster.published).length === 0 ? '还没有报名册'
          : Object.keys(state.roster.published).map(function (id) { return id + ' ' + state.roster.published[id] + ' 行' }).join('，')],
        ['令牌', '有效 ' + activeTokens + ' / 共 ' + state.tokens.length],
        ['上限策略', state.quota ? (state.quota.enforce === 'cut' ? '超限即断开' : state.quota.enforce === 'block' ? '超限只拒新建' : '只记账') : '—']
      ].forEach(function (pair) {
        var row = el('div', undefined, 'row')
        row.appendChild(el('span', pair[0]))
        row.appendChild(el('span', pair[1]))
        kv.appendChild(row)
      })
      sumBody.appendChild(kv)
      summary.appendChild(sumBody)
      two.appendChild(summary)
      viewEl.appendChild(two)
      return
    }

    if (view === 'connectors') {
      var card = el('section', undefined, 'card')
      var head = el('header'); head.appendChild(el('h2', '在线连接器')); head.appendChild(el('span', '共 ' + state.totals.connectors + ' 台', 'meta')); card.appendChild(head)
      var body = el('div', undefined, 'body')
      body.appendChild(table(['连接器', '所属人', '#连接时长', '#最后心跳', '#通道', ''], state.connectors.map(function (row) {
        return [row.connectorId, row.owner || '—', duration(Date.now() - row.since), ago(row.lastPongAt), String(row.channels),
          btn('断开', function () {
            if (!confirm('断开连接器 ' + row.connectorId + '？它的通道会一起关掉')) return
            post('/admin/api/disconnect', { connectorId: row.connectorId }).then(refresh)
          }, true)]
      }), '还没有连接器连上来 — 电脑上的 DSH 一开就会自己连'))
      card.appendChild(body)
      viewEl.appendChild(card)
      return
    }

    if (view === 'channels') {
      var channels = el('section', undefined, 'card')
      var chHead = el('header'); chHead.appendChild(el('h2', '活跃通道')); chHead.appendChild(el('span', '共 ' + state.totals.channels + ' 条', 'meta')); channels.appendChild(chHead)
      var chBody = el('div', undefined, 'body')
      chBody.appendChild(table(['电脑', '手机', '用途', '#已转发', '#起于', ''], state.channels.map(function (row) {
        return [row.connectorId, row.deviceId, el('span', row.purpose === 'paired' ? '业务' : '配对', 'tag'), bytes(row.forwardedBytes), duration(Date.now() - row.startedAt),
          btn('断开', function () {
            if (!confirm('断开这条通道？')) return
            post('/admin/api/disconnect', { connectorId: row.connectorId, deviceId: row.deviceId }).then(refresh)
          }, true)]
      }), '没有正在使用的通道'))
      channels.appendChild(chBody)
      viewEl.appendChild(channels)
      return
    }

    if (view === 'usage') {
      if (state.auth) {
        var totalUsed = (state.quota ? state.quota.rows : []).reduce(function (sum, row) { return sum + row.used }, 0)
        var totalOnline = state.users.reduce(function (sum, row) { return sum + row.online }, 0)
        var totalDevices = state.users.reduce(function (sum, row) { return sum + row.devices }, 0)
        var usageKpis = el('div', undefined, 'kpis')
        ;[
          ['账号', state.users.length, ''],
          ['本月总用量', bytes(totalUsed), 'accent'],
          ['在线电脑', totalOnline, ''],
          ['已配对设备', totalDevices, '']
        ].forEach(function (item) {
          var box = el('div', undefined, 'kpi ' + item[2])
          box.appendChild(el('div', String(item[1]), 'v'))
          box.appendChild(el('div', item[0], 'k'))
          usageKpis.appendChild(box)
        })
        viewEl.appendChild(usageKpis)

        var userUsage = el('section', undefined, 'card')
        var usageHead = el('header')
        usageHead.appendChild(el('h2', '用户用量'))
        usageHead.appendChild(el('span', '按已用降序', 'meta'))
        userUsage.appendChild(usageHead)
        var usageBody = el('div', undefined, 'body')
        var sortedUsers = state.users.slice().sort(function (a, b) { return b.usedBytes - a.usedBytes })
        usageBody.appendChild(table(
          ['账号', '状态', '#电脑', '#在线', '#设备', '本月用量', '最近登录', ''],
          sortedUsers.map(function (row) {
            var usageCell = el('div')
            usageCell.appendChild(el('div',
              bytes(row.usedBytes) + (row.quotaBytes === null ? ' / 不限' : ' / ' + bytes(row.quotaBytes)),
              'num'))
            if (row.quotaBytes !== null) usageCell.appendChild(usageBar(row.usedBytes, row.quotaBytes))
            var actions = el('span')
            actions.appendChild(btn('改额度', function () {
              var current = row.quotaBytes === null ? '' : (row.quotaBytes / 1073741824).toFixed(2)
              var next = prompt('本月额度（GB）；留空 = 不限', current)
              if (next === null) return
              if (next.trim() === '') {
                post('/admin/api/users/limits', { id: row.id, quotaBytes: null }).then(refresh)
                return
              }
              var value = parseFloat(next)
              if (!isFinite(value) || value <= 0) { alert('要一个正数'); return }
              post('/admin/api/users/limits', { id: row.id, quotaBytes: Math.round(value * 1073741824) }).then(refresh)
            }))
            actions.appendChild(btn('重置', function () {
              if (!confirm('把 ' + row.email + ' 的本期用量归零？')) return
              post('/admin/api/quota/reset', { subject: 'user:' + row.id }).then(refresh)
            }))
            return [
              row.email,
              row.status === 'active' ? '正常' : '已停用',
              String(row.activeConnectors),
              String(row.online),
              String(row.devices),
              usageCell,
              row.lastLoginAt ? ago(row.lastLoginAt) : '—',
              actions
            ]
          }),
          '还没有账号'
        ))
        userUsage.appendChild(usageBody)
        viewEl.appendChild(userUsage)

        var accountSubjects = {}
        state.users.forEach(function (user) { accountSubjects['user:' + user.id] = true })
        var legacyRows = (state.quota ? state.quota.rows : []).filter(function (row) {
          return accountSubjects[row.subject] !== true
        })
        if (legacyRows.length > 0) {
          var legacyCard = el('section', undefined, 'card')
          var legacyHead = el('header')
          legacyHead.appendChild(el('h2', '未归属账号的主体'))
          legacyCard.appendChild(legacyHead)
          var legacyBody = el('div', undefined, 'body')
          legacyBody.appendChild(table(['主体', '已用', '上限', ''], legacyRows.map(function (row) {
            var used = el('span', bytes(row.used), 'num')
            if (row.limit !== null && row.used >= row.limit) used.style.color = 'var(--bad)'
            var limitCell = el('span')
            limitCell.appendChild(el('span', row.limit === null ? '不限制' : bytes(row.limit)))
            if (row.limit !== null) {
              limitCell.appendChild(document.createTextNode(' '))
              limitCell.appendChild(usageBar(row.used, row.limit))
            }
            var actions = el('span')
            actions.appendChild(btn(row.limit === null ? '设上限' : '改上限', function () {
              var next = prompt('上限（字节）；留空 = 取消上限', row.limit === null ? '' : String(row.limit))
              if (next === null) return
              var trimmed = next.trim()
              if (trimmed === '') { post('/admin/api/quota', { subject: row.subject, bytes: null }).then(refresh); return }
              var value = parseInt(trimmed, 10)
              if (!isFinite(value) || value <= 0) { alert('要一个正整数（字节），或留空取消'); return }
              post('/admin/api/quota', { subject: row.subject, bytes: value }).then(refresh)
            }))
            actions.appendChild(btn('重置', function () {
              if (!confirm('把 ' + row.subject + ' 的本期用量归零？')) return
              post('/admin/api/quota/reset', { subject: row.subject }).then(refresh)
            }))
            return [row.subject, used, limitCell, actions]
          }), '没有未归属的用量'))
          legacyCard.appendChild(legacyBody)
          viewEl.appendChild(legacyCard)
        }
        return
      }

      var usage = el('section', undefined, 'card')
      var uHead = el('header'); uHead.appendChild(el('h2', '用量与上限')); uHead.appendChild(el('span', state.quota ? (state.quota.period === 'month' ? '按月' : state.quota.period === 'day' ? '按天' : '不重置') : '', 'meta')); usage.appendChild(uHead)
      var uBody = el('div', undefined, 'body')
      var rows = state.quota ? state.quota.rows : []
      uBody.appendChild(table(['主体', '已用', '上限', ''], rows.map(function (row) {
        var used = el('span', bytes(row.used), 'num')
        if (row.limit !== null && row.used >= row.limit) used.style.color = 'var(--bad)'
        var limitCell = el('span')
        limitCell.appendChild(el('span', row.limit === null ? '不限制' : bytes(row.limit)))
        if (row.limit !== null) {
          limitCell.appendChild(document.createTextNode(' '))
          limitCell.appendChild(usageBar(row.used, row.limit))
        }
        var actions = el('span')
        actions.appendChild(btn(row.limit === null ? '设上限' : '改上限', function () {
          var next = prompt('上限（字节）；留空 = 取消上限', row.limit === null ? '' : String(row.limit))
          if (next === null) return
          var trimmed = next.trim()
          if (trimmed === '') { post('/admin/api/quota', { subject: row.subject, bytes: null }).then(refresh); return }
          var value = parseInt(trimmed, 10)
          if (!isFinite(value) || value <= 0) { alert('要一个正整数（字节），或留空取消'); return }
          post('/admin/api/quota', { subject: row.subject, bytes: value }).then(refresh)
        }))
        actions.appendChild(btn('重置', function () {
          if (!confirm('把 ' + row.subject + ' 的本期用量归零？')) return
          post('/admin/api/quota/reset', { subject: row.subject }).then(refresh)
        }))
        return [row.subject, used, limitCell, actions]
      }), '还没有用量'))
      usage.appendChild(uBody)
      viewEl.appendChild(usage)
      return
    }

    if (view === 'settings') {
      if (!state.auth) {
        var noAuth = el('section', undefined, 'card')
        var noHead = el('header'); noHead.appendChild(el('h2', '账号模式未启用')); noAuth.appendChild(noHead)
        viewEl.appendChild(noAuth); return
      }
      var authState = state.auth
      var fieldOf = function (label, value, type, placeholder) {
        var wrap = el('label', null, 'field')
        wrap.appendChild(el('span', label))
        var input = el('input', null, 'input')
        input.type = type || 'text'
        input.value = value === undefined || value === null ? '' : String(value)
        if (placeholder) input.placeholder = placeholder
        wrap.appendChild(input)
        return { wrap: wrap, input: input }
      }
      var checkOf = function (label, checked) {
        var wrap = el('label', null, 'check')
        var input = el('input'); input.type = 'checkbox'; input.checked = checked
        wrap.appendChild(input); wrap.appendChild(el('span', label))
        return { wrap: wrap, input: input }
      }

      var limitsCard = el('section', undefined, 'card')
      var limitsHead = el('header'); limitsHead.appendChild(el('h2', '默认')); limitsCard.appendChild(limitsHead)
      var limitsBody = el('div', undefined, 'body')
      var limitsGrid = el('div', undefined, 'settings-grid')
      var defaultComputers = fieldOf('默认电脑数', authState.defaultMaxConnectors, 'number', '2')
      var defaultQuota = fieldOf('新账号月额度（GB）',
        authState.defaultQuotaBytes === null ? '' : (authState.defaultQuotaBytes / 1073741824).toFixed(2),
        'number', '留空 = 不限')
      limitsGrid.appendChild(defaultComputers.wrap)
      limitsGrid.appendChild(defaultQuota.wrap)
      limitsBody.appendChild(limitsGrid)
      var saveLimits = btn('保存', function () {
        var max = parseInt(defaultComputers.input.value, 10)
        if (!isFinite(max) || max < 1 || max > 100) { alert('电脑数要 1–100'); return }
        var rawQuota = defaultQuota.input.value.trim()
        var quota = rawQuota === '' ? null : Math.round(parseFloat(rawQuota) * 1073741824)
        if (rawQuota !== '' && (!isFinite(quota) || quota < 1)) { alert('额度要一个正数'); return }
        saveLimits.disabled = true
        post('/admin/api/limits-defaults', { maxConnectors: max, quotaBytes: quota }).then(function (data) {
          if (data) refresh(true); else saveLimits.disabled = false
        })
      })
      limitsBody.appendChild(saveLimits)
      limitsCard.appendChild(limitsBody); viewEl.appendChild(limitsCard)

      var regCard = el('section', undefined, 'card')
      var regHead = el('header'); regHead.appendChild(el('h2', '注册')); regCard.appendChild(regHead)
      var regBody = el('div', undefined, 'body')
      var modeRow = el('div')
      modeRow.style.cssText = 'display:flex;align-items:center;gap:14px;margin:0 0 20px'
      modeRow.appendChild(el('span', '状态', 'cap'))
      var currentMode = authState.registration === 'closed' ? 'closed' : 'open'
      var seg = el('div', undefined, 'seg')
      var modeButtons = []
      ;[['open', '开放'], ['closed', '关闭']].forEach(function (pair) {
        var b = el('button', pair[1])
        b.type = 'button'
        if (currentMode === pair[0]) b.className = 'on'
        b.addEventListener('click', function () {
          currentMode = pair[0]
          modeButtons.forEach(function (item) { item.className = item === b ? 'on' : '' })
        })
        modeButtons.push(b); seg.appendChild(b)
      })
      modeRow.appendChild(seg); regBody.appendChild(modeRow)
      var domains = fieldOf('邮箱域名白名单', (authState.emailDomains || []).join(', '), 'text', '留空 = 不限；多个用逗号分隔')
      regBody.appendChild(domains.wrap)
      var saveReg = btn('保存', function () {
        saveReg.disabled = true
        post('/admin/api/registration', { mode: currentMode, emailDomains: domains.input.value }).then(function (data) {
          if (data) refresh(true); else saveReg.disabled = false
        })
      })
      regBody.appendChild(saveReg)
      regCard.appendChild(regBody); viewEl.appendChild(regCard)

      var smtp = authState.smtp || { host: '', port: 587, secure: false, starttls: true, user: '', from: '', fromName: '' }
      var mailCard = el('section', undefined, 'card')
      var mailHead = el('header')
      mailHead.appendChild(el('h2', '发信'))
      mailHead.appendChild(el('span', smtp.host ? smtp.host + ':' + smtp.port : '未配置', 'meta'))
      mailCard.appendChild(mailHead)
      var mailBody = el('div', undefined, 'body')
      var grid = el('div', undefined, 'settings-grid')
      var host = fieldOf('服务器', smtp.host, 'text', 'send.ahasend.com')
      var port = fieldOf('端口', smtp.port, 'number', '587')
      var user = fieldOf('用户名', smtp.user, 'text', 'SMTP 用户名')
      var pass = fieldOf('密码', '', 'password', '留空 = 不改')
      var from = fieldOf('发件人', smtp.from, 'email', 'noreply@example.com')
      var fromName = fieldOf('发件人名称', smtp.fromName || '', 'text', 'DSH 中转')
      ;[host, port, user, pass, from, fromName].forEach(function (item) { grid.appendChild(item.wrap) })
      var tls = el('div', null, 'full')
      var secure = checkOf('SSL / TLS（465）', smtp.secure === true)
      var starttls = checkOf('STARTTLS（587）', smtp.starttls === true)
      tls.appendChild(secure.wrap); tls.appendChild(starttls.wrap); grid.appendChild(tls)
      mailBody.appendChild(grid)
      var mailActions = el('div', null, 'actions')
      var saveMail = btn('保存', function () {
        saveMail.disabled = true
        post('/admin/api/smtp', {
          host: host.input.value.trim(),
          port: Number(port.input.value),
          secure: secure.input.checked,
          starttls: starttls.input.checked,
          user: user.input.value.trim(),
          pass: pass.input.value,
          from: from.input.value.trim(),
          fromName: fromName.input.value.trim(),
        }).then(function (data) { if (data) refresh(true); else saveMail.disabled = false })
      })
      mailActions.appendChild(saveMail)
      mailBody.appendChild(mailActions)
      var testRow = el('div')
      testRow.style.cssText = 'display:flex;gap:10px;align-items:flex-end;margin-top:18px;max-width:420px'
      var testTo = fieldOf('测试收件人', '', 'email', 'you@example.com')
      testTo.wrap.style.margin = '0'
      testTo.wrap.style.flex = '1'
      testRow.appendChild(testTo.wrap)
      var testBtn = btn('发送测试', function () {
        var to = testTo.input.value.trim()
        if (to === '') return
        testBtn.disabled = true
        post('/admin/api/mail/test', { to: to }).then(function (data) {
          testBtn.disabled = false
          if (data) alert('已交给 SMTP')
        })
      })
      testRow.appendChild(testBtn)
      mailBody.appendChild(testRow)
      mailCard.appendChild(mailBody); viewEl.appendChild(mailCard)
      return
    }

    if (view === 'events') {
      var eventsCard = el('section', undefined, 'card')
      var eHead = el('header'); eHead.appendChild(el('h2', '最近事件')); eHead.appendChild(el('span', String(state.events.length) + ' 条（最多留 100）', 'meta')); eventsCard.appendChild(eHead)
      var eBody = el('div', undefined, 'body')
      eBody.appendChild(table(['时间', '事件', '对象与细节'], state.events.map(function (row) {
        var label = EVENT_LABELS[row.evt] || row.evt
        var tag = el('span', label, 'tag' + (row.level === 'warn' || row.level === 'error' ? ' bad' : ''))
        return [new Date(row.at).toLocaleTimeString(), tag, describe(row.detail || {})]
      }), '还没有事件 — 有人连上来就会有'))
      eventsCard.appendChild(eBody)
      viewEl.appendChild(eventsCard)
      return
    }

    var tokens = el('section', undefined, 'card')
    var tHead = el('header'); tHead.appendChild(el('h2', '连接器令牌')); tHead.appendChild(el('span', '有效 ' + activeTokens + ' / ' + state.tokens.length, 'meta')); tokens.appendChild(tHead)

    // 连接器认证：开放 = 谁都能自助兑换一张；必需 = 只有管理员签发的能连。
    // 名额留空 = 无上限（不预设人为限制，收紧是 owner 的动作）。
    var auth = state.connectorAuth || { mode: 'required', limit: null, autoCount: 0 }
    var authBody = el('div', undefined, 'body')
    // 管理台只管理已有令牌；"给自己电脑发令牌"在用户控制台。
    var selfRow = el('div')
    selfRow.style.cssText = 'display:flex;justify-content:flex-end;margin:0 0 10px'
    var selfLink = el('a', '添加我的电脑', 'btn')
    selfLink.href = '/console'
    selfLink.style.textDecoration = 'none'
    selfLink.style.display = 'inline-flex'
    selfLink.style.alignItems = 'center'
    selfRow.appendChild(selfLink)
    authBody.appendChild(selfRow)
    var modeLine = el('div')
    modeLine.style.cssText = 'display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:0 0 12px'
    modeLine.appendChild(el('span', '连接器认证', 'meta'))
    modeLine.appendChild(el('span', auth.mode === 'open' ? '开放' : '必需', 'tag ' + (auth.mode === 'open' ? 'ok' : '')))
    if (!state.auth) {
      modeLine.appendChild(btn('设为开放', function () {
        post('/admin/api/connector-auth', { mode: 'open', limit: auth.limit }).then(refresh)
      }))
      modeLine.appendChild(btn('设为必需', function () {
        post('/admin/api/connector-auth', { mode: 'required', limit: auth.limit }).then(refresh)
      }))
    }
    authBody.appendChild(modeLine)
    if (!state.auth) {
      var limitLine = el('div')
      limitLine.style.cssText = 'display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:0 0 4px'
      limitLine.appendChild(el('span', '自动签发上限', 'meta'))
      var limitInput = el('input')
      limitInput.type = 'number'
      limitInput.min = '1'
      limitInput.placeholder = '留空 = 无上限'
      limitInput.value = auth.limit === null ? '' : String(auth.limit)
      limitInput.style.cssText = 'width:120px;padding:8px 10px;border:1px solid var(--line2);border-radius:8px;background:transparent;color:inherit;font:inherit'
      limitLine.appendChild(limitInput)
      limitLine.appendChild(btn('保存上限', function () {
        var raw = limitInput.value.trim()
        var next = raw === '' ? null : Number(raw)
        if (next !== null && (!isFinite(next) || next < 1)) { alert('上限要正整数，或留空表示无上限'); return }
        post('/admin/api/connector-auth', { mode: auth.mode, limit: next }).then(refresh)
      }))
      limitLine.appendChild(el('span', '已自动签发 ' + auth.autoCount + ' 条', 'meta'))
      authBody.appendChild(limitLine)
    }
    tokens.appendChild(authBody)
    var tBody = el('div', undefined, 'body')
    tBody.appendChild(table(['名称', '账号', '状态', ''], state.tokens.map(function (row) {
      var actions = el('span')
      if (row.revokedAt) {
        actions.appendChild(btn('恢复', function () {
          if (!confirm('恢复令牌 ' + row.id + '？') ) return
          post('/admin/api/tokens/restore', { id: row.id }).then(refresh)
        }))
        actions.appendChild(btn('删除', function () {
          if (!confirm('永久删除 ' + row.id + ' 的令牌记录？删了就查不到了（不可恢复）')) return
          post('/admin/api/tokens/remove', { id: row.id }).then(refresh)
        }, true))
      } else {
        actions.appendChild(btn('吊销', function () {
          if (!confirm('吊销令牌 ' + row.id + '？吊销后它立刻下线；要彻底删掉，先吊销再删除')) return
          post('/admin/api/tokens/revoke', { id: row.id }).then(refresh)
        }, true))
      }
      var label = el('span', row.name || row.id)
      label.title = row.id
      var owner = row.owner || '—'
      if (row.userId) {
        var ownerUser = (state.users || []).find(function (user) { return user.id === row.userId })
        owner = ownerUser ? ownerUser.email : row.userId
      }
      return [label, owner, el('span', row.revokedAt ? '已吊销' : '有效', 'tag ' + (row.revokedAt ? 'bad' : 'ok')), actions]
    }), '还没有连接器令牌'))
    tokens.appendChild(tBody)
    viewEl.appendChild(tokens)
  }

  document.getElementById('login-form').addEventListener('submit', function (event) {
    event.preventDefault()
    var value = tokenInput.value.trim()
    if (value === '') { errorEl.textContent = '请输入管理令牌'; errorEl.hidden = false; return }
    sessionMode = false
    sessionStorage.setItem(TOKEN_KEY, value)
    errorEl.hidden = true
    refresh()
  })
  document.getElementById('logout').addEventListener('click', function () {
    if (sessionMode) {
      fetch('/api/auth/logout', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'x-csrf-token': csrf() }
      }).catch(function () {}).then(function () { location.href = '/login' })
      return
    }
    sessionStorage.removeItem(TOKEN_KEY)
    tokenInput.value = ''
    toLogin(null)
  })
  document.getElementById('refresh').addEventListener('click', function () { refresh(true) })
  window.addEventListener('hashchange', function () { if (lastState) render(lastState) })

  // 先看有没有管理员账号会话；没有再看有没有 break-glass 令牌。
  if (token() !== '') {
    refresh()
  } else {
    fetch('/api/auth/me', { credentials: 'same-origin' }).then(function (response) {
      return response.ok ? response.json() : null
    }).then(function (data) {
      if (data && data.user && data.user.role === 'admin') {
        sessionMode = true
        refresh()
      } else {
        toLogin(null)
      }
    }).catch(function () { toLogin(null) })
  }
})()
</script>
</body>
</html>`
