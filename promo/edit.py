#!/usr/bin/env python3
"""Desk Stream demo cut: screen recordings → speed-ramped one take with a punch-in camera → end card.
python3 edit.py out.mp4 [--times 1.2,4.5]   (--times writes stills.png instead of the film)"""
import subprocess, sys, math, numpy as np, cv2
import hud

FPS, OW, OH = 60, 1920, 1248
SRC_FPS, SW, SH = 120, 3024, 1964
LW = 1512                                  # logical points across the source
FULL = (756, 491, 1.0)

# shot: clip, t0, t1, speed, camera keys [(src_t, cx, cy, zoom)] in logical points
# 1x where something happens, 3x through cursor travel, zoom never past 1.3
SHOTS = [
    ('n1', 2.20, 3.60, 1.0, [(2.2, *FULL), (3.6, *FULL)]),
    ('n1', 3.60, 4.95, 3.0, [(3.6, *FULL), (4.95, 800, 330, 1.25)]),
    ('n1', 4.95, 6.05, 1.0, [(4.95, 800, 330, 1.25), (6.05, 800, 340, 1.28)]),
    ('n1', 6.05, 6.80, 3.0, [(6.05, 800, 340, 1.28), (6.8, 820, 520, 1.1)]),
    ('n1', 6.80, 8.60, 1.0, [(6.8, 820, 520, 1.1), (7.9, 880, 480, 1.12), (8.6, *FULL)]),
    ('n2', 1.55, 2.90, 1.0, [(1.55, *FULL), (2.9, *FULL)]),
    ('n2', 2.90, 5.35, 2.2, [(2.9, *FULL), (5.35, *FULL)]),
    ('n2', 6.85, 8.30, 1.0, [(6.85, *FULL), (7.15, 1000, 480, 1.12), (8.3, 756, 491, 1.06)]),
    ('n2', 8.30, 10.0, 3.0, [(8.3, 756, 491, 1.06), (10.0, 756, 330, 1.3)]),
    ('n2', 10.0, 12.1, 1.0, [(10.0, 756, 330, 1.3), (11.1, 756, 330, 1.3), (11.8, *FULL), (12.1, *FULL)]),
    ('n3', 1.60, 2.60, 1.0, [(1.6, *FULL), (2.6, *FULL)]),
    ('n3', 2.60, 4.10, 3.0, [(2.6, *FULL), (4.1, 756, 300, 1.3)]),
    ('n3', 4.10, 5.75, 1.0, [(4.1, 756, 300, 1.3), (5.75, 756, 300, 1.3)]),
    ('n3', 5.75, 6.60, 1.0, [(5.75, 756, 300, 1.3), (6.4, *FULL), (6.6, *FULL)]),
    ('n4', 1.15, 2.40, 2.0, [(1.15, *FULL), (2.4, *FULL)]),
    ('n4', 2.40, 5.55, 3.2, [(2.4, *FULL), (5.55, 900, 380, 1.12)]),
    ('n4', 5.55, 7.40, 1.0, [(5.55, 900, 380, 1.12), (6.3, *FULL), (7.4, *FULL)]),
]
END = 3.0                                   # end card seconds
SEAM = 8                                    # frames of dissolve where one take meets the next
EVENTS = [  # (clip, src_t, kind) — sound placement
    ('n1', 2.82, 'key'), ('n1', 6.85, 'down'), ('n1', 8.2, 'up'),
    ('n2', 1.70, 'pan'), ('n2', 3.85, 'panlong'), ('n2', 6.90, 'flick'), ('n2', 7.15, 'create'), ('n2', 11.0, 'click'),
    ('n3', 1.95, 'click'), ('n3', 4.20, 'down'), ('n3', 5.75, 'up'),
    ('n4', 1.30, 'panlong'), ('n4', 5.70, 'click'),
]

def ease(k): return 0.5 - 0.5 * math.cos(math.pi * min(1, max(0, k)))

def timeline():
    """per output frame: (shot index, src_t); speed changes inside a continuous run are smoothed"""
    rows, run = [], []
    def flush():
        if not run: return
        ts = np.array([r[1] for r in run]); k = 9   # ~0.15 s
        pad = np.pad(ts, k, mode='edge'); w = np.hanning(2 * k + 1); w /= w.sum()
        sm = np.convolve(pad, w, mode='valid')
        rows.extend((r[0], s) for r, s in zip(run, sm)); run.clear()
    for i, (clip, t0, t1, sp, _) in enumerate(SHOTS):
        if i and not (SHOTS[i - 1][0] == clip and abs(SHOTS[i - 1][2] - t0) < 1e-6): flush()
        n = round((t1 - t0) / sp * FPS)
        run.extend((i, t0 + (t1 - t0) * j / n) for j in range(n))
    flush()
    return rows

