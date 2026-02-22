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
local tradeskillCache = {}
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
local TYPE_TRADESKILL = "tradeskill"

-- Tradeskill state (declared early for scoping)
local tradeskillWindowOpen = false
local pendingCraft = nil  -- {recipeName, qty} for auto-craft when profession opens
local autoCraftHiding = false  -- true while TradeSkillFrame should be invisible
local autoCraftPollTicker = nil

-- Standalone frame that enforces TradeSkillFrame invisibility every rendered frame
local tradeskillHider = CreateFrame("Frame")
tradeskillHider:SetScript("OnUpdate", function()
    if autoCraftHiding and TradeSkillFrame and TradeSkillFrame:IsShown() then
        TradeSkillFrame:SetAlpha(0)
    end
end)

-- Close the hidden tradeskill window after all queued crafts finish
-- Uses GetTradeskillRepeatCount() to know when the queue is empty,
-- then waits for the final cast to finish before closing
local function StartAutoCraftClose()
    if autoCraftPollTicker then
        autoCraftPollTicker:Cancel()
    end
    autoCraftPollTicker = C_Timer.NewTicker(0.2, function(ticker)
        local remaining = GetTradeskillRepeatCount and GetTradeskillRepeatCount() or 0
        local casting = UnitCastingInfo("player") or UnitChannelInfo("player")

        -- Only close when no crafts remain AND no cast in progress
        if remaining == 0 and not casting then
            C_Timer.After(0.3, function()
                autoCraftHiding = false
                if TradeSkillFrame then
                    TradeSkillFrame:SetAlpha(1)
                end
                CloseTradeSkill()
                -- Recalculate availability from actual bag contents
                -- (handles both completed crafts and canceled crafts correctly)
                RecalcTradeskillAvailability()
            end)
            ticker:Cancel()
            autoCraftPollTicker = nil
        end
    end)
end
-- Auto-scan state
local autoScanQueue = {}
local autoScanActive = false

-- Skill line name -> { spellName, skillLineID }
-- skillLineID used for C_TradeSkillUI.OpenTradeSkill (avoids CastSpellByName taint)
local CRAFTING_PROFESSIONS = {
    ["Alchemy"]        = { spell = "Alchemy",        skillLineID = 171 },
    ["Blacksmithing"]  = { spell = "Blacksmithing",  skillLineID = 164 },
    ["Cooking"]        = { spell = "Cooking",         skillLineID = 185 },
    ["Enchanting"]     = { spell = "Enchanting",      skillLineID = 333 },
    ["Engineering"]    = { spell = "Engineering",     skillLineID = 202 },
    ["First Aid"]      = { spell = "First Aid",       skillLineID = 129 },
    ["Jewelcrafting"]  = { spell = "Jewelcrafting",   skillLineID = 755 },
    ["Leatherworking"] = { spell = "Leatherworking",  skillLineID = 165 },
    ["Mining"]         = { spell = "Smelting",         skillLineID = 186 },
    ["Tailoring"]      = { spell = "Tailoring",        skillLineID = 197 },
}

local SKILL_COLORS = {
    optimal = { 1.0, 0.5, 0.25 },
    medium  = { 1.0, 1.0, 0.0 },
    easy    = { 0.25, 0.75, 0.25 },
    trivial = { 0.50, 0.50, 0.50 },
}

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

    -- Search tradeskill recipes (if any are cached)
    if #tradeskillCache > 0 then
        for _, entry in ipairs(tradeskillCache) do
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
-- Merchant Cache
-- ============================================================================

local merchantItemCache = {}

local function BuildMerchantCache()
    wipe(merchantItemCache)

    local numItems = GetMerchantNumItems()
    for i = 1, numItems do
        local name, texture, price, quantity, numAvailable, isPurchasable, isUsable, extendedCost = GetMerchantItemInfo(i)
        if name then
            table.insert(merchantItemCache, {
                index = i,
                name = name,
                nameLower = name:lower(),
                texture = texture,
                price = price,
                quantity = quantity,
                numAvailable = numAvailable,
                isUsable = isUsable,
                extendedCost = extendedCost,
            })
        end
    end
end

-- ============================================================================
-- Merchant Search
-- ============================================================================

local function FormatPrice(copper)
    if not copper or copper == 0 then return "" end

    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100

    local parts = {}
    if gold > 0 then table.insert(parts, "|cffffd700" .. gold .. "g|r") end
    if silver > 0 then table.insert(parts, "|cffc7c7cf" .. silver .. "s|r") end
    if cop > 0 then table.insert(parts, "|cffeda55f" .. cop .. "c|r") end

    return table.concat(parts, " ")
end

