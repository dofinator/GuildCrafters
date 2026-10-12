local _, ns = ...

local Data = {}
ns.Data = Data

function Data:Init()
    local db = GuildCraftersDB or {}
    GuildCraftersDB = db
    db.schema = db.schema or ns.DB_SCHEMA
    db.settings = db.settings or {}
    db.settings.minimap = db.settings.minimap or {}
    if db.settings.shareMats == nil then db.settings.shareMats = false end
    db.settings.filters = db.settings.filters or {}   -- fanernes flueben og sortering (se UI.Saved)
    db.settings.profHint = db.settings.profHint or {}  -- ["Char-Realm/Alchemy"] = true: hint vist i chatten
    db.myChars = db.myChars or {}
    db.mains = db.mains or {}       -- [realm] = valgt main-nøgle
    db.guilds = db.guilds or {}
    db.reagents = db.reagents or {}  -- ["i123"/"e456"] = { made = n, r = { id, antal, ... } } (spildata)
    db.craftList = db.craftList or {} -- { { kind = "i"|"e", id = 123, qty = 1 }, ... }
    ns.db = db
end

------------------------------------------------------------------------
-- Egne chars
------------------------------------------------------------------------

-- Egen chars data. Oprettes ved første kald (efter PLAYER_LOGIN, hvor realm-navnet er kendt).
function Data:GetMe()
    local key = ns.Compat.PlayerKey()
    local me = ns.db.myChars[key]
    if not me then
        me = { profs = {}, v = { info = 0, recipes = 0, mats = 0 } }
        ns.db.myChars[key] = me
    end
    return me, key
end

-- Kaldes, når noget i ens egne data ændrer sig, som andre skal se.
function Data:MeChanged(kind)
    local me = self:GetMe()
    me.v[kind] = me.v[kind] + 1
    ns:Fire("ME_CHANGED", kind)
end

function Data:RefreshBasics()
    local me = self:GetMe()
    local _, class = UnitClass("player")
    local level = UnitLevel("player")
    if me.class ~= class or me.level ~= level then
        me.class, me.level = class, level
        self:MeChanged("info")
    end
end

local function RealmOf(key)
    return key:match("%-(.+)$")
end

-- Main for egne chars på denne realm: manuelt valgt, ellers den med højest level.
function Data:GetMyMain()
    local realm = ns.Compat.RealmName()
    local chosen = ns.db.mains[realm]
    if chosen and ns.db.myChars[chosen] then return chosen end

    local best, bestLevel
    for key, c in pairs(ns.db.myChars) do
        if RealmOf(key) == realm then
            local level = c.level or 0
            if not best or level > bestLevel or (level == bestLevel and key < best) then
                best, bestLevel = key, level
            end
        end
    end
    return best
end

-- Returnerer true, hvis navnet passede på en af ens egne chars.
function Data:SetMyMain(name)
    local realm = ns.Compat.RealmName()
    if name == "" then
        ns.db.mains[realm] = nil
        self:MeChanged("info")
        return true
    end
    local key = ns.Compat.FullName(name)
    for myKey in pairs(ns.db.myChars) do
        if myKey:lower() == key:lower() then
            ns.db.mains[realm] = myKey
            self:MeChanged("info")
            return true
        end
    end
    return false
end

local function AddNew(target, source)
    local added = 0
    for id in pairs(source) do
        if not target[id] then
            target[id] = true
            added = added + 1
        end
    end
    return added
end

-- Merger et scan additivt: et filtreret eller delvist lukket vindue må aldrig fjerne recipes,
-- og recipes kan ikke aflæres i Classic. Returnerer antal nye recipes.
function Data:MergeProfession(scan)
    local me = self:GetMe()
    local prof = me.profs[scan.name]
    local isNew = not prof
    if isNew then
        prof = { items = {}, enchants = {} }
        me.profs[scan.name] = prof
    end

    if isNew or prof.rank ~= scan.rank or prof.max ~= scan.max then
        prof.rank, prof.max = scan.rank, scan.max
        self:MeChanged("info")
    end

    local added = AddNew(prof.items, scan.items) + AddNew(prof.enchants, scan.enchants)
    -- Nye reagents (fx første scan efter en opdatering) skal også ud til guilden.
    local newReagents = self:MergeReagents(scan.reagents)
    if added > 0 or newReagents > 0 then
        self:MeChanged("recipes")
    end
    prof.scanned = time()
    return added
