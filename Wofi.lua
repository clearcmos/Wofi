-- Wofi: Spotlight/Rofi-style spell & item launcher for WoW Classic
-- /wofi to open, or use keybind
-- Uses SecureActionButtons to cast spells and use items (Enter or click)

local addonName, addon = ...

-- Saved variables defaults
local defaults = {
    keybind = nil,
    includeItems = true,
    includeMacros = true,
    includeTradeskills = true,
    allSpellRanks = false,
    maxResults = 8,
    showCraftAlert = true,
    showMerchantSearch = true,
    includePlayers = true,
    includeZones = true,
    includeLockouts = true,
    includeQuests = true,
    welcomeShown = false,
}

-- Caches
local spellCache = {}
local itemCache = {}
local macroCache = {}
local tradeskillCache = {}
local playerCache = {}
local zoneCache = {}
local lockoutCache = {}
local questCache = {}
local spellCacheBuilt = false
local itemCacheBuilt = false
local macroCacheBuilt = false
local playerCacheBuilt = false
local zoneCacheBuilt = false
local questCacheBuilt = false
local recentPlayers = {}
local recentPlayerCount = 0
local coGuildPlayers = {}  -- session-only, populated by GreenWall message handler or comember_cache seed
local MAX_RECENT_PLAYERS = 50
local playerCacheRebuildTimer = nil

-- Localized API functions (avoid table lookups in hot paths)
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerNumSlots = GetContainerNumSlots
local GetTradeskillRepeatCount = _G.GetTradeskillRepeatCount

-- Main frame
local WofiFrame
local searchBox
local resultsFrame
local resultButtons = {}
local selectedIndex = 1
local currentResults = {}
local MAX_RESULTS = 12
local initializing = false
local welcomeFrame = nil

-- Settings category ID for native options panel
local settingsCategoryID = nil

-- Entry types
local TYPE_SPELL    = "spell"
local TYPE_ITEM     = "item"
local TYPE_MACRO    = "macro"
local TYPE_TRADESKILL = "tradeskill"
local TYPE_PLAYER   = "player"
local TYPE_MAP      = "map"
local TYPE_LOCKOUT  = "lockout"
local TYPE_QUEST    = "quest"

-- Questie optional integration
local function IsQuestieAvailable()
    return QuestieLoader ~= nil
end

-- Player source priority and display info
local PLAYER_SOURCE_RECENT  = 1
local PLAYER_SOURCE_COGUILD = 2
local PLAYER_SOURCE_GUILD   = 3
local PLAYER_SOURCE_BNET    = 4
local PLAYER_SOURCE_FRIEND  = 5
local PLAYER_SOURCE_INFO = {
    [1] = { tag = "[recent]",  color = {0.8, 0.8, 0.5} },
    [2] = { tag = "[coguild]", color = {0.4, 0.85, 0.4} },
    [3] = { tag = "[guild]",   color = {0.25, 1.0, 0.25} },
    [4] = { tag = "[bnet]",    color = {0.0, 0.8, 1.0} },
    [5] = { tag = "[friend]",  color = {0.0, 1.0, 0.5} },
}

-- Tradeskill state (declared early for scoping)
local tradeskillWindowOpen = false
local pendingCraft = nil  -- {recipeName, qty} for auto-craft when profession opens
local autoCraftHiding = false  -- true while TradeSkillFrame should be invisible
local autoCraftPollTicker = nil
local RecalcTradeskillAvailability  -- forward declaration (defined later in file)

-- Standalone frame that enforces TradeSkillFrame invisibility every rendered frame
local tradeskillHider = CreateFrame("Frame")
tradeskillHider:SetScript("OnUpdate", function()
    if autoCraftHiding and TradeSkillFrame and TradeSkillFrame:IsShown() then
        TradeSkillFrame:SetAlpha(0)
    end
end)

-- Craft progress alert (RepSync-style center-screen fade)
local craftAlertFrame = CreateFrame("Frame", "WofiCraftAlertFrame", UIParent)
craftAlertFrame:SetSize(512, 40)
craftAlertFrame:SetPoint("TOP", UIParent, "TOP", 0, -220)
craftAlertFrame:SetFrameStrata("HIGH")
craftAlertFrame:Hide()

local craftAlertText = craftAlertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
craftAlertText:SetPoint("CENTER")
craftAlertText:SetFont(craftAlertText:GetFont(), 26, "THICKOUTLINE")
craftAlertText:SetTextColor(0.5, 1.0, 0.5)

local craftAlertCrafting = false  -- true while actively crafting (hold alpha=1)
local craftAlertStartTime = 0
local CRAFT_ALERT_FADE_IN  = 0.5
local CRAFT_ALERT_HOLD     = 1.5
local CRAFT_ALERT_FADE_OUT = 2.0

craftAlertFrame:SetScript("OnUpdate", function(self)
    if craftAlertCrafting then
        -- During crafting: fade in then hold at full alpha
        local elapsed = GetTime() - craftAlertStartTime
        if elapsed < CRAFT_ALERT_FADE_IN then
            self:SetAlpha(elapsed / CRAFT_ALERT_FADE_IN)
        else
            self:SetAlpha(1.0)
        end
    else
        -- After crafting: fade in, hold, fade out
        local elapsed = GetTime() - craftAlertStartTime
        if elapsed < CRAFT_ALERT_FADE_IN then
            self:SetAlpha(elapsed / CRAFT_ALERT_FADE_IN)
        elseif elapsed < CRAFT_ALERT_FADE_IN + CRAFT_ALERT_HOLD then
            self:SetAlpha(1.0)
        elseif elapsed < CRAFT_ALERT_FADE_IN + CRAFT_ALERT_HOLD + CRAFT_ALERT_FADE_OUT then
            local fadeElapsed = elapsed - CRAFT_ALERT_FADE_IN - CRAFT_ALERT_HOLD
            self:SetAlpha(1.0 - fadeElapsed / CRAFT_ALERT_FADE_OUT)
        else
            self:Hide()
        end
    end
end)

local function UpdateCraftAlert(remaining, recipeName)
    if not WofiDB.showCraftAlert then return end
    craftAlertText:SetText(recipeName .. ": " .. remaining .. " remaining")
    craftAlertCrafting = true
    if not craftAlertFrame:IsShown() then
        craftAlertStartTime = GetTime()
        craftAlertFrame:SetAlpha(0)
        craftAlertFrame:Show()
    end
end

local function CompleteCraftAlert(recipeName)
    if not WofiDB.showCraftAlert then return end
    craftAlertText:SetText(recipeName .. " complete!")
    craftAlertCrafting = false
    craftAlertStartTime = GetTime()
    craftAlertFrame:SetAlpha(0)
    craftAlertFrame:Show()
end

local function DismissCraftAlert()
    -- Silently fade out whatever is currently showing (skip to fade-out phase)
    craftAlertCrafting = false
    craftAlertStartTime = GetTime() - CRAFT_ALERT_FADE_IN - CRAFT_ALERT_HOLD
end

