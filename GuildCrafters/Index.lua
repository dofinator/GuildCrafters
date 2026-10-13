local _, ns = ...

-- Opslagstabeller bygget ud fra alle kendte chars (egne chars i guilden, guild-cachen og
-- test-data). Bruges af søgning, tooltip, craft-listen og Mats-fanen. Genbygges dovent efter ændringer.
local Index = {}
ns.Index = Index

local dirty = true
local built = false     -- er indekset bygget mindst én gang? (i kamp bruges det, selvom det er forældet)
local sorted = {}       -- ["i123"] = crafters sorteret med online først; ryddes, når nogen af dem går on/off
local onlineMemo = {}   -- [key] = online-status, som sorteringerne sidst så den
local crafters = {}     -- ["i123"] / ["e456"] = { key, ... }
local recipes = {}      -- { { kind = "i"|"e", id = 123 }, ... }
local holders = {}      -- [itemID] = { { key, bags, bank, time }, ... }
local guildBank = {}    -- [itemID] = antal
local people = {}       -- [key] = { rec = record, mine = bool, online = bool|nil }
local gbankTime

local function Add(map, id, value)
    local list = map[id]
    if not list then
        list = {}
        map[id] = list
    end
    table.insert(list, value)
end

local function CollectPeople()
    wipe(people)
    local guild = ns.Data:GetGuild()
    -- Chars, der har forladt guilden, skjules straks (og slettes senere, se Data:SweepGone).
    for key, rec in pairs(guild and guild.chars or {}) do
        if not ns.Sync:IsGone(key) then people[key] = { rec = rec } end
    end
    for key, rec in pairs(ns.Data:MyGuildChars()) do
        people[key] = { rec = rec, mine = true }
    end
    for _, fake in ipairs(ns.Debug and ns.Debug.fakes or {}) do
        if fake.hasAddon then
            people[fake.key] = { rec = fake, online = fake.online }
        end
    end
    return guild
end

local function Rebuild()
    wipe(crafters)
    wipe(sorted)
    wipe(onlineMemo)
    wipe(recipes)
    wipe(holders)
    wipe(guildBank)
    gbankTime = nil

    local guild = CollectPeople()
    for key, p in pairs(people) do
        -- Samme recipe kan stå under to professions; hver char må kun tælle med én gang.
        local seen = {}
        for _, prof in pairs(p.rec.profs or {}) do
            for id in pairs(prof.items or {}) do seen["i" .. id] = true end
            for id in pairs(prof.enchants or {}) do seen["e" .. id] = true end
        end
        for id in pairs(seen) do Add(crafters, id, key) end
        -- Egne mats ser man altid selv; andres kun hvis de deler dem.
        local m = p.rec.mats
        if m and (p.mine or p.rec.matsShared) then
            local merged = {}
            for id, n in pairs(m.bags or {}) do merged[id] = { bags = n, bank = 0 } end
            for id, n in pairs(m.bank or {}) do
                merged[id] = merged[id] or { bags = 0, bank = 0 }
                merged[id].bank = n
            end
            for id, counts in pairs(merged) do
                Add(holders, id, { key = key, bags = counts.bags, bank = counts.bank, time = m.time,
                    mine = p.mine })
            end
        end
    end

    for id in pairs(crafters) do
        table.insert(recipes, { kind = id:sub(1, 1), id = tonumber(id:sub(2)) })
    end

    if guild and guild.guildBank then
        gbankTime = guild.guildBank.s
        for _, counts in pairs(guild.guildBank.tabs or {}) do
            for id, n in pairs(counts) do
                guildBank[id] = (guildBank[id] or 0) + n
            end
        end
    end
    dirty = false
    built = true
end

-- En genopbygning koster ca. 40 ms med 200 addon-brugere (målt i tools/sim/loadtest.py). I kamp
-- bruges det indeks, vi har, selvom det er forældet; det bygges igen ved første opslag efter kampen.
local function Ensure()
    if dirty and not (built and ns.Compat.InCombat()) then Rebuild() end
end

function Index:MarkDirty()
    dirty = true
end

