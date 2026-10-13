# MTG Commander table for Tabletop Simulator: handoff (updated 2026-10-13)

## What this is
Andrew is building a fully automated MTG Commander table in Tabletop Simulator (TTS Lua, MoonSharp runtime). Dark neon cyberpunk look, official MTG rules, no house rules. The table PROPOSES and players CONFIRM. The repo is public: C:\Users\User\Desktop\TTS MTG (src/ has ~39 Lua files, plus assets/, relay/worker.js, tools/, TEST_GUIDE.txt).

## Current state
- Script version: **1.63 (Zoo fixes: Mox, Pod, Eldritch, GSZ, Finale, Shared Summons, Crop Rotation, search scroll, mana tile, real table flip)**.
- v1.60-1.63 were made in a Claude Code (cloud) session on 2026-10-12/13 and pushed to the branch `claude/confident-galileo-rrz03m`. Andrew pulls that branch into the PC folder and pushes `main` (`git pull origin claude/confident-galileo-rrz03m`, then `git push`). Check `git log` on the PC first to see whether v1.63 is in.
- Expected chat line after Save & Play: `MTG > Scripts loaded: version 1.63 (Zoo fixes: Mox, Pod, Eldritch, GSZ, Finale, Shared Summons, Crop Rotation, search scroll, mana tile, real table flip)`
- **v1.60-1.63 have NOT been played in TTS yet.** They were syntax-checked and their card-text parsing was tested in a lupa harness only. Be honest about this.
- **Relay:** relay/worker.js changed in v1.61 (multi-part cards keep rules text) and v1.62 (Attraction lit numbers). Andrew redeployed after v1.61 (health page says "MTG relay OK"); a redeploy after v1.62 is NOT confirmed. Decks with Studious First-Year / adventure cards / Attractions must be re-imported after the redeploy.

