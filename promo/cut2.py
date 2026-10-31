#!/usr/bin/env python3
"""Second demo cut: one Cap recording, re-timed, with a trackpad that shows each gesture and one caption card.
python3 cut2.py src.mp4 out.mp4 [--times 1.2,4.5]   (--times writes a contact sheet instead of the film)
Everything below is keyed to source seconds, so it follows the footage through every speed ramp. No sound."""
import glob, math, subprocess, sys, numpy as np, cv2
from PIL import Image, ImageDraw, ImageFont, ImageFilter

FPS, W, H, SS = 60, 1664, 1080, 2             # the recording's own size; overlay drawn at 2x and downscaled
ICON = '../mac/DeskStream/Assets.xcassets/AppIcon.appiconset/icon_512x512.png'
SF = '/System/Library/Fonts/SFNS.ttf'
PF = glob.glob('/System/Library/AssetsV2/*/*/AssetData/PingFang.ttc')[0]

# (src t0, src t1, speed): 1x where something happens, fast through holds and cursor travel
SEGS = [
    (0.95, 1.45, 1.0),    # four fingers down
    (1.45, 1.85, 1.0),    # windows fly in
    (1.85, 3.20, 3.0),
    (3.20, 3.95, 1.0),    # swipe to Desktop 2
    (3.95, 4.30, 2.0),
    (4.30, 4.95, 1.0),    # on to full-screen Safari
    (4.95, 5.40, 2.5),
    (5.40, 7.25, 1.25),   # one long swipe back
    (7.25, 7.85, 3.5),
    (7.85, 8.35, 1.0),    # pinch in
    (8.35, 9.15, 3.0),
    (9.15, 9.75, 1.0),    # scroll down the desk
    (9.75, 10.35, 3.0),
    (10.35, 11.30, 1.0),  # and back up
    (11.30, 12.05, 2.5),  # cursor to the label
    (12.05, 13.40, 1.0),  # click, the overview, a rest
    (13.40, 15.35, 5.0),
    (15.35, 16.15, 1.0),  # click back into Desktop 1
    (16.15, 16.45, 2.0),
    (16.45, 17.25, 1.0),  # fling to Safari
    (17.25, 17.55, 2.5),
    (17.55, 18.40, 0.8),  # one more flick at the end makes Desktop 3
    (18.40, 21.60, 5.0),
    (21.60, 23.00, 1.0),  # click the empty desk, macOS switches to it
]
END = 2.4

# (src t0, src t1, kind, arg): fingers on the trackpad, timed to what the footage shows
GESTURES = [
    (1.02, 1.42, 'four_down', 0),
    (3.30, 3.72, 'swipe', -1),        # natural scrolling: fingers left, the canvas moves on to the right
    (4.32, 4.64, 'swipe', -1),
    (5.42, 6.02, 'swipe', 1),
    (7.92, 8.26, 'spread', 0),
    (9.22, 9.62, 'scroll', -1),
    (10.42, 10.82, 'scroll', 1),
    (12.17, 12.17, 'click', (687, 67)),
    (15.47, 15.47, 'click', (295, 85)),
    (16.44, 16.68, 'swipe', -1.3),
    (17.62, 17.84, 'swipe', -1.6),
    (21.70, 21.70, 'click', (825, 477)),
]
NOTES = [   # (src t, head, body)
    (0.95, '打开画布', '四指下滑，所有桌面的窗口飞进来'),
    (3.20, '左右滑动', '一个桌面一列，全屏 App 也单独一列'),
    (7.85, '捏合缩放，上下滑动', '放大看清窗口，在一个桌面里上下翻'),
    (11.30, '点桌面标签', '退远看所有桌面，再点一下回到这里'),
    (16.15, '新建桌面', '滑到最右边，再往右甩一下'),
    (21.55, '点空桌面', '直接切到这个桌面'),
]

def ease(k): k = min(1, max(0, k)); return 0.5 - 0.5 * math.cos(math.pi * k)
def spring(k): return 1 - math.exp(-k * 9) * math.cos(k * 13) if k > 0 else 0

def timeline():
    """src time per output frame; speed changes are smoothed over ~0.15 s so ramps don't jolt"""
    ts = []
    for t0, t1, sp in SEGS:
        n = round((t1 - t0) / sp * FPS)
        ts.extend(t0 + (t1 - t0) * j / n for j in range(n))
    ts = np.array(ts); k = 9
    w = np.hanning(2 * k + 1); w /= w.sum()
    return np.convolve(np.pad(ts, k, mode='edge'), w, mode='valid')

