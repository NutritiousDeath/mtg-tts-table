--[[
  rulebook.lua
  The Commander rules book: a closed tome lying in an open corner of the table (an AssetBundle,
  tools/unity/MTGRulesBookBuilder.cs) whose glowing COMMANDER title follows the active player's colour
  (cyan before the game), like the fires and the dice tower. Clicking the book, or RULES on a seat's
  console strip, opens a book-style panel only that player sees: chapters down the side, pages to turn,
  and a search box (keywords first, then every page that mentions the word).
  The content is written for players: how Commander works and how this table does it. The working spec
  with the table's status for each rule is the project doc commander-rules.md.
--]]

Rulebook = {}

local BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/"
local BOOK_URL = BASE .. "rules/mtg_rulebook.unity3d?v=1"
local INDEX = { Purple = 0, Cyan = 0, White = 1, Red = 2, Green = 3, Blue = 4 }

---------------------------------------------------------------------------
-- The book's pages
---------------------------------------------------------------------------

local C = "<color=#5AF0FF>"
local G = "<color=#FFD15A>"
local E = "</color>"

local CHAPTERS = {
  { title = "Start here", pages = {
    "<b>Welcome to the table.</b>\n\nThis book covers how Commander works and how this table handles it for you.\n\n"
      .. "- Chapters are on the left. Use PREV / NEXT to turn pages.\n"
      .. "- Type a word in the search box (a keyword like " .. C .. "ward" .. E .. " or " .. C .. "menace" .. E .. ", or anything else) and press FIND.\n"
      .. "- Only you see this panel. Drag it by its edge if it's in the way.\n\n"
      .. "<b>The short version of a game:</b> everyone starts at 40 life with a 100-card deck led by a legendary commander. "
      .. "Play goes clockwise. Last player standing wins.",
    "<b>Who does what</b>\n\nThe table keeps track of a lot for you: life, poison, commander damage, commander tax, the turn and its steps, "
      .. "the stack, priority, many triggered abilities and effects, combat damage, tokens, and the monarch and initiative.\n\n"
      .. "When the table can't do something itself, it says so in chat (\"by hand\") or asks a YES / NO question. "
      .. "When it asks, read the question: it shows exactly what happens for each answer.\n\n"
      .. "If something looks stuck, type " .. C .. "!unstick" .. E .. " in chat. " .. C .. "!errors" .. E .. " lists any script errors to report.",
  } },
  { title = "Table controls", pages = {
    "<b>Your seat</b>\n\n"
      .. "- " .. G .. "Console strip" .. E .. " (table edge): START GAME, TURN OPTIONS, ROLL DICE, RULES.\n"
      .. "- " .. G .. "Tracker" .. E .. " (in front of you): click the heart for +1 life, right-click for -1; the -/+ rings do 1 (right-click: 5). "
      .. "The drop is poison, the crowns are commander damage from each opponent.\n"
      .. "- " .. G .. "Turn strip" .. E .. ": the current step, and who the table is waiting on.\n"
      .. "- " .. G .. "Action tiles" .. E .. " (your right): DRAW, SCRY, MILL, EXILE, UNTAP, TOKENS. "
      .. "EXILE exiles the top card; right-click it to exile until a nonland card.\n"
      .. "- " .. G .. "NEXT STEP / END STEP / END TURN" .. E .. " tiles beside the tracker.\n"
      .. "- " .. G .. "Mana chips" .. E .. " (left of the command zones): tapping lands adds mana; the table spends it when it can.",
    "<b>Cards</b>\n\n"
      .. "- Drop a card from your hand onto your battlefield to " .. C .. "cast" .. E .. " it (it goes on the stack). Lands are just played.\n"
      .. "- Right-click a card for its abilities, counters, equip, and more.\n"
      .. "- Rotate (Q/E) to tap and untap.\n\n"
      .. "<b>The stack</b> (middle of the table)\n\n"
      .. "- " .. G .. "RESOLVE" .. E .. " asks everyone again for the top item. " .. G .. "RESOLVE ALL" .. E .. " works down the whole stack.\n"
      .. "- " .. G .. "YIELD" .. E .. ": you pass on everything until the stack is empty.\n"
      .. "- " .. G .. "COUNTER" .. E .. " counters the top item by hand.",
    "<b>Decks and games</b>\n\n"
      .. "- " .. G .. "Importing" .. E .. ": paste your Archidekt or Moxfield link in the box under a " .. G .. "Deck Importer" .. E
      .. " card and click IMPORT TO MY SEAT (or type " .. C .. "!import <link>" .. E .. "). Importing again replaces your deck.\n"
      .. "- " .. G .. "START GAME" .. E .. " panel: the " .. G .. "format" .. E .. " (Commander or Pauper Commander), the "
      .. G .. "table layout" .. E .. " (4, 3 or 2 players, or Two-Headed Giant) and who goes first.\n"
      .. "- " .. G .. "START" .. E .. " starts, or restarts with the decks on the table (every card goes back into its owner's library).\n"
      .. "- " .. G .. "NEW DECKS" .. E .. " (click twice) ends the game and clears every seat, so everyone can import a new deck.\n"
      .. "- Changing the layout during a game: click the layout twice; it ends the game first.",
    "<b>If something looks wrong</b>\n\n"
      .. "- Can't click a panel, or a panel is missing: " .. C .. "!resync" .. E .. " rebuilds the screen panels for everyone.\n"
      .. "- Your camera is under or outside the table: " .. C .. "!view" .. E .. ".\n"
      .. "- Which version is loaded, and which seat you are: " .. C .. "!seats" .. E .. ".\n"
      .. "- A pop-up nobody can answer: " .. C .. "!unstick" .. E .. ".\n"
      .. "- Script errors to report: " .. C .. "!errors" .. E .. ".",
    "<b>Handy chat commands</b>\n\n"
      .. C .. "!concede" .. E .. "  leave the game (asks first)\n"
      .. C .. "!firevolume off/low/medium/high" .. E .. "  the fireplace crackle\n"
      .. C .. "!forcepass" .. E .. "  stop waiting on someone who's away\n"
      .. C .. "!afk 45" .. E .. "  pop-ups pass by themselves after 45 seconds\n"
      .. C .. "!search" .. E .. "  search your library\n"
      .. C .. "!seat Red" .. E .. "  take a free seat after a disconnect\n"
      .. C .. "!view" .. E .. "  point your camera at your seat\n"
      .. C .. "!unstick" .. E .. "  clear a stuck pop-up\n"
      .. C .. "!import <link>" .. E .. "  import an Archidekt / Moxfield deck\n"
      .. C .. "!format pdh" .. E .. " / " .. C .. "!format commander" .. E .. "  the format (between games)\n"
      .. C .. "!planechase" .. E .. "  Planechase help",
  } },
  { title = "Turn order", pages = {
    "<b>Each turn, in order</b>\n\n"
      .. "1. " .. G .. "Untap" .. E .. ": your permanents untap. Nobody can act.\n"
      .. "2. " .. G .. "Upkeep" .. E .. ": \"at the beginning of your upkeep\" triggers.\n"
      .. "3. " .. G .. "Draw" .. E .. ": you draw a card. (In multiplayer nobody skips the first draw; with two players, or the first 2HG team, the first player does.)\n"
      .. "4. " .. G .. "Main phase 1" .. E .. ": cast spells, play one land.\n"
      .. "5. " .. G .. "Combat" .. E .. ": beginning, attackers, blockers, damage, end.\n"
      .. "6. " .. G .. "Main phase 2" .. E .. "\n"
      .. "7. " .. G .. "End step" .. E .. ": \"at the beginning of the end step\" triggers.\n"
      .. "8. " .. G .. "Cleanup" .. E .. ": discard down to 7; damage wears off; \"until end of turn\" effects end.",
    "<b>Moving through the turn</b>\n\n"
      .. "Click NEXT STEP. Before the step changes, every other player gets a pop-up: " .. G .. "NO RESPONSE" .. E .. " passes, "
      .. G .. "I HAVE A RESPONSE" .. E .. " stops it so they can cast something first.\n\n"
      .. "END TURN runs the rest of the turn by itself (still asking for responses).\n\n"
      .. "<b>Extra turns</b>: the most recently created one is taken first. "
      .. "TURN OPTIONS has extra turn, extra combat, skip a step and reverse turn order.",
  } },
  { title = "Casting and the stack", pages = {
    "<b>Casting a spell</b>\n\n"
      .. "1. Drop it on your battlefield: it goes on the stack.\n"
      .. "2. If it has modes (\"choose one\"), choose them now.\n"
      .. "3. If it says " .. C .. "target" .. E .. ", choose the targets now: click TARGET on a card, or pick a player. "
      .. "The target glows in your colour and the stack list shows it.\n"
      .. "4. Pay for it (the mana chips help).\n\n"
      .. "Abilities work the same way: triggered abilities choose their targets as they go on the stack.",
    "<b>Priority: everyone gets a chance</b>\n\n"
      .. "When something goes on the stack, every other player is asked in turn order: " .. G .. "NO RESPONSE" .. E .. " or " .. G .. "I HAVE A RESPONSE" .. E .. ".\n\n"
      .. "- If everyone passes, the top item " .. C .. "resolves" .. E .. " on its own.\n"
      .. "- If someone responds, their spell goes on top and gets its own round. Last in, first out.\n"
      .. "- After something resolves, the next item down gets a fresh round.\n\n"
      .. "(In a solo test game nobody else is asked: click RESOLVE.)",
    "<b>Holding priority for a response</b>\n\n"
      .. "Clicking " .. G .. "I HAVE A RESPONSE" .. E .. " gives you priority: nothing resolves and the turn doesn't move on until you act. "
      .. "The turn strip shows RESPONSE? WAITING ON you.\n\n"
      .. "- Put your spell or ability on the stack: everyone else is asked about it.\n"
      .. "- Changed your mind: " .. G .. "NO RESPONSE AFTER ALL" .. E .. ".\n"
      .. "- Someone is away: anyone can type " .. C .. "!forcepass" .. E .. ". The hold also ends by itself after 90 seconds.\n\n"
      .. G .. "RESOLVE ALL" .. E .. " stops as soon as anyone says I HAVE A RESPONSE.\n\n"
      .. "A triggered ability with no legal target is removed from the stack by itself.",
    "<b>Fizzling</b>\n\nAs a spell or ability resolves, its targets are checked again. A target is no longer legal if it left the battlefield "
      .. "(even if it came back: it's a new object), stopped being the right kind of thing, or gained hexproof, shroud or protection.\n\n"
      .. "- Some targets still legal: it only affects those.\n"
      .. "- None legal: it does nothing (\"fizzles\"), and a spell goes to the graveyard.\n\n"
      .. "<b>Can't be countered</b>: counter effects do nothing to it.\n"
      .. "<b>Split second</b>: while it's on the stack, nobody can cast spells or activate abilities (except mana abilities).",
    "<b>Ward</b>\n\nWhen an opponent targets a permanent with ward, a ward trigger goes on the stack on top of their spell or ability. "
      .. "When it resolves, they pay the ward cost or their spell or ability is countered.\n\n"
      .. "<b>Triggered abilities</b>\n\n"
      .. "- Triggers wait until the current spell or ability is done, then go on the stack.\n"
      .. "- Several at once: the active player's go on first, then each other player's in turn order (so the last player's resolve first). "
      .. "If you have two or more, the table lets you order yours.\n"
      .. "- \"When X, " .. C .. "if" .. E .. " Y, ...\": it only triggers if Y is true, and Y is checked again when it resolves.",
  } },
  { title = "Combat", pages = {
    "<b>Attacking</b>\n\n"
      .. "- Each attacking creature picks what it attacks: any opponent, or a planeswalker or battle they control. "
      .. "You can attack several players at once.\n"
      .. "- Creatures that came under your control this turn can't attack (summoning sickness) unless they have " .. C .. "haste" .. E .. ".\n"
      .. "- Attacking taps the creature unless it has " .. C .. "vigilance" .. E .. ".\n"
      .. "- " .. C .. "Goaded" .. E .. " creatures must attack, and must attack a player other than the one who goaded them if they can.\n\n"
      .. "<b>Blocking</b>\n\n"
      .. "- Each untapped creature can block one attacker.\n"
      .. "- " .. C .. "Flying" .. E .. " can only be blocked by flying or reach. " .. C .. "Menace" .. E .. " needs two or more blockers.",
    "<b>Combat damage</b>\n\n"
      .. "- Creatures with " .. C .. "first strike" .. E .. " or " .. C .. "double strike" .. E .. " deal damage in an earlier step; double strike deals damage in both.\n"
      .. "- A blocked creature with several blockers assigns lethal damage to each in order, then the rest.\n"
      .. "- " .. C .. "Trample" .. E .. ": damage beyond lethal to the blockers goes to the player.\n"
      .. "- " .. C .. "Deathtouch" .. E .. ": 1 damage is lethal. " .. C .. "Lifelink" .. E .. ": its damage gains you that much life.\n"
      .. "- " .. C .. "Infect" .. E .. " / " .. C .. "toxic" .. E .. ": poison counters.\n\n"
      .. "Combat damage to the " .. G .. "monarch" .. E .. " or the player with the " .. G .. "initiative" .. E .. " steals it.",
  } },
  { title = "Commander rules", pages = {
    "<b>The deck</b>\n\n"
      .. "- 100 cards including your commander (a legendary creature, or a card that says it can be your commander).\n"
      .. "- One copy of each card, except basic lands.\n"
      .. "- " .. C .. "Color identity" .. E .. ": every card must fit your commander's colours, counting mana symbols in its rules text too. "
      .. "(The table warns at the start of a game if a deck doesn't.)\n"
      .. "- " .. C .. "Partner" .. E .. " / " .. C .. "Background" .. E .. " / Friends forever: two commanders, combined colours.\n\n"
      .. "<b>Starting</b>\n\n"
      .. "- 40 life. Your commander starts in the command zone.\n"
      .. "- Mulligans: your first one is free (no card goes to the bottom).",
    "<b>The command zone</b>\n\n"
      .. "- Cast your commander from the command zone. " .. C .. "Commander tax" .. E .. ": {2} more for each time you've already cast it from there this game. "
      .. "The table counts it on the tax tile above each command zone.\n"
      .. "- If your commander would go to your graveyard or exile, you may put it back in the command zone (the table asks). "
      .. "Its \"dies\" triggers still happen.\n"
      .. "- If it would go to your hand or library, you may put it in the command zone instead (the table asks first).\n\n"
      .. "<b>Commander damage</b>\n\n"
      .. "21 or more " .. C .. "combat" .. E .. " damage from a single commander and you lose. Each commander counts separately; it's the crowns on your tracker.",
  } },
  { title = "Winning and losing", pages = {
    "<b>You lose when</b>\n\n"
      .. "- your life is 0 or less,\n"
      .. "- you'd draw from an empty library,\n"
      .. "- you have 10 or more poison counters (15 for a 2HG team),\n"
      .. "- 21 or more combat damage from one commander,\n"
      .. "- a card says so, or you concede.\n\n"
      .. "The table flags a loss on your tracker: " .. G .. "Confirm loss" .. E .. ", or " .. G .. "Dismiss" .. E .. " if something stops it (a replacement effect). "
      .. "Conceding can't be stopped. Type " .. C .. "!concede" .. E .. " or use TURN OPTIONS.",
    "<b>When a player leaves the game</b>\n\n"
      .. "- Everything they own leaves the game: it goes into a bag at their seat.\n"
      .. "- Cards they controlled but didn't own are exiled.\n"
      .. "- Their spells and abilities on the stack go away. Their tokens are gone.\n"
      .. "- Their seat goes dark and turns skip them. The monarch or initiative passes on.\n"
      .. "- If it was their turn, the turn passes on.\n\n"
      .. "Misclick? The tracker's " .. G .. "Undo: back in game" .. E .. " brings them back; their cards are in the bag.\n\n"
      .. "The last player (or team) left wins.",
  } },
  { title = "Multiplayer", pages = {
    "<b>The monarch</b>\n\n"
      .. "Cards like \"you become the monarch\". The monarch draws a card at the beginning of their end step. "
      .. "If a creature deals combat damage to the monarch, its controller becomes the monarch. Shown on the tracker.\n\n"
      .. "<b>The initiative</b>\n\n"
      .. "Taking the initiative (and the start of your upkeep while you have it) " .. C .. "ventures into Undercity" .. E .. ": "
      .. "Secret Entrance, then Forge or Lost Well, and on down to the Throne of the Dead Three. "
      .. "Combat damage to the player with the initiative passes it on. Shown on the tracker.",
    "<b>The legend rule</b>\n\nIf you control two or more legendary permanents with the same name, you choose one and the rest go to the graveyard. "
      .. "(Two players can each have their own copy.)\n\n"
      .. "<b>Turn order and choices</b>\n\nPlay goes clockwise. When several players choose or trigger at once, the active player goes first, "
      .. "then the others in turn order.\n\n"
      .. "<b>Attacking anyone</b>\n\nEvery opponent is fair game, and you can attack several in one combat.",
  } },
  { title = "Planechase", pages = {
    "<b>Planechase</b>\n\n"
      .. "UNPACK on the chest lays out the planar deck, the plane and the dice tower. The plane in play affects everyone.\n\n"
      .. "- On your turn, in a main phase with the stack empty, you may roll the planar die (drop it in the tower). "
      .. "The first roll each turn is free; each extra roll costs 1 more mana.\n"
      .. "- " .. G .. "Blank" .. E .. ": nothing. " .. G .. "Chaos" .. E .. ": the plane's chaos ability goes on the stack. "
      .. G .. "Planeswalk" .. E .. ": PLANESWALK goes on the stack; when it resolves you move to the next plane.\n"
      .. "- The active player controls the planes (\"you\" on a plane means them).\n"
      .. "- " .. C .. "Phenomena" .. E .. " happen once, then the table planeswalks away by itself.\n"
      .. "- Right-click the plane > Planeswalk for cards that say \"planeswalk\".",
    "<b>What the table does for you</b>\n\n"
      .. "- Each plane's abilities go on the stack by themselves: chaos, planeswalking to and away, \"at the beginning of your upkeep\" "
      .. "and the rest, \"whenever a player casts a spell / draws / taps a land\" and so on.\n"
      .. "- Always-on effects apply: anthems (Krosa), keywords (Gavony), who can attack or block (Tazeem), untapping (The Eon Fog), "
      .. "hand size, land drops, tokens and counters doubling, combat damage (Kessig, The Great Forest).\n"
      .. "- " .. G .. "Counters on a plane" .. E .. " (Aretopolis, Pompeii...) show on the plane card.\n"
      .. "- " .. C .. "Spatial Merging" .. E .. ": two planes side by side. Both count, chaos triggers both, the next planeswalk leaves both.\n"
      .. "- Skybreen and Windriddle Palaces turn each library's top card face up beside it.",
    "<b>Buttons on a plane card</b>\n\n"
      .. "Some planes let everyone do something new: click the button on the plane, for yourself.\n\n"
      .. G .. "UNEARTH" .. E .. " (Grixis), " .. G .. "FLASHBACK" .. E .. " (Otaria), " .. G .. "EMBALM" .. E .. " (Naktamun), "
      .. G .. "ESCAPE" .. E .. " (Stormcage), " .. G .. "SCAVENGE" .. E .. " (The Cave of Skulls): pick a card from your graveyard.\n"
      .. G .. "BLITZ" .. E .. " (The Caldaia), " .. G .. "SUSPEND" .. E .. " (Talon Gates), " .. G .. "FORETELL" .. E .. " (Singing Towers): "
      .. "pick a card from your hand.\n"
      .. G .. "CREW" .. E .. " (Ghirapur, New New York): tap creatures to make a Vehicle a creature.\n"
      .. G .. "CONVOKE" .. E .. " (Ood Sphere): tap creatures for mana.\n\n"
      .. "You pay the mana yourself, as for any spell. The table does the rest (haste, exiling afterwards, the token copy, sacrificing at the end step...).",
    "<b>Phasing</b> (Unyaro, The Doctor's Childhood Barn)\n\n"
      .. "A " .. C .. "phased-out" .. E .. " permanent turns grey and is treated as though it doesn't exist: it can't attack, block or be "
      .. "targeted, sweepers and \"each creature\" skip it, it doesn't count, its abilities stop, and it doesn't untap. "
      .. "Auras and Equipment on it phase out too. They phase back in when a player planeswalks.\n\n"
      .. "<b>Still up to you</b>\n\n"
      .. "- Paying mana costs.\n"
      .. "- Playing a card from a revealed top card (Windriddle Palaces) or from exile (The Matrix of Time, Hotel of Fears): drag it.\n"
      .. "- Choosing a new target for a copy as it resolves.",
  } },
  { title = "Pauper Commander", pages = {
    "<b>Pauper Commander (PDH)</b>\n\n"
      .. "Commander with common cards. Pick it in the START GAME panel (FORMAT: PAUPER COMMANDER) or type " .. C .. "!format pdh" .. E .. ".\n\n"
      .. "<b>The deck</b>\n\n"
      .. "- Your " .. G .. "commander" .. E .. " is an " .. C .. "uncommon" .. E .. " creature (or Vehicle or Spacecraft). It doesn't have to be legendary.\n"
      .. "- The other 99 cards are " .. C .. "commons" .. E .. ".\n"
      .. "- A card counts at a rarity if it was ever printed at that rarity on paper or on Magic Online. Arena-only printings don't count.\n"
      .. "- One copy of each card except basic lands, and every card within your commander's colours, as in Commander.",
    "<b>Playing Pauper Commander</b>\n\n"
      .. "- " .. G .. "30 life" .. E .. " (the table sets it; 45 per team in Two-Headed Giant at this table).\n"
      .. "- " .. G .. "16" .. E .. " combat damage from one commander and you lose (the table checks it).\n"
      .. "- Everything else is as in Commander: the command zone, commander tax, the free first mulligan.\n\n"
      .. "<b>Banned</b>\n\n"
      .. "Rhystic Study, Mystic Remora, Conspiracy cards, cards that mention ante, and cards banned in every format.\n\n"
      .. "PDH is run by the PDH Home Base committee; check their site for the current banned list. "
      .. "The table doesn't check card rarity: build your deck to the rules.",
  } },
  { title = "Two-Headed Giant", pages = {
    "<b>Two-Headed Giant</b> (" .. C .. "!layout 2hg" .. E .. ")\n\n"
      .. "- Two teams of two, sitting side by side.\n"
      .. "- Each team shares one life total (60 at this table) and one poison count (15 loses).\n"
      .. "- Teammates take their turn together and attack together.\n"
      .. "- The team that goes first skips its first draw.\n"
      .. "- Each attacking creature's damage goes to one player of the other team.\n"
      .. "- If one player loses, their team loses. Commander damage still counts per player, per commander.\n\n"
      .. "<b>Teams at this table</b>\n\n"
      .. "- Teammates see each other's hands.\n"
      .. "- A team shares priority: the other team gets one question, both of them see it and either can answer.\n"
      .. "- Talk privately in the chat window's " .. G .. "Team" .. E .. " tab.",
  } },
}