------------------------------------------------------------------------
-- Personer
------------------------------------------------------------------------

function Index:IsOnline(key)
    if key == ns.Compat.PlayerKey() then return true end
    local p = people[key]
    if p and p.online ~= nil then return p.online end
    return ns.Sync:IsOnline(key)
end

function Index:Person(key)
    Ensure()
    return people[key] and people[key].rec
end

-- "Bobcraft (alt of Bob)" eller bare "Bob".
function Index:DisplayName(key)
    local short = ns.Compat.ShortName(key)
    local rec = self:Person(key)
    if rec and rec.main and rec.main ~= key then
        return short .. " (alt of " .. ns.Compat.ShortName(rec.main) .. ")"
    end
    return short
end

-- Online-status til sortering. Slås op én gang pr. person og huskes, til rosteren viser noget andet:
-- sorteringen af crafters var det dyreste i belastningstesten (over 600.000 opslag pr. opdatering).
local function Online(key)
    local value = onlineMemo[key]
    if value == nil then
        value = Index:IsOnline(key) and true or false
        onlineMemo[key] = value
    end
    return value
end

local function OnlineFirst(a, b)
    local oa, ob = Online(a), Online(b)
    if oa ~= ob then return oa end
    return a < b
end

local function SortKeys(keys)
    local list = {}
    for _, key in ipairs(keys or {}) do table.insert(list, key) end
    table.sort(list, OnlineFirst)
    return list
end

-- Alle med addonen, der kan crafte noget, online først og derefter efter navn: { { key, count }, ... }
function Index:CrafterList()
    Ensure()
    local counts = {}
    for _, keys in pairs(crafters) do
        for _, key in ipairs(keys) do counts[key] = (counts[key] or 0) + 1 end
    end
    local list = {}
    for key, n in pairs(counts) do table.insert(list, { key = key, count = n }) end
    table.sort(list, function(a, b) return OnlineFirst(a.key, b.key) end)
    return list
end

------------------------------------------------------------------------
-- Recipes, crafters og reagents
------------------------------------------------------------------------

-- Crafters af et item ("i") eller enchant ("e"), online først. Listen genbruges, indtil rosteren
-- eller data ændrer sig, så den må ikke ændres af den, der får den.
function Index:Crafters(kind, id)
    Ensure()
    local key = kind .. id
    local list = sorted[key]
    if not list then
        list = SortKeys(crafters[key])
        sorted[key] = list
    end
    return list
end

function Index:Recipes()
    Ensure()
    return recipes
end

-- En persons professions, der har recipes: { { name, rank, max, recipes = { ["i123"] = true } }, ... }
-- (usorteret; Crafting-fanen bestemmer rækkefølgen).
function Index:Professions(key)
    local rec = self:Person(key)
    local list = {}
    for name, prof in pairs(rec and rec.profs or {}) do
        local set, n = {}, 0
        for id in pairs(prof.items or {}) do set["i" .. id] = true n = n + 1 end
        for id in pairs(prof.enchants or {}) do set["e" .. id] = true n = n + 1 end
        if n > 0 then
            table.insert(list, { name = name, rank = prof.rank, max = prof.max, recipes = set })
        end
    end
    return list
end

function Index:CanCraft(key, kind, id)
    Ensure()
    for _, k in ipairs(crafters[kind .. id] or {}) do
        if k == key then return true end
    end
    return false
end

-- Reagents til én craft: made (antal der laves), { { id, count }, ... }. nil hvis ukendt.
function Index:Reagents(kind, id)
    local key = kind .. id
    local entry = ns.db.reagents[key] or (ns.Debug and ns.Debug.fakeReagents[key])
    if not entry then return nil end
    local list = {}
    for i = 1, #entry.r, 2 do
        table.insert(list, { id = entry.r[i], count = entry.r[i + 1] })
    end
    return entry.made or 1, list
end

------------------------------------------------------------------------
-- Mats
------------------------------------------------------------------------

-- Hvem har et mat: liste af { key, bags, bank, time, mine }, flest først.
function Index:Holders(itemID)
    Ensure()
    local list = {}
    for _, h in ipairs(holders[itemID] or {}) do table.insert(list, h) end
    table.sort(list, function(a, b) return a.bags + a.bank > b.bags + b.bank end)
    return list
