/**
 * MTG TTS relay (Cloudflare Worker)
 *
 * 1. Card images:  GET /<size>/<face>/<x>/<y>/<uuid>.jpg
 *    Scryfall blocks Tabletop Simulator's built-in image downloader, so this
 *    fetches the image from cards.scryfall.io with proper headers and hands it
 *    to TTS. Paths mirror Scryfall's exactly. Cached at Cloudflare for 30 days.
 *
 * 2. Card building:  POST /cards
 *    TTS's Lua engine is very slow at decoding and encoding JSON, which made a
 *    100-card import take well over a minute. This endpoint does that work
 *    instead: it looks the cards up on Scryfall and returns each one as a
 *    ready-to-spawn TTS card, as plain text lines the importer just joins.
 *
 *    Request body:  {"items":[{"name":"Sol Ring","set":"cmm","cn":"1","commander":false}, ...]}
 *                   (up to 75 items; set/cn optional)
 *    Response (text/plain), one line per item, tab-separated:
 *      CARD  <i>  <card JSON template>  <deck CustomDeck entry template>
 *      MISS  <i>  <name>                 (not found on Scryfall)
 *      FIXED <i>  <name>                 (set/number didn't match; default printing used)
 *    Templates contain placeholders the importer fills per copy:
 *      "@@CID1@@" / "@@CID2@@"  card IDs (number, quotes included)
 *      @@ID1@@ / @@ID2@@        custom deck IDs (inside strings)
 *    JSON never contains raw tabs or newlines, so the format is unambiguous.
 *
 * 3. Archidekt decks:  GET /archidekt/<deckId>
 *    Returns a public Archidekt deck as a plain-text decklist, so TTS doesn't
 *    have to decode Archidekt's large JSON.
 *
 * Only Scryfall card image paths, /cards and /archidekt/<id> are accepted, so
 * this can't be used as a general-purpose proxy.
 */

const IMAGE_UPSTREAM = "https://cards.scryfall.io";
const SCRYFALL_COLLECTION = "https://api.scryfall.com/cards/collection";
const USER_AGENT = "MTG-TTS-Table-Relay/1.1";
const CACHE_SECONDS = 60 * 60 * 24 * 30; // 30 days
const MAX_ITEMS = 75;
const CARD_BACK =
  "https://steamusercontent-a.akamaihd.net/ugc/1647720103762682461/35EF6E87970E2A5D6581E7D96A99F8A575B7A15F/";

// /<size>/<face>/<x>/<y>/<uuid>.<ext>
const IMAGE_PATH_RE =
  /^\/(small|normal|large|png|art_crop|border_crop)\/(front|back)\/[0-9a-f]\/[0-9a-f]\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png)$/;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/" || url.pathname === "/health") {
      return new Response("MTG relay OK", { headers: { "Content-Type": "text/plain" } });
    }

    const archidektMatch = url.pathname.match(/^\/archidekt\/(\d+)$/);
    if (archidektMatch) {
      return handleArchidekt(archidektMatch[1]);
    }

    if (url.pathname === "/cards") {
      if (request.method !== "POST") {
        return new Response("POST only", { status: 405 });
      }
      try {
        return await handleCards(request, url.host);
      } catch (err) {
        return new Response("ERROR\t" + String(err && err.message ? err.message : err), {
          status: 500,
          headers: { "Content-Type": "text/plain" },
        });
      }
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405 });
    }
    if (!IMAGE_PATH_RE.test(url.pathname)) {
      return new Response("Not a Scryfall card image path", { status: 404 });
    }
    return handleImage(request, url, ctx);
  },
};

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

async function handleImage(request, url, ctx) {
  // Cache key ignores any query string, so "?123" variants share one entry.
  const cacheKey = new Request(url.origin + url.pathname, { method: "GET" });
  const cache = caches.default;

  let response = await cache.match(cacheKey);
  if (!response) {
    const upstream = await fetch(IMAGE_UPSTREAM + url.pathname, {
      headers: { "User-Agent": USER_AGENT, "Accept": "image/*" },
      cf: { cacheTtl: CACHE_SECONDS, cacheEverything: true },
    });
    if (!upstream.ok) {
      return new Response("Upstream error " + upstream.status, { status: upstream.status });
    }
    const ext = url.pathname.endsWith(".png") ? "png" : "jpeg";
    response = new Response(upstream.body, {
      status: 200,
      headers: {
        "Content-Type": "image/" + ext,
        "Cache-Control": "public, max-age=" + CACHE_SECONDS,
        "Access-Control-Allow-Origin": "*",
      },
    });
    ctx.waitUntil(cache.put(cacheKey, response.clone()));
  }

  if (request.method === "HEAD") {
    return new Response(null, { status: response.status, headers: response.headers });
  }
  return response;
}

// ---------------------------------------------------------------------------
// Card lookup
// ---------------------------------------------------------------------------

const lower = (s) => (s || "").toLowerCase();
const frontName = (name) => lower((name || "").split(/\s*\/\/\s*/)[0]);

