-- Wofi: Spotlight/Rofi-style spell & item launcher for WoW Classic
-- /wofi to open, or use keybind, or click minimap icon
-- Uses SecureActionButtons to cast spells and use items (Enter or click)

local addonName, addon = ...

-- Saved variables defaults
local defaults = {
    minimapPos = 220,
    showMinimap = true,
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
                table.insert(spellCache, {
                    entryType = TYPE_SPELL,
                    name = spellName,
                    subName = subSpellName or "",
                    slot = slot,
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

local function Search(query)
    local results = {}
    if not query or query == "" then return results end

    local queryLower = query:lower()
    local exactMatches = {}
    local startMatches = {}
    local containsMatches = {}

    -- Search spells
    for _, entry in ipairs(spellCache) do
        if entry.nameLower == queryLower then
            table.insert(exactMatches, entry)
        elseif entry.nameLower:sub(1, #queryLower) == queryLower then
            table.insert(startMatches, entry)
        elseif entry.nameLower:find(queryLower, 1, true) then
            table.insert(containsMatches, entry)
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
            end
        end
    end

    -- Priority: exact > starts with > contains
    for _, entry in ipairs(exactMatches) do
        if #results < MAX_RESULTS then table.insert(results, entry) end
    end
    for _, entry in ipairs(startMatches) do
        if #results < MAX_RESULTS then table.insert(results, entry) end
    end
    for _, entry in ipairs(containsMatches) do
        if #results < MAX_RESULTS then table.insert(results, entry) end
    end

    return results
end

-- ============================================================================
-- UI Creation
-- ============================================================================

local function CreateResultButton(parent, index)
    -- Use SecureActionButtonTemplate for spell/item usage
    local btn = CreateFrame("Button", "WofiResult"..index, parent, "SecureActionButtonTemplate")
    btn:SetHeight(28)
    btn:SetPoint("LEFT", 4, 0)
    btn:SetPoint("RIGHT", -4, 0)
    btn:RegisterForClicks("AnyUp", "AnyDown")

    -- Default to spell type
    btn:SetAttribute("type", "spell")
    btn:SetAttribute("spell", "")

    -- Highlight texture
    btn.highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    btn.highlight:SetAllPoints()
    btn.highlight:SetColorTexture(1, 1, 1, 0.1)

    -- Selected texture
    btn.selected = btn:CreateTexture(nil, "BACKGROUND")
    btn.selected:SetAllPoints()
    btn.selected:SetColorTexture(0.3, 0.6, 1, 0.3)
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

    -- Post-click: hide frame after use
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
            GameTooltip:Show()
        end
    end)

    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
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
    -- Main frame
    WofiFrame = CreateFrame("Frame", "WofiFrame", UIParent, "BackdropTemplate")
    WofiFrame:SetSize(350, 50)
    WofiFrame:SetPoint("CENTER", 0, 200)
    WofiFrame:SetFrameStrata("DIALOG")
    WofiFrame:SetMovable(true)
    WofiFrame:EnableMouse(true)
    WofiFrame:SetClampedToScreen(true)
    WofiFrame:Hide()

    WofiFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    WofiFrame:SetBackdropColor(0.1, 0.1, 0.12, 0.95)
    WofiFrame:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)

    -- Search icon
    local searchIcon = WofiFrame:CreateTexture(nil, "ARTWORK")
    searchIcon:SetSize(20, 20)
    searchIcon:SetPoint("LEFT", 12, 0)
    searchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    searchIcon:SetVertexColor(0.6, 0.6, 0.6)

    -- Search box
    searchBox = CreateFrame("EditBox", "WofiSearchBox", WofiFrame)
    searchBox:SetSize(300, 30)
    searchBox:SetPoint("LEFT", searchIcon, "RIGHT", 8, 0)
    searchBox:SetPoint("RIGHT", -12, 0)
    searchBox:SetFontObject(GameFontNormalLarge)
    searchBox:SetAutoFocus(true)
    searchBox:SetTextInsets(0, 0, 0, 0)

    -- Results frame
    resultsFrame = CreateFrame("Frame", "WofiResults", WofiFrame, "BackdropTemplate")
    resultsFrame:SetPoint("TOPLEFT", WofiFrame, "BOTTOMLEFT", 0, -2)
    resultsFrame:SetPoint("TOPRIGHT", WofiFrame, "BOTTOMRIGHT", 0, -2)
    resultsFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    resultsFrame:SetBackdropColor(0.1, 0.1, 0.12, 0.95)
    resultsFrame:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
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

    WofiFrame:SetScript("OnShow", function()
        if not spellCacheBuilt then
            BuildSpellCache()
        end
        if WofiDB.includeItems and not itemCacheBuilt then
            BuildItemCache()
        end
        searchBox:SetText("")
        searchBox:SetFocus()
        currentResults = {}
        selectedIndex = 1
        addon:UpdateResults()
        -- Clear any character that got typed from the keybind key
        C_Timer.After(0.01, function()
            if WofiFrame:IsShown() and searchBox:GetText() ~= "" then
                searchBox:SetText("")
                currentResults = {}
                addon:UpdateResults()
            end
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
                btn.typeText:SetText("")
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

    configFrame = CreateFrame("Frame", "WofiConfigFrame", UIParent, "BackdropTemplate")
    configFrame:SetSize(300, 280)
    configFrame:SetPoint("CENTER")
    configFrame:SetFrameStrata("DIALOG")
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:SetClampedToScreen(true)
    configFrame:Hide()

    configFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    configFrame:SetBackdropColor(0.1, 0.1, 0.12, 0.98)
    configFrame:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, configFrame, "BackdropTemplate")
    titleBar:SetHeight(28)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    titleBar:SetBackdropColor(0.2, 0.2, 0.25, 1)
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
    yPos = yPos - 30

    -- Show Minimap checkbox
    local minimapCb = CreateCheckbox(configFrame, "Show minimap button", yPos,
        function() return WofiDB.showMinimap end,
        function(val)
            WofiDB.showMinimap = val
            if val then
                _G["WofiMinimapButton"]:Show()
            else
                _G["WofiMinimapButton"]:Hide()
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
        minimapCb:SetChecked(WofiDB.showMinimap)
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
-- Minimap Button
-- ============================================================================

local minimapButton

local function CreateMinimapButton()
    minimapButton = CreateFrame("Button", "WofiMinimapButton", Minimap)
    minimapButton:SetSize(32, 32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetPoint("CENTER", 0, 0)
    minimapButton.icon = icon

    local function UpdatePosition()
        local angle = math.rad(WofiDB.minimapPos)
        local x = math.cos(angle) * 80
        local y = math.sin(angle) * 80
        minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    minimapButton:SetScript("OnDragStart", function(self)
        self.dragging = true
    end)

    minimapButton:SetScript("OnDragStop", function(self)
        self.dragging = false
    end)

    minimapButton:SetScript("OnUpdate", function(self)
        if self.dragging then
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            WofiDB.minimapPos = math.deg(math.atan2(py - my, px - mx))
            UpdatePosition()
        end
    end)

    minimapButton:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            addon:Toggle()
        elseif button == "RightButton" then
            addon:ShowConfig()
        end
    end)

    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Wofi", 1, 1, 1)
        GameTooltip:AddLine("Left-click: Open launcher", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Right-click: Options", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag: Move button", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)

    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    UpdatePosition()

    if not WofiDB.showMinimap then
        minimapButton:Hide()
    end
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
    toggleButton:RegisterForClicks("AnyUp")
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

    bindingListener = CreateFrame("Frame", "WofiBindListener", UIParent, "BackdropTemplate")
    bindingListener:SetSize(300, 100)
    bindingListener:SetPoint("CENTER")
    bindingListener:SetFrameStrata("DIALOG")
    bindingListener:EnableKeyboard(true)
    bindingListener:Hide()

    bindingListener:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    bindingListener:SetBackdropColor(0.1, 0.1, 0.15, 0.95)
    bindingListener:SetBackdropBorderColor(0.4, 0.6, 1, 1)

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
    elseif msg == "minimap" then
        WofiDB.showMinimap = not WofiDB.showMinimap
        if WofiDB.showMinimap then
            minimapButton:Show()
            print("|cff00ff00Wofi:|r Minimap button shown")
        else
            minimapButton:Hide()
            print("|cff00ff00Wofi:|r Minimap button hidden")
        end
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
        print("  /wofi minimap - Toggle minimap button")
        print("  /wofi help - Show this help")
        print("")
        print("|cff00ff00Usage:|r Type to search, Up/Down to select, Enter or Click to use")
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
eventFrame:RegisterEvent("LEARNED_SPELL_IN_TAB")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")

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
        CreateMinimapButton()
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
            print("|cff00ff00Wofi|r loaded. Type |cff88ff88/wofi|r or click minimap icon." .. bindMsg)
        end)

    elseif event == "LEARNED_SPELL_IN_TAB" or event == "SPELLS_CHANGED" then
        -- Rebuild spell cache when spells change
        if spellCacheBuilt then
            C_Timer.After(0.5, BuildSpellCache)
        end

    elseif event == "BAG_UPDATE_DELAYED" then
        -- Rebuild item cache when bags change
        if itemCacheBuilt and WofiDB.includeItems then
            C_Timer.After(0.5, BuildItemCache)
        end
    end
end)
