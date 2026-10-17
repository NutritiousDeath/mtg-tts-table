#!/usr/bin/env python3
"""
Forge card scripts -> src/forge_triggers_data.lua (triggered abilities only).

Forge (https://github.com/Card-Forge/forge) describes every card in
forge-gui/res/cardsfolder as a small script. Each triggered ability is a
"T:" line such as

  T:Mode$ ChangesZone | Origin$ Any | Destination$ Battlefield |
    ValidCard$ Creature.Other | TriggerZones$ Battlefield | ...
    TriggerDescription$ Whenever another creature enters, you gain 1 life.

This tool reads those lines and turns the ones it can express into the
trigger tables src/triggers.lua already understands (kind, subjects, mine,
who, step...). The table prefers this data and falls back to reading the
rules text for anything that isn't in it.

Usage:
  git clone --depth 1 --filter=blob:none --sparse https://github.com/Card-Forge/forge.git forge
  git -C forge sparse-checkout set forge-gui/res/cardsfolder forge-gui/res/lists
  python3 tools/forge_triggers.py forge/forge-gui/res/cardsfolder [--out src/forge_triggers_data.lua]

It prints the Forge trigger modes it could not map, with counts and the main
reasons, so the next ones to support are easy to pick.

Forge's card scripts are licensed under the GPL (version 3). The generated
data file is derived from them, so it carries that license and is kept as a
separate file.
"""

import argparse
import collections
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# Reading Forge scripts
# ---------------------------------------------------------------------------


def faces(path):
    """Each face of a card file: (name, [trigger param dicts])."""
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    out = []
    for part in re.split(r"^ALTERNATE\s*$", text, flags=re.M):
        name, trigs, types = None, [], set()
        for line in part.splitlines():
            if line.startswith("Name:"):
                name = line[5:].strip()
            elif line.startswith("Types:"):
                types = {w.lower() for w in line[6:].split()}
            elif line.startswith("T:"):
                trigs.append(params(line[2:]))
        if name:
            out.append((name, trigs, types))
    return out


def params(line):
    """'Mode$ X | ValidCard$ Y' -> {'Mode': 'X', 'ValidCard': 'Y'}."""
    p = {}
    for chunk in line.split(" | "):
        if "$" not in chunk:
            continue
        k, v = chunk.split("$", 1)
        p[k.strip()] = v.strip()
    return p


# ---------------------------------------------------------------------------
# Matching key: lets the table pair a Forge trigger with the rules-text
# paragraph it belongs to. The same function is in triggers.lua (forgeKey);
# keep the two identical.
# ---------------------------------------------------------------------------

SELF_WORDS = ["this creature", "this permanent", "this artifact", "this enchantment", "this land",
              "this planeswalker", "this card", "this token", "this vehicle", "this case", "this class",
              "this saga", "this aura", "this equipment", "cardname", "nickname"]


def forge_key(text, name):
    s = text.lower()
    s = re.sub(r"\([^)]*\)", "", s)          # reminder text
    s = s.replace("enters the battlefield", "enters")
    s = s.replace("whenever", "when")           # Forge's descriptions mix the two
    names = [name.lower()]
    if "," in name:
        names.append(name.split(",")[0].lower())
    for n in names + SELF_WORDS:
        if len(n) > 1:
            s = s.replace(n, "")
    return re.sub(r"[^a-z]", "", s)[:64]


def shortest_keys(keys, start=12):
    """Cut a card's paragraph keys to the shortest length that still tells them apart.
    The table compares by prefix, so a short key is enough."""
    distinct = sorted(set(keys))
    n = start
    while n < 64 and len({k[:n] for k in distinct}) < len(distinct):
        n += 1
    return {k: k[:n] for k in distinct}


# ---------------------------------------------------------------------------
# Forge filters ("ValidCard$ Creature.Other+YouCtrl,Card.Self") -> our fields
# ---------------------------------------------------------------------------