-- Close the hidden tradeskill window after all queued crafts finish
-- Uses GetTradeskillRepeatCount() to know when the queue is empty,
-- then waits for the final cast to finish before closing.
-- Cancel detection: moving interrupts the cast but GetTradeskillRepeatCount()
-- may stay non-zero, so we also detect "not casting for 1s" as cancelled.
local function StartAutoCraftClose(recipeName, qty)
    if autoCraftPollTicker then
        autoCraftPollTicker:Cancel()
    end
    local showAlert = qty and qty > 1
    local lastDisplayed = qty or 0
    local notCastingSince = nil  -- when we first saw no active cast
    local sawRemainingZero = false  -- true if remaining hit 0 (queue fully consumed)
    if showAlert then
        UpdateCraftAlert(qty, recipeName)
    end
    autoCraftPollTicker = C_Timer.NewTicker(0.2, function(ticker)
        local remaining = GetTradeskillRepeatCount and GetTradeskillRepeatCount() or 0  -- nil-safe: may be absent on some clients
        local casting = UnitCastingInfo("player") or UnitChannelInfo("player")

        if remaining == 0 then
            sawRemainingZero = true
        end

        -- Update alert when remaining count decreases AND still casting
        -- (casting confirms a craft completed and the next one started;
        -- without this guard, a cancel drops remaining before the cast clears)
        if showAlert and remaining > 0 and remaining < lastDisplayed and casting then
            lastDisplayed = remaining
            UpdateCraftAlert(remaining, recipeName)
        end

        -- Track how long we've been idle (not casting)
        if casting then
            notCastingSince = nil
        elseif not notCastingSince then
            notCastingSince = GetTime()
        end

        -- Close when not casting for 1s (covers both completion and cancel)
        -- Normal completion: remaining hit 0 at some point → "complete!"
        -- Cancel (move/esc): remaining never hit 0 → silent fade
        if notCastingSince and (GetTime() - notCastingSince) >= 1.0 then
            -- Cancel ticker FIRST so errors in cleanup can't leave it running
            ticker:Cancel()
            autoCraftPollTicker = nil
            if showAlert then
                if sawRemainingZero then
                    CompleteCraftAlert(recipeName)
                else
                    DismissCraftAlert()
                end
            end
            autoCraftHiding = false
            if TradeSkillFrame then
                TradeSkillFrame:SetAlpha(1)
            end
            CloseTradeSkill()
            RecalcTradeskillAvailability()
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

    -- Sync CVar with our setting so spellbook exposes all ranks (or not)
    SetCVar("ShowAllSpellRanks", WofiDB.allSpellRanks and 1 or 0)

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

    -- Sort alphabetically, then by rank descending (highest first) for same-name spells
    table.sort(spellCache, function(a, b)
        if a.name == b.name then
            return a.slot > b.slot -- higher slot = higher rank
        end
        return a.name < b.name
    end)
    spellCacheBuilt = true
end

-- ============================================================================
-- Item Cache
-- ============================================================================

local function IsUsableItem(bagID, slotID)
    local info = GetContainerItemInfo(bagID, slotID)
    if not info or not info.itemID then return false end

    -- Check if item has a Use: spell effect (potions, gadgets, patterns, etc.)
    local itemSpell = GetItemSpell(info.itemID)
    if itemSpell then return true end

    -- Check if it's a Quest item (quest starters, etc.)
    if select(6, GetItemInfo(info.itemID)) == "Quest" then return true end

    -- Check if item is flagged as readable/usable (some quest items)
    if info.isReadable then return true end

    return false
end

local function BuildItemCache()
    wipe(itemCache)

    -- Scan all bags (0 = backpack, 1-4 = bags)
    local seenIDs = {}  -- deduplicate stacks of the same item
    for bagID = 0, 4 do
        local numSlots = GetContainerNumSlots(bagID)
        for slotID = 1, numSlots do
            if IsUsableItem(bagID, slotID) then
                local info = GetContainerItemInfo(bagID, slotID)
                if info and info.itemID and not seenIDs[info.itemID] then
                    local itemName, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(info.itemID)
                    if itemName then
                        seenIDs[info.itemID] = true
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

    -- Sort alphabetically
    table.sort(itemCache, function(a, b) return a.name < b.name end)
    itemCacheBuilt = true
end

-- ============================================================================
-- Macro Cache
-- ============================================================================

local MAX_ACCOUNT_MACROS = 120
local MAX_CHARACTER_MACROS = 18

local function BuildMacroCache()
    wipe(macroCache)

    local numAccount, numCharacter = GetNumMacros()

    -- Scan account-wide macros (indices 1..numAccount)
    for i = 1, numAccount do
        local name, iconTexture, body = GetMacroInfo(i)
        if name and name ~= "" then
            table.insert(macroCache, {
                entryType = TYPE_MACRO,
                name = name,
                macroIndex = i,
                texture = iconTexture,
                body = body or "",
                nameLower = name:lower(),
            })
        end
    end

    -- Scan character-specific macros (indices MAX_ACCOUNT_MACROS+1..MAX_ACCOUNT_MACROS+numCharacter)
    for i = 1, numCharacter do
        local idx = MAX_ACCOUNT_MACROS + i
        local name, iconTexture, body = GetMacroInfo(idx)
        if name and name ~= "" then
            table.insert(macroCache, {
                entryType = TYPE_MACRO,
                name = name,
                macroIndex = idx,
                texture = iconTexture,
                body = body or "",
                nameLower = name:lower(),
            })
        end
    end

    -- Sort alphabetically
    table.sort(macroCache, function(a, b) return a.name < b.name end)
    macroCacheBuilt = true
end

-- ============================================================================
-- Player Cache
-- ============================================================================

local BuildPlayerCache  -- forward declaration

local function SchedulePlayerCacheRebuild()
    if playerCacheRebuildTimer then
        playerCacheRebuildTimer:Cancel()
    end
    playerCacheRebuildTimer = C_Timer.NewTimer(1, function()
        playerCacheRebuildTimer = nil
        if WofiDB and WofiDB.includePlayers then
            if playerCacheBuilt then
                BuildPlayerCache()
            end
        end
    end)
end

-- Seed coGuildPlayers from GreenWall's comember_cache (recently seen co-guild members)
local function SeedCoGuildFromCache()
    if not gw or not gw.config or not gw.config.comember_cache then return end
    local cache = gw.config.comember_cache.cache
    if not cache then return end
    for name, _ in pairs(cache) do
        local shortName = name:match("^([^%-]+)") or name
        if shortName ~= UnitName("player") and not coGuildPlayers[shortName] then
            coGuildPlayers[shortName] = { timestamp = GetTime() }
        end
    end
end

BuildPlayerCache = function()
    wipe(playerCache)
    local seen = {}  -- name -> { entry, sourcePriority }

    local function AddPlayer(name, source, class, classUpper, level, zone)
        if not name or name == "" then return end
        local existing = seen[name]
        if existing then
            if source > existing.sourcePriority then
                existing.entry.source = source
                existing.entry.class = class or existing.entry.class
                existing.entry.classUpper = classUpper or existing.entry.classUpper
                existing.entry.level = level or existing.entry.level
                existing.entry.zone = zone or existing.entry.zone
                existing.sourcePriority = source
            end
            return
        end

        local texture
        if classUpper and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classUpper] then
            texture = "Interface\\GLUES\\CHARACTERCREATE\\UI-CharacterCreate-Classes"
        else
            texture = "Interface\\FriendsFrame\\UI-Toast-FriendOnlineIcon"
        end

        local entry = {
            entryType = TYPE_PLAYER,
            name = name,
            nameLower = name:lower(),
            texture = texture,
            source = source,
            class = class,
            classUpper = classUpper,
            level = level,
            zone = zone,
        }
        table.insert(playerCache, entry)
        seen[name] = { entry = entry, sourcePriority = source }
    end

    local myRealm = GetRealmName()

    -- 1) WoW friends list
    if C_FriendList then
        local numFriends = C_FriendList.GetNumFriends()
        for i = 1, numFriends do
            local info = C_FriendList.GetFriendInfoByIndex(i)
            if info and info.connected then
                -- className is localized display name, need file name for RAID_CLASS_COLORS
                local classFile = info.className and info.className:upper():gsub(" ", "") or nil
                AddPlayer(info.name, PLAYER_SOURCE_FRIEND, info.className, classFile, info.level, info.area)
            end
        end
    end

    -- 2) BNet friends (same faction, online in WoW)
    if BNGetNumFriends and BNGetFriendInfo and BNGetGameAccountInfo then
        local numBNet = BNGetNumFriends() or 0
        for i = 1, numBNet do
            local ok, _, _, _, _,
                  toonName, toonID, client, isOnline = pcall(BNGetFriendInfo, i)
            if ok and isOnline and toonID and client == BNET_CLIENT_WOW then
                local ok2, _, charName, _, realmName, _, faction,
                      _, class, _, zoneName, level = pcall(BNGetGameAccountInfo, toonID)
                if ok2 and charName and charName ~= "" then
                    local classFile = class and class:upper():gsub(" ", "") or nil
                    local displayName = charName
                    if realmName and realmName ~= "" and realmName ~= myRealm then
                        displayName = charName .. "-" .. realmName
                    end
                    AddPlayer(displayName, PLAYER_SOURCE_BNET, class, classFile, level, zoneName)
                end
            end
        end
    end

    -- 3) Guild members (online only)
    if IsInGuild() then
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        elseif GuildRoster then
            GuildRoster()
        end
        local numGuild = GetNumGuildMembers()
        for i = 1, numGuild do
            local fullName, _, _, level, _, zone, _, _, isOnline, _, classFile = GetGuildRosterInfo(i)
            if fullName and isOnline then
                -- Strip realm suffix if same realm
                local shortName = fullName:match("^([^%-]+)")
                local classDisplay = classFile and (classFile:sub(1,1) .. classFile:sub(2):lower()) or nil
                AddPlayer(shortName, PLAYER_SOURCE_GUILD, classDisplay, classFile, level, zone)
            end
        end
    end

    -- 4) GreenWall co-guild members (optional dependency, populated by message handler)
    for name, data in pairs(coGuildPlayers) do
        AddPlayer(name, PLAYER_SOURCE_COGUILD, data.class, data.classUpper, data.level, data.zone)
    end

    -- 5) Recent interactions (session-only)
    for name, data in pairs(recentPlayers) do
        AddPlayer(name, PLAYER_SOURCE_RECENT, data.class, data.classUpper, data.level, data.zone)
    end

    table.sort(playerCache, function(a, b) return a.name < b.name end)
    playerCacheBuilt = true