def sf(size, weight):
    f = ImageFont.truetype(SF, size * SS); f.set_variation_by_axes([100, min(96, size), 400, weight]); return f
def pf(size, face): return ImageFont.truetype(PF, size * SS, index=face)   # 7 medium, 11 semibold

# ── trackpad fingers ────────────────────────────────────────────────────────
TPW, TPH = 118, 76

def finger_layout(kind, arg, k):
    """finger centres relative to the trackpad's centre, at progress k of the stroke"""
    if kind == 'four_down':
        return [(-27 + 18 * i, -18 + 36 * k) for i in range(4)]
    if kind == 'swipe':
        dx = 44 * arg * (k - 0.5) * (1.25 if abs(arg) > 1 else 1)
        return [(dx - 9, -6), (dx + 9, 6)]
    if kind == 'scroll':
        dy = 34 * arg * (k - 0.5)
        return [(-10, dy), (10, dy)]
    if kind == 'spread':
        d = 8 + 26 * k
        return [(-d * .8, d * .6), (d * .8, -d * .6)]
    return [(6, 4)]                                         # click

def fingers(s):
    """[(x, y, alpha, scale)] plus the click ripple (0..1 or None) at src time s"""
    out, ripple = [], None
    for t0, t1, kind, arg in GESTURES:
        if kind == 'click':
            if t0 - 0.25 < s < t0 + 0.35:
                a = ease((s - t0 + 0.25) / 0.12) * (1 - ease((s - t0 - 0.2) / 0.15))
                press = max(0, 1 - abs(s - t0) / 0.08)
                out.append((*finger_layout(kind, arg, 0)[0], a, 1 - 0.22 * press))
                if s >= t0: ripple = (s - t0) / 0.35
            continue
        if not (t0 - 0.2 < s < t1 + 0.28): continue
        a = ease((s - t0 + 0.2) / 0.14) * (1 - ease((s - t1 - 0.08) / 0.2))
        sc = 1 + 0.25 * (1 - ease((s - t0 + 0.2) / 0.2)) + 0.2 * ease((s - t1 - 0.08) / 0.2)
        k = ease((s - t0) / (t1 - t0))
        trail = [finger_layout(kind, arg, ease((s - 0.025 * j - t0) / (t1 - t0))) for j in range(1, 7)]
        for i, (x, y) in enumerate(finger_layout(kind, arg, k)):
            out.append((x, y, a, sc, [tr[i] for tr in trail]))
    return out, ripple

def screen_ripple(s):
    for t0, _, kind, arg in GESTURES:
        if kind == 'click' and t0 <= s < t0 + 0.4: return arg, (s - t0) / 0.4
    return None

