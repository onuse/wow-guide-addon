--[[
Guide - directions and notes from Claude.

The server knows where everyone is, inside dungeons too, where the 3.3.5
client has no map coordinates and TomTom goes blind. So the server works out
the way and once a second tells this addon, in a hidden addon whisper, how far
it is and which world heading to follow. Between those messages the arrows
follow your own turning, from GetPlayerFacing(), so they stay smooth.

Outdoors it is a compass, straight at the target like TomTom. In a dungeon it
follows the corridors (the navmesh route) and looks different - a ring round
a cyan arrow - so it is never mistaken for a straight line.

Three places show it:
  - the big arrow, near the top of the screen (drag it; /guide lock)
  - the minimap button, whose icon IS a little arrow while you are being
    guided - a compass on the minimap's edge. Left-click: the Claude panel.
    Right-click: options menu (big arrow, lock, reset, clear notes). Drag it round
    the minimap.
  - the Claude panel: where you are headed, and a log of what Claude has told
    you, kept between sessions so directions do not scroll out of chat.

Only messages FROM the character Claude are read. The server fills in the
sender of a whisper, so nobody else can steer this.

Wire format (prefix "Guide", tab-separated):
  A <yards> <angle> <mode> <label> <leg>
                     angle: world heading, radians, 0 = north, anticlockwise -
                     the frame GetPlayerFacing uses. mode: compass (outdoors),
                     route (dungeon corridors; leg = yards to the next turn),
                     lost (dungeon, no way found: straight line),
                     flight (on a flight path; nothing to steer until landing)
  P <indoor> <n,w;n,w;...>
                     minimap dots for the other targets (a hunt's other live
                     ones, the rest of a list of spots): yards north and west
                     of you. Empty = none.
  D <label>          arrived
  X <reason>         stopped
  N <text>           a note for the panel
  T <text>           test
  U <version> <note> a newer Guide is out: the panel and chat say so
  Q                  say hello again
  M <text>           a one-off line for chat (a /way the server could not place)

And back, to the server:
  W <zone> <x> <y> <label>   /way (zone empty = the one you are in)
  S                  /way reset
  H <version>        hello, on entering the world and on Q. Whispered to
                     yourself, so it works whether Claude is online or not;
                     the server reads it on the way past. This is how Claude
                     knows which version you run, and sees when an update
                     has been installed.

/way [zone] x y [label]   guide me to a map spot (TomTom's format; /gway
                          if TomTom is installed and keeps /way)
/way reset                stop
/guide          the Claude panel
/guide arrow    big arrow on/off
/guide lock     lock or unlock the big arrow's position
/guide log      print the last raw messages (testing)
]]

local PREFIX, TRUSTED = "Guide", "Claude"
-- Here, not only in the .toc: the client reads a .toc once, at start, so after
-- a /reload over new files GetAddOnMetadata would still give the old version.
local VERSION = "0.5.4"
local STALE = 5          -- seconds without an A message before guidance lapses
local MAX_NOTES = 100

GuideDB = GuideDB or {}

local function db()
    GuideDB.log = GuideDB.log or {}
    GuideDB.notes = GuideDB.notes or {}
    if GuideDB.locked == nil then GuideDB.locked = false end
    if GuideDB.bigArrow == nil then GuideDB.bigArrow = true end
    if GuideDB.buttonAngle == nil then GuideDB.buttonAngle = 200 end
    if GuideDB.coordBox == nil then GuideDB.coordBox = true end
    return GuideDB
end