-- Keywords A-Z (the search looks here first).
local KEYWORDS = {
  { "Affinity", "Costs {1} less for each of a certain kind of permanent you control." },
  { "Afflict", "When it becomes blocked, the defending player loses that much life." },
  { "Annihilator", "When it attacks, the defending player sacrifices that many permanents." },
  { "Battle cry", "When it attacks, each other attacking creature gets +1/+0." },
  { "Blitz", "Cast it for its blitz cost: haste, draws you a card when it dies, sacrificed at the next end step." },
  { "Cascade", "When you cast it, exile cards from the top of your library until a cheaper nonland card; you may cast that free, the rest go to the bottom." },
  { "Changeling", "It is every creature type." },
  { "Convoke", "Your creatures can help pay: tap one for {1} or one mana of its colour." },
  { "Crew", "Tap creatures with that much total power: this Vehicle becomes a creature until end of turn." },
  { "Cycling", "Pay the cost, discard it: draw a card." },
  { "Deathtouch", "Any damage it deals to a creature is enough to destroy it." },
  { "Defender", "Can't attack." },
  { "Delve", "Exile cards from your graveyard to pay {1} each." },
  { "Demonstrate", "When you cast it, you may copy it; if you do, an opponent you choose copies it too." },
  { "Devour", "As it enters, sacrifice any number of creatures; it gets that many +1/+1 counters for each." },
  { "Double strike", "Deals combat damage in both the first-strike and regular damage steps." },
  { "Embalm", "Exile it from your graveyard and pay: create a token copy, a white Zombie. Sorcery speed." },
  { "Equip", "Attach this Equipment to a creature you control, any time you could cast a sorcery." },
  { "Escape", "Cast it from your graveyard for its escape cost, exiling other cards from your graveyard." },
  { "Exalted", "Whenever a creature you control attacks alone, it gets +1/+1 for each exalted instance." },
  { "Fabricate", "When it enters, put that many +1/+1 counters on it or create that many 1/1 Servos." },
  { "First strike", "Deals combat damage before creatures without first strike." },
  { "Flash", "Can be cast any time you could cast an instant." },
  { "Flashback", "Cast it from your graveyard for its flashback cost, then exile it." },
  { "Flying", "Can only be blocked by creatures with flying or reach." },
  { "Foretell", "Pay {2} and exile it face down from your hand; cast it on a later turn for its foretell cost." },
  { "Goad", "Until your next turn, it must attack each combat, and must attack a player other than you if it can." },
  { "Haste", "Can attack and tap the turn it comes under your control." },
  { "Hexproof", "Can't be the target of spells or abilities your opponents control." },
  { "Indestructible", "Isn't destroyed by damage or \"destroy\" effects. (0 toughness still kills it.)" },
  { "Infect", "Deals damage to creatures as -1/-1 counters and to players as poison counters." },
  { "Kicker", "An optional extra cost for an extra effect." },
  { "Landfall", "Triggers whenever a land enters under your control." },
  { "Lifelink", "Damage it deals also gains you that much life." },
  { "Living weapon", "When this Equipment enters, create a 0/0 black Phyrexian Germ and attach the Equipment to it." },
  { "Menace", "Can't be blocked except by two or more creatures." },
  { "Mentor", "When it attacks, put a +1/+1 counter on an attacking creature with less power." },
  { "Monarch", "Draw a card at the beginning of your end step. Combat damage to you passes it on." },
  { "Morph", "Cast it face down as a 2/2 for {3}; turn it face up any time for its morph cost." },
  { "Ninjutsu", "Return an unblocked attacker you control to hand: put this onto the battlefield tapped and attacking." },
  { "Partner", "You can have two commanders if both have partner." },
  { "Persist", "When it dies without a -1/-1 counter, return it with a -1/-1 counter." },
  { "Phasing", "Phased out: treated as though it doesn't exist until it phases back in." },
  { "Proliferate", "Choose any permanents and players with counters; give each one more of a kind it already has." },
  { "Protection", "Protection from X: can't be Damaged, Enchanted/Equipped, Blocked or Targeted by X (DEBT)." },
  { "Reach", "Can block creatures with flying." },
  { "Rebound", "Cast from your hand, it's exiled as it resolves; at your next upkeep you may cast it free." },
  { "Scavenge", "Exile it from your graveyard and pay: +1/+1 counters equal to its power on target creature. Sorcery speed." },
  { "Scry", "Look at that many cards on top of your library; put any on the bottom, the rest back in any order." },
  { "Shroud", "Can't be the target of any spells or abilities (yours too)." },
  { "Split second", "While it's on the stack, players can't cast spells or activate abilities except mana abilities." },
  { "Storm", "When you cast it, copy it for each spell cast before it this turn." },
  { "Surveil", "Look at that many cards on top; put any into your graveyard, the rest back in any order." },
  { "Suspend", "Exile it with time counters; remove one each upkeep; when the last goes, cast it free." },
  { "Toxic", "Combat damage it deals to a player also gives them that many poison counters." },
  { "Trample", "Combat damage beyond what's lethal to its blockers goes to the player or planeswalker." },
  { "Undying", "When it dies without a +1/+1 counter, return it with a +1/+1 counter." },
  { "Unearth", "Return it from your graveyard to the battlefield with haste; exile it at the next end step or if it would leave." },
  { "Vigilance", "Attacking doesn't tap it." },
  { "Ward", "When an opponent targets it, their spell or ability is countered unless they pay the ward cost." },
  { "Wither", "Deals damage to creatures as -1/-1 counters." },
}

