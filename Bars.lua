--------------------------------------------------------------------------------
-- nugsCastBars
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsCastBars  -  Bars.lua
-- The bars themselves. One frame per unit token (player, target, focus, pet and
-- boss1..boss5), each driven by its own config table and its own unit-filtered
-- events, so nothing here has to listen to the whole world's spellcasting.
--
-- Timing rule of the house: every number that comes out of a unit API is run
-- through NCB.Plain(). If the client hands back a value we are not allowed to do
-- arithmetic on, we fall back to timing the cast ourselves from the moment the
-- event fired - GetTime() deltas are always legal - and to the cast length we
-- measured the last time we watched that spell finish.
--------------------------------------------------------------------------------
local ADDON_NAME, NCB = ...

local Bars = {}
NCB.Bars = Bars

Bars.frames = {}   -- [unit token] = frame
Bars.list   = {}   -- every frame, in creation order

local Plain = NCB.Plain

local SPELL_EVENTS = {
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_FAILED_QUIET",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "UNIT_SPELLCAST_CHANNEL_STOP",
    "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_INTERRUPTIBLE",
    "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
    "UNIT_SPELLCAST_EMPOWER_START",
    "UNIT_SPELLCAST_EMPOWER_UPDATE",
    "UNIT_SPELLCAST_EMPOWER_STOP",
}

--------------------------------------------------------------------------------
-- The 12.0 cast APIs
-- Secret values are not a wall, they are a pipe: the client hands you something
-- you may not read but may pass to a widget, and the widget does the work. These
-- are the taps for that pipe, and they are why this addon can put a real number on
-- another player's cast when reading the timestamps directly cannot.
--
--   UnitCastingDuration / UnitChannelDuration / UnitEmpoweredChannelDuration
--       -> a Duration object. StatusBar:SetTimerDuration() then animates itself
--          from it, and Duration:GetRemainingDuration() / :GetTotalDuration()
--          feed FontString:SetFormattedText() without ever being read in Lua.
--   Texture:SetAlphaFromBoolean(secretBool, ifTrue, ifFalse)
--       -> the display sink for a secret boolean, which is how interruptibility
--          gets on screen despite being un-testable.
--   UnitSpellTargetName / UnitSpellTargetClass
--       -> the cast's actual target, rather than inferring it from unit..target.
--------------------------------------------------------------------------------
local TIMER_DIR     = Enum and Enum.StatusBarTimerDirection
local TIMER_INTERP  = Enum and Enum.StatusBarInterpolation
local HAS_TIMER_API = (TIMER_DIR ~= nil and TIMER_INTERP ~= nil
                       and _G.UnitCastingDuration ~= nil)

local DEMO = {
    { name = "Chaos Bolt",     icon = 236291, length = 3.0 },
    { name = "Greater Heal",   icon = 135914, length = 2.5 },
    { name = "Fel Detonation", icon = 236303, length = 4.0 },
}

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------
-- Trimming counts characters, not bytes: a byte-wise cut through a localised
-- spell name lands in the middle of a multi-byte character and draws a box.
local function Trim(text, maxChars)
    if not text then return "" end
    -- A secret string has no length we are allowed to ask for. It can still be
    -- drawn, so it goes out whole.
    if NCB.IsSecret(text) then return text end
    if not maxChars or maxChars <= 0 then return text end

    if string.utf8len and string.utf8sub then
        local ok, len = pcall(string.utf8len, text)
        if ok and len and len > maxChars then
            local ok2, cut = pcall(string.utf8sub, text, 1, maxChars)
            if ok2 and cut then return cut .. "..." end
        end
        if ok and len then return text end
    end

    if #text > maxChars then return text:sub(1, maxChars) .. "..." end
    return text
end

-- SetText refuses nothing we expect to hand it, but a secret value reaching a sink
-- that will not take one must not take the whole draw down with it.
local function SafeSetText(fs, value, fallback)
    if not value then fs:SetText("") return end
    local ok = pcall(fs.SetText, fs, value)
    if not ok then fs:SetText(fallback or "") end
end

