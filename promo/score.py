import os, sys
sys.path.insert(0, os.path.expanduser("~/.claude/skills/onetake/scripts"))
from sfx_palette import *

ev = [(float(t), k) for t, k in (l.split() for l in open('events.txt'))]
s = Score(22.2, T60=0.9)
for t, k in ev:
    if k == 'key':
        s.place(wood(260, 0.08), t, 0.7); s.place(air(0.5, 300, 2400, shape=0.6), t + 0.05, 0.5, send=0.3)
    elif k == 'down': s.place(wood(220, 0.08), t, 0.55, pan=0.1)
    elif k == 'up': s.place(wood(170, 0.1), t, 0.6, pan=0.1); s.place(sub(70, 0.3), t, 0.25)
    elif k == 'click': s.place(wood(240, 0.08), t, 0.6)
    elif k == 'pan': s.place(air(0.45, 400, 1600, q=1.2), t, 0.35, pan=0.3, pan_to=-0.3)
    elif k == 'panlong': s.place(air(0.8, 300, 1800, q=1.2, shape=0.4), t, 0.4, pan=0.4, pan_to=-0.4)
    elif k == 'flick': s.place(air(0.35, 600, 3200, q=1.6, shape=0.3), t, 0.55, pan=-0.2, pan_to=0.5)
    elif k == 'create': s.place(glass(880, 0.9, 0.8), t, 0.35, pan=0.4, send=0.4)
    elif k == 'land':
        s.place(sub(58, 0.9), t, 0.55); s.place(glass(660, 1.6, 0.7), t + 0.05, 0.3, send=0.45)
        s.place(glass(990, 1.4, 0.6), t + 0.2, 0.18, send=0.5)
s.write('sfx.wav')
