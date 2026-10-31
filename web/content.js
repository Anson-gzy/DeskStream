// 浏览器演示模式的窗口内容与图标：卡片、20px 应用图标、红绿灯

const ICON_BG = { rect: bg => `<rect width="32" height="32" rx="7.2" fill="${bg}"/>` };
const SVG_ICONS = {
  keys: `${ICON_BG.rect('#fcfcfc')}<rect x="6" y="10" width="20" height="13" rx="2.5" fill="none" stroke="#1c1c1f" stroke-width="2"/><path d="M10 14.5h1M15.5 14.5h1M21 14.5h1M11 19h10" stroke="#1c1c1f" stroke-width="2" stroke-linecap="round"/>`,
  gestures: `${ICON_BG.rect('#2a2a2e')}<path d="M16 7v18M7 16h18M16 7l-3 3M16 7l3 3M16 25l-3-3M16 25l3-3M7 16l3-3M7 16l3 3M25 16l-3-3M25 16l-3 3" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,
  clock: `${ICON_BG.rect('#f5f5f5')}<circle cx="16" cy="16" r="9.5" fill="#fff" stroke="#1c1c1f" stroke-width="2"/><path d="M16 10.5V16l4 2.5" fill="none" stroke="#1c1c1f" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,
  note: `${ICON_BG.rect('#f5f5f5')}<path d="M9 11h14M9 16h14M9 21h8" stroke="#1c1c1f" stroke-width="2" stroke-linecap="round"/>`,
  photo: `<defs><linearGradient id="ic-photo" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#c7b3ff"/><stop offset="1" stop-color="#ff946f"/></linearGradient></defs><rect width="32" height="32" rx="7.2" fill="url(#ic-photo)"/><circle cx="21" cy="11" r="3" fill="#fff" fill-opacity=".9"/><path d="M4 26l8-9 6 6 4-4 6 7z" fill="#fff" fill-opacity=".85"/>`,
};
SVG_ICONS.shortcuts = SVG_ICONS.keys;

// 位图图标原版放大到 1/0.8047 再居中裁掉透明边
function iconHTML(src, size = 20) {
  const n = size / 0.8047, o = (size - n) / 2;
  return `<span class="app-icon" style="width:${size}px;height:${size}px"><img src="${src}" alt="" width="${n}" height="${n}" style="left:${o}px;top:${o}px" draggable="false"></span>`;
}

function appIconHTML(app, size = 20) {
  if (SVG_ICONS[app]) return `<svg width="${size}" height="${size}" viewBox="0 0 32 32" aria-hidden="true">${SVG_ICONS[app]}</svg>`;
  return iconHTML(app, size);
}

const LIGHTS = {
  close: { upper: '#f65449', mid: '#f05c56', lower: '#f16862', glow: '#f5837c', edge: 'rgb(140 20 15 / 0.2)', glyph: '#8a0000', icon: '<path d="M3.7 3.7l5.6 5.6M9.3 3.7l-5.6 5.6" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/>' },
  minimize: { upper: '#fbb300', mid: '#fbc000', lower: '#fece32', glow: '#ffd95a', edge: 'rgb(150 95 0 / 0.2)', glyph: '#a83000', icon: '<path d="M3.4 6.5h6.2" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>' },
  zoom: { upper: '#00be00', mid: '#33bf00', lower: '#52c43c', glow: '#6fd95c', edge: 'rgb(0 90 0 / 0.2)', glyph: '#005300', icon: '<g fill="currentColor"><path d="M3.6 3.6h5.2L3.6 8.8z"/><path d="M10.2 5v5.2H5z"/></g>' },
};

const lightsHTML = () => Object.entries(LIGHTS).map(([k, c]) =>
  `<button type="button" class="light" data-light="${k}" aria-label="${k}" tabindex="-1" style="background:radial-gradient(60% 46% at 50% 86%, ${c.glow} 0%, ${c.glow} 30%, transparent 100%), linear-gradient(to bottom, ${c.upper} 0%, ${c.mid} 55%, ${c.lower} 100%);box-shadow:inset 0 0 0 0.5px ${c.edge}, inset 0 0.75px 0 rgb(255 255 255 / 0.4), inset 0 -0.75px 0 rgb(255 255 255 / 0.22)"><svg width="12" height="12" viewBox="0 0 13 13" fill="none" style="color:${c.glyph}" aria-hidden="true">${c.icon}</svg></button>`).join('');

const keysHTML = keys => `<span class="keys">${keys.map(k => `<span class="key">${k}</span>`).join('')}</span>`;
const glyph = d => `<svg viewBox="0 0 48 48" width="48" height="48" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/></svg>`;

const CARDS = {
  shortcuts: () => `<div class="card"><h2>Shortcuts</h2><p>Global, from any app.</p><div class="rows">${[
    ['Open or close the canvas', ['⌃', '⌥', 'Space']],
    ['Row above or below', ['⌃', '⌥', '↑', '↓']],
    ['Desk to the left or right', ['⌃', '⌥', '←', '→']],
    ['Go to a window', ['Click']],
    ['Close the canvas', ['Esc']],
  ].map(([t, k]) => `<div class="row"><span>${t}</span>${keysHTML(k)}</div>`).join('')}</div></div>`,
  gestures: () => `<div class="card"><h2>Gestures</h2><p>Made for the trackpad.</p><div class="grid2">${[
    ['Open', 'Four fingers down, from anywhere.', 'M15 8v12M21 8v12M27 8v12M33 8v12M24 26v14M24 40l-5-5M24 40l5-5'],
    ['Scroll', 'Down a desk, or across to the next.', 'M24 6v36M24 6l-5 5M24 6l5 5M24 42l-5-5M24 42l5-5'],
    ['Go to', 'Click a window, or an empty desk.', 'M12 10l22 9-9 3-3 9z'],
    ['New desk', 'Push past the last desk.', 'M9 9h30v30H9zM24 17v14M17 24h14'],
  ].map(([b, s, d]) => `<div class="cell">${glyph(d)}<b>${b}</b><span>${s}</span></div>`).join('')}</div></div>`,
  clock: () => '<div class="card clock"><div class="time live-time">––:––</div><div class="date live-date"></div></div>',
  note: () => '<div class="card note"><p class="big">Every desk, every window.<br>One canvas.</p><p>Desks run left to right, windows top to bottom. Click one to go there.</p></div>',
  photo: () => '<div class="photo art-dusk" aria-label="Dusk"></div>',
};

// 浏览器里打开时的演示窗口；App 里用真实窗口的缩略图
const DEMO = {
  shortcuts: { app: 'Shortcuts', icon: 'shortcuts', body: CARDS.shortcuts, w: 1040, h: 700 },
  gestures: { app: 'Gestures', icon: 'gestures', body: CARDS.gestures, w: 1040, h: 700 },
  clock: { app: 'Clock', icon: 'clock', body: CARDS.clock, w: 720, h: 480 },
  note: { app: 'Note', icon: 'note', body: CARDS.note, w: 860, h: 640 },
  dusk: { app: 'Dusk', icon: 'photo', body: CARDS.photo, w: 1200, h: 780 },
};

function tickLive(root = document) {
  const now = new Date();
  const t = now.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
  const d = now.toLocaleDateString('en-US', { weekday: 'long', day: 'numeric', month: 'long' });
  root.querySelectorAll('.live-time').forEach(e => { e.textContent = t; });
  root.querySelectorAll('.live-date').forEach(e => { e.textContent = d; });
}
setInterval(tickLive, 1000);
