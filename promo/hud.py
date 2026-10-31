"""Overlay for the cut: the hotkey, a map of the canvas that lives through every shot, one callout card that moves to free ground.
Map state is read from (clip, src_t) so it follows the footage through every speed ramp; pans follow shift.json (measure.py)."""
import glob, json, math, numpy as np, cv2
from PIL import Image, ImageDraw, ImageFont

OW, OH, SS = 1920, 1248, 2                    # supersampled drawing, downscaled per frame
SF = '/System/Library/Fonts/SFNS.ttf'
PF = glob.glob('/System/Library/AssetsV2/*/*/AssetData/PingFang.ttc')[0]

def sf(size, weight):
    f = ImageFont.truetype(SF, size * SS)
    f.set_variation_by_axes([100, min(96, size), 400, weight])
    return f

def pf(size, face):                           # PingFang SC: 3 regular, 7 medium, 11 semibold
    return ImageFont.truetype(PF, size * SS, index=face)

def ease(k): return 0.5 - 0.5 * math.cos(math.pi * min(1, max(0, k)))
def spring(k): return 1 - math.exp(-k * 9) * math.cos(k * 13) if k > 0 else 0

# ── callouts (output seconds) ──────────────────────────────────────────────
NOTES = [
    (0.05, '打开画布', '按快捷键，或者四指下滑'),
    (1.85, '一个桌面一列', '窗口按原比例从上往下排'),
    (3.20, '拖动窗口', '在同一个桌面里换个位置'),
    (5.00, '左右滑动', '桌面连成一条，滑到哪看到哪'),
    (7.50, '新建桌面', '滑到最右边再甩一下'),
    (9.60, '删除桌面', '空桌面的标签上点 ×'),
    (11.93, '看全局', '点标签，退远看整条画布'),
    (13.10, '给桌面排序', '拖动标签，调度中心也跟着变'),
    (15.05, '切换窗口', '滑回去，点哪个窗口就去哪个'),
]
NOTE_END = 17.4
# where the card sits (left edge, centre y): ground the footage leaves empty, reached while the footage is moving anyway
SPOTS = [(0.05, 1030, 900), (0.62, 48, 720), (5.00, 300, 720), (7.50, 1240, 600), (11.93, 900, 840), (15.05, 48, 720)]
NOTE_H = 124
MAP_Y = 1093

# ── the canvas map ─────────────────────────────────────────────────────────
P, CW, CH = 72, 60, 52                        # slot pitch, desk card
VW, VH = 94, 66                               # the screen's share: 1512 pt of screen over a ~1150 pt desk pitch
WIN = {'calc': .55, 'finder': 1.45, 'tips': 1.45, 'clock': 1.3, 'font': 1.3, 'video': 1.8, 'stocks': 1.35, 'dict': 1.25}
DARK = {'calc', 'clock', 'video'}
DESK = {'D1': ['calc', 'finder', 'tips'], 'D2': ['clock', 'font'], 'VH': ['video'], 'D3': ['stocks', 'dict'], 'D4': []}
ORDER = {'n1': 0, 'n2': 1, 'n3': 2, 'n4': 3, 'end': 4}

SHIFT = json.load(open('shift.json'))
def _acc(clip):
    t = np.array([r[0] for r in SHIFT[clip]])
    dx = np.array([r[1] if abs(r[1]) > 0.3 and r[2] > 0.15 else 0 for r in SHIFT[clip]])
    return t, cv2.GaussianBlur(np.cumsum(dx).reshape(-1, 1), (1, 0), 3).ravel()
ACC = {c: _acc(c) for c in ('n2', 'n4')}

def pan(clip, s, a, b, ua, ub):
    """u from ua to ub, shaped like the measured scroll between src a and b"""
    t, acc = ACC[clip]; A, B, v = np.interp([a, b, s], t, acc)
    return ua + (ub - ua) * min(1, max(0, (v - A) / (B - A)))

def prog(c, s, ca, a, b):
    if ORDER[c] != ORDER[ca]: return float(ORDER[c] > ORDER[ca])
    return ease((s - a) / (b - a))