end

local function TrackRecentPlayer(name, class, classUpper, level, zone)
    if not name or name == "" then return end
    -- Skip self
    local myName = UnitName("player")
    if name == myName then return end
    -- Strip realm if same realm
    local shortName = name:match("^([^%-]+)") or name

    if not recentPlayers[shortName] then
        recentPlayerCount = recentPlayerCount + 1
    end
    recentPlayers[shortName] = {
        timestamp = GetTime(),
        class = class,
        classUpper = classUpper,
        level = level,
        zone = zone,
    }

    -- Trim to MAX_RECENT_PLAYERS (evict oldest)
    if recentPlayerCount > MAX_RECENT_PLAYERS then
        local oldestName, oldestTime = nil, math.huge
        for n, data in pairs(recentPlayers) do
            if data.timestamp < oldestTime then
                oldestName = n
                oldestTime = data.timestamp
            end
        end
        if oldestName then
            recentPlayers[oldestName] = nil
            recentPlayerCount = recentPlayerCount - 1
        end
    end

    SchedulePlayerCacheRebuild()
end

-- ============================================================================
-- Zone/Map Cache
-- ============================================================================

local function BuildZoneCache()
    wipe(zoneCache)
    if not C_Map or not C_Map.GetFallbackWorldMapID then return end

    -- Walk the map tree: world root -> continents -> zones
    local rootID = C_Map.GetFallbackWorldMapID()
    local rootChildren = C_Map.GetMapChildrenInfo(rootID) or {}

    local continentIDs = {}
    for _, child in ipairs(rootChildren) do
        if child.mapType == Enum.UIMapType.Continent then
            -- direct continent under root
            table.insert(continentIDs, { mapID = child.mapID, name = child.name })
        elseif child.mapType == Enum.UIMapType.World then
            -- world node between root and continents (e.g. "Azeroth")
            local worldChildren = C_Map.GetMapChildrenInfo(child.mapID) or {}
            for _, wchild in ipairs(worldChildren) do
                if wchild.mapType == Enum.UIMapType.Continent then
                    table.insert(continentIDs, { mapID = wchild.mapID, name = wchild.name })
                end
            end
        end
    end

    for _, cont in ipairs(continentIDs) do
        local zones = C_Map.GetMapChildrenInfo(cont.mapID, Enum.UIMapType.Zone, false) or {}
        for _, zone in ipairs(zones) do
            if zone.name and zone.name ~= "" then
                table.insert(zoneCache, {
                    entryType  = TYPE_MAP,
                    name       = zone.name,
                    nameLower  = zone.name:lower(),
                    mapID      = zone.mapID,
                    continent  = cont.name,
                    texture    = "Interface\\Icons\\INV_Misc_Map_01",
                })
            end
        end
    end
    table.sort(zoneCache, function(a, b) return a.name < b.name end)
    zoneCacheBuilt = true
end

-- ============================================================================
-- Lockout Cache
-- ============================================================================

