"""
Simulerer flere WoW-klienter med GuildCrafters i samme guild, uden spillet.

Kører den rigtige addon-kode (inkl. AceComm/ChatThrottleLib) i hver sin Lua 5.1-runtime
mod en falsk WoW-API (wowmock.lua) og et fælles falsk netværk med forsinkelse.

    pip install lupa
    python tools/sim/sim.py            # kør alle scenarier
    python tools/sim/sim.py -v         # vis også chat-output fra klienterne
"""
import os
import random
import re
import sys

from lupa import lua51

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ADDON = os.path.join(ROOT, "GuildCrafters")
MOCK = os.path.join(os.path.dirname(__file__), "wowmock.lua")
VERBOSE = "-v" in sys.argv

REALM = "Spineshatter"
GUILD = "Testguild"

# id: (navn, classID, subclassID, quality, required level, tooltip-tekst adskilt med ;)
ITEMS = {
    13510: ("Flask of the Titans", 0, 3, 1, 50, "Use: Increases the player's maximum health by 400"),
    13446: ("Major Healing Potion", 0, 1, 1, 45, "Use: Restores 1050 to 1750 health"),
    2996: ("Bolt of Linen Cloth", 7, 5, 1, 0, ""),
    2568: ("Brown Linen Vest", 4, 1, 1, 10, "Chest;Cloth;+1 Stamina"),
    10620: ("Thorium Ore", 7, 7, 1, 0, ""),
    13468: ("Black Lotus", 7, 9, 1, 0, ""),
    8925: ("Crystal Vial", 7, 11, 1, 0, ""),
    2589: ("Linen Cloth", 7, 5, 1, 0, ""),
    23445: ("Fel Iron Bar", 7, 7, 1, 0, ""),
    14047: ("Runecloth", 7, 5, 1, 0, ""),
    6948: ("Hearthstone", 15, 0, 1, 0, ""),
}
SPELLS = {7418: "Enchant Bracer - Minor Health", 13646: "Enchant Bracer - Lesser Deflection"}
SPELL_TEXT = {7418: "Permanently enchant bracers to increase health by 5.",
              13646: "Permanently enchant bracers to increase defense by 1."}


