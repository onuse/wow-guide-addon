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
    Right-click: big arrow on/off. Drag it round the minimap.
  - the Claude panel: where you are headed, and a log of what Claude has told
    you, kept between sessions so directions do not scroll out of chat.

Only messages FROM the character Claude are read. The server fills in the
sender of a whisper, so nobody else can steer this.

Wire format (prefix "Guide", tab-separated):
  A <yards> <angle> <mode> <label> <leg>
                     angle: world heading, radians, 0 = north, anticlockwise -
                     the frame GetPlayerFacing uses. mode: compass (outdoors),
                     route (dungeon corridors; leg = yards to the next turn),
                     lost (dungeon, no way found: straight line)
  D <label>          arrived
  X <reason>         stopped
  N <text>           a note for the panel
  T <text>           test
  U <version> <note> a newer Guide is out: the panel and chat say so
  Q                  say hello again

And back, to the server:
  H <version>        hello, on entering the world and on Q. Whispered to
                     yourself, so it works whether Claude is online or not;
                     the server reads it on the way past. This is how Claude
                     knows which version you run, and sees when an update
                     has been installed.

/guide          the Claude panel
/guide arrow    big arrow on/off
/guide lock     lock or unlock the big arrow's position
/guide log      print the last raw messages (testing)
]]

local PREFIX, TRUSTED = "Guide", "Claude"
-- Here, not only in the .toc: the client reads a .toc once, at start, so after
-- a /reload over new files GetAddOnMetadata would still give the old version.
local VERSION = "0.4.1"
local STALE = 5          -- seconds without an A message before guidance lapses
local MAX_NOTES = 100

GuideDB = GuideDB or {}

local function db()
    GuideDB.log = GuideDB.log or {}
    GuideDB.notes = GuideDB.notes or {}
    if GuideDB.locked == nil then GuideDB.locked = false end
    if GuideDB.bigArrow == nil then GuideDB.bigArrow = true end
    if GuideDB.buttonAngle == nil then GuideDB.buttonAngle = 200 end
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
    GameTooltip:AddLine("Guide")
    if state.heading then
        GameTooltip:AddLine(string.format("%s - %d yd", state.label ~= "" and state.label or "guiding", state.yards or 0), 1, 1, 1)
    end
    GameTooltip:AddLine("Left-click: Claude panel", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Right-click: big arrow on/off", 0.7, 0.7, 0.7)
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

local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)

local updateLine = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
updateLine:SetPoint("BOTTOMLEFT", 22, 16)     -- under the notes; wraps upwards
updateLine:SetWidth(296); updateLine:SetJustifyH("LEFT")
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
notesHead:SetPoint("TOPLEFT", 22, -104)
notesHead:SetText("From Claude")

local notes = CreateFrame("ScrollingMessageFrame", nil, panel)
notes:SetPoint("TOPLEFT", 22, -122)
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
        guideLine:SetText(string.format("To %s: %d yd%s", where, state.yards or 0,
            state.mode == "route" and " by the way through" or ""))
        guideSub:SetText(state.mode == "route"
            and (state.leg > 0 and string.format("Following the corridors - next turn in %d yd.", state.leg)
                 or "Following the corridors - straight on to the end.")
            or state.mode == "lost" and "No way through found - this is the straight line."
            or "Compass: straight at the target.")
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

button:SetScript("OnClick", function(self, which)
    if which == "RightButton" then setBigArrow(not db().bigArrow) else togglePanel() end
end)

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
    if state.mode == "route" then
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
    frame:Hide(); idleIcon()
    if panel:IsShown() then refreshPanel() end
    say(text)
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
