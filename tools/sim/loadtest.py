"""
Belastningstest: hvor bliver GuildCrafters tung i en stor guild?

Kører den rigtige addon-kode (via simulatoren i sim.py) for ÉN målt klient i en guild med 600
medlemmer og måler vægtid, VM-instruktioner og antal kald for roster, søgning, tooltip, modtagelse af
store beskeder, GUILD_ROSTER_UPDATE og login. To profiler:

    A: 600 medlemmer, 10 med addonen
    B: 600 medlemmer, 200 med addonen

De andre addon-brugere findes som (1) rækker i guild-rosteren og (2) data i den målte klients cache,
leveret som rigtige serialiserede HELLO/DATA-beskeder i AceComm-chunks, så modtagevejen bliver brugt.
Ved login svarer de fra en Python-model af afsendersiden i Sync.lua + ChatThrottleLib (klassen Storm);
modellen er sammenlignet med rigtige klienter i relay_check().

    pip install lupa
    python tools/sim/loadtest.py                # begge profiler + relay-tjek (ca. 40 sekunder)
    python tools/sim/loadtest.py A              # kun profil A
    python tools/sim/loadtest.py B --json ud.json
    python tools/sim/loadtest.py --no-relay     # spring tjekket med rigtige relay-klienter over

Ændrer ikke addonen eller simulatoren: al instrumentering sættes på udefra, efter addonen er indlæst.
Tallene er relative (lupa = PUC Lua 5.1 som i WoW, men WoW's API-kald er C-kode og mock'ens er Lua).
"""
import heapq
import json
import os
import random
import re
import statistics
import sys
import time
from collections import defaultdict, deque

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sim  # noqa: E402  (simulatoren; kører kun scenarier under __main__)

perf = time.perf_counter

SEED = 20261013
MEMBERS = 600
PROFILES = {"A": 10, "B": 200}          # antal medlemmer med addonen (inkl. den målte klient)
ONLINE_ADDON = {"A": 2, "B": 30}        # hvor mange af de andre addon-brugere, der er online (15 %)
ONLINE_TOTAL = 90                       # 15 % af 600 er online, inkl. den målte klient
POOL = 300                              # recipes pr. profession i spillet
N_MATS = 250                            # forskellige crafting-mats
ME = "Pepsi"
ME_KEY = f"{ME}-{sim.REALM}"
PREFIX = "GCRAFT"
BASE_TIME = 1790000000                  # samme som i wowmock.lua
GBANK_TIME = BASE_TIME - 100            # scan-tidspunkt for guild banken i alles cache
ADDON_VERSION = sim.toc_version()

CLASSES = ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID"]
ITEM_PROFS = ["Alchemy", "Blacksmithing", "Engineering", "Jewelcrafting", "Leatherworking", "Tailoring",
              "Cooking"]
ALL_PROFS = ITEM_PROFS + ["Enchanting"]

# (classID, subclassID) pr. profession: bestemmer kategorien i Crafting-fanen.
PROF_ITEMS = {
    "Alchemy": (["Flask of", "Elixir of", "Potion of", "Major Potion of"], [(0, 1), (0, 2), (0, 3)]),
    "Blacksmithing": (["Breastplate of", "Helm of", "Blade of", "Gauntlets of"], [(4, 4), (4, 3), (2, 7)]),
    "Engineering": (["Goggles of", "Bomb of", "Device of", "Scope of"], [(4, 1), (7, 3), (2, 3), (6, 2)]),
    "Jewelcrafting": (["Ring of", "Gem of", "Necklace of", "Figurine of"], [(3, 0), (4, 0), (3, 1)]),
    "Leatherworking": (["Tunic of", "Boots of", "Leggings of", "Drums of"], [(4, 2), (4, 3), (7, 6)]),
    "Tailoring": (["Robe of", "Bag of", "Bolt of", "Cloak of"], [(4, 1), (1, 0), (7, 5)]),
    "Cooking": (["Stew of", "Roast of", "Feast of", "Soup of"], [(0, 5)]),
}
WORDS_A = ["Fel", "Primal", "Arcane", "Shadow", "Frost", "Fire", "Nether", "Storm", "Blood", "Sun", "Moon",
           "Void", "Iron", "Mithril", "Thorium", "Adamant", "Spirit", "Wild", "Night", "Dawn"]
WORDS_B = ["Might", "Wisdom", "Fury", "Grace", "Wrath", "Power", "Defense", "Insight", "Speed", "Fortitude",
           "Mastery", "Resolve", "Vigor", "Focus", "Ruin"]
STATS = ["Stamina", "Intellect", "Agility", "Strength", "Spirit", "Fire Resistance", "Frost Resistance",
         "Shadow Resistance", "Nature Resistance", "Arcane Resistance", "Spell Damage", "Healing",
         "Attack Power", "Critical Strike Rating", "Hit Rating", "Defense Rating", "Dodge Rating",
         "Mana every 5 seconds"]
ENCH_SLOTS = ["Bracer", "Chest", "Cloak", "Boots", "Gloves", "Weapon", "2H Weapon", "Shield", "Ring"]


# ----------------------------------------------------------------------
# Spildata: items, enchants, mats og reagents (ens for begge profiler)
# ----------------------------------------------------------------------

class Game:
    def __init__(self):
        rng = random.Random(SEED)
        self.items = {}         # id -> (navn, classID, subclassID, quality, required level, tooltip-tekst)
        self.spells = {}        # id -> (navn, tekst)
        self.pools = {}         # profession -> liste af recipe-id'er (item-id eller enchant-id)
        self.reagents = {}      # "i123"/"e456" -> [made, id, antal, id, antal, ...] (som i DATA-beskeden)
        self.mats = list(range(30000, 30000 + N_MATS))
        for n, mid in enumerate(self.mats):
            self.items[mid] = (f"{rng.choice(WORDS_A)} {['Ore', 'Bar', 'Cloth', 'Leather', 'Herb', 'Dust', 'Essence', 'Gem'][n % 8]} {n}",
                               7, n % 12, 1, 0, "")
        for p, prof in enumerate(ITEM_PROFS):
            prefixes, kinds = PROF_ITEMS[prof]
            combos = [(a, b) for a in WORDS_A for b in WORDS_B]
            rng.shuffle(combos)
            ids = []
            for j in range(POOL):
                iid = 20000 + p * 1000 + j
                a, b = combos[j]
                cls, sub = kinds[j % len(kinds)]
                lines = [f"+{rng.randint(4, 40)} {s}" for s in rng.sample(STATS, rng.randint(1, 4))]
                if cls == 0:
                    lines = [f"Use: Increases {rng.choice(STATS)} by {rng.randint(10, 120)} for 1 hour."]
                self.items[iid] = (f"{prefixes[j % len(prefixes)]} {a} {b}", cls, sub, 1 + j % 4,
                                   rng.choice([0, 10, 20, 30, 40, 50, 60, 70, 70]), ";".join(lines))
                ids.append(iid)
                self.reagents[f"i{iid}"] = self._reagents(rng, rng.choice([1, 1, 1, 5]))
            self.pools[prof] = ids
        ids = []
        for j in range(POOL):
            sid = 40000 + j
            stat = STATS[j % len(STATS)]
            self.spells[sid] = (f"Enchant {ENCH_SLOTS[j % len(ENCH_SLOTS)]} - {WORDS_A[j % len(WORDS_A)]} {stat}",
                                f"Permanently enchant to increase {stat} by {rng.randint(3, 30)}.")
            ids.append(sid)
            self.reagents[f"e{sid}"] = self._reagents(rng, 1)
        self.pools["Enchanting"] = ids

    def _reagents(self, rng, made):
        out = [made]
        for mid in rng.sample(self.mats, rng.randint(2, 4)):
            out += [mid, rng.randint(1, 20)]
        return out

    def items_lua(self):
        """Lua-kode, der registrerer items og spells i mock'en (sim_items, sim_spells, sim_spellText)."""
        parts = ["local I, S, T = sim_items, sim_spells, sim_spellText"]
        for iid, (name, cls, sub, quality, req, text) in self.items.items():
            parts.append(f"I[{iid}]={{name={json.dumps(name)},class={cls},sub={sub},quality={quality},"
                         f"req={req},text={json.dumps(text)}}}")
        for sid, (name, text) in self.spells.items():
            parts.append(f"S[{sid}]={json.dumps(name)} T[{sid}]={json.dumps(text)}")
        return "\n".join(parts)


# ----------------------------------------------------------------------
# Guilden: 600 medlemmer, heraf n med addonen og realistiske data
# ----------------------------------------------------------------------

class User:
    """Et guild-medlem med addonen: det, de ville sende i HELLO og DATA."""

    def __init__(self, key, cls, level, online):
        self.key, self.cls, self.level, self.online = key, cls, level, online
        self.profs = {}         # navn -> { rank, max, ids }
        self.mats = None        # { b = {id: antal}, k = {id: antal}, t = tid } eller None (deler ikke)
        self.v = {"info": 1, "recipes": 1, "mats": 0}
        self.spec, self.role, self.main = 1, "DPS", None

    def info(self):
        return {"class": self.cls, "level": self.level, "spec": self.spec, "role": self.role, "main": self.main,
                "profs": {n: [p["rank"], p["max"]] for n, p in self.profs.items()},
                "av": ADDON_VERSION, "ms": self.mats is not None}

    def hello(self, q=False):
        msg = self.info()
        msg.update({"t": "HELLO", "p": 2, "q": True if q else None, "gb": GBANK_TIME,
                    "v": {"info": self.v["info"], "recipes": self.v["recipes"],
                          "mats": self.v["mats"] if self.mats else None}})
        return msg

    def payload(self, kind, game):
        if kind == "info":
            return self.info()
        if kind == "mats":
            return self.mats
        profs, g = {}, {}
        for name, p in self.profs.items():
            ench = name == "Enchanting"
            profs[name] = {"i": [] if ench else p["ids"], "e": p["ids"] if ench else []}
            for rid in p["ids"]:
                rkey = ("e" if ench else "i") + str(rid)
                g[rkey] = game.reagents[rkey]
        return {"p": profs, "g": g}

    def data(self, kind, game):
        return {"t": "DATA", "p": 2, "c": self.key, "k": kind, "v": self.v[kind], "d": self.payload(kind, game)}

    def recipe_count(self):
        return sum(len(p["ids"]) for p in self.profs.values())


