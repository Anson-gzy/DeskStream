// 画布单位 = 屏幕点，窗口按真实尺寸画（放不进格子就等比缩小）。每个桌面是一列，按行往下排
const COL_W = 1600, GAP = 320, PAD = 40, ROW_GAP = 200, WIN_GAP = 48;
const TOP = 140, BOTTOM = 40; // 屏幕上留给桌面标签的边距
const IW = COL_W - PAD * 2;
const EASE = 'cubic-bezier(.22,1,.36,1)';
const colX = i => i * (COL_W + GAP);
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const $ = (s, r = document) => r.querySelector(s);

// 在 App 里由 Swift 推真实窗口过来，浏览器里用演示窗口
const bridge = window.webkit?.messageHandlers?.desk;
const APP = !!bridge;
const post = msg => bridge?.postMessage(msg);

let seq = 0;
const nid = p => p + Date.now().toString(36) + ++seq;
const R = (...wins) => ({ id: nid('r'), wins });
const D = (name, ...rows) => ({ id: nid('d'), name, y: 0, h: 0, L: null, rows });
const W = id => ({ id });

let winfo = new Map(); // 窗口 id → { title, icon, body, thumb, x, y, w, h }
let vis = { x: 0, y: 0, w: innerWidth, h: innerHeight }; // 进入一行时铺满的区域
const desks = [];

function loadDemo() {
  for (const [k, v] of Object.entries(DEMO)) winfo.set(k, { title: v.app, icon: v.icon, body: v.body, w: v.w, h: v.h });
  desks.push(
    D('Desk 1', R(W('note'), W('clock'))),
    D('Desk 2', R(W('shortcuts'), W('gestures'))),
    D('Desk 3', R(W('dusk'))),
  );
}

const root = $('#root'), stage = $('#stage'), trackEl = $('#track'), ghost = $('#ghost'), dragCanvas = $('#drag-canvas');
const heads = $('#heads'), cols = $('#cols'), dragLayer = $('#drag-layer');
const menu = $('#menu');
const fl = $('#focus-layer'), fstack = $('.f-stack', fl), fbar = $('.f-bar', fl);

const cam = { s: .3, tx: 0 };
const els = new Map();    // 窗口 id（占位为 'ph'）→ 元素
const colEls = new Map(); // 桌面 id → { col, panel, empty, head, ... }
let drag = null, focus = null, camAnim = null, pending = null;
let ghostDesk = null; // 刚新建的桌面：拉出来的虚影跟着它淡掉

/* ---------------- 布局 ---------------- */

const flatWins = d => d.rows.flatMap(r => r.wins);

// 行是自动分的：桌面上窗口不多（≤2）一排一个，多了一排两个，顺序不变（和 DeskModel.rows 同一规则）
function setWins(d, wins) {
  const per = wins.length > 2 ? 2 : 1, old = d.rows;
  d.rows = [];
  for (let i = 0; i < wins.length; i += per) {
    const r = old[d.rows.length] || R();
    r.wins = wins.slice(i, i + per);
    d.rows.push(r);
  }
}

function winSize(w, slot) {
  const info = winfo.get(w.ph ? w.of : w.id);
  if (!info?.w) return { w: slot, h: slot * vis.h / vis.w };
  const k = Math.min(1, slot / info.w);
  return { w: info.w * k, h: info.h * k };
}

// 一排两个时各占半边、在自己那半居中；落单的那个在整行居中。同一行顶边对齐
function layoutDesk(d) {
  setWins(d, flatWins(d));
  const rects = new Map(), rows = [];
  const per = d.rows[0]?.wins.length > 1 ? 2 : 1, slot = (IW - WIN_GAP * (per - 1)) / per;
  let y = PAD;
  for (const row of d.rows) {
    const n = row.wins.length, x0 = PAD + (IW - n * slot - (n - 1) * WIN_GAP) / 2;
    let h = 0;
    row.wins.forEach((w, i) => {
      const s = winSize(w, slot);
      rects.set(w.id, { x: x0 + i * (slot + WIN_GAP) + (slot - s.w) / 2, y, w: s.w, h: s.h });
      h = Math.max(h, s.h);
    });
    rows.push({ y, h });
    y += h + ROW_GAP;
  }
  d.h = d.rows.length ? y - ROW_GAP + PAD : 640;
  d.L = { rects, rows };
}

// 桌面里窗口占的横向范围（桌面内的坐标），空桌面是整张卡
function winSpan(d) {
  let lo = Infinity, hi = -Infinity;
  for (const r of d.L?.rects.values() ?? []) { lo = Math.min(lo, r.x); hi = Math.max(hi, r.x + r.w); }
  return lo < hi ? [lo, hi] : [0, COL_W];
}

function findWin(id) {
  for (let di = 0; di < desks.length; di++) {
    const d = desks[di];
    for (let ri = 0; ri < d.rows.length; ri++) {
      const row = d.rows[ri], wi = row.wins.findIndex(w => w.id === id);
      if (wi >= 0) return { d, di, row, ri, w: row.wins[wi], wi };
    }
  }
}

const winCount = d => d.rows.reduce((a, r) => a + r.wins.length, 0);
const toCanvas = (px, py) => ({ x: (px - cam.tx) / cam.s, y: (py - TOP) / cam.s });
const deskAtX = cx => clamp(Math.floor((cx + GAP / 2) / (COL_W + GAP)), 0, desks.length - 1);
const activeDesk = () => deskAtX((innerWidth / 2 - cam.tx) / cam.s);
const totalW = () => colX(desks.length - 1) + COL_W;
// 整排桌面放得下时居中不滑；否则从第一个桌面居中滑到最后一个桌面居中，再往外是自己做的回弹（滚轮那段的 stretch）。
const fits = s => totalW() * s <= innerWidth - 160;
const clampTx = (tx, s) => (fits(s) ? (innerWidth - totalW() * s) / 2
  : clamp(tx, innerWidth / 2 - (colX(desks.length - 1) + COL_W / 2) * s, innerWidth / 2 - COL_W / 2 * s));
const clampY = (d, y, s) => clamp(y, Math.min(0, (innerHeight - TOP - BOTTOM) / s - d.h), 0);
const fitScale = () => clamp(Math.min((innerWidth - 160) / totalW(), .6), .06, 1);
// 整个桌面竖着放得下，最宽占屏宽三分之二，两边露出相邻桌面
const homeScale = (d = desks[activeDesk()]) => clamp(Math.min(innerWidth * .42 / COL_W, d?.h ? (innerHeight - TOP - BOTTOM) / d.h : 1) * 1.6, .1, .96);
const deskById = id => desks.find(d => d.id === id);

function clampAll() {
  cam.tx = clampTx(cam.tx, cam.s);
  for (const d of desks) d.y = clampY(d, d.y, cam.s);
}

/* ---------------- 渲染 ---------------- */

function render() {
  const seen = new Set();
  desks.forEach((d, i) => {
    layoutDesk(d);
    const c = colEl(d);
    seen.add(d.id);
    c.panel.style.height = d.h + 'px';
    c.empty.style.display = d.rows.length ? 'none' : '';
    if (c.nm.contentEditable !== 'true') c.nm.textContent = d.name;
    const n = winCount(d);
    c.cnt.textContent = n ? `${n} window${n > 1 ? 's' : ''}` : 'Empty';
    c.del.style.display = n || (APP && desks.length < 2) ? 'none' : '';
    for (const w of flatWins(d)) {
      seen.add(w.id);
      const el = winEl(w);
      if (el.parentNode !== c.col) adopt(el, c.col, d, i);
      place(el, d.L.rects.get(w.id));
      el._desk = d.id;
    }
  });
  for (const [id, c] of colEls) if (!seen.has(id)) { leave(c.wrap); leave(c.lane); colEls.delete(id); }
  for (const [id, el] of els) if (!seen.has(id) && !(drag && drag.id === id)) { removeEl(el); els.delete(id); }
  for (const c of colEls.values()) {
    c.hw = c.head.offsetWidth / 2;
    c.pin.style.setProperty('--hw', c.hw + 'px');
  }
  renderCam();
}

/* 横向是 #stage 的原生滚动，每个桌面竖向是各自 .col-wrap 的原生滚动：触控板的增量由 WebKit 的滚动线程
   按屏幕刷新直接用上，带惯性。两端的回弹关掉了（overscroll-behavior-x: none），由滚轮那段自己做。JS 接管滚轮时每个增量都要先过网页主线程，到得早晚不齐，一半的帧拿不到增量。
   cam.tx 和 d.y 只是滚动位置的镜像：用户在滑时从 DOM 读回来；代码移动相机（动画、缩放、拖动）时 write 为 true，写回 DOM */
