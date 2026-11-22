#!/usr/bin/env python3
"""Draw Guide's dungeon maps from the server's navmesh.

Jonas, 2026-11-22: "can Guide be evolved to handle the map (pressing M) while
in a dungeon?" The 3.3.5 client has maps for Wrath dungeons only; in the old
ones M shows the zone outside. So Guide brings its own: the walkable ground
the server's pathfinding uses, seen from above, cut into floors where the
dungeon stacks (Blackrock Depths, Sunken Temple), drawn as an ink-on-parchment
plan. No game art is copied; the picture is made from geometry.

    python3 tools/make_dungeon_maps.py --mmaps DIR 36 230 ...

DIR holds the server's <map>*.mmtile files (they live in the worldserver's
data volume, readable by root only - copy them out first). Writes
Guide/maps/<map>_<floor>_<1..12>.blp (the world map's 4 x 3 tile layout) and
Guide/DungeonMaps.lua (bounds, floors, bosses, entrances).

Floors: the ground reachable from the entrances is grown outward polygon by
polygon; a polygon that would land on top of (or under) ground already in
the region starts another region. Regions whose overlap is only a bridge or
a ledge are merged back; what remains are real floors. A floor can hold
several separate parts (a wing), like Blizzard's own maps.
"""
import argparse
import glob
import math
import os
import re
import struct
import subprocess
import sys
from collections import defaultdict, deque

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import navmesh  # noqa: E402
import materials  # noqa: E402
import blp  # noqa: E402

# The zone whose map shows the way in, for right-click on the dungeon map
# (Wow.exe sits on the continent inside a dungeon). Names as GetMapZones gives them.
OUTSIDE = {33: "Silverpine Forest", 34: "Stormwind City", 36: "Westfall", 43: "The Barrens",
           47: "The Barrens", 48: "Ashenvale", 70: "Badlands", 90: "Dun Morogh",
           109: "Swamp of Sorrows", 129: "The Barrens", 189: "Tirisfal Glades", 209: "Tanaris",
           229: "Burning Steppes", 230: "Searing Gorge", 249: "Dustwallow Marsh",
           289: "Western Plaguelands", 309: "Stranglethorn Vale", 329: "Eastern Plaguelands",
           349: "Desolace", 389: "Orgrimmar", 409: "Burning Steppes", 429: "Feralas",
           469: "Burning Steppes", 509: "Silithus", 531: "Silithus"}

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(os.path.dirname(HERE), "Guide")
CLIENT_KIT = "/mnt/wow-data2/wow-client-kit"
ENV = "/mnt/wow-data2/wow-server/.env"

W, H = 1002, 668          # the world map's visible detail area
SX, SY = 30, 20           # the floor's outline for the layer stack, in cells
SS = 2                    # supersampling
CELL = 2.0                # yards, overlap grid
STACK = 5.0               # yards of height that make two grounds "stacked"
MINOR = 250.0             # sq yd of overlap that is still only a bridge/ledge


# --- client data -------------------------------------------------------------

def dbc(name):
    sys.path.insert(0, os.path.join(CLIENT_KIT, "converters"))
    import m2
    b = m2.read_file(f"DBFilesClient\\{name}")
    n, f, rs, ss = struct.unpack_from("<4x4I", b)
    strs = b[20 + n * rs:]
    rows = [struct.unpack_from(f"<{f}I", b, 20 + i * rs) for i in range(n)]
    s = lambda o: strs[o:strs.index(b"\0", o)].decode("utf-8", "replace")
    return rows, s


def map_name(map_id):
    rows, s = dbc("Map.dbc")
    for r in rows:
        if r[0] == map_id:
            return s(r[5])
    return str(map_id)


def encounters(map_id):
    rows, s = dbc("DungeonEncounter.dbc")
    out = [(r[4], s(r[5])) for r in rows if r[1] == map_id and r[2] == 0]
    return [n for _, n in sorted(out)]


