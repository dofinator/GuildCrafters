# GuildCrafters

Guild-addon til WoW Classic-clients (TBC Anniversary / Classic Era / WoW Forever). Den viser, hvem der
er i guilden, hvilken rolle de spiller, og hvem der kan crafte hvad. Al data deles via addon-beskeder
i guilden, så der er ingen server.

## Installation

1. Kopiér mappen `GuildCrafters` (den inderste, med `GuildCrafters.toc`) til
   `World of Warcraft\_anniversary_\Interface\AddOns\`.
2. Genstart spillet. GuildCrafters skal stå på AddOns-listen.
3. Åbn hvert af dine profession-vinduer én gang, så addonen kender dine opskrifter.

## Brug

| | |
|---|---|
| `/gc` eller minimap-knappen | Åbn vinduet (Roster, Crafting, Craft List, Mats) |
| `/gc flask` | Søg direkte i Crafting. Shift-klik et item efter `/gc ` for at søge på dets navn |
| Crafting | Bygget som auktionshuset: kategorier til venstre, kolonner (Name, Lvl, Crafters) du kan sortere ved klik, og søgning på navn eller stats ("stamina", "fire res"). Shift-klik et item i taskerne for at søge på det. `+` tilføjer til din liste. Højreklik: whisper en crafter. Ctrl-klik: prøv det på. Shift-klik: link i chatten |
| Craft List | Dine ønsker, hver med crafter og mats: hvad du skal bruge, hvad du selv har, og hvem i guilden der har resten. "Ready" når du har det hele |
| Tooltip | Hold musen over et item: "Crafted by ..." og "Guild has: ..." |
| `/gc mats on` | Del dine crafting-mats med guilden (fra som standard) |
| `/gc role tank\|healer\|dps\|auto` | Ret din rolle, hvis gættet er forkert |
| `/gc main <navn>` | Vælg hvilken af dine chars, der er din main |
| `/gc forget <profession>` | Fjern en profession, du har droppet |
| `/gc help` | Alle kommandoer |

Se [SPEC.md](SPEC.md) for design og protokol.

## Udvikling

```
pip install lupa
python tools/sim/sim.py
```

Simulatoren kører addonen i flere falske WoW-klienter og tjekker sync, relay, mats, alts og UI.
