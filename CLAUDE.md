# Wofi - Claude Code Instructions

## Project Overview
Wofi (WoW + Rofi) is a WoW Classic Anniversary Edition (20505) addon that provides a Spotlight/Rofi-style launcher for spells, items, macros, profession recipes, players, zones, instance lockouts, quests, reputations, addons, and dungeon/raid loot. Users can quickly search and cast spells, use items, run macros, craft tradeskill recipes, search merchant inventories, manage addons, or browse instance loot tables - all from a single keyboard-driven interface.

## Architecture

### Core Files
- `Wofi.toc` - Addon manifest (Interface 20505 for Classic Anniversary)
- `Wofi.lua` - All addon logic in a single file (~4200 lines)

### Key Components
1. **Spell Cache** - Builds a searchable cache of all non-passive spells from the player's spellbook
2. **Item Cache** - Scans bags for usable items (items with GetItemSpell, quest items, readable items)
3. **Macro Cache** - Scans account-wide (1-120) and character-specific (121-138) macros via GetMacroInfo
4. **Tradeskill Cache** - Auto-scans all crafting professions on login to index recipes with reagent data; persisted in SavedVariables across sessions
5. **Player Cache** - Indexes online friends, BNet friends (same server), guild members, GreenWall co-guild members (optional dependency), and recently interacted players; session-only recent and co-guild tracking
6. **Zone Cache** - Indexes all game zones/subzones from C_Map for location search; walks up from GetFallbackWorldMapID() to Cosmic root to capture all continents (Azeroth + Outland); built once at login (static data)
7. **Lockout Cache** - Indexes saved instance lockouts (raids/heroics) via GetSavedInstanceInfo; rebuilt on every Wofi open with RequestRaidInfo() for fresh server data; reset timers computed live from absolute expiry timestamps
8. **Quest Cache** - Indexes active quests from the quest log; rebuilt on QUEST_LOG_UPDATE; uses Questie for map navigation (optional dependency)
9. **Reputation Cache** - Scans all player faction standings via GetFactionInfo; expands collapsed headers to access all factions; rebuilt on UPDATE_FACTION; displays standing label and progress with comma-formatted numbers
10. **Merchant Cache** - Built when a merchant window opens, indexes all vendor items for search
11. **Addon Cache** - Scans all installed addons via C_AddOns API; includes name, title, notes, enabled/loaded state; click toggles enable/disable
12. **Instance/Boss Cache** - Indexes dungeon/raid instances and boss encounters from AtlasLoot (optional dependency); pre-caches item data for loot browser
13. **Search UI** - Minimalist popup with EditBox for typing and results frame
12. **SecureActionButtons** - Result buttons use SecureActionButtonTemplate for spells (`type="spell"`), items (`type="item"`), and macros (`type="macro"`)
13. **Tradeskill Craft Popup** - Quantity input with reagent display, live bag counts, MAX button, and secure create button
14. **Merchant Search Overlay** - Search bar that appears on merchant windows with buy/quantity functionality
15. **Craft Progress Alert** - Center-screen notification showing remaining craft count with fade animations and cancel detection
16. **Keybind System** - Custom keybind stored in SavedVariables, applied via SetBindingClick on a macro button
17. **Loot Browser** - Full-featured AtlasLoot-powered instance loot viewer with scroll frame, difficulty buttons (Normal/Heroic), expandable tier set sections grouped by class with spec labels, async item resolution via GET_ITEM_INFO_RECEIVED, Shift-click to link items in chat
18. **Config GUI** - Options panel for settings (opened via `/wofi config`)
19. **Welcome Screen** - First-run setup dialog shown on initial install

### WoW API Constraints
- **Spell/item usage requires SecureActionButtonTemplate** - Cannot call CastSpell() or UseItem() directly
- **SetOverrideBindingClick** - Used to bind Enter key to click the selected secure button
- **SetPropagateKeyboardInput** - Required to let Enter key pass through EditBox to the override binding
- **No combat modifications** - Secure frame attributes cannot be changed during combat
- **C_Container API** - Used for bag scanning in Classic Anniversary (not legacy GetContainerItemInfo)
- **Keybind via macro button** - Custom keybind uses SetBindingClick on a SecureActionButton with `type="macro"` and `macrotext="/wofi"`
- **C_TradeSkillUI.OpenTradeSkill** - Used for taint-free profession opening during auto-scan

