--[[
Guide - dungeon maps.

Jonas, 2026-11-22: "can Guide be evolved to handle the map (pressing M)
while in a dungeon?" The 3.3.5 client has maps of the Wrath dungeons only;
in the old ones M shows the zone outside, and the game gives no map position
there, for you or for your group. So Guide brings its own maps
(DungeonMaps.lua and maps\*.blp, drawn from the server's navmesh by
tools/make_dungeon_maps.py) and the server sends the positions.

On the map:
  - you (the arrow, turning as you turn), your group (class colours), the
    bosses (skulls, numbered in order; greyed once dead). Hover for names.
  - click anywhere on the ground: the arrow leads you there, through the
    corridors. Click a boss: the arrow leads to it. Right-click: the zone
    outside the dungeon; a button at the top brings the dungeon back.
  - where the dungeon has floors on top of each other, a stack of slabs in
    the corner, each one the floor's own shape. Yours pulses. Hover a slab
    to look at that floor; click it to keep it; click yours to go back.
    Group members on other floors show as dots on their slab.

Wire format (prefix "Guide"), added to the ones in Guide.lua:
  from the server:
    K <map>            the map you are on (after K from here, and on hello)
    Y <map> <x> <y> <z> <facing> <dead boss spawn ids>   while the map is open
    R <name>,<class>,<x>,<y>,<z>;...    your group in this instance (Y clears it)
  to the server:
    K                  which map am I on? (on every loading screen)
    I 1 <boss spawn ids> / I 0    the map opened / closed
    V <map> <x> <y> <z> <label>   guide me to this spot (z: the floor's ground there)
]]

local G = GuideCore
local MAPS = GuideDungeonMaps or {}
local W, H = 1002, 668
local ME = UnitName("player")

local function send(msg) SendAddonMessage("Guide", msg, "WHISPER", ME) end

local CLASS = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", nil, "DRUID" }

local curMap                -- from K / Y
local me                    -- { x, y, z, o } from the last Y
local group = {}            -- { name, class, x, y, z }
local dead = {}             -- spawn id -> true
local groupStale = false    -- a Y came: the next R starts the group list afresh
local myFloor, peek, pinned = 1, nil, false
local shownFloor, shownMap
local home                  -- the world map's continent/zone when it opened

-- Which floor a spot is on ------------------------------------------------
-- 8-yard cells list each floor's ground there (lowest, highest). The floor
-- you were on is kept while your height still fits it, so a ramp between two
-- floors does not flip the map back and forth.

local function unpackCells(m)
    if m.cells then return end
    m.cells = {}
    for key, val in string.gmatch(m.packed or "", "([^=|]+)=([^|]+)") do m.cells[key] = val end
end

local function cellFloors(m, x, y)
    unpackCells(m)
    local i, j = math.floor(x / m.cell), math.floor(y / m.cell)
    local s = m.cells[i .. "," .. j]
    if not s then
        for di = -1, 1 do
            for dj = -1, 1 do
                s = s or m.cells[(i + di) .. "," .. (j + dj)]
            end
        end
    end
    local out = {}
    if s then
        for f, lo, hi in string.gmatch(s, "(%d+),(-?%d+),(-?%d+)") do
            table.insert(out, { tonumber(f), tonumber(lo), tonumber(hi) })
        end
    end
    return out
end

local function floorAt(m, x, y, z, keep)
    local list = cellFloors(m, x, y)
    if #list == 0 then return keep or 1 end
    local best, bd = nil, 1e9
    for _, e in ipairs(list) do
        local d = (z < e[2] and e[2] - z) or (z > e[3] and z - e[3]) or 0
        if e[1] == keep and d < 6 then return keep end
        if d < bd then best, bd = e[1], d end
    end
    return best
end

-- The overlay -------------------------------------------------------------

local overlay = CreateFrame("Frame", "GuideDungeonOverlay", WorldMapButton)
overlay:SetAllPoints(WorldMapButton)
overlay:SetFrameLevel(WorldMapButton:GetFrameLevel() + 30)
overlay:EnableMouse(true)
overlay:Hide()

local tiles = {}
for k = 1, 12 do
    tiles[k] = overlay:CreateTexture(nil, "BACKGROUND")
end

local title = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", overlay, "TOP", 0, -10)
local hint = overlay:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", 10, 8)
hint:SetText("Click: guide me there.  Right-click: the zone outside.")

local function scale() return overlay:GetWidth() / W end

local function layout()
    local tw, th = overlay:GetWidth() * 256 / W, overlay:GetHeight() * 256 / H
    for k = 1, 12 do
        local t = tiles[k]
        t:SetWidth(tw); t:SetHeight(th)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", overlay, "TOPLEFT", ((k - 1) % 4) * tw, -math.floor((k - 1) / 4) * th)
    end
end
overlay:SetScript("OnSizeChanged", layout)

local function floorData() return MAPS[curMap] and MAPS[curMap].floors[shownFloor or 1] end

-- world (x north, y west) -> overlay offsets from TOPLEFT
local function toMap(x, y)
    local f = floorData()
    if not f then return 0, 0 end
    local u = (f.left - y) / (f.left - f.right)
    local v = (f.top - x) / (f.top - f.bottom)
    return u * overlay:GetWidth(), -v * overlay:GetHeight()
end

local function fromMap(px, py)
    local f = floorData()
    local u, v = px / overlay:GetWidth(), py / overlay:GetHeight()
    return f.top - v * (f.top - f.bottom), f.left - u * (f.left - f.right)
end

local function place(fr, x, y)
    local px, py = toMap(x, y)
    fr:ClearAllPoints()
    fr:SetPoint("CENTER", overlay, "TOPLEFT", px, py)
end

-- Markers -----------------------------------------------------------------

local function tip(fr, lines)
    fr:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        for i, l in ipairs(lines(self)) do
            if i == 1 then GameTooltip:SetText(l) else GameTooltip:AddLine(l, 1, 1, 1) end
        end
        GameTooltip:Show()
    end)
    fr:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local player = CreateFrame("Frame", nil, overlay)
