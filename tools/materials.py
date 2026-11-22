"""The dungeon's own floors, seen from above, for the maps.

Jonas, 2026-11-22: "some kind of grounding design of these maps, like to use
materials from the dungeon - having them in different levels of beige is not
very engrossing." So each floor of a map is painted with what is really
underfoot there: the building models' (WMO) floor triangles with their own
textures, and the terrain's own blended ground textures where there is
terrain (the Deadmines' cove, Zul'Farrak's streets). Only surfaces at the
floor's own height are used - the navmesh says what that height is at every
point - so roofs, ceilings and the floor above never cover the map.

Reads the client's files through the monitor's gamefiles package (the same
readers the GM view uses).
"""
import io
import math
import os
import re
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw

MONITOR = "/mnt/wow-data2/wow-server-monitor"
sys.path.insert(0, MONITOR)
from gamefiles import adt, minimap, wmo  # noqa: E402
from gamefiles.m2 import decode_blp, read_file  # noqa: E402


def map_dir(map_id):
    from make_dungeon_maps import dbc
    rows, s = dbc("Map.dbc")
    return next(s(r[1]) for r in rows if r[0] == map_id)


def tiles_of(directory):
    """The map's ADT tiles, from the minimap index (every tile has a minimap)."""
    out = set()
    pat = re.compile(rf"{re.escape(directory.lower())}\\map(\d+)_(\d+)\.blp$")
    for k in minimap._translate():
        m = pat.match(k)
        if m:
            out.add((int(m.group(1)), int(m.group(2))))
    return sorted(out)


def wdt_wmo(directory):
    """A map that is one building (Uldaman, Maraudon): the WDT's own MWMO/MODF."""
    blob = read_file(f"World\\Maps\\{directory}\\{directory}.wdt")
    if not blob:
        return []
    name, modf = None, b""
    for tag, off, size in adt._walk(blob):
        if tag == "MWMO" and size > 1:
            name = blob[off:blob.find(b"\0", off)].decode("latin-1")
        elif tag == "MODF":
            modf = blob[off:off + size]
    if not name or not modf:
        return []
    e = struct.unpack_from("<II3f3f6fHHHH", modf)
    # The WDT's building sits at the world origin (world = -local, as
    # tools/plan_maps.py found for Uldaman): its raw position is zero, so
    # not the ADT conversion, which would move it 17,000 yards.
    return [dict(model=name, x=e[4], y=e[2], z=e[3], rot=e[5:8])]