## SavedVariables
`WofiDB` stores:
- `keybind` (string|nil) - Custom keybind like "ALT-S"
- `includeItems` (boolean) - Whether to include items in search results
- `includeMacros` (boolean) - Whether to include macros in search results
- `includeTradeskills` (boolean) - Whether to include tradeskill recipes in search results
- `allSpellRanks` (boolean) - Show all spell ranks vs highest only (controls ShowAllSpellRanks CVar)
- `maxResults` (number) - Maximum search results displayed, 4-12 (default 8)
- `showCraftAlert` (boolean) - Show craft progress notification during multi-craft
- `showMerchantSearch` (boolean) - Show search bar overlay on merchant windows
- `includePlayers` (boolean) - Whether to include online players in search results
- `includeZones` (boolean) - Whether to include game zones in search results
- `includeLockouts` (boolean) - Whether to include instance lockouts (raids/heroics) in search results
- `includeQuests` (boolean) - Whether to include active quests in search results (requires Questie)
- `includeReputations` (boolean) - Whether to include player reputations in search results
- `includeAddons` (boolean) - Whether to include installed addons in search results
- `includeInstances` (boolean) - Whether to include dungeon/raid instances and bosses in search results (requires AtlasLoot)
- `welcomeShown` (boolean) - Whether the first-run welcome screen has been shown
- `tradeskillCache` (table) - Persisted recipe data across sessions for all scanned professions

## Entry Types
Each search result has an `entryType` field:
- `"spell"` - Spellbook spell, uses `btn:SetAttribute("type", "spell")` and `btn:SetAttribute("spell", name)`
- `"item"` - Inventory item, uses `btn:SetAttribute("type", "item")` and `btn:SetAttribute("item", name)`
- `"macro"` - Player macro, uses `btn:SetAttribute("type", "macro")` and `btn:SetAttribute("macro", macroIndex)`
- `"tradeskill"` - Profession recipe, opens craft quantity popup on click (not a secure action itself)
- `"player"` - Online player (friend/BNet/guild/recent), opens whisper via `ChatFrame_SendTell()` (not a secure action)
- `"zone"` - Game zone, opens World Map to that zone on click (not a secure action)
- `"lockout"` - Saved instance (raid/heroic), opens Raid Info panel via `ToggleFriendsFrame(4)` on click; reset timer computed live from stored `expiresAt` timestamp
- `"quest"` - Active quest (requires Questie), selects quest log entry and opens World Map; uses Questie API for zone navigation
- `"reputation"` - Player faction reputation, opens Reputation panel via `ToggleCharacter("ReputationFrame")` on click; displays standing label color-coded with `FACTION_BAR_COLORS` and comma-formatted progress (e.g., `[Honored 5,000/12,000]`)
- `"addon"` - Installed addon, click toggles enable/disable via `C_AddOns.EnableAddOn`/`C_AddOns.DisableAddOn`; shows `[enabled]` or `[disabled]` tag; prints reload message
- `"instance"` - Dungeon/raid instance (AtlasLoot), click opens loot browser; shows `[dungeon]` or `[raid]` tag
- `"boss"` - Boss encounter within an instance (AtlasLoot), click opens loot browser scrolled to that boss; shows `[instanceName]` tag

## Slash Commands
- `/wofi` - Toggle launcher
- `/wofi config` - Open configuration GUI (aliases: `/wofi options`, `/wofi settings`)
- `/wofi refresh` - Rebuild caches
- `/wofi help` - Show help

Note: Keybind, item/macro/tradeskill toggles, and display options are all managed via the config GUI (`/wofi config`).

## Events Handled
- `ADDON_LOADED` - Initialize SavedVariables, create UI
- `PLAYER_LOGIN` - Build caches, apply keybind, auto-scan professions
- `LEARNED_SPELL_IN_SKILL_LINE` / `SPELLS_CHANGED` - Rebuild spell cache
- `BAG_UPDATE_DELAYED` - Rebuild item cache, recalculate tradeskill availability
- `UPDATE_MACROS` - Rebuild macro cache when macros are created/edited/deleted
- `PLAYER_REGEN_DISABLED` - Auto-close Wofi and popups when entering combat
- `MERCHANT_SHOW` / `MERCHANT_UPDATE` / `MERCHANT_CLOSED` - Build/refresh/cleanup merchant search overlay
- `TRADE_SKILL_SHOW` / `TRADE_SKILL_UPDATE` / `TRADE_SKILL_CLOSE` - Build/refresh tradeskill cache, handle pending crafts and auto-scan
- `FRIENDLIST_UPDATE` / `BN_FRIEND_INFO_CHANGED` / `GUILD_ROSTER_UPDATE` - Rebuild player cache (debounced)
- `CHAT_MSG_WHISPER` / `CHAT_MSG_WHISPER_INFORM` - Track recent player interactions
- `PLAYER_TARGET_CHANGED` - Track targeted players as recent interactions
- `GROUP_ROSTER_UPDATE` - Track party/raid members as recent players
- `QUEST_LOG_UPDATE` - Rebuild quest cache when quests change
- `UPDATE_INSTANCE_INFO` - Rebuild lockout cache when instance saves change
- `UPDATE_FACTION` - Rebuild reputation cache when faction standings change