player:SetWidth(28); player:SetHeight(28)
player:SetFrameLevel(overlay:GetFrameLevel() + 20)
local playerTex = player:CreateTexture(nil, "OVERLAY")
playerTex:SetAllPoints()
playerTex:SetTexture("Interface\\Minimap\\MinimapArrow")
player:Hide()

local bossButtons, partyDots = {}, {}

local function bossButton(i)
    local b = bossButtons[i]
    if b then return b end
    b = CreateFrame("Button", nil, overlay)
    b:SetWidth(22); b:SetHeight(22)
    b:SetFrameLevel(overlay:GetFrameLevel() + 10)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetAllPoints()
    b.tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
    b.num = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.num:SetPoint("TOP", b, "BOTTOM", 0, 1)
    b:RegisterForClicks("LeftButtonUp")
    tip(b, function(self)
        local l = { self.order .. ". " .. self.name }
        if dead[self.guid] then table.insert(l, "|cff999999defeated|r") end
        table.insert(l, "|cff20ff20Click|r: guide me there")
        return l
    end)
    b:SetScript("OnClick", function(self)
        send(string.format("V\t%d\t%.1f\t%.1f\t%.1f\t%s", curMap, self.x, self.y, self.z, self.name))
        G.say("arrow set: " .. self.name .. ".")
    end)
    bossButtons[i] = b
    return b
end

local function partyDot(i)
    local d = partyDots[i]
    if d then return d end
    d = CreateFrame("Frame", nil, overlay)
    d:SetWidth(18); d:SetHeight(18)
    d:SetFrameLevel(overlay:GetFrameLevel() + 15)
    d:EnableMouse(true)
    d.tex = d:CreateTexture(nil, "ARTWORK")
    d.tex:SetAllPoints()
    d.tex:SetTexture("Interface\\WorldMap\\WorldMapPartyIcon")
    tip(d, function(self)
        return { self.name, self.away and "|cff999999on another floor|r" or nil }
    end)
    partyDots[i] = d
    return d
end

local function classColor(c)
    local t = CLASS[c] and RAID_CLASS_COLORS and RAID_CLASS_COLORS[CLASS[c]]
    if t then return t.r, t.g, t.b end
    return 1, 1, 1
