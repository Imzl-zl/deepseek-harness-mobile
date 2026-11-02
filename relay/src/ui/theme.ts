/**
 * 中转控制台的设计系统：纸张底色、衬线标题、细线分隔、单色强调。
 *
 * 认证页与用户控制台共用这一份；管理台在 `admin/page.ts` 末尾追加自己的少量覆盖。
 * 没有任何外链字体/图标：CSP 维持 `default-src 'none'`。
 *
 * 决策见 `.agents/notes/implemented/2026-11-02-relay-editorial-ui-and-admin-settings.md`。
 */
export const THEME_CSS = `
:root{
  --display:Georgia,"Times New Roman","Songti SC","Noto Serif SC",serif;
  --mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  --bg:#f4f1ea; --panel:#fffdf8; --panel2:#ebe6db; --line:#ddd6c8; --line2:#c6bdab;
  --ink:#171614; --ink2:#3d3932; --ink3:#6d675c; --cap:#8b8477;
  --accent:#e8451f; --accent-ink:#fff8f2; --accent-soft:rgba(232,69,31,.10);
  --ok:#1f7a4d; --warn:#a86a00; --bad:#b3261e;
  --shadow:none; --r:2px; --r-sm:2px;
}
@media (prefers-color-scheme:dark){:root{
  --bg:#121110; --panel:#1a1816; --panel2:#231f1c; --line:#332f2a; --line2:#4a443c;
  --ink:#f3eee4; --ink2:#d8d0c2; --ink3:#a69d8e; --cap:#8a8173;
  --accent:#ff5a2f; --accent-ink:#1a0c08; --accent-soft:rgba(255,90,47,.12);
  --ok:#5bd39a; --warn:#e0a33a; --bad:#ff7a6b;
}}
*{box-sizing:border-box}
html,body{min-height:100%}
body{margin:0;background:var(--bg);color:var(--ink);
  font:14px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans SC",sans-serif;
  -webkit-font-smoothing:antialiased}
button{font:inherit;color:inherit;cursor:pointer;background:none;border:0}
input,select{font:inherit}
a{color:inherit;text-decoration:none}
a:hover{text-decoration:underline}
[hidden]{display:none!important}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.mono{font-family:var(--mono);font-size:12px}
.num{font-variant-numeric:tabular-nums}
.muted{color:var(--cap)}
.cap{font-size:9.5px;letter-spacing:.14em;text-transform:uppercase;color:var(--cap)}

/* ---------- 认证 ---------- */
.auth{display:grid;grid-template-columns:minmax(420px,1.06fr) minmax(360px,.94fr);min-height:100vh}
.auth-brand{position:relative;display:flex;flex-direction:column;justify-content:space-between;
  padding:56px 64px;border-right:1px solid var(--line);background:var(--panel);overflow:hidden}
.auth-brand:before{content:"";position:absolute;top:0;left:0;right:0;height:4px;background:var(--accent)}
.brandline{display:flex;align-items:center;gap:12px;font-weight:500;letter-spacing:.02em}
.mark{width:38px;height:38px;display:grid;place-items:center;background:var(--accent);
  color:var(--accent-ink);border:1px solid var(--accent);border-radius:0;flex:none}
.mark svg{width:21px;height:21px;stroke:var(--accent-ink)}
.auth-brand h1{font-family:var(--display);font-size:clamp(42px,4.6vw,64px);line-height:1.06;
  letter-spacing:-.025em;font-weight:500;margin:0 0 18px;max-width:12.5em;text-wrap:balance}
.auth-brand p.lead{margin:0;font-size:10.5px;line-height:1.7;letter-spacing:.18em;
  text-transform:uppercase;color:var(--cap)}
.points{list-style:none;margin:52px 0 0;padding:0;display:flex;flex-direction:column;
  border-top:1px solid var(--line);max-width:30em}
.points li{display:flex;align-items:baseline;gap:18px;padding:14px 0;border-bottom:1px solid var(--line);
  font-size:13.5px;color:var(--ink2)}
.points i{flex:none;width:22px;font-style:normal;font-family:var(--mono);font-size:10px;color:var(--accent)}
.points b{font-weight:500;color:var(--ink)}
.auth-foot{font-size:10px;letter-spacing:.2em;text-transform:uppercase;color:var(--cap)}
.auth-main{display:grid;place-items:center;padding:48px 32px}
.auth-card{width:min(400px,100%);background:transparent;border:0;box-shadow:none;padding:0}
.auth-card .mark{margin-bottom:30px}
.auth-card h2{font-family:var(--display);font-size:36px;line-height:1.1;font-weight:500;
  letter-spacing:-.015em;margin:0 0 30px}
.auth-card .mobile-brand{display:none;align-items:center;gap:11px;margin-bottom:28px;font-weight:500}
.sub{margin:0 0 20px;color:var(--cap);font-size:12px}
.field{display:block;margin:0 0 22px}
.field > span{display:block;font-size:10px;letter-spacing:.16em;text-transform:uppercase;
  color:var(--cap);margin:0 0 8px}
.input,select.input{width:100%;height:44px;padding:0;border:0;border-bottom:1px solid var(--line2);
  border-radius:0;background:transparent;color:var(--ink);font-size:15px;outline:none;
  transition:border-color .15s}
.input::placeholder{color:var(--cap)}
.input:focus{border-color:var(--accent);box-shadow:none}
.input:disabled{opacity:.5}
.field-row{display:flex;gap:12px;align-items:flex-end}
.field-row .input{flex:1;min-width:0}
.btn{height:40px;padding:0 16px;border:1px solid var(--ink);border-radius:0;background:transparent;
  color:var(--ink);font-size:10.5px;font-weight:600;letter-spacing:.1em;text-transform:uppercase;
  transition:background .15s,color .15s,border-color .15s;white-space:nowrap}
.btn:hover{background:var(--ink);color:var(--panel)}
.btn.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
.btn.primary:hover{background:var(--ink);border-color:var(--ink);color:var(--panel)}
.btn.danger{border-color:var(--bad);color:var(--bad)}
.btn.danger:hover{background:var(--bad);border-color:var(--bad);color:var(--panel)}
.btn.block{width:100%}
.btn.small{height:32px;padding:0 12px;font-size:10px}
.btn:disabled{opacity:.4;cursor:not-allowed;background:transparent;color:var(--cap);border-color:var(--line2)}
.error{margin:14px 0 0;padding:8px 0 8px 12px;border-left:2px solid var(--bad);border-radius:0;
  background:transparent;color:var(--bad);font-size:12.5px;line-height:1.6}
.okline{margin:14px 0 0;padding:8px 0 8px 12px;border-left:2px solid var(--ok);border-radius:0;
  background:transparent;color:var(--ok);font-size:12.5px;line-height:1.6}
.hint{margin:18px 0 0;color:var(--cap);font-size:11.5px;line-height:1.7}
.hint code{font-family:var(--mono);font-size:11px;background:var(--panel2);border-radius:0;padding:1px 5px}
.auth-alt{margin:22px 0 0;color:var(--cap);font-size:12px;text-align:left}
.auth-alt a{color:var(--ink);text-decoration:underline;text-underline-offset:3px}
.auth-alt a:hover{color:var(--accent)}
.divider{display:flex;align-items:center;gap:10px;margin:18px 0;color:var(--cap);font-size:11px}
.divider:before,.divider:after{content:"";height:1px;flex:1;background:var(--line)}

/* ---------- 控制台骨架 ---------- */
.app{display:flex;min-height:100vh;background:var(--bg)}
.side{width:236px;flex:none;position:sticky;top:0;height:100vh;display:flex;flex-direction:column;
  padding:28px 20px;background:var(--panel);border-right:1px solid var(--line)}
.side .brandline{display:flex;align-items:center;gap:11px}
.side .brandline b{display:block;font-family:var(--display);font-size:19px;font-weight:500;letter-spacing:-.01em}
.side .brandline span{display:block;font-size:9px;letter-spacing:.18em;text-transform:uppercase;color:var(--cap)}
.side .mark{width:32px;height:32px}
.side .mark svg{width:18px;height:18px}
nav{display:flex;flex-direction:column;margin-top:30px;counter-reset:nav}
nav a{display:flex;align-items:center;gap:12px;padding:11px 0;border-top:1px solid var(--line);
  color:var(--ink3);font-size:13px;text-decoration:none;transition:color .15s}
nav a:last-child{border-bottom:1px solid var(--line)}
nav a:before{counter-increment:nav;content:counter(nav,decimal-leading-zero);width:18px;
  font-family:var(--mono);font-size:9.5px;color:var(--cap)}
nav a:hover{color:var(--ink);text-decoration:none}
nav a.active{color:var(--accent);font-weight:600}
nav a.active:before{color:var(--accent)}
nav em{margin-left:auto;font-style:normal;font-family:var(--mono);font-size:10px;color:var(--cap)}
.sidefoot{margin-top:auto;padding-top:18px;border-top:1px solid var(--line);
  display:flex;flex-direction:column;gap:12px}
.who{display:flex;align-items:center;gap:10px;min-width:0}
.avatar{width:32px;height:32px;flex:none;display:grid;place-items:center;border:1px solid var(--line2);
  border-radius:50%;font-family:var(--mono);font-size:11px;color:var(--accent)}
.mail{font-size:11.5px;color:var(--ink3);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.main{flex:1;min-width:0;display:flex;flex-direction:column}
.topbar{position:sticky;top:0;z-index:9;display:flex;align-items:flex-end;gap:14px;
  padding:34px 40px 20px;background:var(--bg);border-bottom:1px solid var(--line)}
.topbar h1{font-family:var(--display);font-size:42px;line-height:1;font-weight:500;
  letter-spacing:-.02em;margin:0}
.topbar p{margin:8px 0 0;font-size:9.5px;letter-spacing:.16em;text-transform:uppercase;color:var(--cap)}
.grow{flex:1}
.content{padding:28px 40px 64px;max-width:1100px;width:100%;margin:0 auto;
  display:flex;flex-direction:column;gap:26px}
.kpis{display:grid;grid-template-columns:repeat(3,1fr);border-top:1px solid var(--line);
  border-bottom:1px solid var(--line)}
.kpi{padding:20px 20px 22px;border-right:1px solid var(--line);background:transparent;border-radius:0}
.kpi:last-child{border-right:0}
.kpi .v{font-family:var(--display);font-size:46px;line-height:1;font-weight:500;
  letter-spacing:-.02em;font-variant-numeric:tabular-nums}
.kpi .k{margin-top:6px;font-size:9.5px;letter-spacing:.14em;text-transform:uppercase;color:var(--cap)}
.kpi .extra{margin-top:12px}
.card{background:transparent;border:0;border-top:1px solid var(--line);border-radius:0;
  box-shadow:none;overflow:visible;min-width:0}
.card > header{display:flex;align-items:baseline;gap:12px;padding:16px 0 10px}
.card h2{margin:0;font-size:10px;font-weight:600;letter-spacing:.16em;text-transform:uppercase;color:var(--cap)}
.card .meta{margin-left:auto;font-size:9.5px;letter-spacing:.08em;color:var(--cap);font-family:var(--mono)}
.card .body{padding:0 0 10px}
.table-wrap{overflow-x:auto}
table{width:100%;border-collapse:collapse}
th{font-size:9px;font-weight:500;letter-spacing:.14em;text-transform:uppercase;color:var(--cap);
  text-align:left;padding:0 8px 9px;border-bottom:1px solid var(--line);white-space:nowrap}
td{padding:13px 8px;border-bottom:1px solid var(--line);white-space:nowrap;color:var(--ink2);
  font-size:13px;vertical-align:middle}
tbody tr:last-child td{border-bottom:0}
tbody tr:hover td{background:var(--accent-soft)}
th.r,td.r{text-align:right}
td.name{color:var(--ink);font-weight:500}
.empty{padding:34px 0;text-align:left;color:var(--cap);font-size:12.5px;line-height:1.7}
.empty b{display:block;color:var(--ink);font-family:var(--display);font-size:20px;font-weight:500;margin-bottom:4px}
.badge{display:inline-flex;align-items:center;height:20px;padding:0 7px;border:1px solid var(--line2);
  border-radius:0;font-size:9px;letter-spacing:.08em;text-transform:uppercase;color:var(--ink3);
  white-space:nowrap;background:transparent}
.badge.ok{color:var(--ok);border-color:color-mix(in srgb,var(--ok) 50%,transparent)}
.badge.warn{color:var(--warn);border-color:color-mix(in srgb,var(--warn) 50%,transparent)}
.badge.bad{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 50%,transparent)}
.bar{display:block;width:100%;height:2px;background:var(--line2);overflow:hidden;border-radius:0}
.bar i{display:block;height:100%;background:var(--accent)}
.bar i.warn{background:var(--warn)} .bar i.bad{background:var(--bad)}
.kv{display:flex;flex-direction:column;font-size:13px;color:var(--ink2)}
.kv .row{display:flex;gap:14px;align-items:baseline;padding:11px 0;border-bottom:1px solid var(--line)}
.kv .row:last-child{border-bottom:0}
.kv .row span:first-child{color:var(--cap);min-width:78px;flex:none;font-size:10px;letter-spacing:.12em;text-transform:uppercase}
.kv .row span:last-child{min-width:0;overflow-wrap:anywhere}
.actions{display:flex;gap:6px;flex-wrap:wrap;align-items:center}
.note{margin:0;padding:12px 14px;border:1px solid var(--line);border-left:3px solid var(--accent);
  border-radius:0;background:transparent;color:var(--ink3);font-size:12px;line-height:1.7}
.note b{color:var(--ink2)}
.steps{margin:0;padding:0 0 0 18px;color:var(--ink3);font-size:13px;line-height:1.9}
.steps code{font-family:var(--mono);font-size:11.5px;background:var(--panel2);padding:1px 5px}

/* ---------- 弹窗 / Toast ---------- */
.modal-backdrop{position:fixed;inset:0;z-index:50;display:grid;place-items:center;padding:20px;
  background:rgba(20,18,16,.55)}
.modal{width:min(520px,100%);background:var(--panel);border:1px solid var(--ink);border-radius:0;
  box-shadow:none;overflow:hidden}
.modal header{padding:28px 28px 0}
.modal h3{margin:0 0 8px;font-family:var(--display);font-size:28px;font-weight:500;line-height:1.1}
.modal .sub{margin:0;color:var(--cap);font-size:12px;line-height:1.6}
.modal .body{padding:22px 28px}
.modal footer{display:flex;justify-content:flex-end;gap:8px;padding:0 28px 22px}
.codebox{display:flex;gap:10px;align-items:stretch}
.codebox .mono{flex:1;min-width:0;padding:13px;border:1px solid var(--line2);border-radius:0;
  background:var(--bg);overflow-wrap:anywhere;line-height:1.5}
.check{display:flex;gap:9px;align-items:flex-start;margin:16px 0 0;font-size:12.5px;color:var(--ink3);line-height:1.6}
.check input{margin-top:2px;accent-color:var(--accent)}
.toast{position:fixed;top:16px;left:50%;transform:translateX(-50%);z-index:80;
  padding:10px 15px;border:1px solid var(--ink);border-radius:0;background:var(--panel);
  color:var(--ink);font-size:12px;box-shadow:none;opacity:0;pointer-events:none;
  transition:opacity .16s,transform .16s}
.toast.show{opacity:1;transform:translateX(-50%) translateY(2px)}
.toast.bad{border-color:var(--bad);color:var(--bad)}
.toast.ok{border-color:var(--ok);color:var(--ok)}
.skeleton{height:14px;background:var(--panel2);animation:pulse 1.2s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:.5}50%{opacity:1}}

@media (max-width:900px){
  .auth{grid-template-columns:1fr}
  .auth-brand{display:none}
  .auth-main{padding:28px 20px}
  .auth-card .mobile-brand{display:flex}
  .app{flex-direction:column}
  .side{width:auto;height:auto;position:static;flex-direction:row;align-items:center;gap:12px;
    padding:12px 16px;overflow-x:auto}
  .side .brandline div:last-child span{display:none}
  nav{flex-direction:row;margin-top:0;gap:0;counter-reset:none}
  nav a{border-top:0;border-bottom:2px solid transparent;padding:8px 10px;font-size:12px}
  nav a:before{display:none}
  nav em{display:none}
  .sidefoot{display:none}
  .topbar{padding:20px 16px 14px}
  .topbar h1{font-size:30px}
  .content{padding:18px 16px 48px;gap:20px}
  .kpis{grid-template-columns:1fr 1fr}
  .kpi{border-right:0;border-bottom:1px solid var(--line);padding:16px 12px}
  .kpi:nth-child(odd){border-right:1px solid var(--line)}
  .kpi .v{font-size:34px}
}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
`
