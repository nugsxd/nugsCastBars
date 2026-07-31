--------------------------------------------------------------------------------
-- nugsCastBars
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsCastBars  -  Options.lua
-- One movable settings window in the same flat dark skin as RaidReady and
-- nugsCooldownPulse: a tab per bar across the top, two columns of settings below,
-- and the same controls for every bar so nothing is buried on one tab only.
--
-- Widgets are hand-rolled rather than built on Blizzard templates, which get
-- renamed between expansions.
--------------------------------------------------------------------------------
local ADDON_NAME, NCB = ...

--------------------------------------------------------------------------------
-- Theme
--------------------------------------------------------------------------------
local C = {
    bg     = { 0.07, 0.07, 0.07, 0.96 },
    header = { 0.10, 0.10, 0.10, 1.00 },
    panel  = { 0.10, 0.10, 0.10, 0.90 },
    input  = { 0.14, 0.14, 0.14, 1.00 },
    btn    = { 0.16, 0.16, 0.16, 1.00 },
    btnHi  = { 0.24, 0.24, 0.24, 1.00 },
    accent = { 0.35, 0.72, 1.00, 1.00 },
    rowB   = { 1, 1, 1, 0.055 },
    text   = { 0.82, 0.82, 0.82 },
    faint  = { 0.50, 0.50, 0.50 },
    gold   = { 1.00, 0.84, 0.42 },
}

local ADDON_ICON = "Interface\\AddOns\\nugsCastBars\\icon"

-- The two columns have to fit inside the window minus the panel inset, the scroll
-- inset and the scroll indicator, or the right column runs off under the edge.
local WIDTH, HEIGHT = 812, 640
local CONTENT_W = WIDTH - 46
local COL_GAP   = 22
local COL_W     = math.floor((CONTENT_W - COL_GAP) / 2)
local ROW_H    = 22

local window, tabStrip, barPanel, generalPanel, barContent, generalContent
local barWidgets, generalWidgets = {}, {}
local sink = barWidgets            -- where newly built widgets register themselves
local currentKey = "player"
local RelayoutAll                  -- forward declaration

local function cfg() return NCB.Config(currentKey) end
local function isBoss()   return currentKey == "boss"   end
local function isPlayer() return currentKey == "player" end
-- The bars that show somebody else's cast, and so are the only ones where "can I
-- kick this" is a question worth colouring.
local function isEnemyBar()
    return currentKey == "target" or currentKey == "focus" or currentKey == "boss"
end