-- The keywords chapter: a few per page.
do
  local per = 8
  local pages = {}
  for i = 1, #KEYWORDS, per do
    local lines = { "<b>Keywords " .. KEYWORDS[i][1]:sub(1, 1) .. "-" .. KEYWORDS[math.min(#KEYWORDS, i + per - 1)][1]:sub(1, 1) .. "</b>\n" }
    for k = i, math.min(#KEYWORDS, i + per - 1) do
      table.insert(lines, G .. KEYWORDS[k][1] .. E .. ": " .. KEYWORDS[k][2])
    end
    table.insert(pages, table.concat(lines, "\n"))
  end
  table.insert(CHAPTERS, { title = "Keywords A-Z", pages = pages })
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

local view = {}       -- [color] = { ch, pg }
local typed = {}      -- [color] = search text

local function show(color)
  local v = view[color] or { ch = 1, pg = 1 }
  view[color] = v
  local ch = CHAPTERS[v.ch]
  if v.search then
    UI.setValue("rbTitle_" .. color, "Search: " .. v.search.q)
    UI.setValue("rbText_" .. color, v.search.text)
    UI.setValue("rbPage_" .. color, "")
    return
  end
  UI.setValue("rbTitle_" .. color, ch.title)
  UI.setValue("rbText_" .. color, ch.pages[v.pg] or "")
  UI.setValue("rbPage_" .. color, "page " .. v.pg .. " of " .. #ch.pages)
  for i = 1, #CHAPTERS do
    pcall(function() UI.setAttribute("rbCh_" .. color .. "_" .. i, "color", i == v.ch and "#1E5A66" or "#141B26") end)
  end
end

function Rulebook.open(color)
  if color == nil or not TableSetup.isActive(color) then
    if color then
      broadcastToColor("Take a seat to open the rules book.", color, { 0.75, 0.8, 0.9 })
    end
    return
  end
  UI.setAttribute("rulebook_" .. color, "active", "true")
  show(color)
end

function Rulebook.close(color)
  UI.setAttribute("rulebook_" .. color, "active", "false")
end

function ui_rulesOpen(player)
  Rulebook.open(player.color)
end

function ui_rulesClose(player)
  Rulebook.close(player.color)
end

function ui_rulesChapter(player, arg)
  local c, i = tostring(arg):match("^(%a+)_(%d+)$")
  if c ~= player.color then
    return
  end
  view[c] = { ch = tonumber(i) or 1, pg = 1 }
  show(c)
end

function ui_rulesPage(player, arg)
  local c, dir = tostring(arg):match("^(%a+)_(%a+)$")
  if c ~= player.color then
    return
  end
  local v = view[c] or { ch = 1, pg = 1 }
  if v.search then
    v.search = nil
  else
    local n = #CHAPTERS[v.ch].pages
    if dir == "next" then
      if v.pg < n then
        v.pg = v.pg + 1
      elseif v.ch < #CHAPTERS then
        v.ch, v.pg = v.ch + 1, 1
      end
    else
      if v.pg > 1 then
        v.pg = v.pg - 1
      elseif v.ch > 1 then
        v.ch = v.ch - 1
        v.pg = #CHAPTERS[v.ch].pages
      end
    end
  end
  view[c] = v
  show(c)
end

function ui_rulesSearchText(player, value)
  typed[player.color] = value
end

local function plain(s)
  return (tostring(s):gsub("<[^>]*>", ""))
end

function ui_rulesFind(player)
  local c = player.color
  local q = tostring(typed[c] or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if q == "" then
    return
  end
  local lq = q:lower()
  local out = {}
  for _, k in ipairs(KEYWORDS) do
    if k[1]:lower():find(lq, 1, true) then
      table.insert(out, G .. k[1] .. E .. ": " .. k[2])
    end
  end
  for _, k in ipairs(KEYWORDS) do
    if not k[1]:lower():find(lq, 1, true) and k[2]:lower():find(lq, 1, true) and #out < 8 then
      table.insert(out, G .. k[1] .. E .. ": " .. k[2])
    end
  end
  local where = {}
  for ci, ch in ipairs(CHAPTERS) do
    if ch.title ~= "Keywords A-Z" then
      for pi, pg in ipairs(ch.pages) do
        if plain(pg):lower():find(lq, 1, true) then
          table.insert(where, ch.title .. " (page " .. pi .. ")")
        end
      end
    end
  end
  local text
  if #out == 0 and #where == 0 then
    text = "Nothing found for \"" .. q .. "\". Try a shorter word."
  else
    text = table.concat(out, "\n")
    if #where > 0 then
      text = text .. (#out > 0 and "\n\n" or "") .. "<b>Also in:</b> " .. table.concat(where, ", ")
    end
    text = text .. "\n\n(PREV or NEXT goes back to the book.)"
  end
  local v = view[c] or { ch = 1, pg = 1 }
  v.search = { q = q, text = text }
  view[c] = v
  show(c)
end

function Rulebook.xml()
  local parts = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    local chs = {}
    for i, ch in ipairs(CHAPTERS) do
      table.insert(chs, ('<Button id="rbCh_%s_%d" onClick="ui_rulesChapter(%s_%d)" preferredHeight="32" color="#141B26" textColor="#E6F1FF" fontSize="14">%s</Button>')
        :format(c, i, c, i, (ch.title:gsub("&", "and"))))
    end
    table.insert(parts, ([[
<Panel id="rulebook_%s" visibility="%s" active="false" width="880" height="660" color="#0B0F17F7" outline="#5AF0FF" outlineSize="2 2"
       allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <HorizontalLayout padding="14 14 14 14" spacing="14" childForceExpandWidth="false">
    <VerticalLayout preferredWidth="220" spacing="5" childForceExpandHeight="false">
      <Text fontSize="20" fontStyle="Bold" color="#5AF0FF" preferredHeight="34" alignment="MiddleCenter">COMMANDER</Text>
      ]] .. table.concat(chs, "\n      ") .. [[

      <InputField id="rbSearch_%s" onValueChanged="ui_rulesSearchText" preferredHeight="34" fontSize="14" placeholder="Search a keyword..." />
      <HorizontalLayout spacing="6" preferredHeight="34">
        <Button onClick="ui_rulesFind" color="#00B3A4" textColor="#06130B" fontStyle="Bold">FIND</Button>
        <Button onClick="ui_rulesClose" color="#2A3346">CLOSE</Button>
      </HorizontalLayout>
    </VerticalLayout>
    <VerticalLayout preferredWidth="610" spacing="8" childForceExpandHeight="false">
      <Text id="rbTitle_%s" fontSize="22" fontStyle="Bold" color="#FFD15A" preferredHeight="34" alignment="MiddleLeft">-</Text>
      <Text id="rbText_%s" fontSize="15" color="#E6F1FF" preferredHeight="518" alignment="UpperLeft">-</Text>
      <HorizontalLayout spacing="8" preferredHeight="36" childForceExpandWidth="false">
        <Button onClick="ui_rulesPage(%s_prev)" preferredWidth="110" color="#1B2333">PREV</Button>
        <Text id="rbPage_%s" preferredWidth="370" fontSize="13" color="#8B98A9" alignment="MiddleCenter">-</Text>
        <Button onClick="ui_rulesPage(%s_next)" preferredWidth="110" color="#1B2333">NEXT</Button>
      </HorizontalLayout>
    </VerticalLayout>
  </HorizontalLayout>
</Panel>
]]):format(c, c, c, c, c, c, c, c))
  end
  return table.concat(parts)
end

---------------------------------------------------------------------------
-- The book on the table
---------------------------------------------------------------------------

local function state()
  GameState.data.table = GameState.data.table or {}
  return GameState.data.table
end

-- An open corner of the table (the Planechase chest has the White/Blue one); 2HG: the west part of the middle band,
-- clear of the deck importer card at the very end (x = -50) and the planar mats near the middle.
-- The book's title reads with its top toward the corner, so it's upright from the middle of the table.
local function spot()
  if TableSetup.layout and TableSetup.layout() == "twohg" then
    return { x = -32, z = 0, yaw = 270 }
  end
  return { x = -38, z = 38, yaw = 315 }
end

local function bookObj()
  local g = state().rulebook
  local o = g and getObjectFromGUID(g)
  if o and not o.isDestroyed() then
    return o
  end
  return nil
end

local function addButton(o)
  pcall(function() o.clearButtons() end)
  o.createButton({
    click_function = "rules_bookClick", function_owner = Global, label = "", tooltip = "Commander rules: click to open",
    position = { 0, 1.35, 0 }, rotation = { 0, 0, 0 }, width = 2400, height = 3400, font_size = 1,
    color = { 0, 0, 0, 0 }, hover_color = { 0.35, 0.94, 1, 0.08 }, press_color = { 0.35, 0.94, 1, 0.16 },
  })
end

function rules_bookClick(obj, color)
  Rulebook.open(color)
end

function Rulebook.ensure()
  local st = state()
  local sp = spot()
  local o = bookObj()
  local co = o and o.getCustomObject()
  if o and co and co.assetbundle == BOOK_URL then
    o.setLock(true)
    o.setPosition({ sp.x, TableSetup.SURFACE_TOP + 0.05, sp.z })
    o.setRotation({ 0, sp.yaw, 0 })
    addButton(o)
    return
  end
  if o then
    o.destruct()
  end
  for _, x in ipairs(getObjectsWithTag("RulesBook")) do
    x.destruct()
  end
  local pos = { sp.x, TableSetup.SURFACE_TOP + 0.05, sp.z }
  local obj = spawnObject({
    type = "Custom_AssetBundle",
    position = pos,
    rotation = { 0, sp.yaw, 0 },
    scale = { 1, 1, 1 },
    sound = false,
    callback_function = function(b)
      b.setLock(true)
      b.setPosition(pos)
      b.setRotation({ 0, sp.yaw, 0 })
      b.setName("Commander Rules")
      b.setDescription("Click to open the rules of the table (only you see it). Also: RULES on your console strip.")
      b.addTag("RulesBook")
      st.rulebook = b.getGUID()
      addButton(b)
      Wait.time(function() Rulebook.setColor(GameState.data.fireColor or "Cyan") end, 2)
    end,
  })
  obj.setCustomObject({ assetbundle = BOOK_URL, type = 0 })
end

-- The title's glow follows the active player's colour (fires.lua calls this); cyan before the game.
function Rulebook.setColor(color)
  local o = bookObj()
  if o == nil then
    return
  end
  local idx = INDEX[color] or 0
  Wait.condition(function()
    if not o.isDestroyed() then
      pcall(function() o.AssetBundle.playLoopingEffect(idx) end)
    end
  end, function()
    return o.isDestroyed() or (o.loading_custom == false and o.AssetBundle ~= nil)
  end, 30)
end