local function FormatResetTime(seconds)
    if seconds <= 0 then return "expired" end
    local d = math.floor(seconds / 86400)
    local h = math.floor((seconds % 86400) / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if d > 0 then return d .. "d " .. h .. "h"
    elseif h > 0 then return h .. "h " .. m .. "m"
    else return m .. "m" end
end

local function BuildLockoutCache()
    wipe(lockoutCache)
    local numInstances = GetNumSavedInstances()
    for i = 1, numInstances do
        local name, id, reset, difficulty, locked, extended,
              instanceIDMostSig, isRaid, maxPlayers, difficultyName,
              numEncounters, progress = GetSavedInstanceInfo(i)
        if name then
            local texture = "Interface\\Icons\\Spell_Arcane_Blink"
            table.insert(lockoutCache, {
                entryType      = TYPE_LOCKOUT,
                name           = name,
                nameLower      = name:lower(),
                instanceIndex  = i,
                isRaid         = isRaid,
                reset          = reset,
                resetStr       = FormatResetTime(reset),
                numEncounters  = numEncounters or 0,
                progress       = progress or 0,
                maxPlayers     = maxPlayers,
                difficultyName = difficultyName,
                texture        = texture,
            })
        end
    end
end

-- ============================================================================
-- Quest Cache
-- ============================================================================

local function BuildQuestCache()
    wipe(questCache)
    local numEntries = GetNumQuestLogEntries()
    for i = 1, numEntries do
        local title, level, questTag, isHeader, isCollapsed,
              isComplete, frequency, questID = GetQuestLogTitle(i)
        if title and not isHeader then
            local _, itemTexture = GetQuestLogSpecialItemInfo(i)
            local complete = isComplete and isComplete ~= 0
            table.insert(questCache, {
                entryType     = TYPE_QUEST,
                name          = title,
                nameLower     = title:lower(),
                questLogIndex = i,
                questID       = questID or 0,
                level         = level,
                isComplete    = complete,
                texture       = itemTexture
                    or (complete
                        and "Interface\\GossipFrame\\AvailableQuestIcon"
                        or  "Interface\\GossipFrame\\ActiveQuestIcon"),
            })
        end
    end
    questCacheBuilt = true
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

    -- Search macros (if enabled)
    if WofiDB.includeMacros then
        for _, entry in ipairs(macroCache) do
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

    -- Search tradeskill recipes (if enabled and any are cached)
    if WofiDB.includeTradeskills and #tradeskillCache > 0 then
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

    -- Search players (if enabled)
    if WofiDB.includePlayers and #playerCache > 0 then
        for _, entry in ipairs(playerCache) do
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

    -- Search zones/maps (if enabled)
    if WofiDB.includeZones and #zoneCache > 0 then
        for _, entry in ipairs(zoneCache) do
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

    -- Search instance lockouts (if enabled)
    if WofiDB.includeLockouts and #lockoutCache > 0 then
        for _, entry in ipairs(lockoutCache) do
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

    -- Search active quests (if enabled and Questie is available)
    if WofiDB.includeQuests and IsQuestieAvailable() and #questCache > 0 then
        for _, entry in ipairs(questCache) do
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
    local maxResults = WofiDB.maxResults or 8
    for _, entry in ipairs(exactMatches) do
        if #results < maxResults then table.insert(results, entry) end
    end
    for _, entry in ipairs(startMatches) do
        if #results < maxResults then table.insert(results, entry) end
    end
    for _, entry in ipairs(containsMatches) do
        if #results < maxResults then table.insert(results, entry) end
    end
    for _, match in ipairs(fuzzyMatches) do
        if #results < maxResults then table.insert(results, match.entry) end
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

    local maxResults = WofiDB.maxResults or 8
    for _, entry in ipairs(exactMatches) do
        if #results < maxResults then table.insert(results, entry) end
    end
    for _, entry in ipairs(startMatches) do
        if #results < maxResults then table.insert(results, entry) end
    end
    for _, entry in ipairs(containsMatches) do
        if #results < maxResults then table.insert(results, entry) end
    end
    for _, match in ipairs(fuzzyMatches) do
        if #results < maxResults then table.insert(results, match.entry) end
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
local animationFrame   -- forward declaration; defined below after UpdateFadeAnimations
local UpdateFadeAnimations  -- forward declaration

local function StartFadeIn(frame, duration)
    duration = duration or 0.15
    fadeAnimations[frame] = {
        elapsed = 0,
        duration = duration,
        startAlpha = 0,
        endAlpha = 1,
    }
    frame:SetAlpha(0)
    -- Re-enable OnUpdate only while animations are active
    animationFrame:SetScript("OnUpdate", UpdateFadeAnimations)
    -- Don't call Show() here - OnShow triggers this, frame is already showing
end

UpdateFadeAnimations = function(self, elapsed)
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
    -- Disable OnUpdate when no animations remain (saves CPU between fades)
    if not next(fadeAnimations) then
        self:SetScript("OnUpdate", nil)
    end
end

-- Animation frame (created once; OnUpdate is enabled only while animations are active)
animationFrame = CreateFrame("Frame")

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
    btn:RegisterForClicks("LeftButtonUp")
    btn:RegisterForDrag("LeftButton", "RightButton")

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

    -- PostClick: hide frame after secure action, or dispatch non-secure entry types
    btn:SetScript("PostClick", function(self)
        if not self.entry then return end
        if self.entry.entryType == TYPE_TRADESKILL then
            addon:ShowTradeskillPopup(self.entry)
            return
        end
        if self.entry.entryType == TYPE_PLAYER then
            ChatFrame_SendTell(self.entry.name)
            WofiFrame:Hide()
            return
        end
        if self.entry.entryType == TYPE_MAP then
            WofiFrame:Hide()
            local targetMapID = self.entry.mapID
            ShowUIPanel(WorldMapFrame)
            -- Defer one tick so OnShow's player-zone reset doesn't override us
            C_Timer.After(0, function()
                if WorldMapFrame.SetMapID then
                    WorldMapFrame:SetMapID(targetMapID)
                end
            end)
            return
        end
        if self.entry.entryType == TYPE_LOCKOUT then
            WofiFrame:Hide()
            return
        end
        if self.entry.entryType == TYPE_QUEST then
            WofiFrame:Hide()
            SelectQuestLogEntry(self.entry.questLogIndex)
            local qID = self.entry.questID
            -- Always open the map first at the player's current zone as a baseline.
            -- Questie will then SetMapID to the quest zone if it can find one.
            WorldMapFrame:Show()
            if C_Map and C_Map.GetBestMapForUnit then
                local m = C_Map.GetBestMapForUnit("player")
                if m then WorldMapFrame:SetMapID(m) end
            end
            -- Use Questie's map navigation to navigate to the quest's zone
            if qID and qID > 0 and QuestieLoader then
                local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
                local QuestieTrackerUtils = QuestieLoader:ImportModule("TrackerUtils")
                if QuestieDB and QuestieTrackerUtils then
                    local quest = QuestieDB.GetQuest(qID)
                    if quest then
                        if quest:IsComplete() == 1 then
                            QuestieTrackerUtils:ShowFinisherOnMap(quest)
                        else
                            -- Check one level deeper: spawnList may exist but contain entries
                            -- with nil Spawns (e.g. event/discovery NPCs with no DB coordinates).
                            local shown = false
                            if quest.Objectives then
                                for _, obj in pairs(quest.Objectives) do
                                    if obj.spawnList then
                                        for _, spawnData in pairs(obj.spawnList) do
                                            if spawnData.Spawns and next(spawnData.Spawns) then
                                                QuestieTrackerUtils:ShowObjectiveOnMap(obj)
                                                shown = true
                                                break
                                            end
                                        end
                                    end
                                    if shown then break end
                                end
                            end
                            if not shown then
                                QuestieTrackerUtils:ShowFinisherOnMap(quest)
                            end
                        end
                    end
                end
            end
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
            elseif self.entry.entryType == TYPE_MACRO then
                GameTooltip:SetText(self.entry.name, 1, 1, 1)
                if self.entry.body and self.entry.body ~= "" then
                    -- Show first few lines of macro body
                    local lines = 0
                    for line in self.entry.body:gmatch("[^\n]+") do
                        if lines < 5 then
                            GameTooltip:AddLine(line, 0.7, 0.7, 0.7)
                            lines = lines + 1
                        end
                    end
                    if lines == 0 then
                        GameTooltip:AddLine("(empty macro)", 0.5, 0.5, 0.5)
                    end
                end
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
                if (self.entry.numAvailable or 0) > 0 then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Can craft: " .. self.entry.numAvailable, 0.5, 1, 0.5)
                end
            elseif self.entry.entryType == TYPE_PLAYER then
                local r, g, b = 1, 1, 1
                if self.entry.classUpper and RAID_CLASS_COLORS and RAID_CLASS_COLORS[self.entry.classUpper] then
                    local cc = RAID_CLASS_COLORS[self.entry.classUpper]
                    r, g, b = cc.r, cc.g, cc.b
                end
                GameTooltip:SetText(self.entry.name, r, g, b)
                if self.entry.class and self.entry.level then
                    GameTooltip:AddLine("Level " .. self.entry.level .. " " .. self.entry.class, 0.8, 0.8, 0.8)
                elseif self.entry.class then
                    GameTooltip:AddLine(self.entry.class, 0.8, 0.8, 0.8)
                elseif self.entry.level then
                    GameTooltip:AddLine("Level " .. self.entry.level, 0.8, 0.8, 0.8)
                end
                if self.entry.zone and self.entry.zone ~= "" then
                    GameTooltip:AddLine(self.entry.zone, 0.6, 0.6, 0.6)
                end
                local sourceInfo = PLAYER_SOURCE_INFO[self.entry.source]
                if sourceInfo then
                    GameTooltip:AddLine(sourceInfo.tag, sourceInfo.color[1], sourceInfo.color[2], sourceInfo.color[3])
                end
            elseif self.entry.entryType == TYPE_MAP then
                GameTooltip:SetText(self.entry.name, 1, 1, 1)
                if self.entry.continent then
                    GameTooltip:AddLine(self.entry.continent, 0.5, 0.5, 1)
                end
            elseif self.entry.entryType == TYPE_LOCKOUT then
                GameTooltip:SetText(self.entry.name, 1, 1, 1)
                local typeStr = (self.entry.isRaid and "Raid" or "Dungeon")
                    .. (self.entry.difficultyName and self.entry.difficultyName ~= ""
                        and " (" .. self.entry.difficultyName .. ")" or "")
                GameTooltip:AddLine(typeStr, 0.5, 0.5, 1)
                if self.entry.numEncounters > 0 then
                    GameTooltip:AddLine("Bosses: " .. self.entry.progress .. "/" .. self.entry.numEncounters, 0.8, 0.8, 0.8)
                end
                GameTooltip:AddLine("Resets in: " .. self.entry.resetStr, 0.6, 0.6, 0.6)
            elseif self.entry.entryType == TYPE_QUEST then
                GameTooltip:SetText(self.entry.name, 1, 0.82, 0)
                if self.entry.level then
                    GameTooltip:AddLine("Level " .. self.entry.level, 0.5, 0.5, 1)
                end
                if self.entry.isComplete then
                    GameTooltip:AddLine("Ready to turn in!", 0.4, 1.0, 0.4)
                end
            end
            GameTooltip:AddLine(" ")
            if self.entry.entryType == TYPE_TRADESKILL then
                GameTooltip:AddLine("Left-click to craft", 0.5, 0.8, 1)
            elseif self.entry.entryType == TYPE_PLAYER then
                GameTooltip:AddLine("Left-click to whisper", 0.5, 0.8, 1)
            elseif self.entry.entryType == TYPE_MAP then
                GameTooltip:AddLine("Left-click to open map", 0.5, 0.8, 1)
            elseif self.entry.entryType == TYPE_LOCKOUT then
                GameTooltip:AddLine("Lockout info", 0.5, 0.5, 0.5)
            elseif self.entry.entryType == TYPE_QUEST then
                GameTooltip:AddLine("Left-click to show on map", 0.5, 0.8, 1)
            elseif self.entry.entryType == TYPE_MACRO then
                GameTooltip:AddLine("Left-click to run, Right-drag to action bar", 0.5, 0.8, 1)
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
        local noDrag = { [TYPE_PLAYER]=true, [TYPE_MAP]=true, [TYPE_LOCKOUT]=true, [TYPE_QUEST]=true }
        if noDrag[self.entry.entryType] then return end

        if self.entry.entryType == TYPE_SPELL then
            PickupSpellBookItem(self.entry.slot, BOOKTYPE_SPELL)
        elseif self.entry.entryType == TYPE_ITEM then
            -- Find current bag/slot for this item (may have moved since cache)
            for bagID = 0, 4 do
                local numSlots = GetContainerNumSlots(bagID)
                for slotID = 1, numSlots do
                    local info = GetContainerItemInfo(bagID, slotID)
                    if info and info.itemID == self.entry.itemID then
                        C_Container.PickupContainerItem(bagID, slotID)
                        return
                    end
                end
            end
        elseif self.entry.entryType == TYPE_MACRO then
            PickupMacro(self.entry.macroIndex)
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
        if WofiDB.includeMacros and not macroCacheBuilt then
            BuildMacroCache()
        end
        if WofiDB.includePlayers and not playerCacheBuilt then
            BuildPlayerCache()
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
            resultButtons[i]:SetAttribute("macro", nil)
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
            btn.icon:SetTexCoord(0, 1, 0, 1)  -- Reset tex coords (player entries override)
            btn.text:SetText(entry.name)
            btn.selected:SetShown(i == selectedIndex)

            if entry.entryType == TYPE_SPELL then
                btn:SetAttribute("type", "spell")
                btn:SetAttribute("spell", entry.name)
                btn:SetAttribute("item", nil)
                btn:SetAttribute("macro", nil)
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
                btn:SetAttribute("macro", nil)
                btn.typeText:SetText("[item]")
                btn.typeText:SetTextColor(0.5, 0.5, 0.5)
            elseif entry.entryType == TYPE_MACRO then
                btn:SetAttribute("type", "macro")
                btn:SetAttribute("macro", entry.macroIndex)
                btn:SetAttribute("spell", nil)
                btn:SetAttribute("item", nil)
                btn.typeText:SetText("[macro]")
                btn.typeText:SetTextColor(0.6, 0.8, 1.0)
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
            elseif entry.entryType == TYPE_PLAYER then
                btn:SetAttribute("type", "")
                btn:SetAttribute("spell", nil)
                btn:SetAttribute("item", nil)
                btn:SetAttribute("macro", nil)
                -- Class icon tex coords
                if entry.classUpper and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[entry.classUpper] then
                    local coords = CLASS_ICON_TCOORDS[entry.classUpper]
                    btn.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                end
                local sourceInfo = PLAYER_SOURCE_INFO[entry.source]
                if sourceInfo then
                    btn.typeText:SetText(sourceInfo.tag)
                    btn.typeText:SetTextColor(sourceInfo.color[1], sourceInfo.color[2], sourceInfo.color[3])
                else
                    btn.typeText:SetText("[player]")
                    btn.typeText:SetTextColor(0.5, 0.5, 0.5)
                end
            elseif entry.entryType == TYPE_MAP then
                btn:SetAttribute("type", "")
                btn:SetAttribute("spell", nil)
                btn:SetAttribute("item", nil)
                btn:SetAttribute("macro", nil)
                btn.typeText:SetText("[map]")
                btn.typeText:SetTextColor(0.4, 0.8, 1.0)
            elseif entry.entryType == TYPE_LOCKOUT then
                btn:SetAttribute("type", "")
                btn:SetAttribute("spell", nil)
                btn:SetAttribute("item", nil)
                btn:SetAttribute("macro", nil)
                local cleared = entry.numEncounters > 0 and entry.progress >= entry.numEncounters
                local progressStr = cleared and "cleared"
                    or (entry.numEncounters > 0 and entry.progress .. "/" .. entry.numEncounters or "locked")
                btn.typeText:SetText("[" .. progressStr .. " | " .. entry.resetStr .. "]")
                if cleared then
                    btn.typeText:SetTextColor(0.4, 1.0, 0.4)
                else
                    btn.typeText:SetTextColor(1.0, 0.8, 0.3)
                end
            elseif entry.entryType == TYPE_QUEST then
                btn:SetAttribute("type", "")
                btn:SetAttribute("spell", nil)
                btn:SetAttribute("item", nil)
                btn:SetAttribute("macro", nil)
                if entry.isComplete then
                    btn.typeText:SetText("[turnin]")
                    btn.typeText:SetTextColor(0.4, 1.0, 0.4)
                else
                    btn.typeText:SetText("[quest]")
                    btn.typeText:SetTextColor(1.0, 0.82, 0.0)
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
-- Welcome Screen (first-run only)
-- ============================================================================

local function ShowWelcome()
    -- Don't show if already dismissed or keybind is set
    if WofiDB.welcomeShown or WofiDB.keybind then return end
    if welcomeFrame then welcomeFrame:Show(); return end

    welcomeFrame = CreateFrame("Frame", "WofiWelcomeFrame", UIParent)
    local frame = welcomeFrame
    frame:SetSize(340, 160)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    ApplyGlowBorder(frame, 1)

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|cff00ff00Wofi|r")

    -- Body text
    local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOP", title, "BOTTOM", 0, -12)
    body:SetWidth(300)
    body:SetJustifyH("CENTER")
    body:SetText("Welcome! Set a keybind in options to open the search launcher with a single keypress.")

    -- Open Options button
    local optionsBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    optionsBtn:SetSize(140, 26)
    optionsBtn:SetPoint("TOP", body, "BOTTOM", 0, -16)
    optionsBtn:SetText("Open Options")
    optionsBtn:SetScript("OnClick", function()
        frame:Hide()
        addon:ShowConfig()
    end)

    -- Don't show again checkbox
    local neverCb = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    neverCb:SetPoint("BOTTOMLEFT", 16, 12)
    neverCb.text:SetText("Don't show again")
    neverCb.text:SetFontObject(GameFontNormalSmall)
    neverCb:SetScript("OnClick", function(self)
        WofiDB.welcomeShown = self:GetChecked()
    end)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function()
        if neverCb:GetChecked() then
            WofiDB.welcomeShown = true
        end
        frame:Hide()
    end)

    frame:Show()
end

-- ============================================================================
-- Native Settings Panel (ESC > Options > AddOns > Wofi)
-- ============================================================================

local function RegisterSettings()
    -- Canvas frame for the options panel
    local canvas = CreateFrame("Frame", "WofiSettingsCanvas", UIParent)
    canvas:Hide()

    local yPos = -16

    -- Section: Search
    local searchHeader = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    searchHeader:SetPoint("TOPLEFT", 16, yPos)
    searchHeader:SetText("Search")
    searchHeader:SetTextColor(1, 0.82, 0)
    yPos = yPos - 30

    -- Include Items checkbox
    local itemsCb = CreateFrame("CheckButton", nil, canvas, "UICheckButtonTemplate")
    itemsCb:SetPoint("TOPLEFT", 16, yPos)
    itemsCb.text:SetText("Include inventory items in search results")
    itemsCb.text:SetFontObject(GameFontNormal)
    itemsCb:SetScript("OnClick", function(self)
        WofiDB.includeItems = self:GetChecked()
        if WofiDB.includeItems and not itemCacheBuilt then
            BuildItemCache()
        end
    end)
    yPos = yPos - 30

    -- Include Macros checkbox
    local macrosCb = CreateFrame("CheckButton", nil, canvas, "UICheckButtonTemplate")
    macrosCb:SetPoint("TOPLEFT", 16, yPos)
    macrosCb.text:SetText("Include macros in search results")
    macrosCb.text:SetFontObject(GameFontNormal)
    macrosCb:SetScript("OnClick", function(self)
        WofiDB.includeMacros = self:GetChecked()
        if WofiDB.includeMacros and not macroCacheBuilt then
            BuildMacroCache()
        end
    end)
    yPos = yPos - 30

    -- Include Tradeskills checkbox
    local tradeskillsCb = CreateFrame("CheckButton", nil, canvas, "UICheckButtonTemplate")
    tradeskillsCb:SetPoint("TOPLEFT", 16, yPos)
    tradeskillsCb.text:SetText("Include tradeskill recipes in search results")
    tradeskillsCb.text:SetFontObject(GameFontNormal)
    tradeskillsCb:SetScript("OnClick", function(self)
        WofiDB.includeTradeskills = self:GetChecked()
    end)
    yPos = yPos - 30

    -- Include Players checkbox
    local playersCb = CreateFrame("CheckButton", nil, canvas, "UICheckButtonTemplate")
    playersCb:SetPoint("TOPLEFT", 16, yPos)
    playersCb.text:SetText("Include online players in search results")
    playersCb.text:SetFontObject(GameFontNormal)
    playersCb:SetScript("OnClick", function(self)
        WofiDB.includePlayers = self:GetChecked()
        if WofiDB.includePlayers and not playerCacheBuilt then
            BuildPlayerCache()
        end
    end)
    yPos = yPos - 30

    -- Include Zones checkbox
    local zonesCb = CreateFrame("CheckButton", nil, canvas, "UICheckButtonTemplate")
    zonesCb:SetPoint("TOPLEFT", 16, yPos)
    zonesCb.text:SetText("Include zone/map search")
    zonesCb.text:SetFontObject(GameFontNormal)
    zonesCb:SetScript("OnClick", function(self)
        WofiDB.includeZones = self:GetChecked()
        if WofiDB.includeZones and not zoneCacheBuilt then
            BuildZoneCache()
        end
    end)
    yPos = yPos - 30

    -- Include Lockouts checkbox
    local lockoutsCb = CreateFrame("CheckButton", nil, canvas, "UICheckButtonTemplate")
    lockoutsCb:SetPoint("TOPLEFT", 16, yPos)
    lockoutsCb.text:SetText("Include instance lockouts in search results")
    lockoutsCb.text:SetFontObject(GameFontNormal)
    lockoutsCb:SetScript("OnClick", function(self)
        WofiDB.includeLockouts = self:GetChecked()
        if WofiDB.includeLockouts then
            BuildLockoutCache()
        end
    end)
    yPos = yPos - 30

    -- Include Quests checkbox (disabled when Questie is not loaded)
    local questsCb = CreateFrame("CheckButton", nil, canvas, "UICheckButtonTemplate")
    questsCb:SetPoint("TOPLEFT", 16, yPos)
    questsCb.text:SetText("Include active quests in search results (requires Questie)")
    questsCb.text:SetFontObject(GameFontNormal)
    questsCb:SetScript("OnClick", function(self)
        WofiDB.includeQuests = self:GetChecked()
        if WofiDB.includeQuests and not questCacheBuilt then
            BuildQuestCache()
        end
    end)
    yPos = yPos - 30

    -- Show all spell ranks checkbox
    local allRanksCb = CreateFrame("CheckButton", nil, canvas, "UICheckButtonTemplate")
    allRanksCb:SetPoint("TOPLEFT", 16, yPos)
    allRanksCb.text:SetText("Show all spell ranks")
    allRanksCb.text:SetFontObject(GameFontNormal)
    allRanksCb:SetScript("OnClick", function(self)
        WofiDB.allSpellRanks = self:GetChecked()
        BuildSpellCache()
    end)
    yPos = yPos - 40

    -- Section: Display
    local displayHeader = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    displayHeader:SetPoint("TOPLEFT", 16, yPos)
    displayHeader:SetText("Display")
    displayHeader:SetTextColor(1, 0.82, 0)
    yPos = yPos - 30

    -- Max results slider
    local maxResultsLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    maxResultsLabel:SetPoint("TOPLEFT", 16, yPos)
    maxResultsLabel:SetText("Maximum search results")
    yPos = yPos - 22

    local maxResultsSlider = CreateFrame("Slider", "WofiMaxResultsSlider", canvas, "OptionsSliderTemplate")
    maxResultsSlider:SetPoint("TOPLEFT", 20, yPos)
    maxResultsSlider:SetSize(200, 17)
    maxResultsSlider:SetMinMaxValues(4, 12)
    maxResultsSlider:SetValueStep(1)
    maxResultsSlider:SetObeyStepOnDrag(true)
    maxResultsSlider.Low:SetText("4")
    maxResultsSlider.High:SetText("12")

    local maxResultsValue = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    maxResultsValue:SetPoint("LEFT", maxResultsSlider, "RIGHT", 12, 0)

    maxResultsSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        WofiDB.maxResults = value
        maxResultsValue:SetText(value)
    end)
    yPos = yPos - 34

    -- Show craft alert checkbox
    local craftAlertCb = CreateFrame("CheckButton", nil, canvas, "UICheckButtonTemplate")
    craftAlertCb:SetPoint("TOPLEFT", 16, yPos)
    craftAlertCb.text:SetText("Show craft progress notification")
    craftAlertCb.text:SetFontObject(GameFontNormal)
    craftAlertCb:SetScript("OnClick", function(self)
        WofiDB.showCraftAlert = self:GetChecked()
    end)
    yPos = yPos - 30

    -- Show merchant search checkbox
    local merchantSearchCb = CreateFrame("CheckButton", nil, canvas, "UICheckButtonTemplate")
    merchantSearchCb:SetPoint("TOPLEFT", 16, yPos)
    merchantSearchCb.text:SetText("Show search bar on merchant windows")
    merchantSearchCb.text:SetFontObject(GameFontNormal)
    merchantSearchCb:SetScript("OnClick", function(self)
        WofiDB.showMerchantSearch = self:GetChecked()
    end)
    yPos = yPos - 40

    -- Section: Keybind
    local keybindHeader = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    keybindHeader:SetPoint("TOPLEFT", 16, yPos)
    keybindHeader:SetText("Keybind")
    keybindHeader:SetTextColor(1, 0.82, 0)
    yPos = yPos - 26

    local keybindLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    keybindLabel:SetPoint("TOPLEFT", 16, yPos)

    local function UpdateKeybindLabel()
        if WofiDB.keybind then
            keybindLabel:SetText("Current: |cff80ff80" .. WofiDB.keybind .. "|r")
        else
            keybindLabel:SetText("Current: |cff808080Not set|r")
        end
    end
    addon.UpdateKeybindLabel = UpdateKeybindLabel
    yPos = yPos - 28

    local setBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    setBtn:SetSize(100, 22)
    setBtn:SetPoint("TOPLEFT", 16, yPos)
    setBtn:SetText("Set Keybind")
    setBtn:SetScript("OnClick", function()
        addon:ShowBindListener()
    end)

    local clearBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    clearBtn:SetSize(80, 22)
    clearBtn:SetPoint("LEFT", setBtn, "RIGHT", 8, 0)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        if WofiDB.keybind then
            SetBinding(WofiDB.keybind, nil)
            SaveBindings(GetCurrentBindingSet())
            WofiDB.keybind = nil
            UpdateKeybindLabel()
            print("|cff00ff00Wofi:|r Keybind cleared")
        end
    end)
    yPos = yPos - 40

    -- Section: Cache
    local cacheHeader = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    cacheHeader:SetPoint("TOPLEFT", 16, yPos)
    cacheHeader:SetText("Cache")
    cacheHeader:SetTextColor(1, 0.82, 0)
    yPos = yPos - 26

    local statsLabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsLabel:SetPoint("TOPLEFT", 16, yPos)
    statsLabel:SetTextColor(0.6, 0.6, 0.6)

    local function UpdateStats()
        local itemCount   = WofiDB.includeItems    and #itemCache    or 0
        local macroCount  = WofiDB.includeMacros   and #macroCache   or 0
        local tradeCount  = #tradeskillCache
        local playerCount = WofiDB.includePlayers  and #playerCache  or 0
        local zoneCount   = WofiDB.includeZones    and #zoneCache    or 0
        local lockCount   = WofiDB.includeLockouts and #lockoutCache or 0
        local questCount  = WofiDB.includeQuests   and #questCache   or 0
        statsLabel:SetText(
            #spellCache .. " spells, " .. itemCount .. " items, " ..
            macroCount .. " macros, " .. tradeCount .. " recipes, " ..
            playerCount .. " players, " .. zoneCount .. " zones, " ..
            lockCount .. " lockouts, " .. questCount .. " quests"
        )
    end
    yPos = yPos - 28

    local refreshBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    refreshBtn:SetSize(120, 22)
    refreshBtn:SetPoint("TOPLEFT", 16, yPos)
    refreshBtn:SetText("Refresh Cache")
    refreshBtn:SetScript("OnClick", function()
        addon:RefreshCache()
        UpdateStats()
    end)

    -- OnRefresh: called when the settings panel shows this category
    canvas.OnRefresh = function()
        itemsCb:SetChecked(WofiDB.includeItems)
        macrosCb:SetChecked(WofiDB.includeMacros)
        tradeskillsCb:SetChecked(WofiDB.includeTradeskills)
        playersCb:SetChecked(WofiDB.includePlayers)
        zonesCb:SetChecked(WofiDB.includeZones)
        lockoutsCb:SetChecked(WofiDB.includeLockouts)
        if IsQuestieAvailable() then
            questsCb:Enable()
            questsCb:SetChecked(WofiDB.includeQuests)
            questsCb.text:SetTextColor(1, 1, 1)
        else
            questsCb:Disable()
            questsCb:SetChecked(false)
            questsCb.text:SetTextColor(0.5, 0.5, 0.5)
        end
        allRanksCb:SetChecked(WofiDB.allSpellRanks)
        maxResultsSlider:SetValue(WofiDB.maxResults or 8)
        maxResultsValue:SetText(WofiDB.maxResults or 8)
        craftAlertCb:SetChecked(WofiDB.showCraftAlert)
        merchantSearchCb:SetChecked(WofiDB.showMerchantSearch)
        UpdateKeybindLabel()
        UpdateStats()
    end

    -- Register as canvas layout category
    local category = Settings.RegisterCanvasLayoutCategory(canvas, "Wofi")
    Settings.RegisterAddOnCategory(category)
    settingsCategoryID = category:GetID()