local function ColorHex(r, g, b)
    return string.format("%02x%02x%02x", math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local function ClassColor(class)
    local colors = _G.RAID_CLASS_COLORS
    local c = class and colors and colors[class]
    if c then return c.r, c.g, c.b end
    return 0.85, 0.85, 0.85
end

-- The unit a cast is aimed at, read once when the cast starts. WoW locks a spell
-- onto its target at cast time, so re-reading this every frame would show where
-- the caster is looking now rather than where the spell is going to land.
--
-- The name may come back secret, in which case it can still be drawn but not
-- coloured by class or compared against the player - so those two go through
-- Plain() and simply stand down when the client will not say.
local function SnapshotTarget(unit)
    -- 12.0 answers this directly: the spell's own target, rather than whoever the
    -- caster happens to be pointed at when we look.
    if _G.UnitSpellTargetName then
        local name = UnitSpellTargetName(unit)
        if name then
            local class = _G.UnitSpellTargetClass and UnitSpellTargetClass(unit) or nil
            -- The spell's target cannot be compared against the player when it is
            -- a secret string, so "is it on me" falls back to the caster's current
            -- target, which is the same unit in all but the rarest cases.
            local onYou = Plain(UnitIsUnit(unit .. "target", "player"))
            return name, Plain(class), onYou, not NCB.IsSecret(name)
        end
        return nil
    end

    local token = unit .. "target"
    -- No UnitExists call: it hands back a boolean, and a boolean is the one kind
    -- of secret we may not even test. UnitName is nil for a unit that is not
    -- there, which answers the same question without the landmine.
    local name = UnitName(token)
    if not name then return nil end
    local _, class = UnitClass(token)
    return name, Plain(class), Plain(UnitIsUnit(token, "player")), not NCB.IsSecret(name)
end

--------------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------------
-- A one-pixel outline drawn just outside the frame, so it never eats into the
-- fill. Four textures rather than a backdrop: backdrops changed template twice in
-- two expansions, plain textures never have.
local function AddBorder(frame)
    local edges = {}
    local function edge(p1, x1, y1, p2, x2, y2, w, h)
        local t = frame:CreateTexture(nil, "OVERLAY", nil, 2)
        t:SetPoint(p1, x1, y1)
        t:SetPoint(p2, x2, y2)
        if w then t:SetWidth(w) end
        if h then t:SetHeight(h) end
        edges[#edges + 1] = t
    end
    edge("TOPLEFT",    -1,  1, "TOPRIGHT",     1,  1, nil, 1)
    edge("BOTTOMLEFT", -1, -1, "BOTTOMRIGHT",  1, -1, nil, 1)
    edge("TOPLEFT",    -1,  1, "BOTTOMLEFT",  -1, -1, 1, nil)
    edge("TOPRIGHT",    1,  1, "BOTTOMRIGHT",  1, -1, 1, nil)
    return edges
end

local function CreateBar(cfgKey, unit, index)
    local f = CreateFrame("Frame", "nugsCastBar_" .. unit, UIParent)
    f.cfgKey = cfgKey
    f.unit   = unit
    f.index  = index
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:Hide()

    f.bar = CreateFrame("StatusBar", nil, f)
    f.bar:SetAllPoints()
    f.bar:SetMinMaxValues(0, 1)
    f.bar:SetValue(0)

    f.bg = f.bar:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()

    f.borders = AddBorder(f)

    -- Player only: the tail of the cast that has already left your client. Drawn
    -- under the spark so a full bar still reads as full.
    f.latency = f.bar:CreateTexture(nil, "OVERLAY", nil, -2)
    f.latency:SetColorTexture(0.9, 0.1, 0.1, 0.4)
    f.latency:Hide()

    -- Interruptibility can be shown but never tested, so it cannot pick a colour
    -- with an `if`. This overlay carries the "cannot be interrupted" colour and is
    -- faded in by the secret boolean itself; it is pinned to the fill texture so
    -- it only ever covers the part of the bar that is actually filled.
    f.uninterruptible = f.bar:CreateTexture(nil, "ARTWORK", nil, 1)
    f.uninterruptible:SetAlpha(0)

    -- "Can I kick this?" is two facts: whether the cast is interruptible, which is
    -- a secret boolean, and whether your own interrupt is off cooldown, which is
    -- not. The AND of the two can never be computed in Lua - but it does not have
    -- to be. This overlay is *tinted* by the plain half (ready or not ready) and
    -- *revealed* by the secret half, with the boolean inverted so it appears only
    -- on a cast that can actually be interrupted. Sits above the uninterruptible
    -- overlay; the two are mutually exclusive by construction.
    f.interrupt = f.bar:CreateTexture(nil, "ARTWORK", nil, 2)
    f.interrupt:SetAlpha(0)

    f.spark = f.bar:CreateTexture(nil, "OVERLAY", nil, 1)
    f.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    f.spark:SetBlendMode("ADD")
    f.spark:Hide()

    -- Empowered (evoker) casts get a divider at each stage boundary.
    f.pips = {}
    for i = 1, 5 do
        local pip = f.bar:CreateTexture(nil, "OVERLAY")
        pip:SetColorTexture(0, 0, 0, 0.85)
        pip:SetWidth(2)
        pip:SetPoint("TOP", f.bar, "TOPLEFT", 0, 0)
        pip:SetPoint("BOTTOM", f.bar, "BOTTOMLEFT", 0, 0)
        pip:Hide()
        f.pips[i] = pip
    end

    f.iconHolder = CreateFrame("Frame", nil, f)
    f.iconHolder:SetPoint("RIGHT", f, "LEFT", -3, 0)
    f.icon = f.iconHolder:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    f.iconBorders = AddBorder(f.iconHolder)

    f.shield = f:CreateTexture(nil, "OVERLAY")
    f.shield:SetTexture("Interface\\CastingBar\\UI-CastingBar-Small-Shield")
    f.shield:Hide()

    f.name   = f.bar:CreateFontString(nil, "OVERLAY")
    f.time   = f.bar:CreateFontString(nil, "OVERLAY")
    f.target = f:CreateFontString(nil, "OVERLAY")

    -- Shown only while the bars are unlocked, so you can tell which is which
    -- before any of them has a real cast on it.
    f.dragLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.dragLabel:SetPoint("BOTTOM", f, "TOP", 0, 3)
    f.dragLabel:Hide()

    f:SetScript("OnDragStart", function(self)
        if NCB.db.locked then return end
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- StopMovingOrSizing is free to re-anchor the frame to whichever corner it
        -- likes, so the relative point has to be saved as well. Reconstructing the
        -- position from `point` alone would move the bar every reload.
        local point, _, relPoint, x, y = self:GetPoint(1)
        local cfg = NCB.Config(self.cfgKey)
        if point and cfg then
            cfg.point    = point
            cfg.relPoint = relPoint or point
            cfg.x = math.floor(x + 0.5)
            cfg.y = math.floor(y + 0.5)
        end
        if NCB.RefreshOptions then NCB.RefreshOptions() end
    end)

    f:SetScript("OnEvent", function(self, event, unitArg, ...)
        Bars:OnUnitEvent(self, event, unitArg, ...)
    end)
    for _, event in ipairs(SPELL_EVENTS) do
        -- Unit-filtered: this frame is woken only by its own unit's casts.
        pcall(f.RegisterUnitEvent, f, event, unit)
    end

    f:SetScript("OnUpdate", function(self, elapsed) Bars:Advance(self, elapsed) end)

    Bars.frames[unit] = f
    Bars.list[#Bars.list + 1] = f
    return f
end

--------------------------------------------------------------------------------
-- Styling
--------------------------------------------------------------------------------
local function ApplyFont(fs, cfg)
    local flags = (cfg.fontOutline ~= "NONE") and cfg.fontOutline or ""
    -- SetFont reports failure rather than erroring when a font file will not load.
    local ok, applied = pcall(fs.SetFont, fs, NCB.FontPath(cfg.font), cfg.fontSize, flags)
    if not ok or applied == false then
        fs:SetFontObject("GameFontHighlightSmall")
    end
    fs:SetTextColor(unpack(cfg.colorText))
end

function Bars:ApplyBar(f)
    local cfg = NCB.Config(f.cfgKey)
    if not cfg then return end

    f:SetScale(cfg.scale)
    f:SetSize(cfg.width, cfg.height)

    -- Position. Only the first frame of a multi-bar group owns a position; the
    -- rest chain off it so the whole stack moves as one.
    f:ClearAllPoints()
    if f.index == 1 then
        f:SetPoint(cfg.point, UIParent, cfg.relPoint or cfg.point, cfg.x, cfg.y)
    else
        local prev = Bars.list[f.listIndex - 1]
        local gap  = cfg.spacing + (cfg.showTarget and cfg.targetPos == "below" and cfg.fontSize + 2 or 0)
        if cfg.grow == "up" then
            f:SetPoint("BOTTOM", prev, "TOP", 0, gap)
        else
            f:SetPoint("TOP", prev, "BOTTOM", 0, -gap)
        end
    end

    f.bar:SetStatusBarTexture(NCB.TexturePath(cfg.texture))
    f.bg:SetTexture(NCB.TexturePath(cfg.texture))
    f.bg:SetVertexColor(unpack(cfg.colorBackground))

    for _, t in ipairs(f.borders) do
        t:SetColorTexture(unpack(cfg.colorBorder))
        t:SetShown(cfg.showBorder)
    end
    for _, t in ipairs(f.iconBorders) do
        t:SetColorTexture(unpack(cfg.colorBorder))
        t:SetShown(cfg.showBorder and cfg.showIcon and cfg.iconSide ~= "NONE")
    end

    -- Icon: a square the height of the bar, hung off whichever end you picked.
    local showIcon = cfg.showIcon and cfg.iconSide ~= "NONE"
    f.iconHolder:SetShown(showIcon)
    if showIcon then
        f.iconHolder:SetSize(cfg.height, cfg.height)
        f.iconHolder:ClearAllPoints()
        if cfg.iconSide == "RIGHT" then
            f.iconHolder:SetPoint("LEFT", f, "RIGHT", cfg.iconGap + 1, 0)
        else
            f.iconHolder:SetPoint("RIGHT", f, "LEFT", -(cfg.iconGap + 1), 0)
        end
        f.icon:SetTexCoord(unpack(cfg.iconZoom and { 0.08, 0.92, 0.08, 0.92 } or { 0, 1, 0, 1 }))
    end

    f.shield:ClearAllPoints()
    f.shield:SetSize(cfg.height * 1.5, cfg.height * 1.5)
    if showIcon and cfg.iconSide == "LEFT" then
        f.shield:SetPoint("CENTER", f.iconHolder, "CENTER", 0, 0)
    else
        f.shield:SetPoint("CENTER", f, "LEFT", cfg.height * 0.4, 0)
    end

    -- Pin the spark to the moving edge of the fill texture rather than working out
    -- where that edge is. It then tracks a bar whose scale we are not allowed to
    -- read, which is the only way it can follow another player's cast at all.
    f.spark:SetSize(16, cfg.height * 2.1)
    f.spark:ClearAllPoints()
    local fill = f.bar:GetStatusBarTexture()
    if fill then
        f.spark:SetPoint("CENTER", fill, "RIGHT", 0, 0)
        f.uninterruptible:SetAllPoints(fill)
        f.interrupt:SetAllPoints(fill)
    else
        f.spark:SetPoint("CENTER", f.bar, "LEFT", 0, 0)
    end
    f.uninterruptible:SetTexture(NCB.TexturePath(cfg.texture))
    f.uninterruptible:SetVertexColor(unpack(cfg.colorUninterruptible))
    f.interrupt:SetTexture(NCB.TexturePath(cfg.texture))

    ApplyFont(f.name, cfg)
    ApplyFont(f.time, cfg)
    ApplyFont(f.target, cfg)

    f.time:ClearAllPoints()
    f.time:SetPoint("RIGHT", f.bar, "RIGHT", -4, 0)
    f.time:SetShown(cfg.showTime)

    f.name:ClearAllPoints()
    f.name:SetPoint("LEFT", f.bar, "LEFT", 4, 0)
    if cfg.showTime then
        f.name:SetPoint("RIGHT", f.time, "LEFT", -6, 0)
    else
        f.name:SetPoint("RIGHT", f.bar, "RIGHT", -4, 0)
    end
    f.name:SetJustifyH(cfg.nameJustify)
    f.name:SetShown(cfg.showName)

    f.target:ClearAllPoints()
    if cfg.targetPos == "below" then
        f.target:SetPoint("TOP", f, "BOTTOM", 0, -2)
        f.target:SetJustifyH("CENTER")
    elseif cfg.targetPos == "right" then
        local anchorTo = (showIcon and cfg.iconSide == "RIGHT") and f.iconHolder or f
        f.target:SetPoint("LEFT", anchorTo, "RIGHT", 6, 0)
        f.target:SetJustifyH("LEFT")
    else
        -- "inline" folds the target into the spell name text instead of drawing a
        -- string of its own.
        f.target:SetPoint("TOP", f, "BOTTOM", 0, -2)
    end
    f.target:SetShown(cfg.showTarget and cfg.targetPos ~= "inline")

    f.dragLabel:SetText(NCB.UnitByKey(f.cfgKey).label ..
        (f.unit:match("%d$") and (" " .. f.unit:match("%d$")) or "") .. " |cff888888(drag)|r")

    self:Redraw(f)
end

function Bars:ApplyAll()
    for _, f in ipairs(Bars.list) do
        self:ApplyBar(f)
        local cfg = NCB.Config(f.cfgKey)
        if not (NCB.db.enabled and cfg.enabled) then
            f.cast, f.finish = nil, nil
            f:Hide()
        elseif NCB.db.locked then
            -- Nothing to show until the unit actually casts something.
            if not f.cast and not f.finish then f:Hide() end
        end
    end
    NCB.Interrupts:ApplyDisplay()
    if not NCB.db.locked then self:ShowPreviews() end
end

--------------------------------------------------------------------------------
-- Cast lookup
--------------------------------------------------------------------------------
-- Normalise UnitCastingInfo / UnitChannelInfo into one shape, with every number
-- laundered through Plain(). A nil time is not an error - it means "the client
-- will not tell us right now", and Begin() falls back to its own clock.
-- `name` and `icon` are kept exactly as the client gave them, secret or not: they
-- are only ever handed to SetText and SetTexture. The raw millisecond stamps are
-- kept too, under separate names, for the same reason - they go into the status
-- bar as display input and are never read. Everything the Lua code actually has to
-- reason about is laundered through Plain() first.
-- 12.0 added a tenth return, `barID`, precisely because castID went secret: it is
-- a plain cast identity, which is the only thing left that two casts can be
-- compared by.
local function ReadCast(unit)
    local name, text, icon, startMS, endMS, isTrade, castID, notInterruptible,
          spellID, barID = UnitCastingInfo(unit)
    if name then
        local ps, pe = Plain(startMS), Plain(endMS)
        return {
            channel     = false,
            name        = name,
            nameIsPlain = not NCB.IsSecret(name),
            icon        = icon,
            spellID     = Plain(spellID),
            barID       = Plain(barID),
            notInterruptible    = Plain(notInterruptible),  -- true / false / nil
            notInterruptibleRaw = notInterruptible,         -- for display sinks only
            startTime   = ps and ps / 1000 or nil,
            endTime     = pe and pe / 1000 or nil,
            startRaw    = startMS,
            endRaw      = endMS,
        }
    end

    local cname, ctext, cicon, cstartMS, cendMS, cisTrade, cnotInterruptible,
          cspellID, isEmpowered, numStages, cbarID = UnitChannelInfo(unit)
    if cname then
        local ps, pe = Plain(cstartMS), Plain(cendMS)
        return {
            channel     = true,
            empower     = Plain(isEmpowered) and true or false,
            stages      = Plain(numStages),
            name        = cname,
            nameIsPlain = not NCB.IsSecret(cname),
            icon        = cicon,
            spellID     = Plain(cspellID),
            barID       = Plain(cbarID),
            notInterruptible    = Plain(cnotInterruptible),
            notInterruptibleRaw = cnotInterruptible,
            startTime   = ps and ps / 1000 or nil,
            endTime     = pe and pe / 1000 or nil,
            startRaw    = cstartMS,
            endRaw      = cendMS,
        }
    end
    return nil
end

local function LearnedLength(spellID)
    if not spellID or not NCB.char then return nil end
    return NCB.char.learned[spellID]
end

local function Learn(spellID, length)
    if not spellID or not NCB.char then return end
    if type(length) ~= "number" or length <= 0.1 or length > 120 then return end
    NCB.char.learned[spellID] = length
end

--------------------------------------------------------------------------------
-- Cast lifecycle
--------------------------------------------------------------------------------
-- The good path on 12.0: give the bar the client's own Duration object and it
-- animates itself, in the right direction, at the right speed - and the same
-- object hands a FontString a real countdown. Nothing passes through Lua, so
-- nothing has to be readable.
local function AttachTimer(f, cast, unit)
    if not (HAS_TIMER_API and f.bar.SetTimerDuration) then return false end

    local getter = (cast.empower and _G.UnitEmpoweredChannelDuration)
                or (cast.channel and _G.UnitChannelDuration)
                or _G.UnitCastingDuration
    if not getter then return false end

    local ok, durationObj = pcall(getter, unit)
    if not ok or not durationObj then return false end

    -- A channel counts down; a cast and an empower count up.
    local direction = (cast.channel and not cast.empower)
                      and TIMER_DIR.RemainingTime or TIMER_DIR.ElapsedTime
    ok = pcall(f.bar.SetTimerDuration, f.bar, durationObj, TIMER_INTERP.Immediate, direction)
    return ok and true or false
end

-- Fallback for a client without the timer API: hand the raw timestamps to
-- SetMinMaxValues and feed the bar the clock. Accurate, but with no way to get a
-- number out of it.
local function TrySecretDrive(f, cast)
    if not (cast.startRaw and cast.endRaw) then return false end

    local ok = pcall(f.bar.SetMinMaxValues, f.bar, cast.startRaw, cast.endRaw)
    if ok then
        ok = pcall(f.bar.SetValue, f.bar, GetTime() * 1000)
    end
    if not ok then
        f.bar:SetMinMaxValues(0, 1)
        f.bar:SetValue(0)
        return false
    end
    return true
end

function Bars:Begin(f, cast)
    local cfg = NCB.Config(f.cfgKey)
    if not (NCB.db.enabled and cfg.enabled) then return end

    local now = GetTime()
    cast.startedAt = cast.startTime or now

    -- A demo must not attach to the client's timer: it would either find nothing
    -- or, worse, latch onto whatever that unit is really casting.
    if not cast.fake and AttachTimer(f, cast, f.unit) then
        -- Best case, and the normal one on 12.0: an accurate bar *and* a real
        -- countdown, for any unit, without reading a thing.
        cast.mode = "timer"
    elseif cast.startTime and cast.endTime then
        -- Times we are allowed to do arithmetic on: a full bar, with a timer.
        cast.mode     = "timed"
        cast.duration = cast.endTime - cast.startTime
        f.bar:SetMinMaxValues(0, 1)
    elseif TrySecretDrive(f, cast) then
        -- An accurate bar we are not allowed to read. No timer, no spark maths,
        -- and channels fill rather than drain, because inverting the value would
        -- mean computing with the stamps.
        cast.mode = "secret"
    else
        cast.duration = LearnedLength(cast.spellID)
        cast.mode     = cast.duration and "guessed" or "unknown"
        f.bar:SetMinMaxValues(0, 1)
    end

    cast.target, cast.targetClass, cast.onYou, cast.targetIsPlain = SnapshotTarget(f.unit)

    f.cast   = cast
    f.finish = nil
    f:SetAlpha(1)
    f:Show()

    self:LayoutPips(f)
    self:Redraw(f)
end

-- Re-read the client after a push-back or a channel tick changed the numbers.
function Bars:Update(f)
    if not f.cast then return end
    local fresh = ReadCast(f.unit)
    if not fresh then return end
    if f.cast.mode == "timer" then
        -- The Duration object is re-fetched: a push-back replaces it rather than
        -- editing it.
        AttachTimer(f, f.cast, f.unit)
    elseif fresh.startTime and fresh.endTime then
        f.cast.startedAt = fresh.startTime
        f.cast.duration  = fresh.endTime - fresh.startTime
        f.cast.mode      = "timed"
        f.bar:SetMinMaxValues(0, 1)
    elseif f.cast.mode == "secret" then
        -- A push-back moved the stamps; re-seat the widget on the new pair.
        f.cast.startRaw, f.cast.endRaw = fresh.startRaw, fresh.endRaw
        TrySecretDrive(f, f.cast)
    end

    f.cast.notInterruptible    = fresh.notInterruptible
    f.cast.notInterruptibleRaw = fresh.notInterruptibleRaw
    f.cast.target, f.cast.targetClass, f.cast.onYou, f.cast.targetIsPlain =
        SnapshotTarget(f.unit)
    self:Redraw(f)
end

function Bars:Finish(f, kind)
    local cfg = NCB.Config(f.cfgKey)
    local cast = f.cast
    if not cast then return end

    -- A cast we had to time ourselves has just told us how long it really was.
    if kind == "success" then
        Learn(cast.spellID, GetTime() - cast.startedAt)
    end

    f.finish = {
        at    = GetTime(),
        kind  = kind,
        color = (kind == "success") and cfg.colorSuccess or cfg.colorFailed,
        label = (kind == "interrupted") and "Interrupted"
                or (kind == "failed") and "Failed"
                or nil,
    }
    -- Where the bar's value is ours to set, an interrupt is left frozen at the
    -- point it landed, which is worth seeing. Where the widget owns the scale -
    -- driven by a Duration object or by secret timestamps - it has to be reclaimed
    -- outright, because it would otherwise keep animating past the end.
    local ownsValue = (cast.mode ~= "timer" and cast.mode ~= "secret")
    f.cast = nil

    f.uninterruptible:SetAlpha(0)
    if ownsValue then
        f.bar:SetValue(kind == "success" and 1 or (f.bar:GetValue() or 0))
    else
        f.bar:SetMinMaxValues(0, 1)
        f.bar:SetValue(1)
    end
    f.bar:SetStatusBarColor(unpack(f.finish.color))
    f.spark:Hide()
    f.latency:Hide()
    if f.finish.label then f.time:SetText("") end
    if f.finish.label and cfg.showName then f.name:SetText(f.finish.label) end
end

function Bars:Stop(f)
    f.cast, f.finish = nil, nil
    if f.preview then return end
    f:Hide()
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
-- These events also fire for instant casts, and a unit can fire one off in the
-- middle of a hardcast. If both the running bar and the event name a spell, they
-- have to be the same spell before the bar is allowed to end.
local function SameSpell(f, spellID)
    local mine = f.cast and f.cast.spellID
    spellID = Plain(spellID)
    if not mine or not spellID then return true end
    return mine == spellID
end

function Bars:OnUnitEvent(f, event, unit, castGUID, spellID, interruptedBy)
    if unit ~= f.unit then return end
    if NCB.debug then
        -- tostring() on a secret value is itself off limits, so the id is reported
        -- only when it survives Plain().
        local id = Plain(spellID)
        NCB.Print(string.format("|cff8cd2ff%s|r %s spell=%s", unit, event,
            id and tostring(id) or "secret/none"))
    end
    local cfg = NCB.Config(f.cfgKey)
    if not (NCB.db and NCB.db.enabled and cfg and cfg.enabled) then return end

    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START"
       or event == "UNIT_SPELLCAST_EMPOWER_START" then
        local cast = ReadCast(unit)
        if cast then self:Begin(f, cast) end

    elseif event == "UNIT_SPELLCAST_DELAYED" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE"
           or event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
        self:Update(f)

    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        if f.cast then
            f.cast.notInterruptible = (event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE")
            self:Redraw(f)
        end

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        NCB.Interrupts:OnInterrupted(unit, spellID, interruptedBy,
                                     f.cast and f.cast.name or nil)
        if f.cast and SameSpell(f, spellID) then self:Finish(f, "interrupted") end

    elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET" then
        if f.cast and not f.cast.channel and SameSpell(f, spellID) then
            self:Finish(f, "failed")
        end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Also fires for instants, and once per channel tick. Only the spell the
        -- bar is actually drawing, and only a non-channel one, ends here.
        if f.cast and not f.cast.channel and SameSpell(f, spellID) then
            self:Finish(f, "success")
        end

    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        -- A channel has no INTERRUPTED event of its own: being kicked shows up here,
        -- as a CHANNEL_STOP that carries somebody in `interruptedBy`. Without this a
        -- kicked channel finished green, as though it had run its course.
        NCB.Interrupts:OnInterrupted(unit, spellID, interruptedBy,
                                     f.cast and f.cast.name or nil)
        if f.cast and SameSpell(f, spellID) then
            self:Finish(f, interruptedBy and "interrupted" or "success")
        end

    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        if f.cast and SameSpell(f, spellID) then self:Finish(f, "success") end
    end
end

-- "target", "focus" and "pet" name whoever is in that slot right now. Re-arming
-- the filter whenever the slot changes costs nothing and removes any question of
-- a registration going stale when the unit behind the token is swapped out.
local function Rearm(f)
    if f.unit == "player" then return end
    for _, event in ipairs(SPELL_EVENTS) do
        pcall(f.RegisterUnitEvent, f, event, f.unit)
    end
end

-- Units that swap out from under us (a new target, a summoned pet, a boss joining
-- the encounter) have to be resynced: their cast started before we were watching.
function Bars:Resync(unit)
    local f = Bars.frames[unit]
    if not f then return end
    Rearm(f)

    local cfg = NCB.Config(f.cfgKey)
    if not (NCB.db.enabled and cfg.enabled) then return end
    if f.preview then return end

    local cast = ReadCast(unit)
    if cast then
        self:Begin(f, cast)
    else
        self:Stop(f)
    end
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_TARGET_CHANGED")
watcher:RegisterEvent("PLAYER_FOCUS_CHANGED")
watcher:RegisterEvent("UNIT_PET")
watcher:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:SetScript("OnEvent", function(_, event, arg1)
    if not NCB.db then return end
    if event == "PLAYER_TARGET_CHANGED" then
        Bars:Resync("target")
    elseif event == "PLAYER_FOCUS_CHANGED" then
        Bars:Resync("focus")
    elseif event == "UNIT_PET" then
        if arg1 == "player" then Bars:Resync("pet") end
    else
        for _, f in ipairs(Bars.list) do Bars:Resync(f.unit) end
        if event == "PLAYER_ENTERING_WORLD" then Bars:HideBlizzard() end
    end
end)

--------------------------------------------------------------------------------
-- Safety net
-- Events are the fast path, not the only path. A slow sweep catches anything the
-- event stream misses - a cast that began in the moment a unit token was being
-- swapped, an event a unit filter never delivered - at a cost of five checks a
-- second across nine frames, which is nothing.
--------------------------------------------------------------------------------
local POLL_INTERVAL = 0.2

local function SameCast(cast, live)
    if not cast or not live then return false end
    -- barID exists in 12.0 precisely because castID went secret: it is the one
    -- plain identity two casts can still be compared by.
    if cast.barID and live.barID then return cast.barID == live.barID end
    if cast.spellID and live.spellID then return cast.spellID == live.spellID end
    -- No identity we are allowed to compare - a target's spellID and name are both
    -- secret. "Something is being cast and the bar is already running" is treated
    -- as the same cast, rather than restarting the bar five times a second. Events
    -- are what catch one cast being replaced by another.
    return true
end

local poller = CreateFrame("Frame", nil, UIParent)
local pollAccum = 0
poller:SetScript("OnUpdate", function(_, elapsed)
    pollAccum = pollAccum + elapsed
    if pollAccum < POLL_INTERVAL then return end
    pollAccum = 0
    if not (NCB.db and NCB.db.enabled) then return end

    -- Your interrupt coming off cooldown has to recolour a cast that is already in
    -- flight - that is the whole point of the feature. Redraw only on the edge, so
    -- this costs one cooldown lookup per tick and nothing else.
    local ready = NCB.Interrupts:Ready()
    if ready ~= Bars.lastInterruptReady then
        Bars.lastInterruptReady = ready
        for _, f in ipairs(Bars.list) do
            if f.cast then Bars:Redraw(f) end
        end
    end

    for _, f in ipairs(Bars.list) do
        local cfg = NCB.Config(f.cfgKey)
        -- Leave demos, previews and bars mid-fade alone: none of those are
        -- describing a real cast, and the sweep would cut them short.
        if cfg and cfg.enabled and not f.preview and not f.finish
           and not (f.cast and f.cast.fake) then
            -- ReadCast is nil for a unit that is not there, so there is no need to
            -- ask UnitExists and risk a boolean we are not allowed to test.
            local live = ReadCast(f.unit)
            if live and not SameCast(f.cast, live) then
                Bars:Begin(f, live)
            elseif not live and f.cast then
                -- Only call it an interrupt when we knew the length and it stopped
                -- short of it. Without that evidence, assume it simply finished.
                local kind = "success"
                if f.cast.duration
                   and (GetTime() - f.cast.startedAt) < f.cast.duration - 0.15 then
                    kind = "interrupted"
                end
                Bars:Finish(f, kind)
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Diagnostics
-- Answers "why is that bar not showing" without a guessing game: what the addon
-- thinks each bar is, where it put it, whether the unit is even there, and what
-- the client says that unit is casting this instant.
--------------------------------------------------------------------------------
function NCB.Diagnostics()
    NCB.Print("v" .. NCB.version .. " diagnostics")
    print(string.format("  master |cffffd479%s|r, bars |cffffd479%s|r, secret-value API %s",
        NCB.db.enabled and "on" or "OFF",
        NCB.db.locked and "locked" or "unlocked",
        NCB.secretsExist and "present" or "absent"))

    for _, f in ipairs(Bars.list) do
        local cfg = NCB.Config(f.cfgKey)
        local point, _, _, x, y = f:GetPoint(1)
        print(string.format(
            "  |cffffd479%-7s|r %-3s frame:%-6s alpha %.2f  %dx%d @ %s %d,%d  events:%s",
            f.unit,
            cfg.enabled and "on" or "OFF",
            f:IsShown() and "shown" or "hidden",
            f:GetAlpha(),
            math.floor(f:GetWidth() + 0.5), math.floor(f:GetHeight() + 0.5),
            tostring(point), math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5),
            f:IsEventRegistered("UNIT_SPELLCAST_START") and "yes" or "|cffff4040NO|r"))

        -- Nothing secret is printed: a secret value cannot go through string.format
        -- at all, so each one is reported as the fact that it is secret.
        local live = ReadCast(f.unit)
        if live then
            local interrupt = "unknown"
            if live.notInterruptible ~= nil then
                interrupt = live.notInterruptible and "cannot" or "can"
            end
            print(string.format(
                "        casting: %s | times: %s | interrupt: %s | drawing as: %s",
                live.nameIsPlain and live.name or "|cffaaaaaa<secret>|r",
                (live.startTime and live.endTime) and "readable" or "|cffaaaaaa secret|r",
                interrupt,
                f.cast and tostring(f.cast.mode) or "|cffff4040not drawing|r"))
        else
            print("        nothing being cast by that unit right now")
        end
    end
    local sample = Bars.list[1]
    print(string.format("  client timer API: %s   secret-boolean display: %s",
        HAS_TIMER_API and "|cff40ff40present|r" or "|cffff4040missing|r",
        (sample and sample.shield.SetAlphaFromBoolean)
            and "|cff40ff40present|r" or "|cffff4040missing|r"))
    -- Interrupt tracking, which is the one thing here the client still answers
    -- plainly, so a wrong spell id is worth being loud about.
    local spells = NCB.Interrupts.spells
    if #spells == 0 then
        local candidates = #NCB.Interrupts:Candidates()
        print(string.format("  interrupt: |cffff4040none found|r for %s - %s",
            tostring(NCB.Interrupts.class),
            candidates == 0 and "no entry for this class"
                or "class has entries but you know none of them; set ids in the options"))
    else
        local names = {}
        for _, id in ipairs(spells) do
            names[#names + 1] = NCB.Interrupts:Name(id) .. " (" .. id .. ")"
        end
        local ready = NCB.Interrupts:Ready()
        print(string.format("  interrupt: %s%s | right now: %s",
            table.concat(names, ", "),
            NCB.Interrupts.fromOverride and " |cffaaaaaa(your override)|r" or "",
            ready == nil and "unknown"
                or (ready and "|cff40ff40ready|r" or "|cffff4040on cooldown|r")))
    end
    print(string.format("  on landing one: announce %s, sound %s%s",
        tostring(NCB.db.interruptAnnounce),
        NCB.db.interruptSound and ("on (" .. tostring(NCB.db.interruptSoundName) .. ")") or "off",
        NCB.Interrupts.watching and "" or " |cffaaaaaa- not watching|r"))

    print("  |cffaaaaaadrawing modes: timer|r = client-driven bar and countdown, " ..
          "|cffaaaaaatimed|r = our own maths, |cffaaaaaasecret|r = accurate bar but no " ..
          "numbers, |cffaaaaaaguessed|r = remembered length, |cffaaaaaaunknown|r = sweep.")
    print("  |cffaaaaaa/ncb debug|r logs every spellcast event as it arrives.")
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------
-- Everything that only changes when the cast changes. The per-frame work in
-- Advance() is deliberately kept to the bar value, the spark and the timer text.
function Bars:Redraw(f)
    local cfg  = NCB.Config(f.cfgKey)
    local cast = f.cast
    if not cast then return end

    -- The bar itself takes the casting/channelling colour. "Cannot be interrupted"
    -- cannot pick a colour with an `if`, so it is an overlay in that colour whose
    -- alpha the secret boolean sets for us.
    f.bar:SetStatusBarColor(unpack(cast.channel and cfg.colorChannel or cfg.colorCast))

    pcall(f.icon.SetTexture, f.icon, cast.icon or 136243)

    -- Three cases, in order of how much the client is willing to say: a plain
    -- answer we can branch on, a secret answer we can only pour into a widget, or
    -- no answer at all.
    local rawFlag = cast.notInterruptibleRaw
    local tint    = self:InterruptTint(f)

    if cast.notInterruptible ~= nil then
        f.shield:SetAlpha(1)
        f.shield:SetShown(cfg.showShield and cast.notInterruptible)
        f.uninterruptible:SetAlpha(cast.notInterruptible and 1 or 0)
        -- Plain answer, so the AND is just an `and`.
        if tint and not cast.notInterruptible then
            f.interrupt:SetVertexColor(tint[1], tint[2], tint[3])
            f.interrupt:SetAlpha(1)
        else
            f.interrupt:SetAlpha(0)
        end

    elseif NCB.IsSecret(rawFlag) and f.shield.SetAlphaFromBoolean then
        f.shield:SetShown(cfg.showShield)
        f.shield:SetAlphaFromBoolean(rawFlag, 1, 0)
        f.uninterruptible:SetAlphaFromBoolean(rawFlag, 1, 0)
        if tint then
            f.interrupt:SetVertexColor(tint[1], tint[2], tint[3])
            -- Inverted against the shield: 0 when the cast cannot be interrupted,
            -- 1 when it can. Nothing here learns which of those it is.
            f.interrupt:SetAlphaFromBoolean(rawFlag, 0, 1)
        else
            f.interrupt:SetAlpha(0)
        end

    else
        f.shield:Hide()
        f.uninterruptible:SetAlpha(0)
        f.interrupt:SetAlpha(0)
    end

    -- The target can only be folded into the spell name when both are strings we
    -- are allowed to join. When either is secret it moves to its own line rather
    -- than being dropped.
    local inline = cfg.showTarget and cfg.targetPos == "inline" and cast.target
                   and cast.nameIsPlain and cast.targetIsPlain

    if cfg.showName then
        local nameText = Trim(cast.name, cfg.nameMaxChars)
        if inline then
            nameText = nameText .. " |cff777777>|r " .. self:TargetString(f, cast)
        end
        SafeSetText(f.name, nameText, "Casting")
    else
        f.name:SetText("")
    end

    local separate = (cfg.showTarget and cast.target and not inline) and true or false
    f.target:SetShown(separate)
    if separate then
        SafeSetText(f.target, cast.target)
        f.target:SetTextColor(self:TargetColor(f, cast))
    end

    f.spark:SetShown(cfg.showSpark)

    -- Latency only means anything for your own casts: it is the slice at the end
    -- that has already left your client, so pressing the next button inside it is
    -- free.
    -- The safe zone needs a real length to take a fraction of. Under the timer API
    -- that has to come out of the Duration object, and only if it survives Plain().
    local total = cast.duration
    if not total and f.bar.GetTimerDuration then
        local obj = f.bar:GetTimerDuration()
        if obj and obj.GetTotalDuration then
            local ok, t = pcall(obj.GetTotalDuration, obj)
            if ok then total = Plain(t) end
        end
    end

    local showLatency = cfg.showLatency and f.unit == "player" and total
    if showLatency then
        local _, _, _, world = GetNetStats()
        local lag = (tonumber(world) or 0) / 1000
        local frac = math.min(0.4, lag / math.max(total, 0.1))
        f.latency:ClearAllPoints()
        f.latency:SetPoint("TOPRIGHT", f.bar, "TOPRIGHT", 0, 0)
        f.latency:SetPoint("BOTTOMRIGHT", f.bar, "BOTTOMRIGHT", 0, 0)
        f.latency:SetWidth(math.max(1, cfg.width * frac))
        f.latency:Show()
    else
        f.latency:Hide()
    end
end

-- Only ever called for a target name we know is a plain string; the separate
-- fontstring path colours itself with SetTextColor instead, which needs no
-- concatenation and so works on a secret name too.
function Bars:TargetString(f, cast)
    local cfg = NCB.Config(f.cfgKey)
    if not cast.target then return "" end
    if cast.onYou and cfg.warnOnYou then
        return "|cffff4040" .. cast.target .. "|r"
    end
    if cfg.targetClassColor and cast.targetClass then
        return "|cff" .. ColorHex(ClassColor(cast.targetClass)) .. cast.target .. "|r"
    end
    return cast.target
end

-- The colour an interruptible cast should take on this bar, or nil to leave it on
-- the normal casting colour. Only the plain half of the question is answered here;
-- whether the cast in front of you can be interrupted at all is decided by the
-- widget, in Redraw.
function Bars:InterruptTint(f)
    local cfg = NCB.Config(f.cfgKey)
    if not (cfg.showInterruptReady or cfg.showInterruptNotReady) then return nil end

    local ready = NCB.Interrupts:Ready()
    if ready == nil then return nil end   -- no interrupt to speak of; stand down

    if ready then
        return cfg.showInterruptReady and cfg.colorInterruptReady or nil
    end
    return cfg.showInterruptNotReady and cfg.colorInterruptNotReady or nil
end

function Bars:TargetColor(f, cast)
    local cfg = NCB.Config(f.cfgKey)
    if cast.onYou and cfg.warnOnYou then return 1, 0.25, 0.25 end
    if cfg.targetClassColor and cast.targetClass then return ClassColor(cast.targetClass) end
    return unpack(cfg.colorText)
end

-- Empowered casts (evoker) hold at each stage; the dividers mark where. 12.0 hands
-- out the boundaries as percentages, which is all the drawing needs - though which
-- stage is *currently* held is no longer knowable by anyone, addons included.
function Bars:LayoutPips(f)
    for _, pip in ipairs(f.pips) do pip:Hide() end

    local cast = f.cast
    if not (cast and cast.empower and _G.UnitEmpoweredStagePercentages) then return end

    local ok, percentages = pcall(UnitEmpoweredStagePercentages, f.unit)
    if not ok or type(percentages) ~= "table" then return end

    local cfg = NCB.Config(f.cfgKey)
    for index, percentage in ipairs(percentages) do
        local p   = Plain(percentage)
        local pip = f.pips[index]
        if not (p and pip) then break end
        if p > 0 and p < 1 then
            pip:ClearAllPoints()
            pip:SetPoint("TOP", f.bar, "TOPLEFT", cfg.width * p, 0)
            pip:SetPoint("BOTTOM", f.bar, "BOTTOMLEFT", cfg.width * p, 0)
            pip:Show()
        end
    end
end

local function TimeText(cfg, elapsed, remaining, duration, unknown)
    if unknown then return "" end
    local fmt = "%." .. cfg.decimals .. "f"
    if cfg.timeFormat == "elapsed" then
        return string.format(fmt, elapsed)
    elseif cfg.timeFormat == "both" then
        return string.format(fmt .. " / " .. fmt, elapsed, duration)
    end
    return string.format(fmt, remaining)
end

-- The Duration object's numbers may themselves be secret. SetFormattedText takes
-- them anyway - that is the whole point of it - so "time remaining" always works.
-- "Elapsed" needs a subtraction, which secrets may refuse, so it is attempted and
-- falls back to the remaining time rather than to nothing.
local function WriteTimerText(f, cfg, obj)
    local fmt = "%." .. cfg.decimals .. "f"

    local ok, remaining = pcall(obj.GetRemainingDuration, obj)
    if not ok then f.time:SetText("") return end

    local function justRemaining()
        f.time:SetFormattedText(fmt, remaining or 0)
    end

    if cfg.timeFormat == "remaining" or not obj.GetTotalDuration then
        justRemaining()
        return
    end

    local okTotal, total = pcall(obj.GetTotalDuration, obj)
    if not okTotal or not total then justRemaining() return end

    local okMath, spent = pcall(function() return total - remaining end)
    if not okMath then justRemaining() return end

    if cfg.timeFormat == "elapsed" then
        f.time:SetFormattedText(fmt, spent)
    else
        f.time:SetFormattedText(fmt .. " / " .. fmt, spent, total)
    end
end

function Bars:Advance(f, elapsed)
    local cfg = NCB.Config(f.cfgKey)
    if not cfg then return end
    local now = GetTime()

    -- Finished: hold at full, then fade.
    if f.finish then
        local age = now - f.finish.at
        if age >= cfg.holdTime + cfg.fadeTime then
            f.finish = nil
            if f.preview then
                self:StartPreview(f)
            else
                f:Hide()
            end
        elseif age > cfg.holdTime then
            f:SetAlpha(1 - (age - cfg.holdTime) / math.max(cfg.fadeTime, 0.01))
        end
        return
    end

    local cast = f.cast
    if not cast then return end

    if cast.mode == "timer" then
        -- The bar is animating itself. All that is left is the number, and that
        -- comes out of the Duration object straight into SetFormattedText.
        if cfg.showTime then
            local obj = f.bar.GetTimerDuration and f.bar:GetTimerDuration()
            if obj then WriteTimerText(f, cfg, obj) else f.time:SetText("") end
        end
        return
    end

    if cast.mode == "secret" then
        -- The widget owns the arithmetic here: it was seated on the client's own
        -- timestamps, and all we do is keep feeding it the clock. We never learn
        -- the fraction, so there is no timer to write.
        pcall(f.bar.SetValue, f.bar, GetTime() * 1000)
        f.time:SetText("")
        return
    end

    if cast.mode == "unknown" then
        -- We were never told how long this takes. Sweep rather than invent a
        -- percentage: the bar says "casting", the timer says nothing.
        local t = ((now - cast.startedAt) % 1.4) / 1.4
        f.bar:SetValue(cast.channel and (1 - t) or t)
        f.time:SetText("")
        return
    end

    local duration = cast.duration or 0
    local run      = now - cast.startedAt
    if run < 0 then run = 0 end
    if run > duration then run = duration end
    local remaining = duration - run
    local pct = duration > 0 and (run / duration) or 0

    local value = (cast.channel and not cast.empower) and (1 - pct) or pct
    f.bar:SetValue(value)

    if cfg.showTime then
        local text = TimeText(cfg, run, remaining, duration, false)
        -- The length is remembered from the last time we watched this spell, not
        -- something the client told us. Say so rather than present it as fact.
        if cast.mode == "guessed" then text = text .. "?" end
        f.time:SetText(text)
    end

    -- A cast whose end no event will announce - one we timed ourselves from a
    -- remembered length, a demo, or a preview - has to retire itself. A real cast
    -- is left alone: its STOP event is the truth, and finishing early would hide a
    -- push-back.
    if remaining <= 0 and (cast.mode == "guessed" or cast.fake or f.preview) then
        self:Finish(f, "success")
    end
end

--------------------------------------------------------------------------------
-- Preview / test
--------------------------------------------------------------------------------
function Bars:StartPreview(f)
    local demo = DEMO[((f.listIndex or 1) % #DEMO) + 1]
    f.preview = true
    f.finish  = nil
    -- Reset the scale: the bar may have last been seated on a real cast's secret
    -- timestamps, and a 0-to-1 value against those would read as permanently empty.
    f.bar:SetMinMaxValues(0, 1)
    f.cast = {
        name      = demo.name,
        icon      = demo.icon,
        startedAt = GetTime(),
        duration  = demo.length,
        mode      = "timed",
        channel   = false,
        notInterruptible = false,
        nameIsPlain = true,
        target    = UnitName("player"),
        targetClass = select(2, UnitClass("player")),
        targetIsPlain = true,
        onYou     = false,
    }
    f:SetAlpha(1)
    f:Show()
    self:Redraw(f)
end

function Bars:StopPreview(f)
    f.preview = false
    f.cast, f.finish = nil, nil
    f:Hide()
    self:Resync(f.unit)
end

function Bars:ShowPreviews()
    for _, f in ipairs(Bars.list) do
        local cfg = NCB.Config(f.cfgKey)
        if NCB.db.enabled and cfg.enabled then
            -- Only start one that is not already running: ApplyAll lands here on
            -- every tick of a slider drag, and restarting the demo each time would
            -- leave the bar frozen at zero.
            if not f.preview then self:StartPreview(f) end
        else
            f.preview = false
            f:Hide()
        end
    end
end

local function DemoCast(f, notInterruptible)
    local demo = DEMO[((f.listIndex or 1) % #DEMO) + 1]
    local now  = GetTime()
    return {
        name = demo.name, icon = demo.icon, channel = false, fake = true,
        nameIsPlain = true,
        notInterruptible = notInterruptible or false,
        startTime = now, endTime = now + demo.length,
    }
end

-- One demo cast on every enabled bar, without unlocking anything.
function Bars:TestAll()
    for _, f in ipairs(Bars.list) do
        local cfg = NCB.Config(f.cfgKey)
        if NCB.db.enabled and cfg.enabled and not f.preview then
            self:Begin(f, DemoCast(f, f.cfgKey == "boss"))
        end
    end
end

function Bars:TestOne(key)
    for _, f in ipairs(Bars.list) do
        local cfg = NCB.Config(f.cfgKey)
        if f.cfgKey == key and NCB.db.enabled and cfg.enabled and not f.preview then
            self:Begin(f, DemoCast(f))
        end
    end
end

function Bars:SetLocked(locked)
    NCB.db.locked = locked and true or false
    -- The announcement moves with the same unlock, so one command places the whole
    -- addon rather than leaving one piece on a switch of its own.
    NCB.Interrupts:SetLocked(NCB.db.locked)
    for _, f in ipairs(Bars.list) do
        f:EnableMouse(not NCB.db.locked)
        f.dragLabel:SetShown(not NCB.db.locked)
    end
    if NCB.db.locked then
        for _, f in ipairs(Bars.list) do
            f.preview = false
            f.cast, f.finish = nil, nil
            f:Hide()
            self:Resync(f.unit)
        end
    else
        self:ShowPreviews()
    end
    if NCB.RefreshOptions then NCB.RefreshOptions() end
end

--------------------------------------------------------------------------------
-- Blizzard's own bars
-- Unregistering the events is what actually stops them; the OnShow hook is only a
-- backstop, and it stands down in combat because some of these frames are
-- protected. Turning this back off needs a /reload.
--------------------------------------------------------------------------------
local function DisableBlizzFrame(name)
    local frame = _G[name]
    if not frame then return end

    -- The player bar has a supported way to stand down: hand it no unit.
    if frame.SetUnit then pcall(frame.SetUnit, frame, nil) end
    if frame.UnregisterAllEvents then pcall(frame.UnregisterAllEvents, frame) end
    if frame.Hide then pcall(frame.Hide, frame) end
    if frame.HookScript and not frame.__ncbHidden then
        frame.__ncbHidden = true
        frame:HookScript("OnShow", function(self)
            if not InCombatLockdown() then self:Hide() end
        end)
    end
end

function Bars:HideBlizzard()
    if not NCB.db then return end
    for _, def in ipairs(NCB.UNITS) do
        local cfg = NCB.Config(def.key)
        if cfg and cfg.hideBlizzard then
            for _, name in ipairs(def.blizz) do DisableBlizzFrame(name) end
        end
    end
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------
function Bars:Init()
    if self.ready then return end
    self.ready = true

    for _, def in ipairs(NCB.UNITS) do
        for index, unit in ipairs(NCB.UnitTokens(def)) do
            local f = CreateBar(def.key, unit, index)
            f.listIndex = #Bars.list
        end
    end

    self:ApplyAll()
    self:SetLocked(NCB.db.locked)
end