local function say(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffGuide:|r " .. text)
end

local function remember(msg)
    local log = db().log
    table.insert(log, date("%H:%M:%S") .. " " .. msg)
    while #log > 30 do table.remove(log, 1) end
end

-- Turn a texture anticlockwise by `a` radians. Each corner of the frame
-- samples the texture at that corner turned back by -a (texture v runs down).
local function rotate(tex, a)
    local c, s = math.cos(a), math.sin(a)
    local function uv(x, y)
        local qx, qy = x * c + y * s, -x * s + y * c
        return 0.5 + qx, 0.5 - qy
    end
    local ulx, uly = uv(-0.5, 0.5)
    local llx, lly = uv(-0.5, -0.5)
    local urx, ury = uv(0.5, 0.5)
    local lrx, lry = uv(0.5, -0.5)
    tex:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
end

local function tint(tex, mode, off)
    if mode == "flight" then tex:SetVertexColor(0.6, 0.6, 0.6); return end
    if mode == "route" then                                         -- cool on a path
        if off < 0.26 then tex:SetVertexColor(0.3, 1, 1)
        elseif off < 1.57 then tex:SetVertexColor(0.35, 0.6, 1)
        else tex:SetVertexColor(0.75, 0.4, 1) end
    else                                                            -- warm on a compass
        if off < 0.26 then tex:SetVertexColor(0.3, 1, 0.3)         -- within ~15 degrees
        elseif off < 1.57 then tex:SetVertexColor(1, 0.85, 0.2)
        else tex:SetVertexColor(1, 0.35, 0.3) end
    end
end

local state = { heading = nil, yards = nil, mode = nil, label = "", leg = 0, seen = 0 }
local refreshPanel      -- defined with the panel below
local dots, dotPool = {}, {}   -- minimap dots: {north, west} yards from you
local clearDots         -- defined with the dots below
local coordText         -- defined with the coordinate box below
local setCoordBox       -- likewise

-- The big arrow ---------------------------------------------------------------

local frame = CreateFrame("Frame", "GuideArrowFrame", UIParent)
frame:SetWidth(56); frame:SetHeight(84)
frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) if not db().locked then self:StartMoving() end end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    db().point = { p, rp, x, y }
end)
frame:Hide()

local arrow = frame:CreateTexture(nil, "OVERLAY")
arrow:SetWidth(56); arrow:SetHeight(56)
arrow:SetPoint("TOP")
-- The minimap's own player arrow: it ships with every client and points up.
arrow:SetTexture("Interface\\Minimap\\MinimapArrow")

-- Route mode looks different on purpose: a ring round the arrow says "this
-- points along the corridors, not at the target".
local ring = frame:CreateTexture(nil, "ARTWORK")
ring:SetWidth(78); ring:SetHeight(78)
ring:SetPoint("CENTER", arrow, "CENTER", 0, 0)
ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
ring:SetTexCoord(0, 0.6, 0, 0.6)
ring:Hide()

local dist = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
dist:SetPoint("TOP", arrow, "BOTTOM", 0, 0)
local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
label:SetPoint("TOP", dist, "BOTTOM", 0, -1)
local turn = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
turn:SetPoint("TOP", label, "BOTTOM", 0, -1)

-- The minimap button: a compass on the minimap's edge ---------------------------

local button = CreateFrame("Button", "GuideMinimapButton", Minimap)
button:SetWidth(31); button:SetHeight(31)
button:SetFrameStrata("MEDIUM"); button:SetFrameLevel(8)
button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
button:RegisterForDrag("LeftButton")
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local buttonBg = button:CreateTexture(nil, "BACKGROUND")
buttonBg:SetWidth(20); buttonBg:SetHeight(20)
buttonBg:SetPoint("CENTER", 0, 1)
buttonBg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

local buttonIcon = button:CreateTexture(nil, "ARTWORK")
buttonIcon:SetWidth(20); buttonIcon:SetHeight(20)
buttonIcon:SetPoint("CENTER", 0, 1)

local buttonBorder = button:CreateTexture(nil, "OVERLAY")
buttonBorder:SetWidth(53); buttonBorder:SetHeight(53)
buttonBorder:SetPoint("TOPLEFT")
buttonBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local function idleIcon()
    buttonIcon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
    buttonIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    buttonIcon:SetVertexColor(1, 1, 1)
    buttonIcon:SetWidth(20); buttonIcon:SetHeight(20)
