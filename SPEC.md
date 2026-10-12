# GuildCrafters – SPEC v0.9

> **Status:** v0.14.0 (UX-gennemgang: Crafting som auktionshuset, se §7). Alle faser + Crafting-fane med kategorier, stats-søgning, reagents-sync og Craft List.
> Testet i simulatoren (`tools/sim`, 59 tjek). Fase 1–2 og UI er også set i TBC Anniversary.
> Mangler: rigtig test med flere spillere i guilden.

En guild-addon, der giver et fælles overblik over **hvem er hvem**, og **hvem kan crafte hvad**.
Den laves til ca. 10 spillere i samme guild. Der er ingen ekstern server. Al data deles via addon-beskeder
over GUILD.


> **Klienter (fra v0.13.0):** Samme kode kører på Classic-klienterne (TBC Anniversary 2.5.6, Classic Era)
> og på Mainline-klienten (retail 12.x og WoW Forever, interface 16001). `Compat.lua` vælger udgave med
> `Compat.IS_MAINLINE`. Forever udkommer 2026-11-04 og bruger retails API med Midnights
> addon-begrænsninger; se CLAUDE.md for de undersøgte fakta og hvad der ikke er testet i en rigtig klient.

## 1. Mål og scope

| # | Feature | v1 |
|---|---------|----|
| 1 | Roster: class, spec, rolle, level, professions og online-status | ✔ |
| 2 | Crafter-opslag: søg fx "Flask" og se hvem, der kan crafte det | ✔ |
| 3 | Tooltip: "Crafted by: X, Y" | ✔ |
| 4 | Mats-deling: hvem har hvilke crafting-mats | ✔ (opt-in) |

**Out of scope:** ekstern server/web, cross-guild-sync, crafting-ordrer og auktionspriser.

## 2. Målclient

- **Endeligt mål:** WoW Forever. Den er ikke udkommet endnu, og API'et er ukendt.
- **Udvikling og test:** TBC Anniversary 2.5.6 (`## Interface: 20506`). Classic Era 1.15.9 (`11509`)
  understøttes sekundært.
- Begge er moderne Blizzard-clients med Lua 5.1, `C_ChatInfo`, `HookScript` og `C_Timer`.
- **Al kode, der afhænger af version, ligger i `Compat.lua`.** Andre filer kalder aldrig direkte
  et API, der er "måske-findes".

**Kendte forskelle**

| | TBC 2.5.x | Era 1.15.x |
|---|---|---|
| Jewelcrafting | ja | nej |
| Guild bank | ja | nej |
| Enchanting | Craft- eller TradeSkill-API (verificeres) | Craft-API (`GetNumCrafts`) |

Addonen lytter på både `TRADE_SKILL_SHOW`/`TRADE_SKILL_UPDATE` og `CRAFT_SHOW`/`CRAFT_UPDATE`.
Om guild bank og Jewelcrafting findes, afgøres ved runtime (feature-detect) og ikke ud fra versionsnummeret.

**Forbudt (kun retail):** `C_TradeSkillUI`, `GetSpecialization*`, `C_ClassTalents`, `C_Traits`,
`C_Club`, `C_TooltipInfo`/`TooltipDataProcessor` og `Settings`-API'et. Kun hvis det er feature-detected i Compat.

## 3. Filstruktur

