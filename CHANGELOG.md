# Changelog

## v1.2.0

### Added
- **Player search** - Search and whisper friends, BNet friends, guild members, and recently interacted players
  - Online WoW friends with `[friend]` indicator in green
  - BNet friends on same server with `[bnet]` indicator in blue
  - Online guild members with `[guild]` indicator in green
  - Recently interacted players (whispers, targets, group members) with `[recent]` indicator
  - Class icons from the class atlas texture with per-class tex coords
  - Tooltip shows class-colored name, level, zone, and source
  - Click or Enter to open whisper to that player
  - Debounced cache rebuilds on friend/guild/BNet events
  - Session-only recent player tracking (max 50 entries)
  - Toggle via config GUI checkbox

## v1.1.0

### Added
- **Macro search** - Search and run account-wide and character-specific macros from the launcher
  - Macros show `[macro]` indicator in results with light blue styling
  - Tooltip displays first 5 lines of macro body
  - Right-drag macros to place on action bars
  - Auto-rebuilds on `UPDATE_MACROS` event (create/edit/delete)
  - Toggle via config GUI checkbox
- **Tradeskill crafting** - Search and craft profession recipes directly from the launcher
  - Auto-scans all crafting professions on login to index recipes
  - Shows recipe difficulty color (optimal/medium/easy/trivial) and available count
  - Craft quantity popup with reagent display and live bag count
  - "MAX" button to fill craftable quantity
  - Auto-opens and hides profession window during crafting
  - Recalculates recipe availability on bag changes without reopening professions
  - Persists tradeskill cache across sessions via SavedVariables
- **Craft progress alert** - Center-screen notification during multi-craft operations
  - Shows remaining count as each craft completes
  - Displays "complete!" on finish with fade-out animation
  - Detects cancellation (movement/escape) and silently dismisses
- **Merchant search** - Search bar overlay on merchant windows
  - Fuzzy search across all merchant items
  - Shows item price, stock, and quantity per purchase
  - Click to buy, with quantity popup for bulk purchases
  - Auto-refreshes on merchant inventory updates

### Changed
- Config GUI height increased to accommodate new macro checkbox
- Cache stats now display macro count alongside spells and items
- Help text updated

## v1.0.0

- Initial release
- Spotlight/Rofi-style launcher for spells and usable items
- Fuzzy search matching (e.g., "fb" finds "Fireball")
- SecureActionButton integration for spell casting and item usage
- Keyboard navigation (Up/Down arrows, Tab/Shift-Tab, Enter to activate)
- Right-drag results to action bars
- Configurable keybind via config GUI
- Item search toggle (include/exclude bag items)
- Auto-close on combat
- Slash commands: `/wofi`, `/wofi config`, `/wofi refresh`, `/wofi help`
