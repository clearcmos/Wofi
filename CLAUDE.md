# Wofi - Claude Code Instructions

## Project Overview
Wofi (WoW + Rofi) is a WoW Classic Anniversary Edition (20505) addon that provides a Spotlight/Rofi-style launcher for spells, items, macros, and profession recipes. Users can quickly search and cast spells, use items, run macros, craft tradeskill recipes, or search merchant inventories - all from a single keyboard-driven interface.

## Architecture

### Core Files
- `Wofi.toc` - Addon manifest (Interface 20505 for Classic Anniversary)
- `Wofi.lua` - All addon logic in a single file (~2950 lines)

### Key Components
1. **Spell Cache** - Builds a searchable cache of all non-passive spells from the player's spellbook
2. **Item Cache** - Scans bags for usable items (items with GetItemSpell, quest items, readable items)
3. **Macro Cache** - Scans account-wide (1-120) and character-specific (121-138) macros via GetMacroInfo
4. **Tradeskill Cache** - Auto-scans all crafting professions on login to index recipes with reagent data; persisted in SavedVariables across sessions
5. **Player Cache** - Indexes online friends, BNet friends (same server), guild members, GreenWall co-guild members (optional dependency), and recently interacted players; session-only recent and co-guild tracking
6. **Merchant Cache** - Built when a merchant window opens, indexes all vendor items for search
7. **Search UI** - Minimalist popup with EditBox for typing and results frame
8. **SecureActionButtons** - Result buttons use SecureActionButtonTemplate for spells (`type="spell"`), items (`type="item"`), and macros (`type="macro"`)
9. **Tradeskill Craft Popup** - Quantity input with reagent display, live bag counts, MAX button, and secure create button
10. **Merchant Search Overlay** - Search bar that appears on merchant windows with buy/quantity functionality
11. **Craft Progress Alert** - Center-screen notification showing remaining craft count with fade animations and cancel detection
12. **Keybind System** - Custom keybind stored in SavedVariables, applied via SetBindingClick on a macro button
13. **Config GUI** - Options panel for settings (opened via `/wofi config`)
14. **Welcome Screen** - First-run setup dialog shown on initial install

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
- `welcomeShown` (boolean) - Whether the first-run welcome screen has been shown
- `tradeskillCache` (table) - Persisted recipe data across sessions for all scanned professions

## Entry Types
Each search result has an `entryType` field:
- `"spell"` - Spellbook spell, uses `btn:SetAttribute("type", "spell")` and `btn:SetAttribute("spell", name)`
- `"item"` - Inventory item, uses `btn:SetAttribute("type", "item")` and `btn:SetAttribute("item", name)`
- `"macro"` - Player macro, uses `btn:SetAttribute("type", "macro")` and `btn:SetAttribute("macro", macroIndex)`
- `"tradeskill"` - Profession recipe, opens craft quantity popup on click (not a secure action itself)
- `"player"` - Online player (friend/BNet/guild/recent), opens whisper via `ChatFrame_SendTell()` (not a secure action)

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

## Config GUI
The config panel (`/wofi config`) includes:
- **Search section**: Checkboxes for include items, include macros, include tradeskills, include players, show all spell ranks
- **Display section**: Max results slider (4-12), show craft progress notification, show merchant search bar
- **Keybind section**: Current binding display, Set/Clear buttons
- Refresh caches button
- Cache stats display (spell/item/macro/recipe/player counts)
- Close button

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

## WoW API Reference

For WoW Classic Anniversary API documentation, patterns, and development workflow, use the `/wow-addon` skill:
```
/wow-addon
```
This loads the shared TBC API reference, common patterns, and gotchas.