```
GuildCrafters/
  GuildCrafters.toc
  Libs/            LibStub, CallbackHandler-1.0, AceComm-3.0 (+ChatThrottleLib), AceSerializer-3.0,
                   LibDataBroker-1.1, LibDBIcon-1.0
  Compat.lua       API-shims og feature-detect (alt versionsafhængigt)
  Core.lua         namespace, events, interne beskeder (On/Fire), /gc
  Data.lua         DB-model, versioner, payloads (byg/anvend), guild-cache
  Scanner.lua      scan af TradeSkill og Craft
  Roles.lua        gæt på spec og rolle, manuel override
  Comm.lua         prefix, serialisering, send/modtag, protokolversion, debug-log
  Sync.lua         HELLO/INVR/REQ/DATA/GBANK, jitter, relay, online-status
  Mats.lua         scan af tasker, bank og guild bank, opt-in
  Index.lua        opslag: hvem crafter hvad, hvem har hvilke mats
  Tooltip.lua      "Crafted by" og "Guild has"
  UI/Frame.lua     vindue, faner, fælles hjælpere (ikoner, farver)
  UI/List.lua      liste med to linjer pr. række, søgefelt, whisper-menu
  UI/Roster.lua  UI/Search.lua  UI/Mats.lua
  UI/Launchers.lua minimap-knap og knap i guild-vinduet
  Debug.lua        /gc debug dump|fake|clear|comm|hello|ping
tools/sim/         simulator med flere klienter (se afsnit 12)
```

## 4. Datamodel (SavedVariables `GuildCraftersDB`, account-wide)

```lua
GuildCraftersDB = {
  schema = 1,
  settings = { minimap = {}, shareMats = false },
  myChars = { ["Bob-Realm"] = <char-record> },  -- egne chars (ejer-data, kilde til sync)
  guilds = {
    ["Realm/GuildNavn"] = {
      chars = {                                  -- cache af andres chars
        ["Bob-Realm"] = {
          class = "WARRIOR", level = 70,
          specTab = 3, role = "TANK", roleOverride = nil,
          main = "Bob-Realm",
          profs = {
            ["Blacksmithing"] = {
              rank = 375, max = 375, scanned = 1727870000,
              items = { [23563] = true },        -- created itemID
              enchants = {},                     -- enchant-spellID
            },
          },
          mats = { bags = { [23445] = 40 }, bank = { [23445] = 120 } },
          v = { info = 4, recipes = 12, mats = 3 }, -- tæller, bumpes ved ændring
          seen = 1727870000,                       -- sidst set (servertid)
          addonVer = "0.1.0",
        },
      },
      guildBank = { scanTime = 1727870000, tabs = { [1] = { [23445] = 200 } } },
    },
  },
}
```

- **Nøgler:** Recipes gemmes som *created itemID* (fra `GetTradeSkillItemLink`). Enchants gemmes som
  *spellID* fra `enchant:NNNN`-linket. Navne gemmes aldrig, de resolves lokalt. Dermed er data uafhængige
  af clientens sprog.
- **Versioner:** Hver char har en tæller pr. datatype. Tælleren bumpes kun, når indholdet faktisk er
  ændret (sammenlign med forrige scan).
- **Scan er additivt:** Et filtreret vindue eller lukkede kategorier må aldrig fjerne recipes, og
  recipes kan ikke aflæres. Lukkede kategorier foldes ud én gang pr. åbning. Rank opdateres også fra
  Skills-fanen (`SKILL_LINES_CHANGED`).
- **Kendt hul:** En profession, der er droppet, bliver liggende. Senere kommer `/gc forget <profession>`
  eller detektion.
- **Alts:** `myChars` er account-wide, så hver client kender sine egne chars. Kun `main` sendes i `HELLO`, og modtageren udleder alts derfra. `main` sættes med `/gc main <navn>` eller via højreklik i rosteren.
  Standard er den char med højest level. En alt bliver først kendt, når den har været logget ind med addonen.

## 5. Protokol

- Prefix: `GCRAFT`, registreres via `C_ChatInfo.RegisterAddonMessagePrefix`.
- Kanal: alt sendes over `GUILD`, så alle opdaterer deres cache, når de hører en `DATA` eller `GBANK`.
- Transport: AceComm (chunking ud over 255 bytes) + AceSerializer. Throttling via ChatThrottleLib:
  `HELLO`/`REQ` sendes med `NORMAL`, `DATA`/`INVR`/`GBANK` med `BULK`.
- Datatyper (`k`): `info` (class, level, spec, rolle, main, professions med rank, `ms` = deler mats),
  `recipes` (`{ p = {profession = {i = itemIDs, e = enchantIDs}}, g = {["i123"] = {made, id, antal, ...}} }`)
  og `mats` (`{b = tasker, k = bank, t = tid}`). Reagents (`g`) er spildata og gemmes i én fælles
  tabel (`db.reagents`). Nye reagents bumper `recipes`-versionen, så de når ud.