end
idleIcon()

local function placeButton()
    local a = math.rad(db().buttonAngle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
end

button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local s = Minimap:GetEffectiveScale()
        db().buttonAngle = math.deg(math.atan2(cy / s - my, cx / s - mx))
        placeButton()
    end)
end)
button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    -- name left, version right, actions in green: the common addon look
    -- (Skada's, which Jonas pointed at, 2026-10-11)
    GameTooltip:AddDoubleLine("Guide", VERSION, 1, 0.82, 0, 0.1, 1, 0.1)
    if state.heading then
        GameTooltip:AddLine(string.format("%s - %d yd", state.label ~= "" and state.label or "guiding", state.yards or 0), 1, 1, 1)
    end
    GameTooltip:AddDoubleLine(GetZoneText(), coordText() or "no map here", 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddLine("|cff20ff20Left-Click|r to open the Claude panel.", 1, 1, 1)
    GameTooltip:AddLine("|cff20ff20Right-Click|r to open the menu.", 1, 1, 1)
    GameTooltip:AddLine("|cff20ff20Drag|r to move the button.", 1, 1, 1)
    GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- One clock for both arrows ---------------------------------------------------

local function guiding()
    return state.heading and GetTime() - state.seen <= STALE
end

local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function()
    if not state.heading then return end
    if not guiding() then
        state.heading = nil
        frame:Hide(); idleIcon()
        if refreshPanel then refreshPanel() end
        return
    end
    local rel = state.heading - (GetPlayerFacing() or 0)
    rel = math.fmod(rel + 3 * math.pi, 2 * math.pi) - math.pi     -- -pi..pi, + is to the left
    local off = math.abs(rel)
    rotate(arrow, rel); tint(arrow, state.mode, off)
    rotate(buttonIcon, rel); tint(buttonIcon, state.mode, off)
end)

-- The Claude panel --------------------------------------------------------------

local panel = CreateFrame("Frame", "GuidePanel", UIParent)
panel:SetWidth(340); panel:SetHeight(300)
panel:SetPoint("RIGHT", UIParent, "RIGHT", -60, 40)
-- A plain dark fill under the dialog border: the stock dialog background is
-- see-through enough that small text was hard to read over bright Booty Bay
-- wood (mele's test, 2026-10-10).
panel:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 16, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
panel:SetBackdropColor(0.05, 0.05, 0.07, 0.9)
panel:SetMovable(true); panel:EnableMouse(true); panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
panel:SetFrameStrata("MEDIUM")
panel:Hide()
tinsert(UISpecialFrames, "GuidePanel")          -- Escape closes it

local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -18)
title:SetText("Claude")

local versionText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
versionText:SetPoint("BOTTOMRIGHT", -16, 14)
versionText:SetText("Guide " .. VERSION)

local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)

local updateLine = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
updateLine:SetPoint("BOTTOMLEFT", 22, 16)     -- under the notes; wraps upwards
updateLine:SetWidth(232); updateLine:SetJustifyH("LEFT")   -- leaves room for the version, bottom right
updateLine:SetTextColor(1, 0.5, 0.25)

local guideHead = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
guideHead:SetPoint("TOPLEFT", 22, -46)
guideHead:SetText("Guidance")
local guideLine = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
guideLine:SetPoint("TOPLEFT", guideHead, "BOTTOMLEFT", 0, -4)
guideLine:SetWidth(296); guideLine:SetJustifyH("LEFT")
local guideSub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
guideSub:SetPoint("TOPLEFT", guideLine, "BOTTOMLEFT", 0, -2)
guideSub:SetWidth(296); guideSub:SetJustifyH("LEFT")

local notesHead = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
notesHead:SetPoint("TOPLEFT", guideSub, "BOTTOMLEFT", 0, -12)   -- follows the guidance text down when it wraps
notesHead:SetText("From Claude")

