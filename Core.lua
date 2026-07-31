--------------------------------------------------------------------------------
-- nugsCastBars
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsCastBars  -  Core.lua
-- Shared state: the unit list every other file iterates, the media lists (bar
-- textures, fonts), saved-variable defaults, and the slash command.
--
-- Shared namespace: the second vararg is the same table across every Lua file in
-- this addon, so all state and functions hang off of it.
--------------------------------------------------------------------------------
local ADDON_NAME, NCB = ...

NCB.name    = ADDON_NAME
NCB.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
              or "0.1.0"

local PREFIX = "|cff6fc2ffnugsCastBars|r: "
function NCB.Print(msg)
    print(PREFIX .. tostring(msg))
end

--------------------------------------------------------------------------------
-- Secret values (Midnight / 12.0)
-- Combat data can be handed to addons as opaque "secret" values: reading one is
-- fine, doing arithmetic on it is not. Every number that comes out of a unit API
-- goes through Plain(), which returns nil rather than something we are not allowed
-- to compute with. nil means "cannot know right now", and the bar falls back to
-- timing the cast itself off GetTime(), which is always legal.
--------------------------------------------------------------------------------
-- Confirmed in the field on 2026-07-28, retail 12.0.7: for a *target's* cast,
-- UnitCastingInfo returns every field secret - name, icon, start, end, castID,
-- notInterruptible and spellID. Two rules follow, and the whole file obeys them:
--
--   * A secret string or number may be truth-tested (`if name then`) and handed
--     to a display sink such as FontString:SetText. It may not be measured,
--     concatenated, compared or computed with.
--   * A secret BOOLEAN may not even be truth-tested - branching on it is exactly
--     the leak the system exists to prevent. Every boolean out of a unit API is
--     therefore run through Plain(), giving a true/false/nil tri-state where nil
--     honestly means "not allowed to know".
local issecretvalue = _G.issecretvalue
NCB.secretsExist = (issecretvalue ~= nil)

function NCB.IsSecret(v)
    if v == nil or not issecretvalue then return false end
    return issecretvalue(v) and true or false
end