end

function addon:ShowConfig()
    if settingsCategoryID then
        Settings.OpenToCategory(settingsCategoryID)
    end
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
    for i = #tradeskillCache, 1, -1 do
        if tradeskillCache[i].professionName == profName then
            table.remove(tradeskillCache, i)
        end
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
RecalcTradeskillAvailability = function()
    if #tradeskillCache == 0 then return end

    -- Count all items in bags
    local bagCounts = {}
    for bagID = 0, 4 do
        local numSlots = GetContainerNumSlots(bagID)
        for slotID = 1, numSlots do
            local info = GetContainerItemInfo(bagID, slotID)
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
    local numSkillLines = GetNumSkillLines()
    for i = numSkillLines, 1, -1 do
        local _, isHeader, isExpanded = GetSkillLineInfo(i)
        if isHeader and not isExpanded then
            ExpandSkillHeader(i)
        end
    end

    -- Discover player's crafting professions via skill lines
    autoScanQueue = {}
    for i = 1, numSkillLines do
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
            StartAutoCraftClose(entry.name, qty)
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
    tradeskillQuantityPopup.createBtn:SetButtonState("NORMAL")

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
            local numSlots = GetContainerNumSlots(bagID)
            for slotID = 1, numSlots do
                local info = GetContainerItemInfo(bagID, slotID)
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
    toggleButton:SetAttribute("macrotext", "/wofi run")
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
        if addon.UpdateKeybindLabel then addon.UpdateKeybindLabel() end
        print("|cff00ff00Wofi:|r Bound to |cff88ff88" .. keyStr .. "|r")
    end)