function identifierFor(item, nameOnly) {
  const front = (item.name || "").split(/\s*\/\/\s*/)[0];
  if (!nameOnly && item.set && item.cn) return { set: item.set, collector_number: item.cn };
  if (!nameOnly && item.set) return { name: front, set: item.set };
  return { name: front };
}

async function scryfallCollection(identifiers) {
  const res = await fetch(SCRYFALL_COLLECTION, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "User-Agent": USER_AGENT,
    },
    body: JSON.stringify({ identifiers }),
  });
  if (!res.ok) throw new Error("Scryfall returned " + res.status);
  const body = await res.json();
  return body.data || [];
}

function indexCards(cards) {
  const byName = new Map();
  const bySetNum = new Map();
  for (const card of cards) {
    byName.set(lower(card.name), card);
    byName.set(frontName(card.name), card);
    if (card.card_faces && card.card_faces[0]) byName.set(lower(card.card_faces[0].name), card);
    bySetNum.set(lower(card.set) + "#" + lower(card.collector_number), card);
  }
  return { byName, bySetNum };
}

function namesMatch(item, card) {
  const want = frontName(item.name);
  if (lower(card.name) === lower(item.name) || frontName(card.name) === want) return true;
  return !!(card.card_faces && card.card_faces[0] && lower(card.card_faces[0].name) === want);
}

function lookup(item, idx) {
  if (item.set && item.cn) {
    const hit = idx.bySetNum.get(lower(item.set) + "#" + lower(item.cn));
    if (hit && namesMatch(item, hit)) return hit;
  }
  const hit = idx.byName.get(lower(item.name)) || idx.byName.get(frontName(item.name));
  return hit && namesMatch(item, hit) ? hit : null;
}

// ---------------------------------------------------------------------------
// TTS card building (matches the Lua importer's output exactly)
// ---------------------------------------------------------------------------

function imageUrl(uris, host) {
  if (!uris) return null;
  const u = uris.large || uris.normal || uris.png || uris.small;
  if (!u) return null;
  return u.replace(/\?.*$/, "").replace("cards.scryfall.io", host);
}

function faceImage(card, faceIndex, host) {
  if (faceIndex !== null && card.card_faces && card.card_faces[faceIndex]) {
    const img = imageUrl(card.card_faces[faceIndex].image_uris, host);
    if (img) return img;
  }
  return (
    imageUrl(card.image_uris, host) ||
    (card.card_faces && card.card_faces[0] ? imageUrl(card.card_faces[0].image_uris, host) : null)
  );
}

function isDoubleFaced(card) {
  return (
    !card.image_uris &&
    Array.isArray(card.card_faces) &&
    card.card_faces.length >= 2 &&
    !!card.card_faces[0].image_uris
  );
}

function faceFields(card, face) {
  const src = face || card;
  return {
    name: src.name || card.name,
    manaCost: src.mana_cost ?? card.mana_cost ?? "",
    typeLine: src.type_line ?? card.type_line ?? "",
    oracle: src.oracle_text ?? card.oracle_text ?? "",
    power: src.power,
    toughness: src.toughness,
    loyalty: src.loyalty,
  };
}

function splitTypes(typeLine) {
  const main = typeLine.split(/\s+—/)[0];
  return main.split(/\s+/).filter(Boolean);
}

function buildDescription(f) {
  const lines = [];
  lines.push(f.manaCost ? f.typeLine + "  " + f.manaCost : f.typeLine);
  if (f.oracle) lines.push(f.oracle);
  if (f.power != null && f.toughness != null) lines.push(f.power + "/" + f.toughness);
  else if (f.loyalty != null) lines.push("Loyalty: " + f.loyalty);
  return lines.join("\n");
}

function buildCardData(card, f, isCommander) {
  const data = {
    v: 1,
    name: f.name,
    scryfallId: card.id,
    manaCost: f.manaCost,
    cmc: card.cmc || 0,
    typeLine: f.typeLine,
    types: splitTypes(f.typeLine),
    oracle: f.oracle,
    keywords: card.keywords || [],
    colors: card.colors || [],
    colorIdentity: card.color_identity || [],
    isCommander: !!isCommander,
  };
  if (f.power != null) data.power = f.power;
  if (f.toughness != null) data.toughness = f.toughness;
  if (f.loyalty != null) data.loyalty = f.loyalty;
  return data;
}

function customDeckEntry(card, faceIndex, host) {
  return {
    FaceURL: faceImage(card, faceIndex, host),
    BackURL: CARD_BACK,
    NumWidth: 1,
    NumHeight: 1,
    BackIsHidden: true,
    UniqueBack: false,
    Type: 0,
  };
}

function cardObject(card, faceIndex, isCommander, slot, host) {
  const face = faceIndex !== null && card.card_faces ? card.card_faces[faceIndex] : null;
  const f = faceFields(card, face);
  return {
    Name: "Card",
    Transform: { posX: 0, posY: 0, posZ: 0, rotX: 0, rotY: 180, rotZ: 180, scaleX: 1, scaleY: 1, scaleZ: 1 },
    Nickname: f.name,
    Description: buildDescription(f),
    GMNotes: JSON.stringify(buildCardData(card, f, isCommander)),
    CardID: "@@CID" + slot + "@@",
    CustomDeck: { ["@@ID" + slot + "@@"]: customDeckEntry(card, faceIndex, host) },
    Tags: ["MTGCard"],
  };
}