class Source:
    """Up-facing surfaces of a map: triangles in world space, each with a
    way to colour a point on it."""

    def __init__(self, map_id):
        self.dir = map_dir(map_id)
        self.tris = []          # (3, 3) world
        self.uvs = []           # (3, 2) texture coords (WMO) or None (terrain)
        self.tex = []           # texture key per triangle
        self.textures = {}      # key -> (h, w, 3) float array, or terrain tile
        placements = {}
        self.terrain = []
        for c, r in tiles_of(self.dir):
            try:
                t = adt.Tile(self.dir, c, r)
            except FileNotFoundError:
                continue
            self.terrain.append(t)
            for w in t.wmos:
                placements[w["id"]] = w
        for w in wdt_wmo(self.dir):
            placements[-1] = w
        for w in placements.values():
            self._wmo(w)
        for t in self.terrain:
            self._terrain(t)
        self.tris = np.array(self.tris) if self.tris else np.zeros((0, 3, 3))

    def _wmo(self, place):
        try:
            model = wmo.WMO(place["model"])
        except FileNotFoundError:
            return
        a = math.radians(place["rot"][1])
        ca, sa = math.cos(a), math.sin(a)
        for mat, parts in model.parts.items():
            m = model.materials[mat] if mat < len(model.materials) else {"texture": ""}
            key = m["texture"]
            for p, _n, uv, tri in parts:
                # world = position - R(yaw) . local (yaw 0: world = position - local,
                # measured on the Monastery's wings)
                lx, ly = p[:, 0] * ca - p[:, 1] * sa, p[:, 0] * sa + p[:, 1] * ca
                world = np.column_stack([place["x"] - lx, place["y"] - ly, place["z"] + p[:, 2]])
                t = world[tri]
                e1, e2 = t[:, 1] - t[:, 0], t[:, 2] - t[:, 0]
                nrm = np.cross(e1, e2)
                ln = np.linalg.norm(nrm, axis=1)
                ok = ln > 1e-6
                up = np.zeros(len(t))
                up[ok] = np.abs(nrm[ok, 2]) / ln[ok]
                keep = up > 0.55
                for k in np.nonzero(keep)[0]:
                    self.tris.append(t[k])
                    self.uvs.append(uv[tri[k]])
                    self.tex.append(key)

    def _terrain(self, tile):
        key = ("adt", tile.col, tile.row)
        for n in range(256):
            if not tile.layers[n]:
                continue
            v = tile.chunk_vertices(n)
            for a, b, c in tile.chunk_triangles(n):
                self.tris.append(np.array([v[a], v[b], v[c]]))
                self.uvs.append(None)
                self.tex.append(key)
        self.textures[key] = tile

    # --- colour -------------------------------------------------------------

    def texture(self, key, texel_per_px):
        """A texture as float RGB, shrunk so a texel is about a pixel (a
        plank pattern minified a hundred times is noise, not wood)."""
        ck = (key, round(math.log2(max(texel_per_px, 1))))
        if ck in self.textures:
            return self.textures[ck]
        blob = read_file(key) if key else None
        if not blob:
            arr = np.full((4, 4, 3), 0.45)
        else:
            im = decode_blp(blob).convert("RGB")
            f = 2 ** ck[1]
            if f > 1:
                im = im.resize((max(1, im.width // f), max(1, im.height // f)), Image.BOX)
            arr = np.asarray(im, np.float64) / 255.0
        self.textures[ck] = arr
        return arr

    def atlas(self, tile, px):
        ck = ("atlas", tile.col, tile.row, px)
        if ck not in self.textures:
            self.textures[ck] = adt.bake_atlas(tile, px).astype(np.float64) / 255.0
        return self.textures[ck]


def paint(src, floor_z, have, to_px, from_px, size, tol=4.0):
    """The floor in its own materials.

    floor_z: (H, W) the floor's height at every pixel (navmesh), have: where
    it is defined. to_px(x, y) -> (u, v) pixels; from_px(u, v arrays) ->
    world x, y. Returns (H, W, 3) float colour and (H, W) bool coverage."""
    W, H = size
    tris = src.tris
    if not len(tris):
        return np.zeros((H, W, 3)), np.zeros((H, W), bool)
    cx, cy, cz = tris[:, :, 0].mean(1), tris[:, :, 1].mean(1), tris[:, :, 2].mean(1)
    u, v = to_px(cx, cy)
    ui, vi = np.clip(u.astype(int), 0, W - 1), np.clip(v.astype(int), 0, H - 1)
    inside = (u >= -20) & (u < W + 20) & (v >= -20) & (v < H + 20) & have[vi, ui]
    fz = floor_z[vi, ui]
    # a surface belongs to this floor if some corner of it is near the floor
    near = np.min(np.abs(tris[:, :, 2] - fz[:, None]), axis=1)
    cand = np.nonzero(inside & (near < tol))[0]
    # painter: farthest from the floor first, nearest last (it wins)
    cand = cand[np.argsort(-np.abs(cz[cand] - fz[cand]))]
    ids = Image.new("I", (W, H), 0)
    d = ImageDraw.Draw(ids)
    for k in cand:
        pu, pv = to_px(tris[k, :, 0], tris[k, :, 1])
        d.polygon(list(zip(pu.tolist(), pv.tolist())), fill=int(k) + 1)
    idimg = np.asarray(ids, np.int64) - 1
    covered = idimg >= 0
    out = np.zeros((H, W, 3))
    ys, xs = np.nonzero(covered)
    k = idimg[ys, xs]
    wx, wy = from_px(xs + 0.5, ys + 0.5)
    # per texture
    keys = np.array([src.tex[i] if isinstance(src.tex[i], str) else "|".join(map(str, src.tex[i]))
                     for i in range(len(src.tex))], dtype=object)
    kk = keys[k]
    px_per_yard = W / max(1e-6, abs(from_px(np.array([W]), np.array([0]))[1][0] - from_px(np.array([0]), np.array([0]))[1][0]))
    for key in set(kk.tolist()):
        sel = kk == key
        ti = k[sel]
        if key.startswith("adt|"):
            tile = src.textures[("adt",) + tuple(int(x) for x in key.split("|")[1:])]
            px = 64
            atl = src.atlas(tile, px)
            p0 = tile.pos[tile.chunk_at[0, 0]]
            ay = ((p0[0] - wx[sel]) / adt.CHUNK * px).astype(int)
            ax = ((p0[1] - wy[sel]) / adt.CHUNK * px).astype(int)
            ay, ax = np.clip(ay, 0, atl.shape[0] - 1), np.clip(ax, 0, atl.shape[1] - 1)
            out[ys[sel], xs[sel]] = atl[ay, ax]
            continue
        t = tris[ti]
        # barycentric of the pixel's world point in each triangle (top view)
        x0, y0 = t[:, 0, 0], t[:, 0, 1]
        e1x, e1y = t[:, 1, 0] - x0, t[:, 1, 1] - y0
        e2x, e2y = t[:, 2, 0] - x0, t[:, 2, 1] - y0
        den = e1x * e2y - e2x * e1y
        den[np.abs(den) < 1e-9] = 1e-9
        px_, py_ = wx[sel] - x0, wy[sel] - y0
        b1 = (px_ * e2y - e2x * py_) / den
        b2 = (e1x * py_ - px_ * e1y) / den
        b0 = 1 - b1 - b2
        uv = np.array([src.uvs[i] for i in ti])
        uu = b0 * uv[:, 0, 0] + b1 * uv[:, 1, 0] + b2 * uv[:, 2, 0]
        vv = b0 * uv[:, 0, 1] + b1 * uv[:, 1, 1] + b2 * uv[:, 2, 1]
        # texels per pixel, from the first triangle's uv span over its size
        full = src.texture(key, 1)
        span_uv = np.hypot(uv[:, 1, 0] - uv[:, 0, 0], uv[:, 1, 1] - uv[:, 0, 1]).mean() * full.shape[1]
        span_yd = np.hypot(e1x, e1y).mean()
        tpp = span_uv / max(span_yd, 1e-3) / px_per_yard
        tex = src.texture(key, tpp)
        th, tw = tex.shape[:2]
        out[ys[sel], xs[sel]] = tex[(np.floor(vv * th).astype(int)) % th, (np.floor(uu * tw).astype(int)) % tw]
    return out, covered