class Guild:
    def __init__(self, game, n_addon, n_online_addon):
        rng = random.Random(SEED * 1000 + n_addon)
        syl = ["ka", "lo", "mi", "ra", "ve", "tu", "shi", "no", "be", "da", "gor", "thal", "an", "el", "ur", "ix",
               "zo", "fen", "my", "qua", "dre", "sa", "ol", "hi"]
        names = set()
        while len(names) < MEMBERS - 1:
            name = "".join(rng.choice(syl) for _ in range(rng.randint(2, 4))).capitalize()
            if name not in (ME, "Helper") and len(name) <= 12:
                names.add(name)
        names = sorted(names)
        rng.shuffle(names)
        n_users = n_addon - 1
        online = set(names[:n_online_addon])                              # addon-brugere, der er online
        online |= set(rng.sample(names[n_users:], ONLINE_TOTAL - 1 - n_online_addon))
        self.members = []       # (navn, level, class, online) i roster-rækkefølge
        self.users = []         # medlemmer med addonen (uden den målte klient)
        for i, name in enumerate(names):
            cls = rng.choice(CLASSES)
            level = 70 if rng.random() < 0.6 else rng.randint(10, 69)
            self.members.append((name, level, cls, name in online))
            if i < n_users:
                u = User(f"{name}-{sim.REALM}", cls, level, name in online)
                for prof in rng.sample(ALL_PROFS, 2):
                    n = rng.randint(50, 300)
                    u.profs[prof] = {"rank": 75 + n, "max": 375, "ids": sorted(rng.sample(game.pools[prof], n))}
                u.spec = rng.randint(1, 3)
                u.role = rng.choice(["TANK", "HEALER", "DPS", "DPS"])
                if rng.random() < 0.3:
                    u.mats = {"b": {m: rng.randint(1, 200) for m in rng.sample(game.mats, rng.randint(20, 60))},
                              "k": {m: rng.randint(1, 400) for m in rng.sample(game.mats, rng.randint(10, 40))},
                              "t": BASE_TIME - rng.randint(600, 86400 * 5)}
                    u.v["mats"] = rng.randint(1, 200)
                u.v["info"], u.v["recipes"] = rng.randint(1, 20), rng.randint(1, 40)
                self.users.append(u)
        for u in self.users:    # 10 % er alts af en anden addon-bruger
            if len(self.users) > 1 and rng.random() < 0.1:
                u.main = rng.choice([o for o in self.users if o is not u]).key
        rng.shuffle(self.members)
        self.by_key = {u.key: u for u in self.users}
        self.gbank = {1: {m: rng.randint(1, 400) for m in rng.sample(game.mats, 60)},
                      2: {m: rng.randint(1, 400) for m in rng.sample(game.mats, 40)}}

    def online_users(self):
        return [u for u in self.users if u.online]

    def offline_users(self):
        return [u for u in self.users if not u.online]

    def stats(self):
        pairs = sum(u.recipe_count() for u in self.users)
        distinct = set()
        crafters = defaultdict(int)
        for u in self.users:
            for name, p in u.profs.items():
                for rid in p["ids"]:
                    distinct.add(rid)
                    crafters[rid] += 1
        return {"addon_users": len(self.users) + 1, "online_addon": len(self.online_users()) + 1,
                "char_recipe_pairs": pairs, "distinct_recipes": len(distinct),
                "max_crafters_per_recipe": max(crafters.values()) if crafters else 0,
                "mats_sharers": sum(1 for u in self.users if u.mats)}

    def hot_item(self):
        """Det item, flest kan crafte (til tooltip-målingen)."""
        crafters = defaultdict(int)
        for u in self.users:
            for name, p in u.profs.items():
                if name != "Enchanting":
                    for rid in p["ids"]:
                        crafters[rid] += 1
        return max(sorted(crafters), key=lambda r: crafters[r])


# ----------------------------------------------------------------------
# Tråd-format: AceSerializer (den rigtige, i en hjælpeklient) + AceComm-chunks
# ----------------------------------------------------------------------

def lua_lit(v):
    """Python-værdi som Lua-tabeltekst. None-felter udelades."""
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(lua_lit(x) for x in v) + "}"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            if x is None:
                continue
            key = f"[{k}]" if isinstance(k, int) else f"[{json.dumps(k)}]"
            parts.append(f"{key}={lua_lit(x)}")
        return "{" + ",".join(parts) + "}"
    raise TypeError(repr(v))


def chunks(text):
    """Deler en serialiseret besked op præcis som AceComm:SendCommMessage (kontrol-byte + 254 bytes)."""
    if len(text) <= 255:
        return [text]
    n = 254
    out = ["\x01" + text[:n]]
    pos = n
    while pos + n < len(text):
        out.append("\x02" + text[pos:pos + n])
        pos += n
    out.append("\x03" + text[pos:])
    return out


class Reassembler:
    """Samler chunks fra én afsender til hele beskeder (som AceComm på modtagersiden)."""

    def __init__(self):
        self.partial = {}

    def feed(self, sender, channel, target, text):
        k = (sender, channel, target)
        c = text[:1]
        if c == "\x01":
            self.partial[k] = [text[1:]]
            return None
        if c == "\x02":
            self.partial.setdefault(k, []).append(text[1:])
            return None
        if c == "\x03":
            parts = self.partial.pop(k, [])
            parts.append(text[1:])
            return "".join(parts)
        return text[1:] if c == "\x04" else text


class LoadWorld(sim.World):
    """sim.World med aflytning af sendte beskeder og måling pr. tick."""

    def __init__(self):
        super().__init__()
        self.rng = random.Random(SEED)
        self.tap = None         # fn(sender, prefix, text, channel, target) for alt, der sendes
        self.model = None       # Storm: de andre addon-brugeres afsenderside
        self.rec = None         # liste af (tid, vægtid, instruktioner, beskeder, bytes) pr. tick
        self.instr = None       # fn() -> løbende instruktionstæller i den målte klient
        self.inbound = defaultdict(int)

    def send(self, sender, prefix, text, channel, target):
        if self.tap:
            self.tap(sender, prefix, text, channel, target)
        super().send(sender, prefix, text, channel, target)

    def inject(self, client, text, sender_key, channel="GUILD", delay=0.1):
        self.queue.append((self.now + delay, client, PREFIX, text, channel, sender_key))

    def step(self, seconds, dt=0.1):
        end = self.now + seconds
        while self.now < end - 1e-9:
            self.now = round(self.now + dt, 3)
            if self.model:
                self.model.tick(self.now, dt)
            due = [m for m in self.queue if m[0] <= self.now]
            if due:
                self.queue = [m for m in self.queue if m[0] > self.now]
            n0 = self.instr() if self.instr else 0
            nbytes = 0
            t0 = perf()
            for _, client, prefix, text, channel, sender in due:
                if client.online:
                    client.L.globals().sim_deliver(prefix, text, channel, sender)
                    nbytes += len(text)
                    kind = "echo" if sender == client.key else "in"
                    self.inbound[kind + "_chunks"] += 1
                    self.inbound[kind + "_bytes"] += len(text)
            for c in self.clients:
                if c.online:
                    c.L.globals().sim_tick()
            wall = perf() - t0
            if self.rec is not None:
                self.rec.append((self.now, wall, (self.instr() - n0) if self.instr else 0, len(due), nbytes))


class Helper:
    """En ekstra klient i sin egen verden. Bruges kun til at serialisere og afkode beskeder med den
    rigtige AceSerializer (og til at tjekke chunks() mod den rigtige AceComm)."""

    def __init__(self):
        self.world = LoadWorld()
        self.c = sim.Client(self.world, "Helper", "MAGE", 70)
        L = self.c.L
        self._ser = L.eval('function(src) return LibStub("AceSerializer-3.0"):Serialize('
                           'assert(loadstring("return " .. src))()) end')
        self._dec = L.eval('''function(text)
            local ok, m = LibStub("AceSerializer-3.0"):Deserialize(text)
            if not ok or type(m) ~= "table" then return "?", nil, nil, 0, 0, false, 0, 0, 0 end
            local n = 0
            if m.t == "INVR" and type(m.l) == "table" then for _ in pairs(m.l) do n = n + 1 end end
            local hv = type(m.v) == "table" and m.v or {}
            return m.t, m.c, m.k, m.h or 0, type(m.v) == "number" and m.v or 0, m.q and true or false, n,
                hv.recipes or 0, hv.mats or 0
        end''')
        self.cache = {}

    def ser(self, msg):
        return self._ser(lua_lit(msg))

    def decode(self, text):
        t, c, k, h, v, q, n, hr, hm = self._dec(text)
        return {"t": t, "c": c, "k": k, "h": h, "v": v, "q": q, "n": n, "hv_recipes": hr, "hv_mats": hm,
                "size": len(text)}

    def text(self, user, kind, game, q=False):
        """Serialiseret HELLO/DATA for en bruger i den aktuelle version (gemmes, så det kun laves én gang)."""
        if kind == "mats" and not user.mats:
            return None
        key = (user.key, kind, q, user.v.get(kind, 0), user.v["info"], user.v["recipes"], user.v["mats"])
        if key not in self.cache:
            self.cache[key] = self.ser(user.hello(q) if kind == "hello" else user.data(kind, game))
        return self.cache[key]

    def check_chunker(self):
        """Sender en besked på 3000 bytes gennem den rigtige AceComm/ChatThrottleLib og sammenligner med chunks()."""
        seen = []
        self.world.tap = lambda s, p, text, ch, tg: seen.append(text)
        self.c.login()
        self.world.step(40)     # klientens egen HELLO skal være sendt, før vi lytter
        text = self.ser({"t": "X", "p": 2, "d": list(range(100000, 100420))})
        del seen[:]
        self.c.L.eval('function(ns, text) ns.Comm:SendCommMessage("GCRAFT", text, "GUILD", nil, "BULK") end')(
            self.c.ns, text)
        self.world.step(20)
        self.world.tap = None
        return seen == chunks(text), len(text), len(seen)


# ----------------------------------------------------------------------
# Instrumentering i den målte klient (sættes på udefra, efter addonen er indlæst)
# ----------------------------------------------------------------------

