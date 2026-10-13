# GuildCrafters 0.15.0

A stability release. There is nothing to set up, and it works together with guild members who are still on 0.14.

## New

- **Works on every game language.** Professions now show correctly, with icon and rank, between players on different client languages, for example German and English.
- **No sync during combat.** GuildCrafters stays quiet while you fight and catches up a few seconds after. The open window is not refreshed in the middle of a fight either.
- **Old data cleans itself up.** Members who left the guild disappear from Crafting, Mats and the tooltips right away, and are removed from your saved data after 7 days. A profession you dropped is hidden from the guild right away and removed after 7 days. If the member or the profession comes back within that week, nothing is lost.
- **`/gc sync`** asks the guild for fresh data now, instead of waiting for the next automatic update.
- **Status line** at the bottom right of the window: when you last received data, and how many guild members with the addon are online. Hover it for details.
- **`/gc tooltip on|off`** turns the "Crafted by" and "Guild has" lines on item tooltips off or on. Inside the GuildCrafters window they are always shown.

## Improved

- Lighter in large guilds: the Crafting tab opens and searches with far less work when many members use the addon, and guild roster updates no longer cause extra work.
- After a reinstall or a move to a new PC, your next change always reaches the guild. Before, others could keep showing your old data.

## Fixed

- `/gc help` showed "tankealer|dps|uto" instead of "tank|healer|dps|auto".
- Craft List: the crafter on an item row is shown by short name, and one of your own characters is preferred.

## Good to know

- The footer texts in Craft List and Mats are shorter, to make room for the status line.
- Cleanup only happens on your own computer. Guild members on 0.14 keep seeing departed members until they update.