CARD_TYPES = {"creature", "land", "artifact", "enchantment", "planeswalker", "permanent", "battle"}

# Real subtypes (Forge's res/lists/TypeLists.txt), so "Creature.Goblin" is read as a Goblin and
# properties like "HasCounters" or "ChosenType" aren't mistaken for one. Filled in main().
SUBTYPES = set()


def load_subtypes(path):
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if line and not line.startswith("["):
            SUBTYPES.add(line.split(":")[0])

# Properties that are conditions the players check when the trigger is
# proposed ("if it was kicked"): the trigger is still the same trigger.
SELF_CONDITIONS = {"kicked", "wasCastByYou", "wasCastFromYourHandByYou", "wasCast", "wasNotCast",
                   "notkicked", "foretold", "evoked", "IsSaddled", "unearthed", "blitzed", "dashed"}


class Unmapped(Exception):
    pass


def card_filter(expr, own=None):
    """Parse a ValidCard-style filter. Returns dict:
       self (bool: only this card), orSelf, subjects [our subject words],
       mine, theirs, nontoken, tokenOnly, excludes [types]."""
    out = {"self": False, "orSelf": False, "subjects": [], "mine": False, "theirs": False,
           "nontoken": False, "tokenOnly": False, "excludes": []}
    others = []
    for alt in expr.split(","):
        alt = alt.strip()
        if not alt:
            continue
        head, _, rest = alt.partition(".")
        props = [p for p in rest.split("+") if p] if rest else []
        if head in ("Card", "Creature", "Permanent") and "Self" in props:
            extra = [p for p in props if p != "Self" and p not in SELF_CONDITIONS]
            if extra:
                raise Unmapped("self prop " + extra[0])
            out["orSelf"] = True
            continue
        others.append((head, props))
    if not others:
        if not out["orSelf"]:
            raise Unmapped("empty filter")
        out["self"], out["orSelf"] = True, False
        return out
    flagsets = []
    needs = []                                # per alternative: the words the card itself would need
    for head, props in others:
        f = {"mine": False, "theirs": False, "nontoken": False, "tokenOnly": False}
        sub = None
        excl = []
        for p in props:
            if p == "YouCtrl":
                f["mine"] = True
            elif p == "OppCtrl":
                f["theirs"] = True
            elif p in ("White", "Blue", "Black", "Red", "Green", "Colorless", "MultiColor", "MonoColor"):
                raise Unmapped("color")
            elif p == "OppOwn":
                raise Unmapped("owner")             # owner, not controller: our triggers only know controllers
            elif p in ("Other", "YouOwn"):
                pass                          # "another": our matchers already skip the card itself
            elif p in ("!token", "nonToken"):
                f["nontoken"] = True
            elif p == "token":
                f["tokenOnly"] = True
            elif p.startswith("non") and p[3:].lower() in CARD_TYPES:
                excl.append(p[3:].lower())
            elif p in SUBTYPES:
                if sub:
                    raise Unmapped("two subtypes")
                sub = "sub:" + p.lower()      # Creature.Dragon = a Dragon creature
            else:
                raise Unmapped("prop " + re.sub(r"[^A-Za-z!_].*", "", p))
        h = head.lower()
        if sub:
            subj = sub
        elif h == "card":
            subj = "permanent"
        elif h in CARD_TYPES:
            subj = "sub:battle" if h == "battle" else h
        elif head in SUBTYPES:
            subj = "sub:" + h                 # Dragon.YouCtrl
        else:
            raise Unmapped("head " + head)
        if subj not in out["subjects"]:
            out["subjects"].append(subj)
        need = {w for w in (h, sub[4:] if sub else None) if w and w not in ("card", "permanent")}
        if f["tokenOnly"]:
            need.add("token")                 # the card itself is never a token
        needs.append(need)
        for e in excl:
            if e not in out["excludes"]:
                out["excludes"].append(e)
        flagsets.append(f)
    # Our triggers carry one set of flags for every subject.
    if any(fs != flagsets[0] for fs in flagsets):
        raise Unmapped("mixed controller/token flags")
    out.update(flagsets[0])
    # Without "Other", the card itself counts too ("Whenever a creature enters") - when it is one.
    # (Never for "an opponent controls": the card is yours.)
    if not any("Other" in props for _, props in others) and not out["self"] and own is not None and not out["theirs"]:
        if any(need <= own for need in needs):
            out["orSelf"] = True
    return out