def viewport_u(c, s):
    if c == 'n2':
        if s < 3.5: return pan('n2', s, 1.7, 3.1, 0, 1)
        if s < 6.9: return pan('n2', s, 3.85, 5.3, 1, 3.3)
        if s < 11.0: return 3.3 + 0.7 * ease((s - 6.95) / 0.6)
        return pan('n2', s, 11.12, 11.45, 4, 3)
    if c == 'n3': return 3 if s < 4 else 2
    if c == 'n4': return pan('n4', s, 1.3, 2.3, 2, 0)
    return 0

def win_layout(names):
    """the app's rule: up to two windows one per row, more two per row, at true aspect"""
    if not names: return {}
    per = 1 if len(names) <= 2 else 2
    rows = [names[i:i + per] for i in range(0, len(names), per)]
    pad, gap = 6, 4
    rh = (CH - 2 * pad - gap * (len(rows) - 1)) / len(rows)
    out, y = {}, -CH / 2 + pad
    for row in rows:
        cell = (CW - 2 * pad - gap * (len(row) - 1)) / len(row)
        ws = [min(rh * WIN[n], cell) for n in row]
        x = -(sum(ws) + gap * (len(row) - 1)) / 2
        for n, w in zip(row, ws):
            h = w / WIN[n]; out[n] = (x, y + (rh - h) / 2, w, h); x += w + gap
        y += rh + gap
    return out

def map_state(c, s):
    swap = prog(c, s, 'n1', 6.95, 8.25)
    d4 = prog(c, s, 'n2', 7.1, 7.5) * (1 - prog(c, s, 'n2', 11.12, 11.45))
    reord = prog(c, s, 'n3', 4.4, 5.7)
    ov = prog(c, s, 'n3', 1.95, 2.55) - prog(c, s, 'n3', 5.8, 6.2)
    def centers(order):
        x, out = 0, {}
        for k in order:
            p = d4 if k == 'D4' else 1; out[k] = x + P * p / 2; x += P * p
        return out, x
    pre, tot = centers(['D1', 'D2', 'VH', 'D3', 'D4'])
    post, _ = centers(['D1', 'D2', 'D3', 'VH', 'D4'])
    cx = {k: pre[k] + (post[k] - pre[k]) * reord for k in pre}
    order = ['D1', 'D2', 'VH', 'D3', 'D4'] if reord < .5 else ['D1', 'D2', 'D3', 'VH', 'D4']
    ghost = tot + P / 2
    off = OW / 2 - (tot + P) / 2
    xs = [cx[k] for k in order] + [ghost]
    vx = np.interp(viewport_u(c, s), range(len(xs)), xs)
    lo = min(cx[k] for k in cx if k != 'D4' or d4 > .5) - P / 2 - 4
    hi = max(cx[k] for k in cx if k != 'D4' or d4 > .5) + P / 2 + 4
    vw = VW + (hi - lo - VW) * ov; vx = vx + ((lo + hi) / 2 - vx) * ov
    a, b = win_layout(['calc', 'finder', 'tips']), win_layout(['calc', 'tips', 'finder'])
    d1 = {n: tuple(p + (q - p) * swap for p, q in zip(a[n], b[n])) for n in a}
    return dict(cx={k: v + off for k, v in cx.items()}, d4=d4, ghost=ghost + off, vx=vx + off, vw=vw,
                lo=off - 14, hi=off + tot + P + 14, d1=d1)

