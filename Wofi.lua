-- Wofi: Spotlight/Rofi-style spell & item launcher for WoW Classic
-- /wofi to open, or use keybind
-- Uses SecureActionButtons to cast spells and use items (Enter or click)

local addonName, addon = ...

-- Saved variables defaults
local defaults = {
    keybind = nil,
    includeItems = true,
}

-- Caches
local spellCache = {}
local itemCache = {}
local spellCacheBuilt = false
local itemCacheBuilt = false

-- Main frame
local WofiFrame
local searchBox
local resultsFrame
local resultButtons = {}
local selectedIndex = 1
local currentResults = {}
local MAX_RESULTS = 8
local initializing = false

-- Config frame
local configFrame = nil

-- Entry types
local TYPE_SPELL = "spell"
local TYPE_ITEM = "item"

-- ============================================================================
-- Spell Cache
-- ============================================================================

local function BuildSpellCache()
    wipe(spellCache)

    local numTabs = GetNumSpellTabs()
    for tabIndex = 1, numTabs do
        local _, texture, offset, numSlots = GetSpellTabInfo(tabIndex)

        for i = 1, numSlots do
            local slot = offset + i
            local spellName, subSpellName = GetSpellBookItemName(slot, BOOKTYPE_SPELL)

            if spellName and not IsPassiveSpell(slot, BOOKTYPE_SPELL) then
                local spellTexture = GetSpellTexture(slot, BOOKTYPE_SPELL)
                local _, spellID = GetSpellBookItemInfo(slot, BOOKTYPE_SPELL)
                table.insert(spellCache, {
                    entryType = TYPE_SPELL,
                    name = spellName,
                    subName = subSpellName or "",
                    slot = slot,
                    spellID = spellID,
                    texture = spellTexture,
                    nameLower = spellName:lower(),
                })
            end
        end
    end

    -- Sort alphabetically
    table.sort(spellCache, function(a, b) return a.name < b.name end)
    spellCacheBuilt = true
end

-- ============================================================================
-- Item Cache
-- ============================================================================

local function IsUsableItem(bagID, slotID)
    local info = C_Container.GetContainerItemInfo(bagID, slotID)
    if not info or not info.itemID then return false end

    -- Check if item has a Use: spell effect (potions, gadgets, patterns, etc.)
    local itemSpell = GetItemSpell(info.itemID)
    if itemSpell then return true end

    -- Check if it's a Quest item (quest starters, etc.)
    local _, _, _, _, _, itemType = GetItemInfo(info.itemID)
    if itemType == "Quest" then return true end

    -- Check if item is flagged as readable/usable (some quest items)
    if info.isReadable then return true end

    return false
end

local function BuildItemCache()
    wipe(itemCache)

    -- Scan all bags (0 = backpack, 1-4 = bags)
    for bagID = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slotID = 1, numSlots do
            if IsUsableItem(bagID, slotID) then
                local info = C_Container.GetContainerItemInfo(bagID, slotID)
                if info and info.itemID then
                    local itemName, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(info.itemID)
                    if itemName then
                        -- Check if we already have this item (avoid duplicates for stacks)
                        local found = false
                        for _, cached in ipairs(itemCache) do
                            if cached.itemID == info.itemID then
                                found = true
                                break
                            end
                        end

                        if not found then
                            table.insert(itemCache, {
                                entryType = TYPE_ITEM,
                                name = itemName,
                                itemID = info.itemID,
                                bagID = bagID,
                                slotID = slotID,
                                texture = itemTexture or info.iconFileID,
                                nameLower = itemName:lower(),
                            })
                        end
                    end
                end
            end
        end
    end

    -- Sort alphabetically
    table.sort(itemCache, function(a, b) return a.name < b.name end)
    itemCacheBuilt = true
end

-- ============================================================================
-- Search
-- ============================================================================

-- Fuzzy match: checks if all query characters appear in order in target
-- Returns match score (lower = better) or nil if no match
local function FuzzyMatch(query, target)
    local queryLen = #query
    local targetLen = #target
    if queryLen == 0 then return 0 end
    if queryLen > targetLen then return nil end

    local queryIdx = 1
    local score = 0
    local lastMatchIdx = 0

    for i = 1, targetLen do
        if target:sub(i, i) == query:sub(queryIdx, queryIdx) then
            -- Penalty for gaps between matched characters
            if lastMatchIdx > 0 then
                score = score + (i - lastMatchIdx - 1)
            end
            lastMatchIdx = i
            queryIdx = queryIdx + 1
            if queryIdx > queryLen then
                return score
            end
        end
    end

    return nil -- Not all characters matched
