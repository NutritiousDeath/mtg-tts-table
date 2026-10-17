"""
Forge effects -> src/forge_effects_data.lua (called by tools/forge_triggers.py).

For each card, every triggered ability (the T: line's Execute$ SVar) and every
activated ability (A:AB$ lines) is followed through its SubAbility$ chain. Each
step is a Forge ApiType (Draw, GainLife, DealDamage, Token, PutCounter...) with
its parameters; the steps this file can express are written as data:

  <paragraph key>|<M or empty>|<Api>:<k>=<v>,<k>=<v>><Api>:...

M = the ability is optional ("you may"). The table (effects.lua
Effects.parseBest) turns each step back into a plain sentence of the kind its own
rules-text reader handles (or, for the few its reader has no words for, an action
of its own) and runs that. A chain with any step this file can't express is
written as "<key>|?" so the table reads the card's text instead of doing half of
it. A modal ability (Charm) gets one entry per mode, keyed by the mode's text.

Amounts that aren't plain numbers are written as a count the table works out
when the ability resolves:
  $v.<words>.<you|opp|all>[.o]   permanents on the battlefield (words joined by
                                 "/", o = other than this card)
  $hand  $life  $domain          cards in your hand, your life, basic land types
  $yard.<words>                  cards in your graveyard
  $pow.<self|that> $tou.<...>    power / toughness of this card or the one that
                                 triggered it
  $ctr.<plus|minus|loyalty|other> counters on this card
followed by math: *N (times), +N, -N, *h (half, rounded down), *H (half, up).

Forge is GPL v3; the generated file is derived from it, carries that license and
is kept separate.
"""

import collections
import os
import re

from forge_triggers import forge_key, shortest_keys, params, lua_str, SUBTYPES

NUM_WORDS = {1: "a", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight", 9: "nine",
             10: "ten"}


class Unmapped(Exception):
    pass


def read_faces(path):
    """Each face: name, [T: params], [A:AB$ params], {svar: params of a DB$/AB$ line}, {svar: raw value}, oracle."""
    text = open(path, encoding="utf-8", errors="replace").read()
    out = []
    for part in re.split(r"^ALTERNATE\s*$", text, flags=re.M):
        name, trigs, abs_, svars, raw, oracle = None, [], [], {}, {}, ""
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
                else:
                    m = re.match(r"SVar:([^:]+):(.*)$", line)
                    if m:
                        raw[m.group(1)] = m.group(2).strip()
        if name:
            out.append((name, trigs, abs_, svars, raw, oracle))
    return out


COLOR_LETTER = {"white": "W", "blue": "U", "black": "B", "red": "R", "green": "G"}


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
                d["more"] = True                  # abilities beyond keywords
        out[fn[:-4]] = d
    return out


def load_token_data(path):
    """The table's own token list (src/token_data.lua): {(name, "p/u", color letters)}."""
    have = set()
    if not os.path.exists(path):
        return have
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r'\s*\{ n = "([^"]*)", t = "[^"]*"(?:, p = "([^"]*)", u = "([^"]*)")?, c = "([^"]*)"', line)
        if m:
            have.add((m.group(1), "%s/%s" % (m.group(2), m.group(3)) if m.group(2) else None,
                      "".join(sorted(m.group(4)))))
    return have


# ---------------------------------------------------------------------------
# Parameters -> our words
# ---------------------------------------------------------------------------

COUNT_WORDS = {"Creature": "creature", "Artifact": "artifact", "Enchantment": "enchantment", "Land": "land",
               "Planeswalker": "planeswalker", "Permanent": "permanent", "Card": "permanent", "Instant": "instant",
               "Sorcery": "sorcery", "Battle": "battle"}
COUNT_CTRL = {"YouCtrl": "you", "OppCtrl": "opp", "YouOwn": "you"}
COUNT_MATH = [(r"Times\.(\d+)", "*%s"), (r"Twice", "*2"), (r"Plus\.(\d+)", "+%s"), (r"Minus\.(\d+)", "-%s"),
              (r"HalfDown", "*h"), (r"HalfUp", "*H")]
CARD_COUNTERS = {"P1P1": "plus", "M1M1": "minus", "LOYALTY": "loyalty"}


def count_filter(expr, zone):
    """'Creature.YouCtrl+Other,Artifact.YouCtrl' -> ('creature/artifact', 'you', other?)."""
    words, ctrl, other = [], None, False
    for alt in expr.split(","):
        head, _, rest = alt.strip().partition(".")
        props = [p for p in rest.split("+") if p]
        word = COUNT_WORDS.get(head)
        if word is None:
            if head in SUBTYPES:
                word = head.lower()
            else:
                raise Unmapped("count of " + head)
        c = "all"
        for p in props:
            if p in COUNT_CTRL:
                c = COUNT_CTRL[p]
            elif p in ("Other", "StrictlyOther") and zone == "field":
                other = True
            elif p in SUBTYPES and word in ("creature", "permanent", "land", "artifact", "enchantment"):
                word = p.lower()
            else:
                raise Unmapped("count prop " + re.sub(r"[^A-Za-z].*", "", p))
        if ctrl not in (None, c):
            raise Unmapped("count mixed control")
        ctrl = c
        words.append(word)
    return "/".join(dict.fromkeys(words)), ctrl, other