// Returns [cardTemplate, deckEntryTemplate].
function buildTemplates(card, isCommander, host) {
  let obj;
  let deckEntry;
  if (isDoubleFaced(card)) {
    obj = cardObject(card, 0, isCommander, 1, host);
    obj.States = { "2": cardObject(card, 1, isCommander, 2, host) };
    deckEntry = customDeckEntry(card, 0, host);
  } else {
    obj = cardObject(card, null, isCommander, 1, host);
    deckEntry = customDeckEntry(card, null, host);
  }
  // CardID placeholders become bare numbers after the importer fills them.
  const tpl = JSON.stringify(obj);
  const entryTpl = '"@@ID1@@":' + JSON.stringify(deckEntry);
  return [tpl, entryTpl];
}

// ---------------------------------------------------------------------------
// /cards
// ---------------------------------------------------------------------------

async function handleCards(request, host) {
  const body = await request.json();
  const items = Array.isArray(body.items) ? body.items.slice(0, MAX_ITEMS) : [];
  if (items.length === 0) throw new Error("No items");

  // Pass 1: set/number where given, otherwise name.
  let cards = await scryfallCollection(items.map((it) => identifierFor(it, false)));
  let idx = indexCards(cards);

  // Pass 2: anything that didn't resolve to the right name, by name alone.
  const retry = [];
  items.forEach((it, i) => {
    if (!lookup(it, idx)) retry.push(i);
  });
  const fixed = new Set();
  if (retry.length > 0) {
    const more = await scryfallCollection(retry.map((i) => identifierFor(items[i], true)));
    cards = cards.concat(more);
    idx = indexCards(cards);
    for (const i of retry) {
      if (items[i].set && lookup(items[i], idx)) fixed.add(i);
    }
  }

  const lines = [];
  items.forEach((it, i) => {
    const card = lookup(it, idx);
    if (!card) {
      lines.push("MISS\t" + i + "\t" + clean(it.name));
      return;
    }
    if (fixed.has(i)) lines.push("FIXED\t" + i + "\t" + clean(it.name));
    const [tpl, entryTpl] = buildTemplates(card, !!it.commander, host);
    lines.push("CARD\t" + i + "\t" + tpl + "\t" + entryTpl);
  });

  return new Response(lines.join("\n"), {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}

function clean(s) {
  return String(s || "").replace(/[\t\r\n]/g, " ");
}

// ---------------------------------------------------------------------------
// /archidekt/<deckId>
// Fetches a public Archidekt deck and returns it as a plain-text decklist,
// so TTS doesn't have to decode Archidekt's large JSON. Response:
//   200: first line "#NAME<tab><deck name>", then the decklist
//        ("Commander" section, blank line, "Deck" section)
//   403: deck is private; 404: deck not found; other: upstream error
// ---------------------------------------------------------------------------

async function handleArchidekt(id) {
  const res = await fetch("https://archidekt.com/api/decks/" + id + "/", {
    headers: { "Accept": "application/json", "User-Agent": USER_AGENT },
  });
  if (!res.ok) {
    return new Response("Archidekt returned " + res.status, {
      status: res.status === 403 || res.status === 404 ? res.status : 502,
      headers: { "Content-Type": "text/plain" },
    });
  }
  const deck = await res.json();
  const text = archidektToDecklist(deck);
  return new Response("#NAME\t" + clean(deck.name) + "\n" + text, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}

// Same rules as src/archidekt.lua: commander = category with isPremier;
// a card is left out only if every category it's in has includedInDeck false.
function archidektToDecklist(deck) {
  const premier = new Set();
  const excluded = new Set();
  for (const cat of deck.categories || []) {
    if (!cat.name) continue;
    if (cat.isPremier) premier.add(cat.name);
    if (cat.includedInDeck === false) excluded.add(cat.name);
  }

  const commanders = [];
  const main = [];
  for (const entry of deck.cards || []) {
    const card = entry.card || {};
    const name = card.oracleCard && card.oracleCard.name;
    if (!name) continue;
    const cats = entry.categories || [];
    let isCommander = false;
    let inDeck = true;
    if (cats.length > 0) {
      inDeck = false;
      for (const c of cats) {
        if (premier.has(c)) isCommander = true;
        if (!excluded.has(c)) inDeck = true;
      }
    }
    if (!inDeck && !isCommander) continue;

    let line = String(entry.quantity || 1) + " " + clean(name);
    const set = card.edition && card.edition.editioncode;
    if (set) {
      line += " (" + set + ")";
      if (card.collectorNumber) line += " " + card.collectorNumber;
    }
    (isCommander ? commanders : main).push(line);
  }

  return ["Commander", ...commanders, "", "Deck", ...main].join("\n");
}