let lastS = 0, geoL = null;
function renderCam(write = false) {
  const s = cam.s, W = innerWidth, n = desks.length;
  if (!write && geoL !== null) cam.tx = geoL - stage.scrollLeft;
  // 放得下时不能滑，桌面数一变就直接回到居中
  if (!write && fits(s) && !camAnim) { cam.tx = clampTx(cam.tx, s); write = true; }
  // 画布原点在滚动内容里的位置。动画途中相机可以暂时越过可滑范围，这时在左边或右边临时多留出空白
  const L0 = fits(s) ? (W - totalW() * s) / 2 : W / 2 - COL_W / 2 * s;
  const L = write || geoL === null ? Math.max(L0, cam.tx) : Math.max(L0, geoL);
  const span = fits(s) ? W + L - L0 : L + (colX(n - 1) + COL_W / 2) * s + W / 2;
  trackEl.style.width = Math.max(span, L - cam.tx + W) + 'px';
  if (write || L !== geoL) stage.scrollLeft = L - cam.tx;
  geoL = L;
  cam.tx = L - stage.scrollLeft;
  // 标签在屏幕上离窗口 14px，尺寸随缩放变化，系数量自原版
  // 这几个变量一改，所有窗口标签都要重算样式，平移时缩放没变就别碰
  const scaled = s !== lastS;
  if (scaled) {
    lastS = s;
    const f = clamp(.421 + 1.147 * s, .55, 1);
    root.style.setProperty('--inv', 1 / s);
    root.style.setProperty('--cs', f / s);
    root.style.setProperty('--rise', -14 / s + 'px');
  }
  dragCanvas.style.transform = `translate(${cam.tx}px, ${TOP}px) scale(${s})`;
  if (deskDrag) deskDrag.x = (deskDrag.mx - cam.tx) / s - deskDrag.grab;
  const cs = desks.map(d => colEls.get(d.id)), mid = desks.map((d, i) => L + (shownX(d, i) + COL_W / 2) * s);
  desks.forEach((d, i) => {
    const c = cs[i], x = shownX(d, i);
    c.wrap.style.left = L + (x - GAP / 2) * s + 'px';
    // 标签的 lane 只到邻居标签跟前：贴边的标签被滑过来的邻居顶住，跟着一起推出屏幕。
    // 也不出这个桌面窗口的左右边：窗口滑到只剩一截时，标签停在窗口边上跟着一起出去
    const [lo, hi] = winSpan(d).map(v => L + (x + v) * s);
    const a = Math.max(i ? Math.min(mid[i], mid[i - 1] + cs[i - 1].hw + 8 + c.hw) : 0, Math.min(mid[i], lo + c.hw));
    const b = Math.min(i < n - 1 ? Math.max(mid[i], mid[i + 1] - cs[i + 1].hw - 8 - c.hw) : span, Math.max(mid[i], hi - c.hw));
    Object.assign(c.lane.style, { left: a + 'px', width: b - a + 'px' });
    c.sp.style.width = mid[i] - a + 'px';
    c.sizer.style.height = TOP + d.h * s + BOTTOM + 'px';
    const rescale = c.s !== s;
    if (rescale) {
      c.s = s;
      c.wrap.style.width = (COL_W + GAP) * s + 'px';
      c.col.style.transform = `translateX(${GAP / 2 * s}px) scale(${s})`;
    }
    if (write || rescale) c.wrap.scrollTop = -d.y * s;
  });
  Object.assign(ghost.style, { top: TOP + 'px', width: COL_W * s + 'px', height: 640 * s + 'px', borderRadius: 44 * s + 'px' });
  if (ghostDesk) ghost.style.left = cam.tx + colX(desks.indexOf(ghostDesk)) * s + 'px';
  updateHeads();
}

/* 桌面标签贴在屏幕两边：桌面滑出屏幕时标签停在边上（sticky，由滚动线程跟手），滑回来时再跟着桌面回到正中。
   旁边桌面的标签滑过来碰到贴边的这个，就把它顶出屏幕（lane 的范围在 renderCam 里定） */
function updateHeads() {
  const ai = activeDesk();
  desks.forEach((d, i) => colEls.get(d.id).head.classList.toggle('active', i === ai));
}

stage.addEventListener('scroll', () => {
  if (geoL === null) return;
  cam.tx = geoL - stage.scrollLeft;
  dragCanvas.style.transform = `translate(${cam.tx}px, ${TOP}px) scale(${cam.s})`;
  updateHeads();
}, { passive: true });

function colEl(d) {
  let c = colEls.get(d.id);
  if (c) return c;
  const wrap = document.createElement('div');
  wrap.className = 'col-wrap';
  wrap.dataset.id = d.id;
  wrap.innerHTML = `<div class="col-sizer"></div><div class="col"><div class="col-panel"></div><div class="col-empty"><span>${APP ? 'No windows' : 'Empty desk. Drag a window here.'}</span></div></div>`;
  wrap.addEventListener('scroll', () => { const dd = deskById(wrap.dataset.id); if (dd) dd.y = -wrap.scrollTop / cam.s; }, { passive: true });
  const lane = document.createElement('div');
  lane.className = 'lane';
  // 标签的位置由前面的占位撑出来：sticky 的元素移动时外边距盒不能出它的包含块，用 margin 定位就往回贴不了边
  lane.innerHTML = `<div class="sp"></div><div class="pin"><div class="col-head glass"><span class="nm"${APP ? '' : ' title="Double-click to rename"'}></span><span class="cnt"></span>
    <button class="h-del" title="Remove desk"><svg width="10" height="10" viewBox="0 0 13 13" aria-hidden="true"><path d="M3.7 3.7l5.6 5.6M9.3 3.7l-5.6 5.6" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/></svg></button></div></div>`;
  const head = $('.col-head', lane);
  head.dataset.id = d.id;
  $('#cols').append(wrap);
  $('#heads').append(lane);
  const col = $('.col', wrap);
  c = { wrap, col, lane, head, pin: $('.pin', lane), sp: $('.sp', lane), sizer: $('.col-sizer', wrap), panel: $('.col-panel', col), empty: $('.col-empty', col),
    nm: $('.nm', head), cnt: $('.cnt', head), del: $('.h-del', head), hw: 0 };
  colEls.set(d.id, c);
  return c;
}

