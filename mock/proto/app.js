/* ============================================================
   DSH Mobile · 交互原型引擎
   纯手势 + 分层返回栈,无框架。所有交互在真机(触屏)上成立,
   桌面浏览器用鼠标拖也能验证同一套代码路径。
   暴露 window.PROTO 供自动化验证与调试。
   ============================================================ */
(() => {
  "use strict";

  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const haptic = (ms = 10) => {
    try {
      navigator.vibrate && navigator.vibrate(ms);
    } catch (_) {}
  };

  /* DSH 图标:统一走 Takeovers.icon(icons.js + 同源兜底),这里只做一层保护 */
  const ic = (name, size = 16) => {
    if (window.Takeovers && window.Takeovers.icon) return window.Takeovers.icon(name, size);
    return `<span style="font-size:${size}px;opacity:.6">◆</span>`;
  };

  /* DSH 的输入栏发送/停止不是图标组件,是手写内联几何
     (ui-conversation/src/client/skeleton/InputBar.tsx:470-472 / 486-492) */
  const SEND_SVG =
    '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M8.3125 0.980183C8.66767 1.0531 8.97902 1.20418 9.2627 1.43233C9.48724 1.61297 9.73029 1.85793 9.97949 2.10714L14.707 6.83468L13.293 8.24874L9 3.95577V15.0417H7V3.95577L2.70703 8.24874L1.29297 6.83468L6.02051 2.10714C6.26971 1.85793 6.51277 1.61297 6.7373 1.43233C6.97662 1.23986 7.28445 1.04402 7.6875 0.980183C7.8973 0.947006 8.1031 0.95516 8.3125 0.980183Z" fill="currentColor"/></svg>';
  const STOP_SVG =
    '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><rect x="3" y="3" width="10" height="10" rx="3" fill="currentColor"/></svg>';

  /* 静态标记里写 data-icon="名字",启动时统一换成 DSH 图标,避免 HTML 里塞大段 SVG */
  function paintIcons(root) {
    $$("[data-icon]", root || document).forEach((el) => {
      const size = Number(el.dataset.iconSize || 16);
      el.innerHTML = ic(el.dataset.icon, size);
    });
  }

  /* ---------------------------------------------------------- 新会话页(blank)的 hero
     DSH 那边"刚连上落到的第一屏"**不是空态,是"已有会话但它是 blank"**
     (`ui-conversation/src/client/skeleton/ConversationMainPanel.tsx:41-43` 的 hero
     两个来源,实际走后者),而那个 blank 会话是工作区连上时被急切创建的
     (`ui-workspace/src/client/navigation.ts:195-205` 的 `reuseOrCreateBlank`)。

     所以原型里这一屏由**会话是 blank** 这个状态决定,不是另做一个页面:
       · `#convHero` 显示、`#msgs` 藏起来(blank 会话没有内容区 —— DSH 的
         `DefaultConversationViews.tsx:32` 在 blank 期直接 `return null`);
       · 输入框占位符换成 `placeholder.hero` 那句(`locales.ts:23`);
       · 两枚 chip 的值就是电脑侧那两个投影(工作区归属 / `agentPreset`)。
     真机上这两枚 chip 的选择走 `session.create({workspaceId, agentPreset})`(建新任务),
     原型同样只改演示值 —— 它没有电脑侧。
     Note: 为什么写路径不用 agentPresets.select —— 见
     .agents/notes/implemented/2026-10-17-blank-session-hero.md */
  const HERO_PH = "描述你想要构建的内容, / 调用指令, @ 文件或对话";
  const NORMAL_PH = "发消息或创建任务, / 调用指令, @ 文件或对话";
  /* 演示数据:与手机侧 hero 上那两枚 chip 同源(工作区来自 `workspace.list`,
     预设来自 `agentPresets.list`)——内置四档的名字照 DSH 的本地化字典
     (`ui-agent-preset/src/client/locales.ts:95-102`)。 */
  const HERO_WORKSPACES = [
    { id: "w-dsh-mobile", name: "dsh-mobile", path: "D:\\sudy\\myproject\\dsh-mobile" },
    { id: "w-dsh", name: "deepseek-harness", path: "D:\\sudy\\github\\deepseek-harness" },
  ];
  const HERO_PRESETS = [
    { id: "standard", name: "标准模式", desc: "处理代码、文件和资料，适合大多数任务。Agent 会按需使用检索、编辑和终端等工具。" },
    { id: "ptc", name: "PTC 模式", desc: "包含标准模式的所有能力，更适合批量调用工具，并对结果进行筛选、整理、去重、统计或汇总的任务。" },
    { id: "minimal", name: "极简模式", desc: "Agent 仅使用终端工具完成任务，适合测试和对比其基础表现。" },
    { id: "cordis", name: "创造模式", desc: "用对话定制 DSH：让 Agent 编写插件，添加新功能或界面；也能组合工具和提示词，创建自己的模式。" },
  ];
  let heroWorkspace = HERO_WORKSPACES[0].id;
  let heroPreset = "standard";

  function setBlankSession(on) {
    const hero = $("#convHero");
    const msgs = $("#msgs");
    const field = $("#input");
    if (hero) hero.hidden = !on;
    if (msgs) msgs.hidden = on;
    if (field) field.placeholder = on ? HERO_PH : NORMAL_PH;
    document.body.classList.toggle("is-blank", on);
    renderHeroChips();
  }

  function renderHeroChips() {
    const ws = $("#heroWorkspaceLabel");
    const ps = $("#heroPresetLabel");
    const wsRow = HERO_WORKSPACES.find((w) => w.id === heroWorkspace);
    const psRow = HERO_PRESETS.find((p) => p.id === heroPreset);
    if (ws) ws.textContent = wsRow ? wsRow.name : "选择工作区";
    if (ps) ps.textContent = psRow ? psRow.name : "选择预设";
    /* 有名字才是"开着"的文件夹(照 `EmptyHero.tsx:55-57` 的 folderClose/folderOpen)。 */
    const wsIcon = $("#heroWorkspace") && $("#heroWorkspace").querySelector("[data-icon]");
    if (wsIcon) {
      wsIcon.dataset.icon = wsRow ? "folderOpen" : "folderClose";
      wsIcon.innerHTML = ic(wsIcon.dataset.icon, 16);
    }
  }

  /* ---------------------------------------------------------- 手势底座
     axis 自动判定:横划归 JS,竖划交还浏览器滚动。
     start() 返回 false 表示这一笔不归我们管。 */
  function onDrag(el, opt) {
    const R = opt.threshold || 8;
    let id = null, sx = 0, sy = 0, lx = 0, ly = 0, lt = 0;
    let vx = 0, vy = 0, live = false;

    el.addEventListener("pointerdown", (e) => {
      if (e.pointerType === "mouse" && e.button !== 0) return;
      if (opt.start && opt.start(e) === false) return;
      id = e.pointerId;
      sx = lx = e.clientX;
      sy = ly = e.clientY;
      lt = performance.now();
      vx = vy = 0;
      live = false;
    });

    el.addEventListener("pointermove", (e) => {
      if (id === null || e.pointerId !== id) return;
      const dx = e.clientX - sx;
      const dy = e.clientY - sy;

      if (!live) {
        if (Math.abs(dx) < R && Math.abs(dy) < R) return;
        const want = opt.axis || (Math.abs(dx) > Math.abs(dy) ? "x" : "y");
        const wrong =
          (want === "x" && Math.abs(dy) > Math.abs(dx)) ||
          (want === "y" && Math.abs(dx) > Math.abs(dy));
        if (wrong) {
          id = null; // 轴不符:放弃这一笔,让浏览器滚动
          return;
        }
        live = true;
        try {
          el.setPointerCapture(id);
        } catch (_) {}
        opt.begin && opt.begin(e, { dx, dy });
        opt.move && opt.move(e, { dx, dy, vx: 0, vy: 0 }); // 首帧就跟手,不留死区
        return;
      }

      const now = performance.now();
      const dt = now - lt;
      if (dt > 0) {
        vx = 0.65 * vx + 0.35 * ((e.clientX - lx) / dt);
        vy = 0.65 * vy + 0.35 * ((e.clientY - ly) / dt);
        lx = e.clientX;
        ly = e.clientY;
        lt = now;
      }
      opt.move && opt.move(e, { dx, dy, vx, vy });
    });

    const finish = (e) => {
      if (id === null || e.pointerId !== id) return;
      const wasLive = live;
      const dx = e.clientX - sx;
      const dy = e.clientY - sy;
      id = null;
      live = false;
      if (wasLive) opt.end && opt.end(e, { dx, dy, vx, vy });
    };
    el.addEventListener("pointerup", finish);
    el.addEventListener("pointercancel", finish);

    /* 长按:替换桌面 hover 的菜单入口(§2) */
    if (opt.longPress) {
      const ms = opt.longPressMs || 460;
      let t = null, fired = false, px = 0, py = 0, pid = null;
      const stop = () => {
        if (t) clearTimeout(t);
        t = null;
        pid = null;
        el.classList.remove("is-press");
      };
      el.addEventListener("pointerdown", (e) => {
        if (e.pointerType === "mouse" && e.button !== 0) return;
        if (opt.start && opt.start(e) === false) return;
        fired = false;
        pid = e.pointerId;
        px = e.clientX;
        py = e.clientY;
        el.classList.add("is-press");
        t = setTimeout(() => {
          t = null;
          fired = true;
          el.classList.remove("is-press");
          haptic(14);
          opt.longPress(e);
        }, ms);
      });
      el.addEventListener("pointermove", (e) => {
        if (pid === null || e.pointerId !== pid) return;
        if (Math.abs(e.clientX - px) > 8 || Math.abs(e.clientY - py) > 8) stop();
      });
      el.addEventListener("pointerup", stop);
      el.addEventListener("pointercancel", stop);
      el.addEventListener("contextmenu", (e) => {
        e.preventDefault();
        if (!fired && opt.longPress) opt.longPress(e);
      });
    }
    return el;
  }

  /* ---------------------------------------------------------- 分层返回栈
     抽屉 / 文件页 / 大图 / sheet 都入栈,系统返回键与左缘返回手势都走这里。
     深度写进 history.state,popstate 以 state 为准收缩,避免多次开关后残留幽灵层。 */
  const layers = [];
  let depth = 0;
  // 刷新会把上一次会话的 history.state 带回来,这里重置基线,避免层深错位
  history.replaceState({ dsh: 0 }, "");

  window.addEventListener("popstate", (e) => {
    const d = (e.state && e.state.dsh) || 0;
    while (layers.length > d) {
      const l = layers.pop();
      l.close(true);
    }
    depth = d;
  });

  function openLayer(kind, close) {
    const top = layers[layers.length - 1];
    if (top && top.kind === kind) {
      top.close = close; // 同一层幂等:避免重复压栈留下幽灵层
      return;
    }
    layers.push({ kind, close });
    depth += 1;
    history.pushState({ dsh: depth, layer: kind }, "");
  }
  function closeLayer(kind, viaHistory) {
    let i = layers.length - 1;
    if (kind) {
      for (let k = layers.length - 1; k >= 0; k--) {
        if (layers[k].kind === kind) {
          i = k;
          break;
        }
      }
    }
    if (i < 0) return false;
    const l = layers[i];
    layers.length = i;
    depth = i;
    if (!viaHistory) {
      history.back(); // 与 pushState 配对;若已被系统返回消费,popstate 里会自愈
      l.close(false);
    } else {
      l.close(true);
    }
    return true;
  }
  const topLayer = () => (layers.length ? layers[layers.length - 1] : null);

  /* ---------------------------------------------------------- 抽屉 */
  const drawer = $("#drawer");
  const scrim = $("#scrim");
  const edgeOpen = $("#edgeOpen");
  const appRoot = $("#app");

  const D = {
    p: 0, // 0 关闭 → 1 打开
    anim: false,
    get width() {
      return drawer.offsetWidth;
    },
    isOpen() {
      return this.p > 0.5;
    },
    render() {
      drawer.style.transform = `translate3d(${(this.p - 1) * this.width}px,0,0)`;
      scrim.style.opacity = String(this.p * 0.55);
      scrim.style.pointerEvents = this.p > 0.02 ? "auto" : "none";
      drawer.setAttribute("aria-hidden", this.p < 0.5 ? "true" : "false");
      appRoot.classList.toggle("drawer-open", this.p > 0.02);
    },
    set(p, animate) {
      this.anim = !!animate;
      drawer.style.transition = animate
        ? "transform var(--d3) var(--ease)"
        : "none";
      scrim.style.transition = animate ? "opacity var(--d3) var(--ease)" : "none";
      this.p = clamp(p, 0, 1);
      this.render();
    },
    open() {
      if (this.p === 1) return;
      this.set(1, true);
      openLayer("drawer", () => this.finishClose());
    },
    close() {
      if (this.p === 0) return;
      if (!closeLayer("drawer")) this.set(0, true); // 没有对应层(如边缘拖一半松手)时直接复位
    },
    finishClose() {
      this.set(0, true);
    },
  };
  D.render();

  if (edgeOpen) {
    onDrag(edgeOpen, {
      axis: "x",
      threshold: 4,
      start: () => D.p === 0, // 抽屉盖住边缘后,左缘手势归抽屉自己
      begin: () => D.set(0, false),
      move: (e, g) => D.set(g.dx / D.width, false),
      end: (e, g) => {
        const p = g.dx / D.width;
        if (p > 0.4 || g.vx > 0.45) D.open();
        else D.set(0, true);
      },
    });
  }

  /* 右缘手势带(2026-10-16):往左划**跟手**拖出右抽屉。
     与左缘同一条纪律:贴最边缘、只占上半屏(下半屏留给系统返回)。
     "跟手"= 拖动时抽屉跟着手指平移(临时去掉 CSS 过渡),松手按拖过 40% 或甩速决定开/回弹。
     抽屉开着时这条带子被 `#app.file-open .edge--side{display:none}` 整条收起来
     (那条"棒棒"也就跟着消失 —— 用户原话"侧滑之后棒要消失")。 */
  const edgeSide = $("#edgeSide");
  if (edgeSide) {
    const sideW = () => sidePage.offsetWidth || 1;
    onDrag(edgeSide, {
      axis: "x",
      threshold: 4,
      start: () => !sidePage.classList.contains("is-in"),
      begin: () => {
        sidePage.classList.add("is-in");
        sidePage.style.transition = "none";
      },
      move: (e, g) => {
        const p = clamp(-g.dx / sideW(), 0, 1);
        sidePage.style.transform = `translate3d(${(1 - p) * 100}%,0,0)`;
        sidePage.style.opacity = String(0.35 + 0.65 * p);
      },
      end: (e, g) => {
        const p = -g.dx / sideW();
        sidePage.style.transition = "";
        sidePage.style.transform = "";
        sidePage.style.opacity = "";
        if (p > 0.4 || g.vx < -0.45) openSide("file");
        else sidePage.classList.remove("is-in");
      },
    });
  }

  let drawerDragging = false;
  onDrag(drawer, {
    axis: "x",
    start: (e) =>
      D.p === 1 &&
      !e.target.closest(".drow") &&
      !e.target.closest(".drow-actions") &&
      !e.target.closest(".dlist"),
    begin: () => {
      drawerDragging = true;
      D.set(1, false);
    },
    move: (e, g) => {
      if (!drawerDragging) return;
      D.set(1 + g.dx / D.width, false);
    },
    end: (e, g) => {
      if (!drawerDragging) return;
      drawerDragging = false;
      const p = 1 + g.dx / D.width;
      if (p < 0.6 || g.vx < -0.45) D.close();
      else D.set(1, true);
    },
  });

  scrim.addEventListener("click", () => D.close());

  /* ---------------------------------------------------------- 会话列表行:左滑归档/删除 */
  const ROW_ACTIONS = 152; // 76*2
  let openRow = null;
  function closeRow(row, animate = true) {
    const el = row.querySelector(".drow");
    el.style.transition = animate ? "transform var(--d2) var(--ease)" : "none";
    el.style.transform = "translate3d(0,0,0)";
    row.dataset.x = "0";
    if (openRow === row) openRow = null;
  }
  $$(".drow-wrap").forEach((wrap) => {
    const row = wrap.querySelector(".drow");
    row.dataset.x = "0";
    onDrag(row, {
      axis: "x",
      move: (e, g) => {
        if (openRow && openRow !== wrap) closeRow(openRow);
        const base = parseFloat(row.dataset.x) || 0;
        let x = base + g.dx;
        if (x > 0) x *= 0.25; // 右划阻尼
        x = clamp(x, -ROW_ACTIONS - 12, 0);
        row.style.transition = "none";
        row.style.transform = `translate3d(${x}px,0,0)`;
      },
      end: (e, g) => {
        const base = parseFloat(row.dataset.x) || 0;
        const x = base + g.dx;
        const open = x < -ROW_ACTIONS / 2.6 || g.vx < -0.4;
        row.dataset.x = open ? String(-ROW_ACTIONS) : "0";
        row.style.transition = "transform var(--d2) var(--ease)";
        row.style.transform = `translate3d(${open ? -ROW_ACTIONS : 0}px,0,0)`;
        openRow = open ? wrap : null;
      },
    });
    wrap.querySelector(".drow-actions .arc").addEventListener("click", () => {
      haptic();
      wrap.style.transition = "opacity var(--d2) var(--ease), height var(--d2) var(--ease)";
      wrap.style.height = wrap.offsetHeight + "px";
      requestAnimationFrame(() => {
        wrap.style.opacity = "0";
        wrap.style.height = "0";
        setTimeout(() => wrap.remove(), 220);
      });
      toast("已归档");
    });
    wrap.querySelector(".drow-actions .del").addEventListener("click", () => {
      haptic(20);
      openSheet({
        title: "删除会话",
        body: `<p style="padding:2px 8px 12px;color:var(--on3);font-size:13px">
          删除后电脑端的会话记录不受影响,只是从手机的列表里移除。</p>`,
        actions: [
          { label: "取消", kind: "out", onClick: closeSheet },
          {
            label: "删除",
            kind: "danger",
            onClick: () => {
              closeSheet();
              wrap.remove();
              toast("已从列表移除");
            },
          },
        ],
      });
    });
  });
  $("#dlist") &&
    $("#dlist").addEventListener("click", (e) => {
      /* 点一行会话 = 打开它 —— 打开的是**有内容的**会话,所以离开 blank 那一屏。
         (真机上同理:blank 会话之外的会话一打开,hero 就让位给消息流。) */
      if (e.target.closest(".drow")) setBlankSession(false);
      if (openRow && !e.target.closest(".drow-wrap")) closeRow(openRow);
    });

  /* ---------------------------------------------------------- 会话搜索
     之前那个"搜索会话"是个只弹 toast 的假框,点了没反应。现在真过滤列表:
     匹配标题 + 摘要,按日期分组标题在无结果时一起隐藏。 */
  const dsInput = $("#drawerSearch");
  const dsClear = $("#drawerSearchClear");
  const dsEmpty = $("#drawerEmpty");
  function applyDrawerSearch() {
    const kw = (dsInput ? dsInput.value : "").trim().toLowerCase();
    if (dsClear) dsClear.hidden = kw === "";
    let hit = 0;
    const wraps = $$(".drow-wrap");
    wraps.forEach((w) => {
      const txt = w.textContent.toLowerCase();
      const on = kw === "" || txt.indexOf(kw) >= 0;
      w.hidden = !on;
      if (on) hit++;
    });
    /* 分组标题:该组下没有可见行就一起藏起来 */
    $$(".dsec").forEach((sec) => {
      let n = sec.nextElementSibling;
      let any = false;
      while (n && !n.classList.contains("dsec")) {
        if (n.classList.contains("drow-wrap") && !n.hidden) any = true;
        n = n.nextElementSibling;
      }
      sec.hidden = !any;
    });
    if (dsEmpty) {
      dsEmpty.hidden = kw === "" || hit > 0;
      dsEmpty.textContent = "没有匹配「" + (dsInput ? dsInput.value.trim() : "") + "」的会话。";
    }
  }
  if (dsInput) {
    dsInput.addEventListener("input", applyDrawerSearch);
    dsInput.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        dsInput.value = "";
        applyDrawerSearch();
        dsInput.blur();
      }
    });
  }
  /* ---------------------------------------------------------- 下拉刷新(抽屉会话列表) */
  const dlist = $("#dlist");
  const ptr = $("#ptr");
  if (dlist && ptr) {
    const ptrLabel = ptr.querySelector(".lbl");
    let pulling = false;
    onDrag(dlist, {
      axis: "y",
      threshold: 6,
      start: () => dlist.scrollTop <= 0 && !ptr.classList.contains("is-busy"),
      begin: () => {
        pulling = true;
        dlist.style.transition = "none";
      },
      move: (e, g) => {
        if (g.dy <= 0) return;
        const y = Math.min(g.dy * 0.45, 64);
        dlist.style.transform = `translate3d(0,${y}px,0)`;
        ptr.style.opacity = String(Math.min(y / 48, 1));
        ptrLabel.textContent = y > 44 ? "松开刷新" : "下拉刷新";
      },
      end: (e, g) => {
        if (!pulling) return;
        pulling = false;
        const y = g.dy * 0.45;
        dlist.style.transition = "transform var(--d3) var(--ease)";
        if (y > 44 || g.vy > 0.5) {
          dlist.style.transform = "translate3d(0,48px,0)";
          ptr.style.opacity = "1";
          ptr.classList.add("is-spin", "is-busy");
          ptrLabel.textContent = "同步中…";
          setTimeout(() => {
            dlist.style.transform = "translate3d(0,0,0)";
            ptr.classList.remove("is-spin", "is-busy");
            ptr.style.opacity = "0";
            ptrLabel.textContent = "下拉刷新";
            toast("已同步 · 4 个会话");
          }, 1100);
        } else {
          dlist.style.transform = "translate3d(0,0,0)";
          ptr.style.opacity = "0";
        }
      },
    });
  }

  /* ---------------------------------------------------------- 分段控件 + 滑动切页 */
  function setupPager(segEl, pagerEl) {
    const track = pagerEl.querySelector(".pager-track");
    const ind = segEl.querySelector(".seg-ind");
    const btns = $$(".seg-btn", segEl);
    const n = btns.length;
    let index = 0;
    let dragging = false;

    const w = () => pagerEl.clientWidth;
    const render = (pos, animate) => {
      track.style.transition = animate
        ? "transform var(--d3) var(--ease)"
        : "none";
      track.style.transform = `translate3d(${-pos * w()}px,0,0)`;
      if (ind) {
        ind.style.transition = animate ? "transform var(--d2) var(--ease)" : "none";
        ind.style.transform = `translate3d(${pos * 100}%,0,0)`;
      }
      btns.forEach((b, i) =>
        b.classList.toggle("is-on", Math.abs(pos - i) < 0.5)
      );
    };
    const go = (i) => {
      index = clamp(i, 0, n - 1);
      render(index, true);
      pagerEl.dispatchEvent(new CustomEvent("page", { detail: index }));
    };
    btns.forEach((b, i) =>
      b.addEventListener("click", () => {
        haptic();
        go(i);
      })
    );
    onDrag(pagerEl, {
      axis: "x",
      threshold: 10,
      start: (e) => !e.target.closest("input, textarea, .gantt"),
      begin: () => {
        dragging = true;
        render(index, false);
      },
      move: (e, g) => {
        if (!dragging) return;
        let pos = index - g.dx / w();
        if (pos < 0) pos *= 0.3;
        if (pos > n - 1) pos = n - 1 + (pos - (n - 1)) * 0.3;
        render(pos, false);
      },
      end: (e, g) => {
        if (!dragging) return;
        dragging = false;
        const pos = index - g.dx / w();
        let target = index;
        if ((g.vx < -0.4 || pos > index + 0.28) && index < n - 1) target = index + 1;
        else if ((g.vx > 0.4 || pos < index - 0.28) && index > 0) target = index - 1;
        go(target);
      },
    });
    return { go, get index() { return index; } };
  }
  const mainPager = setupPager($("#mainSeg"), $("#pager"));

  /* ---------------------------------------------------------- bottom sheet */
  const sheetHost = $("#sheetHost");
  let sheetEl = null;
  let sheetScrim = null;
  let sheetCloseCb = null;

  /* 只拆 DOM,不动返回栈。切 sheet(比如"访问模式 → 风险确认门")时用它,
     否则 closeSheet 的 history.back() 是异步 popstate,落地时新 sheet 已压栈,
     会被自愈逻辑当成多余的层关掉。 */
  function teardownSheet() {
    if (sheetEl) {
      sheetEl.remove();
      sheetEl = null;
    }
    if (sheetScrim) {
      sheetScrim.remove();
      sheetScrim = null;
    }
    if (sheetHost) sheetHost.style.pointerEvents = "none";
  }

  function openSheet({ title, body, actions, onMount, size }) {
    /* 已经有一层 sheet 时复用这一层,不再 close+push,避免返回栈竞态 */
    const reuse = topLayer() && topLayer().kind === "sheet";
    teardownSheet();
    sheetScrim = document.createElement("div");
    sheetScrim.className = "sheet-scrim";
    sheetEl = document.createElement("div");
    sheetEl.className = "sheet";
    sheetEl.setAttribute("role", "dialog");
    sheetEl.setAttribute("aria-modal", "true");
    if (size === "half") sheetEl.style.maxHeight = "62%";
    sheetEl.innerHTML = `
      <div class="sheet-grab"><i></i></div>
      <div class="sheet-h">${title || ""}
        <button class="ib" data-sheet-close aria-label="关闭">${ic("close", 16)}</button>
      </div>
      <div class="sheet-b">${body || ""}</div>
      ${
        actions
          ? `<div style="display:flex;gap:8px;padding:6px 12px 10px">${actions
              .map(
                (a, i) =>
                  `<button class="btn btn--${a.kind || "out"}" data-sheet-act="${i}">${a.label}</button>`
              )
              .join("")}</div>`
          : ""
      }`;
    sheetHost.appendChild(sheetScrim);
    sheetHost.appendChild(sheetEl);
    sheetHost.style.pointerEvents = "auto";
    requestAnimationFrame(() => {
      sheetScrim.style.opacity = "0.45";
      sheetEl.classList.add("is-on");
    });

    sheetScrim.addEventListener("click", () => closeSheet());
    $$("[data-sheet-close]", sheetEl).forEach((b) =>
      b.addEventListener("click", () => closeSheet())
    );
    if (actions) {
      $$("[data-sheet-act]", sheetEl).forEach((b, i) => {
        b.onclick = () => actions[i].onClick && actions[i].onClick();
      });
    }

    /* 下拉关闭:抓手/标题区随时可拖,内容区仅在滚到顶时可拖 */
    let active = false;
    onDrag(sheetEl, {
      axis: "y",
      threshold: 6,
      start: (e) => {
        if (e.target.closest("[data-sheet-close], .btn")) return false;
        const b = e.target.closest(".sheet-b");
        if (b) return b.scrollTop <= 0;
        return true;
      },
      begin: () => {
        active = true;
        sheetEl.style.transition = "none";
      },
      move: (e, g) => {
        if (!active) return;
        sheetEl.style.transform = `translate3d(0,${Math.max(0, g.dy)}px,0)`;
        sheetScrim.style.opacity = String(0.45 * (1 - Math.min(g.dy / 400, 1)));
      },
      end: (e, g) => {
        if (!active) return;
        active = false;
        sheetEl.style.transition = "";
        if (g.dy > 110 || g.vy > 0.55) {
          const s = sheetEl,
            sc = sheetScrim;
          s.style.transform = "translate3d(0,100%,0)";
          sc.style.opacity = "0";
          setTimeout(() => {
            s.remove();
            sc.remove();
            sheetHost.style.pointerEvents = "none";
          }, 260);
          if (sheetCloseCb) sheetCloseCb();
          sheetEl = null;
          sheetScrim = null;
          closeLayer("sheet");
        } else {
          sheetEl.style.transform = "";
          sheetScrim.style.opacity = "0.45";
        }
      },
    });

    sheetCloseCb = onMount && onMount(sheetEl);
    /* 复用已有 sheet 层时不再压栈:返回键/手势仍然只退一层 */
    if (!reuse) openLayer("sheet", () => closeSheet(true));
    haptic();
  }

  function closeSheet(immediate) {
    if (!sheetEl) return;
    if (immediate === true) {
      sheetEl.remove();
      sheetScrim && sheetScrim.remove();
      sheetHost.style.pointerEvents = "none";
      sheetEl = null;
      sheetScrim = null;
      const l = topLayer();
      if (l && l.kind === "sheet") closeLayer("sheet");
      return;
    }
    const s = sheetEl,
      sc = sheetScrim;
    s.style.transform = "translate3d(0,100%,0)";
    sc.style.opacity = "0";
    setTimeout(() => {
      s.remove();
      sc.remove();
      sheetHost.style.pointerEvents = "none";
    }, 260);
    sheetEl = null;
    sheetScrim = null;
    if (sheetCloseCb) sheetCloseCb();
    closeLayer("sheet");
    haptic();
  }

  /* ---------------------------------------------------------- toast */
  let toastEl = null,
    toastT = null;
  function toast(msg) {
    if (!toastEl) {
      toastEl = document.createElement("div");
      toastEl.className = "toast";
      appRoot.appendChild(toastEl);
    }
    toastEl.textContent = msg;
    requestAnimationFrame(() => toastEl.classList.add("is-on"));
    clearTimeout(toastT);
    toastT = setTimeout(() => toastEl.classList.remove("is-on"), 1800);
  }

  /* ---------------------------------------------------------- 排队条(QueueDock) */
  /* 会话正在跑时发出去的消息排进下一个轮次。数据源在真机是 `inbox` 投影的
     next-turn 段(契约 §5.7),这里用演示数据把交互基线定下来:
     计数头(多条时折叠)+ 行内 编辑/删除/插话。三个动作都走 session.updateQueue
     (与 Web 排队 dock 同一个 DSH 方法)。 */
  const queueDock = $("#queueDock");
  const queueState = {
    // 演示数据:两条 next-turn(一条带附件)。
    items: [
      { id: "q-1", text: "顺便把 README 的安装章节也更新一下", attachments: 0 },
      { id: "q-2", text: "这是回归截图", attachments: 2 },
    ],
    running: true, // 插话门:仅运行中可插话发送
    collapsed: true,
  };
  function renderQueueDock() {
    if (!queueDock) return;
    const items = queueState.items;
    if (items.length === 0) {
      queueDock.hidden = true;
      queueDock.innerHTML = "";
      return;
    }
    queueDock.hidden = false;
    const single = items.length === 1;
    const expanded = single || !queueState.collapsed;
    const head = single
      ? ""
      : `<button class="qdock-head" data-qd="toggle" aria-expanded="${expanded}">
           <span data-icon="queue" data-icon-size="14"></span>
           <span class="grow">${items.length} 条排队消息</span>
           <span data-icon="${expanded ? "chevronDown" : "chevronRight"}" data-icon-size="14"></span>
         </button>`;
    const rows = expanded
      ? items
          .map(
            (it) => `
        <div class="qdock-row" data-qd-row="${it.id}">
          ${single ? '<span data-icon="queue" data-icon-size="14"></span>' : ""}
          <div class="grow" style="flex:1;min-width:0">
            <div class="qdock-preview">${escapeHtml(it.text)}</div>
            ${it.attachments ? `<div class="qdock-attach">${it.attachments} 个附件（不随编辑发送）</div>` : ""}
          </div>
          <div class="qdock-acts">
            <button class="qdock-act" data-qd="edit" data-qd-id="${it.id}" aria-label="编辑排队消息" title="编辑排队消息"${it.attachments ? " disabled title='带附件的消息编辑不了（只发文本）'" : ""}><span data-icon="listPen" data-icon-size="14"></span></button>
            <button class="qdock-act" data-qd="remove" data-qd-id="${it.id}" aria-label="删除排队消息" title="删除排队消息"><span data-icon="closeFill" data-icon-size="14"></span></button>
            <button class="qdock-act" data-qd="steer" data-qd-id="${it.id}" aria-label="插话发送" title="${queueState.running ? "插话发送" : "仅运行中可插话发送"}"${queueState.running ? "" : " disabled"}><span data-icon="paperPlane" data-icon-size="14"></span></button>
          </div>
        </div>`
          )
          .join("")
      : "";
    queueDock.innerHTML = head + rows;
    paintIcons(queueDock);
  }
  function escapeHtml(s) {
    return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
  if (queueDock) {
    renderQueueDock();
    queueDock.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-qd]");
      if (!btn) return;
      const act = btn.dataset.qd;
      if (act === "toggle") {
        queueState.collapsed = !queueState.collapsed;
        renderQueueDock();
        haptic();
        return;
      }
      const id = btn.dataset.qdId;
      const item = queueState.items.find((i) => i.id === id);
      if (!item) return;
      // 演示:三个动作只给出结论(真机走 session.updateQueue)。
      if (act === "edit") toast("编辑排队消息（演示）");
      if (act === "remove") {
        queueState.items = queueState.items.filter((i) => i.id !== id);
        renderQueueDock();
        toast("已删除排队消息");
      }
      if (act === "steer") toast("已请求插话发送");
      haptic();
    });
  }

  /* ---------------------------------------------------------- 会话页:滚动 / 长按 / 工具折叠 */
  const msgScroll = $("#msgs");
  const fabDown = $("#fabDown");
  if (msgScroll) {
    msgScroll.addEventListener(
      "scroll",
      () => {
        const far =
          msgScroll.scrollHeight - msgScroll.scrollTop - msgScroll.clientHeight > 240;
        fabDown.classList.toggle("is-on", far);
      },
      { passive: true }
    );
    fabDown.addEventListener("click", () => {
      msgScroll.scrollTo({ top: msgScroll.scrollHeight, behavior: "smooth" });
      haptic();
    });
  }

  $$("[data-longpress-msg]").forEach((el) => {
    onDrag(el, {
      longPress: () => {
        openSheet({
          title: "消息",
          body: `
            <button class="sitem" data-sheet-close><span class="i">${ic("copy", 16)}</span><span class="m">复制文本</span></button>
            <button class="sitem" data-sheet-close><span class="i">${ic("refresh", 16)}</span><span class="m">从这条重发</span></button>
            <button class="sitem" data-sheet-close><span class="i">${ic("branch", 16)}</span><span class="m">分支出新会话</span><span class="s">保留上文</span></button>
            <button class="sitem" data-sheet-close><span class="i">${ic("like", 16)}</span><span class="m">反馈</span></button>`,
        });
      },
    });
  });

  $$(".tool-r").forEach((r) =>
    r.addEventListener("click", () => {
      r.closest(".tool").classList.toggle("is-open");
      haptic();
    })
  );

  /* ---------------------------------------------------------- 输入栏 */
  const ta = $("#input");
  const send = $("#send");
  const rail = $("#attachRail");

  /* 模型目录:照 DSH —— 推理等级是**按模型**的能力(reasoning.efforts / defaultEffort),
     不是全局设置;没有等级的模型在菜单里显示「当前模型未提供推理等级」。 */
  const MODELS = [
    {
      id: "claude-opus",
      name: "claude-opus",
      provider: "Anthropic",
      vision: true,
      efforts: [
        { id: "low", name: "低" },
        { id: "medium", name: "中" },
        { id: "high", name: "高" },
        { id: "max", name: "最高" },
      ],
      def: "high",
    },
    {
      id: "gpt-5-codex",
      name: "gpt-5-codex",
      provider: "OpenAI",
      vision: true,
      efforts: [
        { id: "off", name: "关" },
        { id: "low", name: "低" },
        { id: "high", name: "高" },
        { id: "max", name: "最高" },
      ],
      def: "high",
    },
    {
      id: "deepseek-v4-flash",
      name: "deepseek-v4-flash",
      provider: "DeepSeek 账号",
      vision: false,
      efforts: [
        { id: "standard", name: "标准" },
        { id: "max", name: "最高" },
      ],
      def: "standard",
    },
    {
      id: "kimi-k2",
      name: "kimi-k2",
      provider: "Moonshot",
      vision: true,
      efforts: [],
      def: undefined,
    },
  ];
  const sel = { model: "claude-opus", effort: "high" };
  const modelOf = (id) => MODELS.find((m) => m.id === id) || MODELS[0];
  const effortName = () => {
    const m = modelOf(sel.model);
    const e = m.efforts.find((x) => x.id === sel.effort);
    return e ? e.name : undefined;
  };

  function paintModelChip() {
    const chip = $("#chipModel");
    if (!chip) return;
    const label = modelOf(sel.model).name;
    const eff = effortName();
    chip.innerHTML =
      ic("sparkle", 15) +
      "<b>" + label + "</b>" +
      (eff ? `<span class="cap">· ${eff}</span>` : "") +
      '<span class="cap">▾</span>';
  }

  /* 模型与推理等级:根面板两格 → 钻取到模型列表 / 等级列表(照 ModelSelect)。
     权限模式也收进这里(DSH 是 composer 上的两个 seat,手机窄屏合成一个入口),
     这样输入区不用常驻一排 chip。 */
  function openModelPicker() {
    let pane = "root";
    let q = "";
    const render = (sheet) => {
      const body = sheet.querySelector(".sheet-b");
      const m = modelOf(sel.model);
      const eff = effortName();
      const perm = Takeovers.permissionInfo;
      if (pane === "root") {
        body.innerHTML = `<div class="picker">
          <button class="picker-cell" data-pk="model"><span class="k">模型</span>
            <span class="v">${m.name}</span><span class="cv">${ic("chevronRight", 16)}</span></button>
          <button class="picker-cell" data-pk="effort"><span class="k">推理等级</span>
            <span class="v">${eff || "Default"}</span><span class="cv">${ic(
          "chevronRight",
          16
        )}</span></button>
        </div>`;
      } else if (pane === "model") {
        const groups = {};
        MODELS.filter(
          (x) => q === "" || x.name.toLowerCase().indexOf(q.toLowerCase()) >= 0
        ).forEach((x) => {
          (groups[x.provider] = groups[x.provider] || []).push(x);
        });
        body.innerHTML =
          `<div class="picker-back" data-pk="root">${ic(
            "chevronLeft",
            16
          )} 模型与推理等级</div>
           <label class="searchbox">${ic("search", 16)}
             <input id="pkSearch" placeholder="搜索模型…" value="${q}"></label>` +
          (Object.keys(groups).length === 0
            ? '<div class="pempty">没有匹配的模型。</div>'
            : Object.keys(groups)
                .map(
                  (g) =>
                    `<div class="pgroup">${g}</div>` +
                    groups[g]
                      .map(
                        (x) => `<button class="prow" data-pm="${x.id}">
                          <span class="pcopy">
                            <span class="nm">${x.name}</span>
                            <span class="tags">
                              <span class="ptag">${
                                x.vision ? "图片" : "纯文本"
                              }</span>
                              ${
                                (x.efforts || []).length
                                  ? '<span class="ptag">推理</span>'
                                  : ""
                              }
                            </span>
                          </span>
                          <span class="ck">${
                            sel.model === x.id ? ic("check", 16) : ""
                          }</span>
                        </button>`
                      )
                      .join("")
                )
                .join(""));
        const box = body.querySelector("#pkSearch");
        box.addEventListener("input", () => {
          q = box.value;
          render(sheet);
          const b2 = sheet.querySelector("#pkSearch");
          b2.focus();
          b2.setSelectionRange(b2.value.length, b2.value.length);
        });
      } else {
        body.innerHTML =
          `<div class="picker-back" data-pk="root">${ic(
            "chevronLeft",
            16
          )} 模型与推理等级</div>` +
          (m.efforts.length === 0
            ? '<div class="pempty">当前模型未提供推理等级。</div>'
            : '<div class="picker">' +
              `<button class="prow" data-pe="__default">
                 <span class="pcopy">
                   <span class="nm">Default</span>
                   <span class="tags"><span class="ptag">跟随模型默认</span></span>
                 </span>
                 <span class="ck">${eff === undefined ? ic("check", 16) : ""}</span>
               </button>` +
              m.efforts
                .map(
                  (e) => `<button class="prow" data-pe="${e.id}">
                    <span class="pcopy"><span class="nm">${e.name}</span></span>
                    <span class="ck">${
                      eff === e.name ? ic("check", 16) : ""
                    }</span>
                  </button>`
                )
                .join("") +
              "</div>");
      }
      $$("[data-pk]", body).forEach((b) =>
        b.addEventListener("click", () => {
          pane = b.dataset.pk;
          haptic();
          render(sheet);
        })
      );
      $$("[data-pm]", body).forEach((b) =>
        b.addEventListener("click", () => {
          sel.model = b.dataset.pm;
          const nm = modelOf(sel.model);
          sel.effort = nm.def; // 换模型 = 等级跟着换(DSH 提交的是 provider+model+effort)
          paintModelChip();
          pane = "root";
          haptic();
          render(sheet);
        })
      );
      $$("[data-pe]", body).forEach((b) =>
        b.addEventListener("click", () => {
          const v = b.dataset.pe;
          sel.effort =
            v === "__default"
              ? undefined
              : modelOf(sel.model).efforts.find((e) => e.id === v).id;
          paintModelChip();
          pane = "root";
          haptic();
          render(sheet);
        })
      );
      $$("[data-pp]", body).forEach((b) =>
        b.addEventListener("click", () => {
          const id = b.dataset.pp;
          haptic();
          if (id === "danger-full-access" || id === "auto") {
            /* 风险档要走确认门,不能一步到位 */
            closeSheet();
            Takeovers.gateSheet(openSheet, id);
            return;
          }
          Takeovers.setPermission(id);
          render(sheet);
        })
      );
    };
    openSheet({
      title: "模型与推理等级",
      size: "half",
      body: '<div class="picker"></div>',
      onMount: (sheet) => render(sheet),
    });
  }

  /* ---------------------------------------------------------- 附件
     照 ui-attachment:草稿轨 + FileCard(上传中/就绪/失败重试);图片可看原图。 */
  const drafts = [];
  let draftSeq = 0;
  const SAMPLE_IMG =
    "data:image/svg+xml;utf8," +
    encodeURIComponent(
      `<svg xmlns="http://www.w3.org/2000/svg" width="900" height="600"><rect width="900" height="600" fill="#233C2C"/><circle cx="240" cy="200" r="90" fill="#41C977" opacity=".45"/><text x="40" y="540" font-family="monospace" font-size="34" fill="#41C977">相册照片 900x600</text></svg>`
    );

  function renderRail() {
    if (!rail) return;
    rail.hidden = drafts.length === 0;    rail.innerHTML = drafts
      .map((d) => {
        if (d.kind === "image") {
          return `<div class="athumb" data-draft="${d.id}">
            <img src="${SAMPLE_IMG}" alt="待发送图片">
            <button class="rm" data-rm="${d.id}" aria-label="移除图片 ${d.name}">${ic(
            "closeFill",
            12
          )}</button></div>`;
        }
        const meta =
          d.status === "uploading"
            ? "上传中…"
            : d.status === "error"
            ? "上传失败,点击重试"
            : d.ext + " " + d.size;
        const failed = d.status === "error";
        return `<div class="fcard${failed ? " is-err" : ""}" data-draft="${d.id}">
          <span class="ic">${
            d.status === "uploading"
              ? '<span class="fspin"></span>'
              : ic("folderClose", 16)
          }</span>
          ${
            failed
              ? `<button class="body" data-retry="${d.id}" aria-label="重试上传 ${d.name}">
                   <span class="nm">${d.name}</span><span class="mt">${meta}</span></button>`
              : `<span class="body"><span class="nm">${d.name}</span>
                   <span class="mt">${meta}</span></span>`
          }
          <button class="rm" data-rm="${d.id}" aria-label="移除文件 ${d.name}">${ic(
          "closeFill",
          12
        )}</button>
          ${
            d.status === "uploading"
              ? `<span class="ptrack"><span class="pbar" style="width:${Math.round(
                  d.progress * 100
                )}%"></span></span>`
              : ""
          }
        </div>`;
      })
      .join("");
    $$("[data-rm]", rail).forEach((b) =>
      b.addEventListener("click", () => {
        const i = drafts.findIndex((d) => d.id === b.dataset.rm);
        if (i >= 0) drafts.splice(i, 1);
        renderRail();
        haptic();
      })
    );
    $$("[data-retry]", rail).forEach((b) =>
      b.addEventListener("click", () => startUpload(b.dataset.retry))
    );
    autogrow(); // 有附件 = 可发送,发送键状态必须跟着附件变
  }

  function startUpload(id) {
    const d = drafts.find((x) => x.id === id);
    if (!d) return;
    d.status = "uploading";
    d.progress = 0;
    renderRail();
    const t = setInterval(() => {
      d.progress += 0.28 + Math.random() * 0.18;
      if (d.progress >= 1) {
        clearInterval(t);
        d.progress = 1;
        d.status = "ready";
      }
      renderRail();
    }, 260);
  }

  function addAttachment(kind) {
    const id = "d" + ++draftSeq;
    if (kind === "image") {
      drafts.push({ id, kind: "image", name: "IMG_2481.png" });
      renderRail();
      toast("图片已加入待发送");
    } else {
      drafts.push({
        id,
        kind: "file",
        name: kind === "camera" ? "扫描件.pdf" : "bridge-protocol.md",
        ext: kind === "camera" ? "PDF" : "MD",
        size: kind === "camera" ? "412 KB" : "18.4 KB",
        status: "uploading",
        progress: 0,
      });
      startUpload(id);
      toast("文件上传中…");
    }
    haptic();
  }

  function openAttachSheet() {
    openSheet({
      title: "添加文件或调用指令",
      size: "half",
      body: `
        <button class="sitem" data-att="camera"><span class="i">${ic(
          "browse",
          16
        )}</span><span class="m">拍照<span class="s">扫描件 / 白板,直接进附件</span></span></button>
        <button class="sitem" data-att="image"><span class="i">${ic(
          "deliverDoc",
          16
        )}</span><span class="m">相册<span class="s">仅支持 PNG / JPG / WebP / GIF</span></span></button>
        <button class="sitem" data-att="file"><span class="i">${ic(
          "folderClose",
          16
        )}</span><span class="m">文件<span class="s">上传到电脑端 staging,再随消息发出</span></span></button>
        <div class="pgroup">会话内</div>
        <button class="sitem" data-act="toast" data-msg="工作区文件页(接 bridge 后开)"><span class="i">${ic(
          "workspaceTree",
          16
        )}</span><span class="m">工作区文件<span class="s">浏览会话工作区的文件</span></span></button>
        <button class="sitem" data-act="toast" data-msg="终端页(接 bridge 后开)"><span class="i">${ic(
          "api",
          16
        )}</span><span class="m">新建终端<span class="s">在会话工作区运行命令</span></span></button>
        <button class="sitem" data-act="toast" data-msg="内置浏览器"><span class="i">${ic(
          "globe",
          16
        )}</span><span class="m">浏览器<span class="s">浏览网页</span></span></button>
        <button class="sitem" data-act="jobs-all"><span class="i">${ic(
          "checklist",
          16
        )}</span><span class="m">后台任务<span class="s">看运行中的命令与输出</span></span></button>
        <p class="opt-desc" style="padding:12px 12px 0">手机端没有拖拽与快捷键,所以附件与
        会话内动作都收进这个入口(对应桌面端 ＋ 菜单:工作区文件 Ctrl+P / 新建终端 Ctrl+\` / 浏览器 Ctrl+T)。</p>`,
      onMount: (sheet) => {
        $$("[data-att]", sheet).forEach((b) =>
          b.addEventListener("click", () => {
            addAttachment(b.dataset.att);
            closeSheet();
          })
        );
      },
    });
  }

  function autogrow() {
    if (!ta) return;
    ta.style.height = "auto";
    ta.style.height = Math.min(ta.scrollHeight, 132) + "px";
    if (send)
      send.disabled =
        ta.value.trim().length === 0 && drafts.length === 0 && !running;
  }
  ta && ta.addEventListener("input", autogrow);
  ta && ta.addEventListener("focus", () => setTimeout(() => {
    msgScroll && msgScroll.scrollTo({ top: msgScroll.scrollHeight });
  }, 260));

  if (window.visualViewport) {
    const vv = window.visualViewport;
    const apply = () => {
      const kb = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
      document.documentElement.style.setProperty("--kb", kb + "px");
    };
    vv.addEventListener("resize", apply);
    vv.addEventListener("scroll", apply);
  }

  let running = false;
  function setRunning(on) {
    running = on;
    if (!send) return;
    send.innerHTML = on ? STOP_SVG : SEND_SVG;
    send.setAttribute("aria-label", on ? "停止生成" : "发送消息");
    send.disabled = on ? false : ta.value.trim().length === 0 && drafts.length === 0;
    /* 运行中不再占一行提示:底栏统计片已经用转圈图标表达了 */
    const first = $(".stat");
    if (first)
      first.innerHTML = on
        ? ic("loading", 13) + " 运行中…"
        : ic("gauge", 13) + " 第 1 轮 · 3 步";
  }
  send &&
    send.addEventListener("click", () => {
      haptic();
      if (running) {
        setRunning(false);
        toast("已发送打断");
        return;
      }
      if (drafts.some((d) => d.status === "uploading")) {
        toast("文件还在上传,请等待上传完成后发送");
        return;
      }
      const text = ta.value.trim();
      if (!text && drafts.length === 0) return;
      appendUser(text || "(仅附件)", drafts.slice());
      drafts.length = 0;
      renderRail();
      ta.value = "";
      autogrow();
      setRunning(true);
      msgScroll.scrollTo({ top: msgScroll.scrollHeight, behavior: "smooth" });
      setTimeout(() => {
        setRunning(false);
        appendAssistant(text);
        msgScroll.scrollTo({ top: msgScroll.scrollHeight, behavior: "smooth" });
      }, 1400);
    });

  function appendUser(text, files) {
    const d = document.createElement("div");
    d.className = "turn turn--u";
    const list = files || [];
    d.innerHTML =
      `<div class="b">` +
      (list.length
        ? `<div class="sent-atts">` +
          list
            .map((f) =>
              f.kind === "image"
                ? `<img class="sent-img" src="${SAMPLE_IMG}" alt="已发送图片" data-act="img-open" data-i="0">`
                : `<span class="sent-file">${ic("folderClose", 14)} ${f.name} · ${
                    f.size || ""
                  }</span>`
            )
            .join("") +
          `</div>`
        : "") +
      `<span class="tx"></span></div>`;
    d.querySelector(".tx").textContent = text;
    msgScroll.appendChild(d);
  }
  function appendAssistant(prompt) {
    const d = document.createElement("div");
    d.className = "turn a";
    d.innerHTML = `
      <div class="a-head"><span class="a-ava">${ic("sparkle", 14)}</span><span class="a-who">助手</span>
      <span class="a-mdl">· ${modelOf(sel.model).name}${
      effortName() ? " · " + effortName() : ""
    }</span></div>
      <div class="md"><p data-typing></p></div>`;
    msgScroll.appendChild(d);
    const p = d.querySelector("[data-typing]");
    const full =
      "已收到。这一轮在电脑端执行,手机上可以继续刷会话,完成后推送通知你。";
    let i = 0;
    const t = setInterval(() => {
      p.textContent = full.slice(0, ++i);
      if (i >= full.length) clearInterval(t);
    }, 26);
  }

  /* ============================================================
     后台任务(ui-jobs):行内折叠区 + 全屏页共用一套渲染
     ============================================================ */
  const esc2 = (s) =>
    String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  /* 状态机照 packages/jobs/jobs/src/view.ts:19:
     running | stopping | completed | killed | failed(终态恰好一个)。
     文案照 ui-jobs/src/client/locales.ts:22-26。终止原因来自 JobOutcome.detail,
     人类 kill 固定写 'cancelled by the user';**没有** 'killed before exit' 这种文案。
     JobView 里也没有独立 command 字段 —— "命令"就是 label。 */
  const JOBS = [
    {
      id: "j1",
      kind: "pwsh",
      label: "flutter build apk --debug",
      state: "running",
      started: Date.now() - 134000,
      out:
        "Running Gradle task 'assembleDebug'...\n" +
        "Resolving dependencies...\n" +
        "> Task :app:compileFlutterBuildDebug\n" +
        "(构建在电脑端进行,手机只看进度)",
    },
    {
      id: "j5",
      kind: "pwsh",
      label: "flutter run -d chrome",
      state: "stopping",
      detail: "已发出停止请求,等电脑端的权威帧",
      started: Date.now() - 42000,
      out: "Launching lib/main.dart on Chrome in debug mode...\n(stop 已发送)",
    },
    {
      id: "j2",
      kind: "pwsh",
      label: "flutter pub get",
      state: "completed",
      detail: "exit code: 0",
      dur: 18,
      out: "Resolving dependencies...\nGot dependencies!",
    },
    {
      id: "j3",
      kind: "pwsh",
      label: "dart run build_runner build",
      state: "killed",
      detail: "cancelled by the user",
      dur: 192,
      out: "[INFO] Generating build script...\n^C cancelled by the user",
    },
    {
      id: "j4",
      kind: "pwsh",
      label: "npx tsc --noEmit",
      state: "failed",
      detail: "exit code: 2",
      dur: 54,
      out: "bridge_client.dart(214,7): error TS2322: Type 'string' is not assignable…",
    },
  ];
  const JOB_DOT = {
    running: "ongoing",
    stopping: "warning",
    completed: "done",
    killed: "idle",
    failed: "error",
  };
  const JOB_LABEL = {
    running: "运行中",
    stopping: "正在停止",
    completed: "已完成",
    killed: "已取消",
    failed: "已失败",
  };
  const isLive = (j) => j.state === "running" || j.state === "stopping";
  const fmtDur = (s) =>
    s >= 3600
      ? Math.floor(s / 3600) + "小时" + Math.floor((s % 3600) / 60) + "分"
      : s >= 60
      ? Math.floor(s / 60) + "分" + (s % 60) + "秒"
      : s + "秒";
  const fmtClock = (s) =>
    String(Math.floor(s / 60)).padStart(2, "0") +
    ":" +
    String(s % 60).padStart(2, "0");

  function jobDot(state) {
    const s = JOB_DOT[state] || "idle";
    return s === "ongoing"
      ? '<svg class="sdot-spin" viewBox="0 0 24 24" aria-hidden="true"><g class="motion">' +
          '<circle class="trk" cx="12" cy="12" r="9.5"/><circle class="arc" cx="12" cy="12" r="9.5"/></g></svg>'
      : `<span class="sdot" data-state="${s}"></span>`;
  }

  function jobRow(j, openSet) {
    const live = isLive(j);
    const dur = live
      ? fmtClock(Math.round((Date.now() - j.started) / 1000))
      : fmtDur(j.dur || 0);
    const open = openSet.has(j.id);
    const chev = `<span class="cv" data-icon="chevronDown" data-icon-size="14"></span>`;
    const killBtn =
      j.state === "running"
        ? `<button class="jstop" data-kill="idle" data-job-stop="${j.id}"
             aria-label="停止任务 ${esc2(j.label)}">
             ${ic("stopFill", 10)}<span class="lb" hidden>确认停止</span></button>`
        : "";
    const body =
      `<span class="m" data-job-toggle="${j.id}">` +
      `<span class="l1"><span class="label">${esc2(j.label)}</span></span>` +
      `<span class="l2"><span class="kind">${esc2(j.kind)}</span>` +
      `<span class="status">${esc2(j.detail || JOB_LABEL[j.state])}</span></span>` +
      `</span>` +
      `<span class="tm">${dur}</span>` +
      killBtn +
      chev +
      `<span class="out">${esc2(j.out)}</span>`;
    return live
      ? `<div class="jrow${open ? " is-open" : ""}" data-job="${j.id}">${jobDot(
          j.state
        )}${body}</div>`
      : /* 已结束:一行 —— 状态点 + kind + 标签 + 状态(详情优先) + 时长 */
        `<div class="jrow jrow--settled${open ? " is-open" : ""}" data-job="${j.id}">
          ${jobDot(j.state)}<span class="kind">${esc2(j.kind)}</span>
          <span class="m" data-job-toggle="${j.id}"><span class="label">${esc2(
          j.label
        )}</span></span>
          <span class="status">${esc2(j.detail || JOB_LABEL[j.state])}</span>
          <span class="tm">${dur}</span>${chev}
          <span class="out">${esc2(j.out)}</span></div>`;
  }

  /* 活组永远在上;摘要行只显示前两条正在跑的 label(默认收起,不占屏) */
  function jobsSummary() {
    const live = JOBS.filter(isLive);
    if (!live.length) return "";
    const names = live.slice(0, 2).map((j) => j.label).join(" · ");
    return (
      '<span class="jobs-sum">' +
      (live.length === 1 ? jobDot(live[0].state) : "") +
      `<span class="nm">${esc2(names)}</span>` +
      (live.length > 2 ? `<span>+${live.length - 2}</span>` : "") +
      "</span>"
    );
  }

  function jobsHtml() {
    const live = JOBS.filter(isLive);
    const settled = JOBS.filter((j) => !isLive(j));
    if (!JOBS.length) return '<div class="jobs-empty">没有后台任务。</div>';
    const grp = (label, list) =>
      list.length
        ? `<div class="jgroup">${label}</div>` +
          list.map((j) => jobRow(j, jobOpen)).join("")
        : "";
    return (
      grp("进行中", live) +
      grp("已结束 " + settled.length, settled)
    );
  }

  const jobOpen = new Set(["j1"]);
  const jobsList = $("#jobsList");
  const subsList = $("#subsList");

  /* 子代理(DSH 是「N 个子智能体」折叠区,和任务同一套行样式) */
  const SUBS = [
    {
      id: "s1",
      name: "Extract DSH icon paths",
      task: "从 DSH 源码里抽取真实图标 · 可继续",
      state: "completed",
      dur: 537,
      status: "已完成",
      out: "100 个图标 · 验证脚本 37 项全 PASS",
    },
    {
      id: "s2",
      name: "Research rikkahub standalone mode",
      task: "研究开源安卓 AI 聊天 App 的本机运行模式",
      state: "completed",
      dur: 334,
      status: "已完成",
      out: "docs/standalone-mode-notes.md(921 行)",
    },
    {
      id: "s3",
      name: "Research DSH plugins and jobs",
      task: "从移动端视角查插件体系与后台任务",
      state: "running",
      started: Date.now() - 173000,
      out: "正在读 ui-plugin-manager / ui-jobs / extensions…",
    },
  ];

  /* 顶栏连接状态点(§7.8):一档 = 一个点(服务中绿 / 连接中转圈 / 其余红),
     点它弹「连接操作」sheet(重新配对 / 打开侧面板 / 取消)。
     右抽屉的入口是**隔壁那个独立按钮**(data-act="side-open")—— DSH 的右面板入口
     同样是 header 角落的独立席位(ui-sidebar-right 的 ExpandButton),与连接指示器无关。
     形状照 DSH 的 StateDot:10px 槽里画 6px 核(StateDot.module.css:1-15)。
     原型是静态演示,永远画"服务中"这一档;`.is-off` 是"没连上"那一档。 */
  function renderStatusDot() {
    const dot = $("#statusDot");
    if (!dot) return;
    dot.className = "statusdot";
    dot.setAttribute("aria-label", "连接状态:中转已连接 · 空闲,点按查看连接操作");
  }

  /* 计数 chip(§7.8):子智能体 / 后台任务计数,**有才显示**,点它开右抽屉对应面板。
     **在顶栏那一行里、与标题同行** —— DSH 的 header actions band 就是这个形态
     (ConversationSession.tsx:127-129),所以只显"图标 + 计数":全文本放不下
     (单枚 `3 个子智能体` 实测 137.8dp,而顶栏留给「标题 + chip」的只有 285.4dp)。
     计数口径与**全文本**仍逐字照 DSH:`{count} 个子智能体`(报总数,在跑另画转圈点)、
     `{count} 个后台任务运行中`(报**在跑的个数**)/ `{count} 个后台任务`。出处:
     ui-subagent/src/client/locales.ts:36-39 + SubagentHeaderLineage.tsx:679-711;
     ui-jobs/src/client/locales.ts:8-11 + JobListAction.tsx:450-453。
     全文本退进 aria-label 与 title。 */
  function renderLiveChips() {
    const box = $("#liveChips");
    if (!box) return;
    const liveSubs = SUBS.filter((s) => s.state === "running").length;
    const liveJobs = JOBS.filter(isLive).length;
    const spin = `<span class="livechip-dot" data-icon="loading" data-icon-size="14"></span>`;
    const chips = [];
    if (SUBS.length) {
      const aria = liveSubs
        ? `${liveSubs} 个子智能体,正在运行`
        : `${SUBS.length} 个子智能体`;
      chips.push(
        `<button class="livechip" data-act="subs-all" aria-label="${aria}" title="${aria}">` +
          (liveSubs ? spin : `<span data-icon="users" data-icon-size="13"></span>`) +
          `<span>${SUBS.length}</span></button>`
      );
    }
    if (JOBS.length) {
      const label = liveJobs
        ? `${liveJobs} 个后台任务运行中`
        : `${JOBS.length} 个后台任务`;
      chips.push(
        `<button class="livechip" data-act="jobs-all" aria-label="${label}" title="${label}">` +
          (liveJobs
            ? spin
            : `<span data-icon="checklist" data-icon-size="13"></span>`) +
          `<span>${liveJobs || JOBS.length}</span></button>`
      );
    }
    box.innerHTML = chips.join("");
    box.hidden = chips.length === 0;
    paintIcons(box);
  }

  function renderJobs() {
    /* 运行中提醒走**计数 chip 行**(renderLiveChips)与任务面板:只数 running|stopping,
       用整集帧,不订阅输出流,也不在输入栏常驻。顶栏只剩一个连接状态点(它不表任务);
       这里仍重画点,是因为点与 chip 同批刷新。 */
    if (jobsList) jobsList.innerHTML = jobsHtml();
    paintIcons(jobsList);
    bindJobRows();
    renderStatusDot();
    renderLiveChips();
    /* 侧抽屉 tab 上的运行中计数 */
    const tj = $("#tabJobsN");
    if (tj) {
      tj.hidden = running0() === 0;
      tj.textContent = String(running0());
    }
  }
  const running0 = () => JOBS.filter(isLive).length;

  function subRow(s, openSet) {
    const live = s.state === "running" || s.state === "stopping";
    const dur = live
      ? fmtClock(Math.round((Date.now() - s.started) / 1000))
      : fmtDur(s.dur || 0);
    const open = openSet.has(s.id);
    const chev = `<span class="cv" data-icon="chevronDown" data-icon-size="14"></span>`;
    return live
      ? `<div class="jrow${open ? " is-open" : ""}" data-job="${s.id}">
          ${jobDot(s.state)}
          <span class="m" data-sub-toggle="${s.id}">
            <span class="l1"><span class="label">${esc2(s.name)}</span></span>
            <span class="l2"><span class="kind">agent</span><span class="status">${esc2(
              s.task
            )}</span></span>
          </span>
          <span class="tm">${dur}</span>${chev}
          <span class="out">${esc2(s.out)}</span></div>`
      : `<div class="jrow jrow--settled${open ? " is-open" : ""}" data-job="${s.id}">
          ${jobDot(s.state)}<span class="kind">agent</span>
          <span class="m" data-sub-toggle="${s.id}"><span class="label">${esc2(
          s.name
        )}</span></span>
          <span class="status">${esc2(s.task)}</span>
          <span class="tm">${dur}</span>${chev}
          <span class="out">${esc2(s.out)}</span></div>`;
  }

  function renderSubs() {
    if (!subsList) return;
    const running = SUBS.filter((s) => s.state === "running").length;
    subsList.innerHTML =
      `<div class="jgroup">${
        running ? "进行中 " + running + " · " : ""
      }已结束 ${SUBS.length - running}</div>` +
      SUBS.map((s) => subRow(s, jobOpen)).join("");
    paintIcons(subsList);
    $$("[data-sub-toggle]", subsList).forEach((el) =>
      el.addEventListener("click", () => {
        const id = el.dataset.subToggle;
        if (jobOpen.has(id)) jobOpen.delete(id);
        else jobOpen.add(id);
        haptic();
        renderSubs();
      })
    );
    const ts = $("#tabSubsN");
    if (ts) {
      ts.hidden = running === 0;
      ts.textContent = String(running);
    }
    renderLiveChips();
  }

  function bindJobRows() {
    if (!jobsList) return;
    $$("[data-job-toggle]", jobsList).forEach((el) =>
      el.addEventListener("click", () => {
        const id = el.dataset.jobToggle;
        if (jobOpen.has(id)) jobOpen.delete(id);
        else jobOpen.add(id);
        haptic();
        renderJobs();
      })
    );
    /* 停止:第一次点武装(按钮变宽成"确认停止"),再点才真停 —— 照 JobListAction */
    $$("[data-job-stop]", jobsList).forEach((b) =>
      b.addEventListener("click", (e) => {
        e.stopPropagation();
        const id = b.dataset.jobStop;
        if (b.dataset.kill === "armed") {
          b.dataset.kill = "pending";
          b.disabled = true;
          stopJob(id);
          return;
        }
        b.dataset.kill = "armed";
        const lb = b.querySelector(".lb");
        if (lb) lb.hidden = false;
        haptic();
        clearTimeout(b._disarm);
        b._disarm = setTimeout(() => {
          if (b.dataset.kill !== "armed") return;
          b.dataset.kill = "idle";
          if (lb) lb.hidden = true;
        }, 3000);
      })
    );
  }

  function stopJob(id) {
    const j = JOBS.find((x) => x.id === id);
    if (!j) return;
    /* 已经 stopping 的直接跳过:重复下发停止请求没有意义 */
    if (j.state === "stopping") return;
    if (j.state !== "running") return;
    /* 先转「正在停止」,等权威帧再落终态 —— 不乐观更新(JobListAction.tsx:441-458) */
    j.state = "stopping";
    j.detail = "正在停止…";
    haptic(18);
    renderJobs();
    setTimeout(() => {
      j.state = "killed";
      j.dur = Math.round((Date.now() - j.started) / 1000);
      j.detail = "cancelled by the user";
      j.out += "\n^C cancelled by the user";
      toast("已停止 · " + j.label);
      renderJobs();
    }, 900);
  }

  /* 权威帧模拟:stopping 的任务在若干秒后收到电脑端的终态帧(真实 DSH 里由 host 推送) */
  function resolveStopping(ms) {
    JOBS.filter((j) => j.state === "stopping").forEach((j) => {
      setTimeout(() => {
        if (j.state !== "stopping") return;
        j.state = "killed";
        j.dur = Math.round((Date.now() - j.started) / 1000);
        j.detail = "cancelled by the user";
        j.out += "\n^C cancelled by the user";
        renderJobs();
      }, ms);
    });
  }

  let jobTick = null;
  function startJobTick() {
    if (jobTick) return;
    jobTick = setInterval(() => {
      const anyRunning =
        JOBS.some((j) => j.state === "running") ||
        SUBS.some((s) => s.state === "running");
      if (!anyRunning) return;
      /* 只更新时长文本,不整段重绘(否则展开的输出会跳回顶部) */
      $$("[data-job]").forEach((row) => {
        const it =
          JOBS.find((x) => x.id === row.dataset.job) ||
          SUBS.find((x) => x.id === row.dataset.job);
        if (!it || it.state !== "running") return;
        const tm = row.querySelector(".tm");
        if (tm)
          tm.textContent = fmtClock(Math.round((Date.now() - it.started) / 1000));
      });
    }, 1000);
  }

  /* 侧抽屉里的"文件"面板还是 diff;抽屉入口只切面板 */
  function revealSection(name) {
    openSide(name);
    return true;
  }

  /* ============================================================ 骨架大图 + lightbox */
  const IMGS = [
    "data:image/svg+xml;utf8," +
      encodeURIComponent(
        `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="800"><defs><linearGradient id="a" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5686FE"/><stop offset="1" stop-color="#9E7BAA"/></linearGradient></defs><rect width="1200" height="800" fill="url(#a)"/><circle cx="300" cy="240" r="120" fill="#ffffff" opacity=".22"/><circle cx="900" cy="560" r="180" fill="#0F1115" opacity=".25"/><text x="60" y="740" font-family="monospace" font-size="44" fill="#fff" opacity=".9">DSH mobile · 桌面截图 1</text></svg>`
      ),
    "data:image/svg+xml;utf8," +
      encodeURIComponent(
        `<svg xmlns="http://www.w3.org/2000/svg" width="800" height="1200"><rect width="800" height="1200" fill="#1F3124"/><rect x="60" y="80" width="680" height="180" rx="28" fill="#41C977" opacity=".35"/><rect x="60" y="320" width="680" height="180" rx="28" fill="#22C55E" opacity=".22"/><text x="60" y="1120" font-family="monospace" font-size="40" fill="#41C977">diff-added · 竖图</text></svg>`
      ),
  ];
  const lb = $("#lightbox");
  const lbImg = $("#lbImg");
  const lbIdx = $("#lbIdx");
  let lbState = { i: 0, s: 1, x: 0, y: 0 };
  const lbApply = () =>
    (lbImg.style.transform = `translate3d(${lbState.x}px,${lbState.y}px,0) scale(${lbState.s})`);

  function openLightbox(i) {
    lbState = { i, s: 1, x: 0, y: 0 };
    lbImg.src = IMGS[i];
    lbIdx.textContent = i + 1 + " / " + IMGS.length;
    lbApply();
    lb.classList.add("is-on");
    openLayer("lightbox", () => closeLightbox(true));
    haptic();
  }
  function closeLightbox(viaHistory) {
    lb.classList.remove("is-on");
    if (!viaHistory) closeLayer("lightbox");
  }
  const pointers = new Map();
  let pinch0 = 0,
    lbStart = null;

  lb.addEventListener("pointerdown", (e) => {
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 1) {
      lbStart = { x: e.clientX, y: e.clientY, s: lbState.s, ox: lbState.x, oy: lbState.y };
      lbImg.style.transition = "none";
    } else if (pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      pinch0 = Math.hypot(a.x - b.x, a.y - b.y);
      lbStart = { s: lbState.s, pinchBase: pinch0 };
    }
  });
  lb.addEventListener("pointermove", (e) => {
    if (!pointers.has(e.pointerId)) return;
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 2 && lbStart && lbStart.pinchBase) {
      const [a, b] = [...pointers.values()];
      const d = Math.hypot(a.x - b.x, a.y - b.y);
      lbState.s = clamp(lbStart.s * (d / lbStart.pinchBase), 1, 5);
      lbApply();
      return;
    }
    if (pointers.size === 1 && lbStart && lbStart.s !== undefined) {
      const dx = e.clientX - lbStart.x;
      const dy = e.clientY - lbStart.y;
      if (lbState.s > 1) {
        lbState.x = lbStart.ox + dx;
        lbState.y = lbStart.oy + dy;
      } else {
        lbState.x = dx;
        lbState.y = Math.max(0, dy);
      }
      lbApply();
    }
  });
  const lbUp = (e) => {
    if (!pointers.has(e.pointerId)) return;
    const had = pointers.size;
    pointers.delete(e.pointerId);
    if (had === 2) {
      if (lbState.s <= 1.02) {
        lbState.s = 1;
        lbState.x = lbState.y = 0;
        lbImg.style.transition = "transform var(--d2) var(--ease)";
        lbApply();
      }
      lbStart = null;
      return;
    }
    if (pointers.size === 0 && lbStart && lbStart.s !== undefined) {
      const dy = e.clientY - lbStart.y;
      const dx = e.clientX - lbStart.x;
      lbImg.style.transition = "transform var(--d2) var(--ease)";
      if (lbState.s <= 1.02) {
        if (dy > 110) {
          closeLightbox();
          lbStart = null;
          return;
        }
        if (Math.abs(dx) > 60) {
          const i =
            (lbState.i + (dx < 0 ? 1 : IMGS.length - 1)) % IMGS.length;
          lbState = { i, s: 1, x: 0, y: 0 };
          lbImg.src = IMGS[i];
          lbIdx.textContent = i + 1 + " / " + IMGS.length;
        }
        lbState.x = lbState.y = 0;
        lbApply();
      }
      lbStart = null;
    }
  };
  lb.addEventListener("pointerup", lbUp);
  lb.addEventListener("pointercancel", lbUp);
  lb.addEventListener(
    "dblclick",
    () => {
      lbState.s = lbState.s > 1.5 ? 1 : 2.5;
      lbState.x = lbState.y = 0;
      lbImg.style.transition = "transform var(--d2) var(--ease)";
      lbApply();
    }
  );

  /* ============================================================
     文件预览页:diff / 内容 / 各异常状态
     ============================================================ */
  const MAX_LINES = 400;

  const H = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  const FILES = {
    "app/lib/ui/chat_page.dart": {
      add: 128,
      del: 46,
      lang: "dart",
      status: "modified",
      hunks: [
        {
          head: "@@ -112,9 +112,14 @@ class _ChatPageState extends State<ChatPage> {",
          lines: [
            [" ", 112, 112, "  @override"],
            [" ", 113, 113, "  Widget build(BuildContext context) {"],
            ["-", 114, null, "    return Scaffold("],
            ["-", 115, null, "      body: SessionListView(active: _active),"],
            ["-", 116, null, "      bottomNavigationBar: const DshNavBar(),"],
            ["-", 117, null, "    );"],
            ["+", null, 114, "    return ModalNavigationDrawer("],
            ["+", null, 115, "      drawer: const SessionDrawer(),"],
            ["+", null, 116, "      child: Scaffold("],
            ["+", null, 117, "        appBar: DshAppBar("],
            ["+", null, 118, "          leading: const DrawerButton(),"],
            ["+", null, 119, "          title: Text(_session.title),"],
            ["+", null, 120, "        ),"],
            ["+", null, 121, "        body: ChatView(turns: _turns),"],
            ["+", null, 122, "      ),"],
            ["+", null, 123, "    );"],
            [" ", 118, 124, "  }"],
          ],
        },
        {
          head: "@@ -240,7 +245,11 @@ class _ChatPageState extends State<ChatPage> {",
          lines: [
            [" ", 240, 245, "  void _onTurnUpdate(Turn turn) {"],
            [" ", 241, 246, "    setState(() {"],
            ["-", 242, null, "      _turns.add(turn);"],
            ["+", null, 247, "      if (turn.isStreaming) {"],
            ["+", null, 248, "        _turns.replaceTail(turn);"],
            ["+", null, 249, "      } else {"],
            ["+", null, 250, "        _turns.add(turn);"],
            ["+", null, 251, "      }"],
            [" ", 243, 252, "    });"],
            [" ", 244, 253, "  }"],
          ],
        },
      ],
      content: [
        "import 'package:flutter/material.dart';",
        "",
        "import '../theme/dsh_theme.dart';",
        "import 'session_drawer.dart';",
        "",
        "/// 会话详情页。手机端用「聊天即主页 + 抽屉」结构(见方案 §6)。",
        "class ChatPage extends StatefulWidget {",
        "  const ChatPage({super.key, required this.sessionId});",
        "",
        "  final String sessionId;",
        "",
        "  @override",
        "  State<ChatPage> createState() => _ChatPageState();",
        "}",
        "",
        "class _ChatPageState extends State<ChatPage> {",
        "  final _turns = <Turn>[];",
        "",
        "  @override",
        "  Widget build(BuildContext context) {",
        "    return ModalNavigationDrawer(",
        "      drawer: const SessionDrawer(),",
        "      child: Scaffold(",
        "        appBar: DshAppBar(",
        "          leading: const DrawerButton(),",
        "          title: Text(_session.title),",
        "        ),",
        "        body: ChatView(turns: _turns),",
        "      ),",
        "    );",
        "  }",
        "}",
      ],
    },

    "docs/design-and-tech-plan.md": {
      add: 12,
      del: 3,
      lang: "markdown",
      status: "modified",
      hunks: [
        {
          head: "@@ -324,9 +324,18 @@ ### 7.6 富内容渲染",
          lines: [
            [" ", 324, 324, "### 7.6 富内容渲染(消息 / 工具结果里的 diff、预览等)"],
            ["-", 325, null, "- 文件 diff:手机默认统一视图。"],
            ["+", null, 325, "- 文件 diff:手机默认 unified(单栏)。"],
            ["+", null, 326, "- 点变更文件 chip**进入全屏 diff 页**(不再内联塞在气泡里):"],
            ["+", null, 327, "  - 顶部:文件名 + `+N/−M` + ⋮ 菜单"],
            ["+", null, 328, "  - 分段:差异 ⇄ 文件内容"],
            ["+", null, 329, "  - 行号槽 sticky,长行横滑,超 MAX_RENDERED_LINES 截断"],
            ["+", null, 330, "  - 状态:loading / binary / oversized / missing / created / deleted / unchanged"],
            ["+", null, 331, "  - 左缘右滑返回(跟手)"],
            [" ", 326, 332, ""],
          ],
        },
      ],
      content: [
        "# DSH Mobile 移动端设计与技术方案",
        "",
        "### 7.6 富内容渲染",
        "",
        "- 文件 diff:手机默认 unified(单栏)。",
        "- 点变更文件 chip 进入全屏 diff 页。",
        "- 图片:点开全屏 lightbox,双指缩放。",
      ],
    },

    "assets/icon.png": {
      add: 0,
      del: 0,
      lang: "png",
      status: "binary",
      hunks: [],
      content: [],
    },

    "app/lib/ui/timeline_page.dart": {
      add: 214,
      del: 0,
      lang: "dart",
      status: "created",
      hunks: [
        {
          head: "@@ -0,0 +1,12 @@ 新文件",
          lines: [
            ["+", null, 1, "import 'package:flutter/material.dart';"],
            ["+", null, 2, ""],
            ["+", null, 3, "/// 轨迹页:迷你横滑甘特 + 竖向 ledger(方案 §7.3)。"],
            ["+", null, 4, "class TimelinePage extends StatelessWidget {"],
            ["+", null, 5, "  const TimelinePage({super.key});"],
            ["+", null, 6, ""],
            ["+", null, 7, "  @override"],
            ["+", null, 8, "  Widget build(BuildContext context) => const _Gantt();"],
            ["+", null, 9, "}"],
          ],
        },
      ],
      content: ["import 'package:flutter/material.dart';", "", "// 新文件"],
    },

    "app/lib/legacy/mock_page.dart": {
      add: 0,
      del: 96,
      lang: "dart",
      status: "deleted",
      hunks: [
        {
          head: "@@ -1,10 +0,0 @@ 已删除",
          lines: [
            ["-", 1, null, "import 'package:flutter/material.dart';"],
            ["-", 2, null, ""],
            ["-", 3, "/// 旧的静态 mock 页,已被真交互原型取代。"],
            ["-", 4, null, "class MockPage extends StatelessWidget {"],
            ["-", 5, null, "  const MockPage({super.key});"],
            ["-", 6, null, "}"],
          ],
        },
      ],
      content: [],
    },

    "app/lib/core/bridge_client.dart": {
      add: 0,
      del: 0,
      lang: "dart",
      status: "unchanged",
      hunks: [],
      content: ["// 本轮无改动"],
    },
  };

  /* 超大 diff:演示截断 */
  function hugeHunk() {
    const lines = [];
    for (let i = 0; i < 600; i++) {
      const add = i % 5 === 0;
      const del = i % 7 === 0;
      lines.push([
        del ? "-" : add ? "+" : " ",
        del ? 100 + i : add ? null : 100 + i,
        del ? null : 100 + i,
        `  ${del ? "// 旧实现 " : ""}widget = _buildRow(${i});`,
      ]);
    }
    return [{ head: "@@ -100,600 +100,600 @@ generated", lines }];
  }

  const BIN_STATES = {
    loading: {
      icon: "loading",
      h: "正在读取…",
      d: "从电脑端经中转拉取文件内容。",
      skeleton: true,
    },
    binary: {
      icon: "deliverDoc",
      h: "二进制文件",
      d: "PNG 不能按文本 diff 展示。已切到图片预览,可双指缩放、保存到相册。",
    },
    oversized: {
      icon: "warningTriangle",
      h: "文件过大",
      d: "超过 2 MiB 不在手机端渲染(避免爆内存)。已提供「在电脑打开」。",
    },
    missing: {
      icon: "closeCircleFill",
      h: "文件不存在",
      d: "工作区里找不到该路径,可能已删除或未同步到这台设备。",
    },
    unchanged: {
      icon: "checkCircle",
      h: "无改动",
      d: "这一轮里该文件没有变更。",
    },
  };

  const sidePage = $("#pageSide");
  const filePage = sidePage; // 兼容旧引用
  const fileView = $("#fileView");
  const fileSeg = $("#fileSeg");
  let curFile = null;
  let curState = "ok";
  let fileTab = 0; // 0=差异 1=文件内容
  let splitView = false; // 并排(仅够宽时允许,照方案 §7.6)
  let wrapView = false; // 长行折行
  let sidePanel = "file"; // file | jobs | subs

  function renderDiff(f) {
    const hunks = curState === "truncated" ? hugeHunk() : f.hunks || [];
    if (!hunks.length) {
      fileView.innerHTML = statePanel({
        icon: f.status === "unchanged" ? "checkCircle" : "info",
        h: f.status === "unchanged" ? "无改动" : "没有可显示的差异",
        d: "该文件在这一轮里没有产生 diff。",
      });
      return;
    }
    fileView.classList.toggle("is-wrap", wrapView);
    fileView.innerHTML = splitView ? splitDiffHtml(hunks) : unifiedDiffHtml(hunks);
    fileView.scrollTop = 0;
  }

  function diffTotal(hunks) {
    return hunks.reduce((a, h) => a + h.lines.length, 0);
  }

  function unifiedDiffHtml(hunks) {
    let shown = 0;
    let html = '<div class="diff">';
    outer: for (const hk of hunks) {
      html += `<div class="dl hunk"><span class="gut"><span></span><span></span></span><span class="mk"></span><span class="tx">${H(
        hk.head
      )}</span></div>`;
      for (const [mk, o, n, tx] of hk.lines) {
        if (shown >= MAX_LINES) break outer;
        const cls = mk === "+" ? " add" : mk === "-" ? " del" : "";
        html += `<div class="dl${cls}"><span class="gut"><span>${
          o == null ? "" : o
        }</span><span>${n == null ? "" : n}</span></span><span class="mk">${H(
          mk
        )}</span><span class="tx">${H(tx)}</span></div>`;
        shown++;
      }
    }
    html += "</div>";
    const total = diffTotal(hunks);
    if (total > MAX_LINES) {
      html += `<div class="trunc">已截断 · 仅渲染前 ${MAX_LINES} 行(共 ${total} 行)
        <button data-act="load-more">载入更多</button></div>`;
    }
    return html;
  }

  /* 并排:粗粒度两栏(左=上下文+删除,右=上下文+新增)。
     手机竖屏宽度不够,入口会先拦下来(方案 §7.6:手机默认 unified)。 */
  function splitDiffHtml(hunks) {
    const cell = (rows) =>
      rows
        .map(([mk, o, n, tx]) => {
          const cls = mk === "+" ? " add" : mk === "-" ? " del" : "";
          return `<div class="dl${cls}"><span class="gut"><span>${
            o == null ? "" : o
          }</span><span>${n == null ? "" : n}</span></span><span class="mk">${H(
            mk
          )}</span><span class="tx">${H(tx)}</span></div>`;
        })
        .join("");
    let shown = 0;
    let html = '<div class="diff"><div class="dsplit">';
    outer: for (const hk of hunks) {
      const L = [];
      const R = [];
      for (const [mk, o, n, tx] of hk.lines) {
        if (shown >= MAX_LINES) break outer;
        shown++;
        if (mk === "-") L.push([mk, o, null, tx]);
        else if (mk === "+") R.push([mk, null, n, tx]);
        else {
          L.push([mk, o, null, tx]);
          R.push([mk, null, n, tx]);
        }
      }
      html += `<div class="side-h" style="grid-column:1/-1">${H(hk.head)}</div>`;
      html += `<div>${cell(L)}</div><div>${cell(R)}</div>`;
    }
    html += "</div></div>";
    const total = diffTotal(hunks);
    if (total > MAX_LINES) {
      html += `<div class="trunc">已截断 · 仅渲染前 ${MAX_LINES} 行(共 ${total} 行)</div>`;
    }
    return html;
  }

  function renderContent(f) {
    if (!f.content || !f.content.length) {
      fileView.innerHTML = statePanel({
        icon: "—",
        h: "没有内容",
        d: "该文件当前没有可显示的文本内容。",
      });
      return;
    }
    fileView.innerHTML =
      '<div class="diff">' +
      f.content
        .map(
          (l, i) =>
            `<div class="codeline"><span class="gut">${i + 1}</span><span class="tx">${H(
              l
            )}</span></div>`
        )
        .join("") +
      "</div>";
    fileView.scrollTop = 0;
  }

  function statePanel(s) {
    const iconHtml =
      s.icon && window.DshIcons && window.DshIcons.names.indexOf(s.icon) >= 0
        ? window.DshIcons.svg(s.icon, { size: 24 })
        : s.icon || "";
    if (s.skeleton)
      return `<div class="skel">${'<i></i>'.repeat(7)}</div><div class="state" style="padding-top:8px"><div class="h">${s.h}</div><div class="d">${s.d}</div></div>`;
    return `<div class="state"><div class="ic2">${iconHtml}</div><div class="h">${s.h}</div><div class="d">${s.d}</div></div>`;
  }

  function renderFile() {
    const f = FILES[curFile];
    if (!f) return;
    $("#sideTitle").textContent = curFile.split("/").pop();
    $("#sideSub").textContent = curFile;
    $("#fileAdd").textContent = f.add ? "+" + f.add : "";
    $("#fileDel").textContent = f.del ? "−" + f.del : "";
    $("#fileLang").textContent = f.lang;
    const st = { ok: "已修改", created: "新建", deleted: "已删除" }[f.status] || "已修改";
    $("#fileStatus").textContent = curState === "ok" ? st : curState;
    $("#fileSize").textContent =
      f.status === "binary" ? "48.2 KB" : (f.content.length * 42 + 512) / 1024 > 1
        ? ((f.content.length * 42 + 512) / 1024).toFixed(1) + " KB"
        : (f.content.length * 42 + 512) + " B";

    const bad = BIN_STATES[curState];
    if (bad || f.status === "binary") {
      const s = bad || BIN_STATES.binary;
      fileView.innerHTML = statePanel(s);
      fileSeg.style.visibility = "hidden";
      $("#fileActions").style.display = "none";
      return;
    }
    fileSeg.style.visibility = "visible";
    $("#fileActions").style.display = "flex";
    const fbtns = fileSeg.querySelectorAll(".seg-btn");
    fbtns[0].textContent =
      f.status === "created" ? "新增" : f.status === "deleted" ? "删除" : "差异";
    fbtns.forEach((b, i) => b.classList.toggle("is-on", i === fileTab));
    const find = fileSeg.querySelector(".seg-ind");
    if (find) find.style.transform = `translate3d(${fileTab * 100}%,0,0)`;
    if (fileTab === 0) renderDiff(f);
    else renderContent(f);
  }

  function layoutSidePane() {
    /* 什么时候给右抽屉:横屏,或宽度 ≥700(平板/折叠屏展开)。
       竖屏手机全屏 —— 390 宽里再切一块,会话和 diff 两边都不够用。 */
    const w = window.innerWidth;
    const h = window.innerHeight;
    const full = !(w >= 700 || w > h);
    appRoot.classList.toggle("side-full", full);
    return { full };
  }

  /* 一个抽屉三个面板:文件 / 任务 / 子代理 */
  function setPanel(name) {
    sidePanel = name;
    $$(".stab", $("#sideTabs")).forEach((b) =>
      b.classList.toggle("is-on", b.dataset.panel === name)
    );
    $$(".side-panel").forEach((p) =>
      p.classList.toggle("is-on", p.id === "panel" + name[0].toUpperCase() + name.slice(1))
    );
    if (name === "file") {
      $("#sideTitle").textContent = curFile ? curFile.split("/").pop() : "文件预览";
      $("#sideSub").textContent = curFile || "";
    } else if (name === "jobs") {
      const live = JOBS.filter(isLive).length;
      $("#sideTitle").textContent = "后台任务";
      $("#sideSub").textContent = live
        ? live + " 个运行中 · 在电脑端执行"
        : JOBS.length + " 个,均不" + "在运行";
      $("#fileAdd").textContent = "";
      $("#fileDel").textContent = "";
      renderJobs();
    } else {
      const live = SUBS.filter((s) => s.state === "running").length;
      $("#sideTitle").textContent = "子智能体";
      $("#sideSub").textContent = live ? live + " 个运行中" : "均已结束";
      $("#fileAdd").textContent = "";
      $("#fileDel").textContent = "";
      renderSubs();
    }
  }

  const sideScrim = $("#sideScrim");
  function openSide(panel, via) {
    layoutSidePane();
    setPanel(panel || "file");
    sidePage.classList.add("is-in");
    sidePage.style.transform = "";
    if (sideScrim) sideScrim.classList.add("is-on");
    appRoot.classList.add("file-open");
    if (via !== "keep") openLayer("side", () => closeSide(true));
    haptic();
  }

  function closeSide(viaHistory) {
    sidePage.classList.remove("is-in");
    sidePage.style.transform = "";
    if (sideScrim) sideScrim.classList.remove("is-on");
    appRoot.classList.remove("file-open");
    if (!viaHistory) closeLayer("side");
  }
  if (sideScrim) sideScrim.addEventListener("click", () => closeSide());

  function openFile(path, state) {
    curFile = FILES[path] ? path : Object.keys(FILES)[0];
    curState = state || (FILES[curFile].status === "binary" ? "binary" : "ok");
    fileTab = 0;
    fileSeg.querySelectorAll(".seg-btn").forEach((b, i) =>
      b.classList.toggle("is-on", i === 0)
    );
    const ind = fileSeg.querySelector(".seg-ind");
    if (ind) ind.style.transform = "translate3d(0,0,0)";
    renderFile();
    openSide("file");
  }

  function closeFile(viaHistory) {
    closeSide(viaHistory);
  }

  /* 侧抽屉 tab 切换 */
  $$(".stab", $("#sideTabs")).forEach((b) =>
    b.addEventListener("click", () => {
      if (b.dataset.panel === sidePanel) return;
      haptic();
      setPanel(b.dataset.panel);
    })
  );

  /* 文件页 差异 ⇄ 文件内容 分段(不做左右滑:diff 自身要横滑看长行) */
  $$(".seg-btn", fileSeg).forEach((b, i) =>
    b.addEventListener("click", () => {
      fileTab = i;
      haptic();
      renderFile();
    })
  );

  /* 右抽屉:从**右缘**往右划收起(竖屏降级成全屏时,手势方向改成从左缘返回) */
  const edgeBack = $("#edgeBack");
  if (edgeBack) {
    onDrag(edgeBack, {
      axis: "x",
      threshold: 3,
      start: () => filePage.classList.contains("is-in"),
      begin: () => {
        filePage.style.transition = "none";
      },
      move: (e, g) => {
        /* 全屏(竖屏降级)时从左缘往右划;右抽屉时从右缘往右划 */
        const full = appRoot.classList.contains("side-full");
        const d = full ? Math.max(0, g.dx) : Math.max(0, -g.dx);
        filePage.style.transform = `translate3d(${d}px,0,0)`;
      },
      end: (e, g) => {
        filePage.style.transition = "";
        const full = appRoot.classList.contains("side-full");
        const d = full ? g.dx : -g.dx;
        const v = full ? g.vx : -g.vx;
        if (d > filePage.clientWidth * 0.32 || v > 0.4) closeFile();
        else filePage.style.transform = "";
      },
    });
  }

  /* ============================================================ GoalBar + TodoPanel
     对齐 DSH `ui-goal/GoalBar.tsx` 与 `ui-conversation/skeleton/TodoPanel.tsx`:
     目标是可暂停/恢复、编辑、清除的 dock;任务清单只读且默认收起。
     注意:这里是原型演示状态,真实动作要等 bridge 暴露 goals/todos。 */
  const goalDock = $("#goalDock");
  const todoDock = $("#todoDock");
  const DEMO_GOAL = {
    id: "goal-settings-42",
    revision: 1,
    objective: "基于已核实的42项设置调研，在 mock/proto 中实现可交互的移动端设置页原型",
    phase: "active",
    editing: false,
    deleted: false,
  };
  const DEMO_TODOS = [
    { status: "completed", content: "核对 DSH Web / 客户端设置导航" },
    { status: "in_progress", content: "实现移动端设置页与二级页面" },
    { status: "pending", content: "补 bridge 能力边界与回归截图" },
  ];
  let todoExpanded = false;

  function goalStateLabel() {
    if (DEMO_GOAL.phase === "paused") return "已暂停的目标";
    if (DEMO_GOAL.phase === "blocked") return "受阻的目标";
    return "进行中的目标";
  }
  function renderGoalDock() {
    if (!goalDock) return;
    if (DEMO_GOAL.deleted) {
      goalDock.innerHTML = `<button class="goal-dock" data-act="goal-reopen"><span class="goal-glyph">${ic("goal", 15)}</span><span class="goal-copy"><span class="goal-state">没有目标</span><span class="goal-objective">点按重新显示演示目标</span></span>${ic("chevronRight", 14)}</button>`;
      paintIcons(goalDock);
      return;
    }
    if (DEMO_GOAL.editing) {
      goalDock.innerHTML = `<div class="goal-dock"><span class="goal-glyph">${ic("goal", 15)}</span><input class="goal-edit" id="goalEditInput" aria-label="目标内容" value="${DEMO_GOAL.objective.replace(/"/g, "&quot;")}"><div class="goal-actions"><button class="goal-action" data-act="goal-edit-cancel" aria-label="取消编辑">${ic("close", 14)}</button><button class="goal-action" data-act="goal-edit-save" aria-label="保存目标">${ic("check", 14)}</button></div></div>`;
      paintIcons(goalDock);
      const input = $("#goalEditInput");
      if (input) { input.focus(); input.setSelectionRange(input.value.length, input.value.length); }
      return;
    }
    const action = DEMO_GOAL.phase === "active"
      ? `<button class="goal-action" data-act="goal-pause" aria-label="暂停目标">${ic("pause", 14)}</button>`
      : `<button class="goal-action" data-act="goal-resume" aria-label="恢复目标">${ic("play", 14)}</button>`;
    goalDock.innerHTML = `<div class="goal-dock"><span class="goal-glyph">${ic("goal", 15)}</span><span class="goal-copy"><span class="goal-state">${goalStateLabel()}</span><span class="goal-objective">${DEMO_GOAL.objective}</span></span><div class="goal-actions">${action}<button class="goal-action" data-act="goal-edit" aria-label="编辑目标">${ic("edit", 14)}</button><button class="goal-action danger" data-act="goal-clear" aria-label="清除目标">${ic("trash", 14)}</button></div></div>`;
    paintIcons(goalDock);
  }
  function renderTodoDock() {
    if (!todoDock) return;
    const done = DEMO_TODOS.filter(x => x.status === "completed").length;
    const active = DEMO_TODOS.filter(x => x.status === "in_progress").length;
    const pending = DEMO_TODOS.filter(x => x.status === "pending").length;
    todoDock.innerHTML = `<div class="todo-dock"><button class="todo-head" data-act="todo-toggle" aria-expanded="${todoExpanded}"><span class="todo-dot">${ic("checklist", 14)}</span><span class="todo-title">任务清单</span><span class="todo-progress">${done} 完成 · ${active} 进行中 · ${pending} 待办</span>${ic(todoExpanded ? "chevronUp" : "chevronDown", 14)}</button>${todoExpanded ? `<div class="todo-list">${DEMO_TODOS.map(item => `<div class="todo-item" data-status="${item.status}"><span class="todo-dot">${ic(item.status === "completed" ? "checkCircle" : item.status === "in_progress" ? "loading" : "clock", 14)}</span><span>${item.content}</span></div>`).join("")}</div>` : ""}</div>`;
    paintIcons(todoDock);
  }
  renderGoalDock();
  renderTodoDock();

  /* ============================================================ 设置页
     Note: 设置首页与二级页为什么分层,以及为何不伪造插件页面,见
     .agents/notes/implemented/2026-09-30-mobile-settings-information-architecture.md
     第一版页面映射来自 docs/settings-porting-notes.md:
     通用(本地偏好) / 模型(连接电脑时需 bridge) / 权限与会话 /
     内置插件(只读清单) / Agent 预设 / 关于连接。
     插件自定义页不在这里伪造,只明确显示"需在电脑端编辑"。 */
  const settingsPage = $("#pageSettings");
  const settingsHome = $("#settingsHome");
  const settingsDetail = $("#settingsDetail");
  const settingsTitle = $("#settingsTitle");
  let settingsSection = null;

  const settingsIcon = (name) => `<span class="row-icon">${ic(name, 18)}</span>`;
  const settingsArrow = () => `<span class="row-arrow">${ic("chevronRight", 16)}</span>`;
  function settingsRow(section, icon, title, sub, value = "") {
    return `<button class="settings-row" data-act="settings-detail" data-section="${section}">
      ${settingsIcon(icon)}<span class="row-copy"><span class="row-title">${title}</span><span class="row-sub">${sub}</span></span>
      ${value ? `<span class="row-value">${value}</span>` : ""}${settingsArrow()}
    </button>`;
  }
  function settingsCard(rows) { return `<div class="settings-card">${rows.join("")}</div>`; }

  function renderSettingsHome() {
    if (!settingsHome) return;
    settingsHome.innerHTML = `
      <div class="settings-hero">
        <h2>设置</h2>
        <p>按 DSH Web 的设置分组排列;手机本地偏好与电脑端配置明确分开。</p>
      </div>
      <section class="settings-section">
        <div class="settings-section-title">账号与余额</div>
        ${settingsCard([
          settingsRow("account", "user", "账号与余额", "电脑端登录状态与余额只读展示", "仅电脑端"),
        ])}
      </section>
      <div class="settings-connection">
        <span class="conn-dot"></span>
        <span class="copy"><strong>我的电脑 · 已连接</strong><span>Windows · 中转在线 · 设置写入需 bridge 能力</span></span>
        ${ic("chevronRight", 16)}
      </div>
      <section class="settings-section">
        <div class="settings-section-title">通用设置</div>
        ${settingsCard([
          settingsRow("general", "personalization", "通用设置", "权限、外观、语言、字号、工作步骤与发送行为", "按 DSH 排列"),
        ])}
      </section>
      <section class="settings-section">
        <div class="settings-section-title">模型</div>
        ${settingsCard([
          settingsRow("models", "sparkle", "模型与服务商", "当前模型、推理等级、提供商与密钥", "需 bridge"),
        ])}
      </section>
      <section class="settings-section">
        <div class="settings-section-title">内置插件</div>
        ${settingsCard([
          settingsRow("plugins", "pluginPinwheel", "内置插件", "清单、搜索、加载状态;自定义页面不在手机渲染", "只读"),
        ])}
      </section>
      <section class="settings-section">
        <div class="settings-section-title">Agent 预设</div>
        ${settingsCard([
          settingsRow("agent-presets", "agentPreset", "Agent 预设", "列表与默认预设;配置在电脑端查看", "只读部分"),
        ])}
      </section>
      <section class="settings-section">
        <div class="settings-section-title">关于与连接</div>
        ${settingsCard([
          settingsRow("about", "info", "关于与连接", "版本、设备、配对与在电脑端打开配置", "DSH Mobile"),
        ])}
      </section>
      <p class="settings-note">DSH 的子智能体、Agent 循环、终端与网页搜索属于侧边栏 Plugins 面板,不混入 settings.section。完整 42 项处置见 docs/settings-porting-notes.md。</p>`;
    paintIcons(settingsHome);
  }

  function settingsControl(title, sub, right) {
    return `<div class="settings-control"><span class="control-copy"><span class="control-title">${title}</span>${sub ? `<span class="control-sub">${sub}</span>` : ""}</span>${right}</div>`;
  }
  function toggleControl(title, sub, on, key) {
    return settingsControl(title, sub, `<button class="settings-toggle ${on ? "is-on" : ""}" data-act="settings-toggle" data-setting="${key}" aria-pressed="${on}"></button>`);
  }

  /* 通用设置里的「新会话默认权限」是**另一个**设置项:DSH 把它注册成 `settings.general.item`
     (id=permission, order -20, `ui-permission-presets/src/client/index.ts:159-165`),
     值来自 `permission.defaultPreset`;当前会话权限是输入栏的 `/permission` 浮层(`:167-174`)。
     原型的旧版本把两者混用一个 store —— 这里按 DSH 拆开,顶层「权限与会话」页随之折进通用设置。
     默认档只含三档:`auto`(Auto review, EXP)只属于当前会话档
     (`presentation.ts:15-19`,见 docs/settings-porting-notes.md §7.5 第 1 条)。
     为何这样切、代价是什么见
     .agents/notes/implemented/2026-09-30-permission-setting-folds-into-general.md */
  let defaultPermission = "workspace-write";
  const defaultPermInfo = () =>
    Takeovers.perms.find((p) => p.id === defaultPermission) || Takeovers.perms[1];
  const defaultPermChoices = () => Takeovers.perms.filter((p) => p.id !== "auto");

  function applyDefaultPerm(id) {
    if (!Takeovers.perms.some((p) => p.id === id)) return;
    defaultPermission = id;
    toast("新会话默认权限已设为 " + defaultPermInfo().label + "(演示;写入需 bridge permission.defaultPreset)");
    if (settingsSection === "general") renderSettingsDetail("general");
  }

  function renderSettingsDetail(section) {    if (!settingsDetail) return;
    const configs = {
      account: {
        title: "账号与余额",
        intro: "DSH Web 的账号状态属于电脑端。手机只展示脱敏状态,不提供会打断电脑任务的退出操作。",
        body: `<section class="settings-detail-group"><h3>电脑端账号</h3><div class="settings-card">
          ${settingsControl("DeepSeek 账号", "已登录电脑端 DSH", '<span class="settings-badge">已登录</span>')}
          ${settingsControl("充值余额", "电脑端账户余额", '<span class="settings-badge">只读</span>')}
          ${settingsControl("赠金余额", "电脑端账户余额", '<span class="settings-badge">只读</span>')}
        </div></section>
        <div class="settings-readonly">退出登录会影响电脑端正在运行的任务,第一版手机不提供退出按钮。如需账户操作,请在电脑端完成。</div>`,
      },
      general: {
        title: "通用设置",
        intro: "按 DSH `settings.general.item` 的 order 排列;这组偏好只影响手机,不覆盖电脑 DSH 的同名偏好。",
        body: `
          <section class="settings-detail-group"><h3>权限</h3><div class="settings-card">
            ${settingsControl("新会话默认权限", "只影响之后新建的会话", `<button class="settings-badge" data-act="pick-default-perm">${defaultPermInfo().label}</button>`)}
            ${settingsControl("当前会话权限", "由输入栏的权限图标调整;完全权限仍需风险确认", `<span class="settings-badge">${Takeovers.permissionInfo.label}</span>`)}
          </div></section>
          <section class="settings-detail-group"><h3>显示</h3><div class="settings-card">
            ${settingsControl("语言", "界面语言", '<span class="settings-badge">简体中文</span>')}
            ${toggleControl("外观", "主题跟随 DSH Mobile 主题层", true, "appearance")}
            ${settingsControl("字号大小", "仅影响会话内容的字号", '<span class="settings-badge">系统默认</span>')}
            ${settingsControl("工作步骤展示", "消息中的步骤与工具轨迹", '<span class="settings-badge">标准</span>')}
            ${toggleControl("显示代码工作视图", "开启后显示轨迹、本轮代码差异;关闭会一并隐藏", true, "code-view")}
            ${settingsControl("网页链接打开方式", "只影响手机端链接", '<span class="settings-badge">系统浏览器</span>')}
          </div></section>
          <section class="settings-detail-group"><h3>输入与性能</h3><div class="settings-card">
            ${settingsControl("繁忙时的发送行为", "排队 / 插话由 bridge session.startTurn / steer 支持", '<span class="settings-badge">插话发送</span>')}
            ${settingsControl("性能与用量", "状态 dock 与统计 sheet", '<span class="settings-badge">详细</span>')}
          </div></section>
          <section class="settings-detail-group"><h3>日志</h3><div class="settings-card">
            ${toggleControl("在使用官方模型 API 时上传 Session Log", "帮助改进 DeepSeek 模型与产品;需下发到电脑", false, "session-log")}
          </div></section>
          <p class="settings-note">快捷键(DSH order 16)手机无物理键盘,不搬;当前版本(order 100)按第一版分组放在「关于与连接」,避免同一事实两处写。排列依据 docs/settings-porting-notes.md。</p>`,
      },
      models: {
        title: "模型与服务商",
        intro: "连接电脑模式下,模型目录与提供商由电脑 DSH 持有;手机只显示脱敏状态。切换/修改需要 bridge 扩展。",
        body: `
          <section class="settings-detail-group"><h3>当前选择</h3><div class="settings-card">
            ${settingsControl("当前模型", "推理等级从输入栏模型入口调整", '<span class="settings-badge">claude-opus · 高</span>')}
          </div></section>
          <section class="settings-detail-group"><h3>提供商</h3><div class="settings-card">
            <div class="settings-provider"><span class="provider-mark">${ic("sparkle", 18)}</span><span class="provider-copy"><strong>Anthropic</strong><span>API 密钥 · 已设置 · 值不会回传手机</span></span><span class="settings-badge">连接中</span></div>
            <div class="settings-provider"><span class="provider-mark">${ic("api", 18)}</span><span class="provider-copy"><strong>OpenAI 兼容</strong><span>未配置 · 需要 bridge 写入</span></span><span class="provider-action">配置</span></div>
          </div></section>
          <div class="settings-empty-action">${ic("plus", 16)} 添加提供商 <span class="settings-badge">需 bridge</span></div>
          <p class="settings-note">API 密钥只有 set / unset 写入通道,不会通过 describe 读取。自定义端点、模型目录与获取可用模型属于连接电脑模式分叉。</p>`,
      },
      plugins: {
        title: "内置插件",
        intro: "这是只读清单,不是插件自定义页面。插件的 React 页面不在手机端伪造。",
        body: `
          <section class="settings-detail-group"><h3>已发现</h3><div class="settings-card">
            <div class="settings-provider"><span class="provider-mark">${ic("pluginPinwheel", 18)}</span><span class="provider-copy"><strong>Session Log</strong><span>官方插件 · 已加载 · 配置由电脑端页面维护</span></span><span class="settings-badge">运行中</span></div>
            <div class="settings-provider"><span class="provider-mark">${ic("workspaceTree", 18)}</span><span class="provider-copy"><strong>Workspace Tools</strong><span>官方插件 · 已加载 · 3 个组件</span></span><span class="settings-badge">运行中</span></div>
            <div class="settings-provider"><span class="provider-mark">${ic("warningTriangle", 18)}</span><span class="provider-copy"><strong>Example Plugin</strong><span>未加载 · 暂时无法配置</span></span><span class="settings-badge warn">unavailable</span></div>
          </div></section>
          <div class="settings-readonly">手机第一版支持清单、状态与搜索。安装、启停、安装脚本批准属于第二阶段 bridge 能力;插件配置与自定义页面需在电脑端编辑或打开。</div>`,
      },
      "agent-presets": {
        title: "Agent 预设",
        intro: "手机先做列表与默认值;预设配置在电脑端只读查看。",
        body: `
          <section class="settings-detail-group"><h3>预设列表</h3><div class="settings-card">
            ${settingsControl("默认助手", "claude-opus · 高", '<span class="settings-badge">当前</span>')}
            ${settingsControl("代码审查", "gpt-5-codex · 标准", '<button class="settings-badge" data-act="toast" data-msg="已设为默认(演示)">设为默认</button>')}
            ${settingsControl("只读研究", "deepseek-v4-flash · 低", '<button class="settings-badge" data-act="toast" data-msg="已设为默认(演示)">设为默认</button>')}
          </div></section>
          <div class="settings-readonly">查看配置是只读状态。让 Agent 创建预设属于桌面工作流,不进第一版手机设置。</div>`,
      },
      about: {
        title: "关于与连接",
        intro: "设备连接、版本与电脑端配置入口。",
        body: `
          <section class="settings-detail-group"><h3>连接</h3><div class="settings-card">
            ${settingsControl("我的电脑", "Windows · 直连已连接 · 空闲", '<span class="settings-badge">在线</span>')}
            ${settingsControl("设备管理", "配对、吊销与切换设备", settingsArrow())}
          </div></section>
          <section class="settings-detail-group"><h3>连接方式</h3><div class="settings-card">
            <div class="settings-provider"><span class="provider-mark">${ic("link", 18)}</span><span class="provider-copy"><strong>直连</strong><span>ws://192.168.2.43:8790 · 同一 WiFi</span><span>当前连接</span></span><span class="settings-badge">首选</span></div>
            <div class="settings-provider" data-act="toast" data-msg="演示:已把中转设为首选,下次重连生效"><span class="provider-mark">${ic("globe", 18)}</span><span class="provider-copy"><strong>中转</strong><span>ws://192.168.2.43:8787 · 保底通道</span><span>直连不可用时自动走它</span></span><span class="settings-badge">设为首选</span></div>
          </div>
          <p class="settings-note">排在第一位的先拨,拨不通自动顺延;点一行把它设为首选,下次重连生效。端点只是地址、不含凭据 —— 换端点不重扫码。</p></section>
          <section class="settings-detail-group"><h3>应用</h3><div class="settings-card">
            ${settingsControl("当前版本", "手机 App;电脑端 DSH 版本需 bridge", '<span class="settings-badge">0.1.0</span>')}
            ${settingsControl("打开电脑端配置文件", "由电脑上的原生编辑器打开", '<button class="settings-badge" data-act="toast" data-msg="已请求电脑端打开配置文件">打开</button>')}
          </div></section>
          <p class="settings-note">连接模式与本机运行模式的 Provider / Model / Assistant 配置分叉,详见 docs/standalone-mode-notes.md。</p>`,
      },
    };
    const cfg = configs[section] || configs.general;
    settingsSection = section;
    settingsTitle.textContent = cfg.title;
    settingsDetail.innerHTML = `<div class="settings-detail-intro">${cfg.intro}</div>${cfg.body}`;
    settingsHome.hidden = true;
    settingsDetail.hidden = false;
    settingsDetail.classList.remove("is-on");
    requestAnimationFrame(() => settingsDetail.classList.add("is-on"));
    paintIcons(settingsDetail);
    const back = $("#settingsBack");
    if (back) back.dataset.settingsDetail = "1";
  }

  function openSettings(section) {
    if (!settingsPage) return;
    if (!section) {
      settingsSection = null;
      settingsTitle.textContent = "设置";
      renderSettingsHome();
      settingsHome.hidden = false;
      settingsDetail.hidden = true;
      const back = $("#settingsBack");
      if (back) delete back.dataset.settingsDetail;
    } else {
      renderSettingsDetail(section);
    }
    settingsPage.classList.add("is-in");
    settingsPage.setAttribute("aria-hidden", "false");
    appRoot.classList.add("settings-open");
    openLayer("settings", () => closeSettings(true));
    haptic();
  }

  function closeSettings(viaHistory) {
    if (!settingsPage) return;
    settingsPage.classList.remove("is-in");
    settingsPage.setAttribute("aria-hidden", "true");
    appRoot.classList.remove("settings-open");
    settingsSection = null;
    if (!viaHistory) closeLayer("settings");
  }

  function settingsBack() {
    if (settingsSection) openSettings();
    else closeSettings();
  }
  renderSettingsHome();

  /* ============================================================ 自动化任务(ui-schedule)
     列表照 DSH `TaskManagerPage.tsx:114-203`:状态筛选(全部/已开启/已结束)+ 搜索
     + 行内"提醒频率"与"下次计划时间";行按 scheduledAt 升序(`:64-65`);空态三分(`:69-71`)。
     下次计划时间的绝对戳与相对距离照 `schedule-format.ts:405-439`(nextRunParts):
     中文绝对戳不带年(`:342-357`),相对写 `(3小时后)` / `(已逾期 2小时)` / `(现在到期)`
     (`frequency-locales.ts:66-68`)。文案（含全角标点）照抄 `task-manager-locales.ts` 的 zh。
     详情只做规则里的名称与内容:时间规则编辑要 cron 与时区选择器(`TaskDetail.tsx`),原型不做;
     "任务运行记录"要 `schedule.records`,当前 bridge 没有,不做也不伪造(`:813-824`)。
     已结束任务整块只读,照 `TaskDetail.tsx:758-763,784,789-790,801,842`。
     删除确认文案照 `task-manager-locales.ts:270-278`。
     页面不提供创建表单:DSH 的"新建"是开新会话让模型建任务(`TaskManagerPage.tsx:22-27`)。
     数据是演示数据:`schedule.list/update/delete` 未进 AA bridge,原型不假装已远程提交。
     见 .agents/notes/implemented/2026-09-30-automation-tasks-page-scope.md */
  const tasksPage = $("#pageTasks");
  const tasksView = $("#tasksView");
  const tasksDetail = $("#tasksDetail");
  const tasksSearch = $("#tasksSearch");
  const tasksSearchClear = $("#tasksSearchClear");

  /* 演示数据按"装载时刻 + 偏移"生成:写死日期会让相对时间永远显示"已逾期"。
     频率文案取 DSH `frequency-locales.ts` 与 `task-manager-locales.ts:203` 的 zh 口径。 */
  const HOUR_MS = 3600000;
  const taskAt = (offset) => new Date(Date.now() + offset).toISOString();
  const TASK_SEED = [
    {
      id: "sched-7f31a4",
      name: "每日构建巡检",
      prompt: "检查昨天的 CI 构建结果,失败就总结根因并给出修复建议",
      status: "active",
      frequency: "每天 09:00",
      scheduledAt: taskAt(3 * HOUR_MS),
      sessionId: "sess-2b91",
      sessionTitle: "手机端控制电脑DSH方案",
    },
    {
      id: "sched-2c07de",
      name: "工作日依赖更新提醒",
      prompt: "每个工作日早上汇总依赖更新,有安全补丁就单独标出来",
      status: "active",
      frequency: "周一至周五 08:30",
      scheduledAt: taskAt(26 * HOUR_MS),
      sessionId: "sess-4d18",
      sessionTitle: "依赖升级与安全补丁",
    },
    {
      id: "sched-9a1c53",
      name: "发布前一键回归",
      prompt: "发布前跑一遍回归脚本,把失败用例贴回这个会话",
      status: "inactive",
      frequency: "仅一次",
      scheduledAt: taskAt(-20 * HOUR_MS),
      sessionId: "sess-77ac",
      sessionTitle: "v0.3 发布检查",
    },
  ];

  /* 演示目录是可变数组(删除会 splice),所以从种子重建 —— 验证脚本靠它复位空态分支 */
  const DEMO_TASKS = [];
  const resetDemoTasks = () => {
    DEMO_TASKS.length = 0;
    DEMO_TASKS.push(...TASK_SEED.map((t) => ({ ...t })));
  };
  resetDemoTasks();

  let tasksFilter = "all";
  let tasksQuery = "";
  let tasksSelected = null;
  let taskDraft = null;
  let taskDetailTimer = null;
  const taskAttr = (s) => H(String(s)).replace(/"/g, "&quot;");

  /* 绝对戳:中文不带年,照 DSH YEAR_LANGUAGES / NO_YEAR_LANGUAGES(schedule-format.ts:342-357) */
  function taskAbsolute(iso) {
    const at = Date.parse(iso);
    if (Number.isNaN(at)) return iso;
    return new Intl.DateTimeFormat("zh-CN", {
      month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
    }).format(at);
  }
  /* 相对距离:取最大自然单位;未来向上取整、逾期向下取整(schedule-format.ts:424-439) */
  function taskRelative(iso) {
    const diff = Date.parse(iso) - Date.now();
    if (diff === 0) return "现在到期";
    const seconds = Math.abs(diff) / 1000;
    const units = [["天", 86400], ["小时", 3600], ["分钟", 60], ["秒", 1]];
    const hit = units.find((u) => seconds >= u[1]) || units[units.length - 1];
    const value = Math.max(1, diff > 0 ? Math.ceil(seconds / hit[1]) : Math.floor(seconds / hit[1]));
    return diff > 0 ? `${value}${hit[0]}后` : `已逾期 ${value}${hit[0]}`;
  }
  /* 搜索命中面照 DSH `TaskManagerPage.tsx:61-63`:内容 / 会话 id / 任务名 */
  function taskMatches(t, q) {
    return (
      t.prompt.toLowerCase().includes(q) ||
      t.sessionId.toLowerCase().includes(q) ||
      t.name.toLowerCase().includes(q)
    );
  }
  function visibleTasks() {
    const q = tasksQuery.trim().toLowerCase();
    return DEMO_TASKS
      .filter((t) => (tasksFilter === "all" || t.status === tasksFilter) && taskMatches(t, q))
      .sort((a, b) => Date.parse(a.scheduledAt) - Date.parse(b.scheduledAt));
  }
  function taskEmptyTitle() {
    if (tasksFilter === "inactive" && tasksQuery.trim() === "") return "没有已结束的自动化任务";
    if (DEMO_TASKS.length === 0) return "还没有自动化任务，在会话中创建的任务会显示在这里";
    return "没有匹配的自动化任务";
  }

  function renderTasks() {
    if (!tasksView) return;
    if (tasksSearchClear) tasksSearchClear.hidden = tasksQuery === "";
    const rows = visibleTasks();
    if (!rows.length) {
      tasksView.innerHTML = `<div class="tasks-empty">
        <span class="empty-glyph">${ic("clock", 24)}</span>
        <h2>${taskEmptyTitle()}</h2>
        <button class="btn btn--out tasks-empty-action" data-act="tasks-new">新建自动化任务</button>
      </div>`;
      paintIcons(tasksView);
      return;
    }
    tasksView.innerHTML = rows
      .map(
        (t) => `<button class="task-row" data-act="task-open" data-id="${taskAttr(t.id)}" data-status="${t.status}">
        <span class="task-glyph">${ic("clock", 15)}</span>
        <span class="task-copy">
          <span class="task-name">${H(t.name)}</span>
          <span class="task-meta">
            ${t.status === "inactive" ? `<span class="badge-off">已结束</span>` : ""}
            <span>${H(t.frequency)}</span>
            ${
              t.status === "active"
                ? `<span>下次计划时间：<time datetime="${taskAttr(t.scheduledAt)}">${taskAbsolute(t.scheduledAt)}</time> <span class="next-rel">(${taskRelative(t.scheduledAt)})</span></span>`
                : ""
            }
          </span>
        </span>
      </button>`
      )
      .join("");
    paintIcons(tasksView);
  }

  function renderTaskDetail() {
    if (!tasksDetail) return;
    const task = DEMO_TASKS.find((t) => t.id === tasksSelected);
    if (!task) {
      tasksDetail.classList.remove("is-in");
      tasksDetail.hidden = true;
      return;
    }
    const readonly = task.status === "inactive";
    const dirty = taskDraft && (taskDraft.name !== task.name || taskDraft.prompt !== task.prompt);
    const nameField = readonly
      ? `<div class="tasks-field"><span class="field-label">自动化任务名称</span><p class="tasks-readonly">${H(task.name)}</p></div>`
      : `<div class="tasks-field"><label class="field-label" for="taskName">自动化任务名称</label>
          <input id="taskName" maxlength="120" value="${taskAttr(taskDraft ? taskDraft.name : task.name)}" aria-label="自动化任务名称"></div>`;
    const promptField = readonly
      ? `<div class="tasks-field"><span class="field-label">自动化任务内容</span><p class="tasks-readonly">${H(task.prompt)}</p></div>`
      : `<div class="tasks-field"><label class="field-label" for="taskPrompt">自动化任务内容</label>
          <textarea id="taskPrompt" rows="3" aria-label="自动化任务内容">${H(taskDraft ? taskDraft.prompt : task.prompt)}</textarea></div>`;
    tasksDetail.innerHTML = `
      <div class="tasks-detail-head">
        <button class="ib" data-act="task-detail-close" data-icon="chevronLeft" aria-label="关闭详情"></button>
        <h2>任务详情</h2>
        <button class="ib" data-act="task-delete" data-icon="trash" aria-label="删除任务"></button>
      </div>
      <div class="tasks-detail-scroll">
        <div class="settings-card">${nameField}${promptField}</div>
        <div class="settings-card">
          ${settingsControl("状态", "", `<span class="settings-badge">${readonly ? "已结束" : "已开启"}</span>`)}
          ${
            readonly
              ? settingsControl("下次计划时间", "", `<span class="settings-badge">已结束</span>`)
              : settingsControl("下次计划时间", `${taskAbsolute(task.scheduledAt)} (${taskRelative(task.scheduledAt)})`, "")
          }
          ${settingsControl("提醒频率", "时间规则编辑需要 cron 与时区选择器", `<span class="settings-badge">${H(task.frequency)}</span>`)}
          ${settingsControl("任务 ID", "", `<span class="settings-badge">${taskAttr(task.id)}</span>`)}
          ${settingsControl("关联会话", "打开原会话需要会话目录,当前 bridge 未提供", `<span class="settings-badge">需 bridge</span>`)}
        </div>
        ${
          readonly
            ? ""
            : `<footer class="tasks-save" id="taskSave"${dirty ? "" : " hidden"}>
                <span class="save-notice">有未保存的修改</span>
                <button class="btn btn--out" data-act="task-draft-cancel">取消</button>
                <button class="btn btn--fill" data-act="task-draft-save">保存修改</button>
              </footer>`
        }
        <p class="tasks-detail-note">${
          readonly
            ? "已结束的任务为只读，无法修改时间。"
            : "演示数据：<code>schedule.list/update/delete</code> 未进 bridge，这里的编辑与删除不会下发到电脑。"
        }</p>
      </div>`;
    paintIcons(tasksDetail);
    /* 输入时只切保存栏的显隐,不整块重渲染 —— 重渲染会销毁输入框,从名称点内容框时会丢焦点。 */
    const nameEl = $("#taskName");
    const promptEl = $("#taskPrompt");
    const saveEl = $("#taskSave");
    const syncSave = () => {
      if (!taskDraft || !saveEl) return;
      if (nameEl) taskDraft.name = nameEl.value;
      if (promptEl) taskDraft.prompt = promptEl.value;
      saveEl.hidden = taskDraft.name === task.name && taskDraft.prompt === task.prompt;
    };
    if (nameEl) nameEl.addEventListener("input", syncSave);
    if (promptEl) promptEl.addEventListener("input", syncSave);
  }

  function openTaskDetail(id) {
    const task = DEMO_TASKS.find((t) => t.id === id);
    if (!task || !tasksDetail) return;
    tasksSelected = id;
    taskDraft = { name: task.name, prompt: task.prompt };
    if (taskDetailTimer) {
      clearTimeout(taskDetailTimer);
      taskDetailTimer = null;
    }
    renderTaskDetail();
    tasksDetail.hidden = false;
    requestAnimationFrame(() => tasksDetail.classList.add("is-in"));
    haptic();
  }

  function closeTaskDetail(immediate) {
    tasksSelected = null;
    taskDraft = null;
    if (!tasksDetail) return;
    if (taskDetailTimer) {
      clearTimeout(taskDetailTimer);
      taskDetailTimer = null;
    }
    tasksDetail.classList.remove("is-in");
    if (immediate) tasksDetail.hidden = true;
    else taskDetailTimer = setTimeout(() => { tasksDetail.hidden = true; taskDetailTimer = null; }, 320);
  }

  function openTasks() {
    if (!tasksPage) return;
    tasksFilter = "all";
    tasksQuery = "";
    if (tasksSearch) tasksSearch.value = "";
    $$(".tasks-filter", tasksPage).forEach((b) => {
      const on = b.dataset.filter === "all";
      b.classList.toggle("is-on", on);
      b.setAttribute("aria-pressed", on ? "true" : "false");
    });
    closeTaskDetail(true);
    renderTasks();
    tasksPage.classList.add("is-in");
    tasksPage.setAttribute("aria-hidden", "false");
    openLayer("tasks", () => closeTasks(true));
    haptic();
  }

  function closeTasks(viaHistory) {
    if (!tasksPage) return;
    closeTaskDetail(true);
    tasksPage.classList.remove("is-in");
    tasksPage.setAttribute("aria-hidden", "true");
    if (!viaHistory) closeLayer("tasks");
  }

  /* 删除确认照 `task-manager-locales.ts:270-278`;真实动作要 bridge schedule.delete。 */
  function confirmDeleteTask() {
    const task = DEMO_TASKS.find((t) => t.id === tasksSelected);
    if (!task) return;
    openSheet({
      title: "删除此任务？",
      body: `<p style="margin:0;color:var(--on2);font-size:13.5px;line-height:20px">任务将停止触发，并连同其已保存的任务运行记录一并删除。原会话及其消息仍然保留；已排队的消息不会被撤回。</p>
        <p style="margin:10px 0 0;color:var(--cap);font-size:11.5px;line-height:17px">演示：删除只作用于本机原型数据，不下发到电脑。</p>`,
      actions: [
        { label: "取消", kind: "out" },
        {
          label: "确认删除",
          kind: "danger",
          onClick: () => {
            const i = DEMO_TASKS.findIndex((x) => x.id === task.id);
            if (i >= 0) DEMO_TASKS.splice(i, 1);
            closeTaskDetail(true);
            renderTasks();
            toast("任务已删除(演示;真实动作需 bridge schedule.delete)");
          },
        },
      ],
    });
  }

  if (tasksSearch) {
    tasksSearch.addEventListener("input", () => {
      tasksQuery = tasksSearch.value;
      renderTasks();
    });
  }
  renderTasks();


  /* ============================================================ 事件代理 */
  document.addEventListener("click", (e) => {
    const t = e.target.closest("[data-act]");
    if (!t) return;
    const act = t.dataset.act;
    switch (act) {
      case "drawer-open":
        D.open();
        break;
      case "drawer-close":
        D.close();
        break;
      case "settings-open":
        /* 从左抽屉切到设置页不能先 D.close() 再 push settings:
           drawer 的 history.back() 是异步的,晚到的 popstate 会把设置页误关。
           先同步摘掉 drawer 层,再打开 settings 层。 */
        if (D.p > 0) {
          D.set(0, true);
          closeLayer("drawer", true);
        }
        openSettings();
        break;
      case "settings-detail":
        openSettings(t.dataset.section);
        break;
      case "settings-back":
        settingsBack();
        break;
      case "settings-close":
        closeSettings();
        break;
      case "settings-toggle":
        t.classList.toggle("is-on");
        t.setAttribute("aria-pressed", t.classList.contains("is-on") ? "true" : "false");
        haptic();
        break;
      case "tasks-open":
        /* 与 settings-open 同一条路径:从左抽屉切到全屏页时先同步摘掉 drawer 层。
           不摘的话页面会开在仍未收起的抽屉后面(返回栈还会留下 'drawer' 幽灵层)。 */
        if (D.p > 0) {
          D.set(0, true);
          closeLayer("drawer", true);
        }
        openTasks();
        break;
      case "tasks-close":
        closeTasks();
        break;
      case "tasks-filter": {
        tasksFilter = t.dataset.filter;
        $$(".tasks-filter", tasksPage).forEach((b) => {
          const on = b === t;
          b.classList.toggle("is-on", on);
          b.setAttribute("aria-pressed", on ? "true" : "false");
        });
        renderTasks();
        haptic();
        break;
      }
      case "tasks-search-clear":
        tasksQuery = "";
        if (tasksSearch) tasksSearch.value = "";
        renderTasks();
        break;
      case "tasks-new":
        /* DSH 的"新建"是开新会话让模型建任务,页面本身没有创建表单
           (`TaskManagerPage.tsx:22-27`);原型把这件事如实说成"需要电脑端"。 */
        toast("已请求电脑端新建会话:自动化任务由模型在会话里创建(演示;真实动作需 bridge)");
        break;
      case "task-open":
        openTaskDetail(t.dataset.id);
        break;
      case "task-detail-close":
        closeTaskDetail();
        break;
      case "task-delete":
        confirmDeleteTask();
        break;
      case "task-draft-save": {
        const task = DEMO_TASKS.find((x) => x.id === tasksSelected);
        if (!task || !taskDraft) break;
        const name = taskDraft.name.trim();
        const prompt = taskDraft.prompt.trim();
        if (!name || name.length > 120) {
          toast("请输入不超过 120 个字符的任务名称");
          break;
        }
        if (!prompt) {
          toast("请输入任务内容");
          break;
        }
        task.name = name;
        task.prompt = prompt;
        taskDraft = { name, prompt };
        renderTaskDetail();
        renderTasks();
        toast("任务已更新(演示;真实动作需 bridge schedule.update)");
        break;
      }
      case "task-draft-cancel": {
        const task = DEMO_TASKS.find((x) => x.id === tasksSelected);
        if (task) taskDraft = { name: task.name, prompt: task.prompt };
        renderTaskDetail();
        break;
      }
      case "goal-pause":
        DEMO_GOAL.phase = "paused";
        renderGoalDock();
        toast("目标已暂停(演示;真实动作需 bridge goals.pause)");
        break;
      case "goal-resume":
        DEMO_GOAL.phase = "active";
        renderGoalDock();
        toast("目标已恢复(演示;真实动作需 bridge goals.resume)");
        break;
      case "goal-edit":
        DEMO_GOAL.editing = true;
        renderGoalDock();
        break;
      case "goal-edit-cancel":
        DEMO_GOAL.editing = false;
        renderGoalDock();
        break;
      case "goal-edit-save": {
        const input = $("#goalEditInput");
        const value = input ? input.value.trim() : "";
        if (!value) { toast("目标内容不能为空"); break; }
        DEMO_GOAL.objective = value;
        DEMO_GOAL.revision += 1;
        DEMO_GOAL.editing = false;
        renderGoalDock();
        toast("目标已编辑(演示;真实动作需 bridge goals.edit)");
        break;
      }
      case "goal-clear":
        DEMO_GOAL.deleted = true;
        DEMO_GOAL.editing = false;
        renderGoalDock();
        toast("目标已清除(演示;真实动作需 bridge goals.clear)");
        break;
      case "goal-reopen":
        DEMO_GOAL.deleted = false;
        DEMO_GOAL.phase = "active";
        renderGoalDock();
        toast("已恢复演示目标");
        break;
      case "todo-toggle":
        todoExpanded = !todoExpanded;
        renderTodoDock();
        break;
      case "new-session":
        /* 手机上按 ⊕ 走 `session.create` 再打开它 —— 新会话是 blank,
           于是落到**新会话页**(hero)。原型照同一条:切到 blank 状态。 */
        setBlankSession(true);
        toast("已新建会话(blank)—— 这一屏就是 DSH 的新会话页");
        break;
      case "hero-workspace":
        openSheet({
          title: "工作区",
          size: "half",
          body:
            HERO_WORKSPACES.map(
              (w) => `<button class="sitem" data-act="hero-workspace-set" data-ws="${w.id}">
                <span class="i">${ic("folderOpen", 16)}</span>
                <span class="m">${w.name}<span class="s">${w.path}</span></span>
                ${heroWorkspace === w.id ? '<span class="ck">✓</span>' : ""}
              </button>`
            ).join("") +
            /* 与手机同一条纪律:拿不到清单就**明说**,不摆一个空选择器
               (真机走 `workspace.list`,缺 `workspaceController` 时方法不出现)。 */
            `<p class="opt-desc" style="padding:10px 12px 0">
              切工作区 = 立刻落到该工作区的 blank 会话(DSH navigation.ts:220-230),
              不是只记住选择。手机上这一步走 session.create({workspaceId})。</p>`,
        });
        break;
      case "hero-workspace-set": {
        heroWorkspace = t.dataset.ws;
        renderHeroChips();
        closeSheet(true);
        const picked = HERO_WORKSPACES.find((w) => w.id === heroWorkspace);
        toast(`已在新任务里切到「${picked ? picked.name : heroWorkspace}」`);
        break;
      }
      case "hero-preset":
        openSheet({
          title: "Agent 预设",
          size: "half",
          body:
            HERO_PRESETS.map(
              (p) => `<button class="sitem" data-act="hero-preset-set" data-preset="${p.id}">
                <span class="i">${ic("agentPreset", 16)}</span>
                <span class="m">${p.name}<span class="s">${p.desc}</span></span>
                ${heroPreset === p.id ? '<span class="ck">✓</span>' : ""}
              </button>`
            ).join("") +
            /* 立场照 DSH 的 `AgentPresetSeat.tsx:4-9`:这个选择只在会话开始前成立,
               "跑过一轮的会话"上没有它。 */
            `<p class="opt-desc" style="padding:10px 12px 0">
              预设只在任务开始前可选 —— 会话跑过一轮后组合就固定了
              (DSH 会回 agent-preset/locked)。手机上选它 = 带 agentPreset 建一个新任务。</p>`,
        });
        break;
      case "hero-preset-set": {
        heroPreset = t.dataset.preset;
        renderHeroChips();
        closeSheet(true);
        const picked = HERO_PRESETS.find((p) => p.id === heroPreset);
        toast(`已在新任务里切到「${picked ? picked.name : heroPreset}」`);
        break;
      }
      case "open-file":
        openFile(t.dataset.file, t.dataset.state);
        break;
      case "files-all":
        openSheet({
          title: "本轮改动 7 个文件",
          size: "half",
          body: Object.keys(FILES)
            .map((p) => {
              const f = FILES[p];
              const st =
                f.status === "created"
                  ? "新建"
                  : f.status === "deleted"
                  ? "删除"
                  : f.status === "unchanged"
                  ? "无改动"
                  : f.status === "binary"
                  ? "二进制"
                  : "已修改";
              return `<button class="sitem" data-act="open-file" data-file="${p}">
                <span class="i">${
          f.status === "created"
            ? ic("plus", 16)
            : f.status === "deleted"
            ? ic("close", 16)
            : ic("code", 16)
        }</span>
                <span class="m"><span style="font-family:var(--mono);font-size:13px">${p}</span>
                <span class="s">${st}</span></span>
                <span class="st" style="font-family:var(--mono);font-size:11.5px">
                  ${f.add ? '<span style="color:var(--fadd-mk)">+' + f.add + "</span>" : ""}
                  ${f.del ? '<span style="color:var(--fdel-mk)">−' + f.del + "</span>" : ""}
                </span></button>`;
            })
            .join(""),
        });
        break;
      case "toast":
        toast(t.dataset.msg || "演示动作");
        break;
      case "jobs-toggle":
        $("#sideTabs").querySelector('[data-panel="jobs"]').click();
        break;
      case "subs-toggle":
        $("#sideTabs").querySelector('[data-panel="subs"]').click();
        break;
      case "jobs-all":
        openSide("jobs");
        break;
      case "subs-all":
        openSide("subs");
        break;
      case "jobs-clear": {
        const before = JOBS.length;
        for (let i = JOBS.length - 1; i >= 0; i--)
          if (JOBS[i].state !== "running") JOBS.splice(i, 1);
        renderJobs();
        toast(
          before === JOBS.length
            ? "没有可清空的已结束任务"
            : "已清空 " + (before - JOBS.length) + " 个已结束任务"
        );
        break;
      }
      case "jobs-stop-all": {
        const run = JOBS.filter((j) => j.state === "running");
        run.forEach((j) => stopJob(j.id));
        if (!run.length) toast("没有运行中的任务");
        break;
      }
      case "drawer-search-clear":
        if (dsInput) {
          dsInput.value = "";
          applyDrawerSearch();
          dsInput.focus();
        }
        break;
      case "qreply-toggle":
        t.closest(".qreply").classList.toggle("is-open");
        haptic();
        break;
      case "reopen-approval":
      case "reopen-question": {
        const want = act === "reopen-approval" ? "approval" : "question";
        if (!Takeovers.focus || !Takeovers.focus(want)) {
          toast("这一项已经处理完了,再点「交互演示」重新入队");
        }
        break;
      }
      case "demo":
        openSheet({
          title: "交互演示",
          size: "half",
          body: `
            <button class="sitem" data-act="demo-approval"><span class="i">${ic("api", 16)}</span>
              <span class="m">审批瀑布(2 项)<span class="s">拒绝 / 允许一次,逐项处理</span></span></button>
            <button class="sitem" data-act="demo-question"><span class="i">${ic("question", 16)}</span>
              <span class="m">提问(3 题)<span class="s">单选+推荐 / 多选 / 纯自定义答案</span></span></button>
            <button class="sitem" data-act="demo-plan"><span class="i">${ic("plan", 16)}</span>
              <span class="m">计划待审<span class="s">要求修改 / 同意执行</span></span></button>
            <button class="sitem" data-act="demo-all"><span class="i">${ic("queue", 16)}</span>
              <span class="m">全部入队<span class="s">看瀑布队列提示</span></span></button>
            <button class="sitem" data-act="demo-gate"><span class="i">${ic("permissionFullAccess", 16)}</span>
              <span class="m">权限风险确认门<span class="s">切到完全权限要勾选风险确认</span></span></button>`,
        });
        break;
      case "demo-approval":
        closeSheet();
        Takeovers.demo.approval();
        break;
      case "demo-question":
        closeSheet();
        Takeovers.demo.question();
        break;
      case "demo-plan":
        closeSheet();
        Takeovers.demo.plan();
        break;
      case "demo-all":
        closeSheet();
        Takeovers.demo.all();
        break;
      case "demo-gate":
        closeSheet();
        Takeovers.gateSheet(openSheet, () => {});
        break;
      case "tj-chip": {
        const sib = t.parentElement.querySelectorAll(".chip");
        sib.forEach((c) => c.classList.toggle("is-on", c === t));
        haptic();
        break;
      }
      case "file-back":
      case "side-close":
        closeSide();
        break;
      case "side-open":
        /* 右缘把手(§7.8):与连接 sheet 里的 conn-open-side 是同一条路,
           只是不再经过 sheet —— 入口本身就该一步到。 */
        openSide("file");
        break;
      case "status-open":
        /* 点顶栏连接状态位 → 弹「连接操作」sheet(议题 3):重新配对 / 打开侧面板 / 取消。
           不再是直接开右抽屉——"打开侧面板"降为 sheet 里的一个选项(见 docs §7.8 偏离)。
           重新配对是演示动作,走 data-act="toast"(照本文件现有 toast 演示项先例);
           取消 / 点遮罩关闭。原型永远有会话、没有空态,故无空态那枚「重新配对」按钮。 */
        openSheet({
          title: "连接操作",
          size: "half",
          body: `
            <div class="sitem"><span class="i">${ic(
              "link",
              16
            )}</span><span class="m">当前连接:直连 · ws://192.168.2.43:8790</span></div>
            <button class="sitem" data-act="toast" data-msg="演示:重新配对会清掉本机凭据,回扫码页(真实动作需 bridge)"><span class="i">${ic(
              "refresh",
              16
            )}</span><span class="m">重新配对(换一台电脑)<span class="s">会清掉本机凭据,需要重新扫码</span></span></button>
            <button class="sitem" data-act="conn-open-side"><span class="i">${ic(
              "panelLeft",
              16
            )}</span><span class="m">打开侧面板</span></button>
            <button class="sitem" data-act="conn-cancel"><span class="m">取消</span></button>`,
        });
        break;
      case "conn-open-side":
        /* 从连接 sheet 里开右抽屉:.sheet-host(z:25)盖在 .page--side(z:12)之上,
           所以不能像 jobs-all 那样只 openSide(那会把连接 sheet 留在 side 之上);
           也不能先 closeSheet() 再 openSide()——closeSheet() 的 history.back() 是异步的,
           会和 side 的 pushState 竞态把 side 误关(AGENTS.md 层规则)。
           照 settings-open/tasks-open 的处理:先**同步**摘掉 sheet 层
           (closeLayer("sheet", true):拆 DOM + 出栈,不再 history.back),再开 side 层。 */
        if (topLayer() && topLayer().kind === "sheet") closeLayer("sheet", true);
        openSide("file");
        break;
      case "conn-cancel":
        closeSheet();
        break;
      case "side-jobs":
        openSide("jobs");
        break;
      case "side-subs":
        openSide("subs");
        break;
      case "file-menu":
        openSheet({
          title: "文件",
          size: "half",
          body: `
            <button class="sitem" data-act="copy-path"><span class="i">${ic("copy", 16)}</span><span class="m">复制路径</span></button>
            <button class="sitem" data-act="open-pc"><span class="i">${ic("rightUp", 16)}</span><span class="m">在电脑上打开</span></button>
            <button class="sitem" data-act="share"><span class="i">${ic("share", 16)}</span><span class="m">导出 / 分享</span></button>
            <button class="sitem" data-act="state-pick"><span class="i">${ic("inspect", 16)}</span><span class="m">切换显示状态</span><span class="s">演示用</span></button>`,
        });
        break;
      case "state-pick":
        openSheet({
          title: "文件状态(演示)",
          size: "half",
          body: Object.keys(BIN_STATES)
            .map(
              (k) =>
                `<button class="sitem" data-act="state-set" data-state="${k}"><span class="m">${k}</span>${
                  curState === k ? '<span class="ck">✓</span>' : ""
                }</button>`
            )
            .join("") +
            `<button class="sitem" data-act="state-set" data-state="ok"><span class="m">ok(正常 diff)</span>${
              curState === "ok" ? '<span class="ck">✓</span>' : ""
            }</button>
             <button class="sitem" data-act="state-set" data-state="truncated"><span class="m">truncated(600 行截断)</span>${
               curState === "truncated" ? '<span class="ck">✓</span>' : ""
             }</button>`,
        });
        break;
      case "state-set":
        curState = t.dataset.state;
        if (curState !== "ok") fileTab = 0;
        closeSheet();
        renderFile();
        break;
      case "copy-path":
        navigator.clipboard && navigator.clipboard.writeText(curFile);
        closeSheet();
        toast("路径已复制");
        break;
      case "open-pc":
        closeSheet();
        toast("已在电脑端打开");
        break;
      case "share":
        closeSheet();
        toast("已唤起系统分享");
        break;
      case "pick-model":
        openModelPicker();
        break;
      case "attach":
        openAttachSheet();
        break;
      case "pick-default-perm":
        openSheet({
          title: "新会话默认权限",
          size: "half",
          body:
            defaultPermChoices()
              .map(
                (p) => `<button class="sitem" data-act="default-perm-set" data-perm="${p.id}">
                  <span class="i">${ic(p.icon, 16)}</span>
                  <span class="m">${p.label}<span class="s">${p.desc}</span></span>
                  ${defaultPermission === p.id ? '<span class="ck">✓</span>' : ""}
                </button>`
              )
              .join("") +
            `<p class="opt-desc" style="padding:10px 12px 0">
              只影响之后新建的会话;当前会话权限在输入栏调整。Auto review(EXP)只属于当前会话档,不在默认可选里。</p>`,
        });
        break;
      case "default-perm-set":
        /* 风险档仍走同一个确认门,只是落点改成默认档 —— 不另造一套门 */
        if (t.dataset.perm === "danger-full-access") {
          Takeovers.gateSheet(openSheet, t.dataset.perm, applyDefaultPerm);
        } else {
          closeSheet(true);
          applyDefaultPerm(t.dataset.perm);
        }
        break;
      case "pick-perm":
        openSheet({
          title: "访问模式",
          size: "half",
          body:
            Takeovers.perms
              .map(
                (p) => `<button class="sitem" data-act="perm-set" data-perm="${p.id}">
                  <span class="i">${ic(p.icon, 16)}</span>
                  <span class="m">${p.label}${
                    p.badge ? ` <span class="badge-rec">${p.badge}</span>` : ""
                  }<span class="s">${p.desc}</span></span>
                  ${Takeovers.permission === p.id ? '<span class="ck">✓</span>' : ""}
                </button>`
              )
              .join("") +
            `<p class="opt-desc" style="padding:10px 12px 0">
              当前:${Takeovers.permissionInfo.label}。非完全权限下,越权工具调用会弹审批接管输入栏。</p>`,
        });
        break;
      case "perm-set":
        /* 风险档:不 close 再 open —— closeSheet 会 history.back(),
           与 openSheet 的 pushState 交错后,晚到的 popstate 会把新层当多余的层弹掉
           (风险确认门会被自己关掉)。openSheet 内部本来就复用同一个 sheet 层。 */
        if (t.dataset.perm === "danger-full-access" || t.dataset.perm === "auto") {
          Takeovers.gateSheet(openSheet, t.dataset.perm);
        } else {
          closeSheet(true);
          Takeovers.setPermission(t.dataset.perm);
          toast("已切到 " + Takeovers.permissionInfo.label);
        }
        break;
      case "pick-set": {
        /* 只剩模型选择走这里;权限模式由 Takeovers.onPermission 统一驱动,避免两个真相来源 */
        const v = t.dataset.pick.split(":")[1];
        $("#chipModel").querySelector("b").textContent = v;
        closeSheet();
        toast("模型已切到 " + v);
        break;
      }
      case "sheet-stats":
        openSheet({
          title: "会话统计",
          body: `
            <div class="kv"><span class="k">模型用时</span><span class="v">12.4<span class="u">s</span></span></div>
            <div class="kv"><span class="k">工具用时</span><span class="v">3.8<span class="u">s</span></span></div>
            <div class="kv"><span class="k">首 token (TTFT)</span><span class="v">420<span class="u">ms</span></span></div>
            <div class="kv"><span class="k">输出速度</span><span class="v">516<span class="u">tok/s</span></span></div>
            <div class="kv"><span class="k">轮次 / 步数</span><span class="v">1 / 3</span></div>`,
        });
        break;
      case "sheet-usage":
        openSheet({
          title: "Token 用量",
          body: `
            <div class="kv"><span class="k">缓存命中</span><span class="v">0%</span></div>
            <div class="kv"><span class="k">未缓存输入</span><span class="v">12,480</span></div>
            <div class="kv"><span class="k">缓存读取</span><span class="v">289,120</span></div>
            <div class="kv"><span class="k">缓存写入</span><span class="v">0</span></div>
            <div class="kv"><span class="k">输出</span><span class="v">1,204</span></div>
            <div class="kv"><span class="k">合计</span><span class="v">302,804</span></div>`,
        });
        break;
      case "sheet-context":
        openSheet({
          title: "上下文已用 3%",
          body: `
            <div class="meterbar">
              <span class="mb-sys" style="width:22%"></span>
              <span class="mb-tool" style="width:31%"></span>
              <span class="mb-msg" style="width:8%"></span>
            </div>
            <div class="legend">
              <span><i class="mb-sys"></i>系统提示词 7.2K</span>
              <span><i class="mb-tool"></i>工具定义 10.1K</span>
              <span><i class="mb-msg"></i>对话消息 2.6K</span>
            </div>
            <div class="kv"><span class="k">已用 / 上限</span><span class="v">19.9K / 1M</span></div>`,
        });
        break;
      case "sheet-traj":
        openSheet({
          title: "轨迹条目",
          body: `
            <div class="kv"><span class="k">角色</span><span class="v">tool · read</span></div>
            <div class="kv"><span class="k">参数</span><span class="v">timeline_page.dart</span></div>
            <div class="kv"><span class="k">耗时</span><span class="v">84<span class="u">ms</span></span></div>
            <div class="kv"><span class="k">结果</span><span class="v">1.2 KB</span></div>`,
          actions: [{ label: "查看完整调用", kind: "fill", onClick: closeSheet }],
        });
        break;
      case "img-open":
        openLightbox(Number(t.dataset.i));
        break;
      case "copy-code":
        navigator.clipboard && navigator.clipboard.writeText(t.dataset.copy || "");
        toast("已复制");
        break;
      case "code-wrap": {
        /* 代码块自动换行开关(照 DSH 的 CodeToolbar):**默认换行**,
           点一下给 `.is-nowrap`(那时才横滚),图标与 aria/title 跟着换。
           对应 App 侧 `dsh_markdown.dart` 的 `_DshCodeBlock`。 */
        const box = t.closest(".code");
        if (!box) break;
        const nowrap = box.classList.toggle("is-nowrap");
        const label = nowrap ? "自动换行" : "取消自动换行";
        t.setAttribute("aria-label", label);
        t.setAttribute("title", label);
        const icon = t.querySelector("[data-icon]");
        if (icon) {
          icon.dataset.icon = nowrap ? "wrapFill" : "nowrapFill";
          paintIcons(t);
        }
        haptic();
        break;
      }
      case "load-more":
        fileView.querySelector(".trunc") &&
          (fileView.querySelector(".trunc").innerHTML =
            "已载入全部 600 行。<button>收起</button>");
        break;
      case "toggle-split": {
        const btn = $("#btnSplit");
        if (!splitView && window.innerWidth < 640) {
          toast("竖屏宽度不够,并排视图建议横屏或平板再看");
          break;
        }
        splitView = !splitView;
        haptic();
        btn.setAttribute("aria-pressed", String(splitView));
        btn.lastChild.textContent = splitView ? "并排" : "统一";
        renderFile();
        break;
      }
      case "toggle-wrap":
        wrapView = !wrapView;
        haptic();
        $("#btnWrap").setAttribute("aria-pressed", String(wrapView));
        fileView.classList.toggle("is-wrap", wrapView);
        break;
      case "lb-close":
        closeLightbox();
        break;
    }
  });

  /* 初始化 */
  autogrow && autogrow();

  /* ---------------------------------------------------------- 输入栏接管挂载 */
  /* 访问模式:控制行上的一枚图标,名字与说明进 aria-label/title。
     完全权限与 Auto review 是"危险档",用告警色标出来。 */
  const permChip = $("#chipPerm");
  function paintPerm(info) {
    if (!permChip) return;
    permChip.innerHTML = ic(info.icon, 16);
    const danger = info.id === "danger-full-access" || info.id === "auto";
    permChip.classList.toggle("is-warn", danger);
    permChip.setAttribute("aria-label", "访问模式:" + info.label);
    permChip.title = "访问模式:" + info.label + " · " + info.desc;
  }

  Takeovers.mount({
    host: $("#takeover"),
    composer: $("#composerStack"),
    api: {
      toast,
      haptic,
      closeSheet,
      setNeed() {
        /* 审批 / 提问是"接管输入栏"的,本来就在眼前,不占顶栏。
           顶栏只剩连接状态点(renderStatusDot);"后台在跑什么"在 chip 行与任务面板。 */
        renderStatusDot();
        renderLiveChips();
      },
      onPermission: paintPerm,
      appendNode(html) {
        const box = document.createElement("div");
        box.innerHTML = html;
        if (box.firstElementChild) msgScroll.appendChild(box.firstElementChild);
        msgScroll.scrollTo({ top: msgScroll.scrollHeight, behavior: "smooth" });
      },
    },
  });
  paintPerm(Takeovers.permissionInfo);
  paintModelChip();
  renderRail();
  paintIcons();
  if (send) send.innerHTML = SEND_SVG; // 初始态就是 DSH 的发送几何
  renderJobs();
  renderSubs();
  startJobTick();
  resolveStopping(6000); // 演示:stopping 的那条 6 秒后收到权威帧

  window.PROTO = {
    drawer: D,
    /* 验证脚本用:走"左缘侧滑"这条**真实入口**开抽屉 —— 顶栏的 ☰ 在 2026-10-16 去掉了,
       入口只剩手势,所以断言不能再去点一个按钮。事件形状与 shoot.mjs 里那次拖拽一致。 */
    openDrawerByEdge: () => {
      const edge = $("#edgeOpen");
      if (!edge) return;
      const mk = (t, x, y) =>
        edge.dispatchEvent(
          new PointerEvent(t, {
            pointerId: 7,
            pointerType: "touch",
            isPrimary: true,
            bubbles: true,
            cancelable: true,
            clientX: x,
            clientY: y,
            buttons: t === "pointerup" ? 0 : 1,
          })
        );
      // 带子在最边缘(x∈[0,32]),所以起手点取 4。
      mk("pointerdown", 4, 200);
      mk("pointermove", 140, 200);
      mk("pointermove", 280, 200);
      mk("pointerup", 280, 200);
    },
    /* 同上,走**右缘把手**开右抽屉(往左划)。 */
    openSideByEdge: () => {
      const edge = $("#edgeSide");
      if (!edge) return;
      const mk = (t, x, y) =>
        edge.dispatchEvent(
          new PointerEvent(t, {
            pointerId: 8,
            pointerType: "touch",
            isPrimary: true,
            bubbles: true,
            cancelable: true,
            clientX: x,
            clientY: y,
            buttons: t === "pointerup" ? 0 : 1,
          })
        );
      // 右边同样在最边缘:390 宽的视口里,带子在 x∈[358,390]。
      mk("pointerdown", 386, 200);
      mk("pointermove", 270, 200);
      mk("pointermove", 140, 200);
      mk("pointerup", 140, 200);
    },
    openSheet,
    closeSheet,
    openFile,
    closeFile,
    renderFile,
    openLightbox,
    closeLightbox,
    takeovers: Takeovers,
    perm: (id) => Takeovers.setPermission(id),
    /* 验证脚本用:复位自动化任务的演示目录(删除会改数据,空态分支需要干净起点) */
    resetDemoTasks: () => {
      resetDemoTasks();
      renderTasks();
    },
    setState: (s) => {
      curState = s;
      renderFile();
    },
    setTab: (i) => {
      fileTab = i;
      renderFile();
    },
    get layers() {
      return layers.map((l) => l.kind);
    },
    get curState() {
      return curState;
    },
    get curFile() {
      return curFile;
    },
  };

  /* 首屏就把三件事排上:提问向导 → 审批瀑布 → 计划待审 */
  if (document.querySelector("#takeover")) Takeovers.demo.all();
})();
