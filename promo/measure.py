import subprocess, numpy as np, cv2, sys, json
# per-frame horizontal canvas shift (logical points) by phase correlation of high-passed frames
W, H = 756, 491
def run(clip, t0, t1):
    p = subprocess.Popen(['ffmpeg','-v','error','-ss',str(t0),'-to',str(t1),'-i',f'{clip}.mov','-vf',f'fps=60,scale={W}:{H},format=gray','-f','rawvideo','-'],stdout=subprocess.PIPE)
    prev, out, t = None, [], t0
    win = cv2.createHanningWindow((W, 300), cv2.CV_32F)
    while True:
        b = p.stdout.read(W*H)
        if len(b) < W*H: break
        g = np.frombuffer(b, np.uint8).reshape(H, W).astype(np.float32)
        g = (g - cv2.GaussianBlur(g, (0,0), 6))[120:420]
        if prev is not None:
            (dx, dy), r = cv2.phaseCorrelate(prev, g, win)
            out.append((round(t,4), round(dx*2,2), round(r,2)))
        prev = g; t += 1/60
    return out
res = {c: run(c, a, b) for c, a, b in [('n2',1.5,12.2),('n4',1.1,7.5),('n1',2.2,8.7),('n3',1.5,6.7)]}
json.dump(res, open('shift.json','w'))
for c, rows in res.items():
    acc = 0; print(c)
    for t, dx, r in rows:
        acc += dx if abs(dx) > 0.3 and r > 0.15 else 0
        if abs(dx) > 0.3: print(f'  {t:.2f} {dx:7.1f} r{r:.2f} acc{acc:8.0f}')