local function SearchMerchant(query)
    local results = {}
    if not query or query == "" then return results end

    local queryLower = query:lower()
    local exactMatches = {}
    local startMatches = {}
    local containsMatches = {}
    local fuzzyMatches = {}

    for _, entry in ipairs(merchantItemCache) do
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

    table.sort(fuzzyMatches, function(a, b) return a.score < b.score end)

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

    -- PostClick: hide frame after secure action, or show craft popup for tradeskill
    btn:SetScript("PostClick", function(self)
        if self.entry and self.entry.entryType == TYPE_TRADESKILL then
            addon:ShowTradeskillPopup(self.entry)
            return
        end
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
            elseif self.entry.entryType == TYPE_TRADESKILL then
                -- Build tooltip from cached data (SetTradeSkillItem only works with window open)
                GameTooltip:SetText(self.entry.name, 1, 1, 1)
                GameTooltip:AddLine(self.entry.professionName or "Tradeskill", 0.5, 0.5, 1)
                if self.entry.reagents and #self.entry.reagents > 0 then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Reagents:", 1, 0.82, 0)
                    for _, reagent in ipairs(self.entry.reagents) do
                        local rName = reagent.name or ("Item #" .. reagent.itemID)
                        GameTooltip:AddLine("  " .. rName .. " x" .. reagent.count, 0.8, 0.8, 0.8)
                    end
                end
                if self.entry.numAvailable > 0 then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Can craft: " .. self.entry.numAvailable, 0.5, 1, 0.5)
                end
            end
            GameTooltip:AddLine(" ")
            if self.entry.entryType == TYPE_TRADESKILL then
                GameTooltip:AddLine("Left-click to craft", 0.5, 0.8, 1)
            else
                GameTooltip:AddLine("Left-click to use, Right-drag to action bar", 0.5, 0.8, 1)
            end
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
                btn.typeText:SetTextColor(0.5, 0.5, 0.5)
            elseif entry.entryType == TYPE_ITEM then
                btn:SetAttribute("type", "item")
                btn:SetAttribute("item", entry.name)
                btn:SetAttribute("spell", nil)
                btn.typeText:SetText("[item]")
                btn.typeText:SetTextColor(0.5, 0.5, 0.5)
            elseif entry.entryType == TYPE_TRADESKILL then
                btn:SetAttribute("type", "")
                btn:SetAttribute("spell", nil)
                btn:SetAttribute("item", nil)
                local colors = SKILL_COLORS[entry.skillType] or { 1, 1, 1 }
                if entry.numAvailable > 0 then
                    btn.typeText:SetText("[craft: " .. entry.numAvailable .. "]")
                    btn.typeText:SetTextColor(colors[1], colors[2], colors[3])
                else
                    btn.typeText:SetText("[craft: 0]")
                    btn.typeText:SetTextColor(0.5, 0.5, 0.5)
                end
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
-- Merchant Search UI
-- ============================================================================

local merchantSearchFrame = nil
local merchantSearchBox = nil
local merchantResultsFrame = nil
local merchantResultButtons = {}
local merchantSelectedIndex = 1
local merchantCurrentResults = {}
local merchantQuantityPopup = nil
local merchantUpdateTimer = nil
local merchantUICreated = false

local function CreateMerchantQuantityPopup()
    if merchantQuantityPopup then return end

    merchantQuantityPopup = CreateFrame("Frame", "WofiMerchantQuantityPopup", UIParent)
    merchantQuantityPopup:SetSize(250, 130)
    merchantQuantityPopup:SetPoint("CENTER")
    merchantQuantityPopup:SetFrameStrata("FULLSCREEN_DIALOG")
    merchantQuantityPopup:EnableMouse(true)
    merchantQuantityPopup:Hide()

    ApplyGlowBorder(merchantQuantityPopup, 1)

    -- Item icon + name
    merchantQuantityPopup.icon = merchantQuantityPopup:CreateTexture(nil, "ARTWORK")
    merchantQuantityPopup.icon:SetSize(28, 28)
    merchantQuantityPopup.icon:SetPoint("TOPLEFT", 14, -14)
    merchantQuantityPopup.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    merchantQuantityPopup.nameText = merchantQuantityPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    merchantQuantityPopup.nameText:SetPoint("LEFT", merchantQuantityPopup.icon, "RIGHT", 8, 0)
    merchantQuantityPopup.nameText:SetPoint("RIGHT", -14, 0)
    merchantQuantityPopup.nameText:SetJustifyH("LEFT")
    merchantQuantityPopup.nameText:SetTextColor(1, 1, 1)

    -- Quantity label + editbox
    local qtyLabel = merchantQuantityPopup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    qtyLabel:SetPoint("TOPLEFT", merchantQuantityPopup.icon, "BOTTOMLEFT", 0, -12)
    qtyLabel:SetText("Quantity:")
    qtyLabel:SetTextColor(1, 0.82, 0)

    merchantQuantityPopup.qtyBox = CreateFrame("EditBox", "WofiMerchantQtyBox", merchantQuantityPopup, "InputBoxTemplate")
    merchantQuantityPopup.qtyBox:SetSize(60, 22)
    merchantQuantityPopup.qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 8, 0)
    merchantQuantityPopup.qtyBox:SetAutoFocus(true)
    merchantQuantityPopup.qtyBox:SetNumeric(true)
    merchantQuantityPopup.qtyBox:SetMaxLetters(4)

    -- Total price line
    merchantQuantityPopup.totalText = merchantQuantityPopup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    merchantQuantityPopup.totalText:SetPoint("LEFT", merchantQuantityPopup.qtyBox, "RIGHT", 12, 0)
    merchantQuantityPopup.totalText:SetTextColor(0.8, 0.8, 0.8)

    -- OK button
    local okBtn = CreateFrame("Button", nil, merchantQuantityPopup, "UIPanelButtonTemplate")
    okBtn:SetSize(80, 24)
    okBtn:SetPoint("BOTTOMRIGHT", merchantQuantityPopup, "BOTTOM", -4, 12)
    okBtn:SetText("Buy")
    merchantQuantityPopup.okBtn = okBtn

    -- Cancel button
    local cancelBtn = CreateFrame("Button", nil, merchantQuantityPopup, "UIPanelButtonTemplate")
    cancelBtn:SetSize(80, 24)
    cancelBtn:SetPoint("BOTTOMLEFT", merchantQuantityPopup, "BOTTOM", 4, 12)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function()
        merchantQuantityPopup:Hide()
    end)

    -- Store entry data for callbacks
    merchantQuantityPopup.entry = nil

    local function DoPurchase()
        local entry = merchantQuantityPopup.entry
        if not entry then return end

        local qtyText = merchantQuantityPopup.qtyBox:GetText()
        local qty = tonumber(qtyText)
        if not qty or qty < 1 then
            qty = 1
        end
        qty = math.floor(qty)

        -- Validate against limited stock
        if entry.numAvailable > 0 and qty > entry.numAvailable then
            qty = entry.numAvailable
        end

        -- Get the max stack size for this merchant item
        local maxStack = GetMerchantItemMaxStack(entry.index)
        if maxStack and maxStack > 0 then
            -- Batch purchases: BuyMerchantItem is capped at maxStack per call
            local remaining = qty
            while remaining > 0 do
                local batch = math.min(remaining, maxStack)
                BuyMerchantItem(entry.index, batch)
                remaining = remaining - batch
            end
        else
            -- Fallback: no stack info, buy as single call
            BuyMerchantItem(entry.index, qty)
        end

        merchantQuantityPopup:Hide()

        -- Clear the search
        if merchantSearchBox then
            merchantSearchBox:SetText("")
            merchantCurrentResults = {}
            addon:UpdateMerchantResults()
        end
    end

    okBtn:SetScript("OnClick", DoPurchase)

    merchantQuantityPopup.qtyBox:SetScript("OnEnterPressed", function()
        DoPurchase()
    end)

    merchantQuantityPopup.qtyBox:SetScript("OnEscapePressed", function()
        merchantQuantityPopup:Hide()
    end)

    -- Update total price when quantity changes
    merchantQuantityPopup.qtyBox:SetScript("OnTextChanged", function(self)
        local entry = merchantQuantityPopup.entry
        if not entry then return end
        local qty = tonumber(self:GetText()) or 1
        if qty < 1 then qty = 1 end
        local total = entry.price * qty
        merchantQuantityPopup.totalText:SetText("= " .. FormatPrice(total))
    end)

    tinsert(UISpecialFrames, "WofiMerchantQuantityPopup")
