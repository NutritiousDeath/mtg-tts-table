"""
Trigger coverage check for the Forge data (tools/forge_triggers.py).

Runs every Forge card that has rules text through triggers.lua (lupa, Lua 5.5, stub TTS globals),
once reading rules text only and once with Forge data first, and reports how many triggered
paragraphs the table recognizes each way. Writes gained.txt / lost.txt / diff.txt to OUTDIR.

Usage: pip install lupa
       python3 tools/forge_coverage.py . <forge>/forge-gui/res/cardsfolder <outdir>
"""
import os, re, sys, json, collections
from lupa import lua55
REPO, CF, OUTDIR = sys.argv[1], sys.argv[2], sys.argv[3]
cards = []
for root, _, files in os.walk(CF):
    for fn in files:
        if not fn.endswith(".txt"): continue
        text = open(os.path.join(root, fn), encoding="utf-8", errors="replace").read()
        for part in re.split(r"^ALTERNATE\s*$", text, flags=re.M):
            name = oracle = None; types = []; kws = []
            for line in part.splitlines():
                if line.startswith("Name:"): name = line[5:].strip()
                elif line.startswith("Oracle:"): oracle = line[7:].replace("\\n", "\n")
                elif line.startswith("Types:"): types = line[6:].split()
                elif line.startswith("K:"): kws.append(line[2:].split(":")[0].strip())
            if name and oracle and not name.startswith("A-"):
                cards.append((name, oracle, types, kws))
L = lua55.LuaRuntime(unpack_returned_tuples=True)
L.execute(r'''
local function dummy() return setmetatable({}, {__index=function(t,k) return function() return nil end end}) end
Events = { on = function() end, emit = function() end, noteError = function() end }
GameState = { data = {} , solo = function() return false end }
CardData = { get = function(o) return o._d or {} end }
setmetatable(_G, {__index=function(t,k) local d=dummy(); rawset(t,k,d); return d end})
''')
for f in ("src/forge_triggers_data.lua", "src/triggers.lua"):
    L.execute(open(REPO + "/" + f, encoding="utf-8").read())
run = L.eval(r'''function(name, oracle, guid, on)
  Triggers.setForge(on)
  local o = { _d = { name = name, oracle = oracle, types = {}, keywords = {} }, getGUID = function() return guid end, getName = function() return name end }
  local miss = {}
  for _, s in ipairs(Triggers.unrecognized(o)) do miss[s] = true end
  local ab = {}
  for _, a in ipairs(Triggers.abilitiesOf(o)) do
    local t = a.trig
    local s = t.kind
    for _, k in ipairs({"step","who","self","orSelf","mine","theirs","once","alone","subject","spellType","nth","dir","equipped","targetsMe"}) do
      if t[k] ~= nil and t[k] ~= false then s = s .. " " .. k .. "=" .. tostring(t[k]) end end
    ab[a.text] = (ab[a.text] and (ab[a.text] .. "; ") or "") .. s
  end
  return miss, ab
end''')
def is_trig(p):
    l = p.lower(); return l.startswith("whenever ") or l.startswith("when ") or l.startswith("at the beginning of t") or l.startswith("at the beginning of y") or l.startswith("at the beginning of e")
tot = b = a = 0
gained, lost, diff = [], [], []
kinds_diff = collections.Counter()
for i, (name, oracle, types, kws) in enumerate(cards):
    paras = [p for p in oracle.split("\n") if is_trig(re.sub(r"\([^)]*\)", "", p).strip())]
    if not paras: continue
    m0, a0 = run(name, oracle, "a%d" % i, False)
    m1, a1 = run(name, oracle, "b%d" % i, True)
    m0 = set(m0[k] and k for k in m0.keys()); m1 = set(k for k in m1.keys())
    a0 = {k: a0[k] for k in a0.keys()}; a1 = {k: a1[k] for k in a1.keys()}
    tot += len(paras); b += len(paras) - len(m0); a += len(paras) - len(m1)
    for p in m0 - m1: gained.append((name, p, a1.get(p, "")))
    for p in m1 - m0: lost.append((name, p, a0.get(p, "")))
    for p in a1:
        if p in a0 and a0[p] != a1[p]:
            diff.append((name, p, a0[p], a1[p]))
            kinds_diff[(a0[p].split()[0], a1[p].split()[0])] += 1
print("All Forge cards: %d trigger paragraphs. Before (text only): %d (%.1f%%). After (Forge first): %d (%.1f%%)." % (tot, b, 100.0*b/tot, a, 100.0*a/tot))
print("Gained %d, lost %d, read differently %d" % (len(gained), len(lost), len(diff)))
print("Differences by kind (text -> Forge):", kinds_diff.most_common(15))
with open(os.path.join(OUTDIR, "gained.txt"), "w") as f:
    for x in gained: f.write("%s: %s\n   -> %s\n" % x)
with open(os.path.join(OUTDIR, "lost.txt"), "w") as f:
    for x in lost: f.write("%s: %s\n   text had: %s\n" % x)
with open(os.path.join(OUTDIR, "diff.txt"), "w") as f:
    for x in diff: f.write("%s: %s\n   text : %s\n   Forge: %s\n" % x)
