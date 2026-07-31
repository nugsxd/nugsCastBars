--------------------------------------------------------------------------------
-- nugsCastBars
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsCastBars  -  Interrupts.lua
-- Whether *your* interrupt is off cooldown right now.
--
-- This is the half of the question the client will still answer plainly.
-- `C_Spell.GetSpellCooldown` returns isActive and isOnGCD flagged NeverSecret, so
-- unlike almost everything else about a fight, your own kick's readiness is a real
-- true/false we are allowed to branch on.
--
-- The other half - whether the cast in front of you can be interrupted at all - is
-- a secret boolean and never becomes knowable. Bars.lua combines the two without
-- ever computing the AND: see the overlay trick there.
--------------------------------------------------------------------------------
local ADDON_NAME, NCB = ...

local Interrupts = {}
NCB.Interrupts = Interrupts

Interrupts.spells = {}

local Plain = NCB.Plain

--------------------------------------------------------------------------------
-- Class table
-- Every id is checked against the spellbook before it is used, so one that is
-- wrong or has been retired drops out of the list rather than sitting there
-- reporting a cooldown that never moves. `/ncb diag` prints what survived, which
-- is how you find out this table has gone stale - and the override box in the
-- options window is how you fix it without waiting for me.
--------------------------------------------------------------------------------
local CLASS_INTERRUPTS = {
    DEATHKNIGHT = { 47528 },            -- Mind Freeze
    DEMONHUNTER = { 183752 },           -- Disrupt
    DRUID       = { 106839, 78675 },    -- Skull Bash, Solar Beam
    EVOKER      = { 351338 },           -- Quell
    HUNTER      = { 147362, 187707 },   -- Counter Shot, Muzzle
    MAGE        = { 2139 },             -- Counterspell
    MONK        = { 116705 },           -- Spear Hand Strike
    PALADIN     = { 96231 },            -- Rebuke
    PRIEST      = { 15487 },            -- Silence
    ROGUE       = { 1766 },             -- Kick
    SHAMAN      = { 57994 },            -- Wind Shear
    WARLOCK     = { 19647, 89766 },     -- Spell Lock, Axe Toss - both pet abilities
    WARRIOR     = { 6552 },             -- Pummel
}

-- Both spell banks are checked, because a warlock's interrupt belongs to the pet
-- and would be invisible to a player-only lookup.
--
-- IsSpellKnownOrInSpellBook rather than IsSpellKnown: an interrupt can arrive as a
-- talent-granted override, which the stricter call misses. The old globals
-- (IsPlayerSpell, IsSpellKnown) are deprecated in 12.0 and deliberately not used
-- as a fallback - this addon is retail-only, so there is no client that needs them.
local BANK_PLAYER = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
local BANK_PET    = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Pet)    or 1

local function Known(spellID)
    local isKnown = C_SpellBook and (C_SpellBook.IsSpellKnownOrInSpellBook
                                     or C_SpellBook.IsSpellKnown)
    if not isKnown then return false end

    local ok, known = pcall(isKnown, spellID, BANK_PLAYER)
    if ok and known then return true end

    ok, known = pcall(isKnown, spellID, BANK_PET)
    return (ok and known) and true or false
end

local function PlayerClass()
    local class
    if _G.UnitClassBase then
        class = Plain(UnitClassBase("player"))
    end
    if not class then
        class = Plain(select(2, UnitClass("player")))
    end
    return class
end