end

-- Professions uden eget vindue (Skinning, Herbalism, Fishing, og Mining før man åbner Smelting) bliver
-- aldrig scannet, så de blev ikke vist for rigtige spillere (fundet i første test med en ven). De
-- hentes derfor fra Skills-fanen. Navnene er engelske, som resten af addonen (enUS-klient).
local PROFESSIONS = {
    ["Alchemy"] = true, ["Blacksmithing"] = true, ["Enchanting"] = true, ["Engineering"] = true,
    ["Herbalism"] = true, ["Jewelcrafting"] = true, ["Leatherworking"] = true, ["Mining"] = true,
    ["Skinning"] = true, ["Tailoring"] = true, ["Cooking"] = true, ["First Aid"] = true, ["Fishing"] = true,
}

-- Opdaterer rank for kendte professions ud fra Skills-fanen, uden at vinduet skal åbnes, og tilføjer
-- professions, man har lært, men aldrig har åbnet.
function Data:UpdateRanks()
    local me = self:GetMe()
    local ranks = ns.Compat.GetSkillRanks()
    local changed = false
    for name, r in pairs(ranks) do
        if PROFESSIONS[name] and not me.profs[name] then
            me.profs[name] = { items = {}, enchants = {} }
            changed = true
        end
    end
    for name, prof in pairs(me.profs) do
        local r = ranks[name]
        if r and (r.rank ~= prof.rank or r.max ~= prof.max) then
            prof.rank, prof.max = r.rank, r.max
            changed = true
        end
    end
    if changed then
        self:MeChanged("info")
    end
end

-- Crafting-professions, man har lært, men hvis vindue aldrig har været åbnet på denne char: så er der
-- ingen recipes at dele, og intet andet fortæller en det (fundet i UX-gennemgangen). Sorteret efter navn.
-- Mining er ikke med: Smelting-vinduet har sit eget navn, og de fleste miner uden at åbne det.
local SCANNABLE = {
    ["Alchemy"] = true, ["Blacksmithing"] = true, ["Enchanting"] = true, ["Engineering"] = true,
    ["Jewelcrafting"] = true, ["Leatherworking"] = true, ["Tailoring"] = true, ["Cooking"] = true,
    ["First Aid"] = true,
}

function Data:UnscannedProfessions()
    local me = self:GetMe()
    local names = {}
    for name in pairs(ns.Compat.GetSkillRanks()) do
        local prof = me.profs[name]
        if SCANNABLE[name] and not (prof and (prof.scanned or next(prof.items or {}) or next(prof.enchants or {}))) then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

-- "Alchemy", "Alchemy and Enchanting", "Alchemy, Cooking and Enchanting".
function Data.JoinNames(names)
    if #names <= 1 then return names[1] or "" end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

-- Én linje i chatten pr. profession pr. char; derefter står hintet kun øverst i Crafting-fanen.
function Data:HintUnscanned()
    local _, key = self:GetMe()
    local fresh = {}
    for _, name in ipairs(self:UnscannedProfessions()) do
        local id = key .. "/" .. name
        if not ns.db.settings.profHint[id] then
            ns.db.settings.profHint[id] = true
            table.insert(fresh, name)
        end
    end
    if #fresh > 0 then
        ns:Print(string.format("Open %s once, so the guild can see your recipes.", Data.JoinNames(fresh)))
    end
end

------------------------------------------------------------------------
-- Andre guildmedlemmer (cache) og fælles adgang til alle chars
------------------------------------------------------------------------

function Data:GetGuild()
    local guildKey = ns.Compat.GuildKey()
    if not guildKey then return end
    local guild = ns.db.guilds[guildKey]
    if not guild then
        guild = { chars = {} }
        ns.db.guilds[guildKey] = guild
    end
    return guild, guildKey
end

-- Data om en char: egne chars fra myChars (mine = true), andre fra guild-cachen.
function Data:GetChar(key)
    local mine = ns.db.myChars[key]
    if mine then return mine, true end
    local guild = self:GetGuild()
    return guild and guild.chars[key], false
end

function Data:IsMine(key)
    return ns.db.myChars[key] ~= nil
end

