#!/usr/bin/env python3
"""Builds the iOS app's page shim twice with its own script (ios/scripts/build-shim.py, from
claude/ios-app) over this tree's PrivacyScripts.swift: as it is (shim-old.js) and with
fpNoisePixels replaced by the proposal of ios-measure/canvas-alpha/proposed.js (shim-new.js).

    python3 measure/canvas_browser/make_shims.py <out dir>   # ios/shim and ios/scripts in place
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = sys.argv[1]
FP = os.path.join(ROOT, "ios/shim/fingerprint.js")
PAGE = os.path.join(ROOT, "ios/Lumen/Resources/page-shim.js")

PROPOSED = """// WebKit on Apple platforms keeps a 2D canvas premultiplied and converts with Accelerate
// (PixelBufferConversion.cpp -> vImagePremultiplyData / vImageUnpremultiplyData_RGBA8888):
const fpPremul = (v, a) => ((v * a + 127) / 255) | 0;
const fpUnpremul = (p, a) => ((Math.min(p, a) * 255 + (a >> 1)) / a) | 0;

function fpNoisePixels(data, seed) {
  for (let i = 0; i < data.length; i += 4) {
    const a = data[i + 3];
    if (a === 0 || a === 255) continue;
    const h = fpMix(seed, 0, a >> 1);
    if (h % 5 !== 0) continue;
    const b = (a & 0xfe) | ((h >>> 16) & 1);
    if (b === a || b === 0 || b === 255) continue;
    for (let k = i; k < i + 3; k++) data[k] = fpUnpremul(fpPremul(data[k], b), b);
    data[i + 3] = b;
  }
  return data;
}
"""


def build(name):
    os.makedirs(os.path.dirname(PAGE), exist_ok=True)
    subprocess.run([sys.executable, os.path.join(ROOT, "ios/scripts/build-shim.py")], check=True)
    os.replace(PAGE, os.path.join(OUT, name))


os.makedirs(OUT, exist_ok=True)
old = open(FP, encoding="utf-8").read()
build("shim-old.js")
match = re.search(r"function fpNoisePixels\(data, seed\) \{.*?\n\}\n", old, re.S)
if not match:
    sys.exit("fpNoisePixels not found in fingerprint.js")
try:
    open(FP, "w", encoding="utf-8").write(old[:match.start()] + PROPOSED + old[match.end():])
    build("shim-new.js")
finally:
    open(FP, "w", encoding="utf-8").write(old)
print("shims:", ", ".join(f"{n} {os.path.getsize(os.path.join(OUT, n))} bytes" for n in ("shim-old.js", "shim-new.js")))