# ── the caption card: trackpad on the left, words on the right ─────────────
class Card:
    def __init__(self):
        self.head, self.body = pf(30, 11), pf(21, 7)
        self.widths = [18 + TPW + 22 + max(self.head.getlength(h), self.body.getlength(b)) / SS + 28 for _, h, b in NOTES]
        self.h, self.cy = 100, H - 44 - 50

    def draw(self, frame, s, life):
        i = max(j for j, n in enumerate(NOTES) if n[0] <= s or j == 0)
        k = s - NOTES[i][0]
        w = self.widths[i - 1] + (self.widths[i] - self.widths[i - 1]) * spring(min(1, k / 0.3)) if i else self.widths[0]
        x0, y0 = int(W / 2 - w / 2) - 4, int(self.cy - self.h / 2) - 4
        bw, bh = int(w) + 8, self.h + 8
        im = Image.new('RGBA', (bw * SS, bh * SS)); d = ImageDraw.Draw(im)
        P = lambda x, y: ((x - x0) * SS, (y - y0) * SS)
        L, T = W / 2 - w / 2, self.cy - self.h / 2
        d.rounded_rectangle([*P(L, T), *P(L + w, T + self.h)], radius=24 * SS, fill=(14, 18, 28, int(150 * life)),
                            outline=(255, 255, 255, int(40 * life)), width=SS)
        # trackpad
        tx, ty = L + 18 + TPW / 2, self.cy
        fs, ripple = fingers(s)
        dip = 0 if ripple is None else 1 - ripple
        d.rounded_rectangle([*P(tx - TPW / 2, ty - TPH / 2), *P(tx + TPW / 2, ty + TPH / 2)], radius=11 * SS,
                            fill=(8, 10, 16, int((120 - 40 * dip) * life)), outline=(255, 255, 255, int(70 * life)), width=SS)
        if ripple is not None:
            r = 8 + 30 * ease(ripple)
            d.ellipse([*P(tx + 6 - r, ty + 4 - r), *P(tx + 6 + r, ty + 4 + r)], outline=(255, 255, 255, int(200 * (1 - ripple) * life)), width=2 * SS)
        for f in fs:
            x, y, a, sc = f[:4]
            for j, (px, py) in enumerate(f[4] if len(f) > 4 else []):
                ra = 7 * sc * (1 - j / 8); aa = int(45 * a * life * (1 - j / 6))
                d.ellipse([*P(tx + px - ra, ty + py - ra), *P(tx + px + ra, ty + py + ra)], fill=(255, 255, 255, aa))
            r = 8 * sc
            d.ellipse([*P(tx + x - r, ty + y - r + 1.5), *P(tx + x + r, ty + y + r + 1.5)], fill=(0, 0, 0, int(60 * a * life)))
            d.ellipse([*P(tx + x - r, ty + y - r), *P(tx + x + r, ty + y + r)], fill=(255, 255, 255, int(240 * a * life)))
        # words: the old pair lifts out, the new one settles in
        lx = L + 18 + TPW + 22
        def words(j, a, dy):
            d.text(P(lx, self.cy - 17 + dy), NOTES[j][1], font=self.head, fill=(255, 255, 255, int(255 * a * life)), anchor='lm')
            d.text(P(lx, self.cy + 21 + dy), NOTES[j][2], font=self.body, fill=(255, 255, 255, int(185 * a * life)), anchor='lm')
        if i and k < 0.15:
            ko = ease(k / 0.15); words(i - 1, 1 - ko, -6 * ko)
        ki = ease((k - 0.08) / 0.22) if i else 1
        if ki > 0: words(i, ki, 8 * (1 - ki))
        lay = np.asarray(im.resize((bw, bh), Image.LANCZOS)).astype(np.float32) / 255
        mask = Image.new('L', (bw * SS, bh * SS))
        ImageDraw.Draw(mask).rounded_rectangle([*P(L, T), *P(L + w, T + self.h)], radius=24 * SS, fill=int(255 * life))
        mk = np.asarray(mask.resize((bw, bh), Image.LANCZOS)).astype(np.float32)[..., None] / 255
        m = 66; Y0, Y1 = max(0, y0 - m), min(H, y0 + bh + m); X0, X1 = max(0, x0 - m), min(W, x0 + bw + m)
        soft = cv2.GaussianBlur(frame[Y0:Y1, X0:X1].astype(np.float32), (0, 0), 22)[y0 - Y0:y0 - Y0 + bh, x0 - X0:x0 - X0 + bw]
        band = frame[y0:y0 + bh, x0:x0 + bw].astype(np.float32)
        band = band * (1 - mk) + soft * mk
        a = lay[..., 3:4]
        frame[y0:y0 + bh, x0:x0 + bw] = np.clip(band * (1 - a) + lay[..., 2::-1] * 255 * a, 0, 255).astype(np.uint8)
        return frame

def draw_screen_ripple(frame, s):
    r = screen_ripple(s)
    if not r: return frame
    (x, y), k = r
    ov = frame.copy()
    cv2.circle(ov, (x, y), int(10 + 26 * ease(k)), (255, 255, 255), 3, cv2.LINE_AA)
    cv2.circle(ov, (x, y), int(9 * (1 - k)) + 1, (255, 255, 255), -1, cv2.LINE_AA)
    return cv2.addWeighted(ov, 0.85 * (1 - ease(k)), frame, 1 - 0.85 * (1 - ease(k)), 0)

