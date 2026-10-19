# DotPredictor

Shows on your target's health bar how much health your damage-over-time spells are still going to take. If the segment reaches the left end of the bar, a lethal marker lights up: your DoTs should finish the target.

Built for WoW Forever (interface 16001). Health is hidden from addons in this client, so DotPredictor never reads it: it works out how much damage your DoTs have left and lets the health bar itself draw the comparison.

- Reads your DoTs from the target's debuffs (falls back to your casts when the game hides them), including pandemic refreshes
- Haste, crit and versatility in the estimate, plus a calibration slider
- Striped fill, end-of-health line, lethal marker, five colors
- Target frame and, optionally, the target's nameplate
- Settings in Options > AddOns > DotPredictor (or `/dp`), with a list of the DoTs it understood

## Install

1. Open the [latest release](../../releases/latest) and download `DotPredictor-<version>.zip`.
2. Extract it into your `Interface/AddOns/` folder so you end up with `AddOns/DotPredictor/DotPredictor.toc`.

**WowUp**: *Get Addons → Install from URL* and paste this repository's address.

## Commands

| Command | |
|---|---|
| `/dp` | open the settings |
| `/dp plate` | nameplate overlay on / off |
| `/dp text` | cycle the text: damage + time, damage, time, none |
| `/dp spells` | list the DoTs it found in your spellbook |
| `/dp test <spellId>` | show how a spell's tooltip was read |
| `/dp set <spellId> <total> <seconds>` | fix a spell it reads wrong; `/dp unset <spellId>` removes it |
| `/dp attach [frame]` | use another unit frame's health bar (`/fstack` shows names) |
| `/dp debug` | what's being tracked right now |

Tooltips are read in English. Talents and mastery aren't in tooltips; use the calibration slider if the segment is consistently too long or short.

## License

MIT. See [LICENSE](LICENSE).