const esc = s => String(s).replace(/[&<>"]/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[ch]);
const iconOf = info => (SVG_ICONS[info.icon] ? appIconHTML(info.icon) : iconHTML(info.icon));
const bodyOf = info => (info.body ? info.body() : `<div class="embed-box"><img class="embed-snap" alt="" draggable="false" decoding="async"${info.thumb ? ` src="${info.thumb}"` : ''}></div>`);

function winEl(w) {
  let el = els.get(w.id);
  if (el) return el;
  el = document.createElement('div');
  if (w.ph) el.className = 'slot';
  else {
    const info = winfo.get(w.id);
    el.className = 'win enter';
    el.dataset.id = w.id;
    el.innerHTML = `<div class="chip glass"><div class="chip-slot"><div class="chip-icons"><span class="chip-icon">${iconOf(info)}</span></div><div class="lights">${lightsHTML()}</div></div><span class="chip-title">${esc(info.title)}</span></div>
      <div class="win-body">${bodyOf(info)}</div><div class="win-shield"></div><div class="rim rim-hover"></div><div class="rim rim-select"></div>`;
    tickLive(el);
    el.addEventListener('animationend', () => el.classList.remove('enter'), { once: true });
  }
  els.set(w.id, el);
  return el;
}

function place(el, rc) {
  el._x = rc.x; el._y = rc.y;
  el.style.transform = `translate(${rc.x}px, ${rc.y}px)`;
  el.style.width = rc.w + 'px';
  el.style.height = rc.h + 'px';
}

// 换列（或从拖拽层落下）时，先把元素摆回它在屏幕上的原位置，再过渡到新位置
function adopt(el, col, d, i) {
  let cx, cy;
  if (el.parentNode === dragLayer) { cx = el._cx; cy = el._cy; }
  else if (el.parentNode) {
    const j = desks.findIndex(x => x.id === el._desk);
    if (j >= 0) { cx = colX(j) + el._x; cy = desks[j].y + el._y; }
  }
  col.append(el);
  if (cx === undefined) return;
  el.style.transition = 'none';
  el.style.transform = `translate(${cx - colX(i)}px, ${cy - d.y}px)`;
  el.offsetWidth;
  el.style.transition = '';
}

function leave(el) {
  el.classList.add('leaving');
  setTimeout(() => el.remove(), 300);
}

function removeEl(el) {
  if (el.classList.contains('slot')) return el.remove();
  el.classList.add('leaving');
  setTimeout(() => el.remove(), 260);
}

/* ---------------- 相机 ---------------- */

// 相机按画布上的中心点插值；跨得越远中途拉得越远，走一条弧线而不是直线平移
// t0 可以给成上一帧的时间：接着手势动的时候，第一帧就要按过去的这一帧走一步，不然原地停一帧
function animateCam(to, { dur = 620, ease = easeOutSpring, arc = true, t0 = performance.now() } = {}) {
  stopCam();
  const from = { s: cam.s, tx: cam.tx, ys: desks.map(d => d.y) };
  const cx0 = (innerWidth / 2 - from.tx) / from.s, cx1 = (innerWidth / 2 - to.tx) / to.s;
  const dip = arc ? clamp(Math.abs(cx1 - cx0) * Math.min(from.s, to.s) / innerWidth * .18, 0, .22) : 0;
  const step = now => {
    const k = clamp((now - t0) / dur, 0, 1), e = ease(k);
    cam.s = from.s * Math.pow(to.s / from.s, Math.min(e, 1)) * (1 - dip * Math.sin(Math.PI * Math.min(k * 1.15, 1)));
    cam.tx = innerWidth / 2 - (cx0 + (cx1 - cx0) * e) * cam.s;
    if (to.ys) desks.forEach((d, i) => { if (to.ys[i] != null) d.y = from.ys[i] + (to.ys[i] - from.ys[i]) * e; });
    renderCam(true);
    camAnim = k < 1 ? requestAnimationFrame(step) : null;
  };
  camAnim = requestAnimationFrame(step);
}

function stopCam() {
  if (camAnim) cancelAnimationFrame(camAnim);
  camAnim = null;
}

function zoomAt(px, py, f) {
  const s2 = clamp(cam.s * f, .06, 1);
  if (s2 === cam.s) return;
  const c = toCanvas(px, py), d = desks[deskAtX(c.x)], ly = c.y - d.y;
  cam.tx = px - c.x * s2;
  cam.s = s2;
  d.y = (py - TOP) / s2 - ly;
  clampAll();
  renderCam(true);
}

function fitAll() {
  const s = fitScale();
  animateCam({ s, tx: clampTx((innerWidth - totalW() * s) / 2, s), ys: desks.map(() => 0) });
}

function centerDesk(i, s = cam.s, ys) {
  animateCam({ s, tx: clampTx(innerWidth / 2 - (colX(i) + COL_W / 2) * s, s), ys });
}

/* ---------------- 模型操作 ---------------- */

// App 里桌面布局归 Swift 管，页面上的每次改动都整份发过去
function sync() {
  post({
    type: 'layout',
    desks: desks.map(d => ({
      id: d.id, name: d.name,
      rows: d.rows.map(r => ({ wins: r.wins.map(w => Number(w.id)), ratios: r.wins.map(() => 1 / r.wins.length) })),
    })),
  });
}

function removeFromModel(id) {
  const loc = findWin(id);
  loc.row.wins.splice(loc.wi, 1);
  if (!loc.row.wins.length) loc.d.rows.splice(loc.ri, 1);
  return loc;
}

const appendTo = (d, w) => setWins(d, [...flatWins(d), w]);

function closeWin(id) {
  if (APP) return post({ type: 'close', win: Number(id) });
  removeFromModel(id);
  render();
}

function minimizeWin(id) {
  if (APP) return post({ type: 'minimize', win: Number(id) });
  removeFromModel(id);
  render();
}

function moveToDesk(id, i) {
  const { w } = removeFromModel(id);
  appendTo(desks[i], w);
  render();
  sync();
  centerDesk(i, cam.s, desks.map(x => (x === desks[i] ? clampY(x, -Infinity, cam.s) : x.y)));
}

// 桌面增删后其余桌面从原来的位置滑过去，新桌面淡入，删掉的淡出；相机留在原地，超出两端才滑回来
function reflow(change, enter = { opacity: [0, 1], scale: [.9, 1] }) {
  const prevX = new Map(desks.map((d, i) => [d.id, shownX(d, i)])), tx0 = cam.tx, t0 = performance.now();
  change();
  desks.forEach((d, i) => { if (prevX.has(d.id) && prevX.get(d.id) !== colX(i)) slides.set(d.id, { from: prevX.get(d.id), t0 }); });
  render();
  for (const d of desks) {
    if (prevX.has(d.id)) continue;
    const c = colEls.get(d.id);
    for (const el of [c.wrap, c.head]) el.animate(enter, { duration: 420, easing: EASE });
  }
  if (slides.size) runSlides();
  clampAll();
  const tx1 = cam.tx;
  cam.tx = tx0;
  renderCam(true);
  if (tx1 !== tx0) animateCam({ s: cam.s, tx: tx1 });
}

/* App 里新建、删除的是真的 macOS 桌面，要经过调度中心，Swift 那边要一秒左右。
   先在画布上把桌面加上或拿掉，Swift 推来的布局再接替：新桌面的真 id 接管占位桌面，删掉的那个不再画回来 */
let adding = null, removing = null;

// 调度中心在画布底下增删桌面也是一段很重的系统动画，和画布的动画叠在一起两边都掉帧，所以等画布基本停稳再发
// o 是划出新桌面时整排被拉出来的那一截，v 是它当时往左走的速度（px/ms），t0 是画出这一截的那一帧：相机接管这一截，画面原地不动，
// 再接着这个速度用弹簧把新桌面送到正中，过冲一点再回来停住。拉出来的虚影和新桌面叠在一起交叉淡入淡出
function addDesk(o = 0, v = 0, t0 = performance.now()) {
  if (adding) return;
  const d = D(APP ? `Desktop ${desks.filter(x => /^Desktop \d+$/.test(x.name)).length + 1}` : `Desk ${desks.length + 1}`);
  reflow(() => desks.push(d), { opacity: [0, 1] });
  cam.tx -= o;
  ghostDesk = d;
  renderCam(true);
  ghost.animate({ opacity: [getComputedStyle(ghost).opacity, 0] }, { duration: 420, easing: EASE }).onfinish = () => { if (ghostDesk === d) ghostDesk = null; };
  ghost.style.opacity = 0;
  const s = homeScale(d), tx = clampTx(innerWidth / 2 - (colX(desks.indexOf(d)) + COL_W / 2) * s, s);
  animateCam({ s, tx }, { dur: 1600, ease: springFrom(v * 1000 / Math.max(1, cam.tx - tx), 1.6), arc: false, t0 });
  if (!APP) return sync();
  adding = d;
  setTimeout(() => post({ type: 'addDesk' }), 1200);
  setTimeout(() => { if (adding === d) adding = null; }, 4800);
}

function deleteDesk(i) {
  const d = desks[i];
  reflow(() => desks.splice(i, 1));
  if (!APP) return sync();
  removing = d.id;
  setTimeout(() => post({ type: 'removeDesk', desk: d.id }), 400);
  setTimeout(() => { if (removing === d.id) removing = null; }, 4400);
}

/* ---------------- 指针：平移 / 拖窗口 ---------------- */

function track(e, move, up) {
  stage.setPointerCapture(e.pointerId);
  const fin = ev => {
    stage.removeEventListener('pointermove', move);
    stage.removeEventListener('pointerup', fin);
    stage.removeEventListener('pointercancel', fin);
    up(ev);
  };
  stage.addEventListener('pointermove', move);
  stage.addEventListener('pointerup', fin);
  stage.addEventListener('pointercancel', fin);
}

stage.addEventListener('pointerdown', e => {
  if (e.button !== 0 || focus) return;
  stopCam();
  const t = e.target;
  if (t.closest('.light, .col-head, #ghost')) return;
  const we = t.closest('.win');
  if (we) return startPress(e, we.dataset.id);
  startPan(e);
});

function startPan(e) {
  const sx = e.clientX, sy = e.clientY;
  let lx = sx, ly = sy;
  const d = desks[deskAtX(toCanvas(lx, ly).x)];
  root.classList.add('panning');
  track(e, ev => {
    cam.tx += ev.clientX - lx;
    d.y += (ev.clientY - ly) / cam.s;
    lx = ev.clientX; ly = ev.clientY;
    clampAll();
    renderCam(true);
  }, ev => {
    root.classList.remove('panning');
    if (Math.hypot(ev.clientX - sx, ev.clientY - sy) < 5) clickDesk(d, ev.clientX, ev.clientY);
  });
}

function startPress(e, id) {
  const sx = e.clientX, sy = e.clientY;
  track(e, ev => {
    if (!drag) {
      if (Math.hypot(ev.clientX - sx, ev.clientY - sy) < 5) return;
      beginDrag(id, sx, sy);
    }
    drag.px = ev.clientX; drag.py = ev.clientY;
    updateDrag();
  }, () => (drag ? endDrag() : enterWin(id)));
}

function beginDrag(id, sx, sy) {
  const loc = findWin(id), el = els.get(id);
  const cx = colX(loc.di) + el._x, cy = loc.d.y + el._y, p = toCanvas(sx, sy);
  drag = { id, w: loc.w, el, gx: p.x - cx, gy: p.y - cy, px: sx, py: sy };
  loc.row.wins[loc.wi] = { id: 'ph', ph: true, of: id };
  dragLayer.append(el);
  el.classList.add('dragging');
  setDragPos(cx, cy);
  root.classList.add('dragging');
  render();
  requestAnimationFrame(edgeScroll);
}

function setDragPos(cx, cy) {
  const el = drag.el;
  el._cx = cx; el._cy = cy;
  el.style.transform = `translate(${cx}px, ${cy}px)`;
}

function updateDrag() {
  const p = toCanvas(drag.px, drag.py);
  setDragPos(p.x - drag.gx, p.y - drag.gy);
  // App 里桌面就是 macOS 的 Space，窗口只能在自己的桌面里换位置
  const i = APP ? desks.indexOf(phDesk()) : deskAtX(p.x);
  desks.forEach((d, j) => colEls.get(d.id).col.classList.toggle('drop', j === i));
  retarget(desks[i], p.x - colX(i), p.y - desks[i].y);
}

const phDesk = () => desks.find(d => flatWins(d).some(w => w.ph));

// 按阅读顺序找插入点：指针在哪一行，就排在那一行里中线在指针左边的窗口后面
function retarget(d, lx, ly) {
  const cur = phDesk(), pr = d.L.rects.get('ph');
  if (cur === d && lx >= pr.x && lx <= pr.x + pr.w && ly >= pr.y && ly <= pr.y + pr.h) return;
  const ri = d.L.rows.findIndex(r => ly < r.y + r.h + ROW_GAP / 2);
  let idx = 0;
  if (ri < 0) idx = Infinity;
  else {
    for (const row of d.rows.slice(0, ri)) idx += row.wins.filter(w => !w.ph).length;
    idx += d.rows[ri].wins.filter(w => { const rc = d.L.rects.get(w.id); return !w.ph && rc.x + rc.w / 2 < lx; }).length;
  }
  const curWins = flatWins(cur), ph = curWins.find(w => w.ph);
  if (cur === d && curWins.indexOf(ph) === Math.min(idx, curWins.length - 1)) return;
  setWins(cur, curWins.filter(w => !w.ph));
  const wins = flatWins(d);
  wins.splice(idx, 0, ph);
  setWins(d, wins);
  render();
}

// 拖到屏幕边缘时自动滚动：左右换桌面，上下翻当前桌面
function edgeScroll() {
  if (!drag) return;
  const E = 80, { px, py } = drag;
  const v = (a, b) => (a < E ? (E - a) / E * 26 : 0) - (b < E ? (E - b) / E * 26 : 0);
  const vx = v(px, innerWidth - px), vy = v(py - TOP + E / 2, innerHeight - py);
  if (vx || vy) {
    cam.tx += vx;
    const d = desks[deskAtX(toCanvas(px, py).x)];
    d.y += vy / cam.s;
    clampAll();
    renderCam(true);
    updateDrag();
  }
  requestAnimationFrame(edgeScroll);
}

function endDrag() {
  const d = phDesk(), { el, w } = drag;
  setWins(d, flatWins(d).map(x => (x.ph ? w : x)));
  drag = null;
  el.classList.remove('dragging');
  root.classList.remove('dragging');
  for (const c of colEls.values()) c.col.classList.remove('drop');
  render();
  sync();
  flushLoad();
}

stage.addEventListener('click', e => {
  const l = e.target.closest('.light');
  if (!l || focus) return;
  const id = l.closest('.win').dataset.id;
  ({ close: closeWin, minimize: minimizeWin, zoom: enterWin })[l.dataset.light](id);
});

stage.addEventListener('dblclick', e => {
  if (focus || e.target.closest('.win, .col-head, #ghost')) return;
  const i = deskAtX(toCanvas(e.clientX, e.clientY).x);
  if (cam.s > fitScale() * 1.1) fitAll();
  else centerDesk(i, homeScale(desks[i]));
});

/* ---------------- 滚轮与捏合 ---------------- */

/* 滚轮监听只能是 passive：页面上有一个不 passive 的滚轮监听，WebKit 就得等网页主线程处理完每个事件才能滚，
   增量到得早晚不齐，一半的帧拿不到增量，惯性也没了。
   两端的回弹自己做：系统的回弹只拉滚动内容，屏幕外的新桌面跟不上，两边各走各的。这里整排桌面连同右边的新桌面是一条，
   一起被拉出来、一起弹回去。手感照 iOS 的橡皮筋（use-gesture 的 rubberband）和 motion 的 inertia 撞到边界换弹簧：
   手指按着时划出头的量一点不漏，画面按 rubber 跟手、越拉越沉，手不动就停在那；手指一松，从当时的位置和速度用欠阻尼弹簧弹回去，
   过冲一点再停；从中间滑过去的惯性撞到头，带着撞上去的速度弹一下。
   手指按着、松开、惯性开始和结束，wheel 事件里没有：App 里由 Swift 在阶段变化时告诉网页（deskStream.wheel），
   浏览器里和鼠标滚轮没有阶段，90ms 没有新事件就当松手。
   已经滑到最右边时再往右划，一点点就把新桌面拉出一截，稍微用点力（最近 220ms 里累计 80pt）就新建桌面。
   拉出头以后锁住原生滚动，直到这次手势连同惯性结束、回弹也停了：不然往回划和剩下的惯性会让原生滚动和这里抢着动，
   锁住期间往回划的部分由这里手动滚 */
const swipe = { t: 0, armed: false, fired: false, bounced: false, h: [], ax: 0, ay: 0 };
const finger = { down: false, momentum: false, timer: 0 };
const edge = { pull: 0, o: 0, v: 0, t: 0, raf: 0, h: [], spring: null };
// 锁住期间手动滚的那段的惯性：原生惯性被锁挡掉了，松手时接着最近的速度自己滑（h 是最近手动滚过的量）
const glide = { raf: 0, h: [] };
const GLIDE_TAU = 450; // ms，和系统滚动的减速差不多
const edgeEls = [cols, heads];
const RUBBER = .55; // iOS UIScrollView 的系数
const rubber = x => { const W = innerWidth, a = Math.abs(x); return Math.sign(x) * a * W * RUBBER / (W + RUBBER * a); };
const unrubber = o => { const W = innerWidth, a = Math.min(Math.abs(o), W - 1); return Math.sign(o) * a * W / (RUBBER * (W - a)); };
// 回弹的弹簧：约半秒一个来回，阻尼比 .5，过冲约 16%
const BOUNCE_W = 13, BOUNCE_Z = .5;
function bounceAt({ x0, v0 }, t) {
  const wd = BOUNCE_W * Math.sqrt(1 - BOUNCE_Z * BOUNCE_Z), a = BOUNCE_Z * BOUNCE_W, B = (v0 + a * x0) / wd;
  const e = Math.exp(-a * t), c = Math.cos(wd * t), s = Math.sin(wd * t), x = x0 * c + B * s;
  return [e * x, e * (wd * (B * c - x0 * s) - a * x)];
}
let unlockT;
const holdLock = () => {
  clearTimeout(unlockT);
  unlockT = setTimeout(() => (camAnim || edge.raf || glide.raf || finger.down || finger.momentum ? holdLock() : stage.classList.remove('locked')), 150);
};
const lock = () => { stage.classList.add('locked'); holdLock(); };
function paintEdge(o) {
  // 挪的是 #track 里面的两层：挪 #track 本身会缩小可滑范围，滚动位置被夹回去，正好把拉出来的抵消掉
  for (const el of edgeEls) el.style.transform = o ? `translateX(${-o}px)` : '';
  if (ghostDesk) return;
  ghost.style.left = cam.tx + colX(desks.length) * cam.s - o + 'px';
  ghost.style.opacity = swipe.armed ? clamp(o / 32, 0, 1) * .5 : 0;
}
function tick(now) {
  const dt = edge.t ? Math.min(50, now - edge.t) : 8;
  edge.t = now;
  let o;
  if (edge.spring) {
    const [x, v] = bounceAt(edge.spring, Math.max(0, now - edge.spring.t0) / 1000);
    o = x;
    if (Math.abs(x) < .3 && Math.abs(v) < 20) { o = 0; edge.spring = null; }
  } else {
    // 滚轮事件和帧不同步，有的帧来两个、有的一个没有，直接用会一顿一顿的：画面再跟一个约 16ms 的低通
    o = edge.o + (rubber(edge.pull) - edge.o) * (1 - Math.exp(-dt / 16));
    if (!edge.pull && Math.abs(o) < .3) o = 0;
  }
  // 速度取最近约 30ms 的平均：滚轮事件和帧不同步，逐帧算忽快忽慢
  edge.h.push([now, o]);
  if (edge.h.length > 4) edge.h.shift();
  edge.v = edge.h.length > 1 ? (o - edge.h[0][1]) / Math.max(1, now - edge.h[0][0]) : 0;
  edge.o = o;
  paintEdge(o);
  edge.raf = o || edge.pull || edge.spring ? requestAnimationFrame(tick) : 0;
  if (!edge.raf) Object.assign(edge, { o: 0, v: 0, t: 0, h: [] });
}
const runEdge = () => { if (!edge.raf) edge.raf = requestAnimationFrame(tick); };
// 手指在锁住的画布上的位移：先照常滚，滚到头的部分拉出来；拉出来的往回收过了头，多的再滚回去
function pushEdge(dx) {
  const max = stage.scrollWidth - stage.clientWidth, s0 = stage.scrollLeft;
  lock();
  if (!edge.pull) {
    const to = clamp(s0 + dx, 0, max);
    stage.scrollLeft = to;
    dx -= to - s0;
  }
  if (dx) {
    const p = edge.pull + dx;
    if (edge.pull && p * edge.pull < 0 && max >= 1) { edge.pull = 0; stage.scrollLeft = clamp(stage.scrollLeft + p, 0, max); }
    else edge.pull = p;
  }
  const now = performance.now();
  glide.h.push([now, stage.scrollLeft - s0]);
  while (now - glide.h[0][0] > 100) glide.h.shift();
  if (!dx) return;
  edge.spring = null;
  runEdge();
}
function springBack(v0) {
  edge.spring = { x0: edge.o, v0, t0: edge.t || performance.now() };
  edge.pull = 0;
  lock();
  runEdge();
}
function glideFrom(v) {
  const s0 = stage.scrollLeft, max = stage.scrollWidth - stage.clientWidth, t0 = performance.now();
  const step = now => {
    const t = now - t0, e = Math.exp(-t / GLIDE_TAU), x = s0 + v * GLIDE_TAU * (1 - e), vt = v * e;
    stage.scrollLeft = clamp(x, 0, max);
    if (x < 0 || x > max) {
      // 滑到头：和惯性撞到头一样带着速度弹一下
      glide.raf = 0;
      edge.spring = { x0: 0, v0: clamp(vt, -4, 4) * RUBBER * 1000, t0: now };
      return runEdge();
    }
    glide.raf = Math.abs(vt) > .02 ? requestAnimationFrame(step) : 0;
  };
  lock();
  swipe.bounced = true; // 系统的惯性事件还会来，撞头由这里弹，别再弹一次
  glide.raf = requestAnimationFrame(step);
}
function newGesture() {
  Object.assign(swipe, { fired: false, bounced: false, h: [], ax: 0, ay: 0, armed: stage.scrollLeft >= stage.scrollWidth - stage.clientWidth - 2 });
}
function touch() {
  clearTimeout(finger.timer);
  Object.assign(finger, { down: true, momentum: false });
  newGesture();
  cancelAnimationFrame(glide.raf);
  Object.assign(glide, { raf: 0, h: [] });
  // 回弹到一半被手指按住：从当时的位置接着拉。弹簧过冲到另一边时那边没有头可拉，放掉它，不然往回划会被当成往那边拉、滑不动
  if (edge.spring) {
    const s = stage.scrollLeft, max = stage.scrollWidth - stage.clientWidth;
    edge.pull = (edge.o > 0 ? s >= max - 1 : s <= 1) ? unrubber(edge.o) : 0;
    edge.spring = null;
  }
}
function release() {
  finger.down = false;
  if (edge.pull) return springBack(edge.v * 1000);
  const now = performance.now(), h = glide.h.filter(([t]) => now - t < 100);
  glide.h = [];
  if (stage.classList.contains('locked') && h.length > 1) glideFrom(h.reduce((a, [, d]) => a + d, 0) / 100);
}
function fire() {
  swipe.fired = true;
  lock();
  const { o, v, t } = edge;
  cancelAnimationFrame(edge.raf);
  Object.assign(edge, { pull: 0, o: 0, v: 0, t: 0, raf: 0, h: [], spring: null });
  for (const el of edgeEls) el.style.transform = '';
  addDesk(Math.max(0, o), Math.max(0, v), t || performance.now());
}
stage.addEventListener('wheel', e => {
  if (focus) return;
  const now = performance.now(), dx = e.deltaX, gap = now - swipe.t;
  swipe.t = now;
  // 没有手势阶段（浏览器里，或者鼠标滚轮）：隔了 120ms 算新的一下，停 90ms 算松手
  if (!finger.down && !finger.momentum) {
    if (gap > 120) newGesture();
    clearTimeout(finger.timer);
    finger.timer = setTimeout(release, 90);
  }
  const live = finger.down || !finger.momentum;
  if (live && glide.raf) { cancelAnimationFrame(glide.raf); glide.raf = 0; }
  if (stage.classList.contains('locked')) holdLock();
  // 划出新桌面之后，这次手势剩下的事件（含惯性）不能打断滑向新桌面的动画
  if (swipe.fired) return;
  stopCam();
  if (deskDrag || drag) return;
  // 在桌面里上下翻时手指总带一点横向，滚轮事件照样给 deltaX：这次手势竖向为主就不拉边、不弹、不新建，
  // 不然停在最后一个桌面上下翻，横向的那点累计到 80 就新建了桌面
  swipe.ax += Math.abs(dx);
  swipe.ay += Math.abs(e.deltaY);
  if (swipe.ay > swipe.ax) return;
  const max = stage.scrollWidth - stage.clientWidth;
  const atEnd = (dx > 0 && stage.scrollLeft >= max - 1) || (dx < 0 && stage.scrollLeft <= 1);
  if (!live) {
    // 惯性撞到头：带着撞上去的速度弹一下，这次惯性剩下的事件不再管
    if (atEnd && !swipe.bounced && !edge.raf) {
      swipe.bounced = true;
      springBack(clamp(dx / clamp(gap, 8, 20), -4, 4) * RUBBER * 1000);
    }
    return;
  }
  if (edge.pull || atEnd || stage.classList.contains('locked')) pushEdge(dx);
  if (!swipe.armed || adding) return;
  swipe.h.push([now, dx]);
  while (now - swipe.h[0][0] > 220) swipe.h.shift();
  if (swipe.h.reduce((a, [, d]) => a + d, 0) > 80) fire();
}, { passive: true });

// Safari / WKWebView 的触控板捏合走 gesture 事件
let g0 = 1;
document.addEventListener('gesturestart', e => { e.preventDefault(); g0 = cam.s; });
document.addEventListener('gesturechange', e => {
  e.preventDefault();
  if (focus) { if (!APP && e.scale < .8) exitFocus(); return; }
  zoomAt(e.clientX, e.clientY, g0 * e.scale / cam.s);
});

/* ---------------- 进入窗口：飞到它在屏幕上本来的位置和大小 ---------------- */

const setBox = (el, r) => Object.assign(el.style, { left: r.x + 'px', top: r.y + 'px', width: r.w + 'px', height: r.h + 'px' });

// 初速度为零的阻尼弹簧：起步柔和，中段过冲约 2.5% 再回来（相机用）
const easeOutSpring = t => (t >= 1 ? 1 : 1 - Math.exp(-7 * t) * (Math.cos(6 * t) + 7 / 6 * Math.sin(6 * t)));
// 带初速度的欠阻尼弹簧：v 是初速度（全程算 1，每秒），T 是动画总秒数；约 4% 的过冲，1.6 秒时余下的晃动不到 1px
const springFrom = (v, T, w = 6, z = .72) => {
  const wd = w * Math.sqrt(1 - z * z), b = (z * w - v) / wd;
  return k => (k >= 1 ? 1 : 1 - Math.exp(-z * w * k * T) * (Math.cos(wd * k * T) + b * Math.sin(wd * k * T)));
};
// Mission Control 的窗口飞行：直线，临界阻尼弹簧，不过冲；除以终值让最后一帧正好落地
const springMC = t => 1 - (1 + 7 * t) * Math.exp(-7 * t);
const easeMC = t => springMC(t) / springMC(1);

// 盒子从 a 直线飞到 b，返回相对 b 的 transform 关键帧
function lineFrames(a, b, n = 24) {
  return Array.from({ length: n + 1 }, (_, i) => {
    const e = easeMC(i / n);
    const x = a.x + (b.x - a.x) * e, y = a.y + (b.y - a.y) * e, w = a.w + (b.w - a.w) * e, h = a.h + (b.h - a.h) * e;
    return { offset: i / n, transform: `translate(${x - b.x}px, ${y - b.y}px) scale(${w / b.w}, ${h / b.h})` };
  });
}
const elBox = el => { const r = el.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };

// App 里用窗口的真实位置；演示没有真实窗口，按画布上的尺寸放大到 1:1（放不下就缩），居中
function frameOf(id) {
  const info = winfo.get(id);
  if (APP && info?.w) return { x: info.x, y: info.y, w: info.w, h: info.h };
  const b = elBox(els.get(id)), k = Math.min(1 / cam.s, vis.w * .9 / b.w, vis.h * .9 / b.h);
  const w = b.w * k, h = b.h * k;
  return { x: vis.x + (vis.w - w) / 2, y: vis.y + (vis.h - h) / 2, w, h };
}

function setFocus(loc, id) {
  const f = document.createElement('div');
  f.className = 'fwin';
  f.innerHTML = `<div class="win-body">${bodyOf(winfo.get(id))}</div>`;
  tickLive(f);
  fstack.append(f);
  const box = frameOf(id);
  setBox(f, box);
  els.get(id).style.visibility = 'hidden';
  focus = { d: loc.d, ri: loc.ri, id, f, box };
  root.classList.add('focused');
  return f;
}

function enterWin(id) {
  // App 里让 Swift 把真窗口提上来，这个桌面的窗口一起飞回各自的真实位置，落地后画布才淡出
  if (APP) {
    post({ type: 'go', win: Number(id) });
    return flyDesk(findWin(id).d, id, true, 300);
  }
  const from = elBox(els.get(id)), f = setFocus(findWin(id), id);
  f.animate(lineFrames(from, focus.box), { duration: 480 });
  updateFocusChrome();
  flashChrome();
}

// 像 Mission Control 那样，桌面上的窗口一起在真实位置和画布位置之间飞，lead 压在最上面。
// 飞向真实位置的副本停在终点，等画布淡出、下次打开再清。
// 飞回卡片时副本没有阴影和标签，落地那一下直接换成卡片会闪；弹簧后段几乎不动，
// 所以飞到六成就把卡片在副本底下露出来，阴影和标签淡入，副本飞完再撤
// 飞回真实位置时，副本全部落地才发 landed，Swift 这时才淡出画布：副本还在路上就淡出，会和底下的真窗口错开叠成重影。
// 副本也按真实的前后顺序叠（zOrder，最前的在前），否则窗口重叠处淡出时是两扇不同的窗口叠在一起。
// 缩略图一直在刷新，副本要按真实尺寸重新解码，几扇窗口要上百毫秒：解码完再起飞，
// 边飞边解码时开头几帧画不出来，第一帧就跳过大半程（异步解码则是黑框）
let flights = [], zOrder = [];
const LAND_AT = .6;
function flyDesk(d, lead, toReal, dur) {
  clearFlights();
  renderCam();
  const z = id => { const i = zOrder.indexOf(id); return i < 0 ? zOrder.length : i; };
  const ids = flatWins(d).map(w => w.id).filter(id => id !== lead).sort((a, b) => z(b) - z(a));
  if (lead != null) ids.push(lead);
  const decoded = [];
  for (const id of ids) {
    const el = els.get(id), card = elBox(el), real = frameOf(id);
    const f = document.createElement('div');
    f.className = 'fwin';
    f.innerHTML = `<div class="win-body">${bodyOf(winfo.get(id))}</div>`;
    f.style.visibility = 'hidden';
    fstack.append(f);
    setBox(f, toReal ? real : card);
    // 落地时 scale 为 1，圆角要和卡片在屏幕上的一样
    if (!toReal) f.style.borderRadius = 16 * cam.s + 'px';
    // 飞入时窗口刚在真实位置上，卡片先藏起来；飞出时卡片留到起飞那一帧
    if (!toReal) el.style.visibility = 'hidden';
    const img = $('img', f);
    if (img) decoded.push(img.decode().catch(() => {}));
    flights.push({ f, el, from: toReal ? card : real, to: toReal ? real : card });
  }
  root.classList.toggle('focused', toReal);
  const mine = flights;
  Promise.race([Promise.all(decoded), new Promise(r => setTimeout(r, 200))]).then(() => {
    if (flights === mine) launch(mine, toReal, dur);
  });
}

// 几张大图第一次上屏要几百毫秒，期间动画时钟照走，第一帧就到了终点：
// 副本先在起点露出来，等这一帧真画出来（两次 rAF）再开始计时
function launch(list, toReal, dur) {
  for (const { f, el, from, to } of list) {
    f.style.transform = lineFrames(from, to, 1)[0].transform;
    f.style.visibility = '';
    el.style.visibility = 'hidden';
  }
  requestAnimationFrame(() => requestAnimationFrame(() => { if (flights === list) fly(list, toReal, dur); }));
}

function fly(list, toReal, dur) {
  const anims = list.map(flight => {
    const { f, el, from, to } = flight;
    const anim = f.animate(lineFrames(from, to), { duration: dur, fill: toReal ? 'forwards' : 'none' });
    if (!toReal) {
      flight.land = setTimeout(() => land(el, dur * (1 - LAND_AT)), dur * LAND_AT);
      anim.onfinish = () => f.remove();
    }
    return anim.finished;
  });
  if (toReal) Promise.all(anims).then(() => post({ type: 'landed' }), () => {});
}

function land(el, dur) {
  el.style.visibility = '';
  const opts = { duration: dur, easing: 'ease-out' };
  el.animate({ boxShadow: ['none', getComputedStyle(el).boxShadow] }, opts);
  $('.chip', el)?.animate({ opacity: [0, 1] }, opts);
}

function clearFlights() {
  for (const { f, el, land } of flights) { clearTimeout(land); f.remove(); el.style.visibility = ''; }
  flights = [];
  root.classList.remove('focused');
}

// App 里点空桌面就切过去：桌面框直线放大到全屏，同时 Swift 切 Space
function clickDesk(d, x, y) {
  if (!APP || d.rows.length) return;
  const r = elBox(colEls.get(d.id).empty);
  if (x < r.x || x > r.x + r.w || y < r.y || y > r.y + r.h) return;
  post({ type: 'goDesk', desk: d.id });
  clearFlights();
  const f = document.createElement('div'), full = { x: 0, y: 0, w: innerWidth, h: innerHeight };
  f.className = 'fdesk';
  fstack.append(f);
  setBox(f, full);
  f.animate(lineFrames(r, full), { duration: 300, fill: 'forwards' });
  flights.push({ f, el: f });
  root.classList.add('focused');
}

function clearFocus() {
  if (!focus) return;
  const el = els.get(focus.id);
  if (el) el.style.visibility = '';
  focus.f.remove();
  focus = null;
  root.classList.remove('focused');
}

function exitFocus() {
  if (!focus) return;
  const { id, f, box } = focus;
  focus = null;
  root.classList.remove('focused');
  setChrome(false);
  const el = els.get(id);
  if (!el) return f.remove();
  revealWin(id);
  f.animate(lineFrames(box, elBox(el)), { duration: 480, fill: 'forwards' }).onfinish = () => {
    f.remove();
    el.style.visibility = '';
  };
}

// 退出前把相机挪到能看见这个窗口所在行的地方，全屏层挡着，所以直接跳
function revealWin(id) {
  const loc = findWin(id), { d, di } = loc, rr = d.L.rows[loc.ri];
  const sx = cam.tx + colX(di) * cam.s;
  if (sx < 20 || sx + COL_W * cam.s > innerWidth - 20) cam.tx = innerWidth / 2 - (colX(di) + COL_W / 2) * cam.s;
  const sy = TOP + (d.y + rr.y) * cam.s;
  if (sy < TOP || sy + rr.h * cam.s > innerHeight - BOTTOM) d.y = ((innerHeight - TOP - BOTTOM) / cam.s - rr.h) / 2 - rr.y;
  stopCam();
  clampAll();
  renderCam(true);
}

// 换行上下滑，换桌面左右滑，落到那一行的第一个窗口（只有浏览器演示用；App 里由热键直接切真实窗口）
function focusGo(d, ri) {
  const di = desks.indexOf(d), odi = desks.indexOf(focus.d);
  const dx = di === odi ? 0 : Math.sign(di - odi), dy = di === odi ? Math.sign(ri - focus.ri) : 0;
  const ox = dx * (innerWidth + 32), oy = dy * (innerHeight + 32);
  const old = focus;
  els.get(old.id).style.visibility = '';
  old.f.animate([{ transform: 'none' }, { transform: `translate(${-ox}px, ${-oy}px)` }], { duration: 560, easing: EASE, fill: 'forwards' }).onfinish = () => old.f.remove();
  const f = setFocus({ d, ri }, d.rows[ri].wins[0].id);
  f.animate([{ transform: `translate(${ox}px, ${oy}px)` }, { transform: 'none' }], { duration: 560, easing: EASE });
  updateFocusChrome();
  flashChrome();
}

function focusStep(k) {
  const ri = focus.ri + k;
  if (ri >= 0 && ri < focus.d.rows.length) focusGo(focus.d, ri);
}

function focusDesk(k) {
  const di = desks.indexOf(focus.d);
  for (let i = di + k; i >= 0 && i < desks.length; i += k) {
    const d = desks[i];
    if (d.rows.length) return focusGo(d, Math.min(focus.ri, d.rows.length - 1));
  }
}

function updateFocusChrome() {
  const di = desks.indexOf(focus.d);
  $('.f-desk', fbar).textContent = `${focus.d.name} · ${focus.ri + 1}/${focus.d.rows.length}`;
  const dis = (f, v) => { $(`[data-f="${f}"]`, fbar).disabled = v; };
  dis('up', focus.ri === 0);
  dis('down', focus.ri === focus.d.rows.length - 1);
  dis('desk-prev', !desks.slice(0, di).some(d => d.rows.length));
  dis('desk-next', !desks.slice(di + 1).some(d => d.rows.length));
}

// 顶部工具条：刚进入或切换时露一下，之后鼠标靠近顶边才出来
const chrome = { flash: false, top: false, timer: 0 };
function setChrome(on) {
  fbar.classList.toggle('show', on && (chrome.flash || chrome.top));
}
function flashChrome() {
  chrome.flash = true;
  setChrome(true);
  clearTimeout(chrome.timer);
  chrome.timer = setTimeout(() => { chrome.flash = false; if (focus) setChrome(true); }, 1800);
}

fl.addEventListener('pointermove', e => {
  if (!focus || APP) return;
  chrome.top = e.clientY < 64 || fbar.contains(e.target);
  setChrome(true);
});

fl.addEventListener('click', e => {
  const b = focus && e.target.closest('[data-f]');
  if (!b) return;
  ({
    overview: exitFocus,
    'desk-prev': () => focusDesk(-1),
    'desk-next': () => focusDesk(1),
    up: () => focusStep(-1),
    down: () => focusStep(1),
  })[b.dataset.f]();
});

// 全屏里滚轮翻行：竖滚上下一行，横滑换桌面，捏合（缩小）回到画布。
// 只在演示里挂：App 里不进全屏，这个不 passive 的监听会让画布的滑动也等主线程
const wh = { t: 0, lock: false, x: 0, y: 0, z: 0 };
if (!APP) fl.addEventListener('wheel', e => {
  if (!focus) return;
  e.preventDefault();
  const now = performance.now(), gap = now - wh.t;
  wh.t = now;
  if (wh.lock) { if (gap < 220) return; wh.lock = false; }
  if (gap > 300) wh.x = wh.y = wh.z = 0;
  if (e.ctrlKey || e.metaKey) {
    wh.z += e.deltaY;
    if (wh.z > 40) { wh.lock = true; exitFocus(); }
    return;
  }
  const k = e.deltaMode === 1 ? 16 : 1;
  if (e.shiftKey && !e.deltaX) wh.x += e.deltaY * k;
  else { wh.x += e.deltaX * k; wh.y += e.deltaY * k; }
  if (Math.abs(wh.x) >= 100 && Math.abs(wh.x) > Math.abs(wh.y)) { wh.lock = true; focusDesk(Math.sign(wh.x)); wh.x = wh.y = 0; }
  else if (Math.abs(wh.y) >= 100) { wh.lock = true; focusStep(Math.sign(wh.y)); wh.x = wh.y = 0; }
}, { passive: false });

/* ---------------- 右键菜单 ---------------- */

function showMenu(x, y, items) {
  menu.innerHTML = items.map((it, i) => it.sep ? '<div class="ms"></div>'
    : it.head ? `<div class="mh">${esc(it.head)}</div>`
    : `<button class="mi ${it.danger ? 'danger' : ''}" data-i="${i}" ${it.disabled ? 'disabled' : ''}>${esc(it.label)}</button>`).join('');
  menu._items = items;
  menu.classList.add('show');
  const r = menu.getBoundingClientRect();
  menu.style.left = Math.min(x, innerWidth - r.width - 8) + 'px';
  menu.style.top = Math.min(y, innerHeight - r.height - 8) + 'px';
}
const closeMenu = () => menu.classList.remove('show');

menu.addEventListener('click', e => {
  const b = e.target.closest('.mi');
  if (!b) return;
  closeMenu();
  menu._items[b.dataset.i].act();
});
document.addEventListener('pointerdown', e => { if (!menu.contains(e.target)) closeMenu(); }, true);

stage.addEventListener('contextmenu', e => {
  e.preventDefault();
  if (focus || drag) return;
  const we = e.target.closest('.win');
  if (!we) return showMenu(e.clientX, e.clientY, [...(APP ? [] : [{ label: 'New desk', act: addDesk }]), { label: 'Fit all desks', act: fitAll }]);
  const id = we.dataset.id, loc = findWin(id);
  showMenu(e.clientX, e.clientY, [
    { label: 'Go in', act: () => enterWin(id) },
    ...(APP ? [] : [
      { sep: 1 }, { head: 'Move to desk' },
      ...desks.map(d => ({ label: d.name, disabled: d === loc.d, act: () => moveToDesk(id, desks.indexOf(d)) })),
      { label: 'New desk', act: () => { desks.push(D(`Desk ${desks.length + 1}`)); moveToDesk(id, desks.length - 1); } },
    ]),
    { sep: 1 },
    { label: 'Minimize', act: () => minimizeWin(id) },
    { label: 'Close window', danger: 1, act: () => closeWin(id) },
  ]);
});

/* ---------------- 桌面标签 ---------------- */

heads.addEventListener('click', e => {
  const h = e.target.closest('.col-head');
  if (!h || deskDragEnded) return;
  const i = desks.findIndex(d => d.id === h.dataset.id);
  if (e.target.closest('.h-del')) return deleteDesk(i);
  if (e.target.closest('.nm[contenteditable="true"]')) return;
  // 点标签在总览和这个桌面之间切换
  if (cam.s <= fitScale() * 1.1) centerDesk(i, homeScale(desks[i]));
  else fitAll();
});

/* 拖标签给桌面排序：画面以鼠标为锚点缩到总览，手下的桌面跟着鼠标走，松手后回到原来的大小 */
let deskDrag = null, deskDragEnded = false;

heads.addEventListener('pointerdown', e => {
  const h = e.target.closest('.col-head');
  if (!h || e.button !== 0 || focus || e.target.closest('.h-del, .nm[contenteditable="true"]')) return;
  const sx = e.clientX, sy = e.clientY;
  const move = ev => {
    if (!deskDrag) {
      if (Math.hypot(ev.clientX - sx, ev.clientY - sy) < 5) return;
      beginDeskDrag(h.dataset.id, sx);
    }
    moveDeskDrag(ev.clientX);
  };
  const up = () => {
    removeEventListener('pointermove', move);
    removeEventListener('pointerup', up);
    if (deskDrag) endDeskDrag();
  };
  addEventListener('pointermove', move);
  addEventListener('pointerup', up);
});

// 让位和松手归位由 JS 逐帧推，标签和桌面用同一个 x；CSS 过渡只动得了桌面，标签会直接跳过去
const slides = new Map(), SLIDE_MS = 320;
let slideRaf = null;

function shownX(d, i) {
  if (deskDrag?.d === d) return deskDrag.x;
  const sl = slides.get(d.id);
  if (!sl) return colX(i);
  return sl.from + (colX(i) - sl.from) * easeMC(Math.min(1, (performance.now() - sl.t0) / SLIDE_MS));
}

function runSlides() {
  if (slideRaf) return;
  root.classList.add('sliding');
  const tick = () => {
    const now = performance.now();
    for (const [id, sl] of slides) {
      if (now - sl.t0 < SLIDE_MS) continue;
      slides.delete(id);
      const c = colEls.get(id);
      c?.wrap.classList.remove('lifted');
      c?.head.classList.remove('lifted');
    }
    renderCam();
    if (slides.size) slideRaf = requestAnimationFrame(tick);
    else { slideRaf = null; root.classList.remove('sliding'); }
  };
  slideRaf = requestAnimationFrame(tick);
}

function beginDeskDrag(id, mx) {
  slides.delete(id);
  closeMenu();
  const i = desks.findIndex(d => d.id === id), c = colEls.get(id);
  const ax = (mx - cam.tx) / cam.s;
  deskDrag = { d: desks[i], mx, grab: ax - colX(i), x: colX(i), from: i };
  c.wrap.classList.add('lifted');
  c.head.classList.add('lifted');
  root.classList.add('desk-dragging');
  zoomCam(Math.min(fitScale(), cam.s * .7), mx, ax, 300);
}

function moveDeskDrag(mx) {
  deskDrag.mx = mx;
  renderCam();
  const from = desks.indexOf(deskDrag.d), to = deskAtX(deskDrag.x + COL_W / 2);
  if (to === from) return;
  const cur = new Map(desks.map((d, i) => [d.id, shownX(d, i)])), t0 = performance.now();
  desks.splice(from, 1);
  desks.splice(to, 0, deskDrag.d);
  desks.forEach((d, i) => {
    if (d !== deskDrag.d && cur.get(d.id) !== colX(i)) slides.set(d.id, { from: cur.get(d.id), t0 });
  });
  render();
  runSlides();
}

function endDeskDrag() {
  const { d, from } = deskDrag;
  slides.set(d.id, { from: deskDrag.x, t0: performance.now() });
  deskDrag = null;
  root.classList.remove('desk-dragging');
  // 调度中心按位置给桌面编号，名字先跟着新顺序改，不等 Swift 确认
  if (APP) { let n = 0; for (const x of desks) if (/^Desktop \d+$/.test(x.name)) x.name = `Desktop ${++n}`; }
  render();
  runSlides();
  sync();
  const to = desks.indexOf(d);
  if (to !== from) post({ type: 'moveDesk', desk: d.id, to });
  flushLoad();
  centerDesk(to, homeScale(d));
  // 松手的 pointerup 后面还跟着一个落在标签上的 click
  deskDragEnded = true;
  setTimeout(() => (deskDragEnded = false));
}

// 缩放时画布上 ax 这一点一直停在屏幕的 mx 处
function zoomCam(s1, mx, ax, dur) {
  stopCam();
  const s0 = cam.s, t0 = performance.now();
  const step = now => {
    const k = Math.min(1, (now - t0) / dur);
    cam.s = s0 * Math.pow(s1 / s0, easeMC(k));
    cam.tx = mx - ax * cam.s;
    renderCam(true);
    camAnim = k < 1 ? requestAnimationFrame(step) : null;
  };
  camAnim = requestAnimationFrame(step);
}

heads.addEventListener('dblclick', e => {
  const nm = e.target.closest('.nm');
  if (!nm || APP) return;
  const d = desks.find(x => x.id === nm.closest('.col-head').dataset.id);
  nm.contentEditable = 'true';
  nm.focus();
  getSelection().selectAllChildren(nm);
  const done = () => {
    nm.contentEditable = 'false';
    d.name = nm.textContent.trim() || d.name;
    nm.removeEventListener('keydown', key);
    render();
    sync();
  };
  const key = ev => { if (ev.key === 'Enter') { ev.preventDefault(); nm.blur(); } };
  nm.addEventListener('keydown', key);
  nm.addEventListener('blur', done, { once: true });
});

document.addEventListener('keydown', e => {
  if (e.key !== 'Escape' || e.target.isContentEditable) return;
  closeMenu();
  if (APP) post({ type: 'dismiss' });
  else exitFocus();
});

addEventListener('resize', () => {
  if (!APP) vis = { x: 0, y: 0, w: innerWidth, h: innerHeight };
  render();
  clampAll();
  renderCam(true);
});

/* ---------------- 与 Swift 的桥（docs/bridge.md） ---------------- */

function load(st) {
  if (drag || deskDrag) { pending = st; return; }
  vis = st.screen.visible;
  const count = new Map();
  for (const w of Object.values(st.windows)) count.set(w.app, (count.get(w.app) || 0) + 1);
  winfo = new Map(Object.entries(st.windows).map(([id, w]) => [id, {
    title: count.get(w.app) > 1 && w.title ? w.title : w.app, icon: w.icon, thumb: w.thumb,
    x: w.x, y: w.y, w: w.w, h: w.h,
  }]));
  const ys = new Map(desks.map(d => [d.id, d.y]));
  const shape = () => JSON.stringify(desks.map(d => d.rows.map(r => r.wins.map(w => w.id))));
  if (removing && !st.desks.some(d => d.id === removing)) removing = null;
  const fresh = st.desks.find(d => !ys.has(d.id));
  if (adding && fresh) {
    const c = colEls.get(adding.id);
    colEls.delete(adding.id);
    colEls.set(fresh.id, c);
    c.head.dataset.id = fresh.id;
    adding.id = fresh.id;
    adding = null;
  }
  const first = !desks.length;
  const rebuild = () => {
    const keep = adding;
    desks.length = 0;
    for (const d of st.desks) {
      if (d.id === removing) continue;
      desks.push({ id: d.id, name: d.name, y: ys.get(d.id) ?? 0, h: 0, L: null,
        rows: d.rows.map(r => R(...r.wins.map(id => W(String(id))))) });
    }
    if (keep) desks.push(keep);
  };
  for (const [id, el] of els) {
    const info = winfo.get(id);
    if (!info || el.classList.contains('slot')) continue;
    $('.chip-title', el).textContent = info.title;
    const img = $('.embed-snap', el);
    if (info.thumb && img.getAttribute('src') !== info.thumb) img.src = info.thumb;
  }
  const before = shape();
  if (first) { rebuild(); render(); } else reflow(rebuild);
  // Swift 新加的窗口不按这里的自动分行，分完之后把行发回去，热键换行才对得上
  if (shape() !== before) sync();
}

function flushLoad() {
  if (pending) { const st = pending; pending = null; load(st); }
}

window.deskStream = {
  load,
  thumb(wid, v) {
    const id = String(wid), info = winfo.get(id), url = `desk://thumb/${id}?v=${v}`;
    if (info) info.thumb = url;
    const img = els.get(id)?.querySelector('.embed-snap');
    if (img) img.src = url;
  },
  // 面板刚显示：当前窗口从它在屏幕上的位置缩回画布
  // 停在当前所在的桌面上；上次聚焦的窗口在别的桌面时，从当前桌面最前面的窗口飞
  open(fromWid, order = [], here = null) {
    zOrder = order.map(String);
    clearFocus();
    clearFlights();
    closeMenu();
    const cur = desks.find(d => d.id === here);
    let id = fromWid != null ? String(fromWid) : null;
    if (cur && findWin(id)?.d !== cur) id = zOrder.find(w => findWin(w)?.d === cur) ?? null;
    const d = cur ?? findWin(id)?.d;
    if (!d) return;
    const i = desks.indexOf(d);
    cam.s = homeScale(d);
    cam.tx = clampTx(innerWidth / 2 - (colX(i) + COL_W / 2) * cam.s, cam.s);
    clampAll();
    renderCam(true);
    if (id) flyDesk(d, id, false, 320);
  },
  // 面板淡出时正在飞的窗口要留着，下次 open 再清
  close: closeMenu,
  // 触控板手势的阶段（Overlay.swift）：touch 手指放上，release 松开，momentum 惯性开始，still 惯性结束
  wheel(phase) {
    if (phase === 'touch') return touch();
    if (phase === 'release') {
      release();
      // 松手后要是有惯性，紧跟着会来 momentum；没来就是停稳了才松的手
      finger.momentum = true;
      clearTimeout(finger.timer);
      finger.timer = setTimeout(() => { finger.momentum = false; }, 300);
      return;
    }
    clearTimeout(finger.timer);
    finger.momentum = phase === 'momentum';
  },
  // 先在后台解码好再换，换的那一下不闪
  wallpaper(url) {
    const img = new Image();
    img.src = url;
    img.decode().then(() => root.style.setProperty('--wall', `url("${url}")`), () => {});
  },
};

/* ---------------- 启动 ---------------- */

if (APP) $('#root').classList.add('app');
else loadDemo();
render();
cam.s = homeScale(desks[0]);
cam.tx = innerWidth / 2 - COL_W / 2 * cam.s;
clampAll();
renderCam(true);
tickLive();
requestAnimationFrame(() => requestAnimationFrame(() => root.classList.remove('no-anim')));
post({ type: 'ready' });
