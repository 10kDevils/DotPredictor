# Change log — DotPredictor

## 1.0.1
- **Reads your DoTs from the target's debuffs** when the game allows it, so DoTs applied any way count (Misery's Shadow Word: Pain, focus / mouseover casts), refreshes keep their real (pandemic-extended) time, and dispelled or expired DoTs drop off at once. When debuff timings are hidden it falls back to your casts; a debuff seen for the first time without a cast starts its own timer. An empty debuff list only counts as "no DoTs" once the game has shown it lets the addon read debuffs.
- Cast fallback: refreshing a running DoT carries over up to 30% of its duration (pandemic) instead of restarting.
- Channeled spells (Mind Flay, Mind Flay: Insanity, Void Torrent, Mind Sear, Drain Life, Penance, ...) are never counted; channels you cast are also learned automatically.
- Estimate includes haste (DoTs tick faster), your average crit (expected value) and optionally versatility, plus a calibration multiplier (x0.5–2).
- Tooltip reading also understands "X damage every N sec. Lasts Y sec." and "seconds".
- Targets whose ID the game hides no longer share one list: records reset on target change.
- **Visuals:** striped "incoming" fill, a bright line where health is predicted to end, and a pulsing **lethal marker** at the left end of the bar when your DoTs should finish the target (a clipped window onto a copy of the doom bar, so the game does the comparison; health is never read). Five colors.
- **Nameplate overlay** (optional) on your target's nameplate.
- Text: damage + time left, damage, time, or none; inside, above or below the bar (no longer collides with the target's name by default).
- **Settings window** (Options > AddOns > DotPredictor, or `/dp`) with a list of the DoTs it found in your spellbook and the numbers it read. `/dp debug` shows what's tracked right now, `/dp spells` lists your DoTs, `/dp plate` toggles the nameplate.
- Performance: health and debuff events for the target only (was every unit), updater at 10/s only while there's something to draw (2/s otherwise), old records pruned every 10 s.

## 1.0.0
- Red segment on the target frame's health bar from your DoTs' tooltips and cast timers.
