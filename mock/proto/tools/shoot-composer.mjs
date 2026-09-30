import { setTimeout as sleep } from "node:timers/promises";
import { writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const CDP = process.env.CDP_URL || "http://127.0.0.1:9400";
const PAGE = process.env.PAGE_URL || "file:///C:/sudy/myproject/dsh-mobile/mock/proto/index.html";
const OUT = join(dirname(fileURLToPath(import.meta.url)), "..", "shots");
mkdirSync(OUT, { recursive: true });

const list = await (await fetch(CDP + "/json/list")).json();
const t = list.find(x => x.type === "page" && x.webSocketDebuggerUrl);
const ws = new WebSocket(t.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let id = 0; const pend = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); } };
const send = (method, params = {}) => { const mid = ++id; ws.send(JSON.stringify({ id: mid, method, params })); return new Promise(r => pend.set(mid, r)); };

await send("Page.enable"); await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });
await send("Page.navigate", { url: PAGE }); await sleep(1500);
await send("Runtime.evaluate", {
  expression: "(async()=>{const T=window.Takeovers;while(T.pending)T.dequeue();await new Promise(r=>setTimeout(r,400));const q=s=>document.querySelector(s);q('#msgs').scrollTop=q('#msgs').scrollHeight;await new Promise(r=>setTimeout(r,300));})()",
  awaitPromise: true,
});
let r = await send("Page.captureScreenshot", { format: "png" });
writeFileSync(join(OUT, "01-chat-composer.png"), Buffer.from(r.result.data, "base64"));
console.log("saved 01-chat-composer.png");

// 极长模型名:确认省略号生效且不挤掉权限图标
await send("Runtime.evaluate", {
  expression: "(async()=>{const q=s=>document.querySelector(s);q('#chipModel').querySelector('b').textContent='claude-opus-4-5-very-long-name';await new Promise(r=>setTimeout(r,200));})()",
  awaitPromise: true,
});
r = await send("Page.captureScreenshot", { format: "png" });
writeFileSync(join(OUT, "10-composer-long-model.png"), Buffer.from(r.result.data, "base64"));
console.log("saved 10-composer-long-model.png");

const chk = await send("Runtime.evaluate", {
  expression: `(() => {
    const q = s => document.querySelector(s);
    const R = el => el.getBoundingClientRect();
    const send = R(q('#send')), perm = R(q('#chipPerm')), model = R(q('#chipModel')), tools = R(q('.ctools'));
    return { modelW: Math.round(model.width), permW: Math.round(perm.width),
      permVisible: perm.width > 20, noOverlap: tools.right <= send.left + 1,
      sendIsRightmost: q('.ctools').nextElementSibling.id === 'send' };
  })()`,
  returnByValue: true,
});
console.log(JSON.stringify(chk.result.result.value));
ws.close();
