#!/usr/bin/env python3
"""Turn an image into the float32 input tools/npu-run.cpp `classify` reads (1x3xHxW, RGB, NCHW).

    npu-prep.py IMAGE OUT.f32 [SIZE]

Resize the short side to SIZE*256/224, centre-crop SIZE (default 224), scale to 0-1 and normalise with the
ImageNet mean and std, as CIX's model hub classification graphs (MobileNetV2, ResNet) expect.
Needs Pillow and NumPy (Debian/Ubuntu: python3-pil python3-numpy).
"""
import sys

import numpy as np
from PIL import Image


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    size = int(sys.argv[3]) if len(sys.argv) > 3 else 224
    img = Image.open(sys.argv[1]).convert("RGB")
    short = round(size * 256 / 224)
    w, h = img.size
    s = short / min(w, h)
    img = img.resize((max(short, round(w * s)), max(short, round(h * s))), Image.BILINEAR)
    w, h = img.size
    left, top = (w - size) // 2, (h - size) // 2
    img = img.crop((left, top, left + size, top + size))
    x = np.asarray(img, dtype=np.float32) / 255.0
    x = (x - np.array([0.485, 0.456, 0.406], dtype=np.float32)) / np.array([0.229, 0.224, 0.225], dtype=np.float32)
    x.transpose(2, 0, 1)[np.newaxis].astype(np.float32).tofile(sys.argv[2])


if __name__ == "__main__":
    main()