end

function addon:ShowBindListener()
    SetupKeybindListener()
    bindingListener:Show()
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
        if not spellCacheBuilt then BuildSpellCache() end
        if WofiDB.includeItems   and not itemCacheBuilt   then BuildItemCache()   end
        if WofiDB.includeMacros  and not macroCacheBuilt  then BuildMacroCache()  end
        if WofiDB.includePlayers and not playerCacheBuilt then BuildPlayerCache() end
        if WofiDB.includeZones   and not zoneCacheBuilt   then BuildZoneCache()   end
        if WofiDB.includeQuests  and not questCacheBuilt  then BuildQuestCache()  end
        if WofiDB.includeLockouts then BuildLockoutCache() end
        WofiFrame:Show()
    end
end

function addon:RefreshCache()
    BuildSpellCache()
    if WofiDB.includeItems    then BuildItemCache()    end
    if WofiDB.includeMacros   then BuildMacroCache()   end
    if WofiDB.includePlayers  then BuildPlayerCache()  end
    if WofiDB.includeZones    then BuildZoneCache()    end
    if WofiDB.includeLockouts then BuildLockoutCache() end
    if WofiDB.includeQuests   then BuildQuestCache()   end
    if #tradeskillCache > 0   then RecalcTradeskillAvailability() end
    local itemCount   = WofiDB.includeItems    and #itemCache    or 0
    local macroCount  = WofiDB.includeMacros   and #macroCache   or 0
    local playerCount = WofiDB.includePlayers  and #playerCache  or 0
    local zoneCount   = WofiDB.includeZones    and #zoneCache    or 0
    local lockCount   = WofiDB.includeLockouts and #lockoutCache or 0
    local questCount  = WofiDB.includeQuests   and #questCache   or 0
    print("|cff00ff00Wofi:|r Cache refreshed (" ..
        #spellCache .. " spells, " .. itemCount .. " items, " ..
        macroCount .. " macros, " .. playerCount .. " players, " ..
        zoneCount .. " zones, " .. lockCount .. " lockouts, " .. questCount .. " quests)")