end

-- The layer stack ---------------------------------------------------------
-- One slab per floor, top floor at the top: the floor's own outline (30 x
-- 20 cells from the map data), each row shifted right a little further than
-- the one in front of it, so the slab lies tilted away like a floor seen from
-- above and in front. Rows are drawn as runs of cells, a texture per run.

local stack = CreateFrame("Frame", nil, overlay)
stack:SetFrameLevel(overlay:GetFrameLevel() + 25)
stack:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", -14, 14)
local slabs = {}
local CW, RH, SHEAR, GAP = 4, 1.7, 2.2, 30    -- cell width, row height, shift per row, slab spacing

-- A map can hold separate wings (the Monastery's four, each behind its own
-- door); each has its own frame and its own stack. rank[fi] = the floor's
-- place in its wing's stack, 1 = top.
local stackWing, rank, wingCount = nil, {}, 0

local function slabPoint(m, fi, cx, cy)        -- cell coords (0..w, 0..h, y down) -> stack offsets
    local f = m.floors[fi]
    local h = #f.shape / f.w
    local x = cx * CW + (h - cy) * SHEAR
    local y = (wingCount - rank[fi]) * GAP + (h - cy) * RH
    return x, y
end

local function buildStack(m, wing)
    for _, s in pairs(slabs) do s:Hide() end
    stackWing = wing
    wipe(rank)
    local list = {}
    for fi, f in ipairs(m.floors) do
        if (f.wing or 1) == wing then table.insert(list, fi); rank[fi] = #list end
    end
    wingCount = #list
    if #list < 2 then stack:Hide(); return end
    local n = #list
    local w0 = m.floors[list[1]].w
    local h0 = #m.floors[list[1]].shape / w0
    stack:SetWidth(w0 * CW + h0 * SHEAR + 4)
    stack:SetHeight((n - 1) * GAP + h0 * RH + 4)
    for k = n, 1, -1 do                         -- bottom first: the floors above overlap it
        local fi = list[k]
        local f = m.floors[fi]
        local s = slabs[fi]
        if not s then
            s = CreateFrame("Button", nil, stack)
            s.runs, s.plates = {}, {}
            slabs[fi] = s
        end
        s:SetFrameLevel(stack:GetFrameLevel() + (n - k) + 1)
        for _, t in ipairs(s.runs) do t:Hide() end
        for _, t in ipairs(s.plates) do t:Hide() end
        local h = #f.shape / f.w
        local nr, np = 0, 0
        for row = 0, h - 1 do
            -- the plate: the whole row, faint
            np = np + 1
            local p = s.plates[np] or s:CreateTexture(nil, "BACKGROUND")
            s.plates[np] = p
            local x, y = slabPoint(m, fi, 0, row + 1)
            p:SetTexture(0, 0, 0, 0.45)
            p:SetWidth(f.w * CW); p:SetHeight(RH + 0.3)
            p:ClearAllPoints(); p:SetPoint("BOTTOMLEFT", stack, "BOTTOMLEFT", x, y); p:Show()
            -- the ground: runs of filled cells
            local c = 0
            while c < f.w do
                if string.sub(f.shape, row * f.w + c + 1, row * f.w + c + 1) == "1" then
                    local c2 = c
                    while c2 < f.w and string.sub(f.shape, row * f.w + c2 + 1, row * f.w + c2 + 1) == "1" do c2 = c2 + 1 end
                    nr = nr + 1
                    local t = s.runs[nr] or s:CreateTexture(nil, "ARTWORK")
                    s.runs[nr] = t
                    local rx, ry = slabPoint(m, fi, c, row + 1)
                    t:SetTexture(1, 1, 1, 1)
                    t:SetWidth((c2 - c) * CW); t:SetHeight(RH + 0.3)
                    t:ClearAllPoints(); t:SetPoint("BOTTOMLEFT", stack, "BOTTOMLEFT", rx, ry); t:Show()
                    c = c2
                else
                    c = c + 1
                end
            end
        end
        s.nr = nr
        -- the slab's hit box: its bounding box
        local x0, y0 = slabPoint(m, fi, 0, h)
        s:ClearAllPoints()
        s:SetPoint("BOTTOMLEFT", stack, "BOTTOMLEFT", x0, y0)
        s:SetWidth(f.w * CW + h * SHEAR); s:SetHeight(h * RH)
        s.floor = fi
        s:SetScript("OnEnter", function(self)
            if not pinned then peek = self.floor end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText(self.floor == myFloor and "Your floor" or "Another floor")
            GameTooltip:AddLine(self.floor == myFloor and "You are here." or "|cff20ff20Click|r to keep it on the map.", 1, 1, 1)
            GameTooltip:Show()
        end)
        s:SetScript("OnLeave", function()
            if not pinned then peek = nil end
            GameTooltip:Hide()
        end)
        s:SetScript("OnClick", function(self)
            if self.floor == myFloor then pinned, peek = false, nil
            else pinned, peek = true, self.floor end
        end)
        s:Show()
    end
    stack:Show()
