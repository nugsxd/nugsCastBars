--------------------------------------------------------------------------------
-- nugsCastBars
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsCastBars  -  GCD.lua
-- A slim bar tracking the global cooldown.
--
-- Two ways of showing it, because they answer different questions:
--
--   loop    A metronome. The bar sweeps continuously at the length of your global
--           and restarts the moment one is triggered, so between presses it keeps
--           beating rather than sitting empty. This is the one for keeping rhythm -
--           you can see where the next window opens even when nothing is running.
--   window  The conventional behaviour: show the global while it runs, then go
--           quiet until the next one.
--
-- The global cooldown is itself a spell - 61304, and has been for as long as anyone
-- has needed to ask - so it is read like any other cooldown.
--
-- WHY TWO STATUS BARS: window mode hands the client's own Duration object to
-- StatusBar:SetTimerDuration, which is what keeps it correct in combat without a
-- number passing through Lua. Loop mode cannot use that - a duration object only
-- exists while a cooldown is running, and the loop has to keep going between them -
-- so it drives SetValue off our own clock instead. Those two do not mix on one
-- widget: a *finished* timer keeps painting its terminal state, and a later
-- SetValue on the same bar does not necessarily repaint it. There is no documented
-- way to detach a timer once armed. Two bars, one shown at a time, sidesteps the
-- whole question rather than betting on undocumented repaint behaviour.
--------------------------------------------------------------------------------
local ADDON_NAME, NCB = ...

local GCD = {}
NCB.GCD = GCD

local Plain = NCB.Plain

local GCD_SPELL = 61304

local TIMER_DIR     = Enum and Enum.StatusBarTimerDirection
local TIMER_INTERP  = Enum and Enum.StatusBarInterpolation
local HAS_TIMER_API = (TIMER_DIR ~= nil and TIMER_INTERP ~= nil)

-- Fast enough that the sweep looks continuous and the reset lands within a frame
-- or two of the press, without running Lua on every frame.
local POLL = 0.03

-- What counts as a believable global. Anything outside this is some other cooldown
-- reported through the same call, or a value we should not have been reading.
local MIN_LEN, MAX_LEN = 0.5, 1.7
local DEFAULT_LEN = 1.5

local frame

--------------------------------------------------------------------------------
-- Reading the global
--------------------------------------------------------------------------------
local function DurationHandle()
    local fn = C_Spell and C_Spell.GetSpellCooldownDuration
    if not fn then return nil end
    local ok, obj = pcall(fn, GCD_SPELL)
    if ok then return obj end
    return nil
end

-- true / false / nil, where nil means the client would not say and the bar stands
-- down rather than guessing. isActive is flagged NeverSecret, so this is a real
-- boolean we are allowed to branch on even mid-fight.
local function IsRunning()
    if not (C_Spell and C_Spell.GetSpellCooldown) then return nil end
    local info = C_Spell.GetSpellCooldown(GCD_SPELL)
    if not info then return nil end
    return info.isActive and true or false
end
GCD.IsRunning = IsRunning

-- How long a global lasts right now. Haste moves it, so it is re-learned rather
-- than assumed: read plainly when the client allows, and otherwise measured off our
-- own clock, which is always legal. Same approach the cast bars use for cast length.
function GCD:Length()
    return self.length or DEFAULT_LEN
end

function GCD:LearnFromAPI()
    if not (C_Spell and C_Spell.GetSpellCooldown) then return end
    local info = C_Spell.GetSpellCooldown(GCD_SPELL)
    if not info then return end
    local d = Plain(info.duration)
    if d and d >= MIN_LEN and d <= MAX_LEN then
        self.length = d
        self.lengthFrom = "client"
    end
end

--------------------------------------------------------------------------------
-- The frame
--------------------------------------------------------------------------------
-- A one-pixel outline drawn just outside the frame, so it never eats into a bar
-- this thin. Mirrors the helper in Bars.lua; kept local so this file stands alone.
local function AddBorder(f)
    local edges = {}
    local function edge(p1, x1, y1, p2, x2, y2, w, h)
        local t = f:CreateTexture(nil, "OVERLAY", nil, 2)
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

local function SavePosition(f)
    local point, _, relPoint, x, y = f:GetPoint(1)
    if not point then return end
    local cfg = NCB.db.gcd
    cfg.point    = point
    cfg.relPoint = relPoint or point
    cfg.x = math.floor(x + 0.5)
    cfg.y = math.floor(y + 0.5)
end

local function NewBar(parent)
    local b = CreateFrame("StatusBar", nil, parent)
    b:SetAllPoints()
    b:SetMinMaxValues(0, 1)
    b:SetValue(0)
    b:Hide()
    return b