end

local function ShowMerchantQuantityPopup(entry)
    CreateMerchantQuantityPopup()

    merchantQuantityPopup.entry = entry
    merchantQuantityPopup.icon:SetTexture(entry.texture)
    merchantQuantityPopup.nameText:SetText(entry.name)
    merchantQuantityPopup.qtyBox:SetText("1")
    merchantQuantityPopup.totalText:SetText("= " .. FormatPrice(entry.price))
    merchantQuantityPopup:Show()
    merchantQuantityPopup.qtyBox:SetFocus()
end

local function UpdateMerchantSelection()
    for i = 1, MAX_RESULTS do
        if merchantResultButtons[i] then
            merchantResultButtons[i].selected:SetShown(i == merchantSelectedIndex)
        end
    end
end

function addon:UpdateMerchantResults()
    if #merchantCurrentResults == 0 then
        if merchantResultsFrame then merchantResultsFrame:Hide() end
        for i = 1, MAX_RESULTS do
            if merchantResultButtons[i] then
                merchantResultButtons[i].entry = nil
                merchantResultButtons[i]:Hide()
            end
        end
        return
    end

    local height = 8
    for i = 1, MAX_RESULTS do
        local btn = merchantResultButtons[i]
        local entry = merchantCurrentResults[i]

        if entry then
            btn.entry = entry
            btn.icon:SetTexture(entry.texture)
            btn.text:SetText(entry.name)
            btn.selected:SetShown(i == merchantSelectedIndex)

            -- Price on the right
            if entry.extendedCost then
                btn.priceText:SetText("[special]")
            else
                btn.priceText:SetText(FormatPrice(entry.price))
            end

            -- Stock indicator
            if entry.numAvailable > 0 then
                btn.stockText:SetText("(" .. entry.numAvailable .. ")")
                btn.stockText:Show()
            else
                btn.stockText:SetText("")
                btn.stockText:Hide()
            end

            btn:Show()
            height = height + 22
        else
            if btn then
                btn.entry = nil
                btn:Hide()
            end
        end
    end

    merchantResultsFrame:SetHeight(height)
    merchantResultsFrame:Show()
end

local function CreateMerchantResultButton(parent, index)
    local btn = CreateFrame("Button", "WofiMerchantResult" .. index, parent)
    btn:SetHeight(20)
    btn:SetPoint("LEFT", 4, 0)
    btn:SetPoint("RIGHT", -4, 0)

    -- Highlight texture
    btn.highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    btn.highlight:SetAllPoints()
    btn.highlight:SetTexture(BAR_TEXTURE)
    btn.highlight:SetVertexColor(COLORS.highlight[1], COLORS.highlight[2], COLORS.highlight[3], COLORS.highlight[4])

    -- Selected texture
    btn.selected = btn:CreateTexture(nil, "BACKGROUND")
    btn.selected:SetAllPoints()
    btn.selected:SetTexture(BAR_TEXTURE)
    btn.selected:SetVertexColor(COLORS.selected[1], COLORS.selected[2], COLORS.selected[3], COLORS.selected[4])
    btn.selected:Hide()

    -- Icon
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetSize(16, 16)
    btn.icon:SetPoint("LEFT", 4, 0)
    btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Name text
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.text:SetPoint("LEFT", btn.icon, "RIGHT", 6, 0)
    btn.text:SetPoint("RIGHT", -70, 0)
    btn.text:SetJustifyH("LEFT")
    btn.text:SetTextColor(1, 1, 1)

    -- Price text (right-aligned)
    btn.priceText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.priceText:SetPoint("RIGHT", -6, 0)
    btn.priceText:SetJustifyH("RIGHT")

    -- Stock text (next to price)
    btn.stockText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.stockText:SetPoint("RIGHT", btn.priceText, "LEFT", -4, 0)
    btn.stockText:SetTextColor(1, 0.5, 0.5)
    btn.stockText:Hide()

    btn:SetScript("OnClick", function(self)
        if self.entry then
            ShowMerchantQuantityPopup(self.entry)
        end
    end)

    btn:SetScript("OnEnter", function(self)
        if self.entry then
            merchantSelectedIndex = index
            UpdateMerchantSelection()
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetMerchantItem(self.entry.index)
            GameTooltip:Show()
        end
    end)

    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return btn