function NCB.Plain(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

--------------------------------------------------------------------------------
-- Units
-- One entry per configurable bar. `multi` means the bar config drives several
-- frames (boss1..boss5) that chain off a single anchor.
-- `blizz` lists the stock frames to switch off when "Hide Blizzard's bar" is on.
--------------------------------------------------------------------------------
NCB.UNITS = {
    {
        key = "player", label = "Player", unit = "player",
        blizz = { "PlayerCastingBarFrame", "CastingBarFrame" },
    },
    {
        key = "target", label = "Target", unit = "target",
        blizz = { "TargetFrameSpellBar" },
    },
    {
        key = "focus", label = "Focus", unit = "focus",
        blizz = { "FocusFrameSpellBar" },
    },
    {
        key = "pet", label = "Pet", unit = "pet",
        blizz = { "PetCastingBarFrame" },
    },
    {
        key = "boss", label = "Boss", unit = "boss", multi = 5,
        blizz = { "Boss1TargetFrameSpellBar", "Boss2TargetFrameSpellBar",
                  "Boss3TargetFrameSpellBar", "Boss4TargetFrameSpellBar",
                  "Boss5TargetFrameSpellBar" },
    },
}

function NCB.UnitByKey(key)
    for _, u in ipairs(NCB.UNITS) do
        if u.key == key then return u end
    end
end

-- The actual unit tokens a bar config drives. Fixed strings in every case, which
-- is what lets the engine use RegisterUnitEvent instead of listening to the whole
-- world's spellcasts.
function NCB.UnitTokens(def)
    if not def.multi then return { def.unit } end
    local out = {}
    for i = 1, def.multi do out[i] = def.unit .. i end
    return out
end

--------------------------------------------------------------------------------
-- Media
-- Stock entries always work. If LibSharedMedia happens to be loaded by some other
-- addon we borrow its lists too, but nothing here depends on it.
--------------------------------------------------------------------------------
local STOCK_TEXTURES = {
    { name = "Blizzard Raid Bar", path = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" },
    { name = "Blizzard",          path = "Interface\\TargetingFrame\\UI-StatusBar" },
    { name = "Blizzard Character",path = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar" },
    { name = "Cast Bar",          path = "Interface\\CastingBar\\UI-CastingBar-Fill" },
    { name = "Flat",              path = "Interface\\Buttons\\WHITE8X8" },
    { name = "Otravi",            path = "Interface\\PVPFrame\\UI-PVP-Progress-Bar" },
}

local STOCK_FONTS = {
    { name = "Friz Quadrata TT", path = "Fonts\\FRIZQT__.TTF" },
    { name = "Arial Narrow",     path = "Fonts\\ARIALN.TTF"   },
    { name = "Skurri",           path = "Fonts\\SKURRI.TTF"   },
    { name = "Morpheus",         path = "Fonts\\MORPHEUS.TTF" },
}

-- Shared shape for both media kinds: stock list first, LSM appended, no duplicates.
local function MediaList(stock, lsmKind)
    local list, seen = {}, {}
    for _, entry in ipairs(stock) do
        list[#list + 1] = entry
        seen[entry.name] = true
    end

    local LSM = _G.LibStub and _G.LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local ok, names = pcall(LSM.List, LSM, lsmKind)
        if ok and type(names) == "table" then
            for _, name in ipairs(names) do
                if not seen[name] then
                    local ok2, path = pcall(LSM.Fetch, LSM, lsmKind, name)
                    if ok2 and type(path) == "string" then
                        list[#list + 1] = { name = name, path = path }
                        seen[name] = true
                    end
                end
            end
        end
    end
    return list
end

-- Stock cues are numeric SOUNDKIT ids for PlaySound; anything LibSharedMedia adds
-- is a file path for PlaySoundFile. Both shapes share this list and NCB.PlayCue is
-- the only place that has to know the difference. The constants carry numeric
-- fallbacks in case a SOUNDKIT entry gets renamed.
local SK = _G.SOUNDKIT or {}
local STOCK_SOUNDS = {
    { name = "Raid Warning", id = SK.RAID_WARNING           or 8959  },
    { name = "Ready Check",  id = SK.READY_CHECK            or 8960  },
    { name = "Map Ping",     id = SK.MAP_PING               or 3175  },
    { name = "Alarm Clock",  id = SK.ALARM_CLOCK_WARNING_3  or 12867 },
    { name = "Level Up",     id = SK.LEVEL_UP               or 888   },
}

function NCB.TextureList() return MediaList(STOCK_TEXTURES, "statusbar") end
function NCB.FontList()    return MediaList(STOCK_FONTS,    "font")      end
function NCB.SoundList()   return MediaList(STOCK_SOUNDS,   "sound")     end

-- "Master" on purpose: on any other channel the cue goes silent for anyone who has
-- turned sound effects down, which is most of the people who want a cue at all.
function NCB.PlayCue(name)
    for _, s in ipairs(NCB.SoundList()) do
        if s.name == name then
            if s.path then
                PlaySoundFile(s.path, "Master")
            elseif s.id then
                PlaySound(s.id, "Master")
            end
            return
        end
    end
end

function NCB.TexturePath(name)
    for _, entry in ipairs(NCB.TextureList()) do
        if entry.name == name then return entry.path end
    end
    return STOCK_TEXTURES[1].path
end

function NCB.FontPath(name)
    for _, entry in ipairs(NCB.FontList()) do
        if entry.name == name then return entry.path end
    end
    return STOCK_FONTS[1].path
end

NCB.OUTLINES     = { "NONE", "OUTLINE", "THICKOUTLINE" }
NCB.ICON_SIDES   = { "LEFT", "RIGHT", "NONE" }
NCB.JUSTIFY      = { "LEFT", "CENTER", "RIGHT" }
NCB.TIME_FORMATS = {
    { key = "remaining", label = "Time remaining" },
    { key = "elapsed",   label = "Time elapsed" },
    { key = "both",      label = "Elapsed / total" },
}
NCB.TARGET_POS = {
    { key = "inline", label = "After the spell name" },
    { key = "below",  label = "On its own line below" },
    { key = "right",  label = "Right of the bar" },
}
NCB.GROWS = { "down", "up" }
NCB.ANNOUNCE = {
    { key = "off",    label = "Do not announce" },
    { key = "chat",   label = "In the chat frame" },
    { key = "screen", label = "On screen" },
    { key = "both",   label = "Chat and on screen" },
}

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------
-- Every bar carries a full copy of these, so one bar can be restyled without
-- touching the others. The options window has a "copy this bar's look to all"
-- button for when you do want them to match.
NCB.barDefaults = {
    enabled      = true,
    width        = 240,
    height       = 24,
    scale        = 1.00,
    point        = "CENTER",
    x            = 0,
    y            = -200,

    texture      = "Blizzard Raid Bar",
    font         = "Friz Quadrata TT",
    fontSize     = 12,
    fontOutline  = "OUTLINE",

    showIcon     = true,
    iconSide     = "LEFT",
    iconZoom     = true,   -- crop the icon border off rather than squash it
    iconGap      = 3,

    showName     = true,
    nameJustify  = "LEFT",
    nameMaxChars = 0,      -- 0 = never trim

    showTime     = true,
    timeFormat   = "remaining",
    decimals     = 1,

    showTarget   = true,   -- who the cast is aimed at, snapshotted when it starts
    targetPos    = "inline",
    targetClassColor = true,
    warnOnYou    = true,   -- colour the target text red when the cast is on you

    showShield   = true,   -- shield icon while a cast cannot be interrupted
    -- Colour an interruptible cast by whether YOUR interrupt is off cooldown.
    -- Two independent toggles, so you can flag only the state you care about and
    -- leave the other on the normal casting colour.
    showInterruptReady    = false,
    showInterruptNotReady = false,
    showSpark    = true,
    showLatency  = false,  -- player bar: the tail you cannot actually use
    showBorder   = true,

    hideBlizzard = false,
    fadeTime     = 0.35,
    holdTime     = 0.35,   -- how long a finished bar sits before it fades

    -- Boss bars only.
    spacing      = 6,
    grow         = "down",

    colorCast            = { 0.20, 0.55, 0.95 },
    colorChannel         = { 0.24, 0.74, 0.48 },
    colorUninterruptible = { 0.55, 0.55, 0.60 },
    colorInterruptReady    = { 0.20, 0.85, 0.35 },
    colorInterruptNotReady = { 0.75, 0.25, 0.25 },
    colorSuccess         = { 0.35, 0.85, 0.45 },
    colorFailed          = { 0.85, 0.25, 0.25 },
    colorBackground      = { 0.06, 0.06, 0.07, 0.85 },
    colorBorder          = { 0.00, 0.00, 0.00, 1.00 },
    colorText            = { 1.00, 1.00, 1.00 },
}

-- Only the things that should differ out of the box. Everything else is inherited
-- from barDefaults, so a new setting added later lands on every bar at once.
local BAR_OVERRIDES = {
    player = { point = "CENTER", x = 0,    y = -200, showLatency = true, width = 260 },
    -- Interrupt colouring is on out of the box for the two bars you actually watch
    -- for a kick. It is available on the boss bars too, just not assumed.
    target = { point = "CENTER", x = 0,    y = 200,
               showInterruptReady = true, showInterruptNotReady = true },
    focus  = { point = "CENTER", x = -330, y = 160, width = 200, height = 20,
               showInterruptReady = true, showInterruptNotReady = true },
    pet    = { point = "CENTER", x = -330, y = -160, width = 180, height = 18, showTarget = false },
    boss   = { point = "RIGHT",  x = -360, y = 120, width = 200, height = 20 },
}

NCB.defaults = {
    enabled       = true,
    locked        = true,
    minimapHidden = false,
    minimapAngle  = 200,
    -- Optional hand-typed spell ids to treat as your interrupt, replacing the
    -- class list. Global rather than per bar: which spell your kick is has nothing
    -- to do with which bar is drawing it.
    interruptSpells = "",
    -- Landing an interrupt is worth hearing about, and it is the one thing here the
    -- combat log will still tell us plainly.
    interruptAnnounce  = "off",     -- off | chat | screen | both
    interruptSound     = false,
    interruptSoundName = "Raid Warning",
    -- The on-screen announcement is its own movable frame rather than a borrowed
    -- Blizzard one, so it can be placed, styled and sized like everything else here.
    announcePoint      = "CENTER",
    announceRelPoint   = "CENTER",
    announceX          = 0,
    announceY          = 140,
    announceFont       = "Friz Quadrata TT",
    announceFontSize   = 22,
    announceOutline    = "OUTLINE",
    announceColor      = { 0.25, 1.00, 0.45 },
    announceHold       = 1.50,
    announceFade       = 0.60,
    bars          = {},
}

NCB.charDefaults = {
    -- Cast lengths we have watched run to completion, keyed by spellID. Only used
    -- as a fallback: if the client ever hands us a start/end time we cannot do
    -- arithmetic on, a length we measured ourselves still draws an honest bar.
    learned = {},
}

local function CopyDefaults(dst, src)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = CopyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end
NCB.CopyDefaults = CopyDefaults

local function InitDB()
    nugsCastBarsDB     = CopyDefaults(nugsCastBarsDB     or {}, NCB.defaults)
    nugsCastBarsCharDB = CopyDefaults(nugsCastBarsCharDB or {}, NCB.charDefaults)

    for _, def in ipairs(NCB.UNITS) do
        local cfg = nugsCastBarsDB.bars[def.key] or {}
        cfg = CopyDefaults(cfg, BAR_OVERRIDES[def.key] or {})
        cfg = CopyDefaults(cfg, NCB.barDefaults)
        nugsCastBarsDB.bars[def.key] = cfg
    end

    NCB.db   = nugsCastBarsDB
    NCB.char = nugsCastBarsCharDB
    nugsCastBarsDB.profiles = nugsCastBarsDB.profiles or {}
end

--------------------------------------------------------------------------------
-- Profiles
-- Named snapshots of the settings, kept in the account-wide saved variables -
-- which is the whole trick. Save one on any character and every other character
-- can see and load it, with no strings to copy and nothing to export.
--
-- Loading is always a deliberate act. Nothing is bound to a character and nothing
-- auto-saves: a change you make now simply stays, until you choose to Save it into
-- a profile or Load a different one over it.
--
-- Everything in the saved variables is profiled EXCEPT what is listed here, so a
-- setting added later is carried automatically rather than being quietly left out
-- until somebody notices it did not travel.
--------------------------------------------------------------------------------
local PROFILE_SKIP = {
    profiles      = true,   -- the store itself
    activeProfile = true,   -- a record ABOUT profiles, never part of one
    minimapAngle  = true,   -- where you dragged the button is not a look
    minimapHidden = true,
}

local function ProfileDeepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, sub in pairs(v) do out[k] = ProfileDeepCopy(sub) end
    return out
end

-- Written out rather than using `s:trim()`: that is a WoW helper, not Lua, and this
-- file has no business assuming which of them is present.
local function ProfileTrim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
NCB.TrimName = ProfileTrim

function NCB.ProfileNames()
    local names = {}
    for name in pairs(NCB.db.profiles or {}) do names[#names + 1] = name end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function NCB.SaveProfile(name)
    name = ProfileTrim(name)
    if name == "" then return false end
    local snap = {}
    for k, v in pairs(NCB.db) do
        if not PROFILE_SKIP[k] then snap[k] = ProfileDeepCopy(v) end
    end
    NCB.db.profiles[name] = snap
    NCB.db.activeProfile = name
    return true
end

function NCB.LoadProfile(name)
    local snap = NCB.db.profiles and NCB.db.profiles[name]
    if not snap then return false end
    for k, v in pairs(snap) do
        if not PROFILE_SKIP[k] then NCB.db[k] = ProfileDeepCopy(v) end
    end
    NCB.db.activeProfile = name
    if NCB.Bars and NCB.Bars.ApplyAll then NCB.Bars:ApplyAll() end
    if NCB.RefreshOptions then NCB.RefreshOptions() end
    return true
end


-- Which profile the current settings correspond to.
--
-- Returns the name and whether the live settings still MATCH it. Loading a profile
-- and then nudging one slider leaves you on "Raid, modified" - which is the honest
-- answer, and the one that stops somebody assuming their change was saved.
local function ProfileSnapshot()
    local snap = {}
    for k, v in pairs(NCB.db) do
        if not PROFILE_SKIP[k] then snap[k] = ProfileDeepCopy(v) end
    end
    return snap
end

local function SameSettings(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not SameSettings(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function NCB.ProfileStatus()
    local name = NCB.db.activeProfile
    local stored = name and NCB.db.profiles and NCB.db.profiles[name]
    if not stored then return nil, false end
    return name, SameSettings(ProfileSnapshot(), stored)
end

function NCB.DeleteProfile(name)
    name = ProfileTrim(name)
    if not (NCB.db.profiles and NCB.db.profiles[name]) then return false end
    NCB.db.profiles[name] = nil
    return true
end


function NCB.Config(key)
    return NCB.db and NCB.db.bars[key]
end

-- Reset one bar, or every bar, back to the shipped look. Position is included:
-- "reset" that leaves a bar somewhere you cannot find is not a reset.
function NCB.ResetBar(key)
    local cfg = NCB.Config(key)
    if not cfg then return end
    for k in pairs(cfg) do cfg[k] = nil end
    CopyDefaults(cfg, BAR_OVERRIDES[key] or {})
    CopyDefaults(cfg, NCB.barDefaults)
    NCB.Bars:ApplyAll()
end

-- Everything that is a matter of taste rather than placement. Copied by the
-- options window's "use this look everywhere" button.
local LOOK_KEYS = {
    "texture", "font", "fontSize", "fontOutline", "showIcon", "iconSide", "iconZoom",
    "iconGap", "showName", "nameJustify", "nameMaxChars", "showTime", "timeFormat",
    "decimals", "showTarget", "targetPos", "targetClassColor", "warnOnYou",
    "showShield", "showSpark", "showBorder", "fadeTime", "holdTime",
    "showInterruptReady", "showInterruptNotReady",
    "colorCast", "colorChannel", "colorUninterruptible", "colorSuccess",
    "colorFailed", "colorBackground", "colorBorder", "colorText",
    "colorInterruptReady", "colorInterruptNotReady",
}

function NCB.CopyLook(fromKey)
    local src = NCB.Config(fromKey)
    if not src then return end
    for _, def in ipairs(NCB.UNITS) do
        if def.key ~= fromKey then
            local dst = NCB.Config(def.key)
            for _, k in ipairs(LOOK_KEYS) do
                local v = src[k]
                if type(v) == "table" then
                    local copy = {}
                    for i, n in ipairs(v) do copy[i] = n end
                    dst[k] = copy
                else
                    dst[k] = v
                end
            end
        end
    end
    NCB.Bars:ApplyAll()
end

--------------------------------------------------------------------------------
-- nugsSuite
--------------------------------------------------------------------------------
-- One entry in a plain global table, which the nugsSuite launcher reads to list
-- this addon, open its options and carry its settings between characters.
--
-- Written unconditionally and without checking whether nugsSuite exists: the table
-- is inert on its own, so this costs nothing when the suite is not installed, and
-- being a global rather than a call into it means neither addon has to load first.
--
-- NCB.defaults alone would be a poor answer to GetDB, because db.bars starts empty
-- and is filled per unit by InitDB. Handing over defaults that do not include the
-- bars would make every bar setting look changed, so the effective defaults are
-- rebuilt here the same way InitDB seeds them.
local function EffectiveDefaults()
    local eff = CopyDefaults({}, NCB.defaults)
    eff.bars = {}
    for _, def in ipairs(NCB.UNITS) do
        local cfg = CopyDefaults({}, BAR_OVERRIDES[def.key] or {})
        eff.bars[def.key] = CopyDefaults(cfg, NCB.barDefaults)
    end
    return eff
end

local function RegisterWithSuite()
    _G.nugsSuiteRegistry = _G.nugsSuiteRegistry or {}
    _G.nugsSuiteRegistry[ADDON_NAME] = {
        title      = "nugsCastBars",
        version    = NCB.version,
        icon       = "Interface\\AddOns\\nugsCastBars\\icon",
        slash      = "/ncb",
        Open       = function() NCB.ToggleOptions() end,
        SetMinimap = function(shown)
            NCB.db.minimapHidden = not shown
            NCB.SetMinimapShown(shown)
        end,
        GetDB      = function() return nugsCastBarsDB, EffectiveDefaults() end,
        GetCharDB  = function() return nugsCastBarsCharDB, NCB.charDefaults end,
        -- Where this button sits is nobody else's business, and `learned` is a
        -- measured cast-length cache - machine written, per character, and the
        -- largest thing in the saved variables. Neither belongs in a shared profile.
        exclude     = { minimapAngle = true },
        excludeChar = { learned = true },
    }
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
        NCB.Bars:Init()
        if NCB.InitOptions then NCB.InitOptions() end
        RegisterWithSuite()

    elseif event == "PLAYER_LOGIN" then
        NCB.InitMinimap()
        NCB.Interrupts:Rebuild()
        NCB.Interrupts:UpdateWatcher()
        NCB.Interrupts:ApplyDisplay()
        NCB.Bars:ApplyAll()
        NCB.Bars:HideBlizzard()
    end
end)

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------
local function Usage()
    NCB.Print("v" .. NCB.version .. " commands:")
    print("  |cffffd479/ncb|r - open the options window")
    print("  |cffffd479/ncb unlock|r / |cffffd479/ncb lock|r - drag the bars into place")
    print("  |cffffd479/ncb test|r - run a demo cast on every enabled bar")
    print("  |cffffd479/ncb on|r / |cffffd479/ncb off|r - master switch")
    print("  |cffffd479/ncb reset <player|target|focus|pet|boss|all>|r")
    print("  |cffffd479/ncb minimap|r - show or hide the minimap button")
    print("  |cffffd479/ncb diag|r - report what the addon sees on every bar")
    print("  |cffffd479/ncb debug|r - log every spellcast event as it arrives")
end

SLASH_NUGSCASTBARS1 = "/ncb"
SLASH_NUGSCASTBARS2 = "/nugscastbars"
SlashCmdList["NUGSCASTBARS"] = function(msg)
    local db = NCB.db
    if not db then return end

    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd  = (cmd or ""):lower()
    rest = (rest or ""):lower()

    if cmd == "" or cmd == "config" or cmd == "options" then
        NCB.ToggleOptions()

    elseif cmd == "on" or cmd == "off" then
        db.enabled = (cmd == "on")
        NCB.Bars:ApplyAll()
        NCB.Print("bars " .. (db.enabled and "enabled" or "disabled") .. ".")

    elseif cmd == "unlock" then
        NCB.Bars:SetLocked(false)
        NCB.Print("bars unlocked - drag them where you want them, then |cffffd479/ncb lock|r.")

    elseif cmd == "lock" then
        NCB.Bars:SetLocked(true)
        NCB.Print("bars locked.")

    elseif cmd == "test" then
        NCB.Bars:TestAll()

    elseif cmd == "diag" then
        NCB.Diagnostics()

    elseif cmd == "debug" then
        NCB.debug = not NCB.debug
        NCB.Print("debug " .. (NCB.debug and
            "on - every spellcast event for a watched unit is now logged." or "off."))

    elseif cmd == "minimap" then
        db.minimapHidden = not db.minimapHidden
        NCB.SetMinimapShown(not db.minimapHidden)
        NCB.Print("minimap button " .. (db.minimapHidden and "hidden" or "shown") .. ".")

    elseif cmd == "reset" then
        if rest == "all" or rest == "" then
            for _, def in ipairs(NCB.UNITS) do NCB.ResetBar(def.key) end
            NCB.Print("every bar reset to defaults.")
        elseif NCB.UnitByKey(rest) then
            NCB.ResetBar(rest)
            NCB.Print(rest .. " bar reset to defaults.")
        else
            NCB.Print("usage: /ncb reset <player|target|focus|pet|boss|all>")
        end

    else
        Usage()
    end

    if NCB.RefreshOptions then NCB.RefreshOptions() end
end