def sql(query):
    pw = next(l.split("=", 1)[1].strip() for l in open(ENV) if l.startswith("DOCKER_DB_ROOT_PASSWORD="))
    r = subprocess.run(["sudo", "-n", "docker", "exec", "-i", "-e", f"MYSQL_PWD={pw}", "ac-database",
                        "mysql", "-uroot", "acore_world", "-N", "-B"],
                       input=query, capture_output=True, text=True, check=True)
    return [l.split("\t") for l in r.stdout.splitlines() if l]


def entrances(map_id):
    return [tuple(map(float, r)) for r in
            sql(f"SELECT target_position_x, target_position_y, target_position_z FROM areatrigger_teleport "
                f"WHERE target_map = {map_id}")]


def bosses(map_id):
    """Encounter names matched to spawns on the map. Events with no creature
    of that name (Ring of Law, The Seven) are left out."""
    names = encounters(map_id)
    rows = sql(f"SELECT c.guid, c.id, t.name, c.position_x, c.position_y, c.position_z FROM creature c "
               f"JOIN creature_template t ON t.entry = c.id WHERE c.map = {map_id}")
    out = []
    for order, name in enumerate(names, 1):
        hits = [r for r in rows if r[2].lower() == name.lower()] or \
               [r for r in rows if r[2].lower().startswith(name.lower())]    # Sneed: his Shredder
        if not hits:
            print(f"  boss {name!r}: no spawn of that name - left off", file=sys.stderr)
            continue
        g, e, n, x, y, z = hits[0]
        out.append(dict(order=order, name=name, guid=int(g), entry=int(e), x=float(x), y=float(y), z=float(z)))
    return out


def spawn_points(map_id):
    """Where the dungeon's creatures and objects stand: the map keeps the
    ground near them. The navmesh also holds the land and sea outside (the
    Deadmines' cove opens to the sea, and the coast above the mines is on the
    same map), reachable by swimming but no part of the dungeon."""
    return [tuple(map(float, r)) for q in ("creature", "gameobject") for r in
            sql(f"SELECT position_x, position_y, position_z FROM {q} WHERE map = {map_id}")]


def near_spawns(polys, points, reach=45.0, rise=25.0):
    grid = defaultdict(list)
    for x, y, z in points:
        grid[(math.floor(x / reach), math.floor(y / reach))].append((x, y, z))
    keep = []
    for p in polys:
        i, j = math.floor(p.cx / reach), math.floor(p.cy / reach)
        if any((x - p.cx) ** 2 + (y - p.cy) ** 2 < reach * reach and abs(z - p.z) < rise
               for di in (-1, 0, 1) for dj in (-1, 0, 1) for x, y, z in grid[(i + di, j + dj)]):
            keep.append(p)
    return keep


# --- floors ------------------------------------------------------------------

def cells_of(p):
    """Overlap-grid cells a polygon covers (cell centres inside it, else its centre)."""
    xs = [q[0] for q in p.pts]
    ys = [q[1] for q in p.pts]
    out = []
    for i in range(math.floor(min(xs) / CELL), math.floor(max(xs) / CELL) + 1):
        for j in range(math.floor(min(ys) / CELL), math.floor(max(ys) / CELL) + 1):
            if p.contains((i + 0.5) * CELL, (j + 0.5) * CELL):
                out.append((i, j))
    return out or [(math.floor(p.cx / CELL), math.floor(p.cy / CELL))]


def zat(p, x, y):
    """Height of polygon p at (x, y): the nearest vertex's, near enough for stacking."""
    return min(p.pts, key=lambda q: (q[0] - x) ** 2 + (q[1] - y) ** 2)[2]