end

local function Search(query)
    local results = {}
    if not query or query == "" then return results end

    local queryLower = query:lower()
    local exactMatches = {}
    local startMatches = {}
    local containsMatches = {}
    local fuzzyMatches = {}

    -- Search spells
    for _, entry in ipairs(spellCache) do
        if entry.nameLower == queryLower then
            table.insert(exactMatches, entry)
        elseif entry.nameLower:sub(1, #queryLower) == queryLower then
            table.insert(startMatches, entry)
        elseif entry.nameLower:find(queryLower, 1, true) then
            table.insert(containsMatches, entry)
        else
            local score = FuzzyMatch(queryLower, entry.nameLower)
            if score then
                table.insert(fuzzyMatches, { entry = entry, score = score })
            end
        end
    end

    -- Search items (if enabled)
    if WofiDB.includeItems then
        for _, entry in ipairs(itemCache) do
            if entry.nameLower == queryLower then
                table.insert(exactMatches, entry)
            elseif entry.nameLower:sub(1, #queryLower) == queryLower then
                table.insert(startMatches, entry)
            elseif entry.nameLower:find(queryLower, 1, true) then
                table.insert(containsMatches, entry)
            else
                local score = FuzzyMatch(queryLower, entry.nameLower)
                if score then
                    table.insert(fuzzyMatches, { entry = entry, score = score })
                end
            end
        end
    end

    -- Sort fuzzy matches by score (lower = better match)
    table.sort(fuzzyMatches, function(a, b) return a.score < b.score end)

    -- Priority: exact > starts with > contains > fuzzy
    for _, entry in ipairs(exactMatches) do
        if #results < MAX_RESULTS then table.insert(results, entry) end
    end
    for _, entry in ipairs(startMatches) do
        if #results < MAX_RESULTS then table.insert(results, entry) end
    end
    for _, entry in ipairs(containsMatches) do
        if #results < MAX_RESULTS then table.insert(results, entry) end
    end
    for _, match in ipairs(fuzzyMatches) do
        if #results < MAX_RESULTS then table.insert(results, match.entry) end
    end

    return results
end

-- ============================================================================
-- UI Styling (Quartz-inspired)
-- ============================================================================

-- Shared media paths
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local FLAT_TEXTURE = "Interface\\Buttons\\WHITE8x8"

-- Color palette
local COLORS = {
    bg = { 0.10, 0.10, 0.12, 0.95 },  -- Flat dark background
    border = { 0.30, 0.30, 0.35, 1 },
    borderGlow = { 0.4, 0.6, 1.0, 0.25 },
    searchIcon = { 0.85, 0.85, 0.9 },  -- Near-white icon
    selected = { 0.3, 0.5, 0.9, 0.4 },
    highlight = { 1, 1, 1, 0.08 },
}

-- Create clean flat border with subtle glow
local function ApplyGlowBorder(frame, size)
    size = size or 1

    -- Outer glow (subtle blue tint)
    local glow = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
    glow:SetPoint("TOPLEFT", -1, 1)
    glow:SetPoint("BOTTOMRIGHT", 1, -1)
    glow:SetTexture(FLAT_TEXTURE)
    glow:SetVertexColor(COLORS.borderGlow[1], COLORS.borderGlow[2], COLORS.borderGlow[3], COLORS.borderGlow[4])
    frame.glowTexture = glow

    -- Clean border edge
    local edge = frame:CreateTexture(nil, "BACKGROUND", nil, -5)
    edge:SetPoint("TOPLEFT", 0, 0)
    edge:SetPoint("BOTTOMRIGHT", 0, 0)
    edge:SetTexture(FLAT_TEXTURE)
    edge:SetVertexColor(COLORS.border[1], COLORS.border[2], COLORS.border[3], COLORS.border[4])
    frame.edgeTexture = edge

    -- Flat dark background
    local inner = frame:CreateTexture(nil, "BACKGROUND", nil, -4)
    inner:SetPoint("TOPLEFT", size, -size)
    inner:SetPoint("BOTTOMRIGHT", -size, size)
    inner:SetTexture(FLAT_TEXTURE)
    inner:SetVertexColor(COLORS.bg[1], COLORS.bg[2], COLORS.bg[3], COLORS.bg[4])
    frame.innerTexture = inner
end

-- Create sharp geometric magnifying glass icon
local function CreateSearchIcon(parent)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(18, 18)

    local iconColor = { 0.8, 0.8, 0.85 }

    -- Outer circle (filled)
    local outer = container:CreateTexture(nil, "ARTWORK", nil, 1)
    outer:SetSize(14, 14)
    outer:SetPoint("TOPLEFT", 0, 0)
    outer:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    outer:SetVertexColor(iconColor[1], iconColor[2], iconColor[3], 1)
    container.outer = outer

    -- Inner circle (punches hole to make ring)
    local inner = container:CreateTexture(nil, "ARTWORK", nil, 2)
    inner:SetSize(9, 9)
    inner:SetPoint("CENTER", outer, "CENTER", 0, 0)
    inner:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    inner:SetVertexColor(COLORS.bg[1], COLORS.bg[2], COLORS.bg[3], 1)
    container.inner = inner

    -- Handle (diagonal line)
    local handle = container:CreateTexture(nil, "ARTWORK", nil, 3)
    handle:SetSize(10, 2.5)
    handle:SetPoint("TOPLEFT", outer, "BOTTOMRIGHT", -4, 2)
    handle:SetTexture(FLAT_TEXTURE)
    handle:SetVertexColor(iconColor[1], iconColor[2], iconColor[3], 1)
    handle:SetRotation(math.rad(-45))
    container.handle = handle

    return container
end

-- Fade animation state
local fadeAnimations = {}

local function StartFadeIn(frame, duration)
    duration = duration or 0.15
    fadeAnimations[frame] = {
        elapsed = 0,
        duration = duration,
        startAlpha = 0,
        endAlpha = 1,
    }
    frame:SetAlpha(0)
    -- Don't call Show() here - OnShow triggers this, frame is already showing
end

local function UpdateFadeAnimations(self, elapsed)
    for frame, anim in pairs(fadeAnimations) do
        anim.elapsed = anim.elapsed + elapsed
        local progress = math.min(anim.elapsed / anim.duration, 1)
        -- Ease out quad for smooth deceleration
        local eased = 1 - (1 - progress) * (1 - progress)
        local alpha = anim.startAlpha + (anim.endAlpha - anim.startAlpha) * eased
        frame:SetAlpha(alpha)

        if progress >= 1 then
            fadeAnimations[frame] = nil
            frame:SetAlpha(anim.endAlpha)
        end
    end
end

-- Animation frame (created once)
local animationFrame = CreateFrame("Frame")
animationFrame:SetScript("OnUpdate", UpdateFadeAnimations)

-- ============================================================================
-- UI Creation
-- ============================================================================

local function CreateResultButton(parent, index)
    -- Use SecureActionButtonTemplate for spell/item casting
    local btn = CreateFrame("Button", "WofiResult"..index, parent, "SecureActionButtonTemplate")
    btn:SetHeight(28)
    btn:SetPoint("LEFT", 4, 0)
    btn:SetPoint("RIGHT", -4, 0)
    -- Left-click DOWN = cast/use spell/item (action fires immediately)
    -- Right-drag = pick up spell/item for action bar placement
    btn:RegisterForClicks("LeftButtonDown")
    btn:RegisterForDrag("RightButton")

    -- Default to spell type
    btn:SetAttribute("type", "spell")
    btn:SetAttribute("spell", "")

    -- Highlight texture (subtle)
    btn.highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    btn.highlight:SetAllPoints()
    btn.highlight:SetTexture(BAR_TEXTURE)
    btn.highlight:SetVertexColor(COLORS.highlight[1], COLORS.highlight[2], COLORS.highlight[3], COLORS.highlight[4])

    -- Selected texture (Quartz-style gradient)
    btn.selected = btn:CreateTexture(nil, "BACKGROUND")
    btn.selected:SetAllPoints()
    btn.selected:SetTexture(BAR_TEXTURE)
    btn.selected:SetVertexColor(COLORS.selected[1], COLORS.selected[2], COLORS.selected[3], COLORS.selected[4])
    btn.selected:Hide()

    -- Icon
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetSize(22, 22)
    btn.icon:SetPoint("LEFT", 4, 0)
    btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Name text
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    btn.text:SetPoint("LEFT", btn.icon, "RIGHT", 8, 0)
    btn.text:SetPoint("RIGHT", -8, 0)
    btn.text:SetJustifyH("LEFT")
    btn.text:SetTextColor(1, 1, 1)

    -- Type indicator (small text)
    btn.typeText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.typeText:SetPoint("RIGHT", -6, 0)
    btn.typeText:SetTextColor(0.5, 0.5, 0.5)

    -- PostClick: hide frame after secure action executes
    btn:SetScript("PostClick", function(self)
        if WofiFrame:IsShown() then
            WofiFrame:Hide()
        end
    end)

    btn:SetScript("OnEnter", function(self)
        if self.entry then
            selectedIndex = index
            addon:UpdateSelection()
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.entry.entryType == TYPE_SPELL then
                GameTooltip:SetSpellBookItem(self.entry.slot, BOOKTYPE_SPELL)
            elseif self.entry.entryType == TYPE_ITEM then
                GameTooltip:SetItemByID(self.entry.itemID)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Left-click to use, Right-drag to action bar", 0.5, 0.8, 1)
            GameTooltip:Show()
        end
    end)

    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    btn:SetScript("OnDragStart", function(self)
        if InCombatLockdown() then return end
        if not self.entry then return end

        if self.entry.entryType == TYPE_SPELL then
            PickupSpellBookItem(self.entry.slot, BOOKTYPE_SPELL)
        elseif self.entry.entryType == TYPE_ITEM then
            -- Find current bag/slot for this item (may have moved since cache)
            for bagID = 0, 4 do
                local numSlots = C_Container.GetContainerNumSlots(bagID)
                for slotID = 1, numSlots do
                    local info = C_Container.GetContainerItemInfo(bagID, slotID)
                    if info and info.itemID == self.entry.itemID then
                        C_Container.PickupContainerItem(bagID, slotID)
                        return
                    end
                end
            end
        end
    end)

    return btn
end

local function UpdateEnterBinding()
    -- Bind Enter to click the selected result button
    if currentResults[selectedIndex] then
        local btnName = "WofiResult" .. selectedIndex
        SetOverrideBindingClick(WofiFrame, true, "ENTER", btnName)
    else
        ClearOverrideBindings(WofiFrame)
    end
end

local function CreateUI()
    -- Main frame (no backdrop template - we draw our own)
    WofiFrame = CreateFrame("Frame", "WofiFrame", UIParent)
    WofiFrame:SetSize(360, 46)
    WofiFrame:SetPoint("CENTER", 0, 200)
    WofiFrame:SetFrameStrata("DIALOG")
    WofiFrame:SetMovable(true)
    WofiFrame:EnableMouse(true)
    WofiFrame:SetClampedToScreen(true)
    WofiFrame:Hide()

    -- Apply Quartz-style border with glow
    ApplyGlowBorder(WofiFrame, 1)

    -- Search icon (bright and clean)
    local searchIcon = CreateSearchIcon(WofiFrame)
    searchIcon:SetPoint("LEFT", 14, 0)
    WofiFrame.searchIcon = searchIcon

    -- Search box
    searchBox = CreateFrame("EditBox", "WofiSearchBox", WofiFrame)
    searchBox:SetSize(300, 30)
    searchBox:SetPoint("LEFT", searchIcon, "RIGHT", 10, 0)
    searchBox:SetPoint("RIGHT", -14, 0)
    searchBox:SetFontObject(GameFontNormalLarge)
    searchBox:SetAutoFocus(false)
    searchBox:SetTextInsets(0, 0, 0, 0)

    -- Results frame (matching Quartz style)
    resultsFrame = CreateFrame("Frame", "WofiResults", WofiFrame)
    resultsFrame:SetPoint("TOPLEFT", WofiFrame, "BOTTOMLEFT", 0, -2)
    resultsFrame:SetPoint("TOPRIGHT", WofiFrame, "BOTTOMRIGHT", 0, -2)
    ApplyGlowBorder(resultsFrame, 1)
    resultsFrame:Hide()

    -- Create result buttons (SecureActionButtons)
    for i = 1, MAX_RESULTS do
        local btn = CreateResultButton(resultsFrame, i)
        if i == 1 then
            btn:SetPoint("TOP", 0, -4)
        else
            btn:SetPoint("TOP", resultButtons[i-1], "BOTTOM", 0, -2)
        end
        resultButtons[i] = btn
    end

    -- Scripts
    searchBox:SetScript("OnTextChanged", function(self)
        if initializing then return end
        local text = self:GetText()
        currentResults = Search(text)
        selectedIndex = 1
        addon:UpdateResults()
        UpdateEnterBinding()
    end)

    searchBox:SetScript("OnEscapePressed", function()
        WofiFrame:Hide()
    end)

    searchBox:SetScript("OnKeyDown", function(self, key)
        if key == "ENTER" then
            -- Let the override binding handle Enter (cast/use)
            self:SetPropagateKeyboardInput(true)
        elseif key == "DOWN" then
            self:SetPropagateKeyboardInput(false)
            selectedIndex = math.min(selectedIndex + 1, math.max(1, #currentResults))
            addon:UpdateSelection()
            UpdateEnterBinding()
        elseif key == "UP" then
            self:SetPropagateKeyboardInput(false)
            selectedIndex = math.max(selectedIndex - 1, 1)
            addon:UpdateSelection()
            UpdateEnterBinding()
        elseif key == "TAB" then
            self:SetPropagateKeyboardInput(false)
            if IsShiftKeyDown() then
                selectedIndex = math.max(selectedIndex - 1, 1)
            else
                selectedIndex = math.min(selectedIndex + 1, math.max(1, #currentResults))
            end
            addon:UpdateSelection()
            UpdateEnterBinding()
        else
            self:SetPropagateKeyboardInput(false)
        end
    end)

    WofiFrame:SetScript("OnShow", function(self)
        initializing = true
        -- Start fade-in animation
        StartFadeIn(self, 0.12)

        if not spellCacheBuilt then
            BuildSpellCache()
        end
        if WofiDB.includeItems and not itemCacheBuilt then
            BuildItemCache()
        end
        searchBox:SetText("")
        currentResults = {}
        selectedIndex = 1
        addon:UpdateResults()
        -- Delay focus to avoid capturing the keybind keypress
        C_Timer.After(0.02, function()
            if WofiFrame:IsShown() then
                searchBox:SetText("")
                searchBox:SetFocus()
                currentResults = {}
                addon:UpdateResults()
            end
            initializing = false
        end)
    end)

    WofiFrame:SetScript("OnHide", function()
        searchBox:SetText("")
        resultsFrame:Hide()
        ClearOverrideBindings(WofiFrame)
    end)

    -- Allow dragging
    WofiFrame:RegisterForDrag("LeftButton")
    WofiFrame:SetScript("OnDragStart", WofiFrame.StartMoving)
    WofiFrame:SetScript("OnDragStop", WofiFrame.StopMovingOrSizing)
end

function addon:UpdateResults()
    if #currentResults == 0 then
        resultsFrame:Hide()
        -- Clear all buttons
        for i = 1, MAX_RESULTS do
            resultButtons[i].entry = nil
            resultButtons[i]:SetAttribute("type", "spell")
            resultButtons[i]:SetAttribute("spell", "")
            resultButtons[i]:SetAttribute("item", nil)
            resultButtons[i]:Hide()
        end
        return
    end

    local height = 8
    for i = 1, MAX_RESULTS do
        local btn = resultButtons[i]
        local entry = currentResults[i]

        if entry then
            btn.entry = entry
            btn.icon:SetTexture(entry.texture)
            btn.text:SetText(entry.name)
            btn.selected:SetShown(i == selectedIndex)

            if entry.entryType == TYPE_SPELL then
                btn:SetAttribute("type", "spell")
                btn:SetAttribute("spell", entry.name)
                btn:SetAttribute("item", nil)
                -- Show spell rank if available
                if entry.subName and entry.subName ~= "" then
                    btn.typeText:SetText(entry.subName)
                else
                    btn.typeText:SetText("")
                end
            elseif entry.entryType == TYPE_ITEM then
                btn:SetAttribute("type", "item")
                btn:SetAttribute("item", entry.name)
                btn:SetAttribute("spell", nil)
                btn.typeText:SetText("[item]")
            end

            btn:Show()
            height = height + 30
        else
            btn.entry = nil
            btn:SetAttribute("type", "spell")
            btn:SetAttribute("spell", "")
            btn:SetAttribute("item", nil)
            btn:Hide()
        end
    end

    resultsFrame:SetHeight(height)
    resultsFrame:Show()
end

function addon:UpdateSelection()
    for i = 1, MAX_RESULTS do
        resultButtons[i].selected:SetShown(i == selectedIndex)
    end
end

-- ============================================================================
-- Config GUI
-- ============================================================================

local function CreateCheckbox(parent, label, y, getter, setter)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 20, y)
    cb.text:SetText(label)
    cb.text:SetFontObject(GameFontNormal)
    cb:SetChecked(getter())
    cb:SetScript("OnClick", function(self)
        setter(self:GetChecked())
    end)
    return cb
end

local function CreateConfigFrame()
    if configFrame then return end

    configFrame = CreateFrame("Frame", "WofiConfigFrame", UIParent)
    configFrame:SetSize(300, 250)
    configFrame:SetPoint("CENTER")
    configFrame:SetFrameStrata("DIALOG")
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:SetClampedToScreen(true)
    configFrame:Hide()

    -- Quartz-style border
    ApplyGlowBorder(configFrame, 1)

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, configFrame)
    titleBar:SetHeight(28)
    titleBar:SetPoint("TOPLEFT", 1, -1)
    titleBar:SetPoint("TOPRIGHT", -1, -1)

    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints()
    titleBg:SetTexture(BAR_TEXTURE)
    titleBg:SetVertexColor(0.15, 0.15, 0.18, 1)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() configFrame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() configFrame:StopMovingOrSizing() end)

    -- Title text
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", 12, 0)
    title:SetText("Wofi Options")
    title:SetTextColor(1, 1, 1)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("RIGHT", -6, 0)
    closeBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
    closeBtn:SetScript("OnClick", function() configFrame:Hide() end)

    -- Options
    local yPos = -50

    -- Include Items checkbox
    local itemsCb = CreateCheckbox(configFrame, "Include inventory items in search", yPos,
        function() return WofiDB.includeItems end,
        function(val)
            WofiDB.includeItems = val
            if val and not itemCacheBuilt then
                BuildItemCache()
            end
        end)
    yPos = yPos - 40

    -- Keybind section
    local keybindLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    keybindLabel:SetPoint("TOPLEFT", 20, yPos)
    keybindLabel:SetText("Keybind:")
    keybindLabel:SetTextColor(1, 0.82, 0)

    local keybindValue = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    keybindValue:SetPoint("LEFT", keybindLabel, "RIGHT", 8, 0)
    configFrame.keybindValue = keybindValue

    local function UpdateKeybindDisplay()
        if WofiDB.keybind then
            keybindValue:SetText(WofiDB.keybind)
            keybindValue:SetTextColor(0.5, 1, 0.5)
        else
            keybindValue:SetText("Not set")
            keybindValue:SetTextColor(0.5, 0.5, 0.5)
        end
    end
    UpdateKeybindDisplay()
    configFrame.UpdateKeybindDisplay = UpdateKeybindDisplay

    yPos = yPos - 30

    -- Set Keybind button
    local setBindBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    setBindBtn:SetSize(100, 24)
    setBindBtn:SetPoint("TOPLEFT", 20, yPos)
    setBindBtn:SetText("Set Keybind")
    setBindBtn:SetScript("OnClick", function()
        configFrame:Hide()
        addon:ShowBindListener()
    end)

    -- Clear Keybind button
    local clearBindBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    clearBindBtn:SetSize(100, 24)
    clearBindBtn:SetPoint("LEFT", setBindBtn, "RIGHT", 10, 0)
    clearBindBtn:SetText("Clear")
    clearBindBtn:SetScript("OnClick", function()
        if WofiDB.keybind then
            SetBinding(WofiDB.keybind, nil)
            SaveBindings(GetCurrentBindingSet())
            WofiDB.keybind = nil
            UpdateKeybindDisplay()
            print("|cff00ff00Wofi:|r Keybind cleared")
        end
    end)

    yPos = yPos - 40

    -- Refresh cache button
    local refreshBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    refreshBtn:SetSize(140, 24)
    refreshBtn:SetPoint("TOPLEFT", 20, yPos)
    refreshBtn:SetText("Refresh Cache")
    refreshBtn:SetScript("OnClick", function()
        addon:RefreshCache()
    end)

    yPos = yPos - 40

    -- Stats
    local statsLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsLabel:SetPoint("TOPLEFT", 20, yPos)
    statsLabel:SetTextColor(0.6, 0.6, 0.6)
    configFrame.statsLabel = statsLabel

    local function UpdateStats()
        local itemCount = WofiDB.includeItems and #itemCache or 0
        statsLabel:SetText("Cached: " .. #spellCache .. " spells, " .. itemCount .. " items")
    end
    configFrame.UpdateStats = UpdateStats

    configFrame:SetScript("OnShow", function()
        itemsCb:SetChecked(WofiDB.includeItems)
        UpdateKeybindDisplay()
        UpdateStats()
    end)

    -- ESC to close
    tinsert(UISpecialFrames, "WofiConfigFrame")
end

function addon:ShowConfig()
    CreateConfigFrame()
    configFrame:Show()
end

-- ============================================================================
-- Keybinding Support
-- ============================================================================

local bindingListener = nil
local toggleButton = nil

local function CreateToggleButton()
    if toggleButton then return end
    -- Create a button that toggles Wofi when clicked (only on key UP to avoid double-fire)
    toggleButton = CreateFrame("Button", "WofiToggleButton", UIParent, "SecureActionButtonTemplate")
    toggleButton:SetAttribute("type", "macro")
    toggleButton:SetAttribute("macrotext", "/wofi")
    toggleButton:RegisterForClicks("AnyDown")
    toggleButton:Hide()
end

local function ApplyKeybind()
    if WofiDB and WofiDB.keybind then
        CreateToggleButton()
        SetBindingClick(WofiDB.keybind, "WofiToggleButton")
    end
end

local function SetupKeybindListener()
    if bindingListener then return end

    bindingListener = CreateFrame("Frame", "WofiBindListener", UIParent)
    bindingListener:SetSize(300, 100)
    bindingListener:SetPoint("CENTER")
    bindingListener:SetFrameStrata("DIALOG")
    bindingListener:EnableKeyboard(true)
    bindingListener:Hide()

    -- Quartz-style border with accent glow
    ApplyGlowBorder(bindingListener, 1)

    local text = bindingListener:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("CENTER", 0, 10)
    text:SetText("Press a key to bind Wofi\n(ESC to cancel)")
    text:SetTextColor(1, 1, 1)

    bindingListener:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
            print("|cff00ff00Wofi:|r Keybind cancelled")
            return
        end

        -- Build the key string with modifiers
        local keyStr = ""
        if IsControlKeyDown() and key ~= "LCTRL" and key ~= "RCTRL" then
            keyStr = "CTRL-"
        end
        if IsAltKeyDown() and key ~= "LALT" and key ~= "RALT" then
            keyStr = keyStr .. "ALT-"
        end
        if IsShiftKeyDown() and key ~= "LSHIFT" and key ~= "RSHIFT" then
            keyStr = keyStr .. "SHIFT-"
        end

        -- Skip modifier-only keys
        if key == "LCTRL" or key == "RCTRL" or key == "LALT" or key == "RALT" or key == "LSHIFT" or key == "RSHIFT" then
            return
        end

        keyStr = keyStr .. key

        -- Clear old binding
        if WofiDB.keybind then
            SetBinding(WofiDB.keybind, nil)
        end

        -- Set new binding
        CreateToggleButton()
        WofiDB.keybind = keyStr
        SetBindingClick(keyStr, "WofiToggleButton")
        SaveBindings(GetCurrentBindingSet())

        self:Hide()
        print("|cff00ff00Wofi:|r Bound to |cff88ff88" .. keyStr .. "|r")

        -- Update config display if open
        if configFrame and configFrame:IsShown() then
            configFrame.UpdateKeybindDisplay()
        end
    end)
end

function addon:ShowBindListener()
    SetupKeybindListener()
    bindingListener:Show()
end

-- Global function called by keybind
function Wofi_Toggle()
    if WofiFrame and WofiFrame:IsShown() then
        WofiFrame:Hide()
    elseif WofiFrame then
        if InCombatLockdown() then
            print("|cff00ff00Wofi:|r |cffff6666Must be out of combat|r")
            return
        end
        if not spellCacheBuilt then
            BuildSpellCache()
        end
        if WofiDB.includeItems and not itemCacheBuilt then
            BuildItemCache()
        end
        WofiFrame:Show()
    end
end

-- ============================================================================
-- Toggle and Slash Commands
-- ============================================================================

function addon:Toggle()
    if WofiFrame:IsShown() then
        WofiFrame:Hide()
    else
        if InCombatLockdown() then
            print("|cff00ff00Wofi:|r |cffff6666Must be out of combat|r")
            return
        end
        if not spellCacheBuilt then
            BuildSpellCache()
        end
        if WofiDB.includeItems and not itemCacheBuilt then
            BuildItemCache()
        end
        WofiFrame:Show()
    end
end

function addon:RefreshCache()
    BuildSpellCache()
    if WofiDB.includeItems then
        BuildItemCache()
    end
    local itemCount = WofiDB.includeItems and #itemCache or 0
    print("|cff00ff00Wofi:|r Cache refreshed (" .. #spellCache .. " spells, " .. itemCount .. " items)")

    -- Update config display if open
    if configFrame and configFrame:IsShown() then
        configFrame.UpdateStats()
    end
end

-- Slash commands
SLASH_WOFI1 = "/wofi"
SlashCmdList["WOFI"] = function(msg)
    msg = msg:lower():trim()

    if msg == "config" or msg == "options" or msg == "settings" then
        addon:ShowConfig()
    elseif msg == "refresh" then
        addon:RefreshCache()
    elseif msg == "items" then
        WofiDB.includeItems = not WofiDB.includeItems
        if WofiDB.includeItems then
            BuildItemCache()
            print("|cff00ff00Wofi:|r Items enabled (" .. #itemCache .. " usable items found)")
        else
            print("|cff00ff00Wofi:|r Items disabled")
        end
    elseif msg == "bind" then
        addon:ShowBindListener()
    elseif msg == "unbind" then
        if WofiDB.keybind then
            SetBinding(WofiDB.keybind, nil)
            SaveBindings(GetCurrentBindingSet())
            print("|cff00ff00Wofi:|r Unbound from |cff88ff88" .. WofiDB.keybind .. "|r")
            WofiDB.keybind = nil
        else
            print("|cff00ff00Wofi:|r No keybind set")
        end
    elseif msg == "help" then
        print("|cff00ff00Wofi Commands:|r")
        print("  /wofi - Toggle launcher")
        print("  /wofi config - Open options")
        print("  /wofi bind - Set a keybind")
        print("  /wofi unbind - Remove keybind")
        print("  /wofi items - Toggle item search (" .. (WofiDB.includeItems and "ON" or "OFF") .. ")")
        print("  /wofi refresh - Refresh cache")
        print("  /wofi help - Show this help")
        print("")
        print("|cff00ff00Usage:|r Type to search, Up/Down to select, Enter/Left-click to use")
        print("|cff00ff00       |r Right-drag to place on action bar")
        if WofiDB.keybind then
            print("|cff00ff00Current keybind:|r " .. WofiDB.keybind)
        end
    else
        addon:Toggle()
    end
end

-- ============================================================================
-- Initialization
-- ============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        -- Initialize saved variables
        if not WofiDB then
            WofiDB = {}
        end
        for k, v in pairs(defaults) do
            if WofiDB[k] == nil then
                WofiDB[k] = v
            end
        end

        CreateUI()
        CreateToggleButton()

    elseif event == "PLAYER_LOGIN" then
        -- Build caches after login
        C_Timer.After(1, function()
            BuildSpellCache()
            if WofiDB.includeItems then
                BuildItemCache()
            end
            -- Apply saved keybind
            if WofiDB.keybind then
                ApplyKeybind()
            end
            local bindMsg = WofiDB.keybind and (" Keybind: |cff88ff88" .. WofiDB.keybind .. "|r") or ""
            print("|cff00ff00Wofi|r loaded. Type |cff88ff88/wofi|r to open." .. bindMsg)
        end)

    elseif event == "LEARNED_SPELL_IN_SKILL_LINE" or event == "SPELLS_CHANGED" then
        -- Rebuild spell cache when spells change
        if spellCacheBuilt then
            C_Timer.After(0.5, BuildSpellCache)
        end

    elseif event == "BAG_UPDATE_DELAYED" then
        -- Rebuild item cache when bags change
        if itemCacheBuilt and WofiDB.includeItems then
            C_Timer.After(0.5, BuildItemCache)
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Close Wofi when entering combat
        if WofiFrame and WofiFrame:IsShown() then
            WofiFrame:Hide()
            print("|cff00ff00Wofi:|r |cffff6666Closed - entering combat|r")
        end
    end
end)