INSTRUMENT = r'''
local ns = ...
lt = { counts = {}, times = {}, ns = ns }
local counts, times = lt.counts, lt.times
local clock = lt_py_clock
local getinfo, sethook, getupvalue, setupvalue = debug.getinfo, debug.sethook, debug.getupvalue, debug.setupvalue

local function finish(label, t0, ...)
    times[label] = times[label] + (clock() - t0)
    return ...
end

-- Tæller kald til tbl[name]; med timed også samlet tid (inkl. det, funktionen selv kalder).
function lt.wrap(tbl, name, label, timed)
    local orig = tbl[name]
    assert(type(orig) == "function", "mangler " .. label)
    counts[label] = 0
    if timed then
        times[label] = 0
        tbl[name] = function(...)
            counts[label] = counts[label] + 1
            return finish(label, clock(), orig(...))
        end
    else
        tbl[name] = function(...)
            counts[label] = counts[label] + 1
            return orig(...)
        end
    end
end

local function upvalue(fn, name)
    local i = 1
    while true do
        local n, v = getupvalue(fn, i)
        if not n then return nil end
        if n == name then return v, i end
        i = i + 1
    end
end
lt.upvalue = upvalue

-- WoW-API (mock) og Compat
lt.wrap(_G, "GetGuildRosterInfo", "GetGuildRosterInfo")
lt.wrap(_G, "GetNumGuildMembers", "GetNumGuildMembers")
lt.wrap(ns.Compat, "GetGuildMembers", "GetGuildMembers", true)
lt.wrap(ns.Compat, "IsGuildMember", "IsGuildMember", true)
lt.wrap(ns.Compat, "TooltipText", "TooltipText")
lt.wrap(ns.Compat, "ItemDetails", "ItemDetails")
do  -- GetItemInfo er en local i Compat.lua: byt den delte upvalue ud med en tæller.
    local orig, i = upvalue(ns.Compat.ItemName, "GetItemInfo")
    counts.GetItemInfo = 0
    setupvalue(ns.Compat.ItemName, i, function(...)
        counts.GetItemInfo = counts.GetItemInfo + 1
        return orig(...)
    end)
end

-- Transport og sync
local Ser = LibStub("AceSerializer-3.0")
lt.wrap(Ser, "Deserialize", "Deserialize", true)
lt.wrap(Ser, "Serialize", "Serialize", true)
lt.wrap(ns.Comm, "OnCommReceived", "OnCommReceived", true)
lt.wrap(ns.Comm, "Send", "Comm.Send", true)
do  -- bytes afleveret til AceComm (ligger derefter i ChatThrottleLib's kø)
    local orig = ns.Comm.SendCommMessage
    counts.SendBytes = 0
    ns.Comm.SendCommMessage = function(self, prefix, text, ...)
        counts.SendBytes = counts.SendBytes + #text
        return orig(self, prefix, text, ...)
    end
end
lt.wrap(ns.Data, "ApplyPayload", "ApplyPayload", true)
lt.wrap(ns.Data, "BuildPayload", "BuildPayload", true)
lt.wrap(ns.Data, "HeldVersion", "HeldVersion")
lt.wrap(ns.Sync, "QueueReq", "QueueReq")
lt.orig = { Crafters = ns.Index.Crafters }     -- den rigtige funktion, før tælleren sættes på
lt.wrap(ns.Index, "Find", "Index.Find", true)
lt.wrap(ns.Index, "Crafters", "Index.Crafters")
lt.wrap(ns.Index, "Holders", "Index.Holders")
lt.wrap(ns.UI, "RequestRefresh", "RequestRefresh")
do
    local orig = ns.Fire
    ns.Fire = function(self, message, ...)
        local k = "Fire:" .. tostring(message)
        counts[k] = (counts[k] or 0) + 1
        return orig(self, message, ...)
    end
end

-- Rebuild er en local i Index.lua: Crafters -> Ensure -> Rebuild. Tæl og tag tid på hvert kald.
do
    local Ensure = upvalue(lt.orig.Crafters, "Ensure")
    local Rebuild, i = upvalue(Ensure, "Rebuild")
    lt.Rebuild = Rebuild
    counts.Rebuild, times.Rebuild = 0, 0
    setupvalue(Ensure, i, function()
        counts.Rebuild = counts.Rebuild + 1
        local t0 = clock()
        Rebuild()
        times.Rebuild = times.Rebuild + (clock() - t0)
    end)
    lt.searchText = upvalue(ns.Index.SearchText, "searchText")
end

-- Fanernes Refresh (locals i UI-filerne) ligger i Frame.lua's tabs-tabel.
do
    local tabs = upvalue(ns.UI.AddTab, "tabs")
    lt.refresh = {}
    for _, tab in ipairs(tabs) do
        local orig, label = tab.refresh, "Refresh:" .. tab.label
        lt.refresh[tab.label] = orig
        counts[label], times[label] = 0, 0
        tab.refresh = function(...)
            counts[label] = counts[label] + 1
            return finish(label, clock(), orig(...))
        end
    end
end

-- BuildInventory (local i Sync.lua): HELLO-handleren -> PlanInventory -> BuildInventory.
do
    local handlers = upvalue(ns.Comm.Handle, "handlers")
    local PlanInventory = upvalue(handlers.HELLO, "PlanInventory")
    lt.BuildInventory = upvalue(PlanInventory, "BuildInventory")
end

function lt.reset()
    for k in pairs(counts) do counts[k] = 0 end
    for k in pairs(times) do times[k] = 0 end
end

-- VM-instruktioner: count-hook for hver N instruktioner. "profile" husker også, hvilken funktion der kørte.
local prof = { n = 0, by = {}, interval = 1000 }
local function hookCount() prof.n = prof.n + 1 end
local function hookProfile()
    prof.n = prof.n + 1
    local info = getinfo(2, "S")
    if info then
        local key = info.short_src .. ":" .. info.linedefined
        prof.by[key] = (prof.by[key] or 0) + 1
    end
end
function lt.prof_start(mode, interval)
    prof.n, prof.by, prof.interval = 0, {}, interval
    sethook(mode == "profile" and hookProfile or hookCount, "", interval)
end
function lt.prof_stop()
    sethook()
    return prof.n * prof.interval, prof.by
end
function lt.prof_n() return prof.n * prof.interval end

-- Allokering: stop GC, mål hvor meget hukommelsen vokser, start GC igen.
function lt.gc_begin()
    collectgarbage("collect")
    collectgarbage("stop")
    return collectgarbage("count")
end
function lt.gc_end()
    local kb = collectgarbage("count")
    collectgarbage("restart")
    return kb
end
function lt.mem()
    collectgarbage("collect")
    return collectgarbage("count")
end

-- Tæller kald til Index:IsOnline og Compat.PlayerKey under ét kald af fn. Tællerne sættes kun på her:
-- de kaldes så ofte, at en fast tæller ville forstyrre tidsmålingerne.
function lt.count_hot(fn)
    local isOnline, playerKey = 0, 0
    local o1, o2 = ns.Index.IsOnline, ns.Compat.PlayerKey
    ns.Index.IsOnline = function(...) isOnline = isOnline + 1 return o1(...) end
    ns.Compat.PlayerKey = function(...) playerKey = playerKey + 1 return o2(...) end
    fn()
    ns.Index.IsOnline, ns.Compat.PlayerKey = o1, o2
    return isOnline, playerKey
end

function lt.toggle(i)
    local m = sim_roster[i]
    m.online = not m.online
end
function lt.chars()
    local guild, n, withRecipes = ns.Data:GetGuild(), 0, 0
    for _, c in pairs(guild and guild.chars or {}) do
        n = n + 1
        if c.dataV and (c.dataV.recipes or 0) > 0 then withRecipes = withRecipes + 1 end
    end
    return n, withRecipes
end
function lt.frames() return #sim_allFrames end
'''

SHORT = {"GetGuildMembers": "GGM", "GetGuildRosterInfo": "GGRI", "Deserialize": "Deser", "Serialize": "Ser",
         "TooltipText": "TipScan", "GetItemInfo": "ItemInfo", "Fire:ROSTER_CHANGED": "ROSTER_CHANGED",
         "Fire:DATA_CHANGED": "DATA_CHANGED", "Fire:INDEX_CHANGED": "INDEX_CHANGED",
         "Index.Crafters": "Crafters()", "Index.Holders": "Holders()", "Index.Find": "Find"}
HIDE = {"GetNumGuildMembers", "OnCommReceived", "Fire:ITEM_NAMES", "Fire:LOGIN", "Fire:ME_CHANGED",
        "Comm.Send", "Fire:CRAFTLIST_CHANGED", "SendBytes"}

_src = {}


def func_name(key):
    """ "Index.lua:42" -> "Index.lua:42 Rebuild" (funktionsnavnet læses fra kildefilen)."""
    path, _, line = key.rpartition(":")
    full = os.path.join(sim.ADDON, path.replace("\\", os.sep).replace("/", os.sep))
    if not os.path.isfile(full) or not line.isdigit() or int(line) <= 0:
        return key
    if full not in _src:
        _src[full] = open(full, encoding="utf-8").read().split("\n")
    text = _src[full][int(line) - 1].strip()
    m = (re.search(r"function\s+([\w.:]+)\s*\(", text) or re.search(r"(\w+)\s*=\s*function", text)
         or re.search(r'(?:On|RegisterEvent|Handle)\("(\w+)"', text))
    return f"{key} {m.group(1) if m else text[:32]}"


def split_sources(by):
    """Fordeler profil-samples på addon / libs / mock+måleudstyr."""
    addon = libs = other = 0
    for key, n in by.items():
        if key.startswith("Libs"):
            libs += n
        elif key.startswith("[string") or key.startswith("loadtest") or key.startswith("[C]"):
            other += n
        else:
            addon += n
    return addon, libs, other


class Bench:
    def __init__(self, me, rows, profile):
        self.me, self.rows, self.profile = me, rows, profile
        self.lt = me.g.lt
        self.group = ""

    def counts(self):
        out = {k: int(v) for k, v in self.lt.counts.items() if v}
        return out

    def times(self):
        return {k: v * 1000 for k, v in self.lt.times.items() if v}

    def _row(self, label, walls, instr, by, calls, alloc, note, once=False):
        total = sum(by.values()) or 1
        addon, libs, other = split_sources(by)
        interval = instr / total if by else 0
        top = sorted(((n, k) for k, n in by.items() if not k.startswith("[string") and not k.startswith("loadtest")),
                     reverse=True)[:4]
        row = {
            "profile": self.profile, "group": self.group, "label": label,
            "wall_ms": statistics.median(walls) * 1000, "wall_min_ms": min(walls) * 1000,
            "instr": instr, "instr_addon": addon * interval, "instr_libs": libs * interval,
            "instr_mock": other * interval, "alloc_kb": alloc, "calls": calls, "note": note, "once": once,
            "top": [(func_name(k), round(n * interval)) for n, k in top],
        }
        self.rows.append(row)
        return row

    def run(self, label, fn, reps=5, setup=None, note=""):
        """Gentagelig operation: én kørsel med profil-hook (instruktioner, kald), én med stoppet GC
        (allokering) og reps kørsler uden hook (vægtid, median)."""
        lt = self.lt
        if setup:
            setup()
        lt.reset()
        lt.prof_start("profile", 100)
        fn()
        instr, by = lt.prof_stop()
        by = dict(by.items())
        calls = self.counts()
        if setup:
            setup()
        before = lt.gc_begin()
        fn()
        alloc = lt.gc_end() - before
        walls = []
        for _ in range(reps):
            if setup:
                setup()
            t0 = perf()
            fn()
            walls.append(perf() - t0)
        return self._row(label, walls, instr, by, calls, alloc, note)

    def once(self, label, fn, note=""):
        """Operation, der kun kan køres én gang: profil-hook for hver 1000 instruktioner (vægtid ca. 5 % for høj)."""
        lt = self.lt
        lt.reset()
        lt.prof_start("profile", 1000)
        t0 = perf()
        fn()
        wall = perf() - t0
        instr, by = lt.prof_stop()
        return self._row(label, [wall], instr, dict(by.items()), self.counts(), None, note, once=True)

    def info(self, label, note, **extra):
        row = {"profile": self.profile, "group": self.group, "label": label, "note": note, "info": True}
        row.update(extra)
        self.rows.append(row)
        return row


