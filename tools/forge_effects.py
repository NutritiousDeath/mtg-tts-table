"""
Forge effects -> src/forge_effects_data.lua (called by tools/forge_triggers.py).

For each card, every triggered ability (the T: line's Execute$ SVar) and every
activated ability (A:AB$ lines) is followed through its SubAbility$ chain. Each
step is a Forge ApiType (Draw, GainLife, DealDamage, Token, PutCounter...) with
its parameters; the steps this file can express are written as data:

  <paragraph key>|<M or empty>|<Api>:<k>=<v>,<k>=<v>><Api>:...

M = the ability is optional ("you may"). The table (effects.lua
Effects.forgeSentence) turns each step back into one plain sentence of the kind
its own rules-text reader handles, and runs that. A chain with any step this file
can't express is written as "<key>|?" so the table reads the card's text instead
of doing half of it.

Forge is GPL v3; the generated file is derived from it, carries that license and
is kept separate.
"""

import collections
import os
import re

from forge_triggers import forge_key, shortest_keys, params, lua_str

NUM_WORDS = {1: "a", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight", 9: "nine",
             10: "ten"}


class Unmapped(Exception):
    pass


def read_faces(path):
    """Each face: name, [T: params], [A:AB$ params], {svar name: params of a DB$ line}, oracle text."""
    text = open(path, encoding="utf-8", errors="replace").read()
    out = []
    for part in re.split(r"^ALTERNATE\s*$", text, flags=re.M):
        name, trigs, abs_, svars, oracle = None, [], [], {}, ""
        for line in part.splitlines():
            if line.startswith("Name:"):
                name = line[5:].strip()
            elif line.startswith("T:"):
                trigs.append(params(line[2:]))
            elif line.startswith("Oracle:"):
                oracle = line[7:].replace("\\n", "\n")
            elif line.startswith("A:AB$"):
                p = params(line[2:])
                p["_api"] = line[5:].split("|")[0].strip()
                abs_.append(p)
            elif line.startswith("SVar:"):
                m = re.match(r"SVar:([^:]+):(DB|AB)\$\s*(.*)$", line)
                if m:
                    p = params(m.group(2) + "$ " + m.group(3))
                    p["_api"] = m.group(3).split("|")[0].strip()
                    svars[m.group(1)] = p
        if name:
            out.append((name, trigs, abs_, svars, oracle))
    return out


def load_tokens(folder):
    """Forge token script name -> (name, types, pt, colors, keywords)."""
    out = {}
    if not os.path.isdir(folder):
        return out
    for fn in os.listdir(folder):
        if not fn.endswith(".txt"):
            continue
        d = {"name": "", "types": [], "pt": None, "colors": [], "kw": [], "more": False}
        for line in open(os.path.join(folder, fn), encoding="utf-8", errors="replace"):
            line = line.strip()
            if line.startswith("Name:"):
                d["name"] = line[5:].replace(" Token", "").strip()
            elif line.startswith("Types:"):
                d["types"] = line[6:].split()
            elif line.startswith("PT:"):
                d["pt"] = line[3:].strip()
            elif line.startswith("Colors:"):
                d["colors"] = [c.strip() for c in line[7:].split(",")]
            elif line.startswith("K:"):
                d["kw"].append(line[2:].split(":")[0].strip())
            elif line[:2] in ("A:", "S:", "T:") or line.startswith("R:"):
                d["more"] = True                  # abilities beyond keywords: only the rules text says them
        out[fn[:-4]] = d
    return out


# ---------------------------------------------------------------------------
# Parameters -> our words
# ---------------------------------------------------------------------------

def amount(v, default=1):
    if v is None:
        return default
    if re.fullmatch(r"\d+", v.strip()):
        return int(v)
    raise Unmapped("amount " + v.strip()[:12])


def num_word(n):
    return NUM_WORDS.get(n, str(n))


TARGET_TYPES = {"Creature": "creature", "Artifact": "artifact", "Enchantment": "enchantment", "Land": "land",
                "Planeswalker": "planeswalker", "Permanent": "permanent", "Card": "card", "Battle": "battle"}


