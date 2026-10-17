"""
Coverage and regression check for the Forge data (tools/forge_triggers.py).

Loads the table's own triggers.lua, effects.lua and stack.lua in lupa (Lua 5.5)
with stub TTS globals and runs every Forge card that has rules text through them:

  triggers  every "When/Whenever/At the beginning..." paragraph: does the table
            watch for it (Triggers.unrecognized), and as what (abilitiesOf)?
  effects   every triggered paragraph and every activated ability's effect:
            what actions does the table carry out (Effects.parseBest, or
            Effects.parse before Forge effects existed)?

Each run is done twice, Forge data off (rules text only) and on, and also
saved as a snapshot (JSON) so two versions of the table can be compared:

  pip install lupa
  python3 tools/forge_coverage.py run   <forge>/forge-gui/res/cardsfolder OUT.json [--decks DECKS.json]
  python3 tools/forge_coverage.py diff  OLD.json NEW.json

DECKS.json: {"decks": {"NAME": [card names]}} to also report those cards separately.
"""

import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def read_cards(cf):
    cards = []
    for root, _, files in os.walk(cf):
        for fn in sorted(files):
            if not fn.endswith(".txt"):
                continue
            text = open(os.path.join(root, fn), encoding="utf-8", errors="replace").read()
            for part in re.split(r"^ALTERNATE\s*$", text, flags=re.M):
                name = oracle = None
                types, kws = [], []
                for line in part.splitlines():
                    if line.startswith("Name:"):
                        name = line[5:].strip()
                    elif line.startswith("Oracle:"):
                        oracle = line[7:].replace("\\n", "\n")
                    elif line.startswith("Types:"):
                        types = line[6:].split()
                    elif line.startswith("K:"):
                        kws.append(line[2:].split(":")[0].strip())
                if name and oracle and not name.startswith("A-"):
                    cards.append({"name": name, "oracle": oracle, "types": types, "keywords": kws})
    return cards


LUA_STUBS = r'''
local function dummy() return setmetatable({}, {__index=function(t,k) return function() return nil end end}) end
Events = { on = function() end, emit = function() end, noteError = function() end }
GameState = { data = {} , solo = function() return false end, player = function() return nil end }
CardData = { get = function(o) return o._d or {} end }
JSON = { decode = function(s) return HARNESS_NOTES[s] end, encode = function() return "" end }
HARNESS_NOTES = {}
Soulbond, Statics, Pile, Ring = false, false, false, false   -- optional modules the code checks for
setmetatable(_G, {__index=function(t,k) local d=dummy(); rawset(t,k,d); return d end})
'''

LUA_RUN = r'''
local FIELDS = { "step", "who", "self", "orSelf", "mine", "theirs", "once", "alone", "subject", "spellType", "nth",
  "dir", "equipped", "targetsMe", "tgt", "combat", "cmd", "commander", "perBlocker", "playedOnly", "spell", "onlyType", "mvMin" }
local AFIELDS = { "who", "n", "query", "where", "kind", "ty", "label", "phrase", "mode", "self", "all" }
local function trigDesc(t)
  local s = tostring(t.kind)
  for _, k in ipairs(FIELDS) do
    if t[k] ~= nil and t[k] ~= false then s = s .. " " .. k .. "=" .. tostring(t[k]) end
  end
  return s
end
local function fxDesc(p)
  if type(p) ~= "table" then return "" end
  local out = {}
  for _, a in ipairs(p.actions or {}) do
    local s = tostring(a.what)
    for _, k in ipairs(AFIELDS) do
      if a[k] ~= nil and type(a[k]) ~= "table" and a[k] ~= false then s = s .. " " .. k .. "=" .. tostring(a[k]) end
    end
    table.insert(out, s)
  end
  return table.concat(out, "; ")
end
local function parse(text, name)
  local ok, p
  if Effects.parseBest then
    ok, p = pcall(Effects.parseBest, text, name)
  else
    ok, p = pcall(Effects.parse, text, name)
  end
  if not ok then return "ERROR " .. tostring(p):sub(1, 80) end
  return fxDesc(p)
end
return function(name, oracle, types, kws, guid, forgeOn)
  if Triggers.setForge then Triggers.setForge(forgeOn) end
  GameState.data.forgeFxOff = not forgeOn or nil
  local d = { name = name, oracle = oracle, types = {}, keywords = {} }
  for i = 1, #types do d.types[i] = types[i] end
  for i = 1, #kws do d.keywords[i] = kws[i] end
  HARNESS_NOTES[guid] = d
  local o = { _d = d, getGUID = function() return guid end, getName = function() return name end,
    getGMNotes = function() return guid end, getDescription = function() return oracle end }
  local miss = {}
  for _, s in ipairs(Triggers.unrecognized(o)) do miss[#miss + 1] = s end
  local trig, fx = {}, {}
  for _, a in ipairs(Triggers.abilitiesOf(o)) do
    trig[a.text] = (trig[a.text] and (trig[a.text] .. "; ") or "") .. trigDesc(a.trig) .. (a.forge and " [F]" or "")
    if fx["T:" .. a.text] == nil then fx["T:" .. a.text] = parse(a.text, name) end
  end
  for _, ab in ipairs(Stack.activatedAbilities(o)) do
    fx["A:" .. ab.effect] = parse(ab.effect, name)
  end
  return miss, trig, fx
end
'''