end

-- Slash commands
SLASH_WOFI1 = "/wofi"
SlashCmdList["WOFI"] = function(msg)
    msg = msg:lower():trim()

    if msg == "help" then
        print("|cff00ff00Wofi Commands:|r")
        print("  /wofi - Open launcher")
        print("  /wofi config - Open options (aliases: options, settings)")
        print("  /wofi refresh - Refresh cache")
        print("  /wofi help - Show this help")
        print("")
        print("|cff00ff00Usage:|r Set a keybind in options, then type to search")
        print("|cff00ff00       |r Up/Down to select, Enter/Left-click to use")
        print("|cff00ff00       |r Right-drag to place on action bar")
    elseif msg == "config" or msg == "options" or msg == "settings" then
        addon:ShowConfig()
    elseif msg == "refresh" then
        addon:RefreshCache()
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
eventFrame:RegisterEvent("UPDATE_MACROS")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("TRADE_SKILL_UPDATE")
eventFrame:RegisterEvent("TRADE_SKILL_CLOSE")
eventFrame:RegisterEvent("FRIENDLIST_UPDATE")
eventFrame:RegisterEvent("BN_FRIEND_INFO_CHANGED")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_WHISPER")
eventFrame:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
eventFrame:RegisterEvent("UPDATE_INSTANCE_INFO")

eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2, ...)
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
        RegisterSettings()

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
        eventFrame:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN" then
        -- Build caches after login
        C_Timer.After(1, function()
            BuildSpellCache()
            if WofiDB.includeItems then
                BuildItemCache()
            end
            if WofiDB.includeMacros then
                BuildMacroCache()
            end
            -- Build zone, lockout, and quest caches
            if WofiDB.includeZones    then BuildZoneCache()    end
            if WofiDB.includeLockouts then BuildLockoutCache() end
            if WofiDB.includeQuests   then BuildQuestCache()   end

            -- Build player cache (delayed to let friend/guild data arrive)
            if WofiDB.includePlayers then
                C_Timer.After(2, function()
                    if C_FriendList and C_FriendList.ShowFriends then
                        C_FriendList.ShowFriends()
                    end
                    BuildPlayerCache()
                    -- GreenWall integration (optional dependency)
                    -- Hook gw.ReplicateMessage to capture co-guild player names as they chat
                    if gw and gw.ReplicateMessage then
                        local origReplicateMessage = gw.ReplicateMessage
                        gw.ReplicateMessage = function(event, message, guild_id, arglist)
                            local result = origReplicateMessage(event, message, guild_id, arglist)
                            if WofiDB.includePlayers and arglist and arglist[2] then
                                local sender = arglist[2]
                                local shortName = sender:match("^([^%-]+)") or sender
                                if shortName ~= UnitName("player") and not coGuildPlayers[shortName] then
                                    coGuildPlayers[shortName] = { timestamp = GetTime() }
                                    SchedulePlayerCacheRebuild()
                                end
                            end
                            return result
                        end
                    end
                    -- Seed co-guild players from GreenWall's comember_cache
                    if gw and gw.config and gw.config.comember_cache then
                        C_Timer.After(5, function()
                            if WofiDB.includePlayers then
                                SeedCoGuildFromCache()
                                SchedulePlayerCacheRebuild()
                            end
                        end)
                    end
                end)
            end
            -- Apply or clear keybind
            if WofiDB.keybind then
                ApplyKeybind()
            else
                -- Clear any orphaned WoW binding to the toggle button
                local key = GetBindingKey("CLICK WofiToggleButton:LeftButton")
                if key then
                    SetBinding(key, nil)
                    SaveBindings(GetCurrentBindingSet())
                end
            end
            local bindMsg = WofiDB.keybind and (" Keybind: |cff88ff88" .. WofiDB.keybind .. "|r") or ""
            local tradeMsg = #tradeskillCache > 0 and (", " .. #tradeskillCache .. " recipes cached") or ""
            local playerMsg = ""
            print("|cff00ff00Wofi|r loaded. Type |cff88ff88/wofi|r to open." .. bindMsg .. tradeMsg .. playerMsg)

            -- Show welcome screen on first run
            if not WofiDB.welcomeShown then
                ShowWelcome()
            end

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

    elseif event == "UPDATE_MACROS" then
        -- Rebuild macro cache when macros are created, edited, or deleted
        if macroCacheBuilt and WofiDB.includeMacros then
            BuildMacroCache()
        end

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
        if WofiDB.showMerchantSearch then
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
        end

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

                StartAutoCraftClose(craft.recipeName, craft.qty)
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

    -- Player cache events
    elseif event == "FRIENDLIST_UPDATE" or event == "BN_FRIEND_INFO_CHANGED" then
        if playerCacheBuilt and WofiDB.includePlayers then
            SchedulePlayerCacheRebuild()
        end

    elseif event == "GUILD_ROSTER_UPDATE" then
        if playerCacheBuilt and WofiDB.includePlayers then
            SchedulePlayerCacheRebuild()
        end

    elseif event == "CHAT_MSG_WHISPER" then
        if WofiDB.includePlayers and arg2 then
            TrackRecentPlayer(arg2)
        end

    elseif event == "CHAT_MSG_WHISPER_INFORM" then
        if WofiDB.includePlayers and arg2 then
            TrackRecentPlayer(arg2)
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        if WofiDB.includePlayers and UnitIsPlayer("target") and UnitIsFriend("player", "target") then
            local name = UnitName("target")
            local _, classUpper = UnitClass("target")
            local classDisplay = classUpper and (classUpper:sub(1,1) .. classUpper:sub(2):lower()) or nil
            local level = UnitLevel("target")
            TrackRecentPlayer(name, classDisplay, classUpper, level)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Track party/raid members as recent players
        if WofiDB.includePlayers then
            local numGroup = GetNumGroupMembers()
            if numGroup > 0 then
                local prefix = IsInRaid() and "raid" or "party"
                for i = 1, numGroup do
                    local unit = prefix .. i
                    if UnitExists(unit) and UnitIsPlayer(unit) and UnitIsConnected(unit) then
                        local name = UnitName(unit)
                        local _, classUpper = UnitClass(unit)
                        local classDisplay = classUpper and (classUpper:sub(1,1) .. classUpper:sub(2):lower()) or nil
                        local level = UnitLevel(unit)
                        TrackRecentPlayer(name, classDisplay, classUpper, level)
                    end
                end
            end
        end

    elseif event == "QUEST_LOG_UPDATE" then
        if questCacheBuilt and WofiDB.includeQuests then
            BuildQuestCache()
        end

    elseif event == "UPDATE_INSTANCE_INFO" then
        if WofiDB.includeLockouts then
            BuildLockoutCache()
        end
    end
end)