-- Egne chars, der er i den aktuelle guild (den aktuelle char er altid med).
function Data:MyGuildChars()
    local _, guildKey = self:GetGuild()
    local current = ns.Compat.PlayerKey()
    local result = {}
    for key, rec in pairs(ns.db.myChars) do
        if key == current or (guildKey and rec.guild == guildKey) then
            result[key] = rec
        end
    end
    return result
end

local function SameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- Reagents er spildata og ens for alle, så de ligger i én fælles tabel. Returnerer antal nye/ændrede.
function Data:MergeReagents(reagents)
    local changed = 0
    for key, entry in pairs(reagents or {}) do
        local old = ns.db.reagents[key]
        if not old or old.made ~= entry.made or not SameList(old.r, entry.r) then
            ns.db.reagents[key] = { made = entry.made, r = entry.r }
            changed = changed + 1
        end
    end
    return changed
end

local function SharesMats()
    return ns.db.settings.shareMats and true or false
end

-- Den version af en datatype ("info", "recipes", "mats"), vi kan levere for en char.
function Data:HeldVersion(key, kind)
    local c, mine = self:GetChar(key)
    if not c then return 0 end
    if mine then
        if kind == "mats" and not SharesMats() then return 0 end
        return c.v and c.v[kind] or 0
    end
    return c.dataV and c.dataV[kind] or 0
end

local function IdList(set)
    local list = {}
    for id in pairs(set or {}) do table.insert(list, id) end
    return list
end

local function IdSet(list)
    local set = {}
    for _, id in ipairs(list or {}) do set[id] = true end
    return set
end

-- Bygger den payload, der sendes i DATA (og for "info" også i HELLO).
function Data:BuildPayload(key, kind)
    local c, mine = self:GetChar(key)
    if not c then return end

    if kind == "info" then
        local profs = {}
        for name, p in pairs(c.profs or {}) do
            profs[name] = { p.rank or 0, p.max or 0 }
        end
        return {
            class = c.class,
            level = c.level,
            spec = c.specTab,
            role = mine and (c.roleOverride or c.role) or c.role,
            main = mine and self:GetMyMain() or c.main,
            profs = profs,
            av = mine and ns.VERSION or c.addonVer,
            ms = mine and SharesMats() or (c.matsShared and true or false),
        }
    elseif kind == "recipes" then
        -- p: professions med item- og enchant-ID'er. g: reagents som { made, id, antal, id, antal, ... }.
        local profs, reagents = {}, {}
        for name, p in pairs(c.profs or {}) do
            profs[name] = { i = IdList(p.items), e = IdList(p.enchants) }
            for id in pairs(p.items or {}) do reagents["i" .. id] = ns.db.reagents["i" .. id] end
            for id in pairs(p.enchants or {}) do reagents["e" .. id] = ns.db.reagents["e" .. id] end
        end
        local g = {}
        for key, entry in pairs(reagents) do
            local list = { entry.made }
            for _, v in ipairs(entry.r) do table.insert(list, v) end
            g[key] = list
        end
        return { p = profs, g = g }
    elseif kind == "mats" then
        if mine and not SharesMats() then return end
        local m = c.mats
        if not m then return end
        return { b = m.bags or {}, k = m.bank or {}, t = m.time }
    end
end

-- Gemmer modtagne data om en anden char. Egne chars ignoreres altid (vi er selv kilden).
function Data:ApplyPayload(key, kind, version, d)
    if self:IsMine(key) then return end
    local guild = self:GetGuild()
    if not guild then return end

    local c = guild.chars[key]
    if not c then
        c = { profs = {}, v = {}, dataV = {} }
        guild.chars[key] = c
    end
    c.v = c.v or {}
    c.dataV = c.dataV or {}
    c.profs = c.profs or {}

    if kind == "info" then
        c.class, c.level, c.specTab, c.role = d.class, d.level, d.spec, d.role
        c.main, c.addonVer = d.main, d.av
        c.matsShared = d.ms and true or false
        if not c.matsShared then
            c.mats = nil
            c.dataV.mats = 0
        end
        -- Rank fra info; recipes på eksisterende professions bevares.
        local profs = {}
        for name, p in pairs(d.profs) do
            local prof = c.profs[name] or { items = {}, enchants = {} }
            prof.rank, prof.max = p[1], p[2]
            profs[name] = prof
        end
        c.profs = profs
    elseif kind == "recipes" then
        for name, prof in pairs(c.profs) do
            if not d.p[name] then prof.items, prof.enchants = {}, {} end
        end
        for name, r in pairs(d.p) do
            local prof = c.profs[name] or {}
            prof.items, prof.enchants = IdSet(r.i), IdSet(r.e)
            c.profs[name] = prof
        end
        local reagents = {}
        for key, list in pairs(d.g or {}) do
            local r = {}
            for i = 2, #list do r[i - 1] = list[i] end
            reagents[key] = { made = list[1], r = r }
        end
        self:MergeReagents(reagents)
    elseif kind == "mats" then
        c.mats = { bags = d.b or {}, bank = d.k or {}, time = d.t }
    end

    c.dataV[kind] = version
    if (c.v[kind] or 0) < version then c.v[kind] = version end
    ns:Fire("DATA_CHANGED", key, kind)