# ── drawing (output px; Canvas supersamples and blends every shape, PIL alone would overwrite) ──
class Canvas:
    def __init__(self, y0):
        self.y0 = y0
        self.im = Image.new('RGBA', (OW * SS, (OH - y0) * SS)); self.mask = Image.new('L', self.im.size)
        self.bb = [OH, 0]                         # rows touched, so compose only resamples and blurs that band

    def _put(self, box, draw):
        W, H = self.im.size
        X0, Y0 = max(0, int(box[0] * SS) - 6), max(0, int((box[1] - self.y0) * SS) - 6)
        X1, Y1 = min(W, int(box[2] * SS) + 6), min(H, int((box[3] - self.y0) * SS) + 6)
        if X1 <= X0 or Y1 <= Y0: return
        self.bb = [min(self.bb[0], Y0 // SS + self.y0), max(self.bb[1], Y1 // SS + 1 + self.y0)]
        tmp = Image.new('RGBA', (X1 - X0, Y1 - Y0))
        draw(ImageDraw.Draw(tmp), lambda x, y: ((x * SS - X0), ((y - self.y0) * SS - Y0)))
        self.im.alpha_composite(tmp, (X0, Y0))

    def rr(self, x0, y0, x1, y1, r, fill=None, outline=None, width=1, glass=0):
        def f(d, p):
            d.rounded_rectangle([*p(x0, y0), *p(x1, y1)], radius=r * SS, fill=fill, outline=outline, width=max(1, round(width * SS)))
        self._put((x0, y0, x1, y1), f)
        if glass:
            ImageDraw.Draw(self.mask).rounded_rectangle([x0 * SS, (y0 - self.y0) * SS, x1 * SS, (y1 - self.y0) * SS], radius=r * SS, fill=int(255 * glass))

    def dashed(self, x0, y0, x1, y1, r, col, dash, gapl, width, plus=0):
        def f(d, p):
            w = max(1, round(width * SS))
            for a, b, horiz, fixed in [(x0 + r, x1 - r, True, y0), (x0 + r, x1 - r, True, y1), (y0 + r, y1 - r, False, x0), (y0 + r, y1 - r, False, x1)]:
                q = a
                while q < b:
                    e = min(b, q + dash)
                    d.line([*p(q, fixed), *p(e, fixed)] if horiz else [*p(fixed, q), *p(fixed, e)], fill=col, width=w); q = e + gapl
            for ax, ay, st in [(x0, y0, 180), (x1 - 2 * r, y0, 270), (x1 - 2 * r, y1 - 2 * r, 0), (x0, y1 - 2 * r, 90)]:
                d.arc([*p(ax, ay), *p(ax + 2 * r, ay + 2 * r)], st, st + 90, fill=col, width=w)
            if plus:
                cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
                d.line([*p(cx - plus, cy), *p(cx + plus, cy)], fill=col, width=round(w * 1.2))
                d.line([*p(cx, cy - plus), *p(cx, cy + plus)], fill=col, width=round(w * 1.2))
        self._put((x0, y0, x1, y1), f)

    def text(self, x, y, s, font, fill, anchor='mm'):
        w = font.getlength(s) / SS; h = font.size / SS; l = x - w / 2 if anchor == 'mm' else x
        self._put((l, y - h, l + w, y + h), lambda d, p: d.text(p(x, y), s, font=font, fill=fill, anchor=anchor))

def desk(d, x, y, sc, name, alpha, lay, glass):
    """one desk card; glass=1 on the dark map panel, 0 on the bright end-card ground"""
    if alpha <= 0.01: return
    w, h = CW * sc, CH * sc
    fa = int((46 + 70 * (1 - glass)) * alpha); oa = int((70 + 120 * (1 - glass)) * alpha)
    d.rr(x - w / 2, y - h / 2, x + w / 2, y + h / 2, 7 * sc, fill=(255, 255, 255, fa), outline=(255, 255, 255, oa), width=1 * sc)
    for n, (wx, wy, ww, wh) in lay.items():
        col = (38, 41, 50) if n in DARK else (248, 249, 251)
        d.rr(x + wx * sc, y + wy * sc, x + (wx + ww) * sc, y + (wy + wh) * sc, 2.2 * sc, fill=col + (int(240 * alpha),))

def draw_map(d, m, y, sc=1.0, shift=0.0, glass=1.0, alpha=1.0, ghost=1.0, copies=0.0, scroll=0.0, fade=None):
    cx0 = OW / 2
    X = lambda x: cx0 + (x + shift - cx0) * sc - scroll
    lays = {k: win_layout(v) for k, v in DESK.items()}; lays['D1'] = m['d1']
    def fa(x): return alpha if fade is None else alpha * fade(x)
    if copies > 0:                            # the canvas never ends: the same desks again on both sides
        span = 4 * P * sc
        for rep in range(-4, 5):
            if rep == 0: continue
            for k in ('D1', 'D2', 'D3', 'VH'):
                x = X(m['cx'][k]) + rep * span
                if -200 < x < OW + 200: desk(d, x, y, sc, k, fa(x) * copies, lays[k], glass)
    for k in ('D1', 'D2', 'VH', 'D3', 'D4'):
        a = m['d4'] if k == 'D4' else 1
        x = X(m['cx'][k]); desk(d, x, y, sc, k, fa(x) * a, lays[k], glass)
    if ghost > 0.01:
        gx = X(m['ghost'])
        d.dashed(gx - CW * sc / 2, y - CH * sc / 2, gx + CW * sc / 2, y + CH * sc / 2, 7 * sc, (255, 255, 255, int(170 * ghost * alpha)),
                 5 * sc, 4 * sc, 1.3 * sc, plus=6 * sc)
    vx = X(m['vx']); vw = m['vw'] * sc; vh = VH * sc
    d.rr(vx - vw / 2, y - vh / 2, vx + vw / 2, y + vh / 2, 10 * sc, fill=(255, 255, 255, int(26 * alpha)),
       outline=(255, 255, 255, int(235 * alpha)), width=2.2 * sc)

def keycaps(d, y, t, alpha, press):
    keys = [('⌃', 74), ('⌥', 74), ('Space', 200)]
    f = sf(34, 520); fs = sf(26, 560); gap = 14
    total = sum(w for _, w in keys) + gap * (len(keys) - 1); x = OW / 2 - total / 2
    for i, (lab, w) in enumerate(keys):
        p = press[i]
        dy = 5 * p; top = y - 37 + dy; bot = y + 37
        d.rr(x, y - 37 + 6, x + w, bot + 4, 14, fill=(150, 158, 175, int(170 * alpha)))      # key skirt
        c = int(252 - 28 * p)
        d.rr(x, top, x + w, bot - 4 + dy * 0.2, 14, fill=(c, c, c + 2, int(245 * alpha)), outline=(255, 255, 255, int(200 * alpha)), width=1.2)
        d.text(x + w / 2, top + (bot - 4 - top) / 2, lab, fs if len(lab) > 1 else f, (34, 40, 54, int(255 * alpha)))
        x += w + gap

def note_spot(t):
    i = max(j for j, sp in enumerate(SPOTS) if sp[0] <= t or j == 0)
    if i == 0: return SPOTS[0][1:]
    k = ease((t - SPOTS[i][0]) / 0.4)
    return tuple(a + (b - a) * k for a, b in zip(SPOTS[i - 1][1:], SPOTS[i][1:]))

def draw_note(cv, t, head, body, widths):
    """one card all film long: it glides to free ground, resizes, and swaps its words at each beat"""
    life = ease((t - NOTES[0][0]) / 0.3) * (1 - ease((t - NOTE_END) / 0.25))
    if life <= 0: return
    i = max(j for j, n in enumerate(NOTES) if n[0] <= t or j == 0)
    k = t - NOTES[i][0]
    w = widths[i - 1] + (widths[i] - widths[i - 1]) * spring(min(1, k / 0.3)) if i > 0 else widths[i]
    x0, cy = note_spot(t)
    cv.rr(x0, cy - NOTE_H / 2, x0 + w, cy + NOTE_H / 2, 22, fill=(14, 18, 28, int(150 * life)),
          outline=(255, 255, 255, int(40 * life)), width=1, glass=life)
    def words(j, a, dy):
        cv.text(x0 + 28, cy - 20 + dy, NOTES[j][1], head, (255, 255, 255, int(255 * a * life)), 'lm')
        cv.text(x0 + 28, cy + 25 + dy, NOTES[j][2], body, (255, 255, 255, int(185 * a * life)), 'lm')
    if i > 0 and k < 0.15:
        ko = ease(k / 0.15); words(i - 1, 1 - ko, -6 * ko)
    ki = ease((k - 0.08) / 0.22) if i > 0 else 1
    if ki > 0: words(i, ki, 8 * (1 - ki))

def panel(cv, x0, x1, y, alpha):
    ph = VH + 22
    cv.rr(x0, y - ph / 2, x1, y + ph / 2, 22, fill=(14, 18, 28, int(130 * alpha)), outline=(255, 255, 255, int(36 * alpha)), width=1, glass=alpha)

class HUD:
    def __init__(self):
        self.head, self.body = pf(40, 11), pf(26, 7)
        self.widths = [max(self.head.getlength(h), self.body.getlength(b)) / SS + 56 for _, h, b in NOTES]
        self.title = sf(70, 650); self.sub = pf(30, 7); self.keyf = sf(28, 560)

    def compose(self, frame, cv, blur=22):
        """frosted glass where the mask is set, then the drawn shapes on top"""
        y0, y1 = max(cv.y0, cv.bb[0] - 2), min(OH, cv.bb[1] + 2)
        if y1 <= y0: return frame
        crop = (0, (y0 - cv.y0) * SS, OW * SS, (y1 - cv.y0) * SS); size = (OW, y1 - y0)
        lay = np.asarray(cv.im.crop(crop).resize(size, Image.LANCZOS)).astype(np.float32) / 255
        mk = np.asarray(cv.mask.crop(crop).resize(size, Image.LANCZOS)).astype(np.float32)[..., None] / 255
        band = frame[y0:y1].astype(np.float32)
        if mk.max() > 0:
            m = 3 * blur; b0, b1 = max(0, y0 - m), min(OH, y1 + m)
            soft = cv2.GaussianBlur(frame[b0:b1].astype(np.float32), (0, 0), blur)[y0 - b0:y1 - b0]
            band = band * (1 - mk) + soft * mk
        rgb = lay[..., 2::-1] * 255; a = lay[..., 3:4]
        out = frame.copy(); out[y0:y1] = np.clip(band * (1 - a) + rgb * a, 0, 255).astype(np.uint8)
        return out

    def film(self, frame, t, clip, s, t_key):
        cv = Canvas(0)
        kin = ease(t / 0.25); kout = ease((t - t_key - 0.2) / 0.3)
        mp = ease((t - t_key - 0.25) / 0.35)  # the map takes the keys' place once the canvas opens
        if kout < 1:
            press = [min(1, max(0, 1 - abs(t - (t_key - dt)) / 0.09) * 1.6) for dt in (0.07, 0.04, 0)]
            keycaps(cv, MAP_Y + 10 * (1 - kin) - 8 * kout, t, kin * (1 - kout), press)
        if mp > 0:
            m = map_state(clip, s)
            g = (1 - mp) * .3
            panel(cv, m['lo'] + (OW / 2 - m['lo']) * g, m['hi'] - (m['hi'] - OW / 2) * g, MAP_Y, mp)
            draw_map(cv, m, MAP_Y + 6 * (1 - mp), alpha=mp)
        draw_note(cv, t, self.head, self.body, self.widths)
        return self.compose(frame, cv)

    def end(self, frame, tau):
        cv = Canvas(0)
        m = map_state('end', 0)
        fly = ease(tau / 0.62); sc = 1 + 1.3 * fly; y = MAP_Y + (640 - MAP_Y) * fly
        pa = 1 - ease(tau / 0.22)                # the panel stays behind and clears before the map leaves it
        if pa > 0: panel(cv, m['lo'], m['hi'], MAP_Y, pa)
        scroll = 1.5 * P * sc * ease((tau - 0.45) / 1.45)   # glides along the endless strip, then holds still
        copies = ease((tau - 0.35) / 0.45)
        fade = lambda x: min(1, max(0, (900 - abs(x - OW / 2)) / 260))
        draw_map(cv, m, y, sc=sc, shift=(OW / 2 - m['vx']) * fly, glass=1 - fly, ghost=1 - copies,
                 copies=copies, scroll=scroll % (4 * P * sc), fade=fade)
        for delay, yy, txt, font, col in [(0.38, 372, 'Desk Stream', self.title, (22, 30, 48)),
                                          (0.52, 446, '所有桌面，铺在一张画布上', self.sub, (60, 70, 92))]:
            k = ease((tau - delay) / 0.42)
            if k > 0: cv.text(OW / 2, yy + 16 * (1 - k), txt, font, col + (int(255 * k),))
        k = ease((tau - 0.66) / 0.42)
        if k > 0:
            pw, ph, py = 250, 62, 840 + 14 * (1 - k)
            cv.rr(OW / 2 - pw / 2, py, OW / 2 + pw / 2, py + ph, ph / 2, fill=(255, 255, 255, int(150 * k)), outline=(255, 255, 255, int(220 * k)), width=2)
            cv.text(OW / 2, py + ph / 2, '⌃ ⌥ Space', self.keyf, (40, 52, 76, int(255 * k)))
        return self.compose(frame, cv)
