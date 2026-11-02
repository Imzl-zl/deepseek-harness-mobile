/**
 * 中转控制台的设计 token 与组件样式（认证页、用户控制台共用）。
 *
 * 与 `admin/page.ts` 的深色控制台同一套语言：深色 slate 底 + 青绿强调，
 * 但把圆角、间距、表单、弹窗、空态、Toast 收成一套可复用的类。
 * 没有任何外链字体/图标：CSP 维持 `default-src 'none'`。
 */
export const THEME_CSS = `
:root{
  --bg:#0a0e14; --panel:#11161f; --panel2:#161d28; --line:#222b39; --line2:#2e3a4c;
  --ink:#e7eef7; --ink2:#b6c2d3; --ink3:#93a1b5; --cap:#6b7a90;
  --accent:#3dd6c0; --accent-ink:#04231f; --accent-soft:rgba(61,214,192,.12);
  --ok:#38d39f; --warn:#f5b544; --bad:#ff6b81;
  --shadow:0 18px 50px rgba(0,0,0,.38);
  --r:12px; --r-sm:9px;
}
@media (prefers-color-scheme:light){
  :root{
    --bg:#f4f6fa; --panel:#ffffff; --panel2:#eef2f7; --line:#e2e8f0; --line2:#cbd5e1;
    --ink:#0f172a; --ink2:#334155; --ink3:#526174; --cap:#8494a8;
    --accent:#0d9488; --accent-ink:#ffffff; --accent-soft:rgba(13,148,136,.10);
    --ok:#047857; --warn:#b45309; --bad:#e11d48;
    --shadow:0 12px 32px rgba(15,23,42,.08);
  }
}
*{box-sizing:border-box}
html,body{min-height:100%}
body{margin:0;background:var(--bg);color:var(--ink);
  font:14px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans SC",sans-serif;
  -webkit-font-smoothing:antialiased}
button{font:inherit;color:inherit;cursor:pointer;background:none;border:0}
input,select{font:inherit}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
[hidden]{display:none!important}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:6px}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px}
.num{font-variant-numeric:tabular-nums}
.muted{color:var(--cap)}

/* ---------- 认证 ---------- */
.auth{display:grid;grid-template-columns:minmax(360px,46%) minmax(360px,1fr);min-height:100vh}
.auth-brand{position:relative;display:flex;flex-direction:column;justify-content:space-between;
  padding:48px 56px;overflow:hidden;
  background:
    radial-gradient(720px 420px at 20% 0%,var(--accent-soft),transparent 70%),
    radial-gradient(620px 380px at 92% 108%,rgba(124,140,255,.14),transparent 70%),
    var(--panel)}
.auth-brand:before{content:"";position:absolute;inset:0;pointer-events:none;
  background-image:linear-gradient(var(--line) 1px,transparent 1px),linear-gradient(90deg,var(--line) 1px,transparent 1px);
  background-size:48px 48px;opacity:.18;mask-image:linear-gradient(180deg,#000,transparent 85%)}
.auth-brand > *{position:relative}
.brandline{display:flex;align-items:center;gap:11px;font-weight:650;letter-spacing:.2px}
.mark{width:34px;height:34px;border-radius:10px;display:grid;place-items:center;
  background:var(--accent-soft);border:1px solid color-mix(in srgb,var(--accent) 35%,transparent)}
.mark svg{width:20px;height:20px;stroke:var(--accent)}
.auth-brand h1{font-size:34px;line-height:1.2;letter-spacing:.2px;margin:0 0 16px;max-width:14em}
.auth-brand p.lead{margin:0;color:var(--ink2);font-size:15px;max-width:30em;line-height:1.8}
.points{list-style:none;margin:30px 0 0;padding:0;display:flex;flex-direction:column;gap:14px;max-width:30em}
.points li{display:flex;gap:12px;color:var(--ink2);font-size:13.5px;line-height:1.6}
.points i{width:22px;height:22px;border-radius:7px;flex:none;display:grid;place-items:center;
  background:var(--accent-soft);color:var(--accent);font-style:normal;font-size:12px;margin-top:1px}
.auth-foot{color:var(--cap);font-size:12px;letter-spacing:.02em}
.auth-main{display:grid;place-items:center;padding:40px 24px}
.auth-card{width:min(420px,100%);background:var(--panel);border:1px solid var(--line);
  border-radius:18px;padding:32px 30px 26px;box-shadow:var(--shadow)}
.auth-card .mark{margin-bottom:18px}
.auth-card h2{margin:0 0 6px;font-size:21px;font-weight:650;letter-spacing:.2px}
.auth-card .sub{margin:0 0 24px;color:var(--cap);font-size:13px;line-height:1.6}
.auth-card .mobile-brand{display:none;align-items:center;gap:10px;margin-bottom:18px;font-weight:650}
.field{display:block;margin:0 0 16px}
.field > span{display:block;font-size:12px;color:var(--ink3);margin:0 0 7px}
.input,select.input{width:100%;height:44px;padding:0 13px;border:1px solid var(--line2);border-radius:var(--r-sm);
  background:var(--bg);color:var(--ink);outline:none;transition:border-color .12s,box-shadow .12s}
.input::placeholder{color:var(--cap)}
.input:focus{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
.input:disabled{opacity:.6}
.field-row{display:flex;gap:8px}
.field-row .input{flex:1;min-width:0}
.btn{height:38px;padding:0 15px;border:1px solid var(--line2);border-radius:var(--r-sm);
  color:var(--ink2);background:var(--panel);font-size:13px;font-weight:500;
  transition:border-color .12s,color .12s,background .12s,filter .12s;white-space:nowrap}
.btn:hover{border-color:var(--accent);color:var(--accent)}
.btn.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-ink);font-weight:650}
.btn.primary:hover{filter:brightness(1.06);color:var(--accent-ink)}
.btn.danger{border-color:color-mix(in srgb,var(--bad) 40%,transparent);color:var(--bad)}
.btn.danger:hover{background:color-mix(in srgb,var(--bad) 12%,transparent)}
.btn.block{width:100%}
.btn:disabled{opacity:.55;cursor:not-allowed;filter:none}
.btn.small{height:30px;padding:0 10px;font-size:12px;border-radius:7px}
.error{margin:14px 0 0;padding:10px 12px;border-radius:var(--r-sm);font-size:12.5px;line-height:1.6;
  background:color-mix(in srgb,var(--bad) 13%,transparent);
  border:1px solid color-mix(in srgb,var(--bad) 34%,transparent);color:var(--bad)}
.okline{margin:14px 0 0;padding:10px 12px;border-radius:var(--r-sm);font-size:12.5px;line-height:1.6;
  background:color-mix(in srgb,var(--ok) 12%,transparent);
  border:1px solid color-mix(in srgb,var(--ok) 32%,transparent);color:var(--ok)}
.hint{margin:16px 0 0;color:var(--cap);font-size:12px;line-height:1.7}
.hint code{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11.5px;
  background:var(--panel2);border:1px solid var(--line);border-radius:5px;padding:1px 5px}
.auth-alt{margin:20px 0 0;color:var(--cap);font-size:12.5px;text-align:center}
.auth-alt a{margin-left:4px}
.divider{display:flex;align-items:center;gap:10px;margin:18px 0;color:var(--cap);font-size:11.5px}
.divider:before,.divider:after{content:"";height:1px;flex:1;background:var(--line)}

/* ---------- 控制台骨架 ---------- */
.app{display:flex;min-height:100vh}
.side{width:244px;flex:none;display:flex;flex-direction:column;gap:20px;padding:20px 14px;
  background:var(--panel);border-right:1px solid var(--line);position:sticky;top:0;height:100vh}
.side .brandline{font-size:14px}
.side .brandline span{display:block;font-size:10.5px;color:var(--cap);letter-spacing:.08em;text-transform:uppercase}
nav{display:flex;flex-direction:column;gap:3px}
nav a{display:flex;align-items:center;gap:10px;padding:9px 11px;border-radius:var(--r-sm);
  color:var(--ink2);font-size:13.5px;text-decoration:none}
nav a:hover{background:var(--panel2);text-decoration:none}
nav a.active{background:var(--accent-soft);color:var(--accent);font-weight:600}
nav em{margin-left:auto;font-style:normal;font-size:11px;color:var(--cap);font-variant-numeric:tabular-nums}
.sidefoot{margin-top:auto;display:flex;flex-direction:column;gap:10px;padding:0 4px}
.who{display:flex;align-items:center;gap:9px;min-width:0}
.avatar{width:30px;height:30px;border-radius:50%;flex:none;display:grid;place-items:center;
  background:var(--accent-soft);color:var(--accent);font-weight:650;font-size:13px}
.who .mail{font-size:12px;color:var(--ink3);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.main{flex:1;min-width:0;display:flex;flex-direction:column}
.topbar{position:sticky;top:0;z-index:9;display:flex;align-items:center;gap:12px;
  padding:16px 28px;background:color-mix(in srgb,var(--bg) 88%,transparent);
  backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.topbar h1{margin:0;font-size:18px;font-weight:650;letter-spacing:.2px}
.topbar p{margin:2px 0 0;font-size:12px;color:var(--cap)}
.grow{flex:1}
.content{padding:26px 28px 48px;max-width:1120px;width:100%;margin:0 auto;display:flex;
  flex-direction:column;gap:18px}
.kpis{display:grid;gap:14px;grid-template-columns:repeat(3,minmax(0,1fr))}
.kpi{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:16px 17px}
.kpi .v{font-size:26px;font-weight:660;letter-spacing:.2px;font-variant-numeric:tabular-nums}
.kpi .k{margin-top:3px;font-size:12px;color:var(--cap)}
.kpi .extra{margin-top:10px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;overflow:hidden;min-width:0}
.card > header{display:flex;align-items:baseline;gap:10px;padding:16px 18px 12px}
.card h2{margin:0;font-size:13px;font-weight:600;color:var(--ink3);letter-spacing:.04em}
.card .meta{margin-left:auto;font-size:11.5px;color:var(--cap)}
.card .body{padding:0 18px 18px}
.table-wrap{overflow-x:auto}
table{width:100%;border-collapse:collapse}
th{font-size:11px;font-weight:500;letter-spacing:.06em;color:var(--cap);text-align:left;
  padding:0 10px 9px;border-bottom:1px solid var(--line);white-space:nowrap}
td{padding:11px 10px;border-bottom:1px solid var(--line);white-space:nowrap;color:var(--ink2);vertical-align:middle}
tbody tr:last-child td{border-bottom:0}
tbody tr:hover td{background:var(--panel2)}
th.r,td.r{text-align:right}
td.name{color:var(--ink);font-weight:500}
.empty{padding:34px 16px;text-align:center;color:var(--cap);font-size:13px;line-height:1.7}
.empty b{display:block;color:var(--ink2);font-size:14px;font-weight:600;margin-bottom:6px}
.badge{display:inline-flex;align-items:center;gap:6px;height:23px;padding:0 9px;border-radius:999px;
  font-size:11.5px;border:1px solid var(--line2);color:var(--ink3);white-space:nowrap}
.badge.ok{color:var(--ok);border-color:color-mix(in srgb,var(--ok) 38%,transparent);background:color-mix(in srgb,var(--ok) 10%,transparent)}
.badge.warn{color:var(--warn);border-color:color-mix(in srgb,var(--warn) 38%,transparent);background:color-mix(in srgb,var(--warn) 10%,transparent)}
.badge.bad{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 38%,transparent);background:color-mix(in srgb,var(--bad) 10%,transparent)}
.bar{display:block;width:100%;height:7px;border-radius:999px;background:var(--line2);overflow:hidden}
.bar i{display:block;height:100%;background:var(--accent);border-radius:999px}
.bar i.warn{background:var(--warn)} .bar i.bad{background:var(--bad)}
.kv{display:flex;flex-direction:column;gap:10px;font-size:13px;color:var(--ink2)}
.kv .row{display:flex;gap:12px;align-items:baseline}
.kv .row span:first-child{color:var(--cap);min-width:78px;flex:none}
.kv .row span:last-child{min-width:0;overflow-wrap:anywhere}
.actions{display:flex;gap:6px;flex-wrap:wrap}
.note{margin:12px 0 0;padding:11px 13px;border-radius:var(--r-sm);font-size:12.5px;line-height:1.7;
  background:var(--panel2);border:1px solid var(--line);color:var(--ink3)}
.note b{color:var(--ink2)}
.steps{margin:0;padding:0 0 0 20px;color:var(--ink3);font-size:13px;line-height:1.9}
.steps code{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;
  background:var(--panel2);border:1px solid var(--line);border-radius:5px;padding:1px 5px}

/* ---------- 弹窗 / Toast ---------- */
.modal-backdrop{position:fixed;inset:0;z-index:50;display:grid;place-items:center;padding:20px;
  background:rgba(4,8,14,.62);backdrop-filter:blur(4px)}
.modal{width:min(520px,100%);background:var(--panel);border:1px solid var(--line2);
  border-radius:16px;box-shadow:var(--shadow);overflow:hidden}
.modal header{padding:20px 22px 0}
.modal h3{margin:0 0 6px;font-size:17px;font-weight:650}
.modal .sub{margin:0;color:var(--cap);font-size:12.5px;line-height:1.6}
.modal .body{padding:18px 22px}
.modal footer{display:flex;justify-content:flex-end;gap:8px;padding:0 22px 18px}
.codebox{display:flex;gap:8px;align-items:stretch}
.codebox .mono{flex:1;min-width:0;padding:12px 13px;border:1px solid var(--line2);border-radius:var(--r-sm);
  background:var(--bg);overflow-wrap:anywhere;line-height:1.5}
.check{display:flex;gap:9px;align-items:flex-start;margin:14px 0 0;font-size:12.5px;color:var(--ink3);line-height:1.6}
.check input{margin-top:2px;accent-color:var(--accent)}
.toast{position:fixed;top:16px;left:50%;transform:translateX(-50%);z-index:80;
  padding:10px 15px;border-radius:10px;font-size:13px;box-shadow:var(--shadow);
  background:var(--panel);border:1px solid var(--line2);color:var(--ink);
  opacity:0;pointer-events:none;transition:opacity .16s,transform .16s}
.toast.show{opacity:1;transform:translateX(-50%) translateY(2px)}
.toast.bad{border-color:color-mix(in srgb,var(--bad) 45%,transparent);color:var(--bad)}
.toast.ok{border-color:color-mix(in srgb,var(--ok) 45%,transparent);color:var(--ok)}
.skeleton{height:14px;border-radius:7px;background:var(--panel2);animation:pulse 1.2s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:.55}50%{opacity:1}}

@media (max-width:900px){
  .auth{grid-template-columns:1fr}
  .auth-brand{display:none}
  .auth-main{padding:24px 16px}
  .auth-card .mobile-brand{display:flex}
  .app{flex-direction:column}
  .side{width:auto;height:auto;position:static;flex-direction:row;align-items:center;gap:12px;
    padding:10px 14px;overflow-x:auto}
  .side .brandline span{display:none}
  nav{flex-direction:row;gap:4px}
  nav a{padding:7px 10px;font-size:13px}
  nav em{display:none}
  .sidefoot{display:none}
  .topbar{padding:12px 15px}
  .topbar h1{font-size:16px}
  .content{padding:16px 15px 40px}
  .kpis{grid-template-columns:1fr 1fr}
  .kpi .v{font-size:22px}
  .card .body{padding:0 14px 16px}
  th,td{padding-left:8px;padding-right:8px}
}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
`