## What changed on 2026-10-12/13 (v1.60-1.63)
- v1.60 Gandalf, Westward Voyager: "whenever you cast a spell with mana value N or greater" checks the MV (it fired on every spell); each opponent reveals their top card; a shared card type copies the spell (COPY item on the stack) and each opponent draws, otherwise you draw. Spell copies: instant/sorcery copy runs the card's text; a permanent spell's copy becomes a token on the battlefield (`Effects.copySpell`, `Effects.resolveCopy`, stack item field `copyOf`).
- v1.61:
  - Tokens the table removes (Combat.removeCard) now really pass through the graveyard first, so "dies" triggers fire for them (Marionette Apprentice, Blood Artist). "Is put into a graveyard from the battlefield" parses as "dies".
  - Mox Diamond: asks to discard a land, else it goes to the graveyard (v1.63: it always asks, and says so when there's no land in hand).
  - Lithoform Engine / Reverberate: "copy target [permanent / instant or sorcery] spell [you control]" and "copy target activated or triggered ability" copy from the stack (`Effects.copyStack`).
  - Lantern of Insight / Courser of Kruphix: a gold "TOP: <card name>" 3D text label over each affected library (TTS can't show a deck's top card face up without lifting it).
  - Mana tile: banked mana as a big number in each chip (v1.63: letters removed from the art, assets/mana/mana_tile.png, ART_VERSION ?v=3).
  - Multi-part single-image cards (prepare, adventure, split) used to import with NO rules text. Relay and Lua importer now take the first part's text and keep the others in card data `parts`. "Enters prepared": right-click > "Cast prepared: <spell>" (Studious First-Year // Rampant Growth).
- v1.62 Attractions (src/attractions.lua): own face-down deck in a new ATTRACTIONS spot above the library (import and Start Game sort them out of the library); "open an Attraction" and `!attraction`; at the start of your first main phase the table rolls to visit (d6) and puts lit Attractions' Visit abilities on the stack (`!visit`). Lit numbers = card data `lights` from Scryfall attraction_lights (needs the relay redeploy). Only the deck list's Attractions are available (no built-in set).
- v1.63 Zoo deck fixes:
  - Birthing Pod remembers the creature sacrificed while activating (`GameState.data.lastSac`) and searches with its MV + 1; Eldritch Evolution asks you to click the creature to sacrifice, then searches MV + 2 or less (`Effects.sacTutor`).
  - Green Sun's Zenith shuffles itself into the library (`shuffleSelf`); Finale of Devastation asks LIBRARY or GRAVEYARD and searches with the X limit (`searchLibOrYard`); X >= 10 pump is announced, by hand.
  - Shared Summons: search limited to "up to N" and announces each card (search option `reveal`). Crop Rotation: "As an additional cost ..., sacrifice a land/artifact" asks for the permanent (`addlSac`).
  - Library search panel scrolls (the grid inside the VerticalScrollView needs a real `height`, not only preferredHeight).
  - Table flip (`!flip` / TURN OPTIONS): screen animation (red flash, shake, "RAGE QUIT!") plus the real face-up cards and dice are launched and glide back after ~3.5 s. Face-down cards, hands, decks and locked tiles stay. Zones.refresh is paused while `Flip.chaosOn`.

## Website (done)
The public page is live at www.uptight-shelf-smart-flow.com/commander-table.html (repo NutritiousDeath/Shelfsmart-website: commander-table.html reuses js/dashboard-mtg-tts.js, banner img/mtg/tts-table.jpg). Andrew does NOT want any link to his GitHub on the site (the GitHub button code was removed). A Steam Workshop button appears only if WORKSHOP_URL is filled in.

## How to work with Andrew (standing preferences)
- Terminal commands: one per code block, never chained with `&&`.
- Complete files, not diffs.
- Direct communication; flag issues clearly.
- Finish the current phase before the next. "Done right": full automation where possible, and be honest about what cannot be automated.
- With EVERY update give: the git commands (`cd "C:\Users\User\Desktop\TTS MTG"`, `git add -A`, `git commit -m "..."`, `git push`, each in its own code block), a Save & Play note, and the expected chat version line.
- **Write changed files straight into his folder** with mcp__remote-devices__device_commit_files (stagedPath from /mnt/user-data/outputs/<folder>, devicePath `~/Desktop/TTS MTG/src/<file>`; TEST_GUIDE.txt goes in the folder root; use force if the mtime guard complains). Do not just hand over downloads (this was dropped once after a compaction).
- Pinned release/publishing items live in project memory. Do not bring them up until Andrew says the table is ready.

## Open items
1. **Test v1.60-1.63 in TTS** (Zoo deck first: Mox Diamond, Birthing Pod, Eldritch Evolution, Green Sun's Zenith, Finale of Devastation, Shared Summons, Crop Rotation, search scrolling, mana tile, table flip; then Gandalf, Marionette Apprentice, Lithoform Engine, Lantern of Insight, Studious First-Year, Attractions).
2. **Relay redeploy after v1.62** not confirmed (needed for Attraction lit numbers and the multi-part card text).
3. **Birthing Pod**: Andrew's tester saw "nothing to activate". The ability IS parsed (menu should read "Activate: {1}{G/P}, {T}, Sacrifice a crea.."); cause not found. Ask what exactly happened.
4. **Mox Diamond** went straight to the graveyard in the test: only happens when no land is seen in hand. Not reproduced; v1.63 always asks now. Ask which land was in hand if it repeats.
5. **Zoo test (Deck B) results so far**: B1 Wheel of Fortune works; B4 tutors all worked except Shared Summons and Crop Rotation (fixed in v1.63); B5 Worldly/Enlightened works; B6 Gamble works; Chord of Calling works. Continue from B7 onward in TEST_GUIDE.txt (B2 and B3 need a retest with v1.63).
6. Lifelink/trample combat question: Andrew said scrap it (the table already follows the rules).
7. Older items still open: Black Waltz No. 3 (need the chat line), pop-up resolve box question, Cavern of Souls type badge.
8. Possible future: `!attractions random` (build an Attraction deck from Scryfall) was offered, not requested.

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
- Test harness: lupa on Lua 5.5 (`pip install lupa`). It may NOT exist in a new session. A quick one: stub the TTS globals with a metatable that returns dummy tables, `load` effects.lua and triggers.lua, then call `Effects.parse(text, name)`; syntax-check any file with `load(src)`.
- Web research: Scryfall is blocked from the sandbox; use WebSearch then WebFetch (casualplaneswalker.com/card/<slug>/faq worked).

## Delivered history (latest first)
v1.63 Zoo fixes + real table flip | v1.62 Attractions | v1.61 Marionette/tokens dying, Mox Diamond, Lithoform, Lantern, prepared/multi-part cards, mana numbers, rage flip | v1.60 Gandalf + spell copies (all from the Claude Code session, branch claude/confident-galileo-rrz03m) | v1.59 exalted, Sliver labels |
v1.58 Slivers/Cavern/Rabid Bite (output folder v187) | relay patch (v186) | v1.57 Suspend, mana value search, Cavern choice, Sheoldred, Notion Thief, Descent into Avernus, Roaming Throne, hidden planar die spot (v185).
