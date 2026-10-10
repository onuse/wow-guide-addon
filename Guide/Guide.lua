--[[
Guide - directions from Claude.

The server knows where everyone is, inside dungeons too, where the 3.3.5
client has no map coordinates and TomTom goes blind. So the server works out
the way (its navmesh route) and once a second tells this addon, in a hidden
addon whisper, how far it is and which world heading leads to the next
corner. Between those messages the arrow follows your own turning, from
GetPlayerFacing(), so it stays smooth.

Only messages FROM the character Claude are read. The server fills in the
sender of a whisper, so nobody else can steer this arrow.

Wire format (prefix "Guide", tab-separated):
  A <yards> <angle> <mode> <label>   angle: world heading, radians, 0 = north,
                                     anticlockwise - the frame GetPlayerFacing uses
  D <label>                          arrived
  X <reason>                         stopped
  T <text>                           test

/guide          show or hide the arrow frame
/guide lock     lock or unlock its position (drag it while unlocked)
/guide log      print the last messages received
]]

local PREFIX, TRUSTED = "Guide", "Claude"
local STALE = 5          -- seconds without an A message before the arrow hides

GuideDB = GuideDB or {}

local function db()
    GuideDB.log = GuideDB.log or {}
    if GuideDB.locked == nil then GuideDB.locked = false end
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

-- The arrow -----------------------------------------------------------------

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

local dist = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
dist:SetPoint("TOP", arrow, "BOTTOM", 0, 0)
local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
label:SetPoint("TOP", dist, "BOTTOM", 0, -1)

-- Turn the arrow image anticlockwise by `a` radians. Each corner of the frame
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

local state = { heading = nil, yards = nil, mode = nil, label = "", seen = 0 }

frame:SetScript("OnUpdate", function(self, elapsed)
    if not state.heading then return end
    if GetTime() - state.seen > STALE then
        state.heading = nil
        self:Hide()
        return
    end
    local rel = state.heading - (GetPlayerFacing() or 0)
    rel = math.fmod(rel + 3 * math.pi, 2 * math.pi) - math.pi     -- -pi..pi, + is to the left
    rotate(arrow, rel)
    local off = math.abs(rel)
    if off < 0.26 then arrow:SetVertexColor(0.3, 1, 0.3)           -- within ~15 degrees
    elseif off < 1.57 then arrow:SetVertexColor(1, 0.85, 0.2)
    else arrow:SetVertexColor(1, 0.35, 0.3) end
end)

-- Messages ------------------------------------------------------------------

local function split(msg)
    local t = {}
    for field in string.gmatch(msg .. "\t", "([^\t]*)\t") do table.insert(t, field) end
    return t
end

local handlers = {}

handlers.A = function(f)
    state.yards, state.heading = tonumber(f[2]), tonumber(f[3])
    state.mode, state.label, state.seen = f[4], f[5] or "", GetTime()
    if not state.heading then return end
    dist:SetText(string.format("%d yd%s", state.yards or 0, state.mode == "line" and " (straight)" or ""))
    label:SetText(state.label)
    frame:Show()
end

handlers.D = function(f)
    state.heading = nil
    frame:Hide()
    say("arrived" .. ((f[2] and f[2] ~= "") and (" at " .. f[2]) or "") .. ".")
    PlaySound("MapPing")
end

handlers.X = function(f)
    state.heading = nil
    frame:Hide()
    say("guidance stopped (" .. (f[2] or "") .. ").")
end

handlers.T = function(f)
    say("test from Claude: " .. (f[2] or ""))
end

local events = CreateFrame("Frame")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if event == "PLAYER_LOGIN" then
        local p = db().point
        if p then frame:ClearAllPoints(); frame:SetPoint(p[1], UIParent, p[2], p[3], p[4]) end
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
    elseif arg == "log" then
        local log = db().log
        if #log == 0 then say("no messages yet.") end
        for i = math.max(1, #log - 9), #log do say(log[i]) end
    elseif frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        if not state.heading then dist:SetText("waiting for Claude"); label:SetText("") end
    end
end