def target_phrase(v):
    """'Creature.OppCtrl' -> 'creature an opponent controls', 'Artifact,Enchantment' -> 'artifact or enchantment'."""
    alts = []
    ctrl = None
    for alt in v.split(","):
        head, _, rest = alt.strip().partition(".")
        if head not in TARGET_TYPES:
            raise Unmapped("target " + head)
        word = TARGET_TYPES[head]
        props = [p for p in rest.split("+") if p] if rest else []
        for p in props:
            if p in ("OppCtrl",):
                c = "an opponent controls"
            elif p in ("YouCtrl",):
                c = "you control"
            elif p.startswith("non") and p[3:] in TARGET_TYPES:
                word = "non" + TARGET_TYPES[p[3:]] + " " + word
                continue
            else:
                raise Unmapped("target prop " + re.sub(r"[^A-Za-z!_].*", "", p))
            if ctrl not in (None, c):
                raise Unmapped("target mixed control")
            ctrl = c
        alts.append(word)
    return " or ".join(alts) + (" " + ctrl if ctrl else "")


def who(p, default="you"):
    """Defined$ / ValidTgts$ for a player -> you / opp / each / tgtp / tgto / that."""
    if "ValidTgts" in p:
        v = p["ValidTgts"]
        if v in ("Player",):
            return "tgtp"
        if v in ("Opponent", "Player.Opponent"):
            return "tgto"
        raise Unmapped("player target " + v)
    d = p.get("Defined")
    if d is None:
        return default
    m = {"You": "you", "Opponent": "opp", "Player": "each", "Player.Opponent": "opp", "Opponents": "opp"}
    if d in m:
        return m[d]
    raise Unmapped("defined " + d)


# Tokens the rules define by name ("Create a Treasure token.").
PREDEFINED_TOKENS = {"Treasure", "Food", "Clue", "Blood", "Gold", "Map", "Powerstone", "Junk", "Lander", "Shard",
                     "Incubator", "Walker"}

COUNTERS = {"P1P1": "+1/+1", "M1M1": "-1/-1", "LOYALTY": "loyalty"}


# Keys every step may carry that don't change what it does at the table.
STEP_IGNORED = {"_api", "DB", "AB", "SpellDescription", "StackDescription", "TgtPrompt", "AILogic", "IsCurse", "AITgts",
                "Cost", "ActivationZone", "SorcerySpeed", "Planeswalker", "Ultimate", "PrecostDesc", "CostDesc",
                "AIPreference", "AnyPlayer", "InstantSpeed", "TargetMin", "TargetMax", "SubAbility", "AITgtBeforeCostEval",
                "RememberTargets", "Activation", "ActivationLimit", "NoReveal", "Hidden", "Shuffle", "Mandatory",
                "ShowCurrentPlayer", "ChangeNum", "NumCardsDesc", "SpellDescriptionPermanent"}