def count_expr(raw_value):
    """A Forge count SVar ('Count$Valid Creature.YouCtrl/Twice') -> our $ expression, or Unmapped."""
    base, _, maths = raw_value.partition("/")
    tail = ""
    for part in [m for m in maths.split("/") if m] if maths else []:
        for pat, out in COUNT_MATH:
            m = re.fullmatch(pat, part)
            if m:
                tail += out % m.group(1) if m.groups() else out
                break
        else:
            raise Unmapped("count math " + part[:10])
    m = re.fullmatch(r"Count\$Valid (\S+)", base)
    if m:
        words, ctrl, other = count_filter(m.group(1), "field")
        return "$v.%s.%s%s%s" % (words, ctrl, ".o" if other else "", tail)
    m = re.fullmatch(r"Count\$ValidGraveyard (\S+)", base)
    if m:
        words, ctrl, _ = count_filter(m.group(1), "yard")
        if ctrl != "you":
            raise Unmapped("count of graveyards")
        return "$yard.%s%s" % (words, tail)
    m = re.fullmatch(r"Count\$ValidHand (\S+)", base)
    if m:
        words, ctrl, _ = count_filter(m.group(1), "hand")
        if ctrl != "you" or words != "permanent":
            raise Unmapped("count of hand " + m.group(1)[:12])
        return "$hand" + tail
    simple = {"Count$CardsInYourHand": "$hand", "Count$YourLifeTotal": "$life", "Count$Domain": "$domain",
              "Count$CardPower": "$pow.self", "Count$CardToughness": "$tou.self",
              "TriggeredCard$CardPower": "$pow.that", "TriggeredCard$CardToughness": "$tou.that"}
    if base in simple:
        return simple[base] + tail
    m = re.fullmatch(r"Count\$CardCounters\.([A-Z0-9_]+)", base)
    if m:
        return "$ctr.%s%s" % (CARD_COUNTERS.get(m.group(1), "other"), tail)
    raise Unmapped("amount " + re.sub(r"[ .].*", "", base)[:28])


def amount(v, raw, default=1, counted=True):
    """A number, or an SVar the table can count when it resolves."""
    if v is None:
        return default
    v = v.strip()
    if re.fullmatch(r"\d+", v):
        return int(v)
    if counted and v in raw:
        return count_expr(raw[v])
    raise Unmapped("amount " + v[:12])


def num_word(n):
    return NUM_WORDS.get(n, str(n))


TARGET_TYPES = {"Creature": "creature", "Artifact": "artifact", "Enchantment": "enchantment", "Land": "land",
                "Planeswalker": "planeswalker", "Permanent": "permanent", "Card": "card", "Battle": "battle"}


def target_phrase(v, other_ok=False):
    """'Creature.OppCtrl' -> 'creature an opponent controls', 'Artifact,Enchantment' -> 'artifact or enchantment'.
    With other_ok, 'Creature.Other+YouCtrl' -> ('creature you control', True); otherwise just the phrase."""
    alts = []
    ctrl = None
    other = False
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
            elif p in ("Other", "StrictlyOther") and other_ok:
                other = True
                continue
            else:
                raise Unmapped("target prop " + re.sub(r"[^A-Za-z!_].*", "", p))
            if ctrl not in (None, c):
                raise Unmapped("target mixed control")
            ctrl = c
        alts.append(word)
    phrase = " or ".join(alts) + (" " + ctrl if ctrl else "")
    return (phrase, other) if other_ok else phrase


def who(p, default="you"):
    """Defined$ / ValidTgts$ for a player -> you / opp / each / tgtp / tgto."""
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
    m = {"You": "you", "Opponent": "opp", "Player": "each", "Player.Opponent": "opp", "Opponents": "opp",
         "TriggeredPlayer": "that", "TriggeredTarget": "that"}
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
                "ShowCurrentPlayer", "ChangeNum", "NumCardsDesc", "SpellDescriptionPermanent", "RestRandomOrder",
                "Reveal", "ForceRevealToController", "NoLooking", "AIMinTgts", "AIMaxTgts", "TokenScript_Desc",
                "ValidDescription", "ChangeTypeDesc"}


# Forge's names for the card that triggered the ability (the table's "that creature").
THAT_CARD = {"TriggeredCard", "TriggeredCardLKICopy", "TriggeredCardLKI", "TriggeredAttacker", "TriggeredAttackerLKICopy",
             "TriggeredAttackerLKI", "TriggeredBlocker", "TriggeredBlockerLKICopy", "TriggeredNewCardLKICopy"}


def tgt_count(p):
    """Only one target per step: 'up to two targets' is more than a sentence here says."""
    if p.get("TargetMax", "1") != "1":
        raise Unmapped("several targets")