def camera(keys, t):
    if t <= keys[0][0]: return keys[0][1:]
    for a, b in zip(keys, keys[1:]):
        if t <= b[0]:
            k = ease((t - a[0]) / (b[0] - a[0]))
            return tuple(x + (y - x) * k for x, y in zip(a[1:], b[1:]))
    return keys[-1][1:]

def crop(frame, cx, cy, z):
    s = SW / LW; w = SW / z; h = w * OH / OW
    x = min(max(cx * s - w / 2, 0), SW - w); y = min(max(cy * s - h / 2, 0), SH - h)
    M = np.float32([[OW / w, 0, -x * OW / w], [0, OH / h, -y * OH / h]])
    return cv2.warpAffine(frame, M, (OW, OH), flags=cv2.INTER_AREA if z < 1.6 else cv2.INTER_CUBIC)

class Reader:
    def __init__(self, clip):
        self.p = subprocess.Popen(['ffmpeg', '-v', 'error', '-hwaccel', 'videotoolbox', '-i', f'{clip}.mov',
                                   '-vf', f'fps={SRC_FPS}', '-f', 'rawvideo', '-pix_fmt', 'bgr24', '-'], stdout=subprocess.PIPE)
        self.i, self.f = -1, None
    def at(self, t):
        want = max(0, round(t * SRC_FPS))
        while self.i < want:
            b = self.p.stdout.read(SW * SH * 3)
            if len(b) < SW * SH * 3: break
            self.f = np.frombuffer(b, np.uint8).reshape(SH, SW, 3); self.i += 1
        return self.f

# ── end card ────────────────────────────────────────────────────────────────
def end_card_frames(bg_bgr, last_bgr):
    bg = cv2.GaussianBlur(bg_bgr, (0, 0), 60)
    for j in range(round(END * FPS)):
        t = j / FPS
        # 0–0.32 s: the last shot pushes in and dissolves into the blurred ground
        if t < 0.32:
            k = ease(t / 0.32); z = 1 + 0.12 * k
            M = cv2.getRotationMatrix2D((OW / 2, OH / 2), 0, z)
            a = cv2.GaussianBlur(cv2.warpAffine(last_bgr, M, (OW, OH)), (0, 0), 0.1 + 40 * k)
            frame = cv2.addWeighted(a, 1 - k, bg, k, 0)
        else:
            frame = bg.copy()
        yield HUD.end(frame, t)

def out_time(clip, src):
    for j, (i, s) in enumerate(ROWS):
        if SHOTS[i][0] == clip and s >= src: return j / FPS
    return None

def frames():
    readers, last, bg, seam = {}, None, None, None
    t_key = out_time('n1', 2.82)
    for j, (i, s) in enumerate(ROWS):
        clip = SHOTS[i][0]
        if clip not in readers:
            readers[clip] = Reader(clip)
            if last is not None: seam = (j, last)   # takes meet on the same canvas state: dissolve over the cursor jump
        f = readers[clip].at(s)
        if clip == 'n2' and bg is None and s > 8.4: bg = crop(f, *FULL)
        cur = crop(f, *camera(SHOTS[i][4], s))
        if seam and j - seam[0] < SEAM:
            k = ease((j - seam[0] + 1) / (SEAM + 1)); cur = cv2.addWeighted(seam[1], 1 - k, cur, k, 0)
        last = cur
        yield HUD.film(cur, j / FPS, clip, s, t_key)
    yield from end_card_frames(bg, last)

ROWS = timeline()
HUD = hud.HUD()
if __name__ == '__main__':
    out = sys.argv[1]
    if '--times' in sys.argv:
        want = sorted(round(float(x) * FPS) for x in sys.argv[sys.argv.index('--times') + 1].split(','))
        got = [cv2.resize(f, (640, 416)) for j, f in enumerate(frames()) if j in want]
        rows = [np.hstack(got[k:k + 3] + [np.zeros_like(got[0])] * (3 - len(got[k:k + 3]))) for k in range(0, len(got), 3)]
        cv2.imwrite(out, np.vstack(rows)); sys.exit()
    total = len(ROWS) / FPS + END
    print(f'{total:.2f} s')
    enc = subprocess.Popen(['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'bgr24', '-s', f'{OW}x{OH}', '-r', str(FPS),
                            '-i', '-', '-c:v', 'libx264', '-crf', '17', '-preset', 'medium', '-pix_fmt', 'yuv420p', out], stdin=subprocess.PIPE)
    for f in frames(): enc.stdin.write(f.tobytes())
    enc.stdin.close(); enc.wait()
    with open('events.txt', 'w') as fh:
        for clip, src, kind in EVENTS:
            t = out_time(clip, src)
            if t is not None: fh.write(f'{t:.3f} {kind}\n')
        fh.write(f'{len(ROWS) / FPS + 0.2:.3f} land\n')