def is_trig(p):
    l = re.sub(r"\([^)]*\)", "", p).strip().lower()
    return (l.startswith("whenever ") or l.startswith("when ") or l.startswith("at the beginning of t")
            or l.startswith("at the beginning of y") or l.startswith("at the beginning of e"))


def run(cf, out, decks_path=None):
    from lupa import lua55
    L = lua55.LuaRuntime(unpack_returned_tuples=True)
    L.execute(LUA_STUBS)
    for f in ("src/forge_triggers_data.lua", "src/forge_effects_data.lua", "src/triggers.lua", "src/effects.lua",
              "src/stack.lua"):
        p = os.path.join(ROOT, f)
        if os.path.exists(p):
            L.execute(open(p, encoding="utf-8").read())
    go = L.execute(LUA_RUN)
    snap = {}
    for i, c in enumerate(read_cards(cf)):
        rec = {}
        for mode, on in (("text", False), ("forge", True)):
            miss, trig, fx = go(c["name"], c["oracle"], L.table(*c["types"]), L.table(*c["keywords"]),
                                "%s%d" % (mode, i), on)
            rec[mode] = {"miss": [miss[k] for k in sorted(miss.keys())],
                         "trig": {k: trig[k] for k in trig.keys()},
                         "fx": {k: fx[k] for k in fx.keys()}}
        rec["paras"] = sum(1 for p in c["oracle"].split("\n") if is_trig(p))
        snap[c["name"]] = rec
    json.dump(snap, open(out, "w"))
    report(snap, decks_path)


def stats(snap, names, mode):
    paras = seen = fx_total = fx_done = 0
    for n in names:
        r = snap.get(n)
        if not r or r["paras"] == 0 and not r[mode]["fx"]:
            continue
        paras += r["paras"]
        seen += r["paras"] - len(r[mode]["miss"])
        for k, v in r[mode]["fx"].items():
            fx_total += 1
            fx_done += 1 if v and not v.startswith("ERROR") else 0
    return paras, seen, fx_total, fx_done


def report(snap, decks_path=None):
    groups = {"ALL FORGE CARDS": list(snap)}
    if decks_path:
        for k, v in json.load(open(decks_path))["decks"].items():
            groups[k] = v
    for g, names in groups.items():
        p0, s0, f0, d0 = stats(snap, names, "text")
        p1, s1, f1, d1 = stats(snap, names, "forge")
        print("%-16s triggers watched: %5d/%5d (%.1f%%) -> %5d (%.1f%%)   effects carried out: %5d/%5d (%.1f%%) -> %5d/%5d (%.1f%%)"
              % (g, s0, p0, 100.0 * s0 / max(1, p0), s1, 100.0 * s1 / max(1, p1),
                 d0, f0, 100.0 * d0 / max(1, f0), d1, f1, 100.0 * d1 / max(1, f1)))


def diff(old_path, new_path):
    """What changed between two snapshots (both modes): lost/gained recognition and changed readings."""
    old, new = json.load(open(old_path)), json.load(open(new_path))
    for mode in ("text", "forge"):
        lost_t, lost_f, changed_t, changed_f = [], [], [], []
        for n, r in old.items():
            if n not in new:
                continue
            a, b = r[mode], new[n][mode]
            for p in set(b["miss"]) - set(a["miss"]):
                lost_t.append((n, p))
            for k, v in a["fx"].items():
                w = b["fx"].get(k)
                if v and not v.startswith("ERROR") and (not w or w.startswith("ERROR")):
                    lost_f.append((n, k, v, w))
                elif v and w and v != w:
                    changed_f.append((n, k, v, w))
            for k, v in a["trig"].items():
                w = b["trig"].get(k)
                if w and w != v:
                    changed_t.append((n, k, v, w))
        print("== %s mode: %d triggers lost, %d effects lost, %d trigger readings changed, %d effect readings changed"
              % (mode, len(lost_t), len(lost_f), len(changed_t), len(changed_f)))
        for x in lost_t[:40]:
            print("  LOST TRIGGER %s: %s" % (x[0], x[1][:100]))
        for x in lost_f[:40]:
            print("  LOST EFFECT  %s: %s\n     was: %s\n     now: %s" % (x[0], x[1][:90], x[2], x[3]))


if __name__ == "__main__":
    if sys.argv[1] == "run":
        decks = sys.argv[sys.argv.index("--decks") + 1] if "--decks" in sys.argv else None
        run(sys.argv[2], sys.argv[3], decks)
    elif sys.argv[1] == "diff":
        diff(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "report":
        report(json.load(open(sys.argv[2])), sys.argv[3] if len(sys.argv) > 3 else None)
