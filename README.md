# Wofi

**Wofi** is an out-of-combat Spotlight/Rofi-style launcher for spells, items, and professions. Search, cast with Enter, or drag to your action bars - a faster alternative to the spellbook for both casting and bar setup.

Built specifically for **TBC Classic Anniversary**.

![Wofi Launcher](https://github.com/clearcmos/Wofi/blob/main/assets/image1.png?raw=true)

---

## Features

- **Fuzzy search** - Type "fb" to find "Fireball", "mana" to find potions and conjured gems
- **Spells, items, and professions** - Search your entire spellbook, usable bag items, and profession abilities in one place
- **Keyboard-driven** - Navigate with arrow keys or Tab, activate with Enter
- **Drag to action bar** - Right-drag any result to place it on your bars
- **Custom keybind** - Set any key combo to open the launcher instantly
- **Smart prioritization** - Exact matches first, then prefix, then contains, then fuzzy
- **Auto-close on combat** - Stays out of your way when the fight starts

---

## Ideal Use Cases

- **Mage teleports/portals** - No need for 12 buttons, just type "iron" for Ironforge
- **Consumables** - Potions, food, bandages, quest items
- **Profession spells** - Cooking fire, fishing, smelting, disenchanting
- **Hunter tracking** - Quickly swap between tracking types
- **Pre-combat buffs** - Find that one buff without hunting through tabs
- **Alts** - When you can't remember where Blizzard put everything

---

## Usage

Type `/wofi` to open the launcher, or use your custom keybind.

1. Start typing a spell or item name
2. Use **Up/Down** or **Tab/Shift+Tab** to navigate
3. Press **Enter** or **click** to cast/use
4. **Right-drag** to place on action bar
5. Press **Escape** to close

### Slash Commands

- `/wofi` - Toggle the launcher
- `/wofi config` - Open configuration GUI
- `/wofi bind` - Set a custom keybind
- `/wofi unbind` - Remove the keybind
- `/wofi items` - Toggle item search on/off
- `/wofi refresh` - Rebuild spell/item cache
- `/wofi help` - Show all commands

---

## Configuration

Open with `/wofi config`:

- **Include items** - Toggle bag item search on/off
- **Keybind** - View, set, or clear your custom hotkey
- **Refresh caches** - Manually rebuild spell/item/profession lists

---

## Limitations

- **Cannot be used during combat** - WoW security restriction, not a bug
- **Auto-closes when combat starts** - Secure frames can't be modified mid-fight

---

## License

MIT License - Open source and free to use.

---

## Feedback & Issues

Found a bug or have a suggestion? Post a comment on CurseForge or open an issue on GitHub: https://github.com/clearcmos/Wofi