def step(p, tokens, raw, token_db, self_trigger=False):
    """One Forge step -> (Api, {k: v}) or raise Unmapped."""
    api = p["_api"]
    used = set()

    def get(k, default=None):
        used.add(k)
        return p.get(k, default)

    out = None
    if api == "Cleanup":
        return None                                    # bookkeeping only
    if api != "DealDamage":
        tgt_count(p)
    if api in ("Draw", "GainLife", "LoseLife", "Mill", "Discard"):
        used.update(("Defined", "ValidTgts"))
        w = who(p)
        if api == "Draw":
            n = amount(get("NumCards"), raw)
            if w not in ("you", "each", "tgtp", "that"):
                raise Unmapped("Draw for " + w)
        elif api == "GainLife":
            n = amount(get("LifeAmount"), raw)
            if w not in ("you", "tgtp"):
                raise Unmapped("GainLife for " + w)
        elif api == "LoseLife":
            n = amount(get("LifeAmount"), raw)
        elif api == "Mill":
            n = amount(get("NumCards"), raw)
            if w == "each":
                raise Unmapped("Mill for " + w)
        else:
            n = amount(get("NumCards"), raw)
            if get("Mode", "TgtChoose") != "TgtChoose":
                raise Unmapped("Discard mode " + p.get("Mode"))
            if w not in ("you", "opp", "tgtp", "that"):
                raise Unmapped("Discard for " + w)
        out = {"w": w, "n": n}
    elif api == "DealDamage":
        n = amount(get("NumDmg"), raw)
        used.update(("Defined", "ValidTgts"))
        k = p.get("TargetMax", "1")
        if not re.fullmatch(r"[1-3]", k):
            raise Unmapped("several targets")
        if "ValidTgts" in p:
            v = p["ValidTgts"]
            w = {"Any": "any", "Player": "tgtp", "Opponent": "tgto", "Player,Planeswalker": "tgtp"}.get(v)
            if w and k != "1":
                raise Unmapped("several targets")
            if not w:
                # A creature (or planeswalker) target: the table's own damage action.
                kinds = []
                ctrl = None
                for alt in v.split(","):
                    head, _, rest = alt.partition(".")
                    if head not in ("Creature", "Planeswalker", "Battle"):
                        raise Unmapped("damage to " + v[:24])
                    kinds.append(head.lower())
                    for pr in [x for x in rest.split("+") if x]:
                        c = {"OppCtrl": "opp", "YouCtrl": "you"}.get(pr)
                        if c is None:
                            raise Unmapped("damage target prop " + re.sub(r"[^A-Za-z].*", "", pr))
                        ctrl = c
                out = {"w": "c", "n": n, "k": "/".join(kinds), "c": ctrl or "all", "m": k}
        else:
            if k != "1":
                raise Unmapped("several targets")
            d = p.get("Defined", "")
            w = {"Opponent": "opp", "Player": "each", "Player.Opponent": "opp", "TriggeredPlayer": "that",
                 "TriggeredTarget": "that"}.get(d)
            if d in ("Self", "Creature.Self"):
                raise Unmapped("damage to itself")
            if d in THAT_CARD:
                out = {"w": "thatc", "n": n}
        if out is None:
            if not w:
                raise Unmapped("damage to " + str(p.get("ValidTgts") or p.get("Defined")))
            out = {"w": w, "n": n}
        if get("DamageSource") is not None:
            raise Unmapped("damage source")
    elif api == "DamageAll":
        n = amount(get("NumDmg"), raw)
        vc = get("ValidCards")
        vp = get("ValidPlayers")
        out = {"n": n}
        if vc is not None:
            m = {"Creature": "all", "Creature.OppCtrl": "opp", "Creature.YouCtrl": "you",
                 "Creature.withoutFlying": "all.nofly", "Creature.withFlying": "all.fly",
                 "Creature.nonAttacking": None, "Creature.Other": "all.o", "Creature.StrictlyOther": "all.o",
                 "Creature.OppCtrl+withoutFlying": "opp.nofly", "Creature.withoutFlying+OppCtrl": "opp.nofly"}.get(vc)
            if not m:
                raise Unmapped("DamageAll " + vc[:24])
            out["c"] = m
        if vp is not None:
            pl = {"Player": "each", "Opponent": "opp", "Player.Opponent": "opp"}.get(vp)
            if not pl:
                raise Unmapped("DamageAll players " + vp)
            out["pl"] = pl
        if vc is None and vp is None:
            raise Unmapped("DamageAll None")
    elif api in ("Scry", "Surveil"):
        out = {"n": amount(get("ScryNum") if api == "Scry" else get("Amount"), raw)}
        if get("Defined", "You") != "You":
            raise Unmapped(api + " for " + p["Defined"])
    elif api in ("PutCounter", "PutCounterAll"):
        ct = get("CounterType", "")
        c = COUNTERS.get(ct)
        if c is None:
            if not re.fullmatch(r"[A-Z][A-Z]+", ct):
                raise Unmapped("counter " + ct)
            c = ct.lower()
        n = amount(get("CounterNum"), raw)
        if api == "PutCounterAll":
            if get("ValidCards") != "Creature.YouCtrl":
                raise Unmapped("counters on " + str(p.get("ValidCards")))
            out = {"c": c, "n": n, "on": "yours"}
        elif "ValidTgts" in p:
            t, other = target_phrase(get("ValidTgts"), True)
            out = {"c": c, "n": n, "on": "tgt", "t": t}
            if other:
                out["o"] = 1
        elif get("Defined", "Self") == "Self":
            out = {"c": c, "n": n, "on": "self"}
        elif p["Defined"] in THAT_CARD:
            out = {"c": c, "n": n, "on": "that"}
        else:
            raise Unmapped("counter on " + p["Defined"])
    elif api == "Token":
        n = amount(get("TokenAmount"), raw)
        scripts = get("TokenScript", "")
        if "," in scripts or scripts not in tokens:
            raise Unmapped("token script")
        owner = get("TokenOwner", "You")
        tw = {"You": None, "Opponent": "opp", "Player": "each", "Player.Opponent": "opp"}.get(owner, "?")
        if tw == "?":
            raise Unmapped("token owner " + owner[:16])
        tk = tokens[scripts]
        if "Legendary" in tk["types"]:
            raise Unmapped("legendary token")              # named: the rules text says the name
        types = [t for t in tk["types"] if t in ("Creature", "Artifact", "Enchantment", "Land")]
        subs = [t for t in tk["types"] if t not in types and t not in ("Legendary", "Snow", "Token")]
        if not tk["pt"] and "Creature" in types:
            raise Unmapped("token without P/T")
        if not tk["pt"]:
            if tk["name"] not in PREDEFINED_TOKENS:
                raise Unmapped("token " + tk["name"][:12])
            out = {"n": n, "name": tk["name"]}                  # Treasure, Food, Clue...
        else:
            # The table makes tokens from its own list (token_data.lua): the token must be in it,
            # same name, P/T and colors, so what it makes has the right abilities too.
            letters = "".join(sorted(COLOR_LETTER.get(c.lower(), "") for c in tk["colors"]))
            if token_db and (tk["name"], tk["pt"], letters) not in token_db and (tk["more"] or len(tk["kw"]) > 2):
                raise Unmapped("token not in token_data")
            if any(not re.fullmatch(r"[A-Za-z ]+", k) for k in tk["kw"][:2]):
                raise Unmapped("token keywords")
            out = {"n": n, "pt": tk["pt"], "col": " and ".join(c for c in tk["colors"] if c),
                   "sub": " ".join(subs), "ty": " ".join(t.lower() for t in types),
                   "kw": " and ".join(k.lower() for k in tk["kw"][:2])}
        if get("TokenTapped") == "True":
            out["tap"] = 1
        if get("TokenAttacking") == "True":
            out["att"] = 1
        if tw:
            out["w"] = tw
    elif api == "Destroy":
        if get("Defined") in THAT_CARD:
            return api, {"that": 1}
        if "ValidTgts" not in p:
            raise Unmapped("Destroy " + str(p.get("Defined")))
        t, other = target_phrase(get("ValidTgts"), True)
        out = {"t": t}
        if other:
            out["o"] = 1
        if get("NoRegen") is not None:
            pass
    elif api == "ChangeZone":
        o, d = get("Origin", ""), get("Destination", "")
        tapped = get("Tapped") == "True"
        if o == "Battlefield" and d == "Hand":
            if "ValidTgts" in p:
                t, other = target_phrase(get("ValidTgts"), True)
                out = {"z": "bounce", "t": t}
                if other:
                    out["o"] = 1
            elif get("Defined") == "Self":
                out = {"z": "bounceSelf"}
            elif p.get("Defined") in THAT_CARD:
                out = {"z": "bounceThat"}
        elif o == "Battlefield" and d == "Exile":
            if "ValidTgts" in p:
                t, other = target_phrase(get("ValidTgts"), True)
                out = {"z": "exile", "t": t}
                if other:
                    out["o"] = 1
            elif get("Defined") == "Self":
                out = {"z": "exileSelf"}
            elif p.get("Defined") in THAT_CARD:
                out = {"z": "exileThat"}
        elif o == "Graveyard" and d in ("Hand", "Battlefield"):
            to = "hand" if d == "Hand" else ("bft" if tapped else "bf")
            if "ValidTgts" in p:
                v = get("ValidTgts")
                head = v.split(".")[0]
                if head not in TARGET_TYPES or v not in (head, head + ".YouOwn", head + ".YouCtrl"):
                    raise Unmapped("graveyard target " + v[:24])
                if v == head:
                    # Any graveyard: only "put onto the battlefield under your control" has words here.
                    if d != "Battlefield" or tapped or head != "Creature" or get("GainControl") != "True":
                        raise Unmapped("graveyard target " + v[:24])
                    out = {"z": "reanimateAny"}
                else:
                    out = {"z": "graveHand" if d == "Hand" else "reanimate", "t": TARGET_TYPES[head], "to": to}
            elif get("Defined") == "Self" or (self_trigger and p.get("Defined") in THAT_CARD):
                # "When ~ dies, return it to its owner's hand": the card that triggered is this one.
                used.add("Defined")
                out = {"z": "yardSelf", "to": to}
            if d == "Battlefield":
                used.add("GainControl")
        elif o == "Library" and d in ("Hand", "Battlefield"):
            ct = get("ChangeType", "")
            mv = None
            m = re.fullmatch(r"(\w+)\.cmcLE(\d+)", ct)
            if m:
                ct, mv = m.group(1), m.group(2)
            q = {"Land.Basic": "basic land", "Land": "land", "Creature": "creature", "Artifact": "artifact",
                 "Enchantment": "enchantment", "Instant": "instant", "Sorcery": "sorcery", "Planeswalker": "planeswalker",
                 "Forest": "Forest", "Plains": "Plains", "Island": "Island", "Swamp": "Swamp", "Mountain": "Mountain",
                 "Card": "any"}.get(ct)
            if not q or get("ChangeNum", "1") != "1" or get("DefinedPlayer") is not None \
                    or (q == "any" and d == "Battlefield"):
                raise Unmapped("search " + ct)
            out = {"z": "search", "t": q, "to": "hand" if d == "Hand" else ("bft" if tapped else "bf")}
            if mv:
                out["mv"] = int(mv)
        if out is None:
            raise Unmapped("zones %s->%s" % (o, d))
    elif api in ("Pump", "PumpAll"):
        a, b = get("NumAtt"), get("NumDef")
        kw = get("KW")
        if a is None and b is None and kw is None:
            raise Unmapped("pump nothing")
        out = {"a": a or "+0", "b": b or ("-0" if (a or "").startswith("-") else "+0")}
        for k in ("a", "b"):
            v = out[k]
            if re.fullmatch(r"[+-]\d+", v):
                continue
            m = re.fullmatch(r"([+-])(\w+)", v)
            if not m or m.group(2) not in raw:
                raise Unmapped("pump amount " + v)
            out[k] = m.group(1) + count_expr(raw[m.group(2)])
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
            t, other = target_phrase(get("ValidTgts"), True)
            out["t"] = t
            if other:
                out["o"] = 1
        elif get("Defined", "Self") == "Self":
            out["on"] = "self"
        elif p["Defined"] in THAT_CARD:
            out["on"] = "that"
        else:
            raise Unmapped("pump " + p.get("Defined"))
    elif api in ("Tap", "Untap"):
        if "ValidTgts" in p:
            t, other = target_phrase(get("ValidTgts"), True)
            out = {"on": "tgt", "t": t}
            if other:
                out["o"] = 1
        elif get("Defined", "Self") == "Self":
            out = {"on": "self"}
        elif p["Defined"] in THAT_CARD:
            out = {"on": "that"}
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
        used.update(("Defined", "ValidTgts"))
        sv = get("SacValid", "")
        w = "you" if p.get("Defined") == "Self" else who(p, "you")
        n = amount(get("Amount"), raw, counted=False)
        if sv in ("Self", "Card.Self") or (sv == "" and p.get("Defined", "Self") == "Self"):
            used.add("Defined")
            out = {"self": 1}
        else:
            t = TARGET_TYPES.get(sv)
            if not t or t == "card":
                raise Unmapped("sacrifice " + sv[:20])
            if w not in ("opp", "each", "you"):
                raise Unmapped("Sacrifice by " + w)
            out = {"w": w, "t": t, "n": n}
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
    elif api == "Animate":
        pw, tg = get("Power"), get("Toughness")
        types = [t for t in get("Types", "").split(",") if t]
        kw = get("Keywords")
        get("Colors")
        get("OverwriteColors")
        get("RemoveCreatureTypes")
        dur = get("Duration")
        if dur not in (None, "Permanent"):
            raise Unmapped("animate " + dur[:16])
        kws = [k.strip() for k in kw.split("&")] if kw else []
        if any(not re.fullmatch(r"[A-Za-z ]+", k) for k in kws):
            raise Unmapped("animate keyword")
        if pw is None and tg is None and not types:
            if not kws or dur:
                raise Unmapped("animate nothing")
            # Only keywords: the same as a pump.
            api = "Pump"
            out = {"a": "+0", "b": "+0", "kw": " and ".join(k.lower() for k in kws)}
        else:
            if not (pw and tg and re.fullmatch(r"\d+", pw) and re.fullmatch(r"\d+", tg)) or "Creature" not in types:
                raise Unmapped("animate P/T")
            out = {"p": int(pw), "t": int(tg), "ty": " ".join(t for t in types if t != "Creature"),
                   "kw": " and ".join(k.lower() for k in kws)}
            if dur == "Permanent":
                out["perm"] = 1
        if "ValidTgts" in p:
            k, ctrl, other = target_kinds(get("ValidTgts"))
            out.update({"on": "tgt", "k": k, "c": ctrl})
            if api == "Pump":
                out["t"], other = target_phrase(p["ValidTgts"], True)
                del out["k"], out["c"]
            if other:
                out["o"] = 1
        elif get("Defined", "Self") == "Self":
            out["on"] = "self"
        elif p["Defined"] in THAT_CARD:
            out["on"] = "that"
        else:
            raise Unmapped("animate " + p["Defined"][:16])
    elif api == "Dig":
        n = amount(get("DigNum"), raw, counted=False)
        k = get("ChangeNum", "1")
        rest = get("DestinationZone2", "Library")
        if not re.fullmatch(r"\d", k) or int(k) >= n or rest not in ("Library", "Graveyard") \
                or get("LibraryPosition2", "-1") != "-1" or get("Defined", "You") != "You":
            raise Unmapped("dig how")
        dz = get("DestinationZone", "Hand")
        if dz not in ("Hand", "Battlefield"):
            raise Unmapped("dig to " + dz)
        cv = get("ChangeValid", "Card")
        q = {"Card": "", "Creature": "creature", "Land": "land", "Artifact": "artifact", "Enchantment": "enchantment",
             "Instant": "instant", "Sorcery": "sorcery", "Planeswalker": "planeswalker"}.get(cv)
        if q is None or (dz == "Battlefield" and not q):
            raise Unmapped("dig for " + cv[:20])
        out = {"n": n, "q": q, "to": "hand" if dz == "Hand" else ("bft" if get("Tapped") == "True" else "bf")}
        if k != "1":
            out["k"] = int(k)
        if rest == "Graveyard":
            out["yard"] = 1
        used.add("Optional")
    else:
        raise Unmapped("api")
    extra = set(p) - STEP_IGNORED - used
    if extra:
        raise Unmapped("key " + sorted(extra)[0])
    return api, out