def tick_stats(rec, baseline=0.0):
    """Sammendrag af målinger pr. tick: (tid, vægtid, instruktioner, beskeder, bytes)."""
    if not rec:
        return {}
    walls = sorted(r[1] for r in rec)
    worst = max(rec, key=lambda r: r[1])
    worst_i = max(rec, key=lambda r: r[2])
    return {
        "ticks": len(rec), "sum_ms": sum(walls) * 1000, "max_ms": walls[-1] * 1000,
        "p99_ms": walls[int(len(walls) * 0.99) - 1] * 1000 if len(walls) >= 100 else walls[-1] * 1000,
        "max_at": worst[0], "max_tick_instr": worst_i[2], "max_tick_instr_at": worst_i[0],
        "sum_instr": sum(r[2] for r in rec),
        "over_5ms": sum(1 for w in walls if w > 0.005), "over_16ms": sum(1 for w in walls if w > 0.0167),
        "over_50ms": sum(1 for w in walls if w > 0.05), "over_200ms": sum(1 for w in walls if w > 0.2),
        "msgs": sum(r[3] for r in rec), "bytes": sum(r[4] for r in rec),
        "idle_ms": baseline * 1000,
    }


def new_me(world, game, saved=None):
    """Den målte klient: Tailoring + Enchanting med 150 recipes hver, lidt mats i tasken."""
    rng = random.Random(SEED + 1)
    profs = []
    for name in ("Tailoring", "Enchanting"):
        ids = sorted(rng.sample(game.pools[name], 150))
        kind = "e" if name == "Enchanting" else "i"
        profs.append({"name": name, "rank": 375, "max": 375, "recipes": ids,
                      "reagents": {i: game.reagents[kind + str(i)][1:] for i in ids}})
    bags = {0: [(m, rng.randint(1, 20)) for m in rng.sample(game.mats, 12)]}
    me = sim.Client(world, ME, "PRIEST", 70, profs=profs, talents=(5, 31, 15), bags=bags, saved=saved)
    L = me.L
    L.execute(f"math.randomseed({SEED})")
    L.execute(game.items_lua())
    me.g.lt_py_clock = perf
    L.eval('function(code, ns) assert(loadstring(code, "=loadtest"))(ns) end')(INSTRUMENT, me.ns)
    world.instr = me.g.lt.prof_n
    return me


def errors_of(client):
    return [e for _, e in client.g.sim_errors.items()]


# ----------------------------------------------------------------------
# Storm: de andre online addon-brugeres afsenderside som Python-model
# ----------------------------------------------------------------------

class Msg:
    __slots__ = ("t", "c", "k", "v", "chunks", "size")

    def __init__(self, t, text, c=None, k=None, v=0):
        self.t, self.c, self.k, self.v = t, c, k, v
        self.chunks = chunks(text)
        self.size = len(text)


class Relay:
    __slots__ = ("user", "avail", "normal", "bulk", "plans", "inv", "last_hello")

    def __init__(self, user):
        self.user = user
        self.avail = 4000.0     # ChatThrottleLib.BURST: en klient, der har været stille, må sende 4000 bytes straks
        self.normal, self.bulk = deque(), deque()
        self.plans = {}         # "key|kind" -> { v, cancelled }   (dataPlanned i Sync.lua)
        self.inv = None         # { seen = bool }                   (invPlanned i Sync.lua)
        self.last_hello = -100.0


class Storm:
    """De andre online addon-brugere set fra den målte klient. Følger reglerne i Sync.lua:
      HELLO med q   -> hver svarer med HELLO efter 1-5 s og planlægger INVR efter 2-8 s; INVR droppes kun,
                       hvis en HEL INVR, der dækker den, er modtaget inden da.
      REQ           -> ejeren (online) svarer efter 0.2-1 s; for offline chars planlægger ALLE, der har data,
                       DATA efter 2-6 s og dropper den kun, hvis en HEL DATA i samme version er modtaget inden da.
    Afsendelse begrænses som i ChatThrottleLib: 4000 bytes straks, derefter 800 bytes/s pr. klient,
    40 bytes overhead pr. chunk, NORMAL (HELLO) før BULK (INVR/DATA).
    ideal=True er det, protokollen sigter efter: én INVR og én DATA pr. REQ."""

    def __init__(self, world, me, helper, game, guild, ideal=False, me_known=True):
        self.world, self.me, self.helper, self.game, self.guild, self.ideal = world, me, helper, game, guild, ideal
        self.rng = random.Random(SEED + 7)
        self.relays = {u.key: Relay(u) for u in guild.online_users()}
        self.events = []
        self.seq = 0
        self.asm = Reassembler()
        self.me_held = {"recipes": 10 ** 9, "mats": 10 ** 9} if me_known else {"recipes": 0, "mats": 0}
        self.me_req_planned = set()
        self.inflight = set()           # (ideal) DATA, der allerede er på vej
        self.sent = defaultdict(int)    # det, modellen har sendt: beskeder/bytes pr. type
        self.me_sent = defaultdict(int) # det, den målte klient har sendt
        self.newcomer = None
        self._invr = {}
        self.hello_at = None            # hvornår den målte klient sendte sin første HELLO med q
        self.req_log = []               # (sekunder efter den HELLO, char, kind, held) for hver REQ, den sendte

    # -- tid --
    def at(self, when, fn, *args):
        self.seq += 1
        heapq.heappush(self.events, (when, self.seq, fn, args))

    def tick(self, now, dt):
        while self.events and self.events[0][0] <= now:
            _, _, fn, args = heapq.heappop(self.events)
            fn(*args)
        for r in self.relays.values():
            r.avail = min(4000.0, r.avail + 800.0 * dt)
            while True:
                q = r.normal or r.bulk
                if not q:
                    break
                msg, i = q[0]
                chunk = msg.chunks[i]
                if r.avail < len(chunk) + 40:
                    break
                r.avail -= len(chunk) + 40
                self.world.inject(self.me, chunk, r.user.key)
                self.sent["chunks"] += 1
                self.sent["bytes"] += len(chunk)
                if i + 1 == len(msg.chunks):
                    q.popleft()
                    self.sent[msg.t if msg.t != "DATA" else "DATA " + msg.k] += 1
                    self.at(now + 0.1, self.completed, r.user.key, msg)
                else:
                    q[0] = (msg, i + 1)

    def backlog(self):
        total = 0
        for r in self.relays.values():
            for q in (r.normal, r.bulk):
                for msg, i in q:
                    total += sum(len(c) for c in msg.chunks[i:])
        return total

    # -- det, den målte klient sender --
    def on_send(self, sender, prefix, text, channel, target):
        if sender is not self.me or prefix != PREFIX:
            return
        full = self.asm.feed(sender.key, channel, target, text)
        self.me_sent["chunks"] += 1
        self.me_sent["bytes"] += len(text)
        if full is None:
            return
        m = self.helper.decode(full)
        self.me_sent[m["t"] if m["t"] != "DATA" else "DATA " + str(m["k"])] += 1
        now = self.world.now
        if m["t"] == "HELLO":
            if m["q"]:
                self.at(now + 0.1, self.hello_q, ME_KEY)
                if self.hello_at is None:
                    self.hello_at = now
            # Kender de andre ikke vores data endnu, beder én af dem om dem (resten ser den REQ).
            for kind in ("recipes", "mats"):
                if m["hv_" + kind] > self.me_held[kind] and kind not in self.me_req_planned and self.relays:
                    self.me_req_planned.add(kind)
                    r = self.rng.choice(list(self.relays.values()))
                    self.at(now + 0.1 + self.rng.uniform(0.5, 3), self.enqueue, r, "normal",
                            Msg("REQ", self.helper.ser({"t": "REQ", "p": 2, "c": ME_KEY, "k": kind, "h": 0})))
        elif m["t"] == "REQ":
            self.at(now + 0.1, self.req, m["c"], m["k"], m["h"])
            self.req_log.append((now - (self.hello_at or 0), m["c"], m["k"], m["h"]))
        elif m["t"] in ("DATA", "INVR"):
            if m["t"] == "DATA" and m["c"] == ME_KEY:
                self.me_held[m["k"]] = m["v"]
                self.me_req_planned.discard(m["k"])
            self.at(now + 0.1, self.completed, ME_KEY, Msg(m["t"], "", m["c"], m["k"], m["v"]))

    # -- reglerne fra Sync.lua --
    def enqueue(self, relay, prio, msg):
        getattr(relay, prio).append((msg, 0))

    def hello_q(self, newcomer):
        now = self.world.now
        self.newcomer = newcomer
        first = True
        for r in self.relays.values():
            if r.user.key == newcomer:
                continue
            delay = max(self.rng.uniform(1, 5), r.last_hello + 10 - now)
            self.at(now + delay, self.send_hello, r)
            if r.inv is None and (not self.ideal or first):
                r.inv = {"seen": False}
                self.at(now + self.rng.uniform(2, 8), self.fire_invr, r, newcomer)
            first = False

    def send_hello(self, r):
        r.last_hello = self.world.now
        self.enqueue(r, "normal", Msg("HELLO", self.helper.text(r.user, "hello", self.game)))

    def invr_msg(self, exclude):
        if exclude not in self._invr:
            entries = {u.key: [u.v["info"], u.v["recipes"], u.v["mats"] if u.mats else 0]
                       for u in self.guild.offline_users() if u.key != exclude}
            self._invr[exclude] = Msg("INVR", self.helper.ser({"t": "INVR", "p": 2, "l": entries})) if entries else None
        return self._invr[exclude]

    def fire_invr(self, r, newcomer):
        plan, r.inv = r.inv, None
        msg = self.invr_msg(newcomer)
        if msg and not plan["seen"]:
            self.enqueue(r, "bulk", msg)

    def req(self, key, kind, held):
        now = self.world.now
        u = self.guild.by_key.get(key)
        if not u or u.v.get(kind, 0) <= held or (kind == "mats" and not u.mats):
            return
        if key in self.relays:
            self.plan(self.relays[key], key, kind, self.rng.uniform(0.2, 1))
        elif self.ideal:
            if (key, kind) not in self.inflight:
                self.inflight.add((key, kind))
                self.plan(self.rng.choice(list(self.relays.values())), key, kind, self.rng.uniform(2, 6))
        else:
            for r in self.relays.values():
                self.plan(r, key, kind, self.rng.uniform(2, 6))

    def plan(self, r, key, kind, delay):
        pid = key + "|" + kind
        if pid in r.plans:
            return
        plan = {"v": self.guild.by_key[key].v[kind], "cancelled": False}
        r.plans[pid] = plan
        self.at(self.world.now + delay, self.fire_data, r, key, kind, plan)

    def fire_data(self, r, key, kind, plan):
        r.plans.pop(key + "|" + kind, None)
        if plan["cancelled"]:
            return
        u = self.guild.by_key[key]
        self.enqueue(r, "bulk", Msg("DATA", self.helper.text(u, kind, self.game), key, kind, u.v[kind]))

    def completed(self, sender_key, msg):
        """En hel besked er nået frem til alle: de andre aflyser det, den dækker."""
        if msg.t == "DATA":
            self.inflight.discard((msg.c, msg.k))
        for r in self.relays.values():
            if r.user.key == sender_key:
                continue
            if msg.t == "INVR" and r.inv:
                r.inv["seen"] = True
            elif msg.t == "DATA":
                plan = r.plans.get(msg.c + "|" + msg.k)
                if plan and msg.v >= plan["v"]:
                    plan["cancelled"] = True

    def replay_req(self, sender_key, key, kind, held):
        """En REQ fra en anden (afspillet): den målte klient og modellens relays ser den samtidig."""
        self.world.inject(self.me, self.helper.ser({"t": "REQ", "p": 2, "c": key, "k": kind, "h": held}),
                          sender_key)
        if key != ME_KEY:
            self.at(self.world.now + 0.1, self.req, key, kind, held)

    # -- en anden addon-bruger logger ind (den målte klient er tilskuer og svarer selv rigtigt) --
    def third_party_login(self, user):
        self.world.inject(self.me, self.helper.text(user, "hello", self.game, q=True), user.key)
        self.at(self.world.now + 0.1, self.hello_q, user.key)