end

local function Build()
    if frame then return end

    local f = CreateFrame("Frame", "nugsCastBarsGCD", UIParent)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:Hide()

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()

    -- See the header: one is timer-driven, the other value-driven, and they are
    -- kept apart on purpose.
    f.timerBar = NewBar(f)
    f.loopBar  = NewBar(f)

    f.borders = AddBorder(f)

    -- The status bars are child frames, and a child draws over every texture its
    -- parent owns no matter what layer that texture is on. Anything that has to
    -- appear ON the fill therefore cannot live on the frame itself - it needs a
    -- frame of its own, stacked above both bars. (The border escapes this because
    -- it is drawn outside the frame's rectangle, and the background wants to be
    -- underneath anyway.)
    f.overlay = CreateFrame("Frame", nil, f)
    f.overlay:SetAllPoints()

    -- The end of the run, where the command you press will still land in time.
    f.latency = f.overlay:CreateTexture(nil, "ARTWORK")
    f.latency:Hide()

    f.spark = f.overlay:CreateTexture(nil, "OVERLAY", nil, 1)
    f.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    f.spark:SetBlendMode("ADD")
    f.spark:Hide()

    f.time = f.overlay:CreateFontString(nil, "OVERLAY")
    f.time:SetPoint("RIGHT", f.overlay, "RIGHT", -3, 0)

    f.dragLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.dragLabel:SetPoint("BOTTOM", f, "TOP", 0, 3)
    f.dragLabel:SetText("Global cooldown |cff888888(drag)|r")
    f.dragLabel:Hide()

    f:SetScript("OnDragStart", function(self)
        if NCB.db.locked then return end
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
        if NCB.RefreshOptions then NCB.RefreshOptions() end
    end)

    f:SetScript("OnUpdate", function(self, elapsed)
        self.accum = (self.accum or 0) + elapsed
        if self.accum < POLL then return end
        self.accum = 0
        GCD:Tick()
    end)

    frame = f
end

--------------------------------------------------------------------------------
-- Styling
--------------------------------------------------------------------------------
-- Whether the bar belongs on screen at all right now. A metronome that keeps
-- beating while you stand in a city is noise, so where it shows is a setting.
function GCD:ShouldShow()
    local cfg = NCB.db and NCB.db.gcd
    if not (cfg and cfg.enabled and NCB.db.enabled) then return false end

    local inCombat = InCombatLockdown() and true or false
    if cfg.visibility == "combat"   then return inCombat end
    if cfg.visibility == "nocombat" then return not inCombat end
    return true
end

function GCD:ActiveBar()
    if not frame then return nil end
    return (NCB.db.gcd.mode == "window") and frame.timerBar or frame.loopBar
end

function GCD:Apply()
    if not NCB.db then return end
    Build()
    local cfg = NCB.db.gcd

    -- Attached mode parks it under the player cast bar and matches its width,
    -- which is where this bar is wanted nine times out of ten and saves lining two
    -- things up by hand every time either one moves.
    --
    -- It has to adopt that bar's SCALE as well as its width. Width is measured in
    -- the frame's own units, so two frames of equal width but different scale do
    -- not come out the same size on screen - which is exactly the misalignment
    -- attaching is meant to prevent. Its own scale setting is hidden while attached
    -- rather than left there doing nothing.
    local width, scale = cfg.width, cfg.scale
    frame:ClearAllPoints()
    local playerBar = NCB.Bars and NCB.Bars.frames and NCB.Bars.frames["player"]
    if cfg.anchor == "playerbar" and playerBar then
        local pcfg = NCB.Config("player")
        width = pcfg.width
        scale = pcfg.scale
        frame:SetPoint("TOP", playerBar, "BOTTOM", 0, -cfg.gap)
    else
        frame:SetPoint(cfg.point, UIParent, cfg.relPoint or cfg.point, cfg.x, cfg.y)
    end
    frame:SetScale(scale)
    frame:SetSize(width, cfg.height)

    local texture = NCB.TexturePath(cfg.texture)
    frame.bg:SetTexture(texture)
    frame.bg:SetVertexColor(unpack(cfg.colorBackground))

    for _, b in ipairs({ frame.timerBar, frame.loopBar }) do
        b:SetStatusBarTexture(texture)
        b:SetStatusBarColor(unpack(cfg.color))
    end

    local active = self:ActiveBar()
    frame.timerBar:SetShown(active == frame.timerBar)
    frame.loopBar:SetShown(active == frame.loopBar)

    for _, t in ipairs(frame.borders) do
        t:SetColorTexture(unpack(cfg.colorBorder))
        t:SetShown(cfg.showBorder)
    end

    -- Kept above whichever bar is showing, whatever levels those ended up with.
    frame.overlay:SetFrameLevel(math.max(frame.timerBar:GetFrameLevel(),
                                         frame.loopBar:GetFrameLevel()) + 2)

    -- A floor on the height: on a 6px bar, a spark scaled purely off that is a
    -- smudge. It wants to stand proud of the bar to read at all.
    frame.spark:SetSize(10, math.max(14, cfg.height * 2.4))
    frame.spark:ClearAllPoints()
    local fill = active and active:GetStatusBarTexture()
    if fill then
        -- Pinned to the moving edge rather than positioned by arithmetic, so it
        -- tracks a bar whose scale we may not be allowed to read.
        frame.spark:SetPoint("CENTER", fill, "RIGHT", 0, 0)
    end
    frame.spark:SetShown(cfg.showSpark)

    self:UpdateLatency()

    local flags = (cfg.fontOutline ~= "NONE") and cfg.fontOutline or ""
    local ok, applied = pcall(frame.time.SetFont, frame.time,
                              NCB.FontPath(cfg.font), cfg.fontSize, flags)
    if not ok or applied == false then
        frame.time:SetFontObject("GameFontHighlightSmall")
    end
    frame.time:SetTextColor(unpack(cfg.colorText))
    frame.time:SetShown(cfg.showTime)

    if not self:ShouldShow() then
        self.running = false
        if not self.preview then frame:Hide() end
    elseif cfg.mode == "loop" and not self.preview then
        -- A metronome has no idle state to hide: once it is allowed on screen it
        -- stays on screen.
        frame:Show()
    end