# What a count counts, and the steps that change it: a count after one of those would be
# worked out too early (the table counts when the ability starts to resolve).
COUNT_CHANGED_BY = {
    "v": {"Token", "ChangeZone", "Destroy", "Sacrifice", "DealDamage", "DamageAll", "Dig"},
    "yard": {"Mill", "Discard", "Sacrifice", "Destroy", "ChangeZone", "DealDamage", "DamageAll", "Dig"},
    "hand": {"Draw", "Discard", "ChangeZone", "Dig"},
    "life": {"GainLife", "LoseLife", "DealDamage", "DamageAll", "PayOrSac"},
    "ctr": {"PutCounter", "PutCounterAll", "Proliferate"},
    "pow": {"PutCounter", "PutCounterAll", "Pump", "PumpAll"},
    "tou": {"PutCounter", "PutCounterAll", "Pump", "PumpAll"},
    "domain": {"ChangeZone", "Destroy", "Sacrifice", "Dig"},
}


def counts_in(prm):
    return [m.group(1) for v in prm.values() for m in [re.search(r"\$([a-z]+)", str(v))] if m]


RETURN_KEYS = {"_api", "DB", "Defined", "Origin", "Destination", "SubAbility", "StackDescription", "SpellDescription",
               "GainControl", "ForgetOtherRemembered"}