end

-- small dots on the slabs: you, and group members on their own floors
local slabDots = {}
local dotLayer = CreateFrame("Frame", nil, stack)       -- above every slab
dotLayer:SetAllPoints(stack)
dotLayer:SetFrameLevel(stack:GetFrameLevel() + 20)
local function slabDot(i)
    local d = slabDots[i]
    if not d then
        d = dotLayer:CreateTexture(nil, "OVERLAY")
        d:SetWidth(4); d:SetHeight(4)
        slabDots[i] = d
    end
    return d
end

local function drawSlabDots(m)
    local n = 0
    local function dot(x, y, z, fi, r, g, b)
        local f = m.floors[fi]
        if not f or not rank[fi] then return end      -- another wing
        local u = (f.left - y) / (f.left - f.right) * f.w
        local v = (f.top - x) / (f.top - f.bottom) * (#f.shape / f.w)
        local px, py = slabPoint(m, fi, u, v)
        n = n + 1
        local d = slabDot(n)
        d:SetTexture(r, g, b, 1)
        d:ClearAllPoints(); d:SetPoint("CENTER", stack, "BOTTOMLEFT", px, py)
        d:Show()
    end
    if me then dot(me.x, me.y, me.z, myFloor, 1, 0.82, 0) end
    for _, p in ipairs(group) do
        dot(p.x, p.y, p.z, p.floor, classColor(p.class))
    end
    for i = n + 1, #slabDots do slabDots[i]:Hide() end
end

-- Drawing -----------------------------------------------------------------

local function showFloor(fi)
    if shownFloor == fi and shownMap == curMap then return end
    shownFloor, shownMap = fi, curMap
    for k = 1, 12 do
        tiles[k]:SetTexture("Interface\\AddOns\\Guide\\maps\\" .. curMap .. "_" .. fi .. "_" .. k)
    end
end

local function refresh()
    local m = MAPS[curMap]
    if not m then return end
    local want = peek or myFloor
    showFloor(want)
    local wing = m.floors[want].wing or 1
    if wing ~= stackWing then buildStack(m, wing) end
    -- bosses on the floor shown
    local nb = 0
    for _, bo in ipairs(m.bosses) do
        if bo[6] == want then
            nb = nb + 1
            local b = bossButton(nb)
            b.order, b.name, b.x, b.y, b.z, b.guid = bo[1], bo[2], bo[3], bo[4], bo[5], bo[7]
            b.num:SetText(bo[1])
            b.tex:SetDesaturated(dead[bo[7]] and true or false)
            b:SetAlpha(dead[bo[7]] and 0.55 or 1)
            place(b, bo[3], bo[4])
            b:Show()
        end
    end
    for i = nb + 1, #bossButtons do bossButtons[i]:Hide() end
    -- group
    for i, p in ipairs(group) do
        local d = partyDot(i)
        d.name, d.away = p.name, p.floor ~= want
        d.tex:SetVertexColor(classColor(p.class))
        d:SetAlpha(d.away and 0.35 or 1)
        place(d, p.x, p.y)
        if (m.floors[p.floor].wing or 1) == wing then d:Show() else d:Hide() end
    end
    for i = #group + 1, #partyDots do partyDots[i]:Hide() end
    -- you
    if me and (m.floors[myFloor].wing or 1) == wing then
        player:SetAlpha(want == myFloor and 1 or 0.35)
        place(player, me.x, me.y)
        player:Show()
    else
        player:Hide()
    end
    if stack:IsShown() then
        for fi, s in pairs(slabs) do
            if s:IsShown() then
                local a = (fi == want) and 1 or 0.45
                for r = 1, s.nr or 0 do
                    local t = s.runs[r]
                    if fi == myFloor then t:SetVertexColor(1, 0.85, 0.45) else t:SetVertexColor(0.85, 0.78, 0.62) end
                    t:SetAlpha(a)
                end
            end
        end
        drawSlabDots(m)
    end
end

-- your floor pulses slowly; your arrow turns with you between updates
overlay:SetScript("OnUpdate", function()
    local f = GetPlayerFacing and GetPlayerFacing()
    if f then G.rotate(playerTex, f) end
    local s = slabs[myFloor]
    if s and s:IsShown() and stack:IsShown() then
        local a = 0.6 + 0.4 * math.sin(GetTime() * 2.5)
        if (peek or myFloor) ~= myFloor then a = a * 0.6 end
        for r = 1, s.nr or 0 do s.runs[r]:SetAlpha(a) end
    end
end)

-- Clicks ------------------------------------------------------------------

-- Right-click: out to the zone the dungeon is in (Jonas, 2026-11-22: "zoom
-- out would just jump to the original outer zone map") - the map under the
-- overlay already is that zone, so the overlay steps aside, and a button
-- brings it back. The next M opens on the dungeon again.
local away = false
local back = CreateFrame("Button", nil, WorldMapButton, "UIPanelButtonTemplate")
back:SetFrameLevel(WorldMapButton:GetFrameLevel() + 40)
back:SetHeight(22)
back:SetPoint("TOPLEFT", WorldMapButton, "TOPLEFT", 8, -8)
back:Hide()
local update

overlay:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
        away = true
        overlay:Hide()
        local m = MAPS[curMap]
        -- the zone outside, by name: Wow.exe sits on the continent map inside
        -- a dungeon, so "the map under the overlay" is not that zone
        if m and m.outside and m.outside ~= "" then
            for c = 1, 2 do
                for i, z in ipairs({ GetMapZones(c) }) do
                    if z == m.outside then SetMapZoom(c, i) end
                end
            end
        end
        if m then
            back:SetText("Back to " .. m.name)
            local fs = back:GetFontString()
            back:SetWidth((fs and fs:GetStringWidth() or 120) + 24)
            back:Show()
        end
        return
    end
    if button ~= "LeftButton" then return end
    local m = MAPS[curMap]
    local fi = peek or myFloor
    local cx, cy = GetCursorPosition()
    local s = self:GetEffectiveScale()
    local x, y = fromMap(cx / s - self:GetLeft(), self:GetTop() - cy / s)
    local z
    for _, e in ipairs(cellFloors(m, x, y)) do
        if e[1] == fi then z = (e[2] + e[3]) / 2 end
    end
    if not z then
        G.say("no ground there on this floor.")
        return
    end
    send(string.format("V\t%d\t%.1f\t%.1f\t%.1f\t%s", curMap, x, y, z, m.name .. " map"))
    G.say("arrow set.")
end)

-- Showing and hiding ------------------------------------------------------
-- Shown when the world map opens on the zone you are in (the one outside
-- the dungeon) and Guide has a map of this dungeon; hidden as soon as the
-- map is moved elsewhere (zoomed out, another zone picked), back when it
-- returns.

local function bossIds(m)
    local t = {}
    for _, bo in ipairs(m.bosses) do table.insert(t, bo[7]) end
    return table.concat(t, ",")
end

update = function()
    local m = MAPS[curMap]
    local inside = IsInInstance()
    if not (m and inside and WorldMapFrame:IsShown() and home) then overlay:Hide(); back:Hide(); return end
    if away then
        overlay:Hide()
        back:Show()             -- until the map is closed or the button used
        return
    end
    if GetCurrentMapContinent() == home[1] and GetCurrentMapZone() == home[2] then
        -- Wow.exe sits on the continent inside a dungeon, and Blizzard's zone
        -- dropdown keeps the last zone's name there ("Westfall" in Blackrock
        -- Depths after a right-click in the Deadmines, mele 2026-11-22)
        if GetCurrentMapZone() == 0 and WorldMapZoneDropDown and UIDropDownMenu_ClearAll then
            UIDropDownMenu_ClearAll(WorldMapZoneDropDown)
        end
        if not overlay:IsShown() then
            title:SetText(m.name)
            layout()
            stackWing = nil
            overlay:Show()
            refresh()
        end
    else
        overlay:Hide()
    end