end

local function CreateMerchantSearchUI()
    if merchantUICreated then return end
    merchantUICreated = true

    -- Search bar container
    merchantSearchFrame = CreateFrame("Frame", "WofiMerchantSearch", MerchantFrame)
    merchantSearchFrame:SetSize(220, 22)
    merchantSearchFrame:SetPoint("TOPLEFT", MerchantFrame, "TOPLEFT", 75, -32)
    merchantSearchFrame:SetFrameLevel(MerchantFrame:GetFrameLevel() + 5)

    ApplyGlowBorder(merchantSearchFrame, 1)

    -- Search icon
    local icon = CreateSearchIcon(merchantSearchFrame)
    icon:SetPoint("LEFT", 6, 0)

    -- Search EditBox
    merchantSearchBox = CreateFrame("EditBox", "WofiMerchantSearchBox", merchantSearchFrame, "InputBoxTemplate")
    merchantSearchBox:SetSize(170, 18)
    merchantSearchBox:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    merchantSearchBox:SetPoint("RIGHT", -8, 0)
    merchantSearchBox:SetFontObject(GameFontHighlightSmall)
    merchantSearchBox:SetAutoFocus(false)

    -- Results dropdown
    merchantResultsFrame = CreateFrame("Frame", "WofiMerchantResults", MerchantFrame)
    merchantResultsFrame:SetPoint("TOPLEFT", merchantSearchFrame, "BOTTOMLEFT", 0, -2)
    merchantResultsFrame:SetPoint("TOPRIGHT", merchantSearchFrame, "BOTTOMRIGHT", 0, -2)
    merchantResultsFrame:SetFrameStrata("DIALOG")
    ApplyGlowBorder(merchantResultsFrame, 1)
    merchantResultsFrame:Hide()

    -- Create result buttons
    for i = 1, MAX_RESULTS do
        local btn = CreateMerchantResultButton(merchantResultsFrame, i)
        if i == 1 then
            btn:SetPoint("TOP", 0, -4)
        else
            btn:SetPoint("TOP", merchantResultButtons[i - 1], "BOTTOM", 0, -2)
        end
        merchantResultButtons[i] = btn
    end

    -- Search box scripts
    merchantSearchBox:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local text = self:GetText()
        merchantCurrentResults = SearchMerchant(text)
        merchantSelectedIndex = 1
        addon:UpdateMerchantResults()
    end)

    merchantSearchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
        merchantCurrentResults = {}
        addon:UpdateMerchantResults()
    end)

    merchantSearchBox:SetScript("OnKeyDown", function(self, key)
        if key == "ENTER" then
            self:SetPropagateKeyboardInput(false)
            if merchantCurrentResults[merchantSelectedIndex] then
                ShowMerchantQuantityPopup(merchantCurrentResults[merchantSelectedIndex])
            end
        elseif key == "DOWN" then
            self:SetPropagateKeyboardInput(false)
            merchantSelectedIndex = math.min(merchantSelectedIndex + 1, math.max(1, #merchantCurrentResults))
            UpdateMerchantSelection()
        elseif key == "UP" then
            self:SetPropagateKeyboardInput(false)
            merchantSelectedIndex = math.max(merchantSelectedIndex - 1, 1)
            UpdateMerchantSelection()
        elseif key == "TAB" then
            self:SetPropagateKeyboardInput(false)
            if IsShiftKeyDown() then
                merchantSelectedIndex = math.max(merchantSelectedIndex - 1, 1)
            else
                merchantSelectedIndex = math.min(merchantSelectedIndex + 1, math.max(1, #merchantCurrentResults))
            end
            UpdateMerchantSelection()
        else
            self:SetPropagateKeyboardInput(false)
        end
    end)

    -- Hook MerchantFrame_Update to show/hide based on active tab
    hooksecurefunc("MerchantFrame_Update", function()
        if MerchantFrame.selectedTab == 1 then
            merchantSearchFrame:Show()
        else
            merchantSearchFrame:Hide()
            merchantResultsFrame:Hide()
        end
    end)
end

-- ============================================================================
-- Tradeskill Cache
-- ============================================================================

local tradeskillQuantityPopup = nil
local tradeskillUpdateTimer = nil

local function BuildTradeskillCache()
    local profName = GetTradeSkillLine()
    if not profName or profName == "" or profName == "UNKNOWN" then return end

    -- Remove only entries for THIS profession, keep all others
    local kept = {}
    for _, entry in ipairs(tradeskillCache) do
        if entry.professionName ~= profName then
            table.insert(kept, entry)
        end
    end
    wipe(tradeskillCache)
    for _, entry in ipairs(kept) do
        table.insert(tradeskillCache, entry)
    end

    -- Expand all categories to index every recipe
    ExpandTradeSkillSubClass(0)

    local numTradeSkills = GetNumTradeSkills()
    local seen = {}
    for i = 1, numTradeSkills do
        local skillName, skillType, numAvailable, isExpanded, altVerb = GetTradeSkillInfo(i)
        if skillName and skillType ~= "header" and not seen[skillName] then
            seen[skillName] = true
            local icon = GetTradeSkillIcon(i)

            -- Store reagent info so we can recalculate availability from bags
            local reagents = {}
            local numReagents = GetTradeSkillNumReagents(i)
            for r = 1, numReagents do
                local reagentName, reagentTexture, reagentCount, playerCount = GetTradeSkillReagentInfo(i, r)
                local reagentLink = GetTradeSkillReagentItemLink(i, r)
                local reagentItemID = reagentLink and tonumber(reagentLink:match("item:(%d+)"))
                if reagentItemID then
                    table.insert(reagents, {
                        itemID = reagentItemID,
                        name = reagentName,
                        count = reagentCount,
                    })
                end
            end

            table.insert(tradeskillCache, {
                entryType = TYPE_TRADESKILL,
                index = i,
                name = skillName,
                nameLower = skillName:lower(),
                texture = icon,
                numAvailable = numAvailable or 0,
                skillType = skillType,
                altVerb = altVerb,
                professionName = profName,
                reagents = reagents,
            })
        end
    end

    -- Persist to saved variables
    if WofiDB then
        WofiDB.tradeskillCache = tradeskillCache
    end
end

-- Recalculate numAvailable for all cached recipes based on current bag contents
-- Called on BAG_UPDATE_DELAYED so crafting counts stay accurate without opening professions
local function RecalcTradeskillAvailability()
    if #tradeskillCache == 0 then return end

    -- Count all items in bags
    local bagCounts = {}
    for bagID = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slotID = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bagID, slotID)
            if info and info.itemID then
                bagCounts[info.itemID] = (bagCounts[info.itemID] or 0) + (info.stackCount or 1)
            end
        end
    end

    -- Recalculate for each recipe that has stored reagent info
    for _, entry in ipairs(tradeskillCache) do
        if entry.reagents and #entry.reagents > 0 then
            local minCrafts = math.huge
            for _, reagent in ipairs(entry.reagents) do
                local have = bagCounts[reagent.itemID] or 0
                local canMake = math.floor(have / reagent.count)
                minCrafts = math.min(minCrafts, canMake)
            end
            entry.numAvailable = minCrafts == math.huge and 0 or minCrafts
        end
    end
end

-- ============================================================================
-- Auto-Scan Professions
-- ============================================================================

local function ScanNextProfession()
    if #autoScanQueue == 0 then
        autoScanActive = false
        autoCraftHiding = false
        if TradeSkillFrame then
            TradeSkillFrame:SetAlpha(1)
        end
        print("|cff00ff00Wofi:|r Profession scan complete (" .. #tradeskillCache .. " recipes indexed)")
        return
    end

    local profInfo = table.remove(autoScanQueue, 1)
    autoCraftHiding = true

    -- Use C_TradeSkillUI.OpenTradeSkill (Blizzard internal API, no taint)
    if C_TradeSkillUI and C_TradeSkillUI.OpenTradeSkill then
        C_TradeSkillUI.OpenTradeSkill(profInfo.skillLineID)
    else
        -- Fallback: won't work from timer due to taint, but try anyway
        CastSpellByName(profInfo.spell)
    end
end

local function StartProfessionScan()
    -- Check if the API exists before attempting scan
    if not (C_TradeSkillUI and C_TradeSkillUI.OpenTradeSkill) then
        return
    end

    -- Expand all collapsed skill headers so secondary professions are visible
    for i = GetNumSkillLines(), 1, -1 do
        local _, isHeader, isExpanded = GetSkillLineInfo(i)
        if isHeader and not isExpanded then
            ExpandSkillHeader(i)
        end
    end

    -- Discover player's crafting professions via skill lines
    autoScanQueue = {}
    for i = 1, GetNumSkillLines() do
        local name, isHeader = GetSkillLineInfo(i)
        if not isHeader and CRAFTING_PROFESSIONS[name] then
            table.insert(autoScanQueue, CRAFTING_PROFESSIONS[name])
        end
    end

    if #autoScanQueue == 0 then
        return
    end

    autoScanActive = true
    ScanNextProfession()
end

-- ============================================================================
-- Tradeskill Quantity Popup
-- ============================================================================

local function CreateTradeskillQuantityPopup()
    if tradeskillQuantityPopup then return end

    tradeskillQuantityPopup = CreateFrame("Frame", "WofiTradeskillQuantityPopup", UIParent)
    tradeskillQuantityPopup:SetSize(280, 160)
    tradeskillQuantityPopup:SetPoint("CENTER")
    tradeskillQuantityPopup:SetFrameStrata("FULLSCREEN_DIALOG")
    tradeskillQuantityPopup:EnableMouse(true)
    tradeskillQuantityPopup:Hide()

    ApplyGlowBorder(tradeskillQuantityPopup, 1)

    -- Icon + name
    tradeskillQuantityPopup.icon = tradeskillQuantityPopup:CreateTexture(nil, "ARTWORK")
    tradeskillQuantityPopup.icon:SetSize(28, 28)
    tradeskillQuantityPopup.icon:SetPoint("TOPLEFT", 14, -14)
    tradeskillQuantityPopup.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    tradeskillQuantityPopup.nameText = tradeskillQuantityPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tradeskillQuantityPopup.nameText:SetPoint("LEFT", tradeskillQuantityPopup.icon, "RIGHT", 8, 0)
    tradeskillQuantityPopup.nameText:SetPoint("RIGHT", -14, 0)
    tradeskillQuantityPopup.nameText:SetJustifyH("LEFT")
    tradeskillQuantityPopup.nameText:SetTextColor(1, 1, 1)

    -- Available count
    tradeskillQuantityPopup.availText = tradeskillQuantityPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tradeskillQuantityPopup.availText:SetPoint("TOPLEFT", tradeskillQuantityPopup.icon, "BOTTOMLEFT", 0, -6)

    -- Quantity label + editbox
    local qtyLabel = tradeskillQuantityPopup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    qtyLabel:SetPoint("TOPLEFT", tradeskillQuantityPopup.availText, "BOTTOMLEFT", 0, -10)
    qtyLabel:SetText("Quantity:")
    qtyLabel:SetTextColor(1, 0.82, 0)

    tradeskillQuantityPopup.qtyBox = CreateFrame("EditBox", "WofiTradeskillQtyBox", tradeskillQuantityPopup, "InputBoxTemplate")
    tradeskillQuantityPopup.qtyBox:SetSize(60, 22)
    tradeskillQuantityPopup.qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 8, 0)
    tradeskillQuantityPopup.qtyBox:SetAutoFocus(true)
    tradeskillQuantityPopup.qtyBox:SetNumeric(true)
    tradeskillQuantityPopup.qtyBox:SetMaxLetters(4)

    -- MAX button
    local maxBtn = CreateFrame("Button", nil, tradeskillQuantityPopup, "UIPanelButtonTemplate")
    maxBtn:SetSize(50, 22)
    maxBtn:SetPoint("LEFT", tradeskillQuantityPopup.qtyBox, "RIGHT", 6, 0)
    maxBtn:SetText("MAX")
    tradeskillQuantityPopup.maxBtn = maxBtn

    -- Reagent display
    tradeskillQuantityPopup.reagentText = tradeskillQuantityPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tradeskillQuantityPopup.reagentText:SetPoint("TOPLEFT", qtyLabel, "BOTTOMLEFT", 0, -8)
    tradeskillQuantityPopup.reagentText:SetPoint("RIGHT", -14, 0)
    tradeskillQuantityPopup.reagentText:SetJustifyH("LEFT")
    tradeskillQuantityPopup.reagentText:SetSpacing(2)

    -- Create button (SecureActionButton to cast profession spell when window is closed)
    local createBtn = CreateFrame("Button", "WofiTradeskillCreateBtn", tradeskillQuantityPopup, "SecureActionButtonTemplate")
    createBtn:SetSize(80, 24)
    createBtn:SetPoint("BOTTOMRIGHT", tradeskillQuantityPopup, "BOTTOM", -4, 12)
    createBtn:RegisterForClicks("LeftButtonDown")
    createBtn:SetNormalFontObject("GameFontNormal")
    createBtn:SetText("Create")
    createBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-Button-Up")
    createBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-Button-Down")
    createBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")
    createBtn:GetNormalTexture():SetTexCoord(0, 0.625, 0, 0.6875)
    createBtn:GetPushedTexture():SetTexCoord(0, 0.625, 0, 0.6875)
    createBtn:GetHighlightTexture():SetTexCoord(0, 0.625, 0, 0.6875)
    tradeskillQuantityPopup.createBtn = createBtn

    -- Cancel button
    local cancelBtn = CreateFrame("Button", nil, tradeskillQuantityPopup, "UIPanelButtonTemplate")
    cancelBtn:SetSize(80, 24)
    cancelBtn:SetPoint("BOTTOMLEFT", tradeskillQuantityPopup, "BOTTOM", 4, 12)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function()
        tradeskillQuantityPopup:Hide()
    end)

    tradeskillQuantityPopup.entry = nil

    -- PostClick: craft directly if window was open, or store pending craft for auto-open
    createBtn:SetScript("PostClick", function(self)
        local entry = tradeskillQuantityPopup.entry
        if not entry then return end

        local qty = tonumber(tradeskillQuantityPopup.qtyBox:GetText()) or 1
        if qty < 1 then qty = 1 end
        qty = math.floor(qty)
        if entry.numAvailable > 0 and qty > entry.numAvailable then
            qty = entry.numAvailable
        end

        -- Always start hiding the TradeSkillFrame
        autoCraftHiding = true

        if tradeskillWindowOpen then
            -- Window already open: craft directly, hide it, poll for completion
            if TradeSkillFrame then
                TradeSkillFrame:SetAlpha(0)
            end
            SelectTradeSkill(entry.index)
            DoTradeSkill(entry.index, qty)
            print("|cff00ff00Wofi:|r Crafting " .. qty .. "x " .. entry.name)
            StartAutoCraftClose()
        else
            -- Window closed: macro will open it, store pending craft for TRADE_SKILL_SHOW
            pendingCraft = { recipeName = entry.name, qty = qty }
            local craftName = entry.name
            C_Timer.After(5, function()
                if pendingCraft and pendingCraft.recipeName == craftName then
                    print("|cff00ff00Wofi:|r Craft cancelled (profession did not open)")
                    pendingCraft = nil
                    autoCraftHiding = false
                end
            end)
        end
        tradeskillQuantityPopup:Hide()
        if WofiFrame and WofiFrame:IsShown() then
            WofiFrame:Hide()
        end
    end)

    -- Enter key: propagate past editbox to reach override binding -> secure button
    tradeskillQuantityPopup.qtyBox:SetScript("OnKeyDown", function(self, key)
        if key == "ENTER" then
            self:SetPropagateKeyboardInput(true)
        elseif key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            tradeskillQuantityPopup:Hide()
        else
            self:SetPropagateKeyboardInput(false)
        end
    end)
    -- ClearFocus so editbox fully releases keyboard after Enter propagates
    tradeskillQuantityPopup.qtyBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    tradeskillQuantityPopup.qtyBox:SetScript("OnEscapePressed", function()
        tradeskillQuantityPopup:Hide()
    end)

    maxBtn:SetScript("OnClick", function()
        local entry = tradeskillQuantityPopup.entry
        if entry and entry.numAvailable > 0 then
            tradeskillQuantityPopup.qtyBox:SetText(tostring(entry.numAvailable))
        end
    end)

    -- Clear override bindings when popup hides
    tradeskillQuantityPopup:SetScript("OnHide", function()
        ClearOverrideBindings(tradeskillQuantityPopup)
    end)

    tinsert(UISpecialFrames, "WofiTradeskillQuantityPopup")
end

-- Addon method so PostClick (defined earlier) can reference it at runtime
function addon:ShowTradeskillPopup(entry)
    CreateTradeskillQuantityPopup()

    tradeskillQuantityPopup.entry = entry
    tradeskillQuantityPopup.icon:SetTexture(entry.texture)
    tradeskillQuantityPopup.nameText:SetText(entry.name)
    tradeskillQuantityPopup.qtyBox:SetText("1")

    -- Use alt verb if available (e.g., "Disenchant", "Prospect")
    if entry.altVerb then
        tradeskillQuantityPopup.createBtn:SetText(entry.altVerb)
    else
        tradeskillQuantityPopup.createBtn:SetText("Create")
    end

    -- Build reagent list and calculate live availability from bags
    local reagentLines = {}
    local liveAvailable = 0
    if entry.reagents and #entry.reagents > 0 then
        -- Count current bag contents
        local bagCounts = {}
        for bagID = 0, 4 do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            for slotID = 1, numSlots do
                local info = C_Container.GetContainerItemInfo(bagID, slotID)
                if info and info.itemID then
                    bagCounts[info.itemID] = (bagCounts[info.itemID] or 0) + (info.stackCount or 1)
                end
            end
        end

        -- Calculate availability and build display
        local minCrafts = math.huge
        for _, reagent in ipairs(entry.reagents) do
            local playerCount = bagCounts[reagent.itemID] or 0
            local color = playerCount >= reagent.count and "|cff00ff00" or "|cffff3333"
            local name = reagent.name or ("Item #" .. reagent.itemID)
            table.insert(reagentLines, color .. name .. "|r  " .. playerCount .. "/" .. reagent.count)
            minCrafts = math.min(minCrafts, math.floor(playerCount / reagent.count))
        end
        liveAvailable = minCrafts == math.huge and 0 or minCrafts
        -- Update the cached value too
        entry.numAvailable = liveAvailable
    end

    if liveAvailable > 0 then
        tradeskillQuantityPopup.availText:SetText("Can create: " .. liveAvailable)
        tradeskillQuantityPopup.availText:SetTextColor(0.5, 1, 0.5)
    else
        tradeskillQuantityPopup.availText:SetText("Missing reagents")
        tradeskillQuantityPopup.availText:SetTextColor(1, 0.3, 0.3)
    end
    tradeskillQuantityPopup.reagentText:SetText(table.concat(reagentLines, "\n"))

    -- Adjust height based on reagent count
    local baseHeight = 140
    local reagentHeight = #reagentLines * 14
    tradeskillQuantityPopup:SetHeight(baseHeight + reagentHeight)

    -- Hide main launcher
    if WofiFrame and WofiFrame:IsShown() then
        WofiFrame:Hide()
    end

    -- Pre-configure the secure create button attributes
    if not InCombatLockdown() then
        if tradeskillWindowOpen then
            tradeskillQuantityPopup.createBtn:SetAttribute("type", "")
        else
            -- Use macro type for reliable profession spell casting
            tradeskillQuantityPopup.createBtn:SetAttribute("type", "macro")
            tradeskillQuantityPopup.createBtn:SetAttribute("macrotext", "/cast " .. entry.professionName)
        end
    end

    tradeskillQuantityPopup:Show()
    tradeskillQuantityPopup.qtyBox:SetFocus()

    -- Bind Enter to click the secure create button (override binding = hardware event)
    SetOverrideBindingClick(tradeskillQuantityPopup, true, "ENTER", "WofiTradeskillCreateBtn", "LeftButton")
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
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_UPDATE")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("TRADE_SKILL_UPDATE")
eventFrame:RegisterEvent("TRADE_SKILL_CLOSE")

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

        -- Restore tradeskill cache from saved variables
        if WofiDB.tradeskillCache and #WofiDB.tradeskillCache > 0 then
            -- Remove old-format entries that lack professionName
            local clean = {}
            local loadSeen = {}
            for _, entry in ipairs(WofiDB.tradeskillCache) do
                if entry.professionName and entry.professionName ~= "UNKNOWN" then
                    local key = entry.professionName .. ":" .. entry.name
                    if not loadSeen[key] then
                        loadSeen[key] = true
                        table.insert(clean, entry)
                    end
                end
            end
            wipe(WofiDB.tradeskillCache)
            for _, entry in ipairs(clean) do
                table.insert(WofiDB.tradeskillCache, entry)
            end
            tradeskillCache = WofiDB.tradeskillCache
        end

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
            local tradeMsg = #tradeskillCache > 0 and (", " .. #tradeskillCache .. " recipes cached") or ""
            print("|cff00ff00Wofi|r loaded. Type |cff88ff88/wofi|r to open." .. bindMsg .. tradeMsg)

            -- Recalculate tradeskill availability from current bag contents
            if #tradeskillCache > 0 then
                C_Timer.After(2, RecalcTradeskillAvailability)
            end

            -- Auto-scan all professions to refresh recipe data
            C_Timer.After(3, StartProfessionScan)
        end)

    elseif event == "LEARNED_SPELL_IN_SKILL_LINE" or event == "SPELLS_CHANGED" then
        -- Rebuild spell cache when spells change
        if spellCacheBuilt then
            C_Timer.After(0.5, BuildSpellCache)
        end

    elseif event == "BAG_UPDATE_DELAYED" then
        -- Debounce: cancel previous timers to avoid stacking scans
        if addon.bagUpdateTimer then
            addon.bagUpdateTimer:Cancel()
        end
        addon.bagUpdateTimer = C_Timer.NewTimer(0.5, function()
            addon.bagUpdateTimer = nil
            if itemCacheBuilt and WofiDB.includeItems then
                BuildItemCache()
            end
            if #tradeskillCache > 0 then
                RecalcTradeskillAvailability()
            end
        end)

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Close Wofi when entering combat
        if WofiFrame and WofiFrame:IsShown() then
            WofiFrame:Hide()
            print("|cff00ff00Wofi:|r |cffff6666Closed - entering combat|r")
        end
        -- Close merchant quantity popup
        if merchantQuantityPopup and merchantQuantityPopup:IsShown() then
            merchantQuantityPopup:Hide()
        end
        -- Close tradeskill quantity popup
        if tradeskillQuantityPopup and tradeskillQuantityPopup:IsShown() then
            tradeskillQuantityPopup:Hide()
        end

    elseif event == "MERCHANT_SHOW" then
        CreateMerchantSearchUI()
        BuildMerchantCache()
        if merchantSearchBox then
            merchantSearchBox:SetText("")
        end
        merchantCurrentResults = {}
        merchantSelectedIndex = 1
        if merchantSearchFrame then
            merchantSearchFrame:Show()
        end
        addon:UpdateMerchantResults()

    elseif event == "MERCHANT_UPDATE" then
        -- Debounce rebuilds
        if merchantUpdateTimer then
            merchantUpdateTimer:Cancel()
        end
        merchantUpdateTimer = C_Timer.NewTimer(0.1, function()
            BuildMerchantCache()
            -- Refresh results if searching
            if merchantSearchBox and merchantSearchBox:GetText() ~= "" then
                merchantCurrentResults = SearchMerchant(merchantSearchBox:GetText())
                addon:UpdateMerchantResults()
            end
            merchantUpdateTimer = nil
        end)

    elseif event == "MERCHANT_CLOSED" then
        if merchantQuantityPopup and merchantQuantityPopup:IsShown() then
            merchantQuantityPopup:Hide()
        end
        if merchantResultsFrame then
            merchantResultsFrame:Hide()
        end

    elseif event == "TRADE_SKILL_SHOW" then
        if not IsTradeSkillLinked() then
            tradeskillWindowOpen = true
            BuildTradeskillCache()

            -- Auto-scan: silently index this profession, then move to next
            if autoScanActive then
                if TradeSkillFrame then
                    TradeSkillFrame:SetAlpha(0)
                end
                C_Timer.After(0.1, function()
                    CloseTradeSkill()
                    C_Timer.After(0.3, ScanNextProfession)
                end)
                return
            end

            -- Handle pending craft (auto-opened from Wofi launcher)
            if pendingCraft then
                local craft = pendingCraft
                pendingCraft = nil

                -- autoCraftHiding already set in PostClick, enforce alpha now
                if TradeSkillFrame then
                    TradeSkillFrame:SetAlpha(0)
                end

                -- Find recipe by name (index may differ from cached value)
                local foundIndex = nil
                for _, entry in ipairs(tradeskillCache) do
                    if entry.name == craft.recipeName then
                        foundIndex = entry.index
                        break
                    end
                end

                if foundIndex then
                    SelectTradeSkill(foundIndex)
                    DoTradeSkill(foundIndex, craft.qty)
                    print("|cff00ff00Wofi:|r Crafting " .. craft.qty .. "x " .. craft.recipeName)
                else
                    print("|cff00ff00Wofi:|r Could not find recipe: " .. craft.recipeName)
                end

                StartAutoCraftClose()
            end
        end

    elseif event == "TRADE_SKILL_UPDATE" then
        if not IsTradeSkillLinked() and tradeskillWindowOpen then
            if tradeskillUpdateTimer then
                tradeskillUpdateTimer:Cancel()
            end
            tradeskillUpdateTimer = C_Timer.NewTimer(0.1, function()
                BuildTradeskillCache()
                tradeskillUpdateTimer = nil
            end)
        end

    elseif event == "TRADE_SKILL_CLOSE" then
        -- Cancel any pending debounced rebuild to prevent stale/duplicate entries
        if tradeskillUpdateTimer then
            tradeskillUpdateTimer:Cancel()
            tradeskillUpdateTimer = nil
        end
        tradeskillWindowOpen = false
        autoCraftHiding = false
        if TradeSkillFrame then
            TradeSkillFrame:SetAlpha(1)
        end
        if tradeskillQuantityPopup and tradeskillQuantityPopup:IsShown() then
            tradeskillQuantityPopup:Hide()
        end
    end
end)