DELAY_KEYS = {"_api", "DB", "Mode", "Phase", "Execute", "SubAbility", "StackDescription", "SpellDescription",
              "TriggerDescription", "RememberObjects", "ThisTurn", "AILogic", "ValidPlayer", "Secondary"}


def target_kinds(v):
    """ValidTgts -> ('creature/artifact', control you|opp|all, other?) for the table's own picker."""
    kinds, ctrl, other = [], "all", False
    for alt in v.split(","):
        head, _, rest = alt.strip().partition(".")
        if head not in TARGET_TYPES or head == "Card":
            raise Unmapped("target " + head)
        kinds.append(TARGET_TYPES[head])
        for pr in [x for x in rest.split("+") if x]:
            if pr in ("YouCtrl", "YouOwn"):
                ctrl = "you"
            elif pr == "OppCtrl":
                ctrl = "opp"
            elif pr in ("Other", "StrictlyOther"):
                other = True
            elif pr.startswith("non") and pr[3:] in TARGET_TYPES:
                kinds[-1] = "non" + TARGET_TYPES[pr[3:]]
            else:
                raise Unmapped("target prop " + re.sub(r"[^A-Za-z].*", "", pr))
    return "/".join(kinds), ctrl, other


def returns_it(q, delayed):
    """A step that puts the exiled card back onto the battlefield."""
    if q is None or q.get("_api") != "ChangeZone" or q.get("Origin") != "Exile" or q.get("Destination") != "Battlefield":
        return False
    names = ("DelayTriggerRememberedLKI", "DelayTriggerRemembered", "Remembered") if delayed else ("Remembered",)
    return q.get("Defined") in names and not (set(q) - RETURN_KEYS) and q.get("GainControl") in (None, "True")


