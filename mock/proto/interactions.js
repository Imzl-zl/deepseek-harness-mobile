/* ============================================================
   DSH Mobile · 输入栏接管(composer takeover)
   真实 DSH 里这三件事不是聊天里的气泡卡片,而是**占用输入栏位置**的接管面板:
     · ui-approval/ApprovalPanel     等待审批 → 拒绝 / 允许一次
     · ui-user-questions/QuestionComposer  一题一屏向导:编号选项 / 多选 / 自定义答案 / 跳过 / 下一题
     · ui-user-questions/PlanReviewPanel   计划待审 → 要求修改 / 同意执行
   要点:提问可能是一组题(1..N),每题可有 N 个选项、可多选;审批只在
   "非完全权限"下出现(完全权限 = danger-full-access 不再逐步确认)。
   规格来源:ApprovalPanel.module.css / QuestionComposer.module.css / locales.ts。
   ============================================================ */
window.Takeovers = (() => {
  "use strict";

  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  /* 本模块自带的震动:之前这里裸调 app.js 作用域里的 haptic(),
     在异步回调里抛 ReferenceError 会中断整个回答流程(队列不推进、无回执)。 */
  const haptic = (ms = 10) => {
    try {
      navigator.vibrate && navigator.vibrate(ms);
    } catch (_) {}
  };
  const esc = (s) =>
    String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  /* DSH 图标(icons.js);缺失时退化为占位,不静默留空。
     权限三枚图标在 DSH 的 ui-primitives/PermissionIcon.tsx(不在 icons/index.tsx 里),
     已请抽取器补进 icons.js;这里保留同源副本作为兜底,icons.js 有了就自动走它。 */
  const PERM_ART = {
    permissionReadOnly:
      '<path d="M5.08545 8.13775L7.18455 10.2368C7.26636 10.3187 7.4003 10.3142 7.47649 10.2271L11.5148 5.61194" stroke="currentColor"/><path d="M6.59624 2.14853C7.50155 1.80917 8.49914 1.80919 9.40444 2.14859L13.9245 3.84317V7.11961C13.9245 11.6089 10.5565 13.5975 8.00035 14.5779C5.44423 13.5975 2.07544 11.6089 2.07544 7.11961V3.84317L6.59624 2.14853Z" stroke="currentColor" stroke-linejoin="round"/>',
    permissionWorkspaceWrite:
      '<path d="M6.4209 1.68067C7.43922 1.299 8.56177 1.29898 9.58008 1.68067L14.0996 3.375C14.2946 3.44811 14.4236 3.63455 14.4238 3.84278V6.89063C14.1115 6.71853 13.7761 6.58312 13.4238 6.48926V4.18946L9.22852 2.61621C8.43657 2.31947 7.56341 2.31939 6.77148 2.61621L2.5752 4.18946V7.11914C2.5752 11.1796 5.52369 13.056 8 14.0391C8.27653 13.9293 8.55827 13.8067 8.8418 13.6729C9.07101 13.9468 9.33228 14.1929 9.62012 14.4053C9.12409 14.6579 8.63578 14.8696 8.17871 15.0449C8.0637 15.0889 7.93628 15.0889 7.82129 15.0449C5.22011 14.0472 1.5752 11.9381 1.5752 7.11914V3.84278C1.57541 3.63469 1.70463 3.44821 1.89941 3.375L6.4209 1.68067Z" fill="currentColor"/><path d="M5.26392 6.60339H10.7361" stroke="currentColor"/><path d="M5.26392 9.86902H8.32833" stroke="currentColor"/><path d="M10.0317 13.2229C10.263 13.3929 10.4943 13.563 10.7256 13.733C10.7932 13.6482 10.8608 13.5634 10.9284 13.4786C12.1455 11.9522 13.3626 10.4258 14.5798 8.89935C14.6474 8.81455 14.715 8.72975 14.7826 8.64495C14.4143 8.37419 14.046 8.10344 13.6777 7.83268C13.6169 7.92252 13.5562 8.01236 13.4954 8.10219C12.4016 9.71926 11.3078 11.3363 10.214 12.9534C10.1532 13.0432 10.0924 13.1331 10.0317 13.2229Z" fill="currentColor"/><path d="M12.6516 12.6696C12.6516 12.925 12.6516 13.1804 12.6516 13.4359C12.6952 13.4378 12.7387 13.4398 12.7823 13.4417C13.5663 13.4768 14.3504 13.5118 15.1345 13.5469C15.178 13.5488 15.2216 13.5508 15.2651 13.5527C15.2651 13.2194 15.2651 12.8861 15.2651 12.5527C15.2216 12.5547 15.178 12.5566 15.1345 12.5586C14.3504 12.5936 13.5663 12.6287 12.7823 12.6637C12.7387 12.6657 12.6952 12.6676 12.6516 12.6696Z" fill="currentColor"/>',
    permissionFullAccess:
      '<path d="M6.59624 2.14853C7.50155 1.80917 8.49914 1.80919 9.40444 2.14859L13.9245 3.84317V7.11961C13.9245 11.6089 10.5565 13.5975 8.00035 14.5779C5.44423 13.5975 2.07544 11.6089 2.07544 7.11961V3.84317L6.59624 2.14853Z" stroke="currentColor" stroke-linejoin="round"/><path d="M8 4.39209V9.89209" stroke="currentColor"/><path d="M8 10.8081V11.8081" stroke="currentColor"/>',
  };

  const ic = (name, size = 16) => {
    if (window.DshIcons && window.DshIcons.names.indexOf(name) >= 0) {
      try {
        return window.DshIcons.svg(name, { size: size });
      } catch (e) {
        /* 落到下面的兜底 */
      }
    }
    if (PERM_ART[name]) {
      return `<svg width="${size}" height="${size}" viewBox="0 0 16 16" fill="none" aria-hidden="true" stroke-width="1">${PERM_ART[name]}</svg>`;
    }
    return `<span style="font-size:${size}px;opacity:.6">◆</span>`;
  };

  /* StateDot:ongoing 用 DSH 那个内联 spinner(24 viewBox / r 9.5 / dash 12 150) */
  const DOT = (state) =>
    state === "ongoing"
      ? '<svg class="sdot-spin" viewBox="0 0 24 24" aria-hidden="true"><g class="motion">' +
        '<circle class="trk" cx="12" cy="12" r="9.5"/><circle class="arc" cx="12" cy="12" r="9.5"/>' +
        "</g></svg>"
      : `<span class="sdot" data-state="${state}"></span>`;

  /* ---------------------------------------------------------- 权限模式
     值/文案照 ui-permission-presets/locales.ts(zh)。 */
  const PERMS = [
    {
      id: "read-only",
      icon: "permissionReadOnly",
      label: "仅可查看",
      desc: "只读:任何写入或外部命令都要你批准",
    },
    {
      id: "workspace-write",
      icon: "permissionWorkspaceWrite",
      label: "工作区内修改",
      desc: "工作区内直接改;越权写入与外部命令要你批准",
    },
    {
      id: "danger-full-access",
      icon: "permissionFullAccess",
      label: "完全权限",
      desc: "减少确认步骤,敏感操作、文件修改、外部命令直接执行",
      gate: true,
    },
    {
      id: "auto",
      icon: "shield",
      label: "Auto review",
      badge: "EXP",
      desc: "无沙箱运行;每次工具调用前由同一模型实验性审查",
      gate: true,
    },
  ];
  const permOf = (id) => PERMS.find((p) => p.id === id) || PERMS[1];

  /* ---------------------------------------------------------- 模块状态 */
  let host = null;
  let composerEl = null;
  let api = null;
  let perm = "workspace-write";
  const queue = []; // 待处理队列(瀑布:一次只处理队首)
  let qs = null; // 提问流程运行时状态
  let tick = null;
  let seq = 0;

  const active = () => queue[0] || null;

  function mount(opts) {
    host = opts.host;
    composerEl = opts.composer;
    api = opts.api;
    render();
  }

  /* ---------------------------------------------------------- 队列 */
  function needsApproval() {
    return perm !== "danger-full-access";
  }

  function enqueue(item) {
    item.key = item.key || "tk-" + ++seq;
    if (item.kind === "approval" && !needsApproval()) {
      api &&
        api.toast(
          "完全权限下不再逐步确认:" + item.toolName + " 直接执行(未入队)"
        );
      return false;
    }
    queue.push(item);
    if (item.kind === "question") {
      qs = {
        index: 0,
        minimized: false,
        drafts: {},
        skipped: {},
        countdown:
          item.countdownMs === undefined
            ? null
            : { left: Math.round(item.countdownMs / 1000), paused: false, done: false },
        submitted: false,
      };
      item.questions.forEach((q) => {
        qs.drafts[q.id] = { selected: [], custom: "" };
      });
    }
    render();
    return true;
  }

  function dequeue() {
    queue.shift();
    if (tick) {
      clearInterval(tick);
      tick = null;
    }
    qs = null;
    render();
  }

  /* ---------------------------------------------------------- 渲染 */
  function render() {
    if (!host) return;
    /* 整卡重绘会重置内层滚动:先记下,重绘后还原,避免点一下选项长列表跳回顶部 */
    const prevBody = host.querySelector(".tk-body");
    const keepScroll = prevBody ? prevBody.scrollTop : 0;
    host.innerHTML = "";
    const a = active();
    host.classList.toggle("is-on", !!a);
    if (composerEl) composerEl.classList.toggle("is-hidden", !!a);
    if (api && api.setNeed) api.setNeed(queue.length);
    if (!a) return;

    const wrap = document.createElement("div");
    if (a.kind === "approval") wrap.innerHTML = approvalHtml(a);
    else if (a.kind === "question") wrap.innerHTML = questionHtml(a);
    else wrap.innerHTML = planHtml(a);
    const card = wrap.firstElementChild;
    host.appendChild(card);

    if (keepScroll > 0) {
      const body = card.querySelector(".tk-body");
      if (body) body.scrollTop = keepScroll;
    }

    if (queue.length > 1) {
      const q = document.createElement("div");
      q.className = "tk-queue";
      q.textContent = "还有 " + (queue.length - 1) + " 项待处理";
      host.appendChild(q);
    }
    wire(card, a);
  }

  /* ---------------------------------------------------------- 审批 */
  function approvalHtml(a) {
    const headline =
      a.reason && a.reason !== ""
        ? esc(a.reason)
        : "工具 " + esc(a.toolName) + " 请求越权执行";
    return `
      <section class="tk is-warn" role="dialog" aria-label="审批">
        <div class="tk-strip">${DOT(
          a.busy ? "ongoing" : "warning"
        )}等待审批
          <span class="sp">${esc(permOf(perm).label)}</span></div>
        <div class="tk-body" tabindex="0" role="group" aria-label="审批详情">
          <div class="tk-title">${headline}</div>
          ${a.detailHtml || ""}
        </div>
        <div class="tk-actions">
          <button class="btn btn--out" data-tk="reject" ${
            a.busy ? "disabled" : ""
          }>拒绝</button>
          <button class="btn btn--fill" data-tk="allow" ${
            a.busy ? "disabled" : ""
          }>允许一次</button>
        </div>
      </section>`;
  }

  /* ---------------------------------------------------------- 提问 */
  function questionHtml(item) {
    const q = item.questions[qs.index];
    const n = item.questions.length;
    const draft = qs.drafts[q.id];
    const hasOptions = (q.options || []).length > 0;
    const answered =
      draft.selected.length > 0 || draft.custom.trim().length > 0;
    const last = qs.index === n - 1;

    const wait = waitHtml();
    const opts = hasOptions
      ? (q.options || [])
          .map((o, i) => {
            const rec = /推荐/.test(o.label);
            const label = o.label.replace(/[（(]推荐[)）]/g, "");
            const on = draft.selected.includes(o.label);
            const mark =
              q.multiSelect === true
                ? `<span class="opt-chk${on ? " is-on" : ""}">${
                    on ? ic("check", 12) : ""
                  }</span>`
                : `<span class="opt-num">${i + 1}</span>`;
            return `<button class="opt${on && q.multiSelect !== true ? " is-on" : ""}"
              role="${q.multiSelect === true ? "checkbox" : "radio"}"
              aria-checked="${on}" data-opt="${esc(o.label)}">
              ${mark}
              <span class="opt-copy">
                <span class="opt-line"><span class="opt-label">${esc(label)}</span>
                ${rec ? '<span class="badge-rec">推荐</span>' : ""}</span>
                ${o.description ? `<span class="opt-desc">${esc(o.description)}</span>` : ""}
              </span></button>`;
          })
          .join("")
      : "";

    const customRow = hasOptions
      ? `<div class="opt${draft.custom !== "" ? " is-on" : ""}" style="cursor:text">
          ${
            q.multiSelect === true
              ? `<span class="opt-chk${draft.custom !== "" ? " is-on" : ""}">${
                  draft.custom !== "" ? ic("check", 12) : ""
                }</span>`
              : `<span class="opt-num">${ic("edit", 12)}</span>`
          }
          ${fieldHtml(q.id, draft.custom, "inline")}
        </div>`
      : `<div class="tk-block">${fieldHtml(q.id, draft.custom, "block")}</div>`;

    return `
      <section class="tk${qs.minimized ? " is-min" : ""}" role="dialog"
        aria-labelledby="q-${item.key}-${qs.index}">
        <header class="tk-head">
          <div class="tk-heading">
            ${q.header ? `<div class="tk-eyebrow">${esc(q.header)}</div>` : ""}
            <h2 class="tk-title" id="q-${item.key}-${qs.index}">${esc(q.question)}</h2>
          </div>
          <div class="tk-hacts">
            <button class="tk-ib" data-tk="min" aria-label="${
              qs.minimized ? "展开问题卡片" : "收起问题卡片"
            }" aria-expanded="${!qs.minimized}">
              ${ic(qs.minimized ? "chevronUp" : "chevronDown", 16)}</button>
            <button class="tk-ib" data-tk="dismiss" aria-label="放弃整组问题">${ic(
              "close",
              16
            )}</button>
          </div>
        </header>
        <div class="tk-waits">${wait}</div>
        ${
          qs.minimized
            ? ""
            : `<div class="tk-body" data-qscroll>
                ${q.detail ? `<div class="tk-detail">${q.detail}</div>` : ""}
                <div class="tk-opts" role="${
                  q.multiSelect === true ? "group" : "radiogroup"
                }">${opts}${customRow}
                ${
                  qs.skipped[q.id]
                    ? '<p class="opt-desc" style="padding:8px 8px 0">这道问题已被跳过。</p>'
                    : ""
                }</div>
              </div>
              <div class="tk-feedback" role="status" data-feedback></div>
              <footer class="tk-foot">
                <div class="tk-pager">
                  <button class="tk-ib" data-tk="prev" aria-label="上一题"
                    ${qs.index === 0 ? "disabled" : ""}>${ic("chevronLeft", 16)}</button>
                  <span class="tk-progress">${qs.index + 1} / ${n}</span>
                  <button class="tk-ib" data-tk="next" aria-label="下一题"
                    ${last ? "disabled" : ""}>${ic("chevronRight", 16)}</button>
                </div>
                <div class="tk-actions" style="padding:0">
                  <button class="btn btn--out" data-tk="skip" style="min-width:76px">跳过</button>
                  <button class="btn btn--fill" data-tk="submit" style="min-width:96px"
                    ${answered ? "" : "disabled"}>${last ? "提交" : "下一题"}</button>
                </div>
              </footer>`
        }
      </section>`;
  }

  function waitHtml() {
    if (!qs || !qs.countdown) return "";
    const c = qs.countdown;
    if (c.done) return `<span class="tk-wait">已继续工作,仍可回答</span>`;
    const text = c.paused
      ? `已暂停 · 剩余 ${c.left} 秒`
      : `${c.left} 秒后继续工作`;
    return (
      `<span class="tk-wait">${text}</span>` +
      (c.paused ? "" : `<button class="tk-waitbtn" data-tk="takeTime">慢慢回答</button>`)
    );
  }

  function fieldHtml(id, value, variant) {
    return `<span class="tk-field" data-field="${id}" data-variant="${variant}">
      <span class="tk-mirror" aria-hidden="true">${esc(value)}\n</span>
      <textarea class="tk-input" rows="1" placeholder="输入你的答案"
        data-custom="${id}">${esc(value)}</textarea>
    </span>`;
  }

  /* ---------------------------------------------------------- 计划待审 */
  function planHtml(a) {
    return `
      <section class="tk is-warn" role="dialog" aria-label="计划待审">
        <div class="tk-strip">${DOT(
          a.busy ? "ongoing" : "warning"
        )}计划待审</div>
        <div class="tk-body">
          <h3 class="tk-title">${esc(a.title)}</h3>
          ${a.description ? `<p class="tk-detail" style="margin-top:6px">${esc(a.description)}</p>` : ""}
          ${a.steps ? `<div class="tk-cmd">${a.steps.map(esc).join("\n")}</div>` : ""}
        </div>
        <div class="tk-actions">
          <button class="btn btn--out" data-tk="discuss" ${
            a.busy ? "disabled" : ""
          }>${ic("edit", 14)} 要求修改</button>
          <button class="btn btn--fill" data-tk="approve" ${
            a.busy ? "disabled" : ""
          }>同意执行</button>
        </div>
      </section>`;
  }

  /* ---------------------------------------------------------- 事件接线 */
  function wire(card, item) {
    $$("[data-tk]", card).forEach((b) => {
      b.addEventListener("click", () => act(b.dataset.tk, item, card, b));
    });
    const inputs = $$("textarea[data-custom]", card);
    inputs.forEach((ta) => {
      const id = ta.dataset.custom;
      const field = ta.closest(".tk-field");
      const mirror = field && field.querySelector(".tk-mirror");
      const sync = () => {
        const d = qs.drafts[id];
        d.custom = ta.value;
        if (mirror) mirror.textContent = ta.value + "\n";
        const row = ta.closest(".opt");
        if (row) row.classList.toggle("is-on", ta.value !== "");
        const chk = row && row.querySelector(".opt-chk");
        if (chk) {
          chk.classList.toggle("is-on", ta.value !== "");
          chk.innerHTML = ta.value !== "" ? ic("check", 12) : "";
        }
        const submit = card.querySelector('[data-tk="submit"]');
        if (submit)
          submit.disabled = !(
            d.selected.length > 0 || d.custom.trim().length > 0
          );
        const fb = card.querySelector("[data-feedback]");
        if (fb) fb.textContent = "";
      };
      ta.addEventListener("input", sync);
      ta.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
          e.preventDefault();
          continueFlow();
        }
      });
    });
    if (item.kind === "question" && item.countdownMs !== undefined && !tick) startTick();
  }

  function act(kind, item, card, btn) {
    switch (kind) {
      case "reject":
        settleApproval(item, "rejected");
        break;
      case "allow":
        settleApproval(item, "allowed-once");
        break;
      case "approve":
        settlePlan(item, true);
        break;
      case "discuss":
        settlePlan(item, false);
        break;
      case "min":
        qs.minimized = !qs.minimized;
        render();
        break;
      case "dismiss":
        api && api.toast("已放弃整组问题");
        dequeue();
        break;
      case "prev":
        if (qs.index > 0) {
          qs.index--;
          render();
        }
        break;
      case "next":
        if (qs.index < item.questions.length - 1) {
          qs.index++;
          render();
        }
        break;
      case "takeTime":
        if (qs.countdown) {
          qs.countdown.paused = true;
          render();
        }
        break;
      case "skip":
        skipQuestion(item);
        break;
      case "submit":
        continueFlow();
        break;
    }
  }

  /* 回答在途:状态圆点转圈 + 按钮禁用(照 ApprovalPanel 的 answered → ongoing) */
  function settleApproval(item, outcome) {
    if (item.busy) return;
    item.busy = true;
    const dot = host.querySelector(".tk-strip .sdot, .tk-strip .sdot-spin");
    if (dot) dot.outerHTML = DOT("ongoing");
    $$(".tk-actions .btn", host).forEach((b) => (b.disabled = true));
    haptic();
    setTimeout(() => {
      api && api.toast(outcome === "rejected" ? "已拒绝" : "已允许一次");
      api && api.appendNode && api.appendNode(approvalNode(item, outcome));
      item.busy = false;
      dequeue();
    }, 420);
  }

  function settlePlan(item, ok) {
    if (item.busy) return;
    item.busy = true;
    const dot = host.querySelector(".tk-strip .sdot, .tk-strip .sdot-spin");
    if (dot) dot.outerHTML = DOT("ongoing");
    $$(".tk-actions .btn", host).forEach((b) => (b.disabled = true));
    haptic();
    setTimeout(() => {
      api && api.toast(ok ? "已同意执行" : "已要求修改,计划退回");
      api && api.appendNode && api.appendNode(planNode(item, ok));
      item.busy = false;
      dequeue();
    }, 420);
  }

  function choose(label, item) {
    const q = item.questions[qs.index];
    const d = qs.drafts[q.id];
    if (q.multiSelect === true) {
      const i = d.selected.indexOf(label);
      if (i >= 0) d.selected.splice(i, 1);
      else d.selected.push(label);
    } else {
      d.selected = d.selected[0] === label ? [] : [label];
    }
    render();
  }

  function skipQuestion(item) {
    const q = item.questions[qs.index];
    qs.skipped[q.id] = true;
    if (qs.index < item.questions.length - 1) {
      qs.index++;
      render();
    } else {
      submitFlow(item);
    }
  }

  function continueFlow() {
    const item = active();
    if (!item || item.kind !== "question") return;
    const q = item.questions[qs.index];
    const d = qs.drafts[q.id];
    const answered = d.selected.length > 0 || d.custom.trim() !== "";
    const fb = host.querySelector("[data-feedback]");
    if (!answered) {
      if (fb) fb.textContent = "请选择一个选项或填写自定义答案。";
      return;
    }
    if (qs.index < item.questions.length - 1) {
      qs.index++;
      render();
    } else {
      submitFlow(item);
    }
  }

  function submitFlow(item) {
    const answers = item.questions.map((q) => ({
      id: q.id,
      question: q.question,
      header: q.header,
      selected: qs.drafts[q.id].selected.slice(),
      custom: qs.drafts[q.id].custom.trim(),
      skipped: qs.skipped[q.id] === true,
    }));
    api && api.toast("回答已发送,电脑端继续工作");
    api && api.appendNode && api.appendNode(questionReplyNode(answers));
    dequeue();
  }

  function startTick() {
    tick = setInterval(() => {
      if (!qs || !qs.countdown || qs.countdown.paused || qs.countdown.done) return;
      qs.countdown.left -= 1;
      if (qs.countdown.left <= 0) {
        qs.countdown.done = true;
        clearInterval(tick);
        tick = null;
        api && api.toast("已到时间,电脑端先继续;你仍可回答");
      }
      paintWait();
    }, 1000);
  }

  /* 只改等待状态那一段,不整卡重绘 —— 否则用户正在自定义答案里打字会被打断 */
  function paintWait() {
    const box = host && host.querySelector(".tk-waits");
    if (!box) return;
    box.innerHTML = waitHtml();
  }

  /* ---------------------------------------------------------- 聊天侧回执节点 */
  function approvalNode(item, outcome) {
    const ok = outcome === "allowed-once";
    return `<div class="turn"><div class="qreply">
      <div class="qreply-h"><span class="sdot" data-state="${
        ok ? "done" : "error"
      }"></span>
        <span>审批回执 · ${esc(item.toolName)} · ${ok ? "允许一次" : "已拒绝"}</span></div>
    </div></div>`;
  }

  function planNode(item, ok) {
    return `<div class="turn"><div class="qreply">
      <div class="qreply-h"><span class="sdot" data-state="${
        ok ? "done" : "idle"
      }"></span>
        <span>计划回执 · ${esc(item.title)} · ${ok ? "同意执行" : "要求修改"}</span></div>
    </div></div>`;
  }

  function questionReplyNode(answers) {
    const rows = answers
      .map((a) => {
        const val = a.skipped
          ? '<span class="skip">已跳过</span>'
          : esc([...a.selected, ...(a.custom ? [a.custom] : [])].join("、"));
        return `<div class="qa"><div class="q">${
          a.header ? esc(a.header) + " — " : ""
        }${esc(a.question)}</div><div class="a">${val}</div></div>`;
      })
      .join("");
    return `<div class="turn"><div class="qreply is-open">
      <button class="qreply-h" data-act="qreply-toggle">
        <span class="sdot" data-state="done"></span>
        <span>回答先前等待中的问题</span><span class="cv">${ic("chevronDown", 16)}</span>
      </button>
      <div class="qreply-b">${rows}</div>
    </div></div>`;
  }

  /* ---------------------------------------------------------- 权限门
     照 permission.access 的 confirm.*:切到完全权限 / Auto review 都要先勾风险确认。
     onConfirm 缺省时落到「当前会话权限」;设置页的「新会话默认权限」传自己的落点,
     共用这一道门而不是再写一套确认流程。 */
  function gateSheet(openSheet, targetId, onConfirm) {
    const target = targetId || "danger-full-access";
    const isAuto = target === "auto";
    let ack = false;
    openSheet({
      title: isAuto ? "确认启用 Auto review(实验)?" : "确认启用完全权限?",
      body: `
        <div class="gate">
          <p>${
            isAuto
              ? "Auto review 不使用沙箱。每次原生工具调用和 PTC 内层调用前,都会由与当前 agent 相同的模型进行审查;审查拒绝的调用由你批准或拒绝。此功能仍属实验性,可能误放行或误拒绝,并会消耗额外 token。"
              : "启用完全权限后,智能体将减少确认步骤,并且可以直接执行更多操作,包括敏感操作、文件修改或外部命令。仅建议在你信任当前任务时使用。"
          }</p>
          <button class="gate-ack" data-gate="ack">
            <span class="opt-chk" data-gate-chk></span>
            <span>我已了解风险,并愿意继续</span>
          </button>
        </div>`,
      actions: [
        { label: "取消", kind: "out", onClick: () => api.closeSheet() },
        {
          label: isAuto ? "启用 Auto review" : "启用完全权限",
          kind: "danger",
          onClick: () => {
            if (!ack) return;
            api.closeSheet();
            if (onConfirm) {
              onConfirm(target);
              return;
            }
            setPermission(target);
            api.toast(
              isAuto
                ? "已启用 Auto review(实验)"
                : "已启用完全权限 · 工具调用不再逐步确认"
            );
          },
        },
      ],
      onMount: (sheet) => {
        const ackBtn = sheet.querySelector('[data-gate="ack"]');
        const chk = sheet.querySelector("[data-gate-chk]");
        ackBtn.addEventListener("click", () => {
          ack = !ack;
          chk.classList.toggle("is-on", ack);
          chk.innerHTML = ack ? ic("check", 12) : "";
        });
      },
    });
  }

  /* 从聊天里的工具行重新打开(nav.close = 收起问题面板,可从工具调用重新打开) */
  function focus(kind) {
    const a = active();
    if (!a || (kind && a.kind !== kind)) return false;
    if (a.kind === "question" && qs && qs.minimized) {
      qs.minimized = false;
      render();
    }
    const card = host && host.querySelector(".tk");
    if (card) {
      if (card.animate) {
        card.animate(
          [{ transform: "scale(1)" }, { transform: "scale(1.015)" }, { transform: "scale(1)" }],
          { duration: 260, easing: "cubic-bezier(.4,0,.2,1)" }
        );
      }
      if (card.scrollIntoView) card.scrollIntoView({ block: "nearest" });
    }
    return true;
  }

  function setPermission(id) {    if (!permOf(id) || perm === id) return;
    perm = id;
    if (api && api.onPermission) api.onPermission(permOf(perm));
    /* 完全权限会把队里的审批直接放行 */
    if (!needsApproval()) {
      const dropped = queue.filter((i) => i.kind === "approval").length;
      for (let i = queue.length - 1; i >= 0; i--) {
        if (queue[i].kind === "approval") queue.splice(i, 1);
      }
      if (dropped > 0) api && api.toast("完全权限:已放行 " + dropped + " 项待审批");
    }
    render();
  }

  /* ---------------------------------------------------------- 演示数据 */
  const DEMO = {
    approval() {
      enqueue({
        kind: "approval",
        toolName: "bash",
        detailHtml: `<div class="tk-cmd"><span class="dim">$</span> rm -rf build/ && flutter clean
<span class="dim">cwd</span> D:\\sudy\\myproject\\dsh-mobile\\app</div>
<div class="tk-detail" style="margin-top:8px">只读 / 工作区内修改模式下,工作区外的删除与外部命令都要你确认。</div>`,
      });
      enqueue({
        kind: "approval",
        toolName: "write",
        reason: "写入工作区外的路径",
        detailHtml: `<div class="tk-cmd"><span class="dim">path</span> C:\\Users\\me\\.dsh\\config.toml
<span class="dim">size</span> 1.2 KB  <span class="dim">diff</span> +14 −3</div>`,
      });
    },
    question() {
      enqueue({
        kind: "question",
        countdownMs: 45000,
        questions: [
          {
            id: "q1",
            header: "实现顺序",
            question: "鸿蒙壳先接 Flutter OHOS,还是先把 iOS 壳跑通?",
            detail:
              "<p>三条路都能走通,区别是风险与返工量。CI 与原生插件(SecureStorage / 推送)要按第一条落地的平台先定。</p>",
            options: [
              {
                label: "先把 iOS 壳跑通(推荐)",
                description: "上游主线,插件生态完整,遇到问题可查资料最多",
              },
              {
                label: "先接鸿蒙",
                description: "直接对齐三端目标,但 fork 版本跟随华为节奏,插件缺口要自己补",
              },
              {
                label: "两个并行",
                description: "最快看到三端效果,但要两套构建环境,CI 复杂度翻倍",
              },
            ],
            multiSelect: false,
          },
          {
            id: "q2",
            header: "本轮范围",
            question: "这一轮还要一起做哪些?(可多选)",
            options: [
              { label: "设置页", description: "对齐 DSH 全量配置:模型 / 插件 / 外观" },
              { label: "文件浏览页", description: "浏览工作区 + 点击进文件预览" },
              { label: "终端页", description: "接 bridge 的交互式终端(依赖后端能力)" },
              { label: "推送通知", description: "审批 / 提问到达时通知,不用一直盯着" },
            ],
            multiSelect: true,
          },
          {
            id: "q3",
            header: "其他",
            question: "还有什么必须遵守的约束?",
            options: [],
          },
        ],
      });
    },
    plan() {
      enqueue({
        kind: "plan",
        title: "重写移动端导航与文件预览",
        description:
          "把底部导航换成 M3 抽屉 + 聊天即主页;变更文件点开进入全屏 diff 页;轨迹页保留迷你横滑甘特。",
        steps: [
          "1. 抽屉:边缘跟手拖拽 / 遮罩 / 系统返回键",
          "2. 文件页:unified diff + 行号槽 + 状态(二进制/超限/缺失)",
          "3. 输入栏接管:审批 / 提问 / 计划待审",
          "4. 验收:真机尺寸逐项对拍",
        ],
      });
    },
    all() {
      DEMO.question();
      DEMO.approval();
      DEMO.plan();
    },
  };

  /* 点在选项行上:委托处理(选项是按钮,单独接线) */
  document.addEventListener("click", (e) => {
    const opt = e.target.closest("[data-opt]");
    if (!opt) return;
    const item = active();
    if (!item || item.kind !== "question") return;
    const q = item.questions[qs.index];
    if (opt.closest(".opt").querySelector("textarea")) return; // 自定义行
    choose(opt.dataset.opt, item);
  });

  return {
    mount,
    enqueue,
    dequeue,
    render,
    focus,
    icon: ic,
    setPermission,
    gateSheet,
    get permission() {
      return perm;
    },
    get permissionInfo() {
      return permOf(perm);
    },
    get pending() {
      return queue.length;
    },
    get waiting() {
      return active();
    },
    perms: PERMS,
    demo: DEMO,
    needsApproval,
  };
})();