local notes = CreateFrame("ScrollingMessageFrame", nil, panel)
notes:SetPoint("TOPLEFT", notesHead, "BOTTOMLEFT", 0, -6)
notes:SetPoint("BOTTOMRIGHT", -22, 44)
notes:SetFontObject(GameFontHighlightSmall)
notes:SetJustifyH("LEFT")
notes:SetFading(false)
notes:SetMaxLines(MAX_NOTES)
notes:SetInsertMode("TOP")     -- newest first, from the top: a short log does not sit in an empty well
notes:EnableMouseWheel(true)
notes:SetScript("OnMouseWheel", function(self, delta)
    if delta > 0 then self:ScrollUp() else self:ScrollDown() end
end)

-- "0.3.1" < "0.4.0"
local function older(a, b)
    local x, y = {}, {}
    for n in string.gmatch(a or "", "%d+") do table.insert(x, tonumber(n)) end
    for n in string.gmatch(b or "", "%d+") do table.insert(y, tonumber(n)) end
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p < q end
    end
    return false
end

local function updateText()
    local u = db().update
    if u and older(VERSION, u.version) then
        local note = u.note or ""
        if note ~= "" and not string.find(note, "[%.!?]$") then note = note .. "." end
        return string.format("Guide %s is out (you have %s)%s", u.version, VERSION,
            note ~= "" and (": " .. note) or ".")
    end
    db().update = nil          -- installed, or never newer
    return nil
end