--------------------------------------------------------------------------------
-- Building the list
--------------------------------------------------------------------------------
function Interrupts:Rebuild()
    local list = {}

    -- A hand-typed override wins outright and is not filtered against the
    -- spellbook: if you went to the trouble of typing an id, the addon has no
    -- business second-guessing whether you have it.
    local override = NCB.db and NCB.db.interruptSpells or ""
    if override ~= "" then
        for id in override:gmatch("%d+") do
            list[#list + 1] = tonumber(id)
        end
        self.fromOverride = true
    else
        self.fromOverride = false
        local class = PlayerClass()
        for _, id in ipairs(CLASS_INTERRUPTS[class or ""] or {}) do
            if Known(id) then list[#list + 1] = id end
        end
    end

    self.spells = list
    self.class  = PlayerClass()
    return list
end

-- What this class *could* have, before the spellbook filter. Only used by the
-- diagnostics, to tell "your class has no entry here" apart from "you do not
-- currently know any of them".
function Interrupts:Candidates()
    return CLASS_INTERRUPTS[PlayerClass() or ""] or {}
end

function Interrupts:Name(spellID)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.name then return info.name end
    end
    return "spell " .. tostring(spellID)
end

--------------------------------------------------------------------------------
-- Readiness
-- true  - at least one interrupt is off cooldown
-- false - every one of them is on cooldown
-- nil   - nothing to go on, and the caller should stand down rather than guess
--------------------------------------------------------------------------------
function Interrupts:Ready()
    if not (C_Spell and C_Spell.GetSpellCooldown) then return nil end
    if #self.spells == 0 then return nil end

    for _, spellID in ipairs(self.spells) do
        local info = C_Spell.GetSpellCooldown(spellID)
        if info then
            -- isActive and isOnGCD are NeverSecret, so this branch is legal
            -- everywhere - in combat, in a key, on a raid boss.
            local active = info.isActive and true or false
            local onGCD  = info.isOnGCD  and true or false
            -- A cooldown that is only the global is not the interrupt being
            -- unavailable: it will be back before you finish pressing it.
            if (not active) or onGCD then return true end
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- Landing one
-- SPELL_INTERRUPT out of the combat log is the only thing that says an interrupt
-- actually connected - no unit event distinguishes "the cast stopped" from "you
-- stopped it". Confirmed still readable on 12.0: BigWigs reads this same subevent
-- through CombatLogGetCurrentEventInfo.
--
-- 12.0 does NOT let an addon register COMBAT_LOG_EVENT_UNFILTERED - the call comes
-- back as ADDON_ACTION_FORBIDDEN on a protected Frame:RegisterEvent. It does not
-- need to: UNIT_SPELLCAST_INTERRUPTED and UNIT_SPELLCAST_CHANNEL_STOP now carry a
-- fourth argument, `interruptedBy`, which is nil when a cast merely ended and set
-- when something stopped it. Those events are unit-filtered and already registered
-- by every bar, so this costs nothing extra at all.
--
-- Whether it was *your* interrupt is answered two ways, best first:
--
--   * If `interruptedBy` survives Plain(), compare it to your own GUID. Exact.
--   * If it is secret, it can still be truth-tested - that much is always legal -
--     which proves the cast was interrupted but not by whom. Ownership then falls
--     back to a correlation: did one of your interrupts land in the last moment.
--     This is what zzal does for the same reason.
--------------------------------------------------------------------------------
-- How recently your own interrupt must have gone off for an interrupt with an
-- unreadable owner to be credited to you.
local OWN_CAST_WINDOW = 0.7

-- Target and focus are frequently the same mob, so one interrupt arrives as two
-- events. Anything closer together than this is the same interrupt twice.
local DUPLICATE_WINDOW = 0.3

-- Prefer resolving the name from the id: a plain spell id looked up locally gives
-- a plain name back, even when the name the combat log handed over is secret.
local function SpellLabel(nameField, idField)
    local id = Plain(idField)
    if id and C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        if info and info.name and not NCB.IsSecret(info.name) then return info.name end
    end
    return Plain(nameField)
end

-- A pet's interrupt counts as yours - that is the whole point for a warlock.
function Interrupts:WasMine(interruptedBy)
    local guid = Plain(interruptedBy)
    if guid then
        return guid == UnitGUID("player") or guid == UnitGUID("pet")
    end

    -- Secret owner. Fall back to "did I just interrupt something".
    return self.castAt ~= nil and (GetTime() - self.castAt) <= OWN_CAST_WINDOW
end

-- Which of your interrupts was the one that landed. The stamp from the cast watcher
-- is the direct answer; with a single candidate there is no ambiguity to resolve
-- anyway, which covers most classes.
function Interrupts:UsedAbility()
    if self.castSpell and self.castAt and (GetTime() - self.castAt) <= OWN_CAST_WINDOW then
        return self:Name(self.castSpell)
    end
    if #self.spells == 1 then return self:Name(self.spells[1]) end
    return nil
end

-- Built from whichever pieces the client was willing to hand over plainly. Each one
-- can be missing independently, so the sentence is assembled rather than formatted:
-- a secret value must never reach a concatenation.
local function BuildMessage(ability, spellLabel, targetLabel)
    local text
    if ability and spellLabel then
        text = ability .. " |cff888888>|r " .. spellLabel
    elseif spellLabel then
        text = "Interrupted " .. spellLabel
    elseif ability then
        text = ability .. " landed"
    else
        text = "Interrupted"
    end

    if targetLabel then text = text .. " |cff888888on|r " .. targetLabel end
    return text
end

function Interrupts:Announce(spellLabel, targetLabel, secretTarget)
    local db = NCB.db
    if not db then return end

    if db.interruptSound then
        NCB.PlayCue(db.interruptSoundName)
    end

    local mode = db.interruptAnnounce or "off"
    if mode == "off" then return end

    local text = BuildMessage(self:UsedAbility(), spellLabel, targetLabel)

    -- Chat cannot carry the secret form: print has to turn its argument into a
    -- string, and that is the one thing a secret will not do. The name reaches the
    -- screen either way, which is where it is being read anyway.
    if mode == "chat" or mode == "both" then
        NCB.Print(text)
    end
    if mode == "screen" or mode == "both" then
        self:Flash(text, secretTarget)
    end
end

--------------------------------------------------------------------------------
-- The on-screen announcement
-- Its own frame rather than a borrowed Blizzard one, so it can be dragged, styled
-- and sized like every other part of this addon. It joins the same lock as the
-- bars: /ncb unlock puts a sample message up and lets you move it.
--------------------------------------------------------------------------------
local display

local function SavePosition(f)
    local point, _, relPoint, x, y = f:GetPoint(1)
    if not point then return end
    local db = NCB.db
    db.announcePoint    = point
    db.announceRelPoint = relPoint or point
    db.announceX = math.floor(x + 0.5)
    db.announceY = math.floor(y + 0.5)
end

local function BuildDisplay()
    if display then return end

    local f = CreateFrame("Frame", "nugsCastBarsAnnounce", UIParent)
    f:SetSize(360, 44)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:Hide()

    -- Only ever visible while unlocked, so you can see what you are grabbing.
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.35, 0.72, 1.0, 0.18)
    f.bg:Hide()

    f.text = f:CreateFontString(nil, "OVERLAY")
    f.text:SetPoint("CENTER", 0, 6)
    f.text:SetJustifyH("CENTER")

    -- Second line, for the interrupted unit's name when the client will only hand
    -- it over as a secret string. A secret may be drawn but never joined to other
    -- text, so it cannot go in the sentence above - it gets a line of its own
    -- instead of being dropped.
    f.sub = f:CreateFontString(nil, "OVERLAY")
    f.sub:SetPoint("TOP", f.text, "BOTTOM", 0, -1)
    f.sub:SetJustifyH("CENTER")
    f.sub:Hide()

    f.dragLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.dragLabel:SetPoint("BOTTOM", f, "TOP", 0, 2)
    f.dragLabel:SetText("nugsCastBars announcement |cff888888(drag)|r")
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

    -- Hold-then-fade as an animation rather than an OnUpdate: the timing is fixed
    -- the moment the message appears, so there is nothing for Lua to recompute
    -- sixty times a second.
    f.anim = f:CreateAnimationGroup()
    f.fade = f.anim:CreateAnimation("Alpha")
    f.fade:SetFromAlpha(1)
    f.fade:SetToAlpha(0)
    f.anim:SetScript("OnFinished", function() f:Hide() end)

    display = f
end

function Interrupts:ApplyDisplay()
    if not NCB.db then return end
    BuildDisplay()
    local db = NCB.db

    display:ClearAllPoints()
    display:SetPoint(db.announcePoint, UIParent,
                     db.announceRelPoint or db.announcePoint, db.announceX, db.announceY)

    local flags = (db.announceOutline ~= "NONE") and db.announceOutline or ""
    -- SetFont reports failure rather than erroring when a font file will not load.
    local ok, applied = pcall(display.text.SetFont, display.text,
                              NCB.FontPath(db.announceFont), db.announceFontSize, flags)
    if not ok or applied == false then
        display.text:SetFontObject("GameFontNormalLarge")
    end
    display.text:SetTextColor(unpack(db.announceColor))

    local subSize = math.max(8, math.floor(db.announceFontSize * 0.8))
    local okSub, appliedSub = pcall(display.sub.SetFont, display.sub,
                                    NCB.FontPath(db.announceFont), subSize, flags)
    if not okSub or appliedSub == false then
        display.sub:SetFontObject("GameFontNormal")
    end
    display.sub:SetTextColor(unpack(db.announceColor))

    display:SetHeight(math.max(28, db.announceFontSize * 2.4))
end

-- `secretName` is a name we are allowed to draw but not to join to anything, so it
-- goes on its own line. Nil whenever the name made it into `text` already.
function Interrupts:Flash(text, secretName)
    self:ApplyDisplay()
    local db = NCB.db

    display.text:SetText(text)
    if secretName then
        local ok = pcall(display.sub.SetText, display.sub, secretName)
        display.sub:SetShown(ok and true or false)
    else
        display.sub:SetText("")
        display.sub:Hide()
    end

    display.anim:Stop()                 -- a second interrupt restarts the timer
    display.fade:SetStartDelay(db.announceHold)
    display.fade:SetDuration(math.max(db.announceFade, 0.01))
    display:SetAlpha(1)
    display:Show()
    display.anim:Play()
end

-- Joins the bars' lock, so one unlock places everything at once.
function Interrupts:SetLocked(locked)
    self:ApplyDisplay()
    if not display then return end   -- called before the database was ready
    display:EnableMouse(not locked)
    display.dragLabel:SetShown(not locked)
    display.bg:SetShown(not locked)

    display.anim:Stop()
    if locked then
        display:Hide()
    else
        -- No fade while you are placing it. Both lines are shown, because in combat
        -- that is the shape it will usually take.
        display.text:SetText(BuildMessage("Kick", "Chaos Bolt", nil))
        display.sub:SetText("Rageclaw Shaman")
        display.sub:Show()
        display:SetAlpha(1)
        display:Show()
    end
end

-- Called by every bar when its unit's cast was stopped by somebody. `interruptedBy`
-- is only ever truth-tested here before being handed to WasMine, because when it is
-- secret that is the one thing we are allowed to do with it.
function Interrupts:OnInterrupted(unit, spellID, interruptedBy, spellName)
    if not interruptedBy then return end          -- the cast just ended
    if not NCB.db then return end
    -- Your own cast being stopped is never your interrupt landing, and without this
    -- getting kicked just after you kicked something would credit you with it.
    if unit == "player" or unit == "pet" then return end
    if not (NCB.db.interruptSound or (NCB.db.interruptAnnounce or "off") ~= "off") then return end
    if not self:WasMine(interruptedBy) then return end

    local now = GetTime()
    if self.lastAnnounce and (now - self.lastAnnounce) < DUPLICATE_WINDOW then return end
    self.lastAnnounce = now

    -- In combat a unit's name comes back secret. Unlike a spell, there is no id to
    -- look a plain one up from - so if it will not survive Plain() the raw value is
    -- carried through to be drawn on its own line rather than lost.
    local raw   = UnitName(unit)
    local plain = Plain(raw)
    self:Announce(SpellLabel(spellName, spellID), plain, (not plain) and raw or nil)
end

-- Your own interrupt going off. Stamped so an interrupt whose owner the client
-- keeps secret can still be credited to you.
local castWatcher = CreateFrame("Frame")
castWatcher:SetScript("OnEvent", function(_, _, _, _, spellID)
    local id = Plain(spellID)
    if not id then return end
    for _, mine in ipairs(Interrupts.spells) do
        if mine == id then
            Interrupts.castAt    = GetTime()
            Interrupts.castSpell = id      -- so the announcement can name it
            return
        end
    end
end)

-- Unit-filtered, and only while there is something to announce. "pet" is in there
-- for the warlock case, where the interrupt is the pet's cast, not yours.
function Interrupts:UpdateWatcher()
    local db = NCB.db
    local want = db and (db.interruptSound or (db.interruptAnnounce or "off") ~= "off")

    if want and not self.watching then
        pcall(castWatcher.RegisterUnitEvent, castWatcher,
              "UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
        self.watching = true
    elseif not want and self.watching then
        castWatcher:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        self.watching = false
    end
end

--------------------------------------------------------------------------------
-- Events
-- The list is rebuilt on anything that can change which interrupt you have: a
-- spec swap, a new pet for a warlock, the spellbook settling after login.
--------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
events:RegisterEvent("UNIT_PET")

events:SetScript("OnEvent", function(_, event, arg1)
    if not NCB.db then return end
    if event == "UNIT_PET" and arg1 ~= "player" then return end
    Interrupts:Rebuild()
    Interrupts:UpdateWatcher()
end)