def subject_fields(f, trig):
    if f["self"]:
        trig["self"] = True
        return trig
    if f["orSelf"]:
        trig["orSelf"] = True
    trig["s"] = "/".join(f["subjects"])
    for k in ("mine", "theirs", "nontoken", "tokenOnly"):
        if f[k]:
            trig[k] = True
    if f["excludes"]:
        trig["x"] = "/".join(f["excludes"])
    return trig


def who_of(player, field="ValidPlayer"):
    """'You' / 'Opponent' / 'Player' (or nothing) -> you / opp / each."""
    if player in (None, "", "Player", "Any"):
        return "each"
    if player == "You":
        return "you"
    if player in ("Opponent", "Player.Opponent", "Player.OppCtrl"):
        return "opp"
    raise Unmapped(field + " " + player)


def on_battlefield(p):
    z = p.get("TriggerZones")
    if z not in (None, "Battlefield"):
        raise Unmapped("TriggerZones " + z)


STEPS = {"Upkeep": "upkeep", "Draw": "draw", "Main1": "main1", "Main2": "main2", "Main": "main",
         "BeginCombat": "combat", "EndCombat": "endcombat", "End of Turn": "end", "End": "end"}

SPELL_TYPES = {
    "Card": None, "Card.YouCtrl": None, "Card.OppCtrl": None, "Spell": None,
    "Card.nonCreature": "noncreature", "Card.nonCreature+YouCtrl": "noncreature",
    "Instant,Sorcery": "instant or sorcery", "Card.Instant,Card.Sorcery": "instant or sorcery",
    "Instant.YouCtrl,Sorcery.YouCtrl": "instant or sorcery",
    "Card.Colorless": "colorless", "Card.MultiColor": "multicolored",
}
for _t in ("Creature", "Artifact", "Enchantment", "Planeswalker", "Instant", "Sorcery", "Land", "Battle"):
    SPELL_TYPES[_t] = _t.lower()
    SPELL_TYPES[_t + ".YouCtrl"] = _t.lower()
    SPELL_TYPES["Card." + _t] = _t.lower()
for _c in ("White", "Blue", "Black", "Red", "Green"):
    SPELL_TYPES["Card." + _c] = _c.lower()
    SPELL_TYPES["Card." + _c + "+YouCtrl"] = _c.lower()


def count_ge(v):
    m = re.fullmatch(r"EQ(\d+)", v or "")
    if not m:
        raise Unmapped("count " + str(v))
    return int(m.group(1))


IGNORED_KEYS = {"Mode", "Execute", "TriggerDescription", "TriggerZones", "OptionalDecider", "Secondary",
                "IsPresent", "PresentCompare", "PresentZone", "PresentPlayer", "CheckSVar", "SVarCompare",
                "NoResolvingCheck", "ActivationLimit", "Static", "CheckDefinedPlayer", "Delirium",
                "Threshold", "Metalcraft", "Hellbent", "Revolt", "Morbid", "IsPresent2", "PresentCompare2",
                "TriggerController", "AILogic", "CheckSVar2", "SVarCompare2", "Ferocious", "Raid",
                "PlayerTurn", "NotPlayerTurn"}