def end_step_delay(q, svars):
    """'At the beginning of the next end step, ...': (the delayed step's params) or None."""
    if q is None or q.get("_api") != "DelayedTrigger" or q.get("Mode") != "Phase" \
            or q.get("Phase", "").lower() != "end of turn" or set(q) - DELAY_KEYS:
        return None
    return svars.get(q.get("Execute"))


LATER_KEYS = {"_api", "DB", "Defined", "Origin", "Destination", "StackDescription", "SpellDescription", "AILogic",
              "ValidCards", "SacValid"}


def at_step(p, svars):
    """'At the beginning of the next end step (end of combat), sacrifice / destroy / exile / return it':
    (('AtStep', params), next SubAbility) or None."""
    if p.get("_api") != "DelayedTrigger":
        return None
    st = {"end of turn": "end", "endcombat": "endcombat"}.get(p.get("Phase", "").lower())
    if p.get("Mode") != "Phase" or st is None or set(p) - DELAY_KEYS:
        raise Unmapped("delayed " + str(p.get("Mode")) + " " + str(p.get("Phase"))[:12])
    ro = p.get("RememberObjects")
    remembered = "self" if ro == "Self" else ("that" if ro in THAT_CARD else None)
    ex = svars.get(p.get("Execute"))
    if ex is None or set(ex) - LATER_KEYS:
        raise Unmapped("delayed step " + str(ex and sorted(set(ex) - LATER_KEYS)[:1]))
    d = ex.get("Defined", "")
    if ex.get("ValidCards") in ("Card.Self",) or d == "Self" or (ex["_api"] == "Sacrifice" and not d and not ex.get("SacValid")):
        of = "self"
    elif d.startswith(("DelayTriggerRemembered", "Remembered")) and remembered:
        of = remembered
    else:
        raise Unmapped("delayed of " + d[:20])
    api = ex["_api"]
    if api in ("Sacrifice", "SacrificeAll") and ex.get("SacValid") in (None, "Self"):
        what = "sac"
    elif api == "Destroy":
        what = "destroy"
    elif api == "ChangeZone" and ex.get("Origin") in (None, "Battlefield") and ex.get("Destination") in ("Exile", "Hand"):
        what = "exile" if ex["Destination"] == "Exile" else "bounce"
    else:
        raise Unmapped("delayed " + api)
    vp = p.get("ValidPlayer")
    if vp not in (None, "You", "Player"):
        raise Unmapped("delayed for " + vp[:16])
    out = {"do": what, "of": of, "st": st}
    if vp == "You":
        out["mine"] = 1                         # "your next end step"
    return ("AtStep", out), p.get("SubAbility")


