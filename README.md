# Wofi

A Spotlight/Rofi-style spell and item launcher for WoW Classic Era. WoW + Rofi = Wofi.

## Why This Addon?

**The problem:** Your spellbook has dozens of spells, your bags have consumables and utility items, but your action bars have limited space. Utility spells and items don't need instant combat access - but digging through the spellbook or bags every time is tedious.

**The solution:** Wofi gives you a quick keyboard-driven launcher. Press a key, type a few letters, hit Enter. Done.

### Ideal Use Cases

- **Mage teleports/portals** - No need for 12 buttons when you can just type "iron" → Ironforge
- **Consumables** - Potions, food, bandages, quest items
- **Profession spells** - Cooking fire, fishing, smelting, disenchanting
- **Hunter tracking** - Quickly swap between tracking types
- **Pre-combat buffs** - Find that one buff you need without hunting through tabs
- **Alts** - When you can't remember where Blizzard put everything

### Not Designed For

- Combat rotations (action bars + muscle memory are faster)
- Time-sensitive abilities
- Anything you need instant access to mid-fight

This addon solves the "I don't want 6 portal spells on my bars, but I also don't want to dig through my spellbook" problem. That's it. Simple, focused, useful.

## Installation

1. Download and extract to `Interface/AddOns/Wofi`
2. Restart WoW or `/reload`

## Usage

### Opening the Launcher
- Type `/wofi`
- Click the minimap button
- Use your custom keybind (set with `/wofi bind` or via config)

### Casting Spells / Using Items
1. Start typing a spell or item name
2. Use **Up/Down arrows** or **Tab/Shift+Tab** to navigate results
3. Press **Enter** or **click** to cast/use
4. Press **Escape** to close

Items are marked with `[item]` in the results list.

### Commands

| Command | Description |
|---------|-------------|
| `/wofi` | Toggle the launcher |
| `/wofi config` | Open the configuration GUI |
| `/wofi bind` | Set a custom keybind |
| `/wofi unbind` | Remove the keybind |
| `/wofi items` | Toggle item search (on by default) |
| `/wofi refresh` | Rebuild spell/item cache |
| `/wofi minimap` | Toggle minimap button |
| `/wofi help` | Show help |

### Configuration GUI

Open the config panel with `/wofi config` or **right-click** the minimap button. Options include:
- Toggle item search on/off
- Toggle minimap button visibility
- View/set/clear custom keybind
- Refresh spell and item caches

### Tips

- The launcher is **draggable** - position it wherever you like
- Search is substring-based: "mana" finds "Mana Potion", "Conjure Mana Ruby", etc.
- Only **usable** items appear (items with "Use:" effects, quest items, readable items)
- Caches update automatically when you learn spells or your bags change
- Works great in a macro: `/wofi`

## Limitations

- **Cannot be used during combat** - This is a WoW security restriction, not a bug. Secure action buttons cannot be modified mid-combat.
- **Requires clicking or Enter** - Due to WoW's security model, spells/items can only be used via hardware events (clicks/keypresses on secure buttons)

## Technical Details

Built for WoW Classic Era (Interface 11508). Uses `SecureActionButtonTemplate` with `type="spell"` and `type="item"` for secure spell casting and item usage.

## Author

clearcmos

## License

MIT - Do whatever you want with it.