def step(p, tokens):
    """One Forge step -> (Api, {k: v}) or raise Unmapped."""
    api = p["_api"]
    used = set()

    def get(k, default=None):
        used.add(k)
        return p.get(k, default)

    out = None
    if p.get("TargetMax", "1") != "1":
        raise Unmapped("several targets")
    if api == "Cleanup":
        return None                                    # bookkeeping only
    if api in ("Draw", "GainLife", "LoseLife", "Mill", "Discard"):
        used.update(("Defined", "ValidTgts"))
        w = who(p)
        if api == "Draw":
            n = amount(get("NumCards"))
            if w not in ("you", "each", "tgtp"):
                raise Unmapped("Draw for " + w)
        elif api == "GainLife":
            n = amount(get("LifeAmount"))
            if w not in ("you", "tgtp"):
                raise Unmapped("GainLife for " + w)
        elif api == "LoseLife":
            n = amount(get("LifeAmount"))
        elif api == "Mill":
            n = amount(get("NumCards"))
            if w == "each" or w == "that":
                raise Unmapped("Mill for " + w)
        else:
            n = amount(get("NumCards"))
            if get("Mode", "TgtChoose") != "TgtChoose":
                raise Unmapped("Discard mode " + p.get("Mode"))
            if w not in ("you", "opp", "tgtp"):
                raise Unmapped("Discard for " + w)
        out = {"w": w, "n": n}
    elif api == "DealDamage":
        n = amount(get("NumDmg"))
        used.update(("Defined", "ValidTgts"))
        if "ValidTgts" in p:
            w = {"Any": "any", "Player": "tgtp", "Opponent": "tgto", "Player,Planeswalker": "tgtp"}.get(p["ValidTgts"])
        else:
            w = {"Opponent": "opp", "Player": "each", "Player.Opponent": "opp"}.get(p.get("Defined", ""))
        if not w:
            raise Unmapped("damage to " + str(p.get("ValidTgts") or p.get("Defined")))
        out = {"w": w, "n": n}
    elif api == "DamageAll":
        n = amount(get("NumDmg"))
        if get("ValidCards") != "Creature" or get("ValidPlayers") is not None:
            raise Unmapped("DamageAll " + str(p.get("ValidCards")))
        out = {"n": n}
    elif api in ("Scry", "Surveil"):
        out = {"n": amount(get("ScryNum") if api == "Scry" else get("Amount"))}
        if get("Defined", "You") != "You":
            raise Unmapped(api + " for " + p["Defined"])
    elif api in ("PutCounter", "PutCounterAll"):
        ct = get("CounterType", "")
        c = COUNTERS.get(ct)
        if c is None:
            if not re.fullmatch(r"[A-Z][A-Z]+", ct):
                raise Unmapped("counter " + ct)
            c = ct.lower()
        n = amount(get("CounterNum"))
        if api == "PutCounterAll":
            if get("ValidCards") != "Creature.YouCtrl":
                raise Unmapped("counters on " + str(p.get("ValidCards")))
            out = {"c": c, "n": n, "on": "yours"}
        elif "ValidTgts" in p:
            out = {"c": c, "n": n, "on": "tgt", "t": target_phrase(get("ValidTgts"))}
        elif get("Defined", "Self") == "Self":
            out = {"c": c, "n": n, "on": "self"}
        else:
            raise Unmapped("counter on " + p["Defined"])
    elif api == "Token":
        n = amount(get("TokenAmount"))
        scripts = get("TokenScript", "")
        if "," in scripts or scripts not in tokens:
            raise Unmapped("token script")
        if get("TokenOwner", "You") != "You" or get("TokenTapped") or get("TokenAttacking"):
            raise Unmapped("token owner/tapped/attacking")
        tk = tokens[scripts]
        if "Legendary" in tk["types"]:
            raise Unmapped("legendary token")              # named: the rules text says the name
        types = [t for t in tk["types"] if t in ("Creature", "Artifact", "Enchantment", "Land")]
        subs = [t for t in tk["types"] if t not in types and t not in ("Legendary", "Snow", "Token")]
        if not tk["pt"] and "Creature" in types:
            raise Unmapped("token without P/T")
        if tk["pt"] and (tk["more"] or len(tk["kw"]) > 2 or any(not re.fullmatch(r"[A-Za-z ]+", k) for k in tk["kw"])):
            raise Unmapped("token abilities")
        if not tk["pt"]:
            if tk["name"] not in PREDEFINED_TOKENS:
                raise Unmapped("token " + tk["name"][:12])
            out = {"n": n, "name": tk["name"]}                  # Treasure, Food, Clue...
        else:
            out = {"n": n, "pt": tk["pt"], "col": " and ".join(c for c in tk["colors"] if c),
                   "sub": " ".join(subs), "ty": " ".join(t.lower() for t in types),
                   "kw": " and ".join(k.lower() for k in tk["kw"][:2])}
    elif api == "Destroy":
        if "ValidTgts" not in p:
            raise Unmapped("Destroy " + str(p.get("Defined")))
        out = {"t": target_phrase(get("ValidTgts"))}
    elif api == "ChangeZone":
        o, d = get("Origin", ""), get("Destination", "")
        if o == "Battlefield" and d == "Hand":
            if "ValidTgts" in p:
                out = {"z": "bounce", "t": target_phrase(get("ValidTgts"))}
            elif get("Defined") == "Self":
                out = {"z": "bounceSelf"}
        elif o == "Battlefield" and d == "Exile" and "ValidTgts" in p:
            out = {"z": "exile", "t": target_phrase(get("ValidTgts"))}
        elif o == "Graveyard" and d == "Hand" and "ValidTgts" in p:
            v = get("ValidTgts")
            head = v.split(".")[0]
            if v not in (head + ".YouOwn", head + ".YouCtrl") or head not in TARGET_TYPES:
                raise Unmapped("graveyard target " + v)
            out = {"z": "graveHand", "t": TARGET_TYPES[head]}
        elif o == "Library" and d in ("Hand", "Battlefield"):
            ct = get("ChangeType", "")
            q = {"Land.Basic": "basic land", "Land": "land", "Creature": "creature", "Artifact": "artifact",
                 "Enchantment": "enchantment", "Instant": "instant", "Sorcery": "sorcery", "Planeswalker": "planeswalker",
                 "Forest": "Forest", "Plains": "Plains", "Island": "Island", "Swamp": "Swamp", "Mountain": "Mountain"}.get(ct)
            if not q or get("ChangeNum", "1") != "1" or get("DefinedPlayer") is not None:
                raise Unmapped("search " + ct)
            out = {"z": "search", "t": q, "to": "hand" if d == "Hand" else ("bft" if get("Tapped") == "True" else "bf")}
        if out is None:
            raise Unmapped("zones %s->%s" % (o, d))
    elif api in ("Pump", "PumpAll"):
        a, b = get("NumAtt"), get("NumDef")
        kw = get("KW")
        if a is None and b is None and kw is None:
            raise Unmapped("pump nothing")
        out = {"a": a or "+0", "b": b or ("-0" if (a or "").startswith("-") else "+0")}
        for v in (out["a"], out["b"]):
            if not re.fullmatch(r"[+-]\d+", v):
                raise Unmapped("pump amount " + v)
        if kw:
            kws = [k.strip() for k in kw.split("&")]
            if any(not re.fullmatch(r"[A-Za-z ]+", k) for k in kws):
                raise Unmapped("pump keyword")
            out["kw"] = " and ".join(k.lower() for k in kws)
        if api == "PumpAll":
            if get("ValidCards") != "Creature.YouCtrl":
                raise Unmapped("PumpAll " + str(p.get("ValidCards")))
            out["on"] = "yours"
        elif "ValidTgts" in p:
            out["on"] = "tgt"
            out["t"] = target_phrase(get("ValidTgts"))
        elif get("Defined", "Self") == "Self":
            out["on"] = "self"
        else:
            raise Unmapped("pump " + p.get("Defined"))
    elif api in ("Tap", "Untap"):
        if "ValidTgts" in p:
            out = {"on": "tgt", "t": target_phrase(get("ValidTgts"))}
        elif get("Defined", "Self") == "Self":
            out = {"on": "self"}
        else:
            raise Unmapped(api + " " + p.get("Defined"))
    elif api in ("TapAll", "UntapAll"):
        v = get("ValidCards", "")
        t = {"Creature.OppCtrl": "creatures your opponents control", "Land.YouCtrl": "lands you control",
             "Creature.YouCtrl": "creatures you control", "Permanent.YouCtrl": "permanents you control"}.get(v)
        if not t:
            raise Unmapped(api + " " + v)
        out = {"t": t}
    elif api == "Sacrifice":
        w = who(p, "you")
        if w not in ("opp", "each"):
            raise Unmapped("Sacrifice by " + w)
        sv = get("SacValid", "")
        t = TARGET_TYPES.get(sv)
        if not t or amount(get("Amount")) != 1:
            raise Unmapped("sacrifice " + sv)
        out = {"w": w, "t": t}
    elif api == "Counter":
        tt = get("TargetType", "Spell")
        v = get("ValidTgts", "Card")
        f = {"Card": "", "Card.nonCreature": "noncreature ", "Instant,Sorcery": "instant or sorcery ",
             "Card.Instant,Card.Sorcery": "instant or sorcery ", "Creature": "creature "}.get(v)
        if tt != "Spell" or f is None:
            raise Unmapped("counter " + v)
        out = {"f": f.strip()}
    elif api == "Proliferate":
        out = {}
    else:
        raise Unmapped("api")
    extra = set(p) - STEP_IGNORED - used
    if extra:
        raise Unmapped("key " + sorted(extra)[0])
    return api, out