# Keys the mode-specific code reads.
USED_KEYS = {
    "ChangesZone": {"Origin", "Destination", "ValidCard"},
    "Phase": {"Phase", "ValidPlayer"},
    "SpellCast": {"ValidCard", "ValidActivatingPlayer", "ActivatorThisTurnCast", "OpponentTurn"},
    "Attacks": {"ValidCard", "Alone", "Attacked"},
    "AttackersDeclared": {"AttackingPlayer"},
    "DamageDone": {"ValidSource", "ValidTarget", "CombatDamage"},
    "DamageDoneOnce": {"ValidSource", "ValidTarget", "CombatDamage"},
    "Blocks": {"ValidCard"},
    "AttackerBlocked": {"ValidCard"},
    "Drawn": {"ValidCard", "Number"},
    "LifeGained": {"ValidPlayer"},
    "LifeLost": {"ValidPlayer"},
    "BecomesTarget": {"ValidTarget", "ValidSource"},
}


def map_trigger(p, own=None):
    """One Forge trigger -> our trigger dict (short field names), or raise Unmapped."""
    mode = p.get("Mode", "?")
    if mode not in USED_KEYS:
        raise Unmapped("mode")
    extra = set(p) - IGNORED_KEYS - USED_KEYS[mode]
    if extra:
        raise Unmapped("key " + sorted(extra)[0])

    if mode == "ChangesZone":
        dest, origin = p.get("Destination"), p.get("Origin", "Any")
        f = card_filter(p.get("ValidCard", "Card.Self"), own)
        if not f["self"]:
            on_battlefield(p)
        if dest == "Battlefield" and origin == "Any":
            return subject_fields(f, {"kind": "enters"})
        if dest == "Graveyard" and origin == "Battlefield":
            return subject_fields(f, {"kind": "dies"})
        raise Unmapped("zones %s->%s" % (origin, dest))

    if mode == "Phase":
        on_battlefield(p)
        ph = p.get("Phase", "")
        if ph not in STEPS:
            raise Unmapped("phase " + ph)
        return {"kind": "step", "step": STEPS[ph], "who": who_of(p.get("ValidPlayer"))}

    if mode == "SpellCast":
        vc = p.get("ValidCard", "Card")
        if vc == "Card.Self":
            return {"kind": "castSelf"}
        on_battlefield(p)
        if vc not in SPELL_TYPES:
            raise Unmapped("spell " + vc)
        t = {"kind": "cast", "who": who_of(p.get("ValidActivatingPlayer"), "ValidActivatingPlayer")}
        if SPELL_TYPES[vc]:
            t["spellType"] = SPELL_TYPES[vc]
        if "ActivatorThisTurnCast" in p:
            n = count_ge(p["ActivatorThisTurnCast"])
            if t["who"] == "opp" and n == 1:
                t["first"] = True
            elif t["who"] == "you":
                t["nth"] = n
            else:
                raise Unmapped("nth for " + t["who"])
        if p.get("OpponentTurn") == "True":
            t["oppTurn"] = True
        return t

    if mode == "Attacks":
        vc = p.get("ValidCard", "")
        attacked = p.get("Attacked")
        if attacked and attacked != "You":
            raise Unmapped("attacked " + attacked)
        if vc in ("Card.EquippedBy", "Card.AttachedBy", "Creature.EquippedBy", "Card.EnchantedBy",
                  "Creature.EnchantedBy"):
            return {"kind": "attacks", "equipped": True}
        f = card_filter(vc)
        if attacked == "You":
            if f["self"] or f["mine"]:
                raise Unmapped("attacked you by own")
            return {"kind": "attacks", "targetsMe": True}
        if f["self"]:
            return {"kind": "attacks", "self": True}
        on_battlefield(p)
        if not f["mine"] or f["theirs"] or f["tokenOnly"]:
            raise Unmapped("attacker not yours")
        t = {"kind": "attacks", "mine": True}
        subs = [s for s in f["subjects"] if s.startswith("sub:")]
        if subs:
            if len(subs) > 1 or len(f["subjects"]) > 1:
                raise Unmapped("several attacker types")
            t["onlyType"] = subs[0][4:]
        if p.get("Alone") == "True":
            t["alone"] = True
        return t

    if mode == "AttackersDeclared":
        on_battlefield(p)
        if p.get("AttackingPlayer") != "You":
            raise Unmapped("attacking " + str(p.get("AttackingPlayer")))
        return {"kind": "attacks", "mine": True, "once": True}

    if mode in ("DamageDone", "DamageDoneOnce"):
        if p.get("CombatDamage") != "True":
            raise Unmapped("noncombat damage")
        if p.get("ValidTarget") not in ("Player", "Opponent", "Player.Opponent"):
            raise Unmapped("damage to " + str(p.get("ValidTarget")))
        vs = p.get("ValidSource", "")
        if vs in ("Creature.EquippedBy", "Card.AttachedBy", "Card.EquippedBy", "Creature.EnchantedBy",
                  "Card.EnchantedBy"):
            return {"kind": "combatDamage", "equipped": True}
        f = card_filter(vs)
        if f["self"]:
            if mode == "DamageDoneOnce":
                raise Unmapped("once self")
            return {"kind": "combatDamage", "self": True}
        on_battlefield(p)
        if not f["mine"] or f["theirs"] or f["tokenOnly"] or f["excludes"]:
            raise Unmapped("damage source not yours")
        t = {"kind": "combatDamage", "mine": True}
        subs = [s for s in f["subjects"] if s != "creature"]
        if subs:
            t["s"] = "/".join(subs)
        if mode == "DamageDoneOnce":
            t["once"] = True
        return t

    if mode in ("Blocks", "AttackerBlocked"):
        vc = p.get("ValidCard", "")
        kind = "blocks" if mode == "Blocks" else "blocked"
        if mode == "Blocks" and vc in ("Card.EquippedBy", "Creature.EquippedBy", "Card.AttachedBy", "Card.EnchantedBy"):
            return {"kind": "blocks", "equipped": True}
        if card_filter(vc)["self"]:
            return {"kind": kind, "self": True}
        raise Unmapped(kind + " " + vc)

    if mode == "Drawn":
        on_battlefield(p)
        vc = p.get("ValidCard", "Card")
        who = {"Card.YouCtrl": "you", "Card.YouOwn": "you", "Card.OppOwn": "opp", "Card.OppCtrl": "opp",
               "Card": "each"}.get(vc)
        if not who:
            raise Unmapped("drawn " + vc)
        t = {"kind": "draw", "who": who}
        if "Number" in p:
            t["nth"] = int(p["Number"])
        return t

    if mode in ("LifeGained", "LifeLost"):
        on_battlefield(p)
        who = who_of(p.get("ValidPlayer"))
        if who == "each":
            raise Unmapped("life each")
        return {"kind": "life", "dir": "gain" if mode == "LifeGained" else "loss", "who": who}

    if mode == "BecomesTarget":
        if not card_filter(p.get("ValidTarget", ""))["self"]:
            raise Unmapped("targeted other")
        src = p.get("ValidSource", "")
        t = {"kind": "targeted", "self": True}
        if "OppCtrl" in src:
            t["opp"] = True
        elif src and "YouCtrl" in src:
            raise Unmapped("targeted by you")
        return t

    raise Unmapped("mode")


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