end

overlay:SetScript("OnShow", function()
    local m = MAPS[curMap]
    if m then send("I\t1\t" .. bossIds(m)) end
end)
overlay:SetScript("OnHide", function()
    send("I\t0")
    peek, pinned = nil, false
end)

WorldMapFrame:HookScript("OnShow", function()
    home = { GetCurrentMapContinent(), GetCurrentMapZone() }
    update()
end)
WorldMapFrame:HookScript("OnHide", function()
    -- a right-click picked the zone outside: put the map back on where you
    -- are, or it opens on that zone in the next dungeon (mele, 2026-11-22)
    if away then SetMapToCurrentZone() end
    home = nil; away = false; overlay:Hide(); back:Hide()
end)
back:SetScript("OnClick", function()
    away = false
    back:Hide()
    if home and (GetCurrentMapContinent() ~= home[1] or GetCurrentMapZone() ~= home[2]) then
        SetMapToCurrentZone()       -- WORLD_MAP_UPDATE calls update()
    else
        update()
    end
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("WORLD_MAP_UPDATE")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        me, group, dead = nil, {}, {}
        myFloor, peek, pinned, shownFloor = 1, nil, false, nil
        send("K")
        return
    end
    if WorldMapFrame:IsShown() then update() end
end)

-- Messages ----------------------------------------------------------------