- Alle beskeder: `{ p = 2, t = "<type>", ... }`, hvor `p` er protokollens major-version. Version 2 kom
  med reagents i recipes-payloaden. Klienter med `p = 1` ignorerer beskederne og får besked om at opdatere.

| Type | Indhold | Hvornår |
|---|---|---|
| `HELLO` | info-payload, `v{info,recipes,mats}`, `gb` (vores guild bank-tid), `q` ("svar venligst") | Ved login med `q` (5–15 s jitter), 5 s efter ændringer, og 1–5 s efter en fremmed `HELLO` med `q`. Flere ønsker samles til én besked, og der går mindst 10 s mellem to `HELLO` |
| `INVR` | `l = {char = {infoV, recipesV, matsV}}` for offline chars, vi har data om | 2–8 s efter en `HELLO` med `q`. Chars, som en anden allerede har annonceret i samme eller nyere version, udelades |
| `REQ` | `c` (char), `k` (type), `h` (version vi har) | 0,5–3 s efter at en `HELLO`/`INVR` viser en nyere version. Droppes, hvis en anden har bedt om det samme |
| `DATA` | `c`, `k`, `v`, `d` (payload) | Som svar på `REQ`: ejeren efter 0,2–1 s, egne alts efter 0,5–1,5 s, relay (kun for offline chars) efter 2–6 s |
| `GBANK` | `s` (scan-tid), `d` (faner) | 5 s efter et ændret guild bank-scan, og når en `HELLO` viser, at afsenderen har en ældre guild bank |

**Regler**
- **Login-storm:** Alle forsinkelser er tilfældige (jitter). Der er højst én aktiv `REQ` pr.
  (char, type), med timeout på 30 s. Målt i simulatoren: 10 spillere logger ind inden for 30 s, og alle
  har alles data efter 2 min. Det giver 50 beskeder / ca. 7 KB i alt og højst 7 beskeder pr. spiller.
- **Mats-throttling:** Taskeændringer vises lokalt med det samme, men der annonceres højst én ny
  mats-version pr. 90 s. (5 s blev prøvet i første test med en ven og fravalgt som overkill.)
- **Relay (offline-spillere):** Når en `REQ` drejer sig om en char, der er offline, svarer den, der har
  cachen, efter en tilfældig forsinkelse på 2–6 s. De andre lader være at svare, hvis de ser en `DATA`
  med samme eller nyere version. Ejeren svarer altid selv, hvis vedkommende er online.
- **Reserve-transport (whisper), fra v0.11.1:** I første test med en ven svarede API'et "Success" på hans
  guild-beskeder, men serveren leverede dem aldrig (heller ikke retur til ham selv), mens whisper virkede.
  Derfor holder hver klient øje med, om dens egne guild-beskeder kommer retur inden for 8 s. Første gang
  de udebliver, sendes HELLO igen; anden gang slås reserven til: alt sendes stadig på GUILD, men også som
  WHISPER til de online guild-medlemmer, der har addonen (hørt fra i denne session eller i cachen).
  Første gang spørges alle online medlemmer (højst 40), så addon-brugerne bliver fundet. Whispers
  accepteres kun fra medlemmer af ens egen guild. Når en spiller sender via whisper, spørger hver
  modtager selv med `REQ` (en andens `REQ` dækker ikke, fordi svaret ikke kan ses på GUILD). Kommer en
  guild-besked retur igen, slås reserven fra.
