"""Read the server's navmesh (mmaps/*.mmtile) for one map.

The walkable ground of a dungeon, as polygons in world coordinates: what the
dungeon maps are drawn from (make_dungeon_maps.py) and what decides which
floor a position is on.

AzerothCore writes Detour tiles behind its own header; the Detour part starts
at the "VAND" magic. Detour keeps Recast's axes: (x, y, z) = (wow Y, wow Z,
wow X). Ground polygons only (off-mesh connections are skipped).
"""
import glob
import os
import struct
from collections import defaultdict

AREA_WATER, AREA_MAGMA, AREA_SLIME = 8, 2, 4     # MapDefines.h NavTerrainFlag


class Poly:
    __slots__ = ("pts", "z", "area", "idx", "nb")

    def __init__(self, pts, area, idx):
        self.pts = pts                      # [(wowX, wowY, wowZ)]
        self.z = sum(p[2] for p in pts) / len(pts)
        self.area = area
        self.idx = idx
        self.nb = []                        # indices of polygons sharing an edge

    @property
    def cx(self):
        return sum(p[0] for p in self.pts) / len(self.pts)

    @property
    def cy(self):
        return sum(p[1] for p in self.pts) / len(self.pts)

    def area2d(self):
        a = 0.0
        n = len(self.pts)
        for i in range(n):
            x1, y1 = self.pts[i][0], self.pts[i][1]
            x2, y2 = self.pts[(i + 1) % n][0], self.pts[(i + 1) % n][1]
            a += x1 * y2 - x2 * y1
        return abs(a) / 2

    def contains(self, x, y):
        inside = False
        n = len(self.pts)
        for i in range(n):
            x1, y1 = self.pts[i][0], self.pts[i][1]
            x2, y2 = self.pts[(i + 1) % n][0], self.pts[(i + 1) % n][1]
            if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
                inside = not inside
        return inside


def load(mmaps_dir, map_id):
    polys = []
    for f in sorted(glob.glob(os.path.join(mmaps_dir, f"{map_id:03d}*.mmtile"))):
        b = open(f, "rb").read()
        o = b.find(b"VAND")
        if o < 0:
            continue
        h = struct.unpack_from("<15i", b, o)
        pc, vc = h[6], h[7]
        o += 100
        V = struct.unpack_from(f"<{vc * 3}f", b, o)
        o += vc * 12
        for i in range(pc):
            p = struct.unpack_from("<I6H6HHBB", b, o + i * 32)
            n, at = p[14], p[15]
            if at >> 6:                     # off-mesh connection
                continue
            pts = [(V[k * 3 + 2], V[k * 3], V[k * 3 + 1]) for k in p[1:1 + n]]
            polys.append(Poly(pts, at & 0x3F, len(polys)))
    _link(polys)
    return polys


def _link(polys):
    """Neighbours by shared edges; tiles repeat border vertices exactly."""
    key = lambda p: (round(p[0], 1), round(p[1], 1), round(p[2], 1))
    edges = defaultdict(list)
    for poly in polys:
        n = len(poly.pts)
        for i in range(n):
            a, b = key(poly.pts[i]), key(poly.pts[(i + 1) % n])
            edges[(min(a, b), max(a, b))].append(poly.idx)
    for owners in edges.values():
        for a in owners:
            for b in owners:
                if a != b:
                    polys[a].nb.append(b)
    # Tile borders: Detour splits polygons at tile edges, and the halves do not
    # always share both vertices. Join polygons whose edges overlap on a border.
    by_edge = defaultdict(list)
    for poly in polys:
        n = len(poly.pts)
        for i in range(n):
            a, b = poly.pts[i], poly.pts[(i + 1) % n]
            for axis in (0, 1):
                if abs(a[axis] - b[axis]) < 0.01:
                    by_edge[(axis, round(a[axis], 1))].append((poly.idx, a, b))
    for (axis, _), segs in by_edge.items():
        if len(segs) < 2:
            continue
        other = 1 - axis
        for i, (pa, a1, a2) in enumerate(segs):
            lo, hi = sorted((a1[other], a2[other]))
            za = (a1[2] + a2[2]) / 2
            for pb, b1, b2 in segs[i + 1:]:
                if pa == pb:
                    continue
                lo2, hi2 = sorted((b1[other], b2[other]))
                if min(hi, hi2) - max(lo, lo2) > 0.2 and abs(za - (b1[2] + b2[2]) / 2) < 4:
                    polys[pa].nb.append(pb)
                    polys[pb].nb.append(pa)
    for poly in polys:
        poly.nb = sorted(set(poly.nb))


def nearest(polys, x, y, z, reach=30.0):
    """The polygon under (x, y) closest in height to z, else the nearest one."""
    best, bd = None, 1e18
    for p in polys:
        if p.contains(x, y):
            d = abs(p.z - z)
        else:
            d = (p.cx - x) ** 2 + (p.cy - y) ** 2 + (p.z - z) ** 2
            if d > reach * reach:
                continue
            d = 1000 + d
        if d < bd:
            best, bd = p, d
    return best


def reachable(polys, starts):
    seen = set()
    stack = [p.idx for p in starts if p]
    while stack:
        i = stack.pop()
        if i in seen:
            continue
        seen.add(i)
        stack.extend(n for n in polys[i].nb if n not in seen)
    return [polys[i] for i in sorted(seen)]