FIELD_ORDER = ["self", "orSelf", "s", "x", "mine", "theirs", "nontoken", "tokenOnly", "who", "step", "spellType",
               "nth", "first", "oppTurn", "once", "alone", "onlyType", "equipped", "targetsMe", "dir", "opp"]


def encode(trig):
    """{'kind': 'enters', 's': 'creature', 'mine': True} -> 'enters|s=creature;mine'."""
    parts = []
    for k in FIELD_ORDER:
        if k not in trig:
            continue
        v = trig[k]
        parts.append(k if v is True else "%s=%s" % (k, v))
    return trig["kind"] + "|" + ";".join(parts)


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cardsfolder")
    ap.add_argument("--types", help="Forge's res/lists/TypeLists.txt (default: next to cardsfolder)")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "src", "forge_triggers_data.lua"))
    args = ap.parse_args()
    load_subtypes(args.types or os.path.join(args.cardsfolder, "..", "lists", "TypeLists.txt"))

    commit = "unknown"
    try:
        commit = subprocess.run(["git", "-C", args.cardsfolder, "log", "-1", "--format=%h %ad", "--date=short"],
                                capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        pass

    data = {}                                  # name -> [entry string]
    total = mapped = 0
    unmapped_modes = collections.Counter()
    reasons = collections.defaultdict(collections.Counter)
    for root, _, files in os.walk(args.cardsfolder):
        for fn in sorted(files):
            if not fn.endswith(".txt"):
                continue
            for name, trigs, own in faces(os.path.join(root, fn)):
                if name.startswith("A-"):
                    continue                  # Arena-only rebalanced versions: never in a paper deck
                key = ""
                entries = []
                unread = []
                for p in trigs:
                    total += 1
                    desc = p.get("TriggerDescription", "")
                    # A Secondary trigger often has no text of its own: same paragraph as the one before.
                    k = forge_key(desc, name) if desc else key
                    key = k or key
                    try:
                        t = map_trigger(p, own)
                    except Unmapped as e:
                        unmapped_modes[p.get("Mode", "?")] += 1
                        reasons[p.get("Mode", "?")][str(e)] += 1
                        if key:
                            # The table reads this paragraph's text instead of using half of it.
                            unread.append(key)
                        continue
                    if not key:
                        unmapped_modes[p.get("Mode", "?")] += 1
                        reasons[p.get("Mode", "?")]["no description"] += 1
                        continue
                    mapped += 1
                    entries.append((key, encode(t)))
                if entries:
                    short = shortest_keys([k for k, _ in entries] + unread)
                    data[name] = [short[k] + "|" + e for k, e in entries] + [short[k] + "|?" for k in dict.fromkeys(unread)]

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("-- Generated by tools/forge_triggers.py from Forge's card scripts\n")
        f.write("-- (https://github.com/Card-Forge/forge, forge-gui/res/cardsfolder, %s).\n" % commit)
        f.write("-- LICENSE: Forge is licensed under the GNU General Public License v3. This file is\n")
        f.write("-- derived from Forge's card scripts and is distributed under the GPL v3 as well; it\n")
        f.write("-- is kept separate from the table's own scripts. Do not edit by hand: re-run the tool.\n")
        f.write("--\n")
        f.write("-- FORGE_TRIGGERS[card name] = entries separated by newlines, each\n")
        f.write("--   <paragraph key>|<kind>|<field>;<field=value>;...\n")
        f.write("-- or <paragraph key>|? for a trigger this data can't express: the table then reads\n")
        f.write("-- that whole paragraph's rules text instead.\n")
        f.write("-- The key pairs the trigger with its rules-text paragraph (triggers.lua forgeKey).\n")
        f.write("FORGE_TRIGGERS = {\n")
        for name in sorted(data):
            f.write("  [%s] = %s,\n" % (lua_str(name), lua_str("\n".join(data[name]))))
        f.write("}\n")

    print("Forge %s: %d cards with mapped triggers, %d of %d triggers mapped (%.1f%%)."
          % (commit, len(data), mapped, total, 100.0 * mapped / max(1, total)))
    print("Written: " + os.path.normpath(args.out) + " (%d KB)" % (os.path.getsize(args.out) // 1024))
    print("\nUnmapped trigger modes (count, then the most common reasons):")
    for mode, n in unmapped_modes.most_common():
        top = ", ".join("%s %d" % (r, c) for r, c in reasons[mode].most_common(4))
        print("  %6d  %-26s %s" % (n, mode, top))


if __name__ == "__main__":
    main()