def flicker(p, svars):
    """Exile something, then return it (now, or at the beginning of the next end step):
    (('Flicker', params), next SubAbility) or None."""
    if p.get("_api") != "ChangeZone" or p.get("Origin") != "Battlefield" or p.get("Destination") != "Exile" \
            or p.get("RememberChanged") != "True":
        return None
    known = {"_api", "DB", "AB", "Origin", "Destination", "RememberChanged", "ValidTgts", "Defined", "TgtPrompt",
             "SubAbility", "StackDescription", "SpellDescription", "Cost", "AILogic", "TargetMin", "TargetMax",
             "SorcerySpeed", "ActivationLimit", "IsCurse", "AITgts", "PrecostDesc", "CostDesc", "ValidTgtsDesc",
             "Mandatory", "Planeswalker", "Ultimate", "ActivationZone"}
    if set(p) - known or p.get("TargetMax", "1") != "1":
        raise Unmapped("flicker key " + sorted(set(p) - known or {"TargetMax"})[0])
    if "ValidTgts" in p:
        k, ctrl, other = target_kinds(p["ValidTgts"])
        out = {"on": "tgt", "k": k, "c": ctrl}
        if other:
            out["o"] = 1
    elif p.get("Defined") == "Self":
        out = {"on": "self"}
    elif p.get("Defined") in THAT_CARD:
        out = {"on": "that"}
    else:
        raise Unmapped("flicker of " + str(p.get("Defined"))[:16])
    nxt = svars.get(p.get("SubAbility"))
    if returns_it(nxt, False):
        out["when"] = "now"
    elif returns_it(end_step_delay(nxt, svars), True):
        out["when"] = "end"
    else:
        raise Unmapped("condition RememberChanged")
    after = nxt.get("SubAbility")
    if after and svars.get(after, {}).get("_api") == "Cleanup":
        after = svars[after].get("SubAbility")
    return ("Flicker", out), after


