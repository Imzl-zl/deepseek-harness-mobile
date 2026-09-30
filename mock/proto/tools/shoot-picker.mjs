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
const send = (m, p = {}) => { const mid = ++id; ws.send(JSON.stringify({ id: mid, method: m, params: p })); return new Promise(r => pend.set(mid, r)); };

await send("Page.enable"); await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });
await send("Page.navigate", { url: PAGE }); await sleep(1500);

// 模型列表
await send("Runtime.evaluate", {
  expression: "(async()=>{const T=window.Takeovers;while(T.pending)T.dequeue();await new Promise(r=>setTimeout(r,400));const q=s=>document.querySelector(s);q('[data-act=\"pick-model\"]').click();await new Promise(r=>setTimeout(r,500));document.querySelector('[data-pk=\"model\"]').click();await new Promise(r=>setTimeout(r,400));})()",
  awaitPromise: true,
});
let r = await send("Page.captureScreenshot", { format: "png" });
writeFileSync(join(OUT, "11-model-picker.png"), Buffer.from(r.result.data, "base64"));
console.log("saved 11-model-picker.png");

// 切换选中后再拍一张,便于对比列是否移动
await send("Runtime.evaluate", {
  expression: "(async()=>{const rows=[...document.querySelectorAll('.prow[data-pm]')];rows[2].click();await new Promise(r=>setTimeout(r,400));document.querySelector('[data-pk=\"model\"]').click();await new Promise(r=>setTimeout(r,400));})()",
  awaitPromise: true,
});
r = await send("Page.captureScreenshot", { format: "png" });
writeFileSync(join(OUT, "12-model-picker-switched.png"), Buffer.from(r.result.data, "base64"));
console.log("saved 12-model-picker-switched.png");
ws.close();