- **Tabte beskeder (fra v0.12.0):** Serveren kan tabe addon-beskeder uden fejl. Derfor:
  - *Genforsøg:* Den, der har bedt om data (eller set en andens `REQ`), husker hvilken version der
    mangler, og spørger igen efter 30 s, hvis den ikke er kommet (højst 4 gange; næste `HELLO`
    starter forfra).
  - *Hjerteslag:* Hver klient sender en `HELLO` uden ændringer ca. hvert 10. minut. Modtagerne
    sammenligner versioner og beder om det, de mangler (også guild banken).
  - *Ny kontakt:* Er reserve-transporten slået til, og man hører fra en addon-bruger første gang,
    sender man straks sin `HELLO` til vedkommende. Rundspørgen til alle online sker højst én gang
    pr. session.
  - Simuleret med 10–50 % tilfældigt tab, 8 spillere (én blokeret): alle er synkroniseret efter 15 min.
    En times stilstand giver 6 beskeder pr. spiller.
- **Versionstolerance:** Ukendte felter ignoreres. Hvis `p` er større end vores egen version, ignoreres
  beskeden, og brugeren ser én gang beskeden "Der findes en nyere version af GuildCrafters".
- **Validering:** Typer og størrelser tjekkes (højst 2000 ID'er pr. liste), og forkert formateret data
  droppes stille. Data om egne chars fra andre ignoreres altid, fordi man selv er kilden.

## 6. Spec og rolle

- Spec er det talent-tab (index 1–3, *ikke* det lokaliserede navn), der har flest point
  (`GetTalentTabInfo`). Returværdierne varierer mellem clients, så parsingen ligger i Compat.
- Rollen findes i en tabel over class og tab. Fx: Warrior 3 = TANK, Priest 1/2 = HEALER,
  Paladin 1 = HEALER, Paladin 2 = TANK, Druid 3 = HEALER, Shaman 3 = HEALER.
  Tvetydige tilfælde (feral, ret/prot-hybrid) sættes til DPS.
- Manuel override via UI eller `/gc role tank|healer|dps|auto` gemmes pr. char.

## 7. UI

**Sprog:** Al tekst i spillet er på engelsk (vindue, tooltips, chat-beskeder og hjælp).

**Stil:** Blizzard-native. Vinduet bygger på `BasicFrameTemplateWithInset` (fallback `BasicFrameTemplate`)
med spillets egne knapper, skrifttyper og scrollbars. Der er ingen egen grafik.

**Opbygning:** Ét vindue (740×480) med faner nederst: **Roster | Crafting | Craft List | Mats**.
- Fanerne har samme bredde.
- Afstanden afhænger af templaten: `PanelTabButtonTemplate` har +3, mens den gamle
  `CharacterFrameTabButtonTemplate` overlapper med -16.
- Hver fane har en statuslinje nederst med antal, "Not in a guild" og lignende.

**Opførsel:**
- Vinduet kan flyttes, og positionen huskes.
- ESC lukker det (`UISpecialFrames`).
- Den sidst valgte fane huskes.

**Adgang:** `/gc`, minimap-knap (LibDBIcon, kan slås fra) og en knap i guild-vinduet.
- `/gc <tekst>` (alt, der ikke er en kommando) åbner Crafting med søgningen udfyldt: `/gc flask`. Et
  shift-klikket item (`/gc [Flask of the Titans]`) bliver til sit navn.
- Login-linjen i chatten ("v0.14.0 loaded ...") vises kun første gang og efter en opdatering.

**Huskede valg:** Fanernes flueben og sortering gemmes i `db.settings.filters` (`UI.Saved`): Roster
(Online only, filter, sortering), Crafting (Usable items, Online crafters only, sortering) og Mats
(Only my craft list). Søgetekst og valgt kategori huskes ikke.

**Roster:**
- Hver række har:
  - online-prik
  - navn i class-farve, og for alts "(alt of Bob)"
  - rolle-ikon
  - level
  - profession-ikoner med rank
- Medlemmer uden addonen er grå.
- Rækkefølge: online først, derefter dem med addonen (i en guild med flere hundrede medlemmer drukner
  de ellers), derefter den valgte kolonne. Klik på et kolonnenavn sorterer; en pil viser den aktive
  kolonne og retningen.
- Toppen har søgefelt (med x og Esc-ryd som de andre faner), filter (rolle/profession) og "Online
  only". Søgningen dækker navn, main, class, rolle og professions ("alch", "priest", "tank"); flere ord
  skal alle passe.
- Højreklik giver kun det, der giver mening for rækken: Whisper (ikke på en selv), Invite (kun online,
  ikke en selv), Show recipes (åbner Crafting med personen valgt under "By crafter"), og på ens egen
  række Set role med "(current)" ud for det nuværende valg. "Set as main" vises på ens andre chars.
  Venstreklik gør ingenting (en direkte whisper på venstreklik var irriterende).
- Tooltippen viser for offline medlemmer "Last online: 3 days ago" og guild-noten, hvis der er en.

**Crafting** (som auktionshuset; brugeren bad i v0.14 om, at fanen ligner AH mest muligt, og valgte
layoutet ud fra mockups: én linje pr. recipe, filterlinje med "Usable items" og Reset):
```
+------------------------------------------------------------------------+
| [Search name or stats...  x] [ ] Usable items [ ] Online crafters only [Reset]
| Open Enchanting once, so the guild can see your recipes.   (kun når relevant)
|-------------------+----------------------------------------------------|
| All recipes   52  | Name ^                    Lvl  Crafters            |
| - Consumables 18  | [i] Flask of the Titans    50  Anna, Kim        [+]|
|     Flasks     4  | [i] Flask of Supreme Pow.  50  Anna          x2 [+]|
|     Potions   12  | [i] Major Healing Potion   45  Anna, Bob +2     [+]|
| + Armor       20  |                                                    |
| + By crafter   6  |                                                    |
+-------------------+----------------------------------------------------+
| 4 of 52 recipes · Consumables > Flasks                                 |
```
- Kolonner: **Name** (quality-farve), **Lvl** (required level; tom for enchants og ting uden krav) og
  **Crafters** (korte navne, online i grøn og først, højst to og derefter "+N"; alle står i tooltippen
  og højreklik-menuen). Klik på en overskrift sorterer, klik igen vender; pilen viser den aktive.
  Crafters-sorteringen sætter det, en anden online kan lave nu, øverst. Ca. 18 rækker ad gangen.
- "x2" i grøn foran `[+]` betyder, at recipen står på ens craft-liste (tooltippen siger det også).
- **Usable items** (som i AH): kun det, ens level kan bruge. **Reset** rydder søgning, flueben og valgt
  kategori/person; sorteringen bliver.
- Shift-klik på et item i taskerne eller et link i chatten, mens chatboksen er lukket, sætter itemets
  navn i søgefeltet (som i AH). Det samme gælder Mats-fanens søgefelt. Efter-hook på
  `ChatEdit_InsertLink` (`Compat.HookLinkInsert`); spillet åbner selv "split stack" for stakke, og det
  vindue lukkes igen.
- Har man en crafting-profession, hvis vindue aldrig har været åbnet på denne char, står der en gul
  linje under filterlinjen (og én gang i chatten ca. 8 sek. efter login): uden et scan er der ingen
  recipes at dele, og intet andet fortalte en det. Listen rykker en linje ned, mens hintet vises.
- Kategorier bestemmes af item class/subclass, som er sproguafhængige:
  - Consumables: Flasks, Potions, Elixirs, Food & Drink, Bandages
  - Armor: Cloth, Leather, Mail, Plate, Cloaks, Shields
  - Weapons, Gems, Bags, Trade Goods og Ammo
  - Enchants deles op efter slot ud fra navnet: "Enchant **Bracer** - ...".
  - "By crafter" (online først) viser alt, hvad én person kan lave, i **profession-visning** (valgt af
    brugeren ud fra tre mockups): højre side grupperes pr. profession med rank ("TAILORING 287/375",
    primære først, så Cooking/First Aid) og derunder kategorier (underkategori for
    Consumables/Enchants som "Flasks", ellers hovedkategori som "Armor"), med de samme rækker og
    kolonner som ellers (uden Crafters, da alle rækker har samme crafter). Overskrifter folder ind/ud
    ved klik. Rosterens højreklik "Show recipes" åbner samme visning.
- Søgefeltet søger i navn og hele tooltip-teksten (stats, effekter, slot og type). Teksten læses med et
  skjult tooltip og caches. Flere ord skal alle passe, fx "flask tit" eller "fire res".
- Når man holder musen over en række, ser man den fulde item-tooltip med "Crafted by" og reagents.
  Reagents vises med "you have N" i grøn eller rød.
- Klik på items (Crafting, Craft List og Mats) som i resten af spillet: **højreklik** giver en menu med
  "Add to craft list" og "Whisper X", **shift-klik** linker itemet i chatten, og **ctrl-klik** viser det
  på ens egen char i dressing room. Et almindeligt venstreklik gør ingenting (en menu på venstreklik var
  irriterende i praksis).
- "Whisper X" åbner en whisper med færdig tekst, som man kan rette, før man trykker Enter:
  - Crafting: "Hi! Could you craft [Flask of the Titans] for me?" (enchants: "Could you do [...]").
  - Craft List, item: "Hi! Could you craft 2x [...] for me? I have the mats." (sidste del kun hvis Ready).
  - Craft List, mat: "Hi! Could you spare 4x [Linen Cloth]? I need it for Bolt of Linen Cloth." (antal =
    det, man mangler).
  - Mats: "Hi! Do you have any [Thorium Ore] to spare?"
- `[+]` lægger itemet på craft-listen; shift-klik lægger 5 på. Står recipen allerede på listen, har
  højreklik-menuen også "Remove from craft list".
- Søgefelterne (alle faner) har et lille "x", og Esc rydder søgningen.
- Mens item-navne hentes fra serveren (kold cache), står der "Loading recipes..." og ikke "Nothing here".

**Craft List** (personlig, account-wide i `db.craftList`):
- Grupperet pr. item (valgt af brugeren efter test i spillet, hvor én samlet mats-liste var uoverskuelig):
  hver item-række (lys baggrund) har antal, `[-] [+] [x]` og status til højre: "Ready" (grøn),
  "Missing N mats" (rød) eller "Reagents unknown". Lige under står itemets mats i kolonnerne
  **Need / You have / Guild has**.
- Need = antal × ceil(qty / made). You have = den aktuelle chars tasker og bank (`GetItemCount`) plus egne
  alts fra seneste scan. Bruger flere items samme mat, fordeles beholdningen ovenfra og ned, så den
  ikke tælles to gange. Grøn = nok, rød = mangler.
- Guild has: op til tre andre (og guild banken) med antal, resten som "+N". Mangler man en mat, som
  ingen har, men som nogen kan crafte (fx Bolt of Linen Cloth til en vest), står der "Bob can craft it"
  eller "You can craft it", og højreklik giver "Add 4x to craft list" og whisper til crafteren. Ellers
  "Nobody in the guild".
- Item-rækken viser crafteren i samme kolonne: "Crafter: Anna +1" ("You", hvis man selv kan; ét navn
  og "+N", så rækken ikke bliver overlæsset; "No crafter in the guild", hvis ingen kan længere).
- Øverst: "2 of 3 ready - 3 mats missing". Hover på et item viser tooltip med "Crafted by"; højreklik giver
  whisper til en crafter. Højreklik på en mat giver "Ask for X" til dem, der har den (online først).
- Items, der er Ready, er foldet sammen til én linje, så det, man mangler, står tydeligt. `+`/`-`-knappen
  foran itemet folder ud/ind (huskes resten af sessionen).
- `[-] [+]` ændrer antal med 1, shift-klik med 5 (shift-minus går ikke under 1). "Clear list" spørger først.

**Mats:**
- Samme layout, grupperet pr. mat: "Bob 40 (bags) · Anna 120 (bank) · Guild bank 200". Højst fire
  navne pr. række, resten som "+N more" (alle står i tooltippen).
- Tooltippen viser, hvornår hver kilde sidst er opdateret.
- "Share my mats" slår deling til og fra.
- "Only my craft list" viser kun de mats, ens craft-liste skal bruge.

## 8. Tooltip

- `Compat.HookItemTooltip` bruger `TooltipDataProcessor`, hvis det findes, og ellers
  `OnTooltipSetItem`. Den tilføjer "Crafted by: X, Y (+n)" på craftede items. Online-navne står i
  grøn og offline-navne i grå.
- På mats vises "Guild has: X 40, Guild bank 200" ud fra delte mats, ens alts og guild bank. Den char,
  man selv spiller, er ikke med (det står allerede i taskerne).
- **Kendt begrænsning:** Recipe-, pattern- og formula-items kan ikke mappes til deres produkt via API'et.
  Det løses med en lille statisk tabel senere, eller udelades.

## 9. Mats-deling

- Kun crafting-mats tæller med: `GetItemInfo` classID Trade Goods (7) eller Reagent (5), og i TBC
  også Gems (3).
- **Tasker:** scannes ved `BAG_UPDATE_DELAYED` (debounced).
- **Bank:** scannes ved `BANKFRAME_OPENED`/`PLAYERBANKSLOTS_CHANGED` og caches.
- **Guild bank (kun TBC):** scannes ved `GUILDBANKFRAME_OPENED`/`GUILDBANKBAGSLOTS_CHANGED` for de
  faner, man kan se. Data deles altid, fordi de tilhører guilden.
- **Egne mats er opt-in og slået fra som standard.** Er delingen slået fra, sendes `mats` slet ikke.

## 10. Risici

1. **WoW Forevers API er ukendt.** Vi isolerer i Compat og tester ved launch.
2. **Disconnect ved for mange addon-beskeder.** Vi bruger ChatThrottleLib, jitter, deltaer via
   versioner og BULK-prioritet.
3. **`GetItemInfo` returnerer nil, når items ikke er cachet.** Al visning skal kunne klare async-load.
4. **Datamængden for mats** kan blive stor. Vi sender kun mats og kun ved versionsændringer.
5. **Enchanting-API'et kan variere** mellem clients. Derfor lytter vi på begge event-sæt.
6. **Blandede addon-versioner i guilden.** Vi bruger protokol-major, ignorerer ukendte felter og
   advarer om nye versioner.
7. **Relay-data kan være forældede eller forkerte.** Ejerens egne data vinder altid, når ejeren er online.

## 11. Build-rækkefølge

1. Scan egne professions (TradeSkill + Craft) og vis dem lokalt (`/gc debug dump`).
2. Libs + Comm + `HELLO` + roster-fane (inkl. medlemmer uden addon) + alt-kobling + rolle.
3. `REQ`/`DATA` recipe-sync, relay og søg-fane.
4. Tooltip-hook.
5. Mats: tasker, bank og guild bank, opt-in og mats-fane.

## 12. Test

- **Loopback:** Man modtager sine egne GUILD-addon-beskeder, så hele pipelinen kan testes alene.
- **`/gc debug fake N`:** laver N syntetiske guildmedlemmer med tilfældige data til test af UI og
  søgning. `/gc debug clear` fjerner dem igen.
- **`/gc debug dump`** viser DB-indhold, og **`/gc debug comm`** logger beskeder ind og ud.
- **Multi-client:** En guildven kører en dev-build. Testscenarier:
  - begge logger ind
  - den ene lærer en ny recipe
  - den ene logger ud, og en tredje henter data via relay
- **Simulator:** `python tools/sim/sim.py` (kræver `pip install lupa`) kører den rigtige addon-kode,
  inkl. AceComm/ChatThrottleLib, i flere Lua 5.1-runtimes. De kører mod en falsk WoW-API
  (`tools/sim/wowmock.lua`) og et fælles netværk. Scenarier:
  - sync af recipes, roller og guild bank
  - mats-deling til og fra
  - relay til en ny spiller, mens ejeren er offline
  - alts
  - UI-røgtest
  - klient uden guild
  - fremmede eller ødelagte beskeder
  - login-storm med 10 spillere
  
  Kør den efter hver ændring i sync-logikken.
- `/console scriptErrors 1` er slået til under udvikling.