--------------------------------------------------------------------------------
-- Widget helpers
--------------------------------------------------------------------------------
local function Backdrop(frame, color, borderAlpha)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(color))
    frame.bgTex = bg
    if borderAlpha then
        for _, p in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" } }) do
            local t = frame:CreateTexture(nil, "BORDER")
            t:SetPoint(p[1]); t:SetPoint(p[2]); t:SetHeight(1)
            t:SetColorTexture(0, 0, 0, borderAlpha)
        end
        for _, p in ipairs({ { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
            local t = frame:CreateTexture(nil, "BORDER")
            t:SetPoint(p[1]); t:SetPoint(p[2]); t:SetWidth(1)
            t:SetColorTexture(0, 0, 0, borderAlpha)
        end
    end
    return bg
end

local function Panel(parent, color)
    local f = CreateFrame("Frame", nil, parent)
    Backdrop(f, color or C.panel, 1)
    return f
end

local function Label(parent, text, template, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(unpack(color or C.text))
    return fs
end

local function SectionHeader(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetText(text)
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(unpack(C.accent))
    return fs
end

local function Button(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    Backdrop(b, C.btn, 1)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(text)
    b.text:SetTextColor(unpack(C.text))
    b:SetScript("OnEnter", function(self) self.bgTex:SetColorTexture(unpack(C.btnHi)) end)
    b:SetScript("OnLeave", function(self) self.bgTex:SetColorTexture(unpack(C.btn)) end)
    b:SetScript("OnClick", onClick)
    b.SetLabel = function(self, t) self.text:SetText(t) end
    return b
end

-- Deliberately built to match RaidReady's header so the suite reads as one thing:
-- a 30px bar with a storm-blue underline, the addon icon on the left, a gold title
-- with a blue tail, and a small flat close button.

local function HeaderBar(f, titleText, tailText)
    local header = CreateFrame("Frame", nil, f)
    Backdrop(header, C.header, 1)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(30)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local accent = header:CreateTexture(nil, "OVERLAY")
    accent:SetPoint("BOTTOMLEFT", 0, 0)
    accent:SetPoint("BOTTOMRIGHT", 0, 0)
    accent:SetHeight(3)
    accent:SetColorTexture(unpack(C.accent))

    local icon = header:CreateTexture(nil, "OVERLAY")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", 10, 0)
    icon:SetTexture(ADDON_ICON)

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText(titleText .. (tailText and (" |cff8cd2ff" .. tailText .. "|r") or ""))
    title:SetTextColor(unpack(C.gold))

    local close = Button(header, "x", 22, 18, function() f:Hide() end)
    close:SetPoint("RIGHT", -6, 0)

    -- Shown only when nugsSuite is absent. _G.nugsSuite is the suite's own handle,
    -- so this also reads correctly when it is installed but switched off - a
    -- disabled suite is no more use than a missing one.
    --
    -- A note, never a warning, and never a dependency: this addon works perfectly
    -- well on its own and the suite is only worth having once you run more than one.
    if not _G.nugsSuite then
        local suite = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        suite:SetPoint("RIGHT", close, "LEFT", -10, 0)
        suite:SetText("Part of the |cff8cd2ffnugs suite|r")
        suite:SetTextColor(unpack(C.faint))
    end

    return header
end

-- Checkbox: a small square that fills with the accent colour when on.
local function Check(parent, text, getter, setter, tooltip)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(ROW_H)

    local box = CreateFrame("Frame", nil, b)
    box:SetSize(14, 14)
    box:SetPoint("LEFT", 0, 0)
    Backdrop(box, C.input, 1)

    local fill = box:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 3, -3)
    fill:SetPoint("BOTTOMRIGHT", -3, 3)
    fill:SetColorTexture(unpack(C.accent))

    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", box, "RIGHT", 6, 0)
    fs:SetPoint("RIGHT", b, "RIGHT", -4, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    fs:SetTextColor(unpack(C.text))

    b:SetScript("OnClick", function()
        setter(not getter())
        NCB.Bars:ApplyAll()
        NCB.RefreshOptions()
    end)
    b:SetScript("OnEnter", function(self)
        fs:SetTextColor(1, 1, 1)
        if tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(text)
            GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function()
        fs:SetTextColor(unpack(C.text))
        GameTooltip:Hide()
    end)

    b.Refresh = function() fill:SetShown(getter() and true or false) end
    sink[#sink + 1] = b
    return b
end

-- Slider: title on the left, live value on the right, bar underneath.
local sliderIndex = 0
local function Slider(parent, title, minV, maxV, step, getter, setter, fmt)
    sliderIndex = sliderIndex + 1
    local name = "nugsCastBarsSlider" .. sliderIndex

    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(40)

    local titleFS = Label(holder, title, "GameFontNormalSmall")
    titleFS:SetPoint("TOPLEFT", 0, 0)

    -- Typeable rather than a read-only label: dragging is for finding a value,
    -- typing is for repeating one you already know. Both drive the same setter.
    --
    -- Commits on Enter AND on losing focus, so clicking away is not a silent
    -- discard. Anything that is not a number puts the live value back rather than
    -- becoming zero, and the result is clamped to the slider's own range so a stray
    -- extra digit cannot push a setting somewhere the slider could never reach.
    local valueBox = CreateFrame("EditBox", nil, holder)
    valueBox:SetPoint("TOPRIGHT", 0, 2)
    valueBox:SetSize(56, 18)
    valueBox:SetAutoFocus(false)
    valueBox:SetFontObject("GameFontHighlightSmall")
    valueBox:SetJustifyH("RIGHT")
    valueBox:SetTextInsets(4, 4, 0, 0)
    valueBox:SetTextColor(unpack(C.accent))
    Backdrop(valueBox, C.input, 1)

    local valueFS = {
        SetText = function(_, text)
            if not valueBox:HasFocus() then
                valueBox:SetText(text)
                valueBox:SetCursorPosition(0)
            end
        end,
    }

    local function CommitTyped(text)
        local n = tonumber(text)
        -- Do nothing when the text already matches the live value. Losing focus fires
        -- this too, so clicking straight onto the slider would otherwise re-apply
        -- whatever was in the box over the value you just clicked - which reads as
        -- the slider jumping out from under you.
        if n and math.abs(n - (getter() or 0)) < 1e-6 then n = nil end
        if n then
            if n < minV then n = minV elseif n > maxV then n = maxV end
            n = tonumber(string.format("%.4f", math.floor(n / step + 0.5) * step))
            setter(n)
            NCB.Bars:ApplyAll()
        end
        local v = getter()
        valueBox:SetText(string.format(fmt or "%.2f", v))
        valueBox:SetCursorPosition(0)
        if holder.Refresh then holder.Refresh() end
    end

    valueBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    valueBox:SetScript("OnEscapePressed", function(self)
        self:SetText(string.format(fmt or "%.2f", getter()))
        self:ClearFocus()
    end)
    valueBox:SetScript("OnEditFocusLost", function(self) CommitTyped(self:GetText()) end)

    local sl
    local ok = pcall(function()
        sl = CreateFrame("Slider", name, holder, "OptionsSliderTemplate")
    end)
    if not ok or not sl then
        -- Template missing on this client: fall back to a bare slider we skin ourselves.
        sl = CreateFrame("Slider", name, holder)
        sl:SetOrientation("HORIZONTAL")
        local track = sl:CreateTexture(nil, "BACKGROUND")
        track:SetPoint("LEFT"); track:SetPoint("RIGHT")
        track:SetHeight(4)
        track:SetColorTexture(0.25, 0.25, 0.25, 1)
        sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    end
    sl:SetPoint("TOPLEFT", 2, -18)
    sl:SetPoint("TOPRIGHT", -2, -18)
    sl:SetHeight(16)
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end

    -- The template ships Low/High/Text labels we do not want.
    for _, suffix in ipairs({ "Low", "High", "Text" }) do
        local fs = sl[suffix] or _G[name .. suffix]
        if fs and fs.SetText then fs:SetText("") end
    end

    local applying = false
    sl:SetScript("OnValueChanged", function(self, value)
        if applying then return end
        -- SetValueStep does not round for us on every path, and the leftover float
        -- noise would end up in saved variables.
        value = tonumber(string.format("%.4f", math.floor(value / step + 0.5) * step))
        setter(value)
        valueFS:SetText(string.format(fmt or "%.2f", value))
        NCB.Bars:ApplyAll()
    end)

    holder.Refresh = function()
        applying = true
        local v = getter()
        sl:SetValue(v)
        valueFS:SetText(string.format(fmt or "%.2f", v))
        applying = false
    end
    sink[#sink + 1] = holder
    return holder
end

-- Cycling choice button. A dropdown would be the obvious widget, but Blizzard has
-- renamed that one twice in two expansions, and with three or four options a
-- click-to-cycle button is fewer motions anyway.
local function Choice(parent, prefix, options, getter, setter)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(ROW_H)

    local function keyOf(o) return type(o) == "table" and o.key or o end
    local function labelOf(o) return type(o) == "table" and o.label or o end

    local btn
    btn = Button(holder, "", 100, ROW_H, function()
        local index = 1
        for i, o in ipairs(options) do
            if keyOf(o) == getter() then index = i break end
        end
        setter(keyOf(options[(index % #options) + 1]))
        NCB.Bars:ApplyAll()
        NCB.RefreshOptions()
    end)
    btn:SetPoint("LEFT", 0, 0)
    btn:SetPoint("RIGHT", 0, 0)

    holder.Refresh = function()
        local text = tostring(getter())
        for _, o in ipairs(options) do
            if keyOf(o) == getter() then text = labelOf(o) end
        end
        btn:SetLabel(prefix .. ": " .. text)
    end
    sink[#sink + 1] = holder
    return holder
end

-- Colour swatch. Opens the game's own picker, which knows how to be a colour
-- picker better than anything hand-rolled would.
local function ShowColorPicker(r, g, b, a, hasAlpha, apply)
    local function currentAlpha()
        if ColorPickerFrame.GetColorAlpha then
            local ok, v = pcall(ColorPickerFrame.GetColorAlpha, ColorPickerFrame)
            if ok and type(v) == "number" then return v end
        end
        if _G.OpacitySliderFrame then return 1 - _G.OpacitySliderFrame:GetValue() end
        return a or 1
    end
    local function onChange()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        apply(nr, ng, nb, hasAlpha and currentAlpha() or a)
    end

    local info = {
        r = r, g = g, b = b,
        hasOpacity = hasAlpha,
        opacity    = hasAlpha and (a or 1) or nil,
        swatchFunc = onChange,
        opacityFunc = onChange,
        cancelFunc = function() apply(r, g, b, a) end,
    }

    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow(info)
    else
        -- Pre-11.x shape, kept so the window is never dead on an older client.
        ColorPickerFrame.func        = info.swatchFunc
        ColorPickerFrame.opacityFunc = info.opacityFunc
        ColorPickerFrame.cancelFunc  = info.cancelFunc
        ColorPickerFrame.hasOpacity  = hasAlpha
        ColorPickerFrame.opacity     = hasAlpha and (1 - (a or 1)) or nil
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame:Hide()
        ColorPickerFrame:Show()
    end
end

local function Swatch(parent, text, getter, hasAlpha)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(ROW_H)

    local well = CreateFrame("Frame", nil, b)
    well:SetSize(30, 14)
    well:SetPoint("LEFT", 0, 0)
    Backdrop(well, { 0, 0, 0, 1 }, 1)

    local fill = well:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", -1, 1)

    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", well, "RIGHT", 8, 0)
    fs:SetText(text)
    fs:SetTextColor(unpack(C.text))

    b:SetScript("OnClick", function()
        local color = getter()
        ShowColorPicker(color[1], color[2], color[3], color[4] or 1, hasAlpha,
            function(r, g, b2, a)
                local c = getter()
                c[1], c[2], c[3] = r, g, b2
                if hasAlpha then c[4] = a end
                NCB.Bars:ApplyAll()
                NCB.RefreshOptions()
            end)
    end)
    b:SetScript("OnEnter", function() fs:SetTextColor(1, 1, 1) end)
    b:SetScript("OnLeave", function() fs:SetTextColor(unpack(C.text)) end)

    b.Refresh = function()
        local c = getter()
        fill:SetColorTexture(c[1], c[2], c[3], hasAlpha and (c[4] or 1) or 1)
    end
    sink[#sink + 1] = b
    return b
end

-- Single-line text field. It re-reads the saved value when the window refreshes,
-- but never while it has focus: overwriting what someone is halfway through typing
-- is maddening.
local function EditBox(parent, getter, setter, placeholder)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(24)

    local eb = CreateFrame("EditBox", nil, holder)
    eb:SetPoint("TOPLEFT", 0, 0)
    eb:SetPoint("TOPRIGHT", 0, 0)
    eb:SetHeight(22)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetTextInsets(6, 6, 0, 0)
    Backdrop(eb, C.input, 1)

    local ghost = Label(eb, placeholder or "", "GameFontDisableSmall", C.faint)
    ghost:SetPoint("LEFT", 8, 0)

    -- ClearFocus fires OnEditFocusLost, which would re-enter commit; the guard
    -- stops the setter running twice for one edit.
    local committing = false
    local function commit(self)
        if committing then return end
        committing = true
        setter(self:GetText() or "")
        self:ClearFocus()
        committing = false
        NCB.RefreshOptions()
    end

    eb:SetScript("OnEnterPressed", commit)
    eb:SetScript("OnEditFocusLost", commit)
    eb:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        NCB.RefreshOptions()
    end)
    eb:SetScript("OnTextChanged", function(self)
        ghost:SetShown((self:GetText() or "") == "")
    end)

    holder.Refresh = function()
        if eb:HasFocus() then return end
        eb:SetText(getter() or "")
        ghost:SetShown((eb:GetText() or "") == "")
    end
    -- Exposed so a caller can read what is typed RIGHT NOW. The setter only fires on
    -- Enter or focus loss, and clicking a button does not reliably take focus off an
    -- edit box - so a Save button that read the setter's value could act on the
    -- previous name rather than the one on screen.
    holder.editBox = eb
    sink[#sink + 1] = holder
    return holder
end

-- Wheel-scrolled area: no Blizzard scroll template, just a child frame we shift
-- plus a thin position indicator on the right edge.
local function ScrollArea(parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    scroll.content = content

    local track = scroll:CreateTexture(nil, "ARTWORK")
    track:SetPoint("TOPRIGHT", 0, 0)
    track:SetPoint("BOTTOMRIGHT", 0, 0)
    track:SetWidth(3)
    track:SetColorTexture(1, 1, 1, 0.05)

    local thumb = scroll:CreateTexture(nil, "OVERLAY")
    thumb:SetWidth(3)
    thumb:SetColorTexture(unpack(C.accent))

    function scroll:UpdateBar()
        local viewH    = self:GetHeight() or 1
        local totalH   = content:GetHeight() or 1
        local maxScrol = math.max(0, totalH - viewH)
        if self:GetVerticalScroll() > maxScrol then self:SetVerticalScroll(maxScrol) end
        if maxScrol <= 0 then
            track:Hide(); thumb:Hide()
            return
        end
        track:Show(); thumb:Show()
        local frac   = math.min(1, viewH / totalH)
        local thumbH = math.max(20, viewH * frac)
        local travel = viewH - thumbH
        local pos    = (self:GetVerticalScroll() / maxScrol) * travel
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -pos)
    end

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local viewH    = self:GetHeight() or 1
        local maxScrol = math.max(0, (content:GetHeight() or 1) - viewH)
        local new = math.max(0, math.min(maxScrol, self:GetVerticalScroll() - delta * 34))
        self:SetVerticalScroll(new)
        self:UpdateBar()
    end)

    return scroll
end

-- Saved-profile picker.
--
-- Width comes from the popup's own SetSize, NOT from scroll:GetWidth(): the scroll is
-- sized by anchors, so on the first open - the frame having just been created, with no
-- layout pass yet - it measures 0, every row is built zero-wide, and the list looks
-- empty until you click again.
--
-- The fill is lifted off the window's near-black and edged in accent, so a floating
-- list reads as sitting on top rather than blending into the panel behind it.
local namePopup

local function ToggleNamePicker(parent, anchorTo, names, onPick)
    if namePopup and namePopup:IsShown() then
        namePopup:Hide()
        return
    end

    if not namePopup then
        namePopup = CreateFrame("Frame", nil, parent)
        namePopup:SetSize(200, 200)
        namePopup:SetFrameStrata("FULLSCREEN_DIALOG")
        namePopup:SetToplevel(true)
        namePopup:SetClampedToScreen(true)
        namePopup:EnableMouse(true)
        Backdrop(namePopup, { 0.13, 0.13, 0.15, 0.98 }, 1)
        for _, p in ipairs({ { "TOPLEFT", "TOPRIGHT", "h" }, { "BOTTOMLEFT", "BOTTOMRIGHT", "h" },
                             { "TOPLEFT", "BOTTOMLEFT", "v" }, { "TOPRIGHT", "BOTTOMRIGHT", "v" } }) do
            local edge = namePopup:CreateTexture(nil, "OVERLAY")
            edge:SetPoint(p[1]); edge:SetPoint(p[2])
            if p[3] == "h" then edge:SetHeight(1) else edge:SetWidth(1) end
            edge:SetColorTexture(0.35, 0.72, 1.00, 0.55)
        end
        namePopup.scroll = ScrollArea(namePopup)
        namePopup.scroll:SetPoint("TOPLEFT", 5, -5)
        namePopup.scroll:SetPoint("BOTTOMRIGHT", -5, 5)
        namePopup.rows = {}
    end
    namePopup:SetParent(parent)

    local content = namePopup.scroll.content
    content:SetWidth(namePopup:GetWidth() - 10)

    for index, name in ipairs(names) do
        local row = namePopup.rows[index]
        if not row then
            row = CreateFrame("Button", nil, content)
            row:SetHeight(22)
            row:SetPoint("TOPLEFT", 0, -(index - 1) * 22)
            row:SetPoint("TOPRIGHT", 0, -(index - 1) * 22)
            row.stripe = row:CreateTexture(nil, "BACKGROUND")
            row.stripe:SetAllPoints()
            row.stripe:SetColorTexture(1, 1, 1, 0)
            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.label:SetPoint("LEFT", 6, 0)
            row.label:SetPoint("RIGHT", -6, 0)
            row.label:SetJustifyH("LEFT")
            row:SetScript("OnEnter", function(self) self.stripe:SetColorTexture(unpack(C.rowB)) end)
            row:SetScript("OnLeave", function(self) self.stripe:SetColorTexture(1, 1, 1, 0) end)
            namePopup.rows[index] = row
        end
        row.label:SetText(name)
        row:SetScript("OnClick", function()
            onPick(name)
            namePopup:Hide()
        end)
        row:Show()
    end
    for index = #names + 1, #namePopup.rows do namePopup.rows[index]:Hide() end

    content:SetHeight(math.max(1, #names * 22))
    namePopup.scroll:SetVerticalScroll(0)
    if namePopup.scroll.UpdateBar then namePopup.scroll:UpdateBar() end

    namePopup:ClearAllPoints()
    local below = (anchorTo:GetBottom() or 0) - namePopup:GetHeight()
    if below < 20 then
        namePopup:SetPoint("BOTTOMLEFT", anchorTo, "TOPLEFT", 0, 2)
    else
        namePopup:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -2)
    end
    namePopup:Raise()
    namePopup:Show()
end

--------------------------------------------------------------------------------
-- Column layout
-- Widgets declare when they are relevant (`show`), and the column re-flows around
-- whatever is hidden. That is what lets one panel serve all five bars without
-- leaving dead controls on the tabs they do not apply to.
--------------------------------------------------------------------------------
local function NewColumn(parent, xOffset, width)
    local col = { parent = parent, x = xOffset, width = width, items = {} }

    function col:Add(region, height, show, indent)
        local isText = region.GetObjectType and region:GetObjectType() == "FontString"
        self.items[#self.items + 1] = {
            region = region, h = height, show = show,
            indent = indent or 0, stretch = not isText,
        }
        return region
    end

    -- The leading gap carries the section's own visibility, so a section that does
    -- not apply to this bar leaves no hole where it would have been.
    function col:Header(text, show)
        self:Gap(6, show)
        return self:Add(SectionHeader(self.parent, text), 22, show)
    end

    function col:Hint(text, show)
        local fs = Label(self.parent, text, "GameFontDisableSmall", C.faint)
        local _, lines = text:gsub("\n", "")
        return self:Add(fs, 14 + lines * 12, show)
    end

    function col:Gap(h, show)
        self.items[#self.items + 1] = { h = h, show = show }
    end

    function col:Layout()
        local y = 0
        for _, item in ipairs(self.items) do
            local visible = (not item.show) or item.show()
            if item.region then
                if visible then
                    item.region:Show()
                    item.region:ClearAllPoints()
                    item.region:SetPoint("TOPLEFT", self.parent, "TOPLEFT",
                        self.x + item.indent, -y)
                    if item.stretch then
                        item.region:SetPoint("TOPRIGHT", self.parent, "TOPLEFT",
                            self.x + self.width, -y)
                    else
                        item.region:SetWidth(self.width - item.indent)
                    end
                    y = y + item.h
                else
                    item.region:Hide()
                end
            elseif visible then
                y = y + item.h
            end
        end
        return y
    end

    return col
end

--------------------------------------------------------------------------------
-- Media picker
-- A popup list rather than a dropdown, and every entry previews itself: fonts are
-- drawn in their own font, bar textures as an actual filled bar. Picking a look
-- from a list of names alone is guesswork.
--------------------------------------------------------------------------------
local mediaPopup

local function ToggleMediaPicker(kind, anchorTo, current, onPick)
    if mediaPopup and mediaPopup:IsShown() and mediaPopup.kind == kind
       and mediaPopup.anchorTo == anchorTo then
        mediaPopup:Hide()
        return
    end

    if not mediaPopup then
        mediaPopup = CreateFrame("Frame", nil, UIParent)
        mediaPopup:SetSize(250, 300)
        mediaPopup:SetFrameStrata("FULLSCREEN_DIALOG")
        mediaPopup:EnableMouse(true)
        Backdrop(mediaPopup, C.bg, 1)
        mediaPopup.scroll = ScrollArea(mediaPopup)
        mediaPopup.scroll:SetPoint("TOPLEFT", 5, -5)
        mediaPopup.scroll:SetPoint("BOTTOMRIGHT", -5, 5)
        mediaPopup.rows = {}
    end

    mediaPopup.kind     = kind
    mediaPopup.anchorTo = anchorTo

    local entries = (kind == "font") and NCB.FontList()
                    or (kind == "sound") and NCB.SoundList()
                    or NCB.TextureList()
    local content = mediaPopup.scroll.content
    content:SetWidth(mediaPopup.scroll:GetWidth())

    for index, entry in ipairs(entries) do
        local row = mediaPopup.rows[index]
        if not row then
            row = CreateFrame("Button", nil, content)
            row:SetHeight(24)
            row.stripe = row:CreateTexture(nil, "BACKGROUND")
            row.stripe:SetAllPoints()
            row.preview = CreateFrame("StatusBar", nil, row)
            row.preview:SetPoint("LEFT", 6, 0)
            row.preview:SetSize(70, 14)
            row.preview:SetMinMaxValues(0, 1)
            row.preview:SetValue(1)
            row.preview:SetStatusBarColor(unpack(C.accent))
            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.label:SetJustifyH("LEFT")
            row:SetScript("OnEnter", function(self) self.stripe:SetColorTexture(unpack(C.rowB)) end)
            row:SetScript("OnLeave", function(self)
                self.stripe:SetColorTexture(1, 1, 1, self.selected and 0.10 or 0)
            end)
            mediaPopup.rows[index] = row
        end

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -(index - 1) * 24)
        row:SetPoint("TOPRIGHT", 0, -(index - 1) * 24)
        row.label:ClearAllPoints()
        row.label:SetText(entry.name)

        if kind == "font" then
            row.preview:Hide()
            row.label:SetPoint("LEFT", 8, 0)
            row.label:SetPoint("RIGHT", -6, 0)
            local ok, applied = pcall(row.label.SetFont, row.label, entry.path, 13, "")
            if not ok or applied == false then
                row.label:SetFontObject("GameFontHighlightSmall")
                row.label:SetText(entry.name .. " |cff888888(unavailable)|r")
            end
        elseif kind == "sound" then
            -- No preview strip to draw; a cue previews by being played, which
            -- happens on click below.
            row.preview:Hide()
            row.label:SetFontObject("GameFontHighlightSmall")
            row.label:SetPoint("LEFT", 8, 0)
            row.label:SetPoint("RIGHT", -6, 0)
        else
            row.preview:Show()
            row.preview:SetStatusBarTexture(entry.path)
            row.label:SetFontObject("GameFontHighlightSmall")
            row.label:SetPoint("LEFT", row.preview, "RIGHT", 8, 0)
            row.label:SetPoint("RIGHT", -6, 0)
        end

        row.selected = (entry.name == current)
        row.stripe:SetColorTexture(1, 1, 1, row.selected and 0.10 or 0)
        row:SetScript("OnClick", function()
            onPick(entry.name)
            if kind == "sound" then NCB.PlayCue(entry.name) end
            mediaPopup:Hide()
        end)
        row:Show()
    end

    for index = #entries + 1, #mediaPopup.rows do mediaPopup.rows[index]:Hide() end

    content:SetHeight(math.max(1, #entries * 24))
    mediaPopup.scroll:SetVerticalScroll(0)
    mediaPopup.scroll:UpdateBar()

    mediaPopup:ClearAllPoints()
    mediaPopup:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -2)
    mediaPopup:Show()
end

local function MediaButton(parent, kind, prefix, getter, setter)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(ROW_H)

    local btn
    btn = Button(holder, "", 100, ROW_H, function()
        ToggleMediaPicker(kind, btn, getter(), function(name)
            setter(name)
            NCB.Bars:ApplyAll()
            NCB.RefreshOptions()
        end)
    end)
    btn:SetPoint("LEFT", 0, 0)
    btn:SetPoint("RIGHT", 0, 0)

    holder.Refresh = function() btn:SetLabel(prefix .. ": " .. tostring(getter())) end
    sink[#sink + 1] = holder
    return holder
end

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------
local tabs = {}

local function SelectTab(key)
    currentKey = key
    for _, tab in ipairs(tabs) do
        local on = (tab.key == key)
        tab.underline:SetShown(on)
        tab.text:SetTextColor(unpack(on and C.gold or C.faint))
    end
    barPanel:SetShown(key ~= "general")
    generalPanel:SetShown(key == "general")
    NCB.RefreshOptions()
end

local function BuildTabs(parent)
    local strip = CreateFrame("Frame", nil, parent)
    strip:SetHeight(26)

    local entries = { { key = "general", label = "General" } }
    for _, def in ipairs(NCB.UNITS) do
        entries[#entries + 1] = { key = def.key, label = def.label }
    end

    local x = 0
    for _, entry in ipairs(entries) do
        local tab = CreateFrame("Button", nil, strip)
        tab.key = entry.key
        tab:SetHeight(24)

        tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tab.text:SetPoint("CENTER", 0, 1)
        tab.text:SetText(entry.label)

        local w = math.max(60, tab.text:GetStringWidth() + 26)
        tab:SetWidth(w)
        tab:SetPoint("LEFT", x, 0)

        tab.underline = tab:CreateTexture(nil, "OVERLAY")
        tab.underline:SetPoint("BOTTOMLEFT", 4, 0)
        tab.underline:SetPoint("BOTTOMRIGHT", -4, 0)
        tab.underline:SetHeight(2)
        tab.underline:SetColorTexture(unpack(C.accent))
        tab.underline:Hide()

        tab:SetScript("OnClick", function() SelectTab(entry.key) end)
        tab:SetScript("OnEnter", function(self)
            if self.key ~= currentKey then self.text:SetTextColor(1, 1, 1) end
        end)
        tab:SetScript("OnLeave", function(self)
            self.text:SetTextColor(unpack(self.key == currentKey and C.gold or C.faint))
        end)

        x = x + w + 2
        tabs[#tabs + 1] = tab
    end

    strip:SetWidth(x)
    return strip
end

--------------------------------------------------------------------------------
-- The per-bar panel
--------------------------------------------------------------------------------
local leftCol, rightCol

local function BuildBarPanel(content)
    sink = barWidgets
    leftCol  = NewColumn(content, 0, COL_W)
    rightCol = NewColumn(content, COL_W + COL_GAP, COL_W)

    local L, R = leftCol, rightCol

    ----------------------------------------------------------------- left column
    L:Header("Bar")
    L:Add(Check(content, "Enable this bar",
        function() return cfg().enabled end,
        function(v) cfg().enabled = v end), ROW_H)
    L:Add(MediaButton(content, "texture", "Texture",
        function() return cfg().texture end,
        function(v) cfg().texture = v end), 26)
    L:Add(Slider(content, "Width", 60, 600, 2,
        function() return cfg().width end,
        function(v) cfg().width = v end, "%d px"), 42)
    L:Add(Slider(content, "Height", 8, 64, 1,
        function() return cfg().height end,
        function(v) cfg().height = v end, "%d px"), 42)
    L:Add(Slider(content, "Scale", 0.5, 2.0, 0.05,
        function() return cfg().scale end,
        function(v) cfg().scale = v end, "%.2fx"), 42)
    L:Add(Check(content, "Draw a border",
        function() return cfg().showBorder end,
        function(v) cfg().showBorder = v end), ROW_H)
    L:Add(Check(content, "Show the spark",
        function() return cfg().showSpark end,
        function(v) cfg().showSpark = v end), ROW_H)
    L:Add(Check(content, "Show the latency tail",
        function() return cfg().showLatency end,
        function(v) cfg().showLatency = v end,
        "Marks the slice at the end of your cast that has already left your client. " ..
        "Starting the next cast inside it costs you nothing."), ROW_H, isPlayer)
    L:Add(Check(content, "Hide Blizzard's own bar",
        function() return cfg().hideBlizzard end,
        function(v)
            cfg().hideBlizzard = v
            if v then NCB.Bars:HideBlizzard() else NCB.Print("Blizzard's bar comes back after a /reload.") end
        end,
        "Switches off the stock cast bar for this unit. Turning it back on needs a /reload."), ROW_H)

    L:Header("Boss bars", isBoss)
    L:Add(Slider(content, "Gap between boss bars", 0, 40, 1,
        function() return cfg().spacing end,
        function(v) cfg().spacing = v end, "%d px"), 42, isBoss)
    L:Add(Choice(content, "Stack", NCB.GROWS,
        function() return cfg().grow end,
        function(v) cfg().grow = v end), 26, isBoss)
    L:Hint("Boss 1 is the bar you drag; the rest follow it.", isBoss)

    L:Header("Icon")
    L:Add(Check(content, "Show the spell icon",
        function() return cfg().showIcon end,
        function(v) cfg().showIcon = v end), ROW_H)
    local iconOn = function() return cfg().showIcon end
    L:Add(Choice(content, "Side", NCB.ICON_SIDES,
        function() return cfg().iconSide end,
        function(v) cfg().iconSide = v end), 26, iconOn)
    L:Add(Check(content, "Crop the icon border",
        function() return cfg().iconZoom end,
        function(v) cfg().iconZoom = v end), ROW_H, iconOn)
    L:Add(Slider(content, "Gap between icon and bar", 0, 20, 1,
        function() return cfg().iconGap end,
        function(v) cfg().iconGap = v end, "%d px"), 42, iconOn)

    L:Header("Position")
    local dragBtn = Button(content, "", 100, 22, function()
        NCB.Bars:SetLocked(not NCB.db.locked)
    end)
    dragBtn.Refresh = function()
        dragBtn:SetLabel(NCB.db.locked and "Unlock bars for dragging" or "Lock bars in place")
    end
    barWidgets[#barWidgets + 1] = dragBtn
    L:Add(dragBtn, 26)
    L:Add(Slider(content, "Horizontal position", -900, 900, 1,
        function() return cfg().x end,
        function(v) cfg().x = v end, "%d"), 42)
    L:Add(Slider(content, "Vertical position", -600, 600, 1,
        function() return cfg().y end,
        function(v) cfg().y = v end, "%d"), 42)
    L:Hint("Offsets from the screen point the bar was last dropped on, so\n" ..
           "dragging it and nudging it here always agree.")

    ---------------------------------------------------------------- right column
    R:Header("Text")
    R:Add(MediaButton(content, "font", "Font",
        function() return cfg().font end,
        function(v) cfg().font = v end), 26)
    R:Add(Choice(content, "Outline", NCB.OUTLINES,
        function() return cfg().fontOutline end,
        function(v) cfg().fontOutline = v end), 26)
    R:Add(Slider(content, "Font size", 6, 28, 1,
        function() return cfg().fontSize end,
        function(v) cfg().fontSize = v end, "%d"), 42)

    R:Add(Check(content, "Show the spell name",
        function() return cfg().showName end,
        function(v) cfg().showName = v end), ROW_H)
    local nameOn = function() return cfg().showName end
    R:Add(Choice(content, "Align", NCB.JUSTIFY,
        function() return cfg().nameJustify end,
        function(v) cfg().nameJustify = v end), 26, nameOn)
    R:Add(Slider(content, "Trim long names to", 0, 40, 1,
        function() return cfg().nameMaxChars end,
        function(v) cfg().nameMaxChars = v end, "%d chars"), 42, nameOn)
    R:Hint("0 leaves every name in full.", nameOn)

    R:Add(Check(content, "Show the cast timer",
        function() return cfg().showTime end,
        function(v) cfg().showTime = v end), ROW_H)
    local timeOn = function() return cfg().showTime end
    R:Add(Choice(content, "Timer", NCB.TIME_FORMATS,
        function() return cfg().timeFormat end,
        function(v) cfg().timeFormat = v end), 26, timeOn)
    R:Add(Slider(content, "Decimal places", 0, 2, 1,
        function() return cfg().decimals end,
        function(v) cfg().decimals = v end, "%d"), 42, timeOn)

    R:Header("Cast target")
    R:Add(Check(content, "Show who the cast is aimed at",
        function() return cfg().showTarget end,
        function(v) cfg().showTarget = v end,
        "Read once, when the cast starts - which is the moment the spell locks " ..
        "onto its target."), ROW_H)
    local targetOn = function() return cfg().showTarget end
    R:Add(Choice(content, "Place it", NCB.TARGET_POS,
        function() return cfg().targetPos end,
        function(v) cfg().targetPos = v end), 26, targetOn)
    R:Add(Check(content, "Colour it by class",
        function() return cfg().targetClassColor end,
        function(v) cfg().targetClassColor = v end), ROW_H, targetOn)
    R:Add(Check(content, "Turn it red when the cast is on you",
        function() return cfg().warnOnYou end,
        function(v) cfg().warnOnYou = v end), ROW_H, targetOn)

    R:Header("Interrupts")
    R:Add(Check(content, "Shield icon when it cannot be interrupted",
        function() return cfg().showShield end,
        function(v) cfg().showShield = v end), ROW_H)
    R:Hint("The bar also takes the 'cannot interrupt' colour below.")

    R:Add(Check(content, "Colour when your interrupt is ready",
        function() return cfg().showInterruptReady end,
        function(v) cfg().showInterruptReady = v end,
        "Only ever applies to a cast that can actually be interrupted."),
        ROW_H, isEnemyBar)
    R:Add(Swatch(content, "Interrupt ready",
        function() return cfg().colorInterruptReady end), ROW_H,
        function() return isEnemyBar() and cfg().showInterruptReady end)

    R:Add(Check(content, "Colour when your interrupt is on cooldown",
        function() return cfg().showInterruptNotReady end,
        function(v) cfg().showInterruptNotReady = v end,
        "Only ever applies to a cast that can actually be interrupted."),
        ROW_H, isEnemyBar)
    R:Add(Swatch(content, "Interrupt on cooldown",
        function() return cfg().colorInterruptNotReady end), ROW_H,
        function() return isEnemyBar() and cfg().showInterruptNotReady end)

    R:Hint("These take |cffffd479priority|r over the casting and channelling colours\n" ..
           "on this bar. A cast that cannot be interrupted keeps its own colour\n" ..
           "either way - it is never claimed to be kickable.", isEnemyBar)
    R:Hint("Which spell counts as your interrupt is set on the General tab.", isEnemyBar)

    R:Header("Colours")
    R:Add(Swatch(content, "Casting",             function() return cfg().colorCast end), ROW_H)
    R:Add(Swatch(content, "Channelling",         function() return cfg().colorChannel end), ROW_H)
    R:Add(Swatch(content, "Cannot be interrupted", function() return cfg().colorUninterruptible end), ROW_H)
    R:Add(Swatch(content, "Finished",            function() return cfg().colorSuccess end), ROW_H)
    R:Add(Swatch(content, "Interrupted / failed", function() return cfg().colorFailed end), ROW_H)
    R:Add(Swatch(content, "Background",          function() return cfg().colorBackground end, true), ROW_H)
    R:Add(Swatch(content, "Border",              function() return cfg().colorBorder end, true), ROW_H)
    R:Add(Swatch(content, "Text",                function() return cfg().colorText end), ROW_H)

    R:Header("Finishing")
    R:Add(Slider(content, "Hold before fading", 0, 2, 0.05,
        function() return cfg().holdTime end,
        function(v) cfg().holdTime = v end, "%.2fs"), 42)
    R:Add(Slider(content, "Fade out over", 0.05, 2, 0.05,
        function() return cfg().fadeTime end,
        function(v) cfg().fadeTime = v end, "%.2fs"), 42)

    sink = generalWidgets
end

--------------------------------------------------------------------------------
-- The general panel
--------------------------------------------------------------------------------
local generalCol

local function BuildGeneralPanel(content)
    sink = generalWidgets
    generalCol = NewColumn(content, 0, COL_W * 2 - 40)
    local G = generalCol

    G:Header("nugsCastBars")
    G:Hint("Cast bars for you, your target, your focus, your pet and up to five\n" ..
           "bosses. Every bar is configured on its own tab, and every bar has the\n" ..
           "same controls - nothing is available on one unit only.")

    G:Header("Profile")
    G:Hint("Saved account-wide, so a profile made on one character can be loaded on\n" ..
           "any other. Nothing auto-saves: a change you make now simply stays until\n" ..
           "you Save it into a profile or Load a different one over it.")

    -- This file's EditBox is (parent, getter, setter, placeholder) and hands back a
    -- holder Frame, not the edit box - a different contract from the same-named
    -- helper in the other addons. Calling it the other way is what left this tab
    -- half-built, since the error stopped construction partway down the column.
    local typedName = ""
    local profileBox = EditBox(content,
        function() return typedName end,
        function(v) typedName = v or "" end,
        "profile name...")
    -- Name box and picker on one row: the column is wide, and a fourth button
    -- crammed next to Save/Load/Delete read as clutter rather than a way in.
    local nameRow = CreateFrame("Frame", nil, content)
    nameRow:SetHeight(24)
    profileBox:SetParent(nameRow)
    profileBox:ClearAllPoints()
    profileBox:SetPoint("LEFT", 0, 0)
    profileBox:SetWidth(220)
    local pPick = Button(nameRow, "Pick a saved profile...", 170, 22, function(self)
        local names = NCB.ProfileNames()
        if #names == 0 then NCB.Print("no profiles saved yet.") return end
        ToggleNamePicker(window, self, names, function(chosen)
            profileBox.editBox:SetText(chosen) profileBox.editBox:SetCursorPosition(0)
        end)
    end)
    pPick:SetPoint("LEFT", profileBox, "RIGHT", 8, 0)
    G:Add(nameRow, 28)

    -- Read straight off the edit box rather than trusting `typedName`: the setter
    -- only runs on Enter or focus loss, and clicking a button does not reliably take
    -- focus away, so the buttons must see what is on screen right now.
    local function CurrentName()
        return NCB.TrimName(profileBox.editBox:GetText())
    end

    local profileRow = CreateFrame("Frame", nil, content)
    profileRow:SetHeight(22)
    local pSave = Button(profileRow, "Save", 66, 22, function()
        local name = CurrentName()
        if name == "" then NCB.Print("give the profile a name first.") return end
        local existed = NCB.db.profiles[name] ~= nil
        if NCB.SaveProfile(name) then
            NCB.Print((existed and "profile updated: " or "profile saved: ") .. name)
            NCB.RefreshOptions()
        end
    end)
    pSave:SetPoint("LEFT", 0, 0)
    local pLoad = Button(profileRow, "Load", 66, 22, function()
        local name = CurrentName()
        if NCB.LoadProfile(name) then NCB.Print("profile loaded: " .. name)
        else NCB.Print("no profile called \"" .. name .. "\".") end
    end)
    pLoad:SetPoint("LEFT", pSave, "RIGHT", 5, 0)
    local pDelete = Button(profileRow, "Delete", 70, 22, function()
        local name = CurrentName()
        if NCB.DeleteProfile(name) then
            NCB.Print("profile deleted: " .. name)
            NCB.RefreshOptions()
        else NCB.Print("no profile called \"" .. name .. "\".") end
    end)
    pDelete:SetPoint("LEFT", pLoad, "RIGHT", 5, 0)
    G:Add(profileRow, 28)

    local savedList = Label(content, "", "GameFontDisableSmall", C.faint)
    savedList.Refresh = function()
        local names = NCB.ProfileNames()
        local active, matches = NCB.ProfileStatus()

        -- "modified" is the honest state after loading a profile and then changing
        -- anything, and saying so is what stops somebody assuming their change was
        -- written back into the profile. It was not; Save does that.
        local current
        if not active then
            current = "Loaded: |cff777777none|r"
        elseif matches then
            current = "Loaded: |cff8cd2ff" .. active .. "|r"
        else
            current = "Loaded: |cff8cd2ff" .. active .. "|r |cffd8a13f(modified)|r"
        end

        savedList:SetText(current .. "\n" .. (#names > 0
            and ("Saved: |cff8cd2ff" .. table.concat(names, "|r, |cff8cd2ff") .. "|r")
            or  "No profiles saved yet."))
    end
    generalWidgets[#generalWidgets + 1] = savedList
    G:Add(savedList, 34)

    G:Header("Master switches")
    G:Add(Check(content, "Cast bars enabled",
        function() return NCB.db.enabled end,
        function(v) NCB.db.enabled = v end), ROW_H)
    G:Add(Check(content, "Show the minimap button",
        function() return not NCB.db.minimapHidden end,
        function(v)
            NCB.db.minimapHidden = not v
            NCB.SetMinimapShown(v)
        end), ROW_H)

    G:Header("Your interrupt")
    G:Hint("Colouring a cast by whether you can kick it needs to know which spell\n" ..
           "your interrupt is. That is worked out from your class and spellbook, and\n" ..
           "only needs setting here if it got it wrong - |cffffd479/ncb diag|r prints what it found.")
    G:Add(EditBox(content,
        function() return NCB.db.interruptSpells end,
        function(v)
            NCB.db.interruptSpells = v
            NCB.Interrupts:Rebuild()
        end,
        "spell ids, comma separated - leave blank for automatic"), 28)
    local foundLabel = Label(content, "", "GameFontDisableSmall", C.faint)
    foundLabel.Refresh = function()
        local spells = NCB.Interrupts.spells
        if #spells == 0 then
            foundLabel:SetText("|cffff8080Nothing detected|r - interrupt colouring is inactive.")
            return
        end
        local names = {}
        for _, id in ipairs(spells) do names[#names + 1] = NCB.Interrupts:Name(id) end
        foundLabel:SetText("Using: |cff8cd2ff" .. table.concat(names, ", ") .. "|r" ..
            (NCB.Interrupts.fromOverride and "  (your override)" or ""))
    end
    generalWidgets[#generalWidgets + 1] = foundLabel
    G:Add(foundLabel, 18)
    G:Hint("Turn the colours on per bar, on the Target, Focus and Boss tabs.")

    G:Header("When you land one")
    G:Hint("Only your own interrupts count - your pet's included, which is what a\n" ..
           "warlock's Spell Lock needs.")
    G:Add(Choice(content, "Announce", NCB.ANNOUNCE,
        function() return NCB.db.interruptAnnounce end,
        function(v)
            NCB.db.interruptAnnounce = v
            NCB.Interrupts:UpdateWatcher()
        end), 26)
    G:Add(Check(content, "Play a sound",
        function() return NCB.db.interruptSound end,
        function(v)
            NCB.db.interruptSound = v
            NCB.Interrupts:UpdateWatcher()
        end), ROW_H)
    G:Add(MediaButton(content, "sound", "Cue",
        function() return NCB.db.interruptSoundName end,
        function(v)
            NCB.db.interruptSoundName = v
            NCB.db.interruptSound = true
            NCB.Interrupts:UpdateWatcher()
        end), 26, function() return NCB.db.interruptSound end)
    -- The name goes in the third slot, which is the shape a real interrupt takes in
    -- combat: a name that can be drawn but not joined to the sentence.
    G:Add(Button(content, "Test the announcement", 200, 22, function()
        NCB.Interrupts:Announce("Chaos Bolt", nil, "Rageclaw Shaman")
    end), 26)

    local onScreen = function()
        local mode = NCB.db.interruptAnnounce
        return mode == "screen" or mode == "both"
    end

    G:Hint("The message names your ability, what it stopped, and who was casting it.\n" ..
           "In combat the client hands a unit's name over in a form that can be drawn\n" ..
           "but not joined to other text, so it appears on a second line. Chat cannot\n" ..
           "carry it at all - that one is a limit of the game, not a setting.", onScreen)
    G:Hint("Drag it with |cffffd479/ncb unlock|r, same as the bars.", onScreen)

    G:Add(MediaButton(content, "font", "Message font",
        function() return NCB.db.announceFont end,
        function(v) NCB.db.announceFont = v end), 26, onScreen)
    G:Add(Choice(content, "Outline", NCB.OUTLINES,
        function() return NCB.db.announceOutline end,
        function(v) NCB.db.announceOutline = v end), 26, onScreen)
    G:Add(Slider(content, "Message size", 8, 48, 1,
        function() return NCB.db.announceFontSize end,
        function(v) NCB.db.announceFontSize = v end, "%d"), 42, onScreen)
    G:Add(Swatch(content, "Message colour",
        function() return NCB.db.announceColor end), ROW_H, onScreen)
    G:Add(Slider(content, "Hold before fading", 0, 5, 0.1,
        function() return NCB.db.announceHold end,
        function(v) NCB.db.announceHold = v end, "%.1fs"), 42, onScreen)
    G:Add(Slider(content, "Fade out over", 0.1, 3, 0.1,
        function() return NCB.db.announceFade end,
        function(v) NCB.db.announceFade = v end, "%.1fs"), 42, onScreen)

    G:Header("Placing the bars")
    local lockBtn = Button(content, "", 200, 22, function()
        NCB.Bars:SetLocked(not NCB.db.locked)
    end)
    lockBtn.Refresh = function()
        lockBtn:SetLabel(NCB.db.locked and "Unlock bars for dragging" or "Lock bars in place")
    end
    generalWidgets[#generalWidgets + 1] = lockBtn
    G:Add(lockBtn, 26)
    G:Hint("While unlocked every enabled bar shows a demo cast so you can see\n" ..
           "exactly what you are lining up.")
    G:Add(Button(content, "Run a demo cast on every bar", 200, 22, function()
        NCB.Bars:TestAll()
    end), 26)

    G:Header("Make every bar match")
    G:Hint("Copies texture, font, icon, timer and colours from one bar to all the\n" ..
           "others. Sizes and positions are left alone.")
    for _, def in ipairs(NCB.UNITS) do
        local key, label = def.key, def.label
        G:Add(Button(content, "Use the " .. label .. " bar's look everywhere", 260, 22, function()
            NCB.CopyLook(key)
            NCB.Print("every bar now uses the " .. label .. " bar's look.")
            NCB.RefreshOptions()
        end), 26)
    end

    G:Header("Start over")
    G:Add(Button(content, "Reset every bar to defaults", 200, 22, function()
        for _, def in ipairs(NCB.UNITS) do NCB.ResetBar(def.key) end
        NCB.Print("every bar reset to defaults.")
        NCB.RefreshOptions()
    end), 26)

    G:Header("Commands")
    G:Hint("|cffffd479/ncb|r opens this window\n" ..
           "|cffffd479/ncb unlock|r and |cffffd479/ncb lock|r place the bars\n" ..
           "|cffffd479/ncb test|r runs a demo cast\n" ..
           "|cffffd479/ncb reset <bar|all>|r starts that bar over\n" ..
           "|cffffd479/ncb on|r and |cffffd479/ncb off|r are the master switch")
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------
local barScroll, generalScroll, unlockBtn

local function BuildWindow()
    local f = CreateFrame("Frame", "nugsCastBarsOptions", UIParent)
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- See the note above about the CENTER anchor: convert it to explicit, pixel
    -- aligned coordinates the first time the window is shown, so the first drag has
    -- no conversion left to do and nothing twitches.
    f:HookScript("OnShow", function(self)
        if self.__anchored then return end
        local left, bottom = self:GetLeft(), self:GetBottom()
        if not (left and bottom) then return end   -- not laid out yet; try again next show
        self.__anchored = true
        self:ClearAllPoints()
        self:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT",
                      math.floor(left + 0.5), math.floor(bottom + 0.5))
    end)
    Backdrop(f, C.bg, 1)
    tinsert(UISpecialFrames, "nugsCastBarsOptions")   -- Escape closes it
    window = f

    HeaderBar(f, "nugsCastBars", "v" .. NCB.version)

    tabStrip = BuildTabs(f)
    tabStrip:SetPoint("TOPLEFT", 10, -36)

    -- Two stacked panels, one visible at a time. Each owns its own scroll frame so
    -- switching tabs does not carry the other tab's scroll position with it.
    barPanel = Panel(f, { 0.05, 0.05, 0.05, 0.9 })
    barPanel:SetPoint("TOPLEFT", 10, -68)
    barPanel:SetPoint("BOTTOMRIGHT", -10, 44)
    barScroll = ScrollArea(barPanel)
    barScroll:SetPoint("TOPLEFT", 10, -10)
    barScroll:SetPoint("BOTTOMRIGHT", -10, 10)
    barContent = barScroll.content
    barContent:SetWidth(CONTENT_W)

    generalPanel = Panel(f, { 0.05, 0.05, 0.05, 0.9 })
    generalPanel:SetPoint("TOPLEFT", 10, -68)
    generalPanel:SetPoint("BOTTOMRIGHT", -10, 44)
    generalScroll = ScrollArea(generalPanel)
    generalScroll:SetPoint("TOPLEFT", 10, -10)
    generalScroll:SetPoint("BOTTOMRIGHT", -10, 10)
    generalContent = generalScroll.content
    generalContent:SetWidth(CONTENT_W)

    BuildBarPanel(barContent)
    BuildGeneralPanel(generalContent)

    -- Bottom bar ---------------------------------------------------------------
    unlockBtn = Button(f, "", 128, 22, function()
        NCB.Bars:SetLocked(not NCB.db.locked)
    end)
    unlockBtn:SetPoint("BOTTOMLEFT", 10, 12)

    local testBtn = Button(f, "Demo cast", 92, 22, function()
        if currentKey == "general" then NCB.Bars:TestAll() else NCB.Bars:TestOne(currentKey) end
    end)
    testBtn:SetPoint("LEFT", unlockBtn, "RIGHT", 6, 0)

    local resetBtn = Button(f, "Reset this bar", 110, 22, function()
        if currentKey == "general" then return end
        NCB.ResetBar(currentKey)
        NCB.Print(currentKey .. " bar reset to defaults.")
        NCB.RefreshOptions()
    end)
    resetBtn:SetPoint("LEFT", testBtn, "RIGHT", 6, 0)

    local copyBtn = Button(f, "Copy this look to every bar", 176, 22, function()
        if currentKey == "general" then return end
        NCB.CopyLook(currentKey)
        NCB.Print("every bar now uses the " .. currentKey .. " bar's look.")
        NCB.RefreshOptions()
    end)
    copyBtn:SetPoint("LEFT", resetBtn, "RIGHT", 6, 0)

    local hint = Label(f, "|cff8cd2ff/ncb|r for commands", "GameFontDisableSmall", C.faint)
    hint:SetPoint("BOTTOMRIGHT", -12, 18)
    hint:SetJustifyH("RIGHT")

    f.bottomButtons = { reset = resetBtn, copy = copyBtn }

    f:SetScript("OnShow", function() NCB.RefreshOptions() end)
    f:SetScript("OnHide", function()
        if mediaPopup then mediaPopup:Hide() end
    end)

    SelectTab("player")

    -- CreateFrame hands back a *shown* frame, so without this the first /ncb would
    -- toggle the brand new window straight back off.
    f:Hide()
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------
RelayoutAll = function()
    if currentKey == "general" then
        local h = generalCol:Layout()
        generalContent:SetHeight(h + 12)
        generalScroll:UpdateBar()
    else
        local h = math.max(leftCol:Layout(), rightCol:Layout())
        barContent:SetHeight(h + 12)
        barScroll:UpdateBar()
    end
end

function NCB.RefreshOptions()
    if not window or not NCB.db then return end

    local list = (currentKey == "general") and generalWidgets or barWidgets
    for _, w in ipairs(list) do
        if w.Refresh then w.Refresh() end
    end

    if unlockBtn then
        unlockBtn:SetLabel(NCB.db.locked and "Unlock bars" or "Lock bars")
    end
    if window.bottomButtons then
        local usable = (currentKey ~= "general")
        window.bottomButtons.reset:SetAlpha(usable and 1 or 0.35)
        window.bottomButtons.copy:SetAlpha(usable and 1 or 0.35)
    end

    RelayoutAll()
end

function NCB.ToggleOptions()
    if not window then BuildWindow() end
    if window:IsShown() then
        window:Hide()
    else
        window:Show()
    end
end

--------------------------------------------------------------------------------
-- A stub in the Blizzard settings list so the addon is findable there; the real
-- controls live in our own window, which stays movable.
--------------------------------------------------------------------------------
function NCB.InitOptions()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end

    local panel = CreateFrame("Frame")
    panel.name = "nugsCastBars"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("nugsCastBars")

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    note:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    note:SetJustifyH("LEFT")
    note:SetText("Cast bars for you, your target, your focus, your pet and bosses." ..
        "\n\nAll settings live in the nugsCastBars window - open it with the button below or with |cffffd479/ncb|r.")

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetSize(220, 24)
    open:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -16)
    open:SetText("Open nugsCastBars options")
    open:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        if not window then BuildWindow() end
        window:Show()
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, "nugsCastBars")
    category.ID = "nugsCastBars"
    Settings.RegisterAddOnCategory(category)
end
