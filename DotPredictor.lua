-- DotPredictor
--
-- Shows how much of your target's health your damage-over-time spells are still going to take,
-- as a segment on the target frame's health bar (and, optionally, on the target's nameplate).
-- If the segment reaches the left end of the bar, your DoTs are expected to finish the target,
-- and a lethal marker lights up there.
--
-- Health is a secret value in this client: addon code can't read it, compare it or do math on
-- it. So the addon never touches health. It works out how much damage your DoTs have left (from
-- the spell's tooltip and how long the DoT has to run) and hands that plain number to a status
-- bar whose range is the target's current health. The game draws the comparison.
--
-- Which DoTs are on the target, and for how long, is read from the target's debuffs when the game
-- allows it; otherwise from your own casts (with the pandemic carry-over on refresh).
--
-- /dp for commands, or the AddOns tab of the game's options.

local ADDON = "DotPredictor"
local VERSION = "1.0.2"
do
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if get then
        local ok, v = pcall(get, ADDON, "Version")
        if ok and type(v) == "string" and v ~= "" then VERSION = v end
    end
end

local db
local issecret = _G.issecretvalue or function() return false end

local DEFAULTS = {
    onFrame = true,       -- overlay on the target frame's health bar
    onPlate = false,      -- overlay on the target's nameplate
    attach = nil,         -- global name (dotted path) of another unit frame's health bar
    textMode = "both",    -- "damage", "time", "both" or "none"
    textPos = "inside",   -- "inside" (right end of the bar), "above" or "below"
    striped = true,       -- striped "incoming" texture instead of a flat fill
    edge = true,          -- bright line where health is predicted to end
    lethal = true,        -- marker at the left end that lights up when your DoTs should finish the target
    color = "red",        -- see COLORS
    haste = true,         -- DoTs tick faster with haste
    crit = true,          -- expected value: include your crit chance
    vers = false,         -- include versatility (leave off if your tooltips already include it)
    calib = 1.0,          -- calibration multiplier
    overrides = {},       -- [spellId] = { total, duration }
    channels = {},        -- [spellId] = true: learned channeled spells (never DoTs here)
}

local COLORS = {
    red    = { 0.95, 0.12, 0.12 },
    purple = { 0.62, 0.25, 1.00 },
    orange = { 1.00, 0.50, 0.08 },
    green  = { 0.30, 0.95, 0.30 },
    white  = { 0.95, 0.95, 0.95 },
}
local COLOR_ORDER = { "red", "purple", "orange", "green", "white" }

-- Channeled spells read like DoTs ("damage over 4.5 sec") but stop when the channel does.
local KNOWN_CHANNELS = {
    [15407] = true,  -- Mind Flay
    [391403] = true, -- Mind Flay: Insanity
    [263165] = true, -- Void Torrent
    [48045] = true,  -- Mind Sear
    [234153] = true, -- Drain Life
    [198590] = true, -- Drain Soul
    [47540] = true,  -- Penance
    [5143] = true,   -- Arcane Missiles
    [113656] = true, -- Fists of Fury
    [356995] = true, -- Disintegrate
}

local function Print(msg) print("|cff33ff99DotPredictor:|r " .. msg) end

local function Short(n)
    if n >= 1e6 then return string.format("%.2fm", n / 1e6) end
    if n >= 1e4 then return string.format("%.0fk", n / 1e3) end
    if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
    return string.format("%d", math.floor(n + 0.5))
end

local function ToNum(s)
    if not s then return nil end
    s = s:gsub(",", "")
    return tonumber(s)
end

-- A boolean answer that can't throw and is false when the game won't say.
local function Truth(fn, ...)
    if not fn then return false end
    local ok, v = pcall(fn, ...)
    return ok and not issecret(v) and v and true or false
end

-- A plain number, or nil when it's missing or secret.
local function Num(v)
    if type(v) == "number" and not issecret(v) then return v end
    return nil
end

---------------------------------------------------------------------------
-- Reading a DoT from its tooltip
---------------------------------------------------------------------------

local function GetDescription(spellId)
    local ok, d
    if C_Spell and C_Spell.GetSpellDescription then
        ok, d = pcall(C_Spell.GetSpellDescription, spellId)
    elseif GetSpellDescription then
        ok, d = pcall(GetSpellDescription, spellId)
    end
    if not ok or type(d) ~= "string" or issecret(d) then return nil end
    return d
end

local function SpellName(spellId)
    if C_Spell and C_Spell.GetSpellName then
        local ok, n = pcall(C_Spell.GetSpellName, spellId)
        if ok and type(n) == "string" and not issecret(n) then return n end
    end
    if GetSpellInfo then
        local ok, n = pcall(GetSpellInfo, spellId)
        if ok and type(n) == "string" and not issecret(n) then return n end
    end
    return "spell " .. tostring(spellId)
end

-- Pulls total damage and duration out of English tooltip text. Returns total, duration or nil.
local function ParseText(d)
    d = d:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("\r?\n", " ")
    local SEC = "sec%a*"

    -- "... 1,234 Shadow damage over 18 sec"  (also "... an additional 1,234 Shadow damage over 16 sec")
    local dmg, dur = d:match("([%d,]+)%s+[%a%s]-damage over ([%d%.]+) " .. SEC)
    if dmg and dur then return ToNum(dmg), tonumber(dur) end

    -- "... 100 Fire damage every 3 sec for 12 sec"
    local per, interval, total = d:match("([%d,]+)%s+[%a%s]-damage every ([%d%.]+) " .. SEC .. " for ([%d%.]+) " .. SEC)
    if not per then
        -- "... 100 Fire damage every 3 sec. Lasts 12 sec."
        per, interval = d:match("([%d,]+)%s+[%a%s]-damage every ([%d%.]+) " .. SEC)
        total = d:match("[Ll]asts ([%d%.]+) " .. SEC)
    end
    if per and interval and total then
        interval, total = tonumber(interval), tonumber(total)
        if interval and interval > 0 and total then
            return ToNum(per) * math.floor(total / interval + 0.001), total
        end
    end
    return nil
end

-- Spells don't change much, but their numbers grow with gear: cache for a few seconds.
local parseCache = {}
local function ParseDot(spellId)
    if not spellId then return nil end
    if db.channels[spellId] or KNOWN_CHANNELS[spellId] then return nil, nil, "channeled" end
    local ov = db.overrides[spellId]
    if ov then return ov[1], ov[2], "override" end
    local now = GetTime()
    local c = parseCache[spellId]
    if c and now - c.at < 5 then return c.total, c.dur, c.how end
    local d = GetDescription(spellId)
    local total, dur, how
    if not d then
        how = "no readable tooltip"
    else
        total, dur = ParseText(d)
        how = total and "tooltip" or "tooltip not understood"
    end
    if total and (not dur or dur <= 0) then total, dur = nil, nil end
    parseCache[spellId] = { at = now, total = total, dur = dur, how = how }
    return total, dur, how
end

-- How much more (or less) your DoTs deal than their tooltips say.
local function Factor()
    local f = db.calib or 1
    if db.haste and GetHaste then
        local ok, h = pcall(GetHaste)
        h = ok and Num(h)
        if h then f = f * (1 + h / 100) end
    end
    if db.crit and GetSpellCritChance then
        local best
        for school = 2, 7 do
            local ok, c = pcall(GetSpellCritChance, school)
            c = ok and Num(c)
            if c and (not best or c > best) then best = c end
        end
        if best then f = f * (1 + math.min(best, 100) / 100) end -- crits deal double
    end
    if db.vers and GetCombatRatingBonus and CR_VERSATILITY_DAMAGE_DONE then
        local ok, v = pcall(GetCombatRatingBonus, CR_VERSATILITY_DAMAGE_DONE)
        v = ok and Num(v)
        local ok2, v2 = pcall(GetVersatilityBonus or function() return 0 end, CR_VERSATILITY_DAMAGE_DONE)
        v2 = ok2 and Num(v2) or 0
        if v then f = f * (1 + (v + v2) / 100) end
    end
    return f
end

---------------------------------------------------------------------------
-- Which of your DoTs are on the target, and for how long
---------------------------------------------------------------------------

-- Cast records, per target: casts[key][spellId] = { start, expires, dur }
local casts = {}
local seen = {}  -- seen[key][spellId] = true: debuffs already accounted for
local track = { source = "none", list = {}, scanOk = false }

local function TargetKey()
    local ok, g = pcall(UnitGUID, "target")
    if not ok or g == nil or issecret(g) then return "target" end
    return g
end

-- Your debuffs on the target. Returns a list of { id, expires, dur } (expires / dur nil when the
-- game hides them) and whether the scan could see anything at all.
-- An empty list doesn't count as "none of your DoTs are on it": the game may simply be hiding them, so
-- then the cast records are used.
local function ScanAuras()
    local out, readable, hidden = {}, false, false
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "target", i, "HARMFUL|PLAYER")
            if not ok then hidden = true break end
            if a == nil then break end
            if type(a) == "table" then
                local id = Num(a.spellId)
                if not id then hidden = true end
                if id then
                    readable = true
                    track.aurasWork = true
                    local exp, dur = Num(a.expirationTime), Num(a.duration)
                    if exp and exp <= 0 then exp = nil end
                    if dur and dur <= 0 then dur = nil end
                    out[#out + 1] = { id = id, expires = exp, dur = dur }
                end
            end
        end
    elseif UnitAura then
        for i = 1, 40 do
            local ok, name, _, _, _, dur, exp, _, _, _, id = pcall(UnitAura, "target", i, "HARMFUL|PLAYER")
            if not ok then hidden = true break end
            if name == nil then break end
            id = Num(id)
            if not id then hidden = true end
            if id then
                readable = true
                track.aurasWork = true
                exp, dur = Num(exp), Num(dur)
                out[#out + 1] = { id = id, expires = (exp and exp > 0) and exp or nil, dur = (dur and dur > 0) and dur or nil }
            end
        end
    end
    return out, readable
end

-- Builds track.list: { id, left (seconds), total, dur } for every DoT that's still running.
local function Collect()
    local now = GetTime()
    local key = TargetKey()
    local rec = casts[key] or {}
    local sn = seen[key] or {}
    casts[key], seen[key] = rec, sn
    wipe(track.list)

    local auras, readable = ScanAuras()
    track.scanOk = readable
    if readable then
        track.source = "debuffs"
        local present = {}
        for _, a in ipairs(auras) do
            local total, baseDur = ParseDot(a.id)
            if total then
                present[a.id] = true
                local left
                if a.expires then
                    left = a.expires - now
                    rec[a.id] = { start = a.expires - (a.dur or baseDur), expires = a.expires, dur = a.dur or baseDur }
                else
                    -- timings hidden: use the cast record, or start one the first time this debuff shows up
                    local r = rec[a.id]
                    if not r then
                        r = { start = now, expires = now + baseDur, dur = baseDur }
                        rec[a.id] = r
                    end
                    left = r.expires - now
                    track.source = "debuffs + your casts"
                end
                sn[a.id] = true
                if left > 0 then
                    track.list[#track.list + 1] = { id = a.id, left = left, total = total, dur = baseDur }
                end
            end
        end
        -- anything you cast that isn't on the target any more was dispelled or has ended
        for id in pairs(rec) do if not present[id] then rec[id] = nil end end
    else
        track.source = next(rec) and "your casts" or "none"
        for id, r in pairs(rec) do
            local left = r.expires - now
            if left <= 0 then
                rec[id] = nil
            else
                local total, baseDur = ParseDot(id)
                if total then track.list[#track.list + 1] = { id = id, left = left, total = total, dur = baseDur } end
            end
        end
    end
end

-- Expected damage still to come, and the longest time left.
local function Remaining()
    Collect()
    local f = Factor()
    local sum, longest = 0, 0
    for _, d in ipairs(track.list) do
        -- damage arrives at total / base duration per second; a pandemic-extended DoT keeps that rate for longer
        local part = d.total / d.dur * d.left * f
        d.remaining = part
        sum = sum + part
        if d.left > longest then longest = d.left end
    end
    return sum, longest
end

-- A cast of yours: remember it on the target (used when the debuffs can't be read).
local function OnCast(spellId)
    spellId = Num(spellId)
    if not spellId then return end
    if not UnitExists("target") or not Truth(UnitCanAttack, "player", "target") then return end
    local total, dur = ParseDot(spellId)
    if not total then return end
    local key = TargetKey()
    casts[key] = casts[key] or {}
    local now = GetTime()
    local r = casts[key][spellId]
    -- refreshing a running DoT keeps up to 30% of its duration (pandemic)
    local carry = r and math.max(0, math.min(r.expires - now, dur * 0.3)) or 0
    casts[key][spellId] = { start = now, expires = now + dur + carry, dur = dur + carry }
end

-- Old records for mobs you've moved on from.
local function Prune()
    local now = GetTime()
    for key, rec in pairs(casts) do
        for id, r in pairs(rec) do if r.expires < now then rec[id] = nil end end
        if not next(rec) then casts[key] = nil; seen[key] = nil end
    end
end

---------------------------------------------------------------------------
-- The overlay (one on the target frame, one on the nameplate)
---------------------------------------------------------------------------

local function IsStatusBar(f)
    if type(f) ~= "table" or not f.GetStatusBarTexture then return false end
    local ok, t = pcall(f.GetStatusBarTexture, f)
    return ok and t ~= nil
end

local function Dig(path)
    local obj = _G
    for part in path:gmatch("[^%.]+") do
        if type(obj) ~= "table" then return nil end
        obj = obj[part]
        if not obj then return nil end
    end
    return obj
end

local STRIPES = "Interface\\RaidFrame\\Shield-Overlay"
local FLAT = "Interface\\TargetingFrame\\UI-StatusBar"

local Overlay = {}
Overlay.__index = Overlay

function Overlay.new(name)
    local o = setmetatable({ name = name }, Overlay)
    -- The overlay's frames are children of the health bar they sit on (set in Attach): on this client a
    -- health bar's size is secret, and only frames inside it reliably follow it.
    o.clip = CreateFrame("Frame", nil, UIParent)
    if o.clip.SetClipsChildren then o.clip:SetClipsChildren(true) end
    o.clip:Hide()

    -- The doom bar spans the filled (current-health) part of the health bar and fills right to left, with
    -- current health as its range: so its fill covers exactly (DoT damage / max health) of the whole bar,
    -- hanging off the right end of the health fill.
    o.bar = CreateFrame("StatusBar", nil, o.clip)
    o.bar:SetStatusBarTexture(FLAT)
    o.bar:SetReverseFill(true)
    o.bar:SetMinMaxValues(0, 1)
    o.bar:SetValue(0)
    o.fill = o.bar:GetStatusBarTexture()

    -- the line where health is predicted to end: the left edge of the doom fill
    o.edgeTex = o.bar:CreateTexture(nil, "OVERLAY")
    o.edgeTex:SetColorTexture(1, 1, 1, 0.95)
    o.edgeTex:SetWidth(2)
    o.edgeTex:SetPoint("TOP", o.fill, "TOPLEFT", 0, 0)
    o.edgeTex:SetPoint("BOTTOM", o.fill, "BOTTOMLEFT", 0, 0)

    -- Lethal marker: a narrow window at the left end of the health bar onto a copy of the doom bar. The
    -- copy only reaches that window when the DoTs cover all of the current health, so the window lights
    -- up exactly then. The game does the comparison; the addon never sees it.
    o.lclip = CreateFrame("Frame", nil, UIParent)
    if o.lclip.SetClipsChildren then o.lclip:SetClipsChildren(true) end
    o.lclip:Hide()
    o.lbar = CreateFrame("StatusBar", nil, o.lclip)
    o.lbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    o.lbar:SetReverseFill(true)
    o.lbar:SetMinMaxValues(0, 1)
    o.lbar:SetValue(0)

    o.text = o.clip:CreateFontString(nil, "OVERLAY")
    o.text:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    o.holder = CreateFrame("Frame", nil, UIParent) -- unclipped, for text placed outside the bar
    o.holder:SetSize(1, 1)
    o.ptext = o.holder:CreateFontString(nil, "OVERLAY")
    o.ptext:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    o.ptext:Hide()
    return o
end

function Overlay:Style()
    local c = COLORS[db.color] or COLORS.red
    local okTex = false
    if db.striped then
        okTex = pcall(self.bar.SetStatusBarTexture, self.bar, STRIPES)
        local t = self.bar:GetStatusBarTexture()
        if okTex and t then
            pcall(t.SetHorizTile, t, true)
            pcall(t.SetVertTile, t, true)
        end
    end
    if not okTex then self.bar:SetStatusBarTexture(FLAT) end
    self.fill = self.bar:GetStatusBarTexture()
    self.bar:SetStatusBarColor(c[1], c[2], c[3], db.striped and 0.9 or 0.65)
    self.edgeTex:ClearAllPoints()
    self.edgeTex:SetPoint("TOP", self.fill, "TOPLEFT", 0, 0)
    self.edgeTex:SetPoint("BOTTOM", self.fill, "BOTTOMLEFT", 0, 0)
    self.edgeTex:SetShown(db.edge)
    self.lbar:SetStatusBarColor(1, 0.95, 0.75, 1)
    self.text:SetTextColor(1, 0.85, 0.85)
    self.ptext:SetTextColor(1, 0.85, 0.85)
end

-- Anchors the overlay to a health bar (or hides it with nil).
function Overlay:Attach(hb)
    if hb == self.hb then return true end
    self.hb = hb
    if not hb then self:Hide() return false end
    local ok = pcall(function()
        local lvl = (hb:GetFrameLevel() or 1) + 3
        self.clip:SetParent(hb)
        self.lclip:SetParent(hb)
        self.holder:SetParent(hb)
        self.holder:ClearAllPoints()
        self.holder:SetPoint("CENTER", hb, "CENTER", 0, 0)
        self.clip:SetFrameLevel(lvl)
        self.clip:ClearAllPoints()
        self.clip:SetAllPoints(hb)
        self.bar:ClearAllPoints()
        self.bar:SetPoint("TOP", hb, "TOP", 0, 0)
        self.bar:SetPoint("BOTTOM", hb, "BOTTOM", 0, 0)
        self.bar:SetPoint("LEFT", hb, "LEFT", 0, 0)
        self.bar:SetPoint("RIGHT", hb:GetStatusBarTexture(), "RIGHT", 0, 0)

        self.lclip:SetFrameLevel(lvl + 1)
        self.lclip:ClearAllPoints()
        self.lclip:SetPoint("TOPLEFT", hb, "TOPLEFT", 0, 0)
        self.lclip:SetPoint("BOTTOMLEFT", hb, "BOTTOMLEFT", 0, 0)
        self.lclip:SetWidth(4)
        self.lbar:ClearAllPoints()
        self.lbar:SetPoint("TOP", hb, "TOP", 0, 0)
        self.lbar:SetPoint("BOTTOM", hb, "BOTTOM", 0, 0)
        self.lbar:SetPoint("LEFT", hb, "LEFT", 0, 0)
        self.lbar:SetPoint("RIGHT", hb:GetStatusBarTexture(), "RIGHT", 0, 0)
    end)
    if not ok then self.hb = nil; self:Hide() return false end
    self:Place()
    return true
end

function Overlay:Place()
    local hb = self.hb
    if not hb then return end
    self.text:ClearAllPoints()
    self.ptext:ClearAllPoints()
    if db.textPos == "above" then
        self.ptext:SetPoint("BOTTOMRIGHT", hb, "TOPRIGHT", 0, 2)
    elseif db.textPos == "below" then
        self.ptext:SetPoint("TOPRIGHT", hb, "BOTTOMRIGHT", 0, -2)
    else
        self.text:SetPoint("RIGHT", hb, "RIGHT", -3, 0)
    end
end

function Overlay:Hide()
    self.clip:Hide(); self.lclip:Hide(); self.ptext:Hide()
end

function Overlay:Show(dmg, longest, now)
    if not self.hb then return end
    -- current health goes straight from the game to the bar: no math on it here
    local okH, hp = pcall(UnitHealth, "target")
    if not okH or hp == nil then self:Hide() return end
    if not (pcall(self.bar.SetMinMaxValues, self.bar, 0, hp) and pcall(self.bar.SetValue, self.bar, dmg)) then
        self:Hide() return
    end
    self.clip:Show()
    if db.lethal and pcall(self.lbar.SetMinMaxValues, self.lbar, 0, hp) and pcall(self.lbar.SetValue, self.lbar, dmg) then
        self.lbar:SetAlpha(0.55 + 0.45 * math.sin(now * 8))
        self.lclip:Show()
    else
        self.lclip:Hide()
    end
    local s
    if db.textMode == "damage" then s = "~" .. Short(dmg)
    elseif db.textMode == "time" then s = string.format("%.0fs", longest)
    elseif db.textMode == "both" then s = string.format("~%s  %.0fs", Short(dmg), longest) end
    if db.textPos == "inside" then
        self.text:SetText(s or ""); self.ptext:Hide()
    else
        self.text:SetText("")
        if s then self.ptext:SetText(s); self.ptext:Show() else self.ptext:Hide() end
    end
end

local frameOv, plateOv

---------------------------------------------------------------------------
-- Finding the health bars
---------------------------------------------------------------------------

local FRAME_BARS = {
    "TargetFrame.TargetFrameContent.TargetFrameContentMain.HealthBarsContainer.HealthBar", -- modern
    "TargetFrameHealthBar",                                                                  -- classic style
    "TargetFrame.healthbar",
}

local function FrameHealthBar()
    if db.attach then
        local f = Dig(db.attach)
        if IsStatusBar(f) then return f end
    end
    for _, path in ipairs(FRAME_BARS) do
        local f = Dig(path)
        if IsStatusBar(f) then return f end
    end
end

local function PlateHealthBar()
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, "target")
    if not ok or type(plate) ~= "table" then return nil end
    local uf = plate.UnitFrame
    if type(uf) ~= "table" then return nil end
    for _, hb in ipairs({ uf.healthBar, uf.HealthBar, uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar,
        uf.HealthBarsContainer and uf.HealthBarsContainer.HealthBar }) do
        if IsStatusBar(hb) then return hb end
    end
end

---------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------

local active = false -- something to draw: the updater runs fast only then

local function Update()
    if not db then return end
    local now = GetTime()
    local hostile = UnitExists("target") and Truth(UnitCanAttack, "player", "target") and not Truth(UnitIsDead, "target")
    local dmg, longest = 0, 0
    if hostile then dmg, longest = Remaining() else wipe(track.list) end
    active = hostile and dmg > 0

    frameOv:Attach(db.onFrame and FrameHealthBar() or nil)
    plateOv:Attach(db.onPlate and PlateHealthBar() or nil)
    for _, o in ipairs({ frameOv, plateOv }) do
        if active and o.hb then o:Show(dmg, longest, now) else o:Hide() end
    end
end

local function Restyle()
    if not frameOv then return end
    for _, o in ipairs({ frameOv, plateOv }) do o:Style(); o:Place() end
    wipe(parseCache)
    Update()
end

---------------------------------------------------------------------------
-- Settings window
---------------------------------------------------------------------------

local panel
local function BuildPanel()
    if panel or not CreateFrame then return end
    panel = CreateFrame("Frame")
    panel.name = ADDON
    local refresh = {}

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("DotPredictor  |cff888888v" .. VERSION .. "|r")
    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    sub:SetWidth(560)
    sub:SetJustifyH("LEFT")
    sub:SetText("Shows how much of your target's health your DoTs are still going to take. If the segment reaches the left end of the bar, the lethal marker lights up.")

    local function Check(label, key, x, y, tip)
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", x, y)
        local t = cb.Text or cb.text
        if not t then
            t = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            t:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        end
        t:SetText(label)
        cb:SetScript("OnClick", function(self) db[key] = self:GetChecked() and true or false; Restyle() end)
        if tip then
            cb:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(label, 1, 0.82, 0)
                GameTooltip:AddLine(tip, 1, 1, 1, true); GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        refresh[#refresh + 1] = function() cb:SetChecked(db[key] and true or false) end
    end
    -- a button that cycles through choices
    local function Cycle(label, key, choices, names, x, y)
        local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        fs:SetPoint("TOPLEFT", x, y - 5)
        fs:SetText(label)
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetSize(110, 22)
        b:SetPoint("TOPLEFT", x + 130, y)
        local function show() for i, c in ipairs(choices) do if db[key] == c then b:SetText(names[i]) end end end
        b:SetScript("OnClick", function()
            local idx = 1
            for i, c in ipairs(choices) do if db[key] == c then idx = i end end
            db[key] = choices[idx % #choices + 1]
            show(); Restyle()
        end)
        refresh[#refresh + 1] = show
    end

    local h1 = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    h1:SetPoint("TOPLEFT", 16, -70); h1:SetText("Where")
    Check("Target frame", "onFrame", 16, -90)
    Check("Target's nameplate", "onPlate", 16, -116, "Also draws the segment on your target's nameplate (the game's own nameplates).")
    Check("Striped fill", "striped", 16, -142)
    Check("Line where health will end", "edge", 16, -168)
    Check("Lethal marker", "lethal", 16, -194, "A bright pulse at the left end of the bar when your DoTs are expected to finish the target.")
    Cycle("Color", "color", COLOR_ORDER, { "Red", "Purple", "Orange", "Green", "White" }, 16, -226)
    Cycle("Text", "textMode", { "both", "damage", "time", "none" }, { "Damage + time", "Damage", "Time left", "None" }, 16, -254)
    Cycle("Text position", "textPos", { "inside", "above", "below" }, { "Inside bar", "Above bar", "Below bar" }, 16, -282)

    local h2 = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    h2:SetPoint("TOPLEFT", 320, -70); h2:SetText("Estimate")
    Check("Haste", "haste", 320, -90, "DoTs tick faster with haste, so they deal more than their tooltip says.")
    Check("Crit (expected value)", "crit", 320, -116, "Adds your average crit damage.")
    Check("Versatility", "vers", 320, -142, "Leave off if your tooltips already include versatility.")

    local sl = CreateFrame("Slider", "DotPredictorScaleSlider", panel, "OptionsSliderTemplate")
    sl:SetPoint("TOPLEFT", 324, -190)
    sl:SetWidth(220)
    sl:SetMinMaxValues(0.5, 2)
    sl:SetValueStep(0.05)
    if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
    local slText = sl.Text or _G["DotPredictorScaleSliderText"]
    local function slShow(v) if slText then slText:SetText(string.format("Calibration x%.2f", v)) end end
    sl:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v * 20 + 0.5) / 20
        db.calib = v; slShow(v); Update()
    end)
    refresh[#refresh + 1] = function() sl:SetValue(db.calib or 1); slShow(db.calib or 1) end
    local slNote = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    slNote:SetPoint("TOPLEFT", 320, -212)
    slNote:SetWidth(260)
    slNote:SetJustifyH("LEFT")
    slNote:SetText("If the segment is consistently too long or too short (talents and mastery aren't in tooltips), adjust this.")

    -- the spells it understood
    local h3 = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    h3:SetPoint("TOPLEFT", 16, -320); h3:SetText("Your DoTs")
    local list = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    list:SetPoint("TOPLEFT", 16, -340)
    list:SetWidth(560)
    list:SetJustifyH("LEFT")
    list:SetSpacing(2)
    local scan = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    scan:SetSize(90, 22)
    scan:SetPoint("TOPLEFT", 120, -316)
    scan:SetText("Rescan")
    local function ShowSpells()
        wipe(parseCache)
        local rows = DotPredictor_ScanSpellbook and DotPredictor_ScanSpellbook() or {}
        local lines = {}
        for _, r in ipairs(rows) do
            if r.total then
                lines[#lines + 1] = string.format("|cff66ff66%s|r  %s over %ss  |cff888888(%s, id %s)|r", r.name, Short(r.total), tostring(r.dur), r.how, tostring(r.id))
            end
        end
        if #lines == 0 then lines[1] = "|cffff8866No DoTs found in your spellbook that the addon can read.|r" end
        lines[#lines + 1] = "|cff888888Wrong or missing? /dp set <spellId> <total damage> <seconds>   ·   /dp debug while fighting|r"
        list:SetText(table.concat(lines, "\n"))
    end
    scan:SetScript("OnClick", ShowSpells)

    panel:SetScript("OnShow", function()
        for _, f in ipairs(refresh) do f() end
        ShowSpells()
    end)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local cat = Settings.RegisterCanvasLayoutCategory(panel, ADDON)
        Settings.RegisterAddOnCategory(cat)
        panel.category = cat
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

local function OpenPanel()
    BuildPanel()
    if Settings and Settings.OpenToCategory and panel and panel.category then
        local id = panel.category.GetID and panel.category:GetID() or panel.category
        pcall(Settings.OpenToCategory, id)
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end

-- Every spell in your spellbook that reads as a DoT (for the settings list and /dp spells).
function DotPredictor_ScanSpellbook()
    local rows, seenIds = {}, {}
    local function add(id)
        id = Num(id)
        if not id or seenIds[id] then return end
        seenIds[id] = true
        local total, dur, how = ParseDot(id)
        if total or how == "override" then
            rows[#rows + 1] = { id = id, name = SpellName(id), total = total, dur = dur, how = how }
        end
    end
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookItemInfo then
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
        local ok, n = pcall(C_SpellBook.GetNumSpellBookSkillLines)
        for i = 1, (ok and Num(n)) or 0 do
            local ok2, line = pcall(C_SpellBook.GetSpellBookSkillLineInfo, i)
            if ok2 and type(line) == "table" and not line.offSpecID and line.itemIndexOffset and line.numSpellBookItems then
                for slot = line.itemIndexOffset + 1, line.itemIndexOffset + line.numSpellBookItems do
                    local ok3, info = pcall(C_SpellBook.GetSpellBookItemInfo, slot, bank)
                    if ok3 and type(info) == "table" and info.spellID and not info.isPassive then add(info.spellID) end
                end
            end
        end
    elseif GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo then
        local ok, tabs = pcall(GetNumSpellTabs)
        for t = 1, (ok and Num(tabs)) or 0 do
            local ok2, _, _, offset, num = pcall(GetSpellTabInfo, t)
            if ok2 and Num(offset) and Num(num) then
                for slot = offset + 1, offset + num do
                    local ok3, kind, id = pcall(GetSpellBookItemInfo, slot, "spell")
                    if ok3 and kind == "SPELL" then add(id) end
                end
            end
        end
    end
    for id in pairs(db.overrides) do add(id) end
    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

SLASH_DOTPREDICTOR1 = "/dp"
SLASH_DOTPREDICTOR2 = "/dotpredictor"
SlashCmdList["DOTPREDICTOR"] = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()

    if cmd == "" or cmd == "options" or cmd == "config" then
        OpenPanel()
        return
    elseif cmd == "text" then
        local order = { both = "damage", damage = "time", time = "none", none = "both" }
        db.textMode = order[db.textMode] or "both"
        Print("Text: " .. db.textMode)
    elseif cmd == "plate" then
        db.onPlate = not db.onPlate
        Print("Nameplate overlay " .. (db.onPlate and "on." or "off."))
    elseif cmd == "attach" then
        if rest == "" then
            db.attach = nil
            Print("Using the default target frame.")
        elseif IsStatusBar(Dig(rest)) then
            db.attach = rest
            Print("Attached to " .. rest)
        else
            Print("'" .. rest .. "' isn't a status bar. Try /fstack to find your health bar's name.")
        end
        frameOv:Attach(nil)
    elseif cmd == "set" then
        local id, total, dur = rest:match("^(%d+)%s+([%d%.]+)%s+([%d%.]+)$")
        if id then
            db.overrides[tonumber(id)] = { tonumber(total), tonumber(dur) }
            wipe(parseCache)
            Print(string.format("%s: %s total damage over %s sec.", SpellName(tonumber(id)), total, dur))
        else
            Print("Usage: /dp set <spellId> <totalDamage> <durationSeconds>")
        end
    elseif cmd == "unset" then
        local id = tonumber(rest)
        if id then db.overrides[id] = nil; wipe(parseCache); Print("Override removed.") end
    elseif cmd == "test" then
        local id = tonumber(rest)
        if not id then Print("Usage: /dp test <spellId>") return end
        local total, dur, how = ParseDot(id)
        if total then
            Print(string.format("%s parsed as ~%s damage over %.1f sec (%s).", SpellName(id), Short(total), dur, how))
        else
            local d = GetDescription(id)
            Print(how == "channeled" and (SpellName(id) .. " is channeled, so it isn't counted.")
                or (d and ("Couldn't read it. Tooltip: " .. d) or "No readable tooltip. Use /dp set."))
        end
    elseif cmd == "spells" then
        local rows = DotPredictor_ScanSpellbook()
        if #rows == 0 then Print("No DoTs found in your spellbook that the addon can read.") end
        for _, r in ipairs(rows) do
            Print(string.format("%s (id %s): %s over %ss (%s)", r.name, r.id, r.total and Short(r.total) or "?", tostring(r.dur), r.how))
        end
    elseif cmd == "debug" then
        Update()
        Print(string.format("v%s  source: %s  factor x%.2f (haste %s, crit %s, vers %s, calibration %.2f)",
            VERSION, track.source, Factor(), db.haste and "on" or "off", db.crit and "on" or "off", db.vers and "on" or "off", db.calib))
        if #track.list == 0 then Print("No DoTs of yours tracked on the target.") end
        for _, d in ipairs(track.list) do
            Print(string.format("  %s: %s left over %.1fs (tooltip %s / %.0fs)", SpellName(d.id), Short(d.remaining or 0), d.left, Short(d.total), d.dur))
        end
        if track.err then Print("  last error: " .. track.err) end
        Print(string.format("  target frame bar: %s   nameplate bar: %s",
            frameOv.hb and "found" or (db.onFrame and "NOT FOUND" or "off"), plateOv.hb and "found" or (db.onPlate and "not found" or "off")))
    elseif cmd == "clear" then
        wipe(casts); wipe(seen)
        Print("Tracked DoTs cleared.")
    elseif cmd == "reset" then
        wipe(db)
        for k, v in pairs(DEFAULTS) do db[k] = type(v) == "table" and CopyTable(v) or v end
        Print("Settings reset.")
    else
        Print("/dp opens the settings. Commands: plate (nameplate on/off) | text (cycle) | attach [frame] | test <spellId> | spells | set <spellId> <total> <sec> | unset <spellId> | debug | clear | reset")
        return
    end
    Restyle()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        DotPredictorDB = DotPredictorDB or {}
        db = DotPredictorDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = type(v) == "table" and CopyTable(v) or v end
        end
        if db.showText == false then db.textMode = "none" end -- 1.0.0 setting
        db.showText = nil
        db.width, db.height, db.scale, db.locked, db.point, db.includePet = nil, nil, nil, nil, nil, nil -- leftovers from the standalone-bar version

        frameOv, plateOv = Overlay.new("frame"), Overlay.new("plate")
        Restyle()
        BuildPanel()

        self:UnregisterEvent("ADDON_LOADED")
        self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
        self:RegisterUnitEvent("UNIT_HEALTH", "target")
        self:RegisterUnitEvent("UNIT_MAXHEALTH", "target")
        self:RegisterUnitEvent("UNIT_AURA", "target")
        self:RegisterEvent("PLAYER_TARGET_CHANGED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        self:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

        -- The estimate runs down as the DoTs do, so redraw 10 times a second while there's something to
        -- draw; otherwise only check twice a second (events cover the rest).
        local elapsed, prune = 0, 0
        self:SetScript("OnUpdate", function(_, dt)
            elapsed, prune = elapsed + dt, prune + dt
            if elapsed >= (active and 0.1 or 0.5) then
                elapsed = 0
                local ok, err = pcall(Update)
                if not ok then track.err = tostring(err) end
            end
            if prune >= 10 then prune = 0; Prune() end
        end)
        return
    end
    if not db then return end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        OnCast(arg3) -- unit, castGUID, spellID
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        local id = Num(arg3)
        if id and not db.channels[id] then
            db.channels[id] = true
            parseCache[id] = nil
            for _, rec in pairs(casts) do rec[id] = nil end
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- with no readable target IDs all records share one key: start fresh for the new target
        casts.target, seen.target = nil, nil
    elseif event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED" then
        plateOv:Attach(nil) -- the target's nameplate may have changed: look again
    end
    Update()
end)