## Development Notes
- Uses `BackdropTemplate` for frame backgrounds (required in modern Classic)
- Item cache includes items where `GetItemSpell(itemID)` returns non-nil, or `itemType == "Quest"`, or `info.isReadable`
- Duplicate items (stacks) are deduplicated by itemID
- Results prioritize: exact match > starts with > contains > fuzzy match
- Fuzzy matching finds entries where query characters appear in order (e.g., "fb" matches "Fireball")
- Default 8 results displayed, configurable 4-12 via config GUI slider
- Items show `[item]` indicator in results, spells show rank (e.g., "Rank 5") if available
- Macros show `[macro]` indicator in light blue, tooltip shows first 5 lines of macro body
- Tradeskill results show difficulty color and `[craft: N]` count (or `[craft: 0]` greyed out)
- Zone results show `[zone]` indicator; clicking opens World Map to that zone
- Lockout results show `[progress | time]` with live countdown; clicking opens Raid Info panel (`ToggleFriendsFrame(4)`)
- Quest results show `[quest]` indicator with completion status; clicking opens quest log and World Map (Questie-enhanced navigation)
- Reputation results show `[Standing current/max]` tag (e.g., `[Honored 5,000/12,000]`) color-coded by standing; clicking opens Reputation panel
- `FormatNumber()` utility formats numbers with thousands separators (e.g., 12345 → "12,345"); used in reputation displays
- Player results show source tag (`[friend]`, `[bnet]`, `[guild]`, `[coguild]`, `[recent]`) with class icons and colored indicators
- Result buttons use `RegisterForClicks("LeftButtonDown")` for immediate spell/item activation
- Result buttons use `RegisterForDrag("RightButton")` to allow placing spells/items/macros on action bars
- Toggle button uses `RegisterForClicks("AnyDown")` to fire on keypress
- OnShow uses `C_Timer.After(0.02, ...)` to clear stray characters and delay focus
- Tradeskill auto-scan uses `C_TradeSkillUI.OpenTradeSkill()` to silently open/close each profession
- Craft progress alert uses OnUpdate-driven fade animations (fade in, hold during craft, fade out on complete/cancel)
- Cancel detection: monitors `UnitCastingInfo` and `GetTradeskillRepeatCount` to distinguish completion from cancellation
- Merchant search debounces rebuilds via `C_Timer.NewTimer(0.1, ...)` on `MERCHANT_UPDATE`
- GreenWall integration (optional, listed in TOC as `OptionalDeps: GreenWall`): hooks `gw.ReplicateMessage` on login to capture co-guild member names as they chat, also seeds from `gw.config.comember_cache` 5s after login; co-guild members appear with `[coguild]` tag
- Addon results show `[enabled]` or `[disabled]` tag; clicking toggles state via `C_AddOns.EnableAddOn`/`C_AddOns.DisableAddOn` and prints reload message; live state queried from API on each display
- Instance results show `[dungeon]` (cyan) or `[raid]` (purple) tag; clicking opens the loot browser
- Boss results show `[instanceName]` tag in grey; clicking opens loot browser scrolled to that boss; creature portrait displayed via `SetPortraitTextureFromCreatureDisplayID` when available
- Loot browser uses object pooling for item frames and boss headers; expand/collapse state resets when switching instances; tier set sections grouped by class with spec labels derived from set name suffixes
- AtlasLoot integration (optional, listed in TOC as `OptionalDeps: AtlasLootClassic`): loads `AtlasLootClassic_DungeonsAndRaids` module on demand via `AtlasLoot.Loader:LoadModule`; item data pre-cached at login for async resolution

## Config GUI
The config panel (`/wofi config`) uses the native Settings API (ESC > Options > AddOns > Wofi):
- **Search section**: Checkboxes for include items, include macros, include tradeskills, include players, include zones, include lockouts, include quests (requires Questie), include reputations, include addons, include instances & bosses (requires AtlasLoot), show all spell ranks
- **Display section**: Max results slider (4-12), show craft progress notification, show merchant search bar
- **Keybind section**: Current binding display, Set/Clear buttons
- **Cache section**: Refresh caches button, cache stats display (spell/item/macro/recipe/player/zone/lockout/quest/reputation/addon/instance+boss counts)