def chain(first, svars, tokens):
    """Follow SubAbility$ from the first step: [(api, params)]."""
    steps, seen, p = [], set(), first
    while p is not None:
        for k in p:
            if k.startswith("Condition") or k in ("ConditionCheckSVar", "Optional", "UnlessCost", "RememberChanged",
                                                    "Defined" if p.get("Defined", "").startswith("Remembered") else "_"):
                raise Unmapped("condition " + k)
        s = step(p, tokens)
        if s:
            steps.append(s)
        nxt = p.get("SubAbility")
        if not nxt:
            break
        if nxt in seen or nxt not in svars:
            raise Unmapped("subability")
        seen.add(nxt)
        p = svars[nxt]
    if not steps:
        raise Unmapped("no steps")
    return steps


def encode(steps):
    parts = []
    for api, prm in steps:
        parts.append(api + ":" + ",".join("%s=%s" % (k, str(v).replace(",", " ").replace(">", " ").replace("|", " "))
                                          for k, v in prm.items()))
    return ">".join(parts)


def build(cardsfolder, tokenfolder, out, commit):
    tokens = load_tokens(tokenfolder)
    data = {}
    total = mapped = 0
    api_ok, api_bad = collections.Counter(), collections.Counter()
    reasons = collections.defaultdict(collections.Counter)
    for root, _, files in os.walk(cardsfolder):
        for fn in sorted(files):
            if not fn.endswith(".txt"):
                continue
            for name, trigs, abs_, svars, oracle in read_faces(os.path.join(root, fn)):
                if name.startswith("A-"):
                    continue
                items = []                         # (description, first step params, optional)
                for t in trigs:
                    ex = t.get("Execute")
                    if ex and ex in svars and t.get("TriggerDescription"):
                        items.append((t["TriggerDescription"], svars[ex], "OptionalDecider" in t))
                for a in abs_:
                    if a.get("SpellDescription") and a["_api"] != "Mana":    # mana abilities: mana.lua
                        items.append((a["SpellDescription"], a, False))
                entries, unread = [], []
                for desc, first, optional in items:
                    key = forge_key(desc, name)
                    if not key:
                        continue
                    total += 1
                    try:
                        steps = chain(first, svars, tokens)
                    except Unmapped as e:
                        api = first.get("_api", "?")
                        api_bad[api] += 1
                        reasons[api][str(e)] += 1
                        unread.append(key)
                        continue
                    mapped += 1
                    for api, _ in steps:
                        api_ok[api] += 1
                    entries.append((key, ("M" if optional else "") + "|" + encode(steps)))
                if entries:
                    # Every paragraph of the card (and the effect part of each activated one) counts
                    # when cutting keys short, so a key never fits a paragraph Forge scripts elsewhere.
                    others = []
                    for para in oracle.split("\n"):
                        others.append(forge_key(para, name))
                        if ":" in para:
                            others.append(forge_key(para.split(":", 1)[1], name))
                    short = shortest_keys([k for k, _ in entries] + unread + [k for k in others if k])
                    data[name] = ([short[k] + "|" + e for k, e in entries]
                                  + [short[k] + "|?" for k in dict.fromkeys(unread)])
    with open(out, "w", encoding="utf-8") as f:
        f.write("-- Generated by tools/forge_triggers.py (tools/forge_effects.py) from Forge's card scripts\n")
        f.write("-- (https://github.com/Card-Forge/forge, forge-gui/res/cardsfolder, %s).\n" % commit)
        f.write("-- LICENSE: Forge is licensed under the GNU General Public License v3. This file is\n")
        f.write("-- derived from Forge's card scripts and is distributed under the GPL v3 as well; it\n")
        f.write("-- is kept separate from the table's own scripts. Do not edit by hand: re-run the tool.\n")
        f.write("--\n")
        f.write("-- FORGE_EFFECTS[card name] = entries separated by newlines, each\n")
        f.write("--   <paragraph key>|<M if optional>|<Api>:<k>=<v>,...><Api>:...\n")
        f.write("-- or <paragraph key>|? when a step can't be expressed (the table reads the text).\n")
        f.write("FORGE_EFFECTS = {\n")
        for name in sorted(data):
            f.write("  [%s] = %s,\n" % (lua_str(name), lua_str("\n".join(data[name]))))
        f.write("}\n")
    lines = ["Effects: %d of %d triggered/activated abilities mapped (%.1f%%) on %d cards. Written: %s (%d KB)"
             % (mapped, total, 100.0 * mapped / max(1, total), len(data), os.path.basename(out), os.path.getsize(out) // 1024),
             "", "Mapped steps by ApiType:"]
    for api, n in api_ok.most_common():
        lines.append("  %6d  %s" % (n, api))
    lines += ["", "Abilities not mapped, by the ApiType of their first step (count, then the most common reasons):"]
    for api, n in api_bad.most_common():
        top = ", ".join("%s %d" % (r, c) for r, c in reasons[api].most_common(4))
        lines.append("  %6d  %-20s %s" % (n, api, top))
    return "\n".join(lines)