# ── end card ────────────────────────────────────────────────────────────────
def end_frames(last):
    bg = cv2.GaussianBlur(last, (0, 0), 50)
    bg = cv2.addWeighted(bg, 0.82, np.full_like(bg, 236), 0.18, 0)
    ic = Image.open(ICON).convert('RGBA')
    title, sub, keyf, keyb = sf(60, 650), pf(26, 7), pf(24, 7), sf(24, 560)
    for j in range(round(END * FPS)):
        t = j / FPS
        if t < 0.32:
            k = ease(t / 0.32)
            M = cv2.getRotationMatrix2D((W / 2, H / 2), 0, 1 + 0.1 * k)
            a = cv2.GaussianBlur(cv2.warpAffine(last, M, (W, H)), (0, 0), 0.1 + 36 * k)
            frame = cv2.addWeighted(a, 1 - k, bg, k, 0)
        else:
            frame = bg.copy()
        im = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)).convert('RGBA')
        ti = t - 0.18
        if ti > 0:
            sz = max(1, int(176 * (0.55 + 0.45 * spring(ti))))
            ii = ic.resize((sz, sz), Image.LANCZOS); al = min(1, ti / 0.18)
            ii.putalpha(ii.getchannel('A').point(lambda v: int(v * al)))
            im.alpha_composite(ii, (int(W / 2 - sz / 2), int(390 - sz / 2)))
        lay = Image.new('RGBA', (W * SS, H * SS)); d = ImageDraw.Draw(lay)
        for delay, y, txt, font, col in [(0.40, 560, 'Desk Stream', title, (22, 30, 48)),
                                         (0.55, 625, '所有桌面，铺在一张画布上', sub, (60, 70, 92))]:
            k = ease((t - delay) / 0.42)
            if k > 0: d.text((W / 2 * SS, (y + 14 * (1 - k)) * SS), txt, font=font, fill=col + (int(255 * k),), anchor='mm')
        k = ease((t - 0.7) / 0.42)
        if k > 0:
            # PingFang has no ⌃⌥, so the keys are set in SF
            a, b = '四指下滑  ·  ', '⌃ ⌥ Space'
            wa, wb = keyf.getlength(a) / SS, keyb.getlength(b) / SS
            pw, ph, py = wa + wb + 56, 54, 690 + 14 * (1 - k)
            d.rounded_rectangle([(W / 2 - pw / 2) * SS, py * SS, (W / 2 + pw / 2) * SS, (py + ph) * SS], radius=ph / 2 * SS,
                                fill=(255, 255, 255, int(150 * k)), outline=(255, 255, 255, int(220 * k)), width=2 * SS)
            x = W / 2 - (wa + wb) / 2; col = (40, 52, 76, int(255 * k))
            d.text((x * SS, (py + ph / 2) * SS), a, font=keyf, fill=col, anchor='lm')
            d.text(((x + wa) * SS, (py + ph / 2) * SS), b, font=keyb, fill=col, anchor='lm')
        im = Image.alpha_composite(im, lay.resize((W, H), Image.LANCZOS))
        yield cv2.cvtColor(np.array(im.convert('RGB')), cv2.COLOR_RGB2BGR)

# ── film ────────────────────────────────────────────────────────────────────
def frames(src):
    p = subprocess.Popen(['ffmpeg', '-v', 'error', '-i', src, '-f', 'rawvideo', '-pix_fmt', 'bgr24', '-'], stdout=subprocess.PIPE)
    card, ts, i, f = Card(), timeline(), -1, None
    n = len(ts); last = None
    for j, s in enumerate(ts):
        want = round(s * FPS)
        while i < want:
            b = p.stdout.read(W * H * 3)
            if len(b) < W * H * 3: break
            f = np.frombuffer(b, np.uint8).reshape(H, W, 3); i += 1
        t = j / FPS
        life = ease(t / 0.3) * (1 - ease((t - (n / FPS - 0.3)) / 0.25))
        out = draw_screen_ripple(f.copy(), s)
        last = f
        yield card.draw(out, s, life) if life > 0 else out
    p.kill()
    yield from end_frames(last)

if __name__ == '__main__':
    src, out = sys.argv[1], sys.argv[2]
    if '--times' in sys.argv:
        want = sorted(round(float(x) * FPS) for x in sys.argv[sys.argv.index('--times') + 1].split(','))
        got = [cv2.resize(fr, (832, 540)) for j, fr in enumerate(frames(src)) if j in want]
        while len(got) % 3: got.append(np.zeros_like(got[0]))
        cv2.imwrite(out, np.vstack([np.hstack(got[k:k + 3]) for k in range(0, len(got), 3)])); sys.exit()
    print(f'{len(timeline()) / FPS + END:.2f} s')
    enc = subprocess.Popen(['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'bgr24', '-s', f'{W}x{H}', '-r', str(FPS),
                            '-i', '-', '-c:v', 'libx264', '-crf', '17', '-preset', 'medium', '-pix_fmt', 'yuv420p', '-an', out], stdin=subprocess.PIPE)
    for fr in frames(src): enc.stdin.write(fr.tobytes())
    enc.stdin.close(); enc.wait()
