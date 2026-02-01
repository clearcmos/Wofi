# Wofi - Claude Code Instructions

## Project Overview
Wofi (WoW + Rofi) is a WoW Classic Anniversary Edition (20505) addon that provides a Spotlight/Rofi-style launcher for spells and usable items. Users can quickly search and cast spells or use items without using action bars or the spellbook/bags.

## Architecture

### Core Files
- `Wofi.toc` - Addon manifest (Interface 20505 for Classic Anniversary)
- `Wofi.lua` - All addon logic in a single file

### Key Components
1. **Spell Cache** - Builds a searchable cache of all non-passive spells from the player's spellbook
2. **Item Cache** - Scans bags for usable items (items with GetItemSpell, quest items, readable items)
3. **Search UI** - Minimalist popup with EditBox for typing and results frame
4. **SecureActionButtons** - Result buttons use SecureActionButtonTemplate for spells (`type="spell"`) and items (`type="item"`)
5. **Keybind System** - Custom keybind stored in SavedVariables, applied via SetBindingClick on a macro button
6. **Config GUI** - Options panel for settings (opened via `/wofi config`)

### WoW API Constraints
- **Spell/item usage requires SecureActionButtonTemplate** - Cannot call CastSpell() or UseItem() directly
- **SetOverrideBindingClick** - Used to bind Enter key to click the selected secure button
- **SetPropagateKeyboardInput** - Required to let Enter key pass through EditBox to the override binding
- **No combat modifications** - Secure frame attributes cannot be changed during combat
- **C_Container API** - Used for bag scanning in Classic Anniversary (not legacy GetContainerItemInfo)
- **Keybind via macro button** - Custom keybind uses SetBindingClick on a SecureActionButton with `type="macro"` and `macrotext="/wofi"`

## SavedVariables
`WofiDB` stores:
- `keybind` (string|nil) - Custom keybind like "ALT-S"
- `includeItems` (boolean) - Whether to include items in search results

## Entry Types
Each search result has an `entryType` field:
- `"spell"` - Spellbook spell, uses `btn:SetAttribute("type", "spell")` and `btn:SetAttribute("spell", name)`
- `"item"` - Inventory item, uses `btn:SetAttribute("type", "item")` and `btn:SetAttribute("item", name)`

## Slash Commands
- `/wofi` - Toggle launcher
- `/wofi config` - Open configuration GUI (aliases: `/wofi options`, `/wofi settings`)
- `/wofi bind` - Set keybind (prompts for key)
- `/wofi unbind` - Remove keybind
- `/wofi items` - Toggle item search
- `/wofi refresh` - Rebuild caches
- `/wofi help` - Show help

## Events Handled
- `ADDON_LOADED` - Initialize SavedVariables, create UI
- `PLAYER_LOGIN` - Build caches, apply keybind
- `LEARNED_SPELL_IN_SKILL_LINE` / `SPELLS_CHANGED` - Rebuild spell cache
- `BAG_UPDATE_DELAYED` - Rebuild item cache
- `PLAYER_REGEN_DISABLED` - Auto-close Wofi when entering combat

## Development Notes
- Uses `BackdropTemplate` for frame backgrounds (required in modern Classic)
- Item cache includes items where `GetItemSpell(itemID)` returns non-nil, or `itemType == "Quest"`, or `info.isReadable`
- Duplicate items (stacks) are deduplicated by itemID
- Results prioritize: exact match > starts with > contains > fuzzy match
- Fuzzy matching finds entries where query characters appear in order (e.g., "fb" matches "Fireball")
- Maximum 8 results displayed
- Items show `[item]` indicator in results, spells show rank (e.g., "Rank 5") if available
- Result buttons use `RegisterForClicks("LeftButtonDown")` for immediate spell/item activation
- Result buttons use `RegisterForDrag("RightButton")` to allow placing spells/items on action bars
- Toggle button uses `RegisterForClicks("AnyDown")` to fire on keypress
- OnShow uses `C_Timer.After(0.02, ...)` to clear stray characters and delay focus

## Config GUI
The config panel (`/wofi config`) includes:
- Checkbox: Include items in search
- Keybind section with current binding display, Set/Clear buttons
- Refresh caches button
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
4. Verify spells show rank (e.g., "Rank 5"), items show `[item]`
5. Use Up/Down arrows or Tab/Shift-Tab to navigate
6. Press Enter or left-click to cast/use
7. Right-drag a result to place spell/item on action bar
8. Test `/wofi items` toggle
9. Verify BAG_UPDATE_DELAYED rebuilds item cache
10. Test `/wofi config` opens GUI
11. Test keybind via config GUI
12. Enter combat - verify Wofi auto-closes with message

## WoW API Reference

For WoW Classic Anniversary API documentation, patterns, and development workflow, use the `/wow-addon` skill:
```
/wow-addon
```
This loads the shared TBC API reference, common patterns, and gotchas.