## Development Workflow

**Before committing any changes:**

1. **Test in-game first** - Copy changed files to the addon folder for testing:
   ```
   /mnt/data/games/World of Warcraft/_anniversary_/Interface/AddOns/Wofi/
   ```
   Then `/reload` in-game to verify the changes work.

2. **Update version numbers** - Before committing:
   - Add a new version section to `CHANGELOG.md` with the changes
   - Increment the version in `Wofi.toc` (`## Version: x.x.x`)

3. **Commit and push** - Only after testing and updating versions.

4. **Deploy to CurseForge** - Follow the steps in `CI.md` to create a tag and trigger the automated release.

### Manual Zip (Legacy - only if CI/CD is unavailable)

```bash
cd ~/git/mine && \
rm -f ~/Wofi-*.zip && \
zip -r ~/Wofi-$(grep "## Version:" Wofi/Wofi.toc | cut -d' ' -f3 | tr -d '\r').zip \
    Wofi/Wofi.toc Wofi/Wofi.lua Wofi/LICENSE.md
```
This creates `~/Wofi-x.x.x.zip` containing a `Wofi/` folder with the addon files.

## Testing
1. `/reload` after changes
2. Test with `/wofi` to open
3. Type partial spell/item name (test fuzzy matching: "fb" should find "Fireball")
4. Verify spells show rank (e.g., "Rank 5"), items show `[item]`, macros show `[macro]`
5. Use Up/Down arrows or Tab/Shift-Tab to navigate
6. Press Enter or left-click to cast/use
7. Right-drag a result to place spell/item/macro on action bar
8. Test item/macro/tradeskill toggles via `/wofi config`
9. Verify BAG_UPDATE_DELAYED rebuilds item cache
10. Verify UPDATE_MACROS rebuilds macro cache
11. Test `/wofi config` opens GUI with items and macros checkboxes
12. Test keybind via config GUI
13. Enter combat - verify Wofi auto-closes with message
14. Open a profession - verify recipes appear in search results
15. Craft a recipe via search - verify quantity popup, reagent display, and progress alert
16. Cancel a multi-craft (move during cast) - verify alert dismisses silently
17. Open a merchant - verify search bar appears and filters items
18. Buy items via merchant search - verify quantity popup for bulk purchases
19. Type a friend's name - verify `[friend]` tag with class icon
20. Hover player result - verify tooltip shows class, level, zone
21. Click/Enter player result - verify whisper chat opens
22. Whisper someone - verify they appear as `[recent]` in future searches
23. Target a player - verify they appear as `[recent]`
24. Guild members - verify online guildies appear with `[guild]` tag
25. GreenWall (if installed) - verify co-guild members appear with `[coguild]` tag after they chat
26. Type a zone name (e.g., "shatt") - verify `[zone]` tag, click opens World Map to that zone
27. Search for a raid/heroic lockout - verify live reset timer and boss progress
28. Click/Enter a lockout result - verify Raid Info panel opens
29. Accept/complete a quest - verify quest cache updates (requires Questie)
30. Click/Enter a quest result - verify quest log selects and World Map opens
31. Search for a faction name (e.g., "aldor", "cenarion") - verify `[Standing current/max]` tag with faction color
32. Hover reputation result - verify tooltip shows standing label and progress
33. Click/Enter a reputation result - verify Reputation panel opens
34. Gain reputation - verify cache updates (UPDATE_FACTION event)
35. Search for an addon name (e.g., "Questie") - verify `[enabled]` or `[disabled]` tag
36. Click/Enter an addon result - verify it toggles enabled/disabled and prints reload message
37. Search for an instance name (e.g., "Karazhan") - verify `[dungeon]` or `[raid]` tag
38. Click/Enter an instance result - verify loot browser opens with boss loot
39. Search for a boss name - verify `[instanceName]` tag, click opens loot browser scrolled to boss
40. In loot browser - verify Normal/Heroic difficulty buttons work for dungeons with multiple difficulties
41. In loot browser - verify tier set class rows expand/collapse, and state resets when switching instances
42. In loot browser - Shift-click an item to verify it links in chat

## WoW API Reference

For WoW Classic Anniversary API documentation, patterns, and development workflow, use the `/wow-addon` skill:
```
/wow-addon
```
This loads the shared TBC API reference, common patterns, and gotchas.
