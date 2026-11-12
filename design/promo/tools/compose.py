"""Frames → film: python3 -I design/promo/tools/compose.py <frames dir> <out.mp4> [--crf 16] [--preset slow]

Reads the captures tools/capture.mjs made (plan.json says how many moments each frame has), averages the moments of
a frame (motion blur), brings the frame down to 1920×1080 with a box filter (the capture's supersampling: each pixel
of the film is the mean of scale × scale captured pixels), and pipes it to ffmpeg: H.264 High, 60 fps, BT.709,
yuv420p, no sound (the film is silent). Work is spread over the CPUs; frames reach ffmpeg in order.
"""
import json
import os
import subprocess
import sys
from multiprocessing import Pool

import numpy as np
from PIL import Image

W, H = 1920, 1080


def load(job):
    folder, n, samples, scale = job
    acc = None
    for s in range(samples):
        im = Image.open(os.path.join(folder, f"f{n:05d}_{s}.jpg")).convert('RGB')
        if im.size != (W, H):
            k = round(im.size[0] / W)
            im = im.reduce(k) if im.size == (W * k, H * k) else im.resize((W, H), Image.LANCZOS)
        a = np.asarray(im, dtype=np.float32)
        acc = a if acc is None else acc + a
    acc /= samples
    return np.clip(acc + 0.5, 0, 255).astype(np.uint8).tobytes()


def main():
    folder, out = sys.argv[1], sys.argv[2]
    crf = sys.argv[sys.argv.index('--crf') + 1] if '--crf' in sys.argv else '16'
    preset = sys.argv[sys.argv.index('--preset') + 1] if '--preset' in sys.argv else 'slow'
    plan = json.load(open(os.path.join(folder, 'plan.json')))
    fps, frm = plan['fps'], plan['from']
    jobs = [(folder, frm + i, s, plan['scale']) for i, s in enumerate(plan['samples'])]
    cmd = ['ffmpeg', '-y', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{W}x{H}', '-r', str(fps), '-i', '-',
           '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
           '-c:v', 'libx264', '-preset', preset, '-crf', crf, '-profile:v', 'high', '-tune', 'film',
           '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv',
           '-g', str(fps * 2), '-movflags', '+faststart', '-an', out]
    ff = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    with Pool(max(1, (os.cpu_count() or 2))) as pool:
        for i, frame in enumerate(pool.imap(load, jobs, chunksize=4)):
            ff.stdin.write(frame)
            if (i + 1) % 600 == 0:
                print(f'{i + 1}/{len(jobs)} frames', flush=True)
    ff.stdin.close()
    sys.exit(ff.wait())


if __name__ == '__main__':
    main()
