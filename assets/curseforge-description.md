**Proposed summary line (CurseForge "Summary" field, not part of the description):** Roster, Recipes & Shared Mats

---

# GuildCrafters

One Blizzard-style window for your guild: who is who, who has the mats, and who can craft what. There is no server and nothing to set up. Guild members who run the addon sync with each other in the background.

## What it does

- **Roster.** Class, role, level, professions with rank and online status. Alts are linked to their main. Members without the addon are listed too, greyed out.
- **Shared mats.** Opt in, and the guild sees the crafting mats in your bags and bank, next to the guild bank's contents. "Who has Thorium Ore?" gets an answer.
- **Craft List.** A personal shopping list. Pick recipes, and for each item see the mats you need, how many you have, and who in the guild has the rest or can craft the part you are missing.
- **Crafting.** Looks and works like the auction house: categories on the left, sortable columns (Name, Lvl, Crafters), and a search that matches item names and tooltip stats ("fire res"). Filter on "Usable items" or "Online crafters only", or browse one person's recipes. Right-click a recipe to whisper a crafter with the message already written.
- **Tooltips.** Items show "Crafted by: Anna, Bob" and "Guild has: ...", at most four names and then "(+N)".
- **Offline members.** Others pass their data on, so you also see recipes from people who are not online.

## Stays out of the way

- No sync work during combat. It pauses and catches up right after.
- People who left the guild and professions you dropped are hidden right away and cleaned up after a week.
- Works on non-English game clients.
- Light in big guilds (tested in a simulator with 600 members).
- Your data survives a reinstall or a new PC.
- A status line in the window shows the sync state.

## Getting started

1. Install GuildCrafters and restart the game.
2. Type `/gc` or click the minimap button.
3. Open each of your profession windows once, so the addon can read your recipes.
4. Optional: `/gc mats on` to share your mats.

## Commands

- `/gc`: open the window
- `/gc <text>`: search recipes, for example `/gc flask`
- `/gc mats on|off`: share your mats (off by default)
- `/gc tooltip on|off`: tooltip lines on or off
- `/gc sync`: ask the guild for fresh data
- `/gc role tank|healer|dps|auto`: correct your role
- `/gc main <name>|auto`: pick your main character
- `/gc forget <profession>`: remove a profession by hand
- `/gc minimap`: show or hide the minimap button
- `/gc help`: list all commands

## Switching from another guild profession addon?

- GuildCrafters is deliberately small: a roster, recipes, a craft list and shared mats, in windows that look like Blizzard's own.
- Nothing is imported. Everyone installs GuildCrafters and opens their profession windows once.
- If your old addon also uses `/gc`, disable it first.

## Supported game versions

- TBC Anniversary (2.5.6)
- Classic Era (1.15.x)
- WoW Forever: built for it and ready for launch-day testing, but not yet tested on a real Forever client.

## FAQ

**Is there a server?** No. Data travels as addon messages inside your guild and is saved on your own PC.

**Someone shows as "Does not have GuildCrafters".** They have not installed it, or their data has not reached you yet. `/gc sync` asks the guild again.

**Mats I just looted do not show for others.** Mats updates can take up to about 2 minutes. That is by design, to keep addon traffic low.

**My guild-mate plays on a German client.** That works once they run 0.15 or later. The addon's own text is English.

**Who sees my mats?** Nobody until you turn sharing on. Guild bank contents are shared by any member with the addon who opens the bank.

## Bugs and requests

Report them on GitHub: https://github.com/dofinator/GuildCrafters/issues