end

-- Guild bank: { s = scanTime, tabs = { [tab] = { [itemID] = antal } } }
function Data:GuildBankTime()
    local guild = self:GetGuild()
    return guild and guild.guildBank and guild.guildBank.s or 0
end

function Data:ApplyGuildBank(scanTime, tabs)
    local guild = self:GetGuild()
    if not guild or scanTime <= self:GuildBankTime() then return false end
    guild.guildBank = { s = scanTime, tabs = tabs }
    ns:Fire("DATA_CHANGED", nil, "gbank")
    return true
end

------------------------------------------------------------------------
-- Personlig craft-liste
------------------------------------------------------------------------

function Data:CraftListFind(kind, id)
    for i, entry in ipairs(ns.db.craftList) do
        if entry.kind == kind and entry.id == id then return entry, i end
    end
end

function Data:CraftListAdd(kind, id, qty)
    local entry = self:CraftListFind(kind, id)
    if entry then
        entry.qty = entry.qty + (qty or 1)
    else
        table.insert(ns.db.craftList, { kind = kind, id = id, qty = qty or 1 })
    end
    ns:Fire("CRAFTLIST_CHANGED")
end

function Data:CraftListSetQty(kind, id, qty)
    local entry, index = self:CraftListFind(kind, id)
    if not entry then return end
    if qty <= 0 then
        table.remove(ns.db.craftList, index)
    else
        entry.qty = qty
    end
    ns:Fire("CRAFTLIST_CHANGED")
end

function Data:CraftListClear()
    wipe(ns.db.craftList)
    ns:Fire("CRAFTLIST_CHANGED")
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

-- SKILL_LINES_CHANGED kan komme før PLAYER_LOGIN, hvor char-nøglen endnu ikke er sikker.
ns:On("LOGIN", function()
    Data:RefreshBasics()
    Data:UpdateRanks()
    -- Lidt efter login, så Skills-listen er indlæst, og linjen ikke drukner i login-beskederne.
    C_Timer.After(8, function() Data:HintUnscanned() end)
end)
ns:RegisterEvent("SKILL_LINES_CHANGED", function()
    if ns.loggedIn then Data:UpdateRanks() end
end)
ns:RegisterEvent("PLAYER_LEVEL_UP", function()
    -- UnitLevel er ikke altid opdateret, når eventet kommer.
    C_Timer.After(1, function() Data:RefreshBasics() end)
end)

ns:RegisterCommand("forget", function(arg)
    local me = Data:GetMe()
    for name in pairs(me.profs) do
        if arg ~= "" and name:lower() == arg:lower() then
            me.profs[name] = nil
            Data:MeChanged("info")
            Data:MeChanged("recipes")
            ns:Print(name .. " removed from your data.")
            return
        end
    end
    ns:Print("Usage: /gc forget <profession> (e.g. if you dropped it)")
end, "/gc forget <profession> - remove a profession you dropped")

ns:RegisterCommand("main", function(arg)
    if arg:lower() == "auto" then
        Data:SetMyMain("")
    elseif arg ~= "" and not Data:SetMyMain(arg) then
        ns:Print(arg .. " is not one of your characters (log in on it with the addon first).")
        return
    end
    local manual = ns.db.mains[ns.Compat.RealmName()] ~= nil
    ns:Print("Main: " .. tostring(Data:GetMyMain()) .. (manual and " (chosen)" or " (auto: highest level)"))
end, "/gc main [name|auto] - show or choose which of your characters is your main")