end

function Index:GuildBankCount(itemID)
    Ensure()
    return guildBank[itemID] or 0, gbankTime
end

-- Hvor mange har man selv: aktuel char (live) + egne alts i guilden (fra seneste scan).
function Index:OwnCount(itemID)
    local total = ns.Compat.ItemCount(itemID)
    local me = ns.Compat.PlayerKey()
    for key, rec in pairs(ns.Data:MyGuildChars()) do
        if key ~= me and rec.mats then
            total = total + ((rec.mats.bags or {})[itemID] or 0) + ((rec.mats.bank or {})[itemID] or 0)
        end
    end
    return total
end

-- Alle mats, som nogen har (inkl. guild bank).
function Index:AllMats()
    Ensure()
    local ids, seen = {}, {}
    for id in pairs(holders) do
        seen[id] = true
        table.insert(ids, id)
    end
    for id in pairs(guildBank) do
        if not seen[id] then table.insert(ids, id) end
    end
    return ids
end

------------------------------------------------------------------------
-- Navne, ikoner og links for recipes ("i" = item, "e" = enchant)
------------------------------------------------------------------------

function Index.Name(kind, id)
    if kind == "e" then return ns.Compat.SpellName(id) end
    return ns.Compat.ItemName(id)
end

function Index.Icon(kind, id)
    if kind == "e" then return ns.Compat.SpellIcon(id) end
    return ns.Compat.ItemIcon(id)
end

function Index.Link(kind, id)
    if kind == "e" then return ns.Compat.SpellLink(id) end
    return ns.Compat.ItemLink(id)
end

function Index.Hyperlink(kind, id)
    return (kind == "e" and "enchant:" or "item:") .. id
end

------------------------------------------------------------------------
-- Kategorier (som i auktionshuset)
------------------------------------------------------------------------

local CONSUMABLE_SUBS = { [1] = "Potions", [2] = "Elixirs", [3] = "Flasks", [4] = "Scrolls",
    [5] = "Food & Drink", [6] = "Item Enhancements", [7] = "Bandages" }
local ARMOR_SUBS = { [0] = "Jewelry & Misc", [1] = "Cloth", [2] = "Leather", [3] = "Mail",
    [4] = "Plate", [6] = "Shields" }

Index.TOP_ORDER = { "Consumables", "Armor", "Weapons", "Enchants", "Gems", "Bags", "Trade Goods",
    "Ammo", "Other" }

-- Kategori og underkategori for en recipe, eller nil hvis itemet ikke er indlæst endnu.
function Index.Category(kind, id)
    if kind == "e" then
        local name = ns.Compat.SpellName(id)
        if not name then return nil end
        local slot = name:match("^Enchant (.-) %- ") or name:match("^Enchant (.+)$")
        return "Enchants", slot or "Other"
    end
    local d = ns.Compat.ItemDetails(id)
    if not d then return nil end
    local c = d.classID
    if c == 0 then return "Consumables", CONSUMABLE_SUBS[d.subclassID] or "Other" end
    if c == 4 then
        if d.equipLoc == "INVTYPE_CLOAK" then return "Armor", "Cloaks" end
        return "Armor", ARMOR_SUBS[d.subclassID] or d.subType or "Other"
    end
    if c == 2 then return "Weapons", d.subType or "Other" end
    if c == 1 then return "Bags", d.subType or "Bags" end
    if c == 3 then return "Gems", d.subType or "Other" end
    if c == 7 then return "Trade Goods", d.subType or "Other" end
    if c == 6 then return "Ammo", d.subType or "Other" end
    return "Other", d.itemType or "Other"
end

