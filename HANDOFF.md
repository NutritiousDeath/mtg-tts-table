# MTG Commander table for Tabletop Simulator: handoff (written 2026-10-11)

## What this is
Andrew is building a fully automated MTG Commander table in Tabletop Simulator (TTS Lua, MoonSharp runtime). Dark neon cyberpunk look, official MTG rules, no house rules. The table PROPOSES and players CONFIRM. The repo is public: C:\Users\User\Desktop\TTS MTG (src/ has ~38 Lua files, plus assets/, relay/worker.js, tools/, TEST_GUIDE.txt).

## Current state
- Script version in the repo: **1.58 (Sliver abilities for every Sliver, Cavern uncounterable, Rabid Bite)**. Files are written to the PC. The git push is Andrew's step (check `git status` / `git log` first).
- Expected chat line after Save & Play: `MTG > Scripts loaded: version 1.58 (Sliver abilities for every Sliver, Cavern uncounterable, Rabid Bite)`
- **Nothing since v1.53 has been played in real TTS.** Everything is tested only in a lupa (Lua 5.5) harness. Be honest about this.

## How to work with Andrew (standing preferences)
- Terminal commands: one per code block, never chained with `&&`.
- Complete files, not diffs.
- Direct communication; flag issues clearly.
- Finish the current phase before the next. "Done right": full automation where possible, and be honest about what cannot be automated.
- With EVERY update give: the git commands (`cd "C:\Users\User\Desktop\TTS MTG"`, `git add -A`, `git commit -m "..."`, `git push`, each in its own code block), a Save & Play note, and the expected chat version line.
- **Write changed files straight into his folder** with mcp__remote-devices__device_commit_files (stagedPath from /mnt/user-data/outputs/<folder>, devicePath `~/Desktop/TTS MTG/src/<file>`; TEST_GUIDE.txt goes in the folder root; use force if the mtime guard complains). Do not just hand over downloads (this was dropped once after a compaction).
- Pinned release/publishing items live in project memory. Do not bring them up until Andrew says the table is ready.

## Open items
1. **Relay redeploy**: relay/worker.js (v186 patch) fixes "Relay unavailable (HTTP 500: Scryfall returned 429)" on deck import. Andrew must redeploy it to Cloudflare. Not confirmed. Not changed in v1.58.
2. **Black Waltz No. 3**: bug not reproducible in the harness. Need the exact chat line it prints.
3. **Pop-up resolve box**: Andrew asked about it; I listed options and asked which box and which changes. No reply yet.
4. **Cavern of Souls type badge**: I offered an on-card badge showing the chosen type; not built (type shows in the prompt/chat and via right-click > "Choose creature type again").
5. In-TTS testing of v1.53–v1.58 using TEST_GUIDE.txt (Part 1, Part 2, Part 3 decks A–E, Part 4 four-player test). Bugs go to the notes section.

## Sliver deck audit (Sliver Hivelord commander): status
Automatic now: Sliver grants (keywords, triggered, activated, mana) to every Sliver you control; Sliver Legion; Diffusion Sliver; Leeching Sliver; cascade; Cavern of Souls (type enforced, uncounterable); Sliver Hive mana restriction; token makers (Hive Stirrings, Thrumming Hivepool); counterspells; removal; Duress; fetch lands; Cultivate; Prophetic Prism; Rabid Bite (asks power, damage marked by hand).
By hand: Patchwork Banner +1/+1, Herald's Horn, Coldsteel Heart color, Path of Ancestry scry, Distant Melody, Rise of the Dark Realms, Confounding Riddle modes, Celestial Regulator copy, Dregscape unearth, Sliver Overlord gain-control, Spiteful Sliver damage, Timeless Lotus eternalize, Replicating Ring.
Caveat: oracle texts for the non-Sliver tests were written from memory, not checked online. Honored Heirloom and Network Terminal were not tested.

## Technical notes
- TTS/MoonSharp: no goto; define locals before use; `gsub` returns 2 values (wrap in parentheses; never put unparenthesised in table.insert/constructors); avoid lazy/long patterns (use `find(...,1,true)`); no group quantifiers; XML attributes must escape `<` `>`; `printToAll`/`printToColor` go to chat.
- Effects: `Effects.parse(text, name)` returns {actions, notes, conds}; lines without "." or ":" are dropped as keyword-only; executors live in the big if-chain around effects.lua line ~2100–2200, descriptions around ~1540. Prompts: `Effects.askChoice`, `askText`, `askNumber`.
- Triggers: `abilitiesOf` (cache keyed by guid|name|granted lines), `parseTrigger`, `Triggers.onAttack/onCombatDamage/onTargeted`.
- Statics: `Statics.grants(obj)`, `hasGrantedKeyword`, `chosenType/setChosen`, `spellGrantCount`; grant sources cached by `Events.epoch` (bumped on cardMoved/stepStarted).
- Mana: `ManaChips.onTap`, `settleRestricted`; `GameState.data.restrict`, `noCounter[guid]`, `freeCast[guid]`.
- Relay (Cloudflare Worker): routes /health, /cards, /tokens, /moxfield, /archidekt/<id>, image paths; errors return "ERROR\t<msg>" with 500; importer falls back to a slower direct import.
- Test harness: lupa on Lua 5.5 in the old session's scratchpad (tb.py plus t1xx–t241 scripts). It may NOT exist in a new session. If needed, rebuild a small harness; main.lua can be syntax-checked with `load`.
- Web research: Scryfall is blocked from the sandbox; use WebSearch then WebFetch (casualplaneswalker.com/card/<slug>/faq worked).

## Delivered history (latest first)
v1.58 Slivers/Cavern/Rabid Bite (output folder v187) | relay patch (v186) | v1.57 Suspend, mana value search, Cavern choice, Sheoldred, Notion Thief, Descent into Avernus, Roaming Throne, hidden planar die spot (v185).
