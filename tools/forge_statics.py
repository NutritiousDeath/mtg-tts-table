"""
Forge static abilities -> src/forge_statics_data.lua (called by tools/forge_triggers.py).

Forge writes each static ability as an "S:" line:

  S:Mode$ Continuous | Affected$ Creature.Other+YouCtrl+Red | AddPower$ 1 | AddToughness$ 1 |
    Description$ Other red creatures you control get +1/+1.

The lines this file can express are written per card as

  <paragraph key>|<kind>|<field>=<value>;...

  C    Continuous: f = who it affects, p / t = +power / +toughness, k = keywords ("flying/haste")
  CA   CantAttack: f = who can't attack
  CB   CantBlock: f = who can't block
  CBB  CantBlockBy: a = attackers that can't be blocked, b = by these blockers ("~" = except by)
  RC   ReduceCost / RaiseCost: f = spells (type words), n = generic mana less (negative: more), w = whose spells

and "<key>|?" for a static the data can't express. The table (statics.lua, combat.lua) uses an
entry only for a rules-text line its own reader didn't understand, so what works stays as it is.

A filter "f" is alternatives joined by ",", each "<type>.<prop>..." with props:
you / opp (controller), other, self, token / nontoken, attacking, W U B R G (color), or a
subtype (elf, goblin...).

Forge is GPL v3; the generated file is derived from it, carries that license and is kept separate.
"""

import collections
import os
import re

from forge_triggers import forge_key, shortest_keys, params, lua_str, SUBTYPES


class Unmapped(Exception):
    pass


TYPES = {"Creature": "creature", "Artifact": "artifact", "Enchantment": "enchantment", "Land": "land",
         "Planeswalker": "planeswalker", "Permanent": "permanent", "Card": "permanent"}
COLORS = {"White": "W", "Blue": "U", "Black": "B", "Red": "R", "Green": "G"}
PROPS = {"YouCtrl": "you", "OppCtrl": "opp", "Other": "other", "StrictlyOther": "other", "Self": "self",
         "token": "token", "nonToken": "nontoken", "attacking": "attacking", "blocking": "blocking"}


def card_filter(expr):
    """Forge's Affected$ / ValidCard$ -> our filter string, or Unmapped."""
    alts = []
    for alt in expr.split(","):
        head, _, rest = alt.strip().partition(".")
        toks = []
        if head in TYPES:
            toks.append(TYPES[head])
        elif head in SUBTYPES:
            toks += ["creature" if head not in ("Equipment", "Aura", "Vehicle") else "permanent", head.lower()]
        else:
            raise Unmapped("affects " + head)
        for p in [x for x in rest.split("+") if x]:
            m = re.fullmatch(r"power(LE|GE)(\d+)", p)
            if p in PROPS:
                toks.append(PROPS[p])
            elif p in COLORS:
                toks.append(COLORS[p])
            elif p in SUBTYPES:
                toks.append(p.lower())
            elif p in ("withFlying", "withoutFlying", "withReach"):
                toks.append({"withFlying": "fly", "withoutFlying": "nofly", "withReach": "reach"}[p])
            elif p.startswith("non") and p[3:] in COLORS:
                toks.append("!" + COLORS[p[3:]])
            elif p.startswith("non") and p[3:] in TYPES:
                toks.append("!" + TYPES[p[3:]])
            elif m:
                toks.append("pow" + ("<=" if m.group(1) == "LE" else ">=") + m.group(2))
            else:
                raise Unmapped("prop " + re.sub(r"[^A-Za-z].*", "", p))
        alts.append(".".join(toks))
    return ",".join(alts)


KEYWORD = re.compile(r"[A-Z][A-Za-z ]*")
CONTINUOUS_KEYS = {"Mode", "Affected", "AddPower", "AddToughness", "AddKeyword", "Description", "EffectZone",
                   "AffectedDefined", "AILogic", "Secondary"}


def continuous(p):
    if set(p) - CONTINUOUS_KEYS:
        raise Unmapped("key " + sorted(set(p) - CONTINUOUS_KEYS)[0])
    if p.get("EffectZone", "Battlefield") != "Battlefield":
        raise Unmapped("from " + p["EffectZone"])
    if "AffectedDefined" in p:
        if p["AffectedDefined"] != "Self":
            raise Unmapped("affects " + p["AffectedDefined"])   # Auras / Equipment: equip.lua
        f = "permanent.self"
    elif "Affected" in p:
        f = card_filter(p["Affected"])
    else:
        raise Unmapped("affects nothing")
    out = {"f": f}
    for k, o in (("AddPower", "p"), ("AddToughness", "t")):
        if k in p:
            if not re.fullmatch(r"[+-]?\d+", p[k]):
                raise Unmapped("amount " + p[k][:10])
            out[o] = int(p[k])
    if "AddKeyword" in p:
        kws = [k.strip() for k in p["AddKeyword"].split("&")]
        if any(not KEYWORD.fullmatch(k) for k in kws):
            raise Unmapped("keyword")
        out["k"] = "/".join(k.lower() for k in kws)
    if len(out) == 1:
        raise Unmapped("nothing added")
    return "C", out