-- Træ til venstre side: { { name, count, subs = { { name, count }, ... } }, ... } + antal ikke indlæste.
function Index:CategoryTree()
    local tops, unresolved = {}, 0
    for _, r in ipairs(self:Recipes()) do
        local top, sub = Index.Category(r.kind, r.id)
        if top then
            tops[top] = tops[top] or { name = top, count = 0, subs = {} }
            tops[top].count = tops[top].count + 1
            tops[top].subs[sub] = (tops[top].subs[sub] or 0) + 1
        else
            unresolved = unresolved + 1
        end
    end
    local tree = {}
    for _, name in ipairs(Index.TOP_ORDER) do
        local t = tops[name]
        if t then
            local subs = {}
            for subName, n in pairs(t.subs) do table.insert(subs, { name = subName, count = n }) end
            table.sort(subs, function(a, b) return a.name < b.name end)
            table.insert(tree, { name = name, count = t.count, subs = subs })
        end
    end
    return tree, unresolved
end

------------------------------------------------------------------------
-- Søgning i navn + tooltip-tekst (stats, effekter, slot, type)
------------------------------------------------------------------------

local searchText = {}   -- [key] = tekst med små bogstaver

function Index:SearchText(kind, id)
    local key = kind .. id
    if searchText[key] then return searchText[key] end
    local name = Index.Name(kind, id)
    if not name or (kind == "i" and not ns.Compat.ItemDetails(id)) then return nil end
    local text = ns.Compat.TooltipText(Index.Hyperlink(kind, id))
    if not text then return name:lower() end   -- prøv tooltip igen næste gang
    searchText[key] = (name .. "\n" .. text):lower()
    return searchText[key]
end

local function Words(query)
    local words = {}
    for word in query:lower():gmatch("%S+") do table.insert(words, word) end
    return words
end

-- filter = { top, sub, crafter, query, onlineOnly }. Returnerer resultater + antal ikke indlæste.
-- Resultat: { kind, id, name, details, keys }
function Index:Find(filter)
    local words = Words(filter.query or "")
    local results, unresolved = {}, 0
    for _, r in ipairs(self:Recipes()) do
        local ok = true
        if filter.crafter then
            ok = self:CanCraft(filter.crafter, r.kind, r.id)
        elseif filter.top then
            local top, sub = Index.Category(r.kind, r.id)
            ok = top == filter.top and (not filter.sub or sub == filter.sub)
        end
        local keys
        if ok and filter.onlineOnly then
            keys = self:Crafters(r.kind, r.id)
            ok = false
            for _, key in ipairs(keys) do
                if self:IsOnline(key) and key ~= ns.Compat.PlayerKey() then ok = true end
            end
        end
        if ok and #words > 0 then
            local text = self:SearchText(r.kind, r.id)
            if not text then
                ok = false
                unresolved = unresolved + 1
            else
                for _, word in ipairs(words) do
                    if not text:find(word, 1, true) then ok = false break end
                end
            end
        end
        if ok then
            local name = Index.Name(r.kind, r.id)
            if name then
                table.insert(results, {
                    kind = r.kind, id = r.id, name = name, keys = keys or self:Crafters(r.kind, r.id),
                    details = r.kind == "i" and ns.Compat.ItemDetails(r.id) or nil,
                })
            else
                unresolved = unresolved + 1
            end
        end
    end
    table.sort(results, function(a, b) return a.name < b.name end)
    return results, unresolved
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local function Changed()
    dirty = true
    ns:Fire("INDEX_CHANGED")
end

ns:On("DATA_CHANGED", Changed)
ns:On("ME_CHANGED", Changed)
-- Rosteren ændrer sig hele tiden i en stor guild (hvert login og logout), og før blev hele indekset
-- bygget igen ved næste tooltip. Indekset afhænger ikke af, hvem der er online; kun rækkefølgen af
-- crafters gør. Sync kalder MarkDirty, når nogen forlader guilden eller kommer tilbage.
ns:On("ROSTER_CHANGED", function()
    for key, was in pairs(onlineMemo) do
        if (Index:IsOnline(key) and true or false) ~= was then
            wipe(sorted)
            wipe(onlineMemo)
            return
        end
    end
end)

-- Item-navne kommer asynkront fra serveren; opdatér visningen, når de er klar.
local namesPending = false
ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
    if namesPending then return end
    namesPending = true
    C_Timer.After(0.5, function()
        namesPending = false
        ns:Fire("ITEM_NAMES")
    end)
end)