G.handlers.K = function(f)
    local id = tonumber(f[2])
    if id ~= curMap then
        if MAPS[curMap] then MAPS[curMap].cells = nil end      -- only the dungeon you are in is unpacked
        curMap = id
        me, group, dead = nil, {}, {}
        myFloor, shownFloor = 1, nil
        if WorldMapFrame:IsShown() then overlay:Hide(); update() end
    end
end

G.handlers.Y = function(f)
    local id = tonumber(f[2])
    if id ~= curMap then G.handlers.K({ "K", f[2] }) end
    local m = MAPS[curMap]
    if not m then return end
    me = { x = tonumber(f[3]), y = tonumber(f[4]), z = tonumber(f[5]), o = tonumber(f[6]) }
    myFloor = floorAt(m, me.x, me.y, me.z, myFloor)
    if pinned and peek == myFloor then pinned, peek = false, nil end
    wipe(dead)
    for id in string.gmatch(f[7] or "", "%d+") do dead[tonumber(id)] = true end
    groupStale = true
    if overlay:IsShown() then refresh() end
end

G.handlers.R = function(f)
    local m = MAPS[curMap]
    if not m then return end
    if groupStale then wipe(group); groupStale = false end
    for name, c, x, y, z in string.gmatch(f[2] or "", "([^,;]+),(%d+),(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)") do
        local p = { name = name, class = tonumber(c), x = tonumber(x), y = tonumber(y), z = tonumber(z) }
        p.floor = floorAt(m, p.x, p.y, p.z, nil)
        table.insert(group, p)
    end
    if overlay:IsShown() then refresh() end
end

-- /guide map: what Guide knows here (testing)
G.mapStatus = function()
    local m = MAPS[curMap]
    if not m then return "no Guide map for map " .. tostring(curMap) .. "." end
    return string.format("%s (map %d), %d floor(s); you are on floor %d%s.", m.name, curMap, #m.floors, myFloor,
        me and string.format(" at %.0f, %.0f, %.0f", me.x, me.y, me.z) or ", position not received yet (open the map)")
end