def toc_files(addon="GuildCrafters"):
    files = []
    for line in open(os.path.join(ADDON, addon + ".toc"), encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        path = line.replace("\\", "/")
        if path.endswith(".xml"):
            base = os.path.dirname(path)
            xml = open(os.path.join(ADDON, path), encoding="utf-8").read()
            for f in re.findall(r'<(?:Script|Include) file="([^"]+)"', xml):
                files.append(os.path.join(base, f.replace("\\", "/")))
        else:
            files.append(path)
    return files


def toc_version():
    for line in open(os.path.join(ADDON, "GuildCrafters.toc"), encoding="utf-8"):
        if line.startswith("## Version:"):
            return line.split(":", 1)[1].strip()


class World:
    def __init__(self):
        self.now = 0.0
        self.clients = []
        self.queue = []      # (deliver_at, client, prefix, text, channel, sender)
        self.sent = []       # log af alle beskeder: (tid, afsender, type-hint, bytes)
        self.ghosts = []     # guild-medlemmer uden addon: (navn, level, class, online)
        self.loss = 0.0      # andel af guild-beskeder, serveren taber for alle (tilfældigt)
        self.rng = random.Random(7)

    def roster(self):
        members = {}
        for c in self.clients:
            if c.guild:
                members[c.key] = c
        return members

    def send(self, sender, prefix, text, channel, target):
        self.sent.append((self.now, sender.name, channel, len(text)))
        if channel == "GUILD" and getattr(sender, "guild_muted", False):
            return      # serveren svarer "Success", men leverer ikke (set i spillet 2026-10-12)
        if channel == "GUILD" and getattr(sender, "drop_guild", 0) > 0:
            sender.drop_guild -= 1
            return      # enkelte tabte beskeder (serverens throttling)
        if channel == "GUILD" and self.loss and self.rng.random() < self.loss:
            return
        if channel == "GUILD":
            receivers = [c for c in self.clients if c.online and c.guild == sender.guild]
        elif channel == "WHISPER":
            short = target.split("-")[0]
            receivers = [c for c in self.clients if c.online and c.name == short]
        else:
            receivers = []
        for r in receivers:
            self.queue.append((self.now + 0.1, r, prefix, text, channel, sender.key))

    def step(self, seconds, dt=0.1):
        end = self.now + seconds
        while self.now < end:
            self.now = round(self.now + dt, 3)
            due = [m for m in self.queue if m[0] <= self.now]
            self.queue = [m for m in self.queue if m[0] > self.now]
            for _, client, prefix, text, channel, sender in due:
                if client.online:
                    client.L.globals().sim_deliver(prefix, text, channel, sender)
            for c in self.clients:
                if c.online:
                    c.L.globals().sim_tick()

    def push_roster(self):
        for c in self.clients:
            if c.online:
                c.set_roster()


class Client:
    def __init__(self, world, name, cls, level, guild=GUILD, profs=None, talents=(0, 0, 0),
                 bags=None, saved=None, flavor="classic", spec_role=None, addon="GuildCrafters",
                 also_loaded=()):
        self.world = world
        self.flavor = flavor            # "classic" (TBC Anniversary) eller "mainline" (retail / WoW Forever)
        self.addon = addon              # mappenavnet: "GuildCrafters" eller testudgaven "GuildCraftersTest"
        self.name = name
        self.key = f"{name}-{REALM}"
        self.guild = guild
        self.online = False
        self.prints = []
        L = lua51.LuaRuntime(unpack_returned_tuples=True)
        self.L = L
        g = L.globals()
        g.sim_py_now = lambda: world.now
        g.sim_py_send = lambda p, t, ch, tg: world.send(self, p, t, ch, tg)
        g.sim_py_print = self._print
        g.sim_version = toc_version()
        g.sim_flavor = flavor
        g.sim_addon = addon
        g.sim_loaded = L.table_from({name: True for name in also_loaded})
        L.execute(open(MOCK, encoding="utf-8").read())

        me = L.table_from({
            "name": name, "realm": REALM, "class": cls, "level": level,
            "talents": L.table_from(list(talents)),
        })
        if guild:
            me.guild = guild
        if spec_role:
            me.specRole = spec_role
        prof_list = []
        for p in profs or []:
            prof_list.append(L.table_from({
                "name": p["name"], "rank": p["rank"], "max": p["max"],
                "recipes": L.table_from(p["recipes"]),
                "reagents": L.table_from({k: L.table_from(v) for k, v in p.get("reagents", {}).items()}),
            }))
        me.profs = L.table_from(prof_list)
        bag_tbl = L.table()
        for bag, slots in (bags or {}).items():
            bag_tbl[bag] = L.table_from([L.table_from(list(s)) for s in slots])
        me.bags = bag_tbl
        g.sim_me = me

        for item_id, (iname, cls_id, sub, quality, req, text) in ITEMS.items():
            g.sim_items[item_id] = L.table_from({"name": iname, "class": cls_id, "sub": sub,
                                                 "quality": quality, "req": req, "text": text})
        for sid, stext in SPELL_TEXT.items():
            g.sim_spellText[sid] = stext
        for sid, sname in SPELLS.items():
            g.sim_spells[sid] = sname

        self.ns = L.table()
        for f in toc_files(addon):
            code = open(os.path.join(ADDON, f), encoding="utf-8").read()
            g.sim_load_file(f, code, self.ns)
        if saved:
            g.sim_load_sv(saved)

    def _print(self, text):
        self.prints.append(text)
        if VERBOSE:
            print(f"  [{self.world.now:6.1f}] {self.name}: {text}")

    @property
    def g(self):
        return self.L.globals()

    def set_roster(self):
        L = self.L
        rows = []
        for c in self.world.clients:
            if c.guild and c.guild == self.guild:
                rows.append(L.table_from({"name": c.key, "level": c.g.sim_me.level,
                                          "class": c.g.sim_me["class"], "online": c.online}))
        if self.guild == GUILD:
            for name, level, cls, online in self.world.ghosts:
                rows.append(L.table_from({"name": f"{name}-{REALM}", "level": level, "class": cls,
                                          "online": online}))
        self.g.sim_roster = L.table_from(rows)
        self.g.sim_fire("GUILD_ROSTER_UPDATE")

    def login(self):
        self.online = True
        self.world.clients.append(self) if self not in self.world.clients else None
        self.g.sim_fire("ADDON_LOADED", self.addon)
        self.g.sim_fire("PLAYER_LOGIN")
        self.world.push_roster()

    @property
    def db(self):
        """Addonens gemte data: GuildCraftersDB, eller GuildCraftersTestDB for testudgaven."""
        return self.g[self.addon + "DB"]

    def logout(self):
        """Gem SavedVariables som tekst og gå offline."""
        saved = self.g.sim_dump(self.db)
        self.online = False
        self.world.push_roster()
        return saved

    def open_trade(self, prof):
        self.g.sim_openTrade = prof
        self.g.sim_fire("TRADE_SKILL_SHOW")
        self.g.sim_fire("TRADE_SKILL_LIST_UPDATE" if self.flavor == "mainline" else "TRADE_SKILL_UPDATE")

    def open_craft(self, prof):
        if self.flavor == "mainline":   # intet Craft-vindue: Enchanting åbnes som alle andre professions
            return self.open_trade(prof)
        self.g.sim_openCraft = prof
        self.g.sim_fire("CRAFT_SHOW")
        self.g.sim_fire("CRAFT_UPDATE")

    def slash(self, text):
        self.g.SlashCmdList.GUILDCRAFTERS(text)

    def cache(self, key):
        guild = self.db.guilds[f"{REALM}/{self.guild}"]
        return guild and guild.chars[key]

    def recipe_ids(self, key):
        c = self.cache(key)
        ids = set()
        if not c:
            return ids
        for _, prof in c.profs.items():
            for i in (prof["items"] or {}).keys():
                ids.add(("i", i))
            for i in (prof.enchants or {}).keys():
                ids.add(("e", i))
        return ids

    def tooltip(self, item_id):
        tt = self.g.GameTooltip
        tt.SetHyperlink(tt, f"item:{item_id}")
        return [l for _, l in tt.sim_lines.items()]


# ----------------------------------------------------------------------
# Scenarier
# ----------------------------------------------------------------------

failures = []


def check(cond, text):
    print(("  OK   " if cond else "  FEJL ") + text)
    if not cond:
        failures.append(text)


def lua_errors(*clients):
    for c in clients:
        errs = [e for _, e in c.g.sim_errors.items()]
        check(not errs, f"{c.name}: ingen Lua-fejl" + (f" ({errs[0]})" if errs else ""))


ALCH = {"name": "Alchemy", "rank": 300, "max": 300, "recipes": [13510, 13446],
        "reagents": {13510: [13468, 1, 8925, 1]}}
TAIL = {"name": "Tailoring", "rank": 75, "max": 75, "recipes": [2996, 2568],
        "reagents": {2996: [2589, 2], 2568: [2996, 2]}}
ENCH = {"name": "Enchanting", "rank": 100, "max": 150, "recipes": [7418, 13646]}


def scenario_sync():
    print("\nScenarie 1: to online klienter synkroniserer recipes, roller og guild bank")
    w = World()
    anna = Client(w, "Anna", "PRIEST", 60, profs=[ALCH], talents=(5, 31, 15),
                  bags={0: [(10620, 20), (6948, 1)]})
    bob = Client(w, "Bob", "WARRIOR", 60, profs=[TAIL, ENCH], talents=(5, 5, 41))
    w.clients = [anna, bob]
    anna.login()
    bob.login()
    anna.open_trade("Alchemy")
    bob.open_trade("Tailoring")
    bob.open_craft("Enchanting")
    w.step(60)

    check(anna.recipe_ids(bob.key) == {("i", 2996), ("i", 2568), ("e", 7418), ("e", 13646)},
          "Anna kender Bobs tailoring- og enchanting-recipes")
    check(bob.recipe_ids(anna.key) == {("i", 13510), ("i", 13446)}, "Bob kender Annas alchemy-recipes")
    check(bob.cache(anna.key).role == "HEALER", "Annas rolle gættes som HEALER (Holy)")
    check(anna.cache(bob.key).role == "TANK", "Bobs rolle gættes som TANK (Protection)")

    # Nyt recipe efter login -> versionsbump -> HELLO -> REQ/DATA
    anna.g.sim_me.profs[1].recipes[3] = 2996
    anna.open_trade("Alchemy")
    w.step(30)
    check(("i", 2996) in bob.recipe_ids(anna.key), "Nyt recipe hos Anna når frem til Bob")

    # Guild bank
    anna.g.sim_fire("GUILDBANKFRAME_OPENED")
    w.step(15)
    gb = bob.g.GuildCraftersDB.guilds[f"{REALM}/{GUILD}"].guildBank
    check(gb is not None and gb.tabs[1][10620] == 40, "Guild bank-scan fra Anna når frem til Bob")

    # Mats: ikke delt som standard, derefter delt
    w.step(100)
    check(bob.cache(anna.key).mats is None, "Annas mats deles ikke, før hun slår det til")
    anna.slash("mats on")
    w.step(30)
    mats = bob.cache(anna.key).mats
    check(mats is not None and mats.bags[10620] == 20, "Annas mats (Thorium Ore 20) når frem efter /gc mats on")
    check(mats is not None and mats.bags[6948] is None, "Hearthstone tælles ikke som mat")
    # Ny mat i tasken (fx lige købt): annonceres samlet efter 90 s, ikke med det samme.
    anna.L.execute("table.insert(sim_me.bags[0], { 2996, 1 })")
    anna.g.sim_fire("BAG_UPDATE_DELAYED")
    w.step(30)
    check(bob.cache(anna.key).mats.bags[2996] is None, "Ny Bolt of Linen Cloth hos Anna sendes ikke med det samme")
    w.step(90)
    check(bob.cache(anna.key).mats.bags[2996] == 1, "Den når frem til Bob efter ventetiden (ca. 90 s)")
    anna.slash("mats off")
    w.step(30)
    check(bob.cache(anna.key).mats is None, "Annas mats fjernes hos Bob efter /gc mats off")

    # Tooltip og søgning hos Bob
    lines = bob.tooltip(13510)
    check(any("Crafted by" in l and "Anna" in l for l in lines), "Tooltip på Flask of the Titans viser Anna")
    lines = bob.tooltip(10620)
    check(any("Guild bank 40" in l for l in lines), "Tooltip på Thorium Ore viser guild bank")
    lua_errors(anna, bob)
    total = sum(s[3] for s in w.sent)
    print(f"  (info: {len(w.sent)} addon-beskeder, {total} bytes i alt)")
    return w, anna, bob


def scenario_relay():
    print("\nScenarie 2: relay - Cara logger ind for første gang, mens Anna er offline")
    w = World()
    anna = Client(w, "Anna", "PRIEST", 60, profs=[ALCH], talents=(5, 31, 15))
    bob = Client(w, "Bob", "WARRIOR", 60, profs=[TAIL], talents=(5, 5, 41))
    w.clients = [anna, bob]
    anna.login()
    bob.login()
    anna.open_trade("Alchemy")
    bob.open_trade("Tailoring")
    w.step(60)
    anna.logout()
    w.step(5)

    cara = Client(w, "Cara", "MAGE", 60, talents=(0, 0, 31))
    w.clients.append(cara)
    cara.login()
    w.step(60)
    check(cara.recipe_ids(bob.key) == {("i", 2996), ("i", 2568)}, "Cara får Bobs recipes direkte fra Bob")
    check(cara.recipe_ids(anna.key) == {("i", 13510), ("i", 13446)},
          "Cara får Annas recipes via relay fra Bob, selvom Anna er offline")
    c = cara.cache(anna.key)
    check(c is not None and c["class"] == "PRIEST" and c.role == "HEALER", "Cara får også Annas info via relay")
    lua_errors(bob, cara)


def scenario_alts():
    print("\nScenarie 3: alts - Annas alt logger ind med samme SavedVariables")
    w = World()
    anna = Client(w, "Anna", "PRIEST", 60, profs=[ALCH], talents=(5, 31, 15))
    bob = Client(w, "Bob", "WARRIOR", 60, profs=[TAIL], talents=(5, 5, 41))
    w.clients = [anna, bob]
    anna.login()
    bob.login()
    anna.open_trade("Alchemy")
    w.step(30)
    saved = anna.logout()
    w.clients.remove(anna)

    annalt = Client(w, "Annalt", "MAGE", 25, profs=[TAIL], saved=saved)
    w.clients.append(annalt)
    annalt.login()
    annalt.open_trade("Tailoring")
    w.step(60)
    c = bob.cache(annalt.key)
    check(c is not None and c.main == anna.key, "Bob ser Annalt som alt af Anna")
    check(("i", 2996) in bob.recipe_ids(annalt.key), "Bob kender Annalts tailoring-recipes")
    check(bob.recipe_ids(anna.key) == {("i", 13510), ("i", 13446)}, "Bob har stadig Annas recipes i cache")
    lua_errors(annalt, bob)


def scenario_ui():
    print("\nScenarie 4: UI, søgning og kommandoer (røgtest)")
    w, anna, bob = scenario_sync_quiet()
    bob.slash("")                 # åbner vinduet
    ns = bob.ns
    for i in (1, 2, 3, 4):
        ns.UI.SelectTab(ns.UI, i)
    ns.UI.Toggle(ns.UI)
    bob.slash("")
    w.step(2)
    box = bob.g.GuildCraftersCraftingSearch
    box.SetText(box, "flask")
    box.sim_scripts.OnTextChanged(box)
    w.step(2)
    names = [ns.Index.Name("i", r.id) for _, r in ns.Index.Recipes(ns.Index).items() if r.kind == "i"]
    check("Flask of the Titans" in names, "Søgeindekset indeholder Flask of the Titans (efter async navneopslag)")
    for cmd in ("help", "debug dump", "debug dump alch", "debug fake 12", "role tank", "role auto",
                "main", "main auto", "forget nothing", "minimap", "minimap", "debug clear", "debug comm"):
        bob.slash(cmd)
    w.step(20)
    lua_errors(anna, bob)

    print("\nScenarie 5: klient uden guild")
    w2 = World()
    solo = Client(w2, "Solo", "ROGUE", 12, guild=None, profs=[TAIL])
    w2.clients = [solo]
    solo.login()
    solo.open_trade("Tailoring")
    solo.slash("")
    solo.slash("debug hello")
    solo.slash("debug ping")
    w2.step(20)
    check(any("<- HELLO" in p for p in solo.prints), "HELLO som whisper til sig selv kommer retur")
    lua_errors(solo)


def scenario_sync_quiet():
    w = World()
    anna = Client(w, "Anna", "PRIEST", 60, profs=[ALCH], talents=(5, 31, 15))
    bob = Client(w, "Bob", "WARRIOR", 60, profs=[TAIL, ENCH], talents=(5, 5, 41))
    w.clients = [anna, bob]
    anna.login()
    bob.login()
    anna.open_trade("Alchemy")
    w.step(60)
    return w, anna, bob


def scenario_protocol():
    print("\nScenarie 6: fremmed protokolversion og ødelagte beskeder")
    w, anna, bob = scenario_sync_quiet()
    ser = bob.L.eval('(LibStub("AceSerializer-3.0"))')
    future = ser.Serialize(ser, bob.L.table_from({"t": "HELLO", "p": 99}))
    bob.g.sim_deliver("GCRAFT", future, "GUILD", "Zed-" + REALM)
    bob.g.sim_deliver("GCRAFT", "noget vrøvl", "GUILD", "Zed-" + REALM)
    bad = ser.Serialize(ser, bob.L.table_from({"t": "DATA", "p": 2, "c": "Zed-" + REALM, "k": "recipes",
                                               "v": 5, "d": "ikke en tabel"}))
    bob.g.sim_deliver("GCRAFT", bad, "GUILD", "Zed-" + REALM)
    w.step(5)
    check(any("newer version" in p for p in bob.prints), "Advarsel om nyere protokolversion vises")
    check(bob.cache("Zed-" + REALM) is None, "Ugyldige data gemmes ikke")
    lua_errors(bob)


def scenario_storm():
    print("\nScenarie 7: 10 spillere logger ind inden for 30 sekunder (login-storm)")
    import random
    random.seed(1)
    w = World()
    pool = [ALCH, TAIL, ENCH]
    clients = []
    for i in range(10):
        c = Client(w, f"Spiller{i}", "MAGE", 60, profs=[pool[i % 3]], talents=(0, 0, 31))
        clients.append(c)
    w.clients = list(clients)
    for c in clients:
        c.login()
        prof = c.g.sim_me.profs[1].name
        if prof == "Enchanting":
            c.open_craft(prof)
        else:
            c.open_trade(prof)
        w.step(random.uniform(0, 3))
    w.step(120)
    complete = 0
    for c in clients:
        others = [o for o in clients if o is not c]
        if all(c.recipe_ids(o.key) for o in others):
            complete += 1
    check(complete == 10, f"Alle 10 kender alle andres recipes ({complete}/10)")
    total = sum(s[3] for s in w.sent)
    peak = max(sum(1 for s in w.sent if s[1] == c.name) for c in clients)
    print(f"  (info: {len(w.sent)} beskeder / {total} bytes i alt; travleste klient sendte {peak})")
    check(peak < 40, "Ingen klient sender over 40 beskeder under login-stormen")
    lua_errors(*clients)


def scenario_crafting():
    print("\nScenarie 8: reagents-sync, kategorier, stats-søgning og craft-liste")
    w = World()
    anna = Client(w, "Anna", "PRIEST", 60, profs=[ALCH], talents=(5, 31, 15),
                  bags={0: [(13468, 3)]})
    bob = Client(w, "Bob", "WARRIOR", 60, profs=[TAIL], talents=(5, 5, 41),
                  bags={0: [(8925, 1), (2589, 10), (10620, 5)]})   # Thorium Ore bruges ikke af craft-listen
    w.clients = [anna, bob]
    anna.login()
    bob.login()
    anna.open_trade("Alchemy")
    bob.open_trade("Tailoring")
    anna.slash("mats on")
    w.step(150)
    ns = bob.ns
    rg = bob.g.GuildCraftersDB.reagents
    check(rg["i13510"] is not None and rg["i13510"].r[1] == 13468,
          "Bob kender reagents til Annas Flask of the Titans (via sync)")
    check(rg["i2568"] is not None, "Bob kender sine egne reagents (Brown Linen Vest)")

    # Kategorier (items skal først indlæses asynkront)
    ns.Index.CategoryTree(ns.Index)
    w.step(2)
    tree, _ = ns.Index.CategoryTree(ns.Index)
    tops = {t.name: {sb.name for _, sb in t.subs.items()} for _, t in tree.items()}
    check("Flasks" in tops.get("Consumables", set()) and "Potions" in tops.get("Consumables", set()),
          "Kategori Consumables > Flasks og Potions")
    check("Cloth" in tops.get("Armor", set()), "Kategori Armor > Cloth (Brown Linen Vest)")
    check("Trade Goods" in tops, "Kategori Trade Goods (Bolt of Linen Cloth)")

    def find(**f):
        found, _ = ns.Index.Find(ns.Index, bob.L.table_from(f))
        return {r.name for _, r in found.items()}
    check(find(query="maximum health") == {"Flask of the Titans"}, "Søgning i stats: \"maximum health\"")
    check(find(query="flask tit") == {"Flask of the Titans"}, "Flere ord: \"flask tit\"")
    check(find(query="stamina") == {"Brown Linen Vest"}, "Søgning i stats: \"stamina\"")
    check(find(top="Consumables", sub="Flasks") == {"Flask of the Titans"}, "Filter på Consumables > Flasks")
    check(find(crafter=anna.key) == {"Flask of the Titans", "Major Healing Potion"}, "Filter på crafter Anna")

    # Craft-liste: 2x Flask -> 2 Black Lotus + 2 Crystal Vial. Bob har 1 vial; Anna har 3 lotus (delt).
    ns.Data.CraftListAdd(ns.Data, "i", 13510, 2)
    made, reagents = ns.Index.Reagents(ns.Index, "i", 13510)
    need = {r.id: r.count * 2 for _, r in reagents.items()}
    check(need == {13468: 2, 8925: 2}, "Craft-liste: 2x Flask kræver 2 Black Lotus og 2 Crystal Vial")
    check(ns.Index.OwnCount(ns.Index, 8925) == 1, "Bob har selv 1 Crystal Vial")
    holders = [h.key for _, h in ns.Index.Holders(ns.Index, 13468).items()]
    check(anna.key in holders, "Anna står som en, der har Black Lotus")

    # UI-røgtest af de nye faner
    bob.slash("")
    for i in (1, 2, 3, 4):
        ns.UI.SelectTab(ns.UI, i)
    ns.UI.SelectTab(ns.UI, 2)
    # Klik på alle kategorier (folder ud), derefter alle underkategorier og crafters.
    lua_click_rows = bob.L.eval("""function()
        local n = 0
        for _, f in ipairs(sim_allFrames) do
            local e = rawget(f, "entry")
            if e and f.sim_scripts.OnClick and (e.type == "top" or e.type == "crafters") then
                f.sim_scripts.OnClick(f); n = n + 1
            end
        end
        for _, f in ipairs(sim_allFrames) do
            local e = rawget(f, "entry")
            if e and f.sim_scripts.OnClick and (e.type == "sub" or e.type == "crafter") then
                f.sim_scripts.OnClick(f); n = n + 1
            end
        end
        return n
    end""")
    clicked = lua_click_rows()
    check(clicked > 0, f"Klik på kategorier og underkategorier ({clicked} klik)")
    box = bob.g.GuildCraftersCraftingSearch
    box.SetText(box, "stamina")
    box.sim_scripts.OnTextChanged(box)
    w.step(1)

    # Klik på et søgeresultat: venstreklik gør ingenting, højreklik = menu, ctrl = dressing room.
    click = bob.L.eval("""function(button, ctrl)
        sim_ctrl = ctrl
        sim_menu = nil
        local before = #sim_dressUp
        for _, f in ipairs(sim_allFrames) do
            local item = rawget(f, "item")
            if item and item.keys and f.sim_shown and f.sim_scripts.OnClick then
                f.sim_scripts.OnClick(f, button)
                break
            end
        end
        sim_ctrl = false
        return sim_menu ~= nil, #sim_dressUp > before
    end""")
    box.SetText(box, "flask")                          # Annas recipe, så der er en anden at whispe
    w.step(1)
    menu, dressed = click("LeftButton", False)
    check(not menu and not dressed, "Venstreklik på et søgeresultat åbner ikke menuen")
    menu, dressed = click("RightButton", False)
    check(menu, "Højreklik på et søgeresultat åbner menuen")
    whisper = bob.L.eval("""function()
        for _, info in ipairs(sim_menu or {}) do
            if info.text and info.text:find("^Whisper") and info.func then
                info.func()
                return sim_whispers[#sim_whispers], sim_chatText[#sim_chatText]
            end
        end
    end""")
    target, text = whisper()
    check(target is not None and text is not None and text.startswith("Hi! Could you craft ")
          and text.endswith(" for me?"), f"\"Whisper X\" åbner en whisper med færdig tekst ({target}: {text})")
    menu, dressed = click("LeftButton", True)
    check(dressed and not menu, "Ctrl-klik viser itemet i dressing room")

    # Craft List grupperet pr. item: status ud fra egne mats (Bob har 10 Linen Cloth og 1 Crystal Vial).
    statuses = bob.L.eval("""function()
        local out = {}
        for _, f in ipairs(sim_allFrames) do
            local item = rawget(f, "item")
            if item and item.entry and f.sim_shown and rawget(f, "status") then
                out[item.name] = f.status.sim_text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            end
        end
        return out
    end""")
    ns.Data.CraftListAdd(ns.Data, "i", 2996, 3)        # 3 Bolt of Linen Cloth = 6 Linen Cloth
    ns.UI.ShowTab(ns.UI, "Craft List")
    st = dict(statuses().items())
    check(st.get("Flask of the Titans") == "Missing 2 mats", f"2x Flask: \"Missing 2 mats\" ({st.get('Flask of the Titans')})")
    check(st.get("Bolt of Linen Cloth") == "Ready", f"3x Bolt of Linen Cloth: \"Ready\" ({st.get('Bolt of Linen Cloth')})")
    ns.Data.CraftListSetQty(ns.Data, "i", 2996, 6)      # 12 Linen Cloth, Bob har 10
    ns.UI.ShowTab(ns.UI, "Craft List")
    st = dict(statuses().items())
    check(st.get("Bolt of Linen Cloth") == "Missing 1 mat", f"6x Bolt of Linen Cloth: \"Missing 1 mat\" ({st.get('Bolt of Linen Cloth')})")

    # Ready-items foldes sammen; fold-knappen folder ud igen.
    shown_mats = bob.L.eval("""function(forName)
        local n = 0
        for _, f in ipairs(sim_allFrames) do
            local item = rawget(f, "item")
            if item and item.need and item.forName == forName and f.sim_shown then n = n + 1 end
        end
        return n
    end""")
    ns.Data.CraftListSetQty(ns.Data, "i", 2996, 3)      # Ready igen
    ns.UI.ShowTab(ns.UI, "Craft List")
    check(shown_mats("Bolt of Linen Cloth") == 0, "Ready-item (Bolt of Linen Cloth) er foldet sammen")
    check(shown_mats("Flask of the Titans") == 2, "Item med manglende mats viser sine 2 mats")
    bob.L.execute("""for _, f in ipairs(sim_allFrames) do
        local item = rawget(f, "item")
        if item and item.entry and item.name == "Bolt of Linen Cloth" and f.sim_shown then
            f.toggle.sim_scripts.OnClick(f.toggle) break
        end
    end""")
    check(shown_mats("Bolt of Linen Cloth") == 1, "Fold-knappen folder Bolt of Linen Cloth ud (Linen Cloth vises)")

    # Shift-klik på + i Crafting lægger 5 på; resultatet viser "On list".
    ns.UI.ShowTab(ns.UI, "Crafting")
    bob.L.execute("""for _, f in ipairs(sim_allFrames) do
        local e = rawget(f, "entry")
        if e and e.type == "all" then f.sim_scripts.OnClick(f) break end
    end""")                                            # "All recipes" (kategori-klikkene valgte en crafter)
    box.SetText(box, "flask")
    added = bob.L.eval("""function()
        sim_shift = true
        for _, f in ipairs(sim_allFrames) do
            local item = rawget(f, "item")
            if item and item.name == "Flask of the Titans" and item.keys and f:IsVisible() then
                for _, c in ipairs({ f:GetChildren() }) do
                    if c:GetText() == "+" then c.sim_scripts.OnClick(c) end
                end
                break
            end
        end
        sim_shift = false
    end""")
    added()
    w.step(1)
    entry, _ = ns.Data.CraftListFind(ns.Data, "i", 13510)
    check(entry is not None and entry.qty == 7, "Shift-klik på + lægger 5 Flasks på (2 -> 7)")
    right = bob.L.eval("""function()
        for _, f in ipairs(sim_allFrames) do
            local item = rawget(f, "item")
            if item and item.name == "Flask of the Titans" and item.keys and f:IsVisible() then return f.onList.sim_text end
        end
    end""")()
    check(right is not None and "x7" in right, f"Søgeresultatet viser \"x7\" (står på craft-listen) ({right})")

    # "Show recipes" fra rosteren åbner Crafting med Annas recipes.
    ns.UI.ShowCrafter(anna.key)
    prof_rows = bob.L.eval("""function()
        local out = {}
        for _, f in ipairs(sim_allFrames) do
            if rawget(f, "label") and rawget(f, "add") and f:IsVisible() and (rawget(f, "header") or rawget(f, "item")) then
                local t = f.label.sim_text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                table.insert(out, t)
            end
        end
        return out
    end""")
    rows = [r for _, r in prof_rows().items()]
    expected = ["- ALCHEMY", "- Flasks", "Flask of the Titans", "- Potions", "Major Healing Potion"]
    check(rows == expected, f"\"Show recipes\" grupperer Annas recipes pr. profession og kategori ({rows})")
    bob.L.execute("""for _, f in ipairs(sim_allFrames) do
        local h = rawget(f, "header")
        if h and h.name == "Flasks" and f:IsVisible() then f.sim_scripts.OnClick(f, "LeftButton") break end
    end""")
    rows = [r for _, r in prof_rows().items()]
    check(rows == ["- ALCHEMY", "+ Flasks", "- Potions", "Major Healing Potion"],
          f"Klik på en kategori-overskrift folder den sammen ({rows})")

    # Mats: "Only my craft list" viser kun de mats, listen skal bruge.
    ns.UI.ShowTab(ns.UI, "Mats")
    mats_count = bob.L.eval("""function()
        for _, f in ipairs(sim_allFrames) do
            local t = rawget(f, "sim_text")
            if type(t) == "string" and t:find("^%d+ mats") then return tonumber(t:match("^(%d+)")) end
        end
    end""")
    total = mats_count()
    bob.L.execute("""for _, f in ipairs(sim_allFrames) do
        if f.label and f.label.sim_text == "Only my craft list" then
            f:SetChecked(true) f.sim_scripts.OnClick(f) break
        end
    end""")
    only = mats_count()
    check(total is not None and only is not None and 0 < only < total,
          f"\"Only my craft list\" viser færre mats ({only} af {total})")

    # "Clear list" spørger først.
    ns.UI.ShowTab(ns.UI, "Craft List")
    bob.L.execute("""for _, f in ipairs(sim_allFrames) do
        if f.sim_text == "Clear list" and f.sim_scripts.OnClick then f.sim_scripts.OnClick(f) break end
    end""")
    popups = [p for _, p in bob.g.sim_popups.items()]
    check(len(ns.db.craftList) > 0 and "GUILDCRAFTERS_CLEAR_LIST" in popups,
          "\"Clear list\" spørger først og rydder ikke listen med det samme")
    bob.g.StaticPopupDialogs.GUILDCRAFTERS_CLEAR_LIST.OnAccept()
    check(len(ns.db.craftList) == 0, "Listen ryddes, når man svarer Yes")
    lua_errors(anna, bob)


def scenario_tour():
    print("\nScenarie 9: /gc debug tour klikker gennem alle faner og tager screenshots")
    w, anna, bob = scenario_sync_quiet()
    ns = bob.ns
    ns.Data.CraftListAdd(ns.Data, "i", 2996, 4)       # brugerens egen liste skal overleve rundturen
    bob.L.execute("sim_handlerBefore = geterrorhandler()")
    bob.slash("debug tour")
    bob.slash("debug tour")                           # dobbeltstart afvises
    w.step(60)
    report = bob.g.GuildCraftersDB.debugTour
    check(report is not None and report.finished is not None, "Rundturen bliver færdig og gemmer en rapport")
    if report is None:
        return
    steps = [s.name for _, s in report.steps.items()]
    errors = [f"{e.step}: {e.msg}" for _, e in report.errors.items()]
    check(len(steps) == 16 and report.shotsOk == 16, f"16 trin med screenshot ({len(steps)} trin, {report.shotsOk} screenshots)")
    check(not errors, "Ingen fejl under rundturen" + (f" ({errors[0]})" if errors else ""))
    check(sum("added to your craft list" in p for p in bob.prints) == 3, "Tre recipes lagt i craft-listen undervejs")
    cl = [(e.kind, e.id, e.qty) for _, e in bob.g.GuildCraftersDB.craftList.items()]
    check(cl == [("i", 2996, 4)], f"Craft-listen er genskabt bagefter ({cl})")
    check(len(report.tabs) == 4, "Fanernes placering er med i rapporten")
    tips = {s.name: [l for _, l in (s.tooltip or {}).items()] for _, s in report.steps.items()}
    tip = tips.get("result-tooltip", [])
    check(tip and "Flask" in tip[0], f"Tooltip-trinnet viser en flask efter søgning på \"flask\" ({tip[:1]})")
    check(any("Crafted by" in l for l in tip), "Tooltippen på et søgeresultat har \"Crafted by\"")
    dupes = []
    for _, r in ns.Index.Recipes(ns.Index).items():
        keys = [k for _, k in ns.Index.Crafters(ns.Index, r.kind, r.id).items()]
        if len(keys) != len(set(keys)):
            dupes.append(r.id)
    check(not dupes, f"Ingen crafter står to gange på samme recipe ({dupes[:3]})")
    check(bob.L.eval("geterrorhandler() == sim_handlerBefore"), "Fejlhandleren er sat tilbage")
    check(any("already running" in p for p in bob.prints), "Anden /gc debug tour afvises, mens den første kører")
    lua_errors(anna, bob)


def scenario_blocked():
    print("\nScenarie 10: en spillers guild-beskeder forsvinder på serveren -> whisper som reserve")
    w = World()
    anna = Client(w, "Anna", "PRIEST", 60, profs=[ALCH], talents=(5, 31, 15))
    bob = Client(w, "Bob", "WARRIOR", 60, profs=[TAIL], talents=(5, 5, 41))
    w.clients = [anna, bob]
    anna.login()
    bob.login()
    anna.open_trade("Alchemy")
    bob.open_trade("Tailoring")
    w.step(60)

    # Kebab er ny (ingen cache, ingen talents), og hans guild-beskeder bliver ikke leveret.
    kebab = Client(w, "Kebab", "WARLOCK", 12, profs=[dict(ENCH)])
    kebab.guild_muted = True
    w.clients.append(kebab)
    kebab.login()
    kebab.open_craft("Enchanting")
    w.step(20)      # reserven kan tidligst slå til efter ca. 23 s (to HELLO + to gange ventetid)
    check(anna.cache(kebab.key) is None, "Før reserven slår til, har Anna intet hørt fra Kebab")
    w.step(130)
    check(any("not getting through" in p for p in kebab.prints), "Kebab får besked om, at guild-kanalen ikke virker")
    c = anna.cache(kebab.key)
    check(c is not None and c["class"] == "WARLOCK", "Anna ser nu Kebab (info kom som whisper)")
    check(anna.recipe_ids(kebab.key) == {("e", 7418), ("e", 13646)}, "Anna får Kebabs enchanting-recipes")
    check(bob.recipe_ids(kebab.key) == {("e", 7418), ("e", 13646)}, "Bob får også Kebabs recipes")
    check(kebab.recipe_ids(anna.key) == {("i", 13510), ("i", 13446)}, "Kebab ser stadig Annas recipes")

    # Ændringer hos Kebab bagefter når også frem.
    kebab.g.sim_me.profs[1].recipes[3] = 13890
    kebab.open_craft("Enchanting")
    w.step(60)
    check(("e", 13890) in anna.recipe_ids(kebab.key), "Nyt recipe hos Kebab når frem til Anna")

    # Whisper fra en, der ikke er i guilden, ignoreres.
    ser = anna.L.eval('(LibStub("AceSerializer-3.0"))')
    fake = ser.Serialize(ser, anna.L.table_from({"t": "HELLO", "p": 2, "class": "MAGE", "level": 60,
                                                  "profs": anna.L.table(), "v": anna.L.table_from({"info": 1})}))
    anna.g.sim_deliver("GCRAFT", fake, "WHISPER", "Stranger-" + REALM)
    w.step(5)
    check(anna.cache("Stranger-" + REALM) is None, "Whisper fra en uden for guilden gemmes ikke")

    # Virker guild-kanalen igen, skifter Kebab tilbage.
    kebab.guild_muted = False
    kebab.slash("role tank")
    w.step(40)
    check(any("getting through again" in p for p in kebab.prints), "Kebab skifter tilbage, når guild-kanalen virker igen")
    peak = sum(1 for s_ in w.sent if s_[1] == "Kebab")
    print(f"  (info: Kebab sendte {peak} beskeder i alt)")
    lua_errors(anna, bob, kebab)


# ----------------------------------------------------------------------
# Robusthed i synkroniseringen (tilføjet efter første test med en ven, 2026-10-12)
# ----------------------------------------------------------------------

def _recipes_of(prof):
    kind = "e" if prof["name"] == "Enchanting" else "i"
    return {(kind, i) for i in prof["recipes"]}


def _player(w, name, profs=(), muted=False, cls="MAGE", level=60, talents=(0, 0, 31), **kw):
    """Klient, der husker sine professions (spec), så _knows kan sammenligne."""
    c = Client(w, name, cls, level, profs=[dict(p) for p in profs], talents=talents, **kw)
    c.spec = [dict(p) for p in profs]
    c.guild_muted = muted
    return c


def _join(w, c, wait=0):
    if c not in w.clients:
        w.clients.append(c)
    c.login()
    for prof in c.spec:
        (c.open_craft if prof["name"] == "Enchanting" else c.open_trade)(prof["name"])
        w.step(1)
    w.step(wait)


def _knows(a, b):
    """Har a alle b's recipes?"""
    want = set()
    for prof in b.spec:
        want |= _recipes_of(prof)
    return a.cache(b.key) is not None and a.recipe_ids(b.key) == want


def _missing(clients):
    return [f"{a.name}->{b.name}" for a in clients for b in clients if a is not b and not _knows(a, b)]


def scenario_blocked_more():
    print("\nScenarie 11: blokeret guild-kanal i flere situationer")
    # Blokeret ven er online først; jeg logger ind senere.
    w = World()
    ven = _player(w, "Ven", [ENCH], muted=True)
    _join(w, ven, 120)
    jeg = _player(w, "Jeg", [TAIL])
    _join(w, jeg, 120)
    check(not _missing([jeg, ven]), f"Ven online først, jeg logger ind senere ({_missing([jeg, ven])})")

    # To blokerede og en normal finder alle hinanden.
    w = World()
    jeg = _player(w, "Jeg", [TAIL])
    _join(w, jeg, 30)
    a = _player(w, "Vena", [ENCH], muted=True)
    _join(w, a, 5)
    b = _player(w, "Venb", [ALCH], muted=True)
    _join(w, b, 240)
    check(not _missing([jeg, a, b]), f"To blokerede + en normal ({_missing([jeg, a, b])})")
    lua_errors(jeg, a, b)

    # Stor guild (45 online uden addon): ingen rundspørge, men vennen når frem, når han hører fra mig.
    w = World()
    w.ghosts = [(f"Ghost{i}", 20, "MAGE", True) for i in range(45)]
    jeg = _player(w, "Jeg", [TAIL])
    _join(w, jeg, 60)
    ven = _player(w, "Ven", [ENCH], muted=True)
    _join(w, ven, 180)
    whispers = sum(1 for m in w.sent if m[1] == "Ven" and m[2] == "WHISPER")
    check(whispers == 0, f"Stor guild: vennen whisper ikke 45 fremmede ({whispers} whispers)")
    jeg.slash("role tank")                      # en almindelig opdatering fra mig
    w.step(120)
    check(not _missing([jeg, ven]), f"Stor guild: vennen når frem efter min næste opdatering ({_missing([jeg, ven])})")

    # Relay: en tredje får den blokeredes data fra mig, mens han er offline.
    ven.logout()
    w.step(10)
    cara = _player(w, "Cara", [ALCH])
    _join(w, cara, 120)
    check(_knows(cara, ven), "Relay: Cara får den blokeredes recipes via mig, mens han er offline")

    # Navn med specialtegn + mange recipes (store beskeder) over whisper.
    big = {"name": "Alchemy", "rank": 375, "max": 375, "recipes": list(range(20000, 20300)),
           "reagents": {i: [2589, 2, 8925, 1] for i in range(20000, 20300)}}
    w = World()
    jeg = _player(w, "Jeg", [TAIL])
    _join(w, jeg, 30)
    ven = _player(w, "Købtkebab", [big], muted=True)
    _join(w, ven, 0)
    t = 0
    while t < 600 and not _knows(jeg, ven):
        w.step(10)
        t += 10
    check(_knows(jeg, ven), f"Blokeret \"Købtkebab\" med 300 recipes når frem (efter {t} s)")
    lua_errors(jeg, ven)


def scenario_loss():
    print("\nScenarie 12: serveren taber beskeder tilfældigt (genforsøg + hjerteslag)")
    # Én tabt besked: genforsøg, uden at skifte til whisper.
    w = World()
    jeg = _player(w, "Jeg", [TAIL])
    _join(w, jeg, 60)
    ven = _player(w, "Ven", [ENCH])
    ven.drop_guild = 1
    _join(w, ven, 120)
    check(not _missing([jeg, ven]), "Én tabt guild-besked: den sendes igen, og begge er synkroniseret")
    check(not any("not getting through" in p for p in ven.prints), "... uden at skifte til whisper")

    # 15 % og 30 % tab, 6 spillere, én af dem blokeret.
    for loss in (0.15, 0.30):
        w = World()
        w.loss = loss
        w.rng = random.Random(3)
        pool = [ALCH, TAIL, ENCH]
        cs = [_player(w, f"P{i}", [pool[i % 3]], muted=(i == 3)) for i in range(6)]
        for c in cs:
            _join(w, c, 2)
        w.step(900)
        check(not _missing(cs), f"{int(loss * 100)} % tab, 6 spillere (1 blokeret): alle synkroniseret efter 15 min "
              f"({len(_missing(cs))} mangler, {len(w.sent)} beskeder)")
        lua_errors(*cs)

    # En times stilstand: kun hjerteslag, ingen snak i ring.
    w = World()
    pool = [ALCH, TAIL, ENCH]
    cs = [_player(w, f"P{i}", [pool[i % 3]]) for i in range(6)]
    for c in cs:
        _join(w, c, 2)
    w.step(300)
    start = len(w.sent)
    w.step(3600)
    busiest = max(sum(1 for m in w.sent[start:] if m[1] == c.name) for c in cs)
    check(busiest <= 8, f"En times stilstand: travleste spiller sender {busiest} beskeder (hjerteslag)")


def scenario_gathering():
    print("\nScenarie 13: professions uden vindue (Skinning) vises også")
    w = World()
    jeg = _player(w, "Jeg", [TAIL])
    _join(w, jeg, 30)
    ven = Client(w, "Ven", "ROGUE", 11, profs=[{"name": "Skinning", "rank": 40, "max": 75, "recipes": []}])
    w.clients.append(ven)
    ven.login()
    w.step(60)
    c = jeg.cache(ven.key)
    profs = dict(c.profs.items()) if c else {}
    check("Skinning" in profs and profs["Skinning"].rank == 40, "Jeg ser vennens Skinning 40 uden at han har åbnet noget")
    lua_errors(jeg, ven)


def scenario_mainline():
    print("\nScenarie 14: Mainline-klienten (retail / WoW Forever) uden de gamle Classic-funktioner")
    w = World()
    anna = Client(w, "Anna", "PRIEST", 60, profs=[ALCH], flavor="mainline", spec_role="HEALER",
                  bags={0: [(13468, 3)], 5: [(10620, 7)], 12: [(2589, 40)]})
    bob = Client(w, "Bob", "WARRIOR", 60, flavor="mainline", spec_role="DAMAGER",
                 profs=[TAIL, ENCH, {"name": "Skinning", "rank": 40, "max": 75, "recipes": []}],
                 bags={0: [(8925, 1), (2589, 10)]})
    w.clients = [anna, bob]
    anna.login()
    bob.login()
    anna.open_trade("Alchemy")
    w.step(2)
    bob.open_trade("Tailoring")
    w.step(2)
    bob.open_craft("Enchanting")        # samme vindue som de andre professions i Mainline
    w.step(2)
    anna.slash("mats on")
    anna.g.sim_fire("BANKFRAME_OPENED")
    w.step(150)

    check(anna.recipe_ids(bob.key) == {("i", 2996), ("i", 2568), ("e", 7418), ("e", 13646)},
          "C_TradeSkillUI: Anna får Bobs tailoring-items og enchants (ulært recipe er ikke med)")
    check(bob.recipe_ids(anna.key) == {("i", 13510), ("i", 13446)}, "Bob får Annas alchemy-recipes")
    rg = bob.g.GuildCraftersDB.reagents
    check(rg["i13510"] is not None and list(rg["i13510"].r.values()) == [13468, 1, 8925, 1],
          "Reagents fra recipe-skemaet: kun faste pladser, laveste kvalitet")
    c = anna.cache(bob.key)
    check(c.role == "DPS" and bob.cache(anna.key).role == "HEALER", "Rolle fra specialization (ingen talent-tabs)")
    profs = {k: v.rank for k, v in c.profs.items()}
    check(profs == {"Tailoring": 75, "Enchanting": 100, "Skinning": 40},
          f"Professions og rank via GetProfessions, også Skinning ({profs})")
    mats = bob.cache(anna.key).mats
    check(mats is not None and mats.bags[10620] == 7, "Mats i reagent-tasken (5. taske) tælles med")
    check(mats is not None and mats.bank[2589] == 40, "Mats i bank-faner tælles med")
    lines = bob.tooltip(13510)
    check(any("Crafted by" in l and "Anna" in l for l in lines), "Tooltip via TooltipDataProcessor viser \"Crafted by\"")

    # Fanerne, menuer (MenuUtil) og hele rundturen.
    ns = bob.ns
    bob.slash("")
    for tab in ("Roster", "Crafting", "Craft List", "Mats"):
        ns.UI.ShowTab(ns.UI, tab)
    ns.Data.CraftListAdd(ns.Data, "i", 13510, 2)
    bob.slash("debug tour")
    w.step(70)
    report = bob.g.GuildCraftersDB.debugTour
    errors = [f"{e.step}: {e.msg}" for _, e in report.errors.items()] if report else ["ingen rapport"]
    check(report is not None and len(list(report.steps.items())) == 16 and not errors,
          "Rundturen gennem alle faner (16 trin) uden fejl" + (f" ({errors[0]})" if errors else ""))

    # Blokeret guild-kanal virker på samme måde.
    cara = Client(w, "Cara", "MAGE", 30, profs=[dict(ENCH)], flavor="mainline")
    cara.guild_muted = True
    w.clients.append(cara)
    cara.login()
    cara.open_craft("Enchanting")
    w.step(150)
    check(anna.recipe_ids(cara.key) == {("e", 7418), ("e", 13646)}, "Whisper-reserven virker også i Mainline")
    lua_errors(anna, bob, cara)


def _strip(text):
    return re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", str(text or ""))


def scenario_ux():
    print("\nScenarie 15: UX - Crafting som auktionshuset, /gc-søgning, roster-menu, hints og huskede filtre")
    w = World()
    me = Client(w, "Pepsi", "PRIEST", 34, profs=[TAIL, dict(ENCH)], talents=(5, 31, 15),
                bags={0: [(2589, 4), (8925, 1)]})
    anna = Client(w, "Anna", "DRUID", 60, profs=[ALCH], talents=(5, 31, 15), bags={0: [(13468, 3), (8925, 20)]})
    bob = Client(w, "Bob", "WARRIOR", 60, profs=[TAIL], talents=(5, 5, 41), bags={0: [(2589, 60)]})
    w.ghosts = [("Aaron", 60, "ROGUE", True), ("Sleepy", 22, "MAGE", False)]
    w.clients = [me, anna, bob]
    for c in (me, anna, bob):
        c.login()
    me.open_trade("Tailoring")              # Enchanting åbnes først senere
    anna.open_trade("Alchemy")
    bob.open_trade("Tailoring")
    anna.slash("mats on")
    bob.slash("mats on")
    w.step(200)
    ns, L, g = me.ns, me.L, me.g

    visible_text = L.eval("""function(prefix)
        for _, f in ipairs(sim_allFrames) do
            local t = rawget(f, "sim_text")
            if type(t) == "string" and t:sub(1, #prefix) == prefix and f:IsVisible() then return t end
        end
    end""")
    result_rows = L.eval("""function()
        local out = {}
        for _, f in ipairs(sim_allFrames) do
            local item = rawget(f, "item")
            if item and item.keys and rawget(f, "crafters") and f:IsVisible() then
                table.insert(out, item.name .. "|" .. f.right.sim_text .. "|" .. f.crafters.sim_text
                    .. "|" .. f.onList.sim_text)
            end
        end
        return out
    end""")
    click_text = L.eval("""function(text, button)
        for _, f in ipairs(sim_allFrames) do
            local fs = rawget(f, "text") or rawget(f, "label")
            local t = (type(fs) == "table" and fs.sim_text) or rawget(f, "sim_text")
            if t == text and f:IsVisible() and f.sim_scripts.OnClick then
                if f.sim_kind == "CheckButton" then f:SetChecked(not f:GetChecked()) end
                f.sim_scripts.OnClick(f, button or "LeftButton")
                return true
            end
        end
        return false
    end""")
    menu_of = L.eval("""function(pred)
        sim_menu = nil
        for _, f in ipairs(sim_allFrames) do
            if f:IsVisible() and f.sim_scripts.OnClick and pred(f) then
                f.sim_scripts.OnClick(f, "RightButton")
                break
            end
        end
        local out = {}
        for _, info in ipairs(sim_menu or {}) do table.insert(out, info.text) end
        return out
    end""")
    tooltip_of = L.eval("""function(pred)
        GameTooltip.sim_lines = {}
        for _, f in ipairs(sim_allFrames) do
            if f:IsVisible() and f.sim_scripts.OnEnter and pred(f) then
                f.sim_scripts.OnEnter(f)
                break
            end
        end
        return GameTooltip.sim_lines
    end""")

    def rows():
        return [_strip(r).split("|") for _, r in result_rows().items()]

    def menu(pred):
        return [_strip(t) for _, t in menu_of(L.eval(pred)).items()]

    def tip(pred):
        return [_strip(t) for _, t in tooltip_of(L.eval(pred)).items()]

    # Hint om en profession, der aldrig er åbnet (Enchanting): én gang i chatten og øverst i Crafting.
    hints = [p for p in me.prints if "Open Enchanting once" in p]
    check(len(hints) == 1, f"Chat-hint om uåbnet Enchanting kommer én gang ({len(hints)})")
    ns.Data.HintUnscanned(ns.Data)
    check(sum("Open Enchanting once" in p for p in me.prints) == 1, "Hintet gentages ikke i chatten")
    ns.UI.ShowTab(ns.UI, "Crafting")
    w.step(2)
    check(visible_text("Open Enchanting once") is not None, "Crafting viser hintet øverst")
    me.open_craft("Enchanting")
    w.step(2)
    check(visible_text("Open Enchanting once") is None, "Hintet forsvinder, når Enchanting har været åbnet")

    # /gc <tekst> søger i Crafting; et shift-klikket item bliver til sit navn.
    ns.UI.Toggle(ns.UI)
    me.slash("flask")
    w.step(1)
    check(g.GuildCraftersCraftingSearch.sim_text == "flask" and [r[0] for r in rows()] == ["Flask of the Titans"],
          f"/gc flask åbner Crafting med søgningen ({[r[0] for r in rows()]})")
    me.slash("|cffffffff|Hitem:13446::::::::|h[Major Healing Potion]|h|r")
    w.step(1)
    check(g.GuildCraftersCraftingSearch.sim_text == "Major Healing Potion" and len(rows()) == 1,
          f"/gc [item-link] søger på itemets navn ({g.GuildCraftersCraftingSearch.sim_text})")
    me.prints.clear()
    me.slash("help")
    check(any("/gc <text>" in p for p in me.prints), "/gc help nævner søgningen")

    # Shift-klik på et item i taskerne sætter navnet i søgefeltet (som i AH), men kun når chatten er lukket.
    link = "|cffffffff|Hitem:13510::::::::|h[Flask of the Titans]|h|r"
    g.ChatEdit_InsertLink(link)
    check(g.GuildCraftersCraftingSearch.sim_text == "Major Healing Potion", "Åben chatboks: linket går i chatten, ikke i søgefeltet")
    g.sim_chatOpen = False
    g.ChatEdit_InsertLink(link)
    w.step(1)
    check(g.GuildCraftersCraftingSearch.sim_text == "Flask of the Titans" and [r[0] for r in rows()] == ["Flask of the Titans"],
          "Lukket chat: shift-klik sætter itemets navn i Crafting-søgningen")
    ns.UI.ShowTab(ns.UI, "Mats")
    g.ChatEdit_InsertLink("|cffffffff|Hitem:2589::::::::|h[Linen Cloth]|h|r")
    check(g.GuildCraftersMatsSearch.sim_text == "Linen Cloth", "På Mats-fanen går navnet i Mats-søgningen")
    g.sim_chatOpen = True
    box = g.GuildCraftersMatsSearch
    box.SetText(box, "")

    # Kolonner: Name | Lvl | Crafters på én linje; klik på overskriften sorterer, klik igen vender.
    ns.UI.ShowTab(ns.UI, "Crafting")
    check(click_text("Reset"), "Reset-knappen findes")
    w.step(1)
    check(g.GuildCraftersCraftingSearch.sim_text == "" and len(rows()) == 6, f"Reset rydder søgningen ({len(rows())} recipes)")
    names = [r[0] for r in rows()]
    check(names == sorted(names), "Standard: sorteret efter navn")
    flask = next(r for r in rows() if r[0] == "Flask of the Titans")
    check(flask[1] == "50" and flask[2] == "Anna", f"Rækken har level og crafter i kolonner ({flask})")
    click_text("Lvl")
    levels = [int(r[1] or 0) for r in rows()]
    check(levels == sorted(levels) and levels[-1] == 50, f"Klik på Lvl sorterer stigende ({levels})")
    click_text("Lvl")
    levels = [int(r[1] or 0) for r in rows()]
    check(levels == sorted(levels, reverse=True), f"Klik igen vender rækkefølgen ({levels})")
    click_text("Crafters")
    crafters = [r[2] for r in rows()]
    check(crafters[0] != "Pepsi" and crafters[-2:] == ["Pepsi", "Pepsi"],
          f"Klik på Crafters: det, en anden online kan lave, står først ({crafters})")
    click_text("Name")

    # "Usable items": Pepsi er level 34, så Flask (50) og Major Healing Potion (45) forsvinder.
    usable = L.eval("""function()
        for _, f in ipairs(sim_allFrames) do
            if f.sim_kind == "CheckButton" and rawget(f, "label") and f.label.sim_text == "Usable items" then return f end
        end
    end""")()
    usable.SetChecked(usable, True)
    usable.sim_scripts.OnClick(usable)
    names = [r[0] for r in rows()]
    check("Flask of the Titans" not in names and "Brown Linen Vest" in names and len(names) == 4,
          f"\"Usable items\" skjuler det, ens level ikke kan bruge ({names})")

    # "x2" foran + når en recipe står på listen; højreklik kan fjerne den igen.
    ns.Data.CraftListAdd(ns.Data, "i", 2568, 2)
    ns.Data.CraftListAdd(ns.Data, "i", 13510, 1)
    w.step(1)
    vest = next(r for r in rows() if r[0] == "Brown Linen Vest")
    check(vest[3] == "x2", f"Recipe på craft-listen viser x2 ({vest})")
    m = menu("function(f) local i = rawget(f, 'item') return i and i.name == 'Brown Linen Vest' and rawget(f, 'crafters') end")
    check("Remove from craft list" in m and "Add to craft list" in m and "Whisper Bob" in m, f"Menu på recipe ({m})")

    # Roster: søgning på profession/class, addon-brugere øverst, menu uden meningsløse punkter.
    ns.UI.ShowTab(ns.UI, "Roster")
    w.step(1)
    roster = L.eval("""function()
        local out = {}
        for _, f in ipairs(sim_allFrames) do
            local e = rawget(f, "entry")
            if e and rawget(f, "dot") and f:IsVisible() then table.insert(out, e.key) end
        end
        return out
    end""")

    def shown():
        return [k.split("-")[0] for _, k in roster().items()]
    check(shown() == ["Anna", "Bob", "Pepsi", "Aaron", "Sleepy"],
          f"Online først, og blandt dem addon-brugere før andre ({shown()})")
    box = g.GuildCraftersRosterSearch
    box.SetText(box, "alch")
    check(shown() == ["Anna"], f"Søgning på \"alch\" finder alchemisten ({shown()})")
    box.SetText(box, "priest")
    check(shown() == ["Pepsi"], f"Søgning på \"priest\" finder en class ({shown()})")
    box.sim_scripts.OnEscapePressed(box)
    check(box.sim_text == "" and len(shown()) == 5, "Esc rydder roster-søgningen")
    m = menu("function(f) local e = rawget(f, 'entry') return e and rawget(f, 'dot') and e.key:find('^Pepsi') end")
    check("Whisper" not in m and "Invite" not in m and "Set role: Auto (current)" in m and "Set as main" not in m,
          f"Egen række: ingen Whisper/Invite, nuværende rolle markeret ({m})")
    m = menu("function(f) local e = rawget(f, 'entry') return e and rawget(f, 'dot') and e.key:find('^Sleepy') end")
    check(m == ["Sleepy", "Whisper"], f"Offline medlem: ingen Invite ({m})")
    m = menu("function(f) local e = rawget(f, 'entry') return e and rawget(f, 'dot') and e.key:find('^Anna') end")
    check(m == ["Anna", "Whisper", "Invite", "Show recipes"], f"Online medlem med addon ({m})")
    t = tip("function(f) local e = rawget(f, 'entry') return e and rawget(f, 'dot') and e.key:find('^Sleepy') end")
    check("Last online: 3 days ago" in t, f"Tooltip på offline medlem viser sidst online ({t})")

    # Item-tooltip: "Guild has" uden en selv.
    t = [_strip(l) for l in me.tooltip(8925)]
    check(any(l == "Guild has: Anna 20" for l in t), f"Tooltip: \"Guild has\" uden ens egen char ({t})")

    # Craft List: crafter på rækken, og en manglende mat, som kan craftes.
    ns.UI.ShowTab(ns.UI, "Craft List")
    w.step(1)
    craft_rows = L.eval("""function()
        local out = {}
        for _, f in ipairs(sim_allFrames) do
            local item = rawget(f, "item")
            if item and rawget(f, "toggle") and f:IsVisible() and not item.note then
                out[item.name] = f.guild.sim_text
            end
        end
        return out
    end""")
    cl = {k: _strip(v) for k, v in craft_rows().items()}
    check(cl.get("Flask of the Titans") == "Crafter: Anna", f"Item-rækken viser crafteren ({cl.get('Flask of the Titans')})")
    check(cl.get("Brown Linen Vest") == "Crafter: You +1",
          f"Kan man selv lave det, står der \"You\" (+1 for Bob) ({cl.get('Brown Linen Vest')})")
    check(cl.get("Bolt of Linen Cloth") == "You can craft it",
          f"Manglende mat, man selv kan lave: \"You can craft it\" ({cl.get('Bolt of Linen Cloth')})")
    m = menu("function(f) local i = rawget(f, 'item') return i and i.need and i.name == 'Bolt of Linen Cloth' end")
    check("Add 4x to craft list" in m, f"Højreklik på matten kan lægge den på listen ({m})")
    L.execute("""for _, info in ipairs(sim_menu) do
        if info.text and info.text:find("^Add 4x") then info.func() end
    end""")
    entry, _ = ns.Data.CraftListFind(ns.Data, "i", 2996)
    check(entry is not None and entry.qty == 4, "Bolt of Linen Cloth x4 ligger nu på craft-listen")
    w.step(1)
    cl = {k: _strip(v) for k, v in craft_rows().items()}
    check(cl.get("Bolt of Linen Cloth") == "Crafter: You +1", f"Egen recipe: \"Crafter: You +1\" ({cl.get('Bolt of Linen Cloth')})")

    # Filtre og sortering huskes efter logout/login, og login-linjen kommer kun første gang.
    ns.UI.ShowTab(ns.UI, "Roster")
    click_text("Lvl")
    saved = me.logout()
    again = Client(w, "Pepsi", "PRIEST", 34, profs=[TAIL, dict(ENCH)], talents=(5, 31, 15), saved=saved)
    w.clients[0] = again
    again.login()
    w.step(20)
    f = again.g.GuildCraftersDB.settings.filters
    check(f.crafting.usable is True and f.roster.sortKey == "level", "Flueben og sortering ligger i SavedVariables")
    again.slash("")
    again.ns.UI.ShowTab(again.ns.UI, "Crafting")
    checked = again.L.eval("""function()
        for _, f in ipairs(sim_allFrames) do
            if f.sim_kind == "CheckButton" and rawget(f, "label") and f.label.sim_text == "Usable items" then
                return f:GetChecked()
            end
        end
    end""")()
    check(checked is True, "\"Usable items\" er stadig slået til efter login")
    check(not any("loaded" in p or "installed" in p for p in again.prints),
          f"Login-linjen vises ikke igen ved næste login ({again.prints[:1]})")
    lua_errors(again, anna, bob)


def scenario_test_copy():
    print("\nScenarie 16: testudgaven (GuildCraftersTest) ved siden af den udgivne addon")

    def toc(name):
        return [l.strip() for l in open(os.path.join(ADDON, name), encoding="utf-8")]

    def head(lines, key):
        return next((l for l in lines if l.startswith(f"## {key}:")), None)

    def body(lines):
        return [l for l in lines if l and not l.startswith("#")]

    main, test = toc("GuildCrafters.toc"), toc("GuildCraftersTest.toc")
    check(body(main) == body(test), "GuildCraftersTest.toc lister de samme filer som GuildCrafters.toc")
    for key in ("Interface", "Version"):
        check(head(main, key) == head(test, key),
              f"Samme {key} i begge .toc-filer ({head(main, key)} / {head(test, key)})")
    check(head(test, "SavedVariables") == "## SavedVariables: GuildCraftersTestDB",
          f"Testudgaven gemmer i GuildCraftersTestDB ({head(test, 'SavedVariables')})")
    check(head(test, "X-Curse-Project-ID") is None, "Testudgaven har intet CurseForge-projekt-id")

    # Testudgaven alene: kører som normalt, synkroniserer med den udgivne og gemmer i sin egen global.
    w = World()
    anna = Client(w, "Anna", "PRIEST", 60, profs=[ALCH], talents=(5, 31, 15))
    bob = Client(w, "Bob", "WARRIOR", 60, profs=[TAIL], talents=(5, 5, 41), addon="GuildCraftersTest")
    w.clients = [anna, bob]
    anna.login()
    bob.login()
    anna.open_trade("Alchemy")
    bob.open_trade("Tailoring")
    w.step(60)
    check(bob.g.GuildCraftersTestDB is not None and bob.g.GuildCraftersDB is None,
          "Testudgaven bruger GuildCraftersTestDB og rører ikke GuildCraftersDB")
    check(bob.recipe_ids(anna.key) == {("i", 13510), ("i", 13446)}, "Testudgaven modtager Annas recipes")
    check(anna.recipe_ids(bob.key) == {("i", 2996), ("i", 2568)}, "Anna modtager testudgavens recipes")

    def titles(client):
        client.slash("")
        w.step(1)
        return client.L.eval("""function()
            local found = {}
            for _, f in ipairs(sim_allFrames) do
                if f.sim_text == "GuildCrafters" or tostring(f.sim_text):find("[TEST]", 1, true) then
                    found[#found + 1] = f.sim_text
                end
            end
            return table.concat(found, ";")
        end""")()

    check("[TEST]" in titles(bob), "Testudgavens vindue hedder \"GuildCrafters [TEST]\"")
    check("[TEST]" not in titles(anna), "Den udgivne addons vindue hedder bare \"GuildCrafters\"")
    lua_errors(anna, bob)
    check("Tailoring" in bob.logout(), "Testudgavens data kan gemmes ved logout")

    # Begge slået til: den udgivne er indlæst først, så testudgaven holder sig helt i ro.
    w = World()
    anna = Client(w, "Anna", "PRIEST", 60, profs=[ALCH], talents=(5, 31, 15))
    both = Client(w, "Bob", "WARRIOR", 60, profs=[TAIL], talents=(5, 5, 41), addon="GuildCraftersTest",
                  also_loaded=("GuildCrafters",))
    w.clients = [anna, both]
    anna.login()
    both.login()
    anna.open_trade("Alchemy")
    both.open_trade("Tailoring")
    w.step(60)
    check(any("Not running" in p and "GuildCrafters is enabled too" in p for p in both.prints),
          f"Begge slået til: testudgaven siger, at den ikke kører ({both.prints[:1]})")
    check(both.g.SlashCmdList.GUILDCRAFTERS is None, "... og tager ikke /gc")
    check(both.g.GuildCraftersTestDB is None, "... og opretter ingen gemte data")
    check(not any(s[1] == "Bob" for s in w.sent), "... og sender ingen addon-beskeder")
    check(anna.cache(both.key) is None or not anna.recipe_ids(both.key),
          "Anna får ingen recipes fra den stille kopi")
    lua_errors(anna, both)


if __name__ == "__main__":
    scenario_sync()
    scenario_relay()
    scenario_alts()
    scenario_ui()
    scenario_protocol()
    scenario_storm()
    scenario_crafting()
    scenario_tour()
    scenario_blocked()
    scenario_blocked_more()
    scenario_loss()
    scenario_gathering()
    scenario_mainline()
    scenario_ux()
    scenario_test_copy()
    print()
    if failures:
        print(f"{len(failures)} FEJL")
        sys.exit(1)
    print("Alle scenarier OK")
