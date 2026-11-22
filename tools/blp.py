"""Write BLP2 textures the 3.3.5 client (Wow.exe) draws: DXT1, with mipmaps.

Pillow's BLP writer makes palettized BLP2 (compression 1); Wow.exe draws those
as solid green (mele's test of Guide 0.8.0, 2026-11-22 - our own client
decoded them, so the first test looked fine). Uncompressed BGRA works but is
256 KB a tile; DXT1 is 32 KB and is what the game's own textures use.

DXT1 here is a plain range fit: per 4x4 block, the two endpoints are the
block's colours furthest apart along its main axis, each pixel takes the
nearest of the four colours between them. Good enough for a map.
"""
import struct

import numpy as np
from PIL import Image


def _565(c):
    c = np.clip(np.rint(c), 0, 255).astype(np.int32)
    return ((c[..., 0] >> 3) << 11) | ((c[..., 1] >> 2) << 5) | (c[..., 2] >> 3)


def _from565(v):
    r = ((v >> 11) & 31) * 255 / 31
    g = ((v >> 5) & 63) * 255 / 63
    b = (v & 31) * 255 / 31
    return np.stack([r, g, b], -1)


def dxt1(img):
    """(H, W, 3) uint8 -> DXT1 bytes. H and W multiples of 4."""
    a = np.asarray(img, np.float64)
    h, w = a.shape[:2]
    blocks = a.reshape(h // 4, 4, w // 4, 4, 3).transpose(0, 2, 1, 3, 4).reshape(-1, 16, 3)
    mean = blocks.mean(1, keepdims=True)
    cen = blocks - mean
    # main axis: power iteration on each block's covariance
    cov = np.einsum("nki,nkj->nij", cen, cen)
    axis = np.ones((len(blocks), 3))
    for _ in range(4):
        axis = np.einsum("nij,nj->ni", cov, axis)
        axis /= np.maximum(np.linalg.norm(axis, axis=1, keepdims=True), 1e-9)
    proj = np.einsum("nki,ni->nk", cen, axis)
    lo = blocks[np.arange(len(blocks)), proj.argmin(1)]
    hi = blocks[np.arange(len(blocks)), proj.argmax(1)]
    c0, c1 = _565(hi), _565(lo)
    # four-colour mode needs c0 > c1; equal endpoints are one flat colour
    swap = c0 < c1
    c0, c1 = np.where(swap, c1, c0), np.where(swap, c0, c1)
    e0, e1 = _from565(c0), _from565(c1)
    palette = np.stack([e0, e1, (2 * e0 + e1) / 3, (e0 + 2 * e1) / 3], 1)          # (n, 4, 3)
    d = ((blocks[:, :, None, :] - palette[:, None, :, :]) ** 2).sum(-1)            # (n, 16, 4)
    idx = d.argmin(-1)
    idx[c0 == c1] = 0
    bits = (idx.astype(np.uint32) << (2 * np.arange(16, dtype=np.uint32))).sum(1).astype(np.uint32)
    out = np.zeros(len(blocks), dtype=[("c0", "<u2"), ("c1", "<u2"), ("bits", "<u4")])
    out["c0"], out["c1"], out["bits"] = c0, c1, bits
    return out.tobytes()


def save(img, path):
    """A square or rectangular power-of-two RGB image as a DXT1 BLP2 with mips."""
    img = img.convert("RGB")
    w, h = img.size
    mips = []
    while True:
        mw, mh = max(4, w), max(4, h)
        level = img.resize((mw, mh), Image.BOX) if (mw, mh) != img.size else img
        mips.append(dxt1(level))
        if w == 1 and h == 1:
            break
        w, h = max(1, w // 2), max(1, h // 2)
        if len(mips) >= 16:
            break
    header = 4 + 4 + 4 + 4 + 4 + 16 * 4 + 16 * 4 + 256 * 4
    offsets, sizes, at = [], [], header
    for m in mips:
        offsets.append(at)
        sizes.append(len(m))
        at += len(m)
    offsets += [0] * (16 - len(offsets))
    sizes += [0] * (16 - len(sizes))
    with open(path, "wb") as f:
        # magic, type 1 (direct), compression 2 (DXT), alpha depth 0,
        # alpha encoding 0 (DXT1), has mips 1, width, height
        f.write(b"BLP2" + struct.pack("<I4B2I", 1, 2, 0, 0, 1, *img.size))
        f.write(struct.pack("<16I", *offsets))
        f.write(struct.pack("<16I", *sizes))
        f.write(b"\0" * 1024)                       # palette, unused for DXT
        for m in mips:
            f.write(m)
