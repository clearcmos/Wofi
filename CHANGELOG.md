# Changelog

## v1.2.0

### Added
- **Addon manager** - Search installed addons, click to enable/disable
- **Loot browser** - Browse dungeon/raid loot tables with difficulty selection and expandable tier set groups (requires AtlasLoot)
- Documentation updated for addon manager and loot browser features

### Fixed
- Loot browser expand/collapse state no longer persists across different instances
- Performance: replaced `math.*` and `table.*` calls with pre-localized WoW globals
- Removed dead variable and identical ternary branch in instance cache

## v1.1.1

### Added
- **Reputation search** - Search all faction reputations with standing level and comma-formatted progress; click to open Reputation panel

### Fixed
- Settings panel duplicate elements when scrolling (frame recycling)
- Zone cache missing Outland zones (now walks up to Cosmic root map)

## v1.1.0

### Added
- **Macro search** - Search and run account-wide and character-specific macros
- **Tradeskill crafting** - Search and craft profession recipes directly from the launcher with quantity popup, reagent display, and live bag counts
- **Craft progress alert** - Center-screen notification during multi-craft with cancel detection
- **Merchant search** - Search bar overlay on merchant windows with bulk purchasing
- **Player search** - Find and whisper friends, BNet friends, guild members, and recently interacted players with class icons and source tags
- **GreenWall co-guild integration** - Co-guild members appear with `[coguild]` tag
- **Zone search** - Search any game zone and open it on the World Map
- **Instance lockout search** - Search saved raids and heroics with live reset timers and boss progress; click to open Raid Info panel
- **Quest search** - Search active quests with completion status and Questie-enhanced map navigation
- **Welcome screen** - First-run setup dialog with quick access to options
- **Show all spell ranks** - Option to display all spell ranks vs highest only
- Config GUI moved to native Settings API (ESC > Options > AddOns > Wofi)
- Configurable max results (4-12)
- Toggle options for all search categories

## v1.0.0

- Initial release