def chain(first, svars, tokens, raw, token_db, left=False, self_trigger=False):
    """Follow SubAbility$ from the first step: [(api, params)]. left: the trigger is this card
    (or the card that triggered it) leaving the battlefield, so its power and counters are gone."""
    steps, seen, p = [], set(), first
    while p is not None:
        fl = flicker(p, svars) or at_step(p, svars)
        if fl:
            steps.append(fl[0])
            if fl[1] is None:
                break
            if fl[1] in seen or fl[1] not in svars:
                raise Unmapped("subability")
            seen.add(fl[1])
            p = svars[fl[1]]
            continue
        unless = p.get("UnlessCost")
        for k in p:
            if k.startswith("Condition") or k in ("ConditionCheckSVar", "RememberChanged", "UnlessSwitched") \
                    or (k == "UnlessPayer" and p[k] != "You") \
                    or (k == "Optional" and p["_api"] != "Dig") \
                    or (k == "UnlessCost" and not (p["_api"] == "Sacrifice" and len(steps) == 0)):
                raise Unmapped("condition " + k)
            if k == "Defined" and p[k].startswith(("Remembered", "Targeted", "Triggered", "Parent", "Imprinted")) \
                    and p[k] not in ("TriggeredPlayer", "TriggeredTarget") and p[k] not in THAT_CARD:
                raise Unmapped("defined " + p[k][:20])
        q = dict(p)
        q.pop("UnlessCost", None)
        q.pop("UnlessPayer", None)
        s = step(q, tokens, raw, token_db, self_trigger)
        if s and unless is not None:
            # "Sacrifice ~ unless you pay {2}": the controller picks.
            if s[1].get("self") != 1 or not re.fullmatch(r"[0-9WUBRGCX ]+", unless) or "X" in unless:
                raise Unmapped("unless " + unless[:12])
            s = ("PayOrSac", {"cost": "".join("{%s}" % c for c in unless.split())})
        if s:
            for kind in counts_in(s[1]):
                if any(api in COUNT_CHANGED_BY.get(kind, ()) for api, _ in steps):
                    raise Unmapped("count after a change")
                if left and kind in ("pow", "tou", "ctr"):
                    raise Unmapped("count of a card that left")
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


def build(cardsfolder, tokenfolder, out, commit, token_data=None):
    tokens = load_tokens(tokenfolder)
    token_db = load_token_data(token_data or os.path.join(os.path.dirname(out), "token_data.lua"))
    data = {}
    total = mapped = 0
    api_ok, api_bad = collections.Counter(), collections.Counter()
    reasons = collections.defaultdict(collections.Counter)
    for root, _, files in os.walk(cardsfolder):
        for fn in sorted(files):
            if not fn.endswith(".txt"):
                continue
            for name, trigs, abs_, svars, raw, oracle in read_faces(os.path.join(root, fn)):
                if name.startswith("A-"):
                    continue
                items = []                         # (description, first step params, optional, left, own)
                for t in trigs:
                    ex = t.get("Execute")
                    if ex and ex in svars and t.get("TriggerDescription"):
                        left = t.get("Mode") in ("ChangesZone", "ChangesZoneAll", "Sacrificed", "Destroyed") \
                            and t.get("Origin") in ("Battlefield", None)
                        own = left and t.get("ValidCard", "") in ("Card.Self", "Creature.Self")
                        items.append((t["TriggerDescription"], svars[ex], "OptionalDecider" in t, left, own))
                for a in abs_:
                    if a.get("SpellDescription") and a["_api"] != "Mana":    # mana abilities: mana.lua
                        items.append((a["SpellDescription"], a, False, False, False))
                # A modal ability: each mode is its own entry, keyed by the mode's own text (the table
                # resolves the mode picked as a separate piece of text).
                for desc, first, optional, left, own in list(items):
                    if first.get("_api") == "Charm":
                        for c in first.get("Choices", "").split(","):
                            c = c.strip()
                            if c in svars and svars[c].get("SpellDescription"):
                                items.append((svars[c]["SpellDescription"], svars[c], False, left, own))
                entries, unread = [], []
                for desc, first, optional, left, own in items:
                    key = forge_key(desc, name)
                    if not key:
                        continue
                    total += 1
                    try:
                        if first.get("_api") == "Charm":
                            raise Unmapped("modal (modes mapped one by one)")
                        steps = chain(first, svars, tokens, raw, token_db, left, own)
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
        f.write("-- Amounts starting with $ are counted when the ability resolves (tools/forge_effects.py).\n")
        f.write("FORGE_EFFECTS = {\n")
        for name in sorted(data):
            f.write("  [%s] = %s,\n" % (lua_str(name), lua_str("\n".join(data[name]))))
        f.write("}\n")
    lines = ["Effects: %d of %d triggered/activated abilities and modes mapped (%.1f%%) on %d cards. Written: %s (%d KB)"
             % (mapped, total, 100.0 * mapped / max(1, total), len(data), os.path.basename(out), os.path.getsize(out) // 1024),
             "", "Mapped steps by ApiType:"]
    for api, n in api_ok.most_common():
        lines.append("  %6d  %s" % (n, api))
    lines += ["", "Abilities not mapped, by the ApiType of their first step (count, then the most common reasons):"]
    for api, n in api_bad.most_common():
        top = ", ".join("%s %d" % (r, c) for r, c in reasons[api].most_common(4))
        lines.append("  %6d  %-20s %s" % (n, api, top))
    return "\n".join(lines)