end

-- The tail of the sweep in which a keypress will still reach the server before the
-- global expires. On a GCD bar this is arguably more to the point than it is on a
-- cast bar: "when can I press the next one" is the question the bar exists to
-- answer, and it is not quite the same question as "when does the global end".
--
-- Which end it sits on follows the direction. A draining bar runs out at its left
-- edge; a filling one runs out at its right.
function GCD:UpdateLatency()
    if not frame then return end
    local cfg = NCB.db.gcd
    if not cfg.showLatency then
        frame.latency:Hide()
        return
    end

    local _, _, _, world = GetNetStats()
    local lag  = (tonumber(world) or 0) / 1000
    local frac = math.min(0.5, lag / math.max(self:Length(), 0.1))

    frame.latency:SetColorTexture(unpack(cfg.colorLatency))
    frame.latency:ClearAllPoints()
    if cfg.direction == "fill" then
        frame.latency:SetPoint("TOPRIGHT", frame.overlay, "TOPRIGHT", 0, 0)
        frame.latency:SetPoint("BOTTOMRIGHT", frame.overlay, "BOTTOMRIGHT", 0, 0)
    else
        frame.latency:SetPoint("TOPLEFT", frame.overlay, "TOPLEFT", 0, 0)
        frame.latency:SetPoint("BOTTOMLEFT", frame.overlay, "BOTTOMLEFT", 0, 0)
    end
    frame.latency:SetWidth(math.max(1, frame:GetWidth() * frac))
    frame.latency:Show()
end

--------------------------------------------------------------------------------
-- Window mode
--------------------------------------------------------------------------------
function GCD:ArmTimer()
    local cfg = NCB.db.gcd
    local bar = frame.timerBar
    frame.driven = false

    local obj = DurationHandle()
    if obj and HAS_TIMER_API and bar.SetTimerDuration then
        -- Draining reads as "time until I can act"; filling reads as "how far
        -- through the global I am". Both are in use out there, so it is a setting.
        local dir = (cfg.direction == "fill") and TIMER_DIR.ElapsedTime
                                              or TIMER_DIR.RemainingTime
        frame.driven = pcall(bar.SetTimerDuration, bar, obj,
                             TIMER_INTERP.Immediate, dir) and true or false
    end

    if not frame.driven then
        -- No handle to animate from. A solid bar for the length of the global still
        -- says "you are inside it" without inventing a position within it.
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(1)
    end
end

