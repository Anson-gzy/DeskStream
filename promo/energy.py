import subprocess, numpy as np, sys
f=sys.argv[1]; W,H=189,123
p=subprocess.run(['ffmpeg','-v','error','-i',f,'-vf',f'fps=30,scale={W}:{H}','-f','rawvideo','-pix_fmt','gray','-'],capture_output=True).stdout
a=np.frombuffer(p,np.uint8).reshape(-1,H,W).astype(np.float32)
d=np.abs(np.diff(a,axis=0)).mean(axis=(1,2))
line=''.join(' .:-=+*#%@'[min(9,int(x*2))] for x in d)
for i in range(0,len(line),60): print(f'{i/30:5.1f} |{line[i:i+60]}|')