COMBAT_KEYS = {"Mode", "ValidCard", "ValidAttacker", "ValidBlocker", "Description", "EffectZone", "Secondary", "AILogic"}


def combat(p):
    if set(p) - COMBAT_KEYS:
        raise Unmapped("key " + sorted(set(p) - COMBAT_KEYS)[0])
    if p.get("EffectZone", "Battlefield") != "Battlefield":
        raise Unmapped("from " + p["EffectZone"])
    mode = p["Mode"]
    if mode == "CantBlockBy":
        if "ValidAttacker" not in p:
            raise Unmapped("no attacker")
        out = {"a": card_filter(p["ValidAttacker"])}
        if "ValidBlocker" in p:
            out["b"] = card_filter(p["ValidBlocker"])
        return "CBB", out
    if "ValidCard" not in p:
        raise Unmapped("no card")
    kind = {"CantAttack": "CA", "CantBlock": "CB", "CantAttack,CantBlock": "CAB"}[mode]
    return kind, {"f": card_filter(p["ValidCard"])}


MODES = {"Continuous": continuous, "CantAttack": combat, "CantBlock": combat, "CantBlockBy": combat,
         "CantAttack,CantBlock": combat}


def encode(kind, fields):
    return kind + "|" + ";".join("%s=%s" % (k, v) for k, v in fields.items())


def read_faces(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    for part in re.split(r"^ALTERNATE\s*$", text, flags=re.M):
        name, statics, oracle = None, [], ""
        for line in part.splitlines():
            if line.startswith("Name:"):
                name = line[5:].strip()
            elif line.startswith("S:"):
                statics.append(params(line[2:]))
            elif line.startswith("Oracle:"):
                oracle = line[7:].replace("\\n", "\n")
        if name:
            yield name, statics, oracle


def build(cardsfolder, out, commit):
    data = {}
    total = mapped = 0
    ok_modes, bad_modes = collections.Counter(), collections.Counter()
    reasons = collections.defaultdict(collections.Counter)
    for root, _, files in os.walk(cardsfolder):
        for fn in sorted(files):
            if not fn.endswith(".txt"):
                continue
            for name, statics, oracle in read_faces(os.path.join(root, fn)):
                if name.startswith("A-"):
                    continue
                entries, unread = [], []
                for p in statics:
                    desc = p.get("Description", "")
                    key = forge_key(desc, name) if desc else ""
                    if not key:
                        continue
                    total += 1
                    mode = p.get("Mode", "?")
                    try:
                        if mode not in MODES:
                            raise Unmapped("mode")
                        kind, fields = MODES[mode](p)
                    except Unmapped as e:
                        bad_modes[mode] += 1
                        reasons[mode][str(e)] += 1
                        unread.append(key)
                        continue
                    mapped += 1
                    ok_modes[mode] += 1
                    entries.append((key, encode(kind, fields)))
                if entries:
                    others = [forge_key(para, name) for para in oracle.split("\n")]
                    short = shortest_keys([k for k, _ in entries] + unread + [k for k in others if k])
                    data[name] = ([short[k] + "|" + e for k, e in entries]
                                  + [short[k] + "|?" for k in dict.fromkeys(unread) if k not in dict(entries)])
    with open(out, "w", encoding="utf-8") as f:
        f.write("-- Generated by tools/forge_triggers.py (tools/forge_statics.py) from Forge's card scripts\n")
        f.write("-- (https://github.com/Card-Forge/forge, forge-gui/res/cardsfolder, %s).\n" % commit)
        f.write("-- LICENSE: Forge is licensed under the GNU General Public License v3. This file is\n")
        f.write("-- derived from Forge's card scripts and is distributed under the GPL v3 as well; it\n")
        f.write("-- is kept separate from the table's own scripts. Do not edit by hand: re-run the tool.\n")
        f.write("--\n")
        f.write("-- FORGE_STATICS[card name] = entries separated by newlines, each\n")
        f.write("--   <paragraph key>|<kind>|<field>=<value>;...   (kinds: tools/forge_statics.py)\n")
        f.write("-- or <paragraph key>|? when the static can't be expressed (the table reads the text).\n")
        f.write("FORGE_STATICS = {\n")
        for name in sorted(data):
            f.write("  [%s] = %s,\n" % (lua_str(name), lua_str("\n".join(data[name]))))
        f.write("}\n")
    lines = ["Statics: %d of %d static abilities mapped (%.1f%%) on %d cards. Written: %s (%d KB)"
             % (mapped, total, 100.0 * mapped / max(1, total), len(data), os.path.basename(out),
                os.path.getsize(out) // 1024), "", "Mapped, by mode:"]
    for m, n in ok_modes.most_common():
        lines.append("  %6d  %s" % (n, m))
    lines += ["", "Not mapped, by mode (count, then the most common reasons):"]
    for m, n in bad_modes.most_common(40):
        top = ", ".join("%s %d" % (r, c) for r, c in reasons[m].most_common(4))
        lines.append("  %6d  %-22s %s" % (n, m, top))
    return "\n".join(lines)