--------------------------------------------------------------------------------
-- The tick
--------------------------------------------------------------------------------
function GCD:Tick()
    if self.preview then return end
    local cfg = NCB.db.gcd
    if not self:ShouldShow() then
        if frame:IsShown() then frame:Hide() end
        return
    end

    local now    = GetTime()
    local active = IsRunning()

    -- Edge detection. A global starting is the only thing that resets the sweep -
    -- which is exactly "when an ability is pressed", but without being fooled by
    -- abilities that are off the global entirely.
    if active and not self.wasActive then
        self.startedAt  = now
        self.cycleStart = now
        -- Cleared first: the client answers this plainly out of combat and not in
        -- it, so the flag has to be re-earned each global or a reading taken before
        -- the pull would lock out measurement for the whole fight.
        self.lengthFrom = nil
        self:LearnFromAPI()
        -- Both the length and the round trip can have moved since the last one.
        self:UpdateLatency()
        if cfg.mode == "window" then self:ArmTimer() end
        frame:SetAlpha(1)
        frame:Show()

    elseif (not active) and self.wasActive then
        -- Measure what that one actually took. Always legal: our own clock.
        if self.startedAt then
            local measured = now - self.startedAt
            if measured >= MIN_LEN and measured <= MAX_LEN and self.lengthFrom ~= "client" then
                self.length = measured
            end
        end
        if cfg.mode == "window" then
            frame.time:SetText("")
            if cfg.hideWhenReady then frame:Hide() end
        end
    end
    if active ~= nil then self.wasActive = active end
    self.running = active and true or false

    if cfg.mode == "loop" then
        self:DrawLoop(now, cfg)
    elseif cfg.showTime and active and frame.driven then
        self:DrawTimerText(cfg)
    end
end

-- The metronome. Modulo keeps it repeating on its own; nothing has to notice a
-- cycle ending and start another.
function GCD:DrawLoop(now, cfg)
    local len = self:Length()
    if not self.cycleStart then self.cycleStart = now end

    local elapsed = (now - self.cycleStart) % len
    local frac    = elapsed / len
    local bar     = frame.loopBar
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(cfg.direction == "fill" and frac or (1 - frac))

    if cfg.showTime then
        frame.time:SetFormattedText("%." .. cfg.decimals .. "f", len - elapsed)
    end
end

function GCD:DrawTimerText(cfg)
    local bar = frame.timerBar
    if not bar.GetTimerDuration then return end
    local obj = bar:GetTimerDuration()
    if not obj then return end
    -- The remaining value may itself be secret; SetFormattedText takes it either
    -- way, which is the whole point of that call.
    local ok, remaining = pcall(obj.GetRemainingDuration, obj)
    if ok then
        frame.time:SetFormattedText("%." .. cfg.decimals .. "f", remaining or 0)
    end
end

-- Something changed a cooldown, or a cast went out. Both are worth a look, and the
-- edge detection in Tick decides whether anything actually happened - cooldown
-- chatter from unrelated spells must never restart the sweep.
function GCD:Check()
    if not (NCB.db and NCB.db.gcd) then return end
    if self.preview then return end
    Build()
    -- Loop mode has to be put back on screen when combat starts or ends; Tick
    -- decides, and takes it away again just as readily.
    if self:ShouldShow() and NCB.db.gcd.mode == "loop" then frame:Show() end
    self:Tick()
end

--------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------
function GCD:SetLocked(locked)
    self:Apply()
    if not frame then return end

    -- Attached to the player bar there is nothing to drag: it goes where that bar
    -- goes. Offering a handle that Apply would immediately undo would be a lie, so
    -- the mouse stays off as well as the label.
    local attached = (NCB.db.gcd.anchor == "playerbar")
    frame:EnableMouse(not locked and not attached)
    frame.dragLabel:SetShown(not locked and not attached)

    if locked then
        self.preview = false
        self.wasActive = nil
        self:Apply()
        self:Check()
    elseif NCB.db.gcd.enabled and NCB.db.enabled then
        self.preview = true
        -- Always the loop bar for the sample, whichever mode is set: it is the one
        -- that has never had a timer armed on it, so SetValue is guaranteed to
        -- paint. The two are styled identically, so there is nothing to see.
        frame.timerBar:Hide()
        frame.loopBar:Show()
        frame.loopBar:SetMinMaxValues(0, 1)
        frame.loopBar:SetValue(0.6)
        frame.time:SetText("")
        frame:SetAlpha(1)
        frame:Show()
    else
        self.preview = false
        frame:Hide()
    end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local driver = CreateFrame("Frame")
driver:RegisterEvent("SPELL_UPDATE_COOLDOWN")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
-- Entering and leaving combat both change whether the bar belongs on screen.
driver:RegisterEvent("PLAYER_REGEN_DISABLED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Unit-filtered: the global starts on your own casts, and this catches the ones
-- SPELL_UPDATE_COOLDOWN is late for.
pcall(driver.RegisterUnitEvent, driver, "UNIT_SPELLCAST_SUCCEEDED", "player")

driver:SetScript("OnEvent", function()
    GCD:Check()
end)