refreshPanel = function()
    updateLine:SetText(updateText() or "")
    if guiding() then
        local where = state.label ~= "" and state.label or "a spot"
        -- a label that is already an instruction ("Fly from ...") gets no "To"
        local fmt = string.find(where, "^Fly ") and "%s: %d yd%s" or "To %s: %d yd%s"
        guideLine:SetText(string.format(fmt, where, state.yards or 0,
            state.mode == "route" and " by the way through" or ""))
        guideSub:SetText(state.mode == "flight" and "In flight - Guide picks up again when you land."
            or state.mode == "route"
            and (state.leg > 0 and string.format("Following the corridors - next turn in %d yd.", state.leg)
                 or "Following the corridors - straight on to the end.")
            or state.mode == "lost" and "No way through found - this is the straight line."
            or "Compass: straight at the target.")
        if #dots > 0 then
            guideSub:SetText(guideSub:GetText() .. string.format(" %d more on the minimap (stars).", #dots))
        end
    else
        guideLine:SetText("Not guiding right now.")
        guideSub:SetText("Whisper Claude \"guide me to ...\" and an arrow appears.")
    end
end

local function addNote(text, stamp)
    notes:AddMessage("|cff888888" .. stamp .. "|r " .. text)
end

panel:SetScript("OnShow", refreshPanel)

local function togglePanel()
    if panel:IsShown() then panel:Hide() else panel:Show() end
end

local function setBigArrow(on)
    db().bigArrow = on
    if on and guiding() then frame:Show() else frame:Hide() end
    say(on and "big arrow on." or "big arrow off - the minimap compass still points the way.")
end

-- Right-click menu: the settings live here, labeled, rather than behind a
-- bare toggle (Jonas, 2026-10-11: "more extendable, and easier to click on a
-- labeled option"). Same menu frame the game uses for unit portraits.
local menuFrame = CreateFrame("Frame", "GuideMenu", UIParent, "UIDropDownMenuTemplate")

StaticPopupDialogs["GUIDE_CLEAR_NOTES"] = {
    text = "Clear everything in the Claude panel's notes?",
    button1 = YES, button2 = NO,
    OnAccept = function()
        wipe(db().notes); notes:Clear()
        say("notes cleared.")
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

local function menuItems()
    return {
        { text = "Guide " .. VERSION, isTitle = true, notCheckable = true },
        { text = "Claude panel", notCheckable = true, func = togglePanel },
        { text = "Big arrow", checked = db().bigArrow,      -- a boolean: 3.3.5 menus take no functions here
          keepShownOnClick = true, func = function() setBigArrow(not db().bigArrow) end },
        { text = "Lock big arrow", checked = db().locked,
          keepShownOnClick = true, func = function() db().locked = not db().locked end },
        { text = "Show coordinates", checked = db().coordBox,
          keepShownOnClick = true, func = function() setCoordBox(not db().coordBox) end },
        { text = "Reset big arrow position", notCheckable = true, func = function()
            db().point = nil
            frame:ClearAllPoints(); frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
            say("big arrow back at the top of the screen.")
        end },
        { text = "Clear notes...", notCheckable = true, func = function() StaticPopup_Show("GUIDE_CLEAR_NOTES") end },
        { text = CLOSE, notCheckable = true, func = function() CloseDropDownMenus() end },
    }
end

button:SetScript("OnClick", function(self, which)
    if which == "RightButton" then
        GameTooltip:Hide()
        EasyMenu(menuItems(), menuFrame, "cursor", 0, 0, "MENU")
    else
        togglePanel()
    end
end)

-- Your coordinates --------------------------------------------------------
-- The zone map's own percentages, as /way takes them. The old dungeons have
-- no map, so nothing there. The world map is only switched to your zone
-- when it is closed, so this never moves a map you are looking at.

local function myCoords()
    if WorldMapFrame and WorldMapFrame:IsShown() then return nil end
    SetMapToCurrentZone()
    local x, y = GetPlayerMapPosition("player")
    if not x or (x == 0 and y == 0) then return nil end
    return x * 100, y * 100
end

coordText = function()
    local x, y = myCoords()
    if not x then return nil end
    return string.format("%.1f, %.1f", x, y)
end

-- The small coordinate box, like TomTom's: drag it anywhere; on or off from
-- the minimap button's menu.
local coordBox = CreateFrame("Frame", "GuideCoordBox", UIParent)
coordBox:SetWidth(90); coordBox:SetHeight(22)
coordBox:SetPoint("TOP", Minimap, "BOTTOM", 0, -14)
coordBox:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
coordBox:SetBackdropColor(0, 0, 0, 0.7)
coordBox:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.8)
coordBox:SetMovable(true); coordBox:EnableMouse(true); coordBox:RegisterForDrag("LeftButton")
coordBox:SetClampedToScreen(true)
coordBox:SetScript("OnDragStart", coordBox.StartMoving)
coordBox:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    db().coordPoint = { p, rp, x, y }
end)
coordBox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Your position on the zone map")
    GameTooltip:AddLine("|cff20ff20Drag|r to move. Hide it from the Guide button's menu.", 1, 1, 1)
    GameTooltip:Show()
end)
coordBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
local coordLabel = coordBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
coordLabel:SetPoint("CENTER")
local coordElapsed = 0
coordBox:SetScript("OnUpdate", function(self, elapsed)
    coordElapsed = coordElapsed + elapsed
    if coordElapsed < 0.5 then return end      -- each read resets the world map to your zone: not too often
    coordElapsed = 0
    coordLabel:SetText(coordText() or "--")
end)

setCoordBox = function(on)
    db().coordBox = on
    if on then coordBox:Show() else coordBox:Hide() end
end

-- Minimap dots ------------------------------------------------------------
-- The server sends where the other targets are as yards north and west of
-- you, once a second; they are drawn on the minimap at its current zoom (the
-- minimap shows a different number of yards indoors). No map coordinates
-- needed, so this works in dungeons too.

local MINIMAP_YARDS = {     -- minimap diameter in yards, by zoom level 0-5
    [false] = { 466.6667, 400, 333.3333, 266.6667, 200, 133.3333 },
    [true]  = { 300, 240, 180, 120, 80, 50 },
}
local dotsIndoor = false

-- Each dot is a small frame of its own above the minimap: a texture on the
-- Minimap frame itself is drawn under the map picture and never shows
-- (0.5.1, mele's hunt test).
local function dotTexture(i)
    local t = dotPool[i]
    if not t then
        t = CreateFrame("Frame", nil, Minimap)
        t:SetWidth(12); t:SetHeight(12)
        t:SetFrameLevel(Minimap:GetFrameLevel() + 10)   -- above the minimap's own buttons
        local tex = t:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")   -- the yellow star
        dotPool[i] = t
    end
    return t
end

clearDots = function()
    wipe(dots)
    for _, t in ipairs(dotPool) do t:Hide() end
end

local function drawDots()
    local diameter = MINIMAP_YARDS[dotsIndoor][(Minimap:GetZoom() or 0) + 1] or 466.6667
    local half = Minimap:GetWidth() / 2
    local scale = Minimap:GetWidth() / diameter
    local rotating = GetCVar("rotateMinimap") == "1"
    local a = rotating and (GetPlayerFacing() or 0) or 0
    local ca, sa = math.cos(a), math.sin(a)
    for i, d in ipairs(dots) do
        local east, north = -d[2], d[1]
        local x, y = east * ca + north * sa, -east * sa + north * ca   -- your facing up, if the minimap turns
        x, y = x * scale, y * scale
        local r = math.sqrt(x * x + y * y)
        local t = dotTexture(i)
        local rim = half - 16                               -- just inside the rim, clear of its buttons
        if r > rim then                                     -- off the minimap: at its edge, faded
            x, y = x * rim / r, y * rim / r
            t:SetAlpha(0.45)
        else
            t:SetAlpha(1)
        end
        t:ClearAllPoints(); t:SetPoint("CENTER", Minimap, "CENTER", x, y); t:Show()
    end
    for i = #dots + 1, #dotPool do dotPool[i]:Hide() end
end

local dotTicker = CreateFrame("Frame")
dotTicker:SetScript("OnUpdate", function() if #dots > 0 then drawDots() end end)

-- Messages ------------------------------------------------------------------

local function split(msg)
    local t = {}
    for field in string.gmatch(msg .. "\t", "([^\t]*)\t") do table.insert(t, field) end
    return t
end

local handlers = {}

handlers.A = function(f)
    local heading = tonumber(f[3])
    if not heading then return end
    state.yards, state.heading = tonumber(f[2]), heading
    state.mode, state.label, state.leg, state.seen = f[4], f[5] or "", tonumber(f[6]) or 0, GetTime()
    if state.mode == "flight" then
        dist:SetText("in flight")
        turn:SetText("picks up again when you land")
        ring:Hide()
    elseif state.mode == "route" then
        dist:SetText(string.format("%d yd by the way through", state.yards or 0))
        turn:SetText(state.leg > 0 and string.format("next turn in %d yd", state.leg) or "")
        ring:Show()
    else
        dist:SetText(string.format("%d yd", state.yards or 0))
        turn:SetText(state.mode == "lost" and "no way found - straight line" or "")
        ring:Hide()
    end
    label:SetText(state.label)
    buttonIcon:SetTexture("Interface\\Minimap\\MinimapArrow")
    buttonIcon:SetWidth(24); buttonIcon:SetHeight(24)
    if db().bigArrow then frame:Show() end
    if panel:IsShown() then refreshPanel() end
end

local function stopGuiding(text)
    state.heading = nil
    clearDots()
    frame:Hide(); idleIcon()
    if panel:IsShown() then refreshPanel() end
    say(text)
end

handlers.P = function(f)
    wipe(dots)
    dotsIndoor = f[2] == "1"
    for n, w in string.gmatch(f[3] or "", "(-?[%d%.]+),(-?[%d%.]+)") do
        table.insert(dots, { tonumber(n), tonumber(w) })
    end
    if #dots == 0 then clearDots() end
    if panel:IsShown() then refreshPanel() end
end

handlers.D = function(f)
    stopGuiding("arrived" .. ((f[2] and f[2] ~= "") and (" at " .. f[2]) or "") .. ".")
    PlaySound("MapPing")
end

handlers.X = function(f)
    stopGuiding("guidance stopped (" .. (f[2] or "") .. ").")
end

handlers.N = function(f)
    local text = f[2] or ""
    if text == "" then return end
    local stamp = date("%d/%m %H:%M")
    local list = db().notes
    table.insert(list, { stamp, text })
    while #list > MAX_NOTES do table.remove(list, 1) end
    addNote(text, stamp)
end

handlers.T = function(f)
    say("test from Claude: " .. (f[2] or ""))
end

handlers.M = function(f)
    say(f[2] or "")
end

local function hello()
    SendAddonMessage(PREFIX, "H\t" .. VERSION, "WHISPER", UnitName("player"))
end

handlers.Q = function() hello() end

handlers.U = function(f)
    if not older(VERSION, f[2]) then return end
    db().update = { version = f[2], note = f[3] or "" }
    say("|cffff8040" .. string.gsub(updateText(), "^Guide ", "version ", 1) .. "|r Copy the new Guide folder into Interface\\AddOns, then /reload.")
    if panel:IsShown() then refreshPanel() end
end

local events = CreateFrame("Frame")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if event == "PLAYER_LOGIN" then
        local p = db().point
        if p then frame:ClearAllPoints(); frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) end
        placeButton()
        local cp = db().coordPoint
        if cp then coordBox:ClearAllPoints(); coordBox:SetPoint(cp[1], UIParent, cp[2], cp[3], cp[4]) end
        setCoordBox(db().coordBox)
        if not IsAddOnLoaded("TomTom") then SLASH_GUIDEWAY2 = "/way" end
        for _, n in ipairs(db().notes) do addNote(n[2], n[1]) end
        if updateText() then say("|cffff8040" .. string.gsub(updateText(), "^Guide ", "version ", 1) .. "|r") end
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        hello()
        return
    end
    if prefix ~= PREFIX or channel ~= "WHISPER" or sender ~= TRUSTED then return end
    remember(msg)
    local f = split(msg)
    local h = handlers[f[1]]
    if h then h(f) end
end)

-- Slash command -------------------------------------------------------------

-- /way, TomTom's way: /way [zone] x y [label], commas allowed; /way reset.
-- The spot goes to the server, which guides you there like any other target
-- (inside dungeons and caves too). If TomTom is installed it keeps /way and
-- Guide answers to /gway only.
local function way(msg)
    msg = string.gsub(msg or "", ",", " ")
    local words = {}
    for w in string.gmatch(msg, "%S+") do table.insert(words, w) end
    if #words == 1 and string.lower(words[1]) == "reset" then
        SendAddonMessage(PREFIX, "S", "WHISPER", UnitName("player"))
        return
    end
    for i = 1, #words - 1 do
        local x, y = tonumber(words[i]), tonumber(words[i + 1])
        if x and y then
            local zone = table.concat(words, " ", 1, i - 1)
            local label = table.concat(words, " ", i + 2)
            SendAddonMessage(PREFIX, string.format("W\t%s\t%s\t%s\t%s", zone, x, y, label), "WHISPER", UnitName("player"))
            return
        end
    end
    say("usage: /way [zone] x y [label] - e.g. /way Dustwallow Marsh 42.8 72.4 Flight master - or /way reset")
end

SLASH_GUIDEWAY1 = "/gway"
SlashCmdList["GUIDEWAY"] = way

SLASH_GUIDE1 = "/guide"
SlashCmdList["GUIDE"] = function(arg)
    arg = string.lower(arg or "")
    if arg == "lock" then
        db().locked = not db().locked
        say(db().locked and "arrow locked." or "arrow unlocked - drag it where you like.")
    elseif arg == "arrow" then
        setBigArrow(not db().bigArrow)
    elseif arg == "log" then
        local log = db().log
        if #log == 0 then say("no messages yet.") end
        for i = math.max(1, #log - 9), #log do say(log[i]) end
    else
        togglePanel()
    end
end