# ----------------------------------------------------------------------
# Målinger for én profil
# ----------------------------------------------------------------------

def run_profile(name, game, helper, rows):
    n_addon = PROFILES[name]
    guild = Guild(game, n_addon, ONLINE_ADDON[name])
    world = LoadWorld()
    world.ghosts = list(guild.members)
    me = new_me(world, game)
    L, g = me.L, me.g
    lt = g.lt
    b = Bench(me, rows, name)
    fire, deliver = g.sim_fire, g.sim_deliver
    gstats = guild.stats()
    print(f"\n=== Profile {name}: {MEMBERS} members, {n_addon} with the addon "
          f"({gstats['online_addon']} online), {gstats['char_recipe_pairs']} char/recipe pairs, "
          f"{gstats['distinct_recipes']} distinct recipes, max {gstats['max_crafters_per_recipe']} crafters "
          f"per recipe, {gstats['mats_sharers']} share mats ===", flush=True)

    # ------------------------------------------------------------------ login (ingen andre svarer)
    b.group = "0 Login and cache"
    lt.reset()
    lt.prof_start("count", 1000)
    world.rec = []
    t0 = perf()
    me.login()
    login_wall = perf() - t0
    me.open_trade("Tailoring")
    me.open_craft("Enchanting")
    me.slash("mats on")
    world.step(40)
    instr, _ = lt.prof_stop()
    calls = b.counts()
    ts = tick_stats(world.rec)
    world.rec = None
    b.info("login + 40 s alone (nobody answers; 2 GUILD_ROSTER_UPDATE events, 2 profession scans)",
           f"GetGuildMembers x{calls.get('GetGuildMembers', 0)}, GetGuildRosterInfo x{calls.get('GetGuildRosterInfo', 0)}, "
           f"IsGuildMember x{calls.get('IsGuildMember', 0)}; max tick {ts['max_ms']:.2f} ms ({ts['max_tick_instr']} instr)",
           wall_ms=ts["sum_ms"] + login_wall * 1000, instr=instr, calls=calls, ticks=ts)

    # ------------------------------------------------------------------ fyld cachen via rigtige beskeder
    lt.prof_start("count", 1000)
    lt.reset()
    mem0 = lt.mem()
    agg = defaultdict(lambda: {"msgs": 0, "bytes": 0, "chunks": 0, "final": [], "pre": 0.0, "instr": 0})
    for u in guild.users:
        for kind in ("hello", "recipes", "mats"):
            text = helper.text(u, kind, game)
            if text is None:
                continue
            cs = chunks(text)
            n0 = lt.prof_n()
            t0 = perf()
            for c in cs[:-1]:
                deliver(PREFIX, c, "GUILD", u.key)
            t1 = perf()
            deliver(PREFIX, cs[-1], "GUILD", u.key)
            t2 = perf()
            a = agg[kind]
            a["msgs"] += 1
            a["bytes"] += len(text)
            a["chunks"] += len(cs)
            a["pre"] += t1 - t0
            a["final"].append(t2 - t1)
            a["instr"] += lt.prof_n() - n0
    deliver(PREFIX, helper.ser({"t": "GBANK", "p": 2, "s": GBANK_TIME, "d": guild.gbank}), "GUILD",
            guild.users[0].key)
    lt.prof_stop()
    ingest_calls = b.counts()
    ingest_times = b.times()
    fire("GUILD_ROSTER_UPDATE")
    world.step(5)
    mem1 = lt.mem()
    nchars, with_recipes = lt.chars()
    for kind, a in agg.items():
        b.info(f"ingest {a['msgs']} x {'HELLO' if kind == 'hello' else 'DATA ' + kind}",
               f"{a['bytes'] / a['msgs']:.0f} B avg, {a['chunks'] / a['msgs']:.1f} chunks avg; "
               f"last chunk median {statistics.median(a['final']) * 1000:.2f} ms, "
               f"max {max(a['final']) * 1000:.2f} ms; reassembly {a['pre'] * 1000:.1f} ms total",
               wall_ms=(sum(a["final"]) + a["pre"]) * 1000, instr=a["instr"],
               bytes=a["bytes"], chunks=a["chunks"], msgs=a["msgs"],
               max_ms=max(a["final"]) * 1000, median_ms=statistics.median(a["final"]) * 1000)
    b.info("cache after ingest", f"{nchars} chars ({with_recipes} with recipes), Lua heap {mem0 / 1024:.1f} -> "
           f"{mem1 / 1024:.1f} MB", calls=ingest_calls, times=ingest_times, heap_mb=mem1 / 1024, chars=nchars)
    assert nchars == len(guild.users), (nchars, len(guild.users))

    # ------------------------------------------------------------------ 5: GUILD_ROSTER_UPDATE, vindue lukket
    b.group = "5 Roster update (window closed)"
    b.run("GUILD_ROSTER_UPDATE, window closed (RefreshOnline)", lambda: fire("GUILD_ROSTER_UPDATE"), reps=15)
    get_members = L.eval("function() return #lt.ns.Compat.GetGuildMembers() end")
    b.run("Compat.GetGuildMembers() alone", get_members, reps=15)

    # ------------------------------------------------------------------ 3: tooltip og Rebuild
    b.group = "3 Tooltip / Index.Rebuild"
    hot = guild.hot_item() if guild.users else game.pools["Tailoring"][0]
    hot_mat = game.mats[0]
    tip = L.eval('function(id) GameTooltip:SetHyperlink("item:" .. id) end')
    mark_dirty = L.eval("function() lt.ns.Index:MarkDirty() end")
    tip(hot)
    world.step(2)               # item-navnet skal være indlæst
    tip(hot)
    lines = [l for _, l in g.GameTooltip.sim_lines.items()]
    b.run("Index Rebuild() alone", lt.Rebuild, reps=9)
    b.run("item tooltip, index clean", lambda: tip(hot), reps=15, note=(lines[-1] if lines else "")[:60])
    b.run("item tooltip, index dirty (first hover after a roster update)", lambda: tip(hot), reps=9,
          setup=mark_dirty)
    b.run("mat tooltip (Guild has), index clean", lambda: tip(hot_mat), reps=15)
    b.run("tooltip for an item nobody crafts, index clean", lambda: tip(6948), reps=15)

    # 10 minutter: hover hvert 2. sekund, roster-opdatering hvert 15. sekund, vinduet lukket.
    rng = random.Random(SEED + 3)
    hover_items = rng.sample(game.pools["Alchemy"] + game.pools["Tailoring"] + game.mats, 40)
    for i in hover_items:
        tip(i)
    world.step(2)
    lt.reset()
    tips, events = [], []
    idle = []
    for second in range(1, 601):
        world.rec = idle if second <= 20 else None
        world.step(1.0)
        if second % 15 == 0:
            lt.toggle(rng.randint(1, MEMBERS - 1))
            t0 = perf()
            fire("GUILD_ROSTER_UPDATE")
            events.append(perf() - t0)
        if second % 2 == 0:
            item = hover_items[(second // 2) % len(hover_items)]
            t0 = perf()
            tip(item)
            tips.append(perf() - t0)
    world.rec = None
    calls, times = b.counts(), b.times()
    idle_ms = statistics.median(r[1] for r in idle) * 1000
    b.info("10 min: hover an item every 2 s + roster update every 15 s",
           f"{len(events)} roster updates -> {calls.get('Rebuild', 0)} Rebuilds "
           f"({times.get('Rebuild', 0):.0f} ms total, {times.get('Rebuild', 0) / max(1, calls.get('Rebuild', 0)):.1f} ms each); "
           f"{len(tips)} tooltips {sum(tips) * 1000:.0f} ms total, max {max(tips) * 1000:.1f} ms, "
           f"median {statistics.median(tips) * 1000:.3f} ms; roster events {sum(events) * 1000:.0f} ms total",
           calls=calls, rebuilds=calls.get("Rebuild", 0), rebuild_ms=times.get("Rebuild", 0),
           tooltip_ms=sum(tips) * 1000, tooltip_max_ms=max(tips) * 1000, roster_ms=sum(events) * 1000,
           roster_updates=len(events), idle_tick_ms=idle_ms)

    # ------------------------------------------------------------------ 5 (fortsat): INVR, whisper
    b.group = "5b HELLO / INVR / whisper"
    some = guild.online_users()[0] if guild.online_users() else guild.users[0]
    hello = helper.text(some, "hello", game)
    b.run("receive HELLO (GUILD)", lambda: deliver(PREFIX, hello, "GUILD", some.key), reps=15,
          note=f"{len(hello)} B")
    b.run("receive HELLO (WHISPER: IsGuildMember scans the roster)",
          lambda: deliver(PREFIX, hello, "WHISPER", some.key), reps=15)
    deliver(PREFIX, hello, "GUILD", some.key)        # viaWhisper tilbage til false
    build_inv = L.eval("function(key) local n = 0 for _ in pairs(lt.BuildInventory(key)) do n = n + 1 end return n end")
    n_inv = build_inv(some.key)
    b.run("BuildInventory() (INVR list for a HELLO with q)", lambda: build_inv(some.key), reps=15,
          note=f"{n_inv} offline chars listed")
    # Hele udvekslingen: HELLO med q fra en online bruger -> vi svarer med HELLO + INVR.
    lt.reset()
    sent0 = len(world.sent)
    world.rec = []
    lt.prof_start("count", 1000)
    world.inject(me, helper.text(some, "hello", game, q=True), some.key)
    world.step(30)
    lt.prof_stop()
    ts = tick_stats(world.rec, idle_ms / 1000)
    world.rec = None
    out = world.sent[sent0:]
    calls = b.counts()
    b.info("HELLO-with-q exchange (we answer HELLO + INVR), 30 s",
           f"sent {len(out)} chunks / {sum(m[3] for m in out)} B; max tick {ts['max_ms']:.2f} ms "
           f"({ts['max_tick_instr']} instr); GetGuildMembers calls: {calls.get('GetGuildMembers', 0)}",
           calls=calls, ticks=ts, sent_chunks=len(out), sent_bytes=sum(m[3] for m in out))

    # INVR med alle offline chars i de versioner, vi allerede har (ingen REQ): ren modtageomkostning.
    invr_entries = {u.key: [u.v["info"], u.v["recipes"], u.v["mats"] if u.mats else 0]
                    for u in guild.offline_users()}
    invr = helper.ser({"t": "INVR", "p": 2, "l": invr_entries})
    invr_chunks = chunks(invr)

    def invr_pre():
        for c in invr_chunks[:-1]:
            deliver(PREFIX, c, "GUILD", some.key)
    if len(invr_chunks) > 1:
        b.run(f"receive INVR ({len(invr_entries)} chars, nothing new): last chunk",
              lambda: deliver(PREFIX, invr_chunks[-1], "GUILD", some.key), reps=9, setup=invr_pre,
              note=f"{len(invr)} B, {len(invr_chunks)} chunks")
    else:
        b.run(f"receive INVR ({len(invr_entries)} chars, nothing new)",
              lambda: deliver(PREFIX, invr, "GUILD", some.key), reps=9, note=f"{len(invr)} B, 1 chunk")
    world.step(2)

    # ------------------------------------------------------------------ 4: stor DATA-besked
    b.group = "4 Large DATA payload"
    big = User(f"Bigcrafter-{sim.REALM}", "MAGE", 70, False)
    big.profs["Alchemy"] = {"rank": 375, "max": 375, "ids": list(game.pools["Alchemy"])}
    big.v["recipes"] = 0
    deliver(PREFIX, helper.ser(big.hello()), "GUILD", big.key)
    world.step(4)               # REQ'en for recipes bliver sendt; svaret kommer herunder

    def next_big():
        big.v["recipes"] += 1
        return chunks(helper.ser(big.data("recipes", game)))
    state = {"chunks": next_big()}
    big_text_len = sum(len(c) - 1 for c in state["chunks"])
    n_chunks = len(state["chunks"])

    def big_pre():
        state["chunks"] = next_big()
        for c in state["chunks"][:-1]:
            deliver(PREFIX, c, "GUILD", big.key)

    def big_first_chunks():
        for c in state["chunks"][:-1]:
            deliver(PREFIX, c, "GUILD", big.key)

    def big_last():
        deliver(PREFIX, state["chunks"][-1], "GUILD", big.key)

    b.run(f"DATA recipes 300 + reagents 300: chunks 1..{n_chunks - 1} (AceComm reassembly)", big_first_chunks,
          reps=9, note=f"{big_text_len} B, {n_chunks} chunks")
    row = b.run("DATA recipes: last chunk = deserialize + validate + apply + events", big_last, reps=9,
                setup=big_pre)
    row["bytes"], row["chunks"] = big_text_len, n_chunks
    lt.reset()
    big_pre()
    big_last()
    row["times"] = b.times()

    def dup_pre():
        for c in state["chunks"][:-1]:
            deliver(PREFIX, c, "GUILD", big.key)
    b.run("DATA recipes: duplicate copy (same version: deserialize + validate only)", big_last, reps=9,
          setup=dup_pre)
    full = "".join(c[1:] for c in state["chunks"])
    deser = L.eval('function(text) return (LibStub("AceSerializer-3.0"):Deserialize(text)) end')
    b.run("  of which AceSerializer:Deserialize", lambda: deser(full), reps=9)
    apply_direct = L.eval('''function(text, key, v)
        local ok, msg = LibStub("AceSerializer-3.0"):Deserialize(text)
        return function() v = v + 1; lt.ns.Data:ApplyPayload(key, "recipes", v, msg.d) end
    end''')(full, big.key, big.v["recipes"] + 1000)
    b.run("  of which Data:ApplyPayload + DATA_CHANGED listeners", apply_direct, reps=9)
    big.v["recipes"] += 5000
    if guild.users and any(u.mats for u in guild.users):
        mu = next(u for u in guild.users if u.mats)
        mats_text = helper.text(mu, "mats", game)
        mats_chunks = chunks(mats_text)

        def mats_all():
            for c in mats_chunks:
                deliver(PREFIX, c, "GUILD", mu.key)
        b.run("DATA mats (same version: deserialize + validate)", mats_all, reps=9,
              note=f"{len(mats_text)} B, {len(mats_chunks)} chunks, {len(mu.mats['b'])}+{len(mu.mats['k'])} items")
    world.step(2)
    build_own = L.eval('''function()
        local d = lt.ns.Data:BuildPayload(lt.ns.Compat.PlayerKey(), "recipes")
        return #LibStub("AceSerializer-3.0"):Serialize({ t = "DATA", c = lt.ns.Compat.PlayerKey(), k = "recipes", v = 1, d = d, p = 2 })
    end''')
    own_size = build_own()
    b.run("answer a REQ for our own recipes: BuildPayload + Serialize (300 recipes)", build_own, reps=9,
          note=f"{own_size} B")
    send_own = L.eval('''function()
        local key = lt.ns.Compat.PlayerKey()
        lt.ns.Comm:Send({ t = "DATA", c = key, k = "recipes", v = lt.ns.Data:HeldVersion(key, "recipes"),
            d = lt.ns.Data:BuildPayload(key, "recipes") }, "GUILD", nil, "BULK")
    end''')
    b.once("  ... + Comm:Send (AceComm split + ChatThrottleLib queue)", send_own)
    world.rec = []
    lt.reset()
    world.step(45)
    ts = tick_stats(world.rec)
    world.rec = None
    calls = b.counts()
    b.info("  ... draining the send queue (45 s) + our own echo coming back",
           f"max tick {ts['max_ms']:.2f} ms, total {ts['sum_ms']:.1f} ms; Deserialize x{calls.get('Deserialize', 0)} "
           f"(our own DATA echo is deserialized and validated too)", ticks=ts, calls=calls)

    # ------------------------------------------------------------------ 1: Roster-fanen
    b.group = "1 Roster tab"
    show_tab = L.eval("function(label) lt.ns.UI:ShowTab(label) end")
    b.once("open window on Roster tab (first time: creates frames + Refresh)", lambda: show_tab("Roster"))
    world.step(1)
    b.run("Roster.Refresh() (600 rows built, 18 shown)", lt.refresh.Roster, reps=15)
    set_roster_search = L.eval("function(t) GuildCraftersRosterSearch:SetText(t) end")
    b.run("Roster search box: 'alch' (Refresh with search)", lambda: set_roster_search("alch"), reps=15)
    set_roster_search("")
    b.run("GUILD_ROSTER_UPDATE, Roster tab open: the event itself", lambda: fire("GUILD_ROSTER_UPDATE"), reps=15)
    world.step(1)
    lt.reset()
    world.rec = []
    fire("GUILD_ROSTER_UPDATE")
    world.step(1)
    ts = tick_stats(world.rec)
    world.rec = None
    calls = b.counts()
    b.info("GUILD_ROSTER_UPDATE with Roster tab open: event + refresh 0.3 s later",
           f"GetGuildMembers x{calls.get('GetGuildMembers', 0)}, GetGuildRosterInfo x{calls.get('GetGuildRosterInfo', 0)}, "
           f"Refresh:Roster x{calls.get('Refresh:Roster', 0)}; max tick {ts['max_ms']:.2f} ms", calls=calls, ticks=ts)

    # ------------------------------------------------------------------ 2: Crafting-fanen og søgning
    b.group = "2 Crafting tab / search"
    b.once("open Crafting tab, item names cold (creates frames + Refresh)", lambda: show_tab("Crafting"))
    world.rec = []
    lt.reset()
    lt.prof_start("count", 1000)
    world.step(3)
    lt.prof_stop()
    ts = tick_stats(world.rec)
    world.rec = None
    calls = b.counts()
    b.info("item info arrives (mock: all in one tick) + ITEM_NAMES refresh, 3 s",
           f"max tick {ts['max_ms']:.1f} ms ({ts['max_tick_instr']} instr); Refresh:Crafting x{calls.get('Refresh:Crafting', 0)}",
           calls=calls, ticks=ts)
    find = L.eval("function(f) return #lt.ns.Index:Find(f) end")
    wipe_search = L.eval("function() wipe(lt.searchText) end")

    def flt(**kw):
        return L.table_from(kw)
    n_all = find(flt())
    b.run("Index:Find{} (all recipes, warm)", lambda: find(flt()), reps=7, note=f"{n_all} results")
    n_fire = find(flt(query="fire"))
    b.run("Index:Find{query='fire'}, search text cold (tooltip scan per recipe)", lambda: find(flt(query="fire")),
          reps=5, setup=wipe_search, note=f"{n_fire} results")
    b.run("Index:Find{query='fire'}, warm", lambda: find(flt(query="fire")), reps=7, note=f"{n_fire} results")
    b.run("Index:Find{top='Armor'}", lambda: find(flt(top="Armor")), reps=7)
    b.run("Index:Find{onlineOnly}", lambda: find(flt(onlineOnly=True)), reps=7)
    if guild.users:
        crafter = max(guild.users, key=lambda u: u.recipe_count())
        b.run("Index:Find{crafter=X} (By crafter view)", lambda: find(flt(crafter=crafter.key)), reps=7,
              note=f"{crafter.recipe_count()} recipes")
    set_query = L.eval("function(t) GuildCraftersCraftingSearch:SetText(t) end")
    b.run("search box: one keystroke -> full Crafting Refresh ('fire', warm)", lambda: set_query("fire"), reps=7)
    set_query("")
    b.run("Crafting Refresh, no query, index clean", lt.refresh.Crafting, reps=7)
    b.run("Crafting Refresh after a roster update (index dirty -> Rebuild)", lt.refresh.Crafting, reps=7,
          setup=mark_dirty)
    n_online, n_key = lt.count_hot(lt.refresh.Crafting)
    b.info("hot calls inside ONE Crafting Refresh (no query)",
           f"Index:IsOnline x{int(n_online)}, Compat.PlayerKey x{int(n_key)} "
           f"(each PlayerKey = UnitName + GetNormalizedRealmName + a string concat)",
           is_online=int(n_online), player_key=int(n_key))
    world.step(1)
    lt.reset()
    world.rec = []
    fire("GUILD_ROSTER_UPDATE")
    world.step(1)
    ts = tick_stats(world.rec)
    calls = b.counts()
    b.info("GUILD_ROSTER_UPDATE with Crafting tab open: event + refresh 0.3 s later",
           f"Rebuild x{calls.get('Rebuild', 0)}, Refresh:Crafting x{calls.get('Refresh:Crafting', 0)}; "
           f"max tick {ts['max_ms']:.1f} ms", calls=calls, ticks=ts)
    # Stor DATA, mens Crafting-fanen er åben: modtagelse + Refresh 0.3 s senere.
    lt.reset()
    world.rec = []
    lt.prof_start("count", 1000)
    for c in next_big():
        world.inject(me, c, big.key, delay=0.05)
    world.step(1)
    lt.prof_stop()
    ts = tick_stats(world.rec)
    world.rec = None
    calls = b.counts()
    b.info("large DATA while Crafting tab is open: receive tick + refresh tick",
           f"max tick {ts['max_ms']:.1f} ms ({ts['max_tick_instr']} instr), sum {ts['sum_ms']:.1f} ms; "
           f"Rebuild x{calls.get('Rebuild', 0)}, Refresh:Crafting x{calls.get('Refresh:Crafting', 0)}",
           calls=calls, ticks=ts)

    # ------------------------------------------------------------------ Mats-fanen
    b.group = "7 Mats tab"
    b.once("open Mats tab (first time)", lambda: show_tab("Mats"))
    world.step(2)
    b.run("Mats Refresh (warm)", lt.refresh.Mats, reps=7)
    frames = lt.frames()
    world.rec = []
    world.step(3)
    b.info("idle tick with the window open", f"{statistics.median(r[1] for r in world.rec) * 1000:.3f} ms "
           f"(mock: {frames} widgets polled per tick); window closed: {idle_ms:.3f} ms")
    world.rec = None

    errs = errors_of(me)
    saved = me.logout()
    b.info("Lua errors (main run)", f"{len(errs)}" + (f": {errs[0][:200]}" if errs else ""), errors=errs)
    return guild, saved


# ----------------------------------------------------------------------
# 6: login, mens de andre addon-brugere svarer
# ----------------------------------------------------------------------

def run_login(name, game, helper, guild, rows, saved, ideal, label, seconds=120, bystander=False):
    world = LoadWorld()
    world.ghosts = list(guild.members)
    me = new_me(world, game, saved=saved)
    lt = me.g.lt
    b = Bench(me, rows, name)
    b.group = "6 Login storm"
    storm = Storm(world, me, helper, game, guild, ideal=ideal, me_known=saved is not None)
    world.tap, world.model = storm.on_send, storm
    lt.reset()
    lt.prof_start("count", 1000)
    world.rec = []
    t0 = perf()
    me.login()
    login_ms = (perf() - t0) * 1000
    if saved is None:           # ny installation: professions åbnes lige efter login
        me.open_trade("Tailoring")
        me.open_craft("Enchanting")
        me.slash("mats on")
    world.step(seconds)
    lt.prof_stop()
    ts = tick_stats(world.rec)
    calls, times = b.counts(), b.times()
    nchars, with_recipes = lt.chars()
    inbound = dict(world.inbound)
    summary = {
        "in_chunks": inbound.get("in_chunks", 0), "in_bytes": inbound.get("in_bytes", 0),
        "echo_chunks": inbound.get("echo_chunks", 0),
        "in_msgs": {k: v for k, v in storm.sent.items() if k not in ("chunks", "bytes")},
        "out": dict(storm.me_sent), "queue_req": calls.get("QueueReq", 0),
        "deserialize": calls.get("Deserialize", 0), "deserialize_ms": times.get("Deserialize", 0),
        "apply": calls.get("ApplyPayload", 0), "apply_ms": times.get("ApplyPayload", 0),
        "oncomm_ms": times.get("OnCommReceived", 0), "backlog_bytes": storm.backlog(),
        "chars": nchars, "chars_with_recipes": with_recipes, "ggm": calls.get("GetGuildMembers", 0),
        "ggri": calls.get("GetGuildRosterInfo", 0), "login_call_ms": login_ms,
    }
    out = storm.me_sent
    b.info(f"{label}: first {seconds} s",
           f"IN {summary['in_chunks']} chunks / {summary['in_bytes'] / 1024:.0f} KB "
           f"({', '.join(f'{k} x{v}' for k, v in sorted(summary['in_msgs'].items()))}); "
           f"OUT {out.get('chunks', 0)} chunks / {out.get('bytes', 0) / 1024:.1f} KB "
           f"({', '.join(f'{k} x{v}' for k, v in sorted(out.items()) if k not in ('chunks', 'bytes'))}); "
           f"QueueReq called x{summary['queue_req']}; Deserialize x{summary['deserialize']} = {summary['deserialize_ms']:.0f} ms; "
           f"ApplyPayload x{summary['apply']}; Lua total {ts['sum_ms']:.0f} ms, max tick {ts['max_ms']:.1f} ms "
           f"({ts['max_tick_instr']} instr), ticks >5 ms: {ts['over_5ms']}, >16.7 ms: {ts['over_16ms']}, "
           f">50 ms: {ts['over_50ms']}; relay backlog {summary['backlog_bytes'] / 1024:.0f} KB; "
           f"cache: {with_recipes} chars with recipes (guild has {len(guild.users)}); "
           f"GetGuildMembers x{summary['ggm']}",
           ticks=ts, calls=calls, times=times, summary=summary)

    if bystander and len(guild.online_users()) >= 2:
        # Ro på først; derefter logger en anden addon-bruger ind, og vi er en af dem, der svarer.
        # Først med vinduet lukket, så med Crafting-fanen åben (hver DATA_CHANGED giver en Refresh).
        show_tab = me.L.eval("function(label) lt.ns.UI:ShowTab(label) end")
        for i, title in enumerate(("window closed", "Crafting tab open")):
            if i == 1:
                show_tab("Crafting")
            world.rec = None
            world.step(120)
            assert storm.backlog() == 0, storm.backlog()
            who = guild.online_users()[-1 - i]
            world.inbound.clear()
            storm.sent.clear()
            storm.me_sent.clear()
            lt.reset()
            lt.prof_start("count", 1000)
            world.rec = []
            storm.third_party_login(who)
            world.step(60)
            lt.prof_stop()
            ts = tick_stats(world.rec)
            calls, times = b.counts(), b.times()
            out = storm.me_sent
            b.info(f"someone else logs in (we are one of the online addon users), {title}: 60 s",
                   f"IN {world.inbound.get('in_chunks', 0)} chunks / {world.inbound.get('in_bytes', 0) / 1024:.0f} KB "
                   f"({', '.join(f'{k} x{v}' for k, v in sorted(storm.sent.items()) if k not in ('chunks', 'bytes'))}); "
                   f"OUT {out.get('chunks', 0)} chunks / {out.get('bytes', 0) / 1024:.1f} KB "
                   f"({', '.join(f'{k} x{v}' for k, v in sorted(out.items()) if k not in ('chunks', 'bytes'))}); "
                   f"Deserialize x{calls.get('Deserialize', 0)} = {times.get('Deserialize', 0):.0f} ms; "
                   f"Refresh:Crafting x{calls.get('Refresh:Crafting', 0)} = {times.get('Refresh:Crafting', 0):.0f} ms; "
                   f"Rebuild x{calls.get('Rebuild', 0)}; "
                   f"Lua total {ts['sum_ms']:.0f} ms, max tick {ts['max_ms']:.1f} ms ({ts['max_tick_instr']} instr), "
                   f"ticks >5 ms: {ts['over_5ms']}, >50 ms: {ts['over_50ms']}, >200 ms: {ts['over_200ms']}",
                   ticks=ts, calls=calls, times=times,
                   summary={"in_chunks": world.inbound.get("in_chunks", 0),
                            "in_bytes": world.inbound.get("in_bytes", 0),
                            "in_msgs": dict(storm.sent), "out": dict(out)})
    world.rec = None
    errs = errors_of(me)
    if errs:
        b.info(f"Lua errors ({label})", f"{len(errs)}: {errs[0][:200]}", errors=errs)
    return errs, storm.req_log


def run_relay_role(name, game, helper, guild, rows, saved, req_log, seconds=120):
    """Den målte klient (fuld cache) er en af dem, der svarer, når en ANDEN logger ind med tom cache.
    Den nyankomnes REQ'er er dem, den målte klient selv sendte i sit kolde login (afspillet)."""
    world = LoadWorld()
    world.ghosts = list(guild.members) + [("Newbie", 70, "MAGE", True)]
    me = new_me(world, game, saved=saved)
    lt = me.g.lt
    b = Bench(me, rows, name)
    b.group = "6 Login storm"
    storm = Storm(world, me, helper, game, guild, ideal=False, me_known=True)
    world.tap, world.model = storm.on_send, storm
    me.login()
    world.step(150)             # vores eget (varme) login skal være overstået
    assert storm.backlog() == 0, storm.backlog()
    newbie = User(f"Newbie-{sim.REALM}", "MAGE", 70, True)
    newbie.v = {"info": 1, "recipes": 0, "mats": 0}
    world.inbound.clear()
    storm.sent.clear()
    storm.me_sent.clear()
    lt.reset()
    lt.prof_start("count", 1000)
    world.rec = []
    start = world.now
    world.inject(me, helper.ser(newbie.hello(q=True)), newbie.key)
    storm.at(start + 0.1, storm.hello_q, newbie.key)
    storm.at(start + 8, storm.replay_req, newbie.key, ME_KEY, "recipes", 0)
    for t, key, kind, held in req_log:
        if t <= seconds:
            storm.at(start + t, storm.replay_req, newbie.key, key, kind, held)
    world.step(seconds)
    lt.prof_stop()
    ts = tick_stats(world.rec)
    world.rec = None
    calls, times = b.counts(), b.times()
    out = storm.me_sent
    handed = calls.get("SendBytes", 0)
    b.info(f"we are a relay while a newcomer with an empty cache logs in (replayed {len(req_log)} REQs): {seconds} s",
           f"IN {world.inbound.get('in_chunks', 0)} chunks / {world.inbound.get('in_bytes', 0) / 1024:.0f} KB; "
           f"BuildPayload x{calls.get('BuildPayload', 0)} = {times.get('BuildPayload', 0):.0f} ms, "
           f"Serialize x{calls.get('Serialize', 0)} = {times.get('Serialize', 0):.0f} ms, "
           f"Comm:Send x{calls.get('Comm.Send', 0)} = {times.get('Comm.Send', 0):.0f} ms; "
           f"handed to AceComm {handed / 1024:.0f} KB, actually sent {out.get('bytes', 0) / 1024:.0f} KB "
           f"({', '.join(f'{k} x{v}' for k, v in sorted(out.items()) if k not in ('chunks', 'bytes'))}), "
           f"still queued in ChatThrottleLib ~{max(0, handed - out.get('bytes', 0)) / 1024:.0f} KB; "
           f"Deserialize x{calls.get('Deserialize', 0)} = {times.get('Deserialize', 0):.0f} ms; "
           f"Lua total {ts['sum_ms']:.0f} ms, max tick {ts['max_ms']:.1f} ms ({ts['max_tick_instr']} instr), "
           f"ticks >5 ms: {ts['over_5ms']}, >16.7 ms: {ts['over_16ms']}, >50 ms: {ts['over_50ms']}",
           ticks=ts, calls=calls, times=times)
    return errors_of(me)


# ----------------------------------------------------------------------
# Tjek af Storm-modellen mod rigtige klienter: sender flere relays virkelig hver sin kopi?
# ----------------------------------------------------------------------

def relay_check(game, helper, rows, n_relays=6, n_offline=150):
    """Én ny klient logger ind i en guild, hvor n_relays rigtige klienter alle har data om n_offline
    offline chars (kun info) og én offline char med 300 recipes. Tæller, hvor mange INVR- og
    DATA-kopier der faktisk bliver sendt."""
    rng = random.Random(SEED + 11)
    world = LoadWorld()
    asm = Reassembler()
    sent = defaultdict(int)
    copies = defaultdict(int)

    def tap(sender, prefix, text, channel, target):
        if prefix != PREFIX:
            return
        sent["chunks"] += 1
        sent["bytes"] += len(text)
        full = asm.feed(sender.key, channel, target, text)
        if full is None:
            return
        m = helper.decode(full)
        kind = m["t"] if m["t"] != "DATA" else "DATA " + str(m["k"])
        sent[kind] += 1
        sent[kind + " bytes"] += m["size"]
        if m["t"] == "DATA":
            copies[(m["c"], m["k"])] += 1
    offline = []
    for i in range(n_offline):
        u = User(f"Off{chr(97 + i // 26)}{chr(97 + i % 26)}x-{sim.REALM}", rng.choice(CLASSES), 70, False)
        u.profs = {"Mining": {"rank": 300, "max": 375, "ids": []}}
        u.v = {"info": 3, "recipes": 0, "mats": 0}
        offline.append(u)
    bigoff = User(f"Bigoff-{sim.REALM}", "MAGE", 70, False)
    bigoff.profs = {"Alchemy": {"rank": 375, "max": 375, "ids": list(game.pools["Alchemy"])}}
    bigoff.v = {"info": 2, "recipes": 5, "mats": 0}
    world.ghosts = [(u.key.split("-")[0], 70, u.cls, False) for u in offline + [bigoff]]
    relays = []
    for i in range(n_relays):
        c = sim.Client(world, f"Relay{chr(97 + i)}", "MAGE", 70)
        c.L.execute(f"math.randomseed({SEED + i})")
        relays.append(c)
        c.login()
    world.step(40)
    # Fyld alle relays' cache direkte (ingen trafik): HELLO for hver offline char + DATA for den store.
    for c in relays:
        deliver = c.g.sim_deliver
        for part in chunks(helper.ser(bigoff.data("recipes", game))):
            deliver(PREFIX, part, "GUILD", bigoff.key)
        for u in offline + [bigoff]:
            deliver(PREFIX, helper.ser(u.hello()), "GUILD", u.key)
    world.push_roster()
    world.step(60)
    world.tap = tap
    new = sim.Client(world, "Newcomer", "PRIEST", 70)
    new.L.execute(f"math.randomseed({SEED + 99})")
    t0 = perf()
    new.login()
    seconds = 300
    world.step(seconds)
    wall = perf() - t0
    guild = new.db.guilds[f"{sim.REALM}/{sim.GUILD}"]
    have = sum(1 for _ in guild.chars.items())
    info_copies = [copies[(u.key, "info")] for u in offline]
    errs = [e for c in relays + [new] for e in errors_of(c)]
    row = {"profile": "-", "group": "8 Relay check (real clients)", "info": True,
           "label": f"{n_relays} real relays, newcomer logs in, {seconds} s",
           "note": (f"INVR sent x{sent.get('INVR', 0)} ({sent.get('INVR bytes', 0) / max(1, sent.get('INVR', 1)):.0f} B each); "
                    f"DATA recipes for the 300-recipe offline char: {copies[(bigoff.key, 'recipes')]} copies "
                    f"({sent.get('DATA recipes bytes', 0) / max(1, sent.get('DATA recipes', 1)):.0f} B each); "
                    f"DATA info per offline char: avg {statistics.mean(info_copies):.2f} copies, max {max(info_copies)}; "
                    f"total on the guild channel {sent['chunks']} chunks / {sent['bytes'] / 1024:.0f} KB; "
                    f"newcomer knows {have} chars; Lua errors {len(errs)}; sim wall {wall:.1f} s"),
           "sent": dict(sent), "errors": errs,
           "bigoff_copies": copies[(bigoff.key, "recipes")], "info_copies_avg": statistics.mean(info_copies)}
    rows.append(row)
    return row


# ----------------------------------------------------------------------
# Udskrift
# ----------------------------------------------------------------------

def fmt_calls(calls):
    parts = []
    for k, v in sorted(calls.items(), key=lambda kv: -kv[1]):
        if k in HIDE or k.startswith("Refresh:") and v == 0:
            continue
        parts.append(f"{SHORT.get(k, k)} {v}")
    return ", ".join(parts[:7])


def print_rows(rows, profile):
    group = None
    print(f"\n{'':2}{'operation':<74}{'wall ms':>9}{'min':>8}{'instr':>11}{'addon%':>7}{'alloc KB':>9}  calls")
    for r in rows:
        if r["profile"] != profile:
            continue
        if r["group"] != group:
            group = r["group"]
            print(f"\n[{group}]")
        if r.get("info"):
            head = f"  * {r['label']}"
            if "wall_ms" in r:
                head += f"  [{r['wall_ms']:.1f} ms" + (f", {r['instr']:,} instr" if r.get("instr") else "") + "]"
            print(head)
            print(f"      {r['note']}")
            continue
        addon = 100 * r["instr_addon"] / r["instr"] if r["instr"] else 0
        alloc = f"{r['alloc_kb']:.0f}" if r["alloc_kb"] is not None else "-"
        print(f"  {r['label'][:73]:<74}{r['wall_ms']:>9.3f}{r['wall_min_ms']:>8.3f}{r['instr']:>11,}{addon:>6.0f}%"
              f"{alloc:>9}  {fmt_calls(r['calls'])}")
        if r["note"]:
            print(f"      ({r['note']})")
        if r["instr"] >= 50000 and r["top"]:
            print("      top: " + "; ".join(f"{n} {i / 1000:.0f}k" for n, i in r["top"]))


def main():
    args = [a for a in sys.argv[1:] if a != "-v"]
    json_path = None
    if "--json" in args:
        i = args.index("--json")
        json_path = args[i + 1]
        del args[i:i + 2]
    do_relay = "--no-relay" not in args
    profiles = [a for a in args if a in PROFILES] or list(PROFILES)
    t_start = perf()
    game = Game()
    helper = Helper()
    ok, size, n = helper.check_chunker()
    print(f"chunks() matches the real AceComm for a {size}-byte message ({n} chunks): {ok}")
    assert ok, "chunks() afviger fra AceComm"
    rows = []
    all_errors = []
    for name in profiles:
        t0 = perf()
        guild, saved = run_profile(name, game, helper, rows)
        # 6: login. Kold = ny installation (tom cache). Varm = dagligt login (cachen fra hovedkørslen),
        # hvor et par brugere har fået nye data imens.
        errs, _ = run_login(name, game, helper, guild, rows, None, True,
                            "cold login, ideal protocol (1 INVR, 1 DATA per REQ)")
        all_errors += errs
        errs, req_log = run_login(name, game, helper, guild, rows, None, False,
                                  "cold login, Sync.lua timing rules (every relay answers)")
        all_errors += errs
        errs, _ = run_login(name, game, helper, guild, rows, saved, False,
                            "warm login (nothing changed), Sync.lua timing rules", bystander=True)
        all_errors += errs
        all_errors += run_relay_role(name, game, helper, guild, rows, saved, req_log)
        rng = random.Random(SEED + 5)
        for u in rng.sample(guild.users, max(1, len(guild.users) // 20)):
            u.v["recipes"] += 1
        errs, _ = run_login(name, game, helper, guild, rows, saved, False,
                            "warm login (5 % of users have new recipes), Sync.lua timing rules")
        all_errors += errs
        print_rows(rows, name)
        print(f"\n(profile {name}: {perf() - t0:.1f} s)", flush=True)
    if do_relay:
        row = relay_check(game, helper, rows)
        print(f"\n[{row['group']}]\n  * {row['label']}\n      {row['note']}")
        all_errors += row["errors"]
    for r in rows:
        all_errors += r.get("errors", []) if r.get("label", "").startswith("Lua errors (main") else []
    print(f"\nLua errors in total: {len(all_errors)}" + (f" (first: {all_errors[0][:300]})" if all_errors else ""))
    print(f"Total time: {perf() - t_start:.1f} s")
    if json_path:
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(rows, f, indent=1, default=str)
        print(f"Raw numbers saved to {json_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