def floors(polys, starts):
    cov = {p.idx: cells_of(p) for p in polys}
    # grow regions: a polygon joins the region it is reached from unless it
    # would sit on top of (or under) that region's ground
    region = {}
    occ = []                                    # region -> {cell: [z]}
    seeds = deque(s.idx for s in starts if s)
    byidx = {p.idx: p for p in polys}

    def fits(r, p):
        for c in cov[p.idx]:
            z = zat(p, (c[0] + 0.5) * CELL, (c[1] + 0.5) * CELL)
            for z2 in occ[r].get(c, ()):
                if abs(z - z2) > STACK:
                    return False
        return True

    def add(r, p):
        region[p.idx] = r
        for c in cov[p.idx]:
            occ[r].setdefault(c, []).append(zat(p, (c[0] + 0.5) * CELL, (c[1] + 0.5) * CELL))

    while seeds:
        s = seeds.popleft()
        if s in region:
            continue
        r = len(occ)
        occ.append({})
        add(r, byidx[s])
        q = deque([s])
        while q:
            i = q.popleft()
            for n in byidx[i].nb:
                if n in region or n not in byidx:
                    continue
                if fits(r, byidx[n]):
                    add(r, byidx[n])
                    q.append(n)
                else:
                    seeds.append(n)

    # overlap between regions, in sq yd, and which regions touch
    nreg = len(occ)
    overlap = defaultdict(float)
    cellreg = defaultdict(list)
    for r, cells in enumerate(occ):
        for c, zs in cells.items():
            cellreg[c].append((r, zs))
    for c, lst in cellreg.items():
        for a in range(len(lst)):
            for b in range(a + 1, len(lst)):
                ra, za = lst[a]
                rb, zb = lst[b]
                if ra != rb and any(abs(x - y) > STACK for x in za for y in zb):
                    k = (min(ra, rb), max(ra, rb))
                    overlap[k] += CELL * CELL
    touch = defaultdict(int)
    for p in polys:
        for n in p.nb:
            if n in region and region[n] != region[p.idx]:
                touch[(min(region[n], region[p.idx]), max(region[n], region[p.idx]))] += 1
    size = defaultdict(float)
    for p in polys:
        size[region[p.idx]] += p.area2d()

    # union regions whose overlap is minor (a bridge, a ledge), biggest borders first
    parent = list(range(nreg))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def group_overlap(a, b):
        ga = [r for r in range(nreg) if find(r) == a]
        gb = [r for r in range(nreg) if find(r) == b]
        return sum(overlap.get((min(x, y), max(x, y)), 0) for x in ga for y in gb)

    changed = True
    while changed:
        changed = False
        for (a, b), _ in sorted(touch.items(), key=lambda kv: -kv[1]):
            ra, rb = find(a), find(b)
            if ra == rb:
                continue
            small = min(sum(size[r] for r in range(nreg) if find(r) == ra),
                        sum(size[r] for r in range(nreg) if find(r) == rb))
            # a sliver (a stair landing, a ledge: under 6000 sq yd) is no floor of its own
            if group_overlap(ra, rb) <= max(MINOR, 0.03 * small) or small < 6000:
                parent[rb] = ra
                changed = True

    groups = sorted({find(r) for r in range(nreg)}, key=lambda g: -sum(size[r] for r in range(nreg) if find(r) == g))
    # colour the groups into floors: groups that do not overlap share a floor
    floor_of = {}
    floors_ = []
    for g in groups:
        for fi, members in enumerate(floors_):
            if all(group_overlap(g, m) <= MINOR for m in members):
                members.append(g)
                floor_of[g] = fi
                break
        else:
            floor_of[g] = len(floors_)
            floors_.append([g])
    # order: the entrance's floor first, then by mean height, highest first
    out = defaultdict(list)
    for p in polys:
        out[floor_of[find(region[p.idx])]].append(p)
    # top floor first: the layer stack is drawn in this order
    med = lambda ps: sorted(p.z for p in ps)[len(ps) // 2]
    return sorted((out[i] for i in range(len(floors_))), key=lambda ps: -med(ps))


# --- drawing -----------------------------------------------------------------

PAPER = np.array([222, 205, 166], float)      # floor, high
PAPER_LOW = np.array([186, 164, 122], float)  # floor, low
WATER = np.array([118, 150, 140], float)
MAGMA = np.array([196, 92, 40], float)
SLIME = np.array([120, 150, 70], float)
ROCK = np.array([46, 37, 29], float)
INK = np.array([28, 19, 12], float)


def bounds(polys, pad=0.06):
    xs = [q[0] for p in polys for q in p.pts]
    ys = [q[1] for p in polys for q in p.pts]
    # screen: right = east = -wowY, down = south = -wowX
    left, right = max(ys), min(ys)
    top, bottom = max(xs), min(xs)
    wy, hx = left - right, top - bottom
    wy, hx = wy * (1 + 2 * pad), hx * (1 + 2 * pad)
    # fit 3:2 (W:H)
    if wy / hx < W / H:
        wy = hx * W / H
    else:
        hx = wy * H / W
    cy, cx = (left + right) / 2, (top + bottom) / 2
    return dict(left=cy + wy / 2, right=cy - wy / 2, top=cx + hx / 2, bottom=cx - hx / 2)


def to_px(b, x, y, scale=1):
    u = (b["left"] - y) / (b["left"] - b["right"]) * W * scale
    v = (b["top"] - x) / (b["top"] - b["bottom"]) * H * scale
    return u, v


def noise(w, h, seed, blur):
    rng = np.random.default_rng(seed)
    n = Image.fromarray((rng.random((h, w)) * 255).astype(np.uint8))
    return np.asarray(n.filter(ImageFilter.GaussianBlur(blur)), float) / 255.0


def draw(polys, others, b, seed, src=None):
    # The whole 1024 x 768 the tiles hold: Wow.exe shows a little past
    # Blizzard's 1002 x 668 (mele's test, 2026-11-22: a flat strip at the
    # right and bottom), so the map runs on there at the same scale.
    w, h = 1024 * SS, 768 * SS
    zs = [p.z for p in polys]
    zlo, zhi = np.percentile(zs, 5), np.percentile(zs, 95)
    zspan = max(zhi - zlo, 1.0)
    floor = Image.new("L", (w, h), 0)
    wat = Image.new("L", (w, h), 0)
    hot = Image.new("L", (w, h), 0)
    slime = Image.new("L", (w, h), 0)
    ghost = Image.new("L", (w, h), 0)
    dg = ImageDraw.Draw(ghost)
    for p in others:                                    # the other floors, faintly, for bearings
        dg.polygon([to_px(b, q[0], q[1], SS) for q in p.pts], fill=255)
    dh, ds = ImageDraw.Draw(hot), ImageDraw.Draw(slime)
    zimg = Image.new("F", (w, h), 0.0)
    zabs = Image.new("F", (w, h), -1e4)                 # the floor's height, for its materials
    da = ImageDraw.Draw(zabs)
    df, dw, dz = ImageDraw.Draw(floor), ImageDraw.Draw(wat), ImageDraw.Draw(zimg)
    for p in sorted(polys, key=lambda p: p.z):          # higher ground drawn over lower
        pts = [to_px(b, q[0], q[1], SS) for q in p.pts]
        t = min(max((p.z - zlo) / zspan, 0.0), 1.0)
        df.polygon(pts, fill=255)
        dz.polygon(pts, fill=t)
        da.polygon(pts, fill=p.z)
        dw.polygon(pts, fill=255 if p.area & navmesh.AREA_WATER else 0)
        # The mmaps generator files a building's liquid by (type & 3), so
        # WMO magma (LiquidType 19) lands as "slime": Molten Core's and
        # Blackrock Depths' lava came out green. Nothing in the old
        # dungeons is slime - both are drawn as lava.
        dh.polygon(pts, fill=255 if p.area & (navmesh.AREA_MAGMA | navmesh.AREA_SLIME) else 0)
    # the navmesh keeps half a body's width off the walls: give that back
    grow = ImageFilter.MaxFilter(3)
    floor = floor.filter(grow).filter(grow)
    zimg = zimg.filter(ImageFilter.MaxFilter(5))
    m = np.asarray(floor, float) / 255.0
    wm = np.asarray(wat.filter(grow).filter(grow), float) / 255.0
    hm = np.asarray(hot.filter(grow).filter(grow), float)[..., None] / 255.0
    sm = np.asarray(slime.filter(grow).filter(grow), float)[..., None] / 255.0
    gm = np.asarray(ghost.filter(grow).filter(grow).filter(ImageFilter.GaussianBlur(SS)), float)[..., None] / 255.0
    t = np.asarray(zimg, float)[..., None]

    # ground: parchment, darker where low, a little grain
    grain = noise(w, h, seed, 1.2)[..., None]
    mott = noise(w // 8, h // 8, seed + 1, 3)
    mott = np.asarray(Image.fromarray((mott * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR), float)[..., None] / 255
    ground = PAPER_LOW + (PAPER - PAPER_LOW) * t
    ground = ground * (0.93 + 0.1 * mott) + (grain - 0.5) * 10
    tone = None
    if src is not None:
        # what is really underfoot (materials.py): the floor's own textures
        za = np.asarray(zabs.filter(ImageFilter.MaxFilter(7)), np.float64)
        have = (np.asarray(floor.filter(ImageFilter.MaxFilter(5)), np.uint8) > 0) & (za > -1e3)
        tp = lambda x, y: to_px(b, np.asarray(x, float), np.asarray(y, float), SS)
        fp = lambda u, v: (b["top"] - v / (H * SS) * (b["top"] - b["bottom"]),
                           b["left"] - u / (W * SS) * (b["left"] - b["right"]))
        col, cov = materials.paint(src, za, have, tp, fp, (w, h), tol=5.0)
        # Grade: textures straight from the files run from murky (the
        # Deadmines) to glaring (Zul'Farrak's sand). Expose every map so its
        # floors sit at one brightness, and take a fifth of the saturation
        # out, so the materials read as materials and the marks stay on top.
        lum = col @ np.array([0.299, 0.587, 0.114])
        med = float(np.median(lum[cov])) if cov.any() else 0.5
        mat = col * (0.58 / max(med, 0.05))
        grey = (mat @ np.array([0.299, 0.587, 0.114]))[..., None]
        mat = np.clip((grey + (mat - grey) * 0.8) * 255, 0, 255)
        covf = cov.astype(float)[..., None]
        if cov.any():
            tone = mat[cov].mean(0)
            # gaps (doodads, a seam) take the colour of the material round them
            blur = lambda a: np.asarray(Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).filter(
                ImageFilter.GaussianBlur(6 * SS)), float)
            wsum = blur(covf[..., 0] * 255)[..., None] / 255.0
            fill = np.stack([blur(mat[..., i] * covf[..., 0]) for i in range(3)], -1) / np.maximum(wsum, 1e-3)
            fill = np.where(wsum > 0.02, fill, tone)
            mat = mat * covf + fill * (1 - covf)
            ground = mat * (0.82 + 0.3 * t) + (grain - 0.5) * 6
    ground = ground * (1 - wm[..., None] * 0.75) + (WATER * (0.9 + 0.15 * mott)) * wm[..., None] * 0.75
    ground = ground * (1 - hm * 0.85) + (MAGMA * (0.85 + 0.3 * mott)) * hm * 0.85
    ground = ground * (1 - sm * 0.75) + (SLIME * (0.9 + 0.15 * mott)) * sm * 0.75

    # walls: shade the ground near them (inner shadow), ink line on the edge
    fimg = Image.fromarray((m * 255).astype(np.uint8))
    inner = np.asarray(fimg.filter(ImageFilter.GaussianBlur(7 * SS)), float) / 255.0
    shade = np.clip((1 - inner) * 1.6, 0, 1)[..., None] * m[..., None]
    ground = ground * (1 - 0.35 * shade)
    dil = np.asarray(fimg.filter(ImageFilter.MaxFilter(2 * SS + 1)), float) / 255.0
    edge = np.clip(dil - m, 0, 1)[..., None]

    # rock: dark, mottled, lighter in a halo round the passages (cave wall)
    halo = np.asarray(fimg.filter(ImageFilter.GaussianBlur(14 * SS)), float)[..., None] / 255.0
    base = ROCK if tone is None else tone * 0.2 + ROCK * 0.35     # the dungeon's own tone, dark
    rock = base * (0.85 + 0.3 * mott) + (grain - 0.5) * 8 + np.array([40, 32, 22]) * np.clip(halo * 2.2, 0, 1)

    rock = rock + np.array([34, 28, 20]) * gm            # another floor above or below
    img = rock * (1 - m[..., None]) + ground * m[..., None]
    img = img * (1 - edge) + INK * edge
    img = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")
    return (img.resize((1024, 768), Image.LANCZOS),
            floor.crop((0, 0, W * SS, H * SS)).resize((SX, SY), Image.BOX))


def write_tiles(img, prefix):
    """The world map's 4 x 3 tiles, as DXT1 BLP2 (blp.py: Wow.exe draws
    Pillow's palettized BLP as solid green)."""
    canvas = img                                    # already 1024 x 768
    for k in range(12):
        x, y = (k % 4) * 256, (k // 4) * 256
        blp.save(canvas.crop((x, y, x + 256, y + 256)), f"{prefix}{k + 1}.blp")
    return canvas


# --- floor lookup for the addon ---------------------------------------------

LOOK = 8.0     # yards per lookup cell


def lookup(floor_polys):
    """Cells where more than one floor has ground: {cell: [(floor, zlo, zhi)]}.
    Elsewhere the floor is whichever one has ground in the cell (single)."""
    cells = defaultdict(dict)
    for fi, polys in enumerate(floor_polys):
        for p in polys:
            xs = [q[0] for q in p.pts]
            ys = [q[1] for q in p.pts]
            hits = [(q[0], q[1], q[2]) for q in p.pts]
            # every cell whose centre (or a quarter point) lies in the polygon
            for i in range(math.floor(min(xs) / LOOK), math.floor(max(xs) / LOOK) + 1):
                for j in range(math.floor(min(ys) / LOOK), math.floor(max(ys) / LOOK) + 1):
                    for fx, fy in ((0.5, 0.5), (0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)):
                        x, y = (i + fx) * LOOK, (j + fy) * LOOK
                        if p.contains(x, y):
                            hits.append((x, y, zat(p, x, y)))
            for x, y, z in hits:
                c = (math.floor(x / LOOK), math.floor(y / LOOK))
                lo, hi = cells[c].get(fi, (1e9, -1e9))
                cells[c][fi] = (min(lo, z), max(hi, z))
    return cells


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def components(polys, min_area=300.0):
    """The separate parts of a map nothing walkable joins: the Monastery's
    four wings, each behind its own door. Specks (a table top, a ledge the
    navmesh left alone) are dropped."""
    idx = {p.idx: p for p in polys}
    seen, out = set(), []
    for p in polys:
        if p.idx in seen:
            continue
        comp, stack = [], [p.idx]
        seen.add(p.idx)
        while stack:
            i = stack.pop()
            comp.append(idx[i])
            for n in idx[i].nb:
                if n in idx and n not in seen:
                    seen.add(n)
                    stack.append(n)
        if sum(q.area2d() for q in comp) >= min_area:
            out.append(comp)
    return sorted(out, key=lambda c: -sum(q.area2d() for q in c))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mmaps", required=True)
    ap.add_argument("--preview", help="also write full-size PNGs with bosses and entrances marked here")
    ap.add_argument("--web", help="also write <map>_<floor>.webp and <map>.json here (the monitor's guide pages)")
    ap.add_argument("--plain", action="store_true", help="parchment only, no materials (faster)")
    ap.add_argument("maps", nargs="+", type=int)
    a = ap.parse_args()
    os.makedirs(os.path.join(ADDON, "maps"), exist_ok=True)
    datafile = os.path.join(ADDON, "DungeonMaps.lua")
    existing = open(datafile).read() if os.path.exists(datafile) else ""
    blocks = dict(re.findall(r"(?ms)^-- map (\d+)\n(.*?)^-- end \1\n", existing))
    for map_id in a.maps:
        name = map_name(map_id)
        print(f"{map_id} {name}", file=sys.stderr)
        polys = navmesh.load(a.mmaps, map_id)
        ents = entrances(map_id)
        starts = [navmesh.nearest(polys, *e) for e in ents]
        # The spawn filter drops land and sea outside the dungeon - only a map
        # with terrain has any. A map that is one building (the Sunken
        # Temple) keeps everything: its long stairs have no creatures near
        # them, and the filter cut its levels apart.
        full = navmesh.reachable(polys, starts)
        full_area = sum(p.area2d() for p in full)
        near = {p.idx for p in polys}
        if materials.tiles_of(materials.map_dir(map_id)):
            # Within 45 yards of a creature or object, 25 up or down; where
            # that leaves under a fifth of the dungeon (Ahn'Qiraj's long
            # empty approach cut it off at the door), 90 and 40.
            pts = spawn_points(map_id) + ents
            for reach_yd, rise in ((45.0, 25.0), (90.0, 40.0)):
                near = {p.idx for p in near_spawns(polys, pts, reach_yd, rise)}
                # connectivity inside the kept set only
                ids = set()
                stack = [s.idx for s in starts if s and s.idx in near]
                while stack:
                    i = stack.pop()
                    if i in ids:
                        continue
                    ids.add(i)
                    stack.extend(n for n in polys[i].nb if n in near and n not in ids)
                if sum(polys[i].area2d() for i in ids) >= 0.2 * full_area:
                    break
        for p in polys:
            p.nb = [n for n in p.nb if n in near]
        reach = [p for p in navmesh.reachable(polys, starts) if p.idx in near]
        for old in glob.glob(os.path.join(ADDON, "maps", f"{map_id}_*.blp")):
            os.remove(old)                  # this map's tiles from an earlier run (floor count may change)
        # wings, then floors within each; every floor of a wing shares its frame
        fl, wing_of, frames = [], [], []
        for wi, comp in enumerate(components(reach)):
            ids = {p.idx for p in comp}
            for fp in floors(comp, [s for s in starts if s and s.idx in ids] or [comp[0]]):
                fl.append(fp)
                wing_of.append(wi)
            frames.append(bounds(comp))
        kept = [p for fp in fl for p in fp]
        bs = bosses(map_id)
        cells = lookup(fl)
        floor_of = {p.idx: i for i, fp in enumerate(fl) for p in fp}
        src = None if a.plain else materials.Source(map_id)
        out = [f"-- map {map_id}", f"GuideDungeonMaps[{map_id}] = {{", f"    name = {lua_str(name)},",
               f"    outside = {lua_str(OUTSIDE.get(map_id, ''))},", "    floors = {"]
        web = {"map": map_id, "name": name, "floors": [], "bosses": [], "entrances": [], "cell": LOOK, "cells": {}}
        for fi, fp in enumerate(fl):
            b = frames[wing_of[fi]]
            others = [p for g, o in enumerate(fl) if g != fi and wing_of[g] == wing_of[fi] for p in o]
            img, outline = draw(fp, others, b, map_id * 10 + fi, src)
            write_tiles(img, os.path.join(ADDON, "maps", f"{map_id}_{fi + 1}_"))
            if a.web:
                os.makedirs(a.web, exist_ok=True)
                img.crop((0, 0, W, H)).save(os.path.join(a.web, f"{map_id}_{fi + 1}.webp"), quality=86, method=6)
            if a.preview:
                os.makedirs(a.preview, exist_ok=True)
                dbg = img.crop((0, 0, W, H))
                dd = ImageDraw.Draw(dbg)
                for bo in bs:
                    u, v = to_px(b, bo["x"], bo["y"])
                    dd.ellipse((u - 5, v - 5, u + 5, v + 5), fill=(200, 30, 30))
                    dd.text((u + 7, v - 6), f"{bo['order']} {bo['name']} z{bo['z']:.0f}", fill=(255, 255, 255))
                for e in ents:
                    u, v = to_px(b, e[0], e[1])
                    dd.ellipse((u - 5, v - 5, u + 5, v + 5), fill=(30, 200, 30))
                dbg.save(os.path.join(a.preview, f"{map_id}_{fi + 1}.png"))
            zs = sorted(p.z for p in fp)
            # the outline for the layer stack: which cells of the frame hold ground
            o = np.asarray(outline)
            shape = "".join("1" if o[j, i] > 40 else "0" for j in range(SY) for i in range(SX))
            area = sum(p.area2d() for p in fp)
            out.append(f"        {{ wing = {wing_of[fi] + 1}, left = {b['left']:.1f}, right = {b['right']:.1f}, "
                       f"top = {b['top']:.1f}, bottom = {b['bottom']:.1f}, z = {zs[len(zs) // 2]:.1f}, "
                       f"area = {area:.0f}, w = {SX}, shape = \"{shape}\" }},")
            web["floors"].append(dict(wing=wing_of[fi] + 1, z=round(zs[len(zs) // 2], 1), area=round(area),
                                      w=SX, shape=shape, img=f"{map_id}_{fi + 1}.webp",
                                      **{k: round(v, 1) for k, v in b.items()}))
            print(f"  wing {wing_of[fi] + 1} floor {fi + 1}: {len(fp)} polygons, {area:.0f} sq yd, "
                  f"z {zs[0]:.0f}..{zs[-1]:.0f}", file=sys.stderr)
        out.append("    },")
        out.append("    bosses = {")
        for bo in bs:
            p = navmesh.nearest(kept, bo["x"], bo["y"], bo["z"])
            f = floor_of.get(p.idx, 0) + 1 if p else 1
            out.append(f"        {{ {bo['order']}, {lua_str(bo['name'])}, {bo['x']:.1f}, {bo['y']:.1f}, "
                       f"{bo['z']:.1f}, {f}, {bo['guid']} }},")
            web["bosses"].append(dict(bo, floor=f))
        out.append("    },")
        out.append("    entrances = {")
        for e, s0 in zip(ents, starts):
            f = floor_of.get(s0.idx, 0) + 1 if s0 else 1
            out.append(f"        {{ {e[0]:.1f}, {e[1]:.1f}, {e[2]:.1f}, {f} }},")
            web["entrances"].append(dict(x=e[0], y=e[1], z=e[2], floor=f))
        out.append("    },")
        # 8-yard cells: each floor's ground there, lowest and highest. The
        # addon reads the floor you stand on from it (by your height, keeping
        # the floor you were on while it still fits - no flipping on a ramp),
        # and a click sends the server the clicked floor's height there.
        # One string, not a table of ~100,000 entries (7 MB in Wow.exe for
        # all the dungeons, mele 2026-11-22): "i,j=f,lo,hi;f,lo,hi|..."; the
        # addon unpacks only the dungeon you are in.
        out.append(f"    cell = {LOOK:.0f},")
        packed = "|".join(f"{i},{j}=" + ";".join(f"{f + 1},{lo:.0f},{hi:.0f}" for f, (lo, hi) in sorted(fs.items()))
                          for (i, j), fs in sorted(cells.items()))
        out.append(f"    packed = \"{packed}\",")
        for (i, j), fs in sorted(cells.items()):
            web["cells"][f"{i},{j}"] = ";".join(f"{f + 1},{lo:.0f},{hi:.0f}" for f, (lo, hi) in sorted(fs.items()))
        out.append("}")
        blocks[str(map_id)] = "\n".join(out[1:]) + "\n"
        if a.web:
            import json
            with open(os.path.join(a.web, f"{map_id}.json"), "w") as f:
                json.dump(web, f, separators=(",", ":"))
    with open(datafile, "w") as f:
        f.write("-- Written by tools/make_dungeon_maps.py from the server's navmesh. Do not edit.\n")
        f.write("GuideDungeonMaps = GuideDungeonMaps or {}\n\n")
        for k in sorted(blocks, key=int):
            f.write(f"-- map {k}\n{blocks[k]}-- end {k}\n\n")


if __name__ == "__main__":
    main()
