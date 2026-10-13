local _, ns = ...

local Data = {}
ns.Data = Data

function Data:Init()
    local db = _G[ns.DB_NAME] or {}
    _G[ns.DB_NAME] = db
    db.schema = db.schema or ns.DB_SCHEMA
    db.settings = db.settings or {}
    db.settings.minimap = db.settings.minimap or {}
    if db.settings.shareMats == nil then db.settings.shareMats = false end
    if db.settings.tooltip == nil then db.settings.tooltip = true end   -- /gc tooltip on|off
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

-- Ny version af en datatype for en af ens egne chars. Versionen er mindst det aktuelle tidspunkt
-- (servertid): så er den også højere end alt, de andre har i cachen, når ens gemte data er væk
-- (geninstallation, ny pc, skift mellem testudgaven og den udgivne). Før startede tælleren forfra på
-- 1, og de andre, der havde fx version 57, hentede aldrig de nye data. For 0.14 er det bare et tal.
function Data.Bump(rec, kind)
    rec.v = rec.v or {}
    rec.v[kind] = math.max((rec.v[kind] or 0) + 1, ns.Compat.Now())
end

-- Kaldes, når noget i ens egne data ændrer sig, som andre skal se.
function Data:MeChanged(kind)
    local me = self:GetMe()
    Data.Bump(me, kind)
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
    self:RestoreDropped(me, scan.name)      -- vinduet er åbent, så man har professionen
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
-- hentes derfor fra Skills-fanen. Navnene er de faste engelske nøgler (Compat.ProfessionKey), uanset
-- klientens sprog.
local PROFESSIONS = {
    ["Alchemy"] = true, ["Blacksmithing"] = true, ["Enchanting"] = true, ["Engineering"] = true,
    ["Herbalism"] = true, ["Inscription"] = true, ["Jewelcrafting"] = true, ["Leatherworking"] = true,
    ["Mining"] = true, ["Skinning"] = true, ["Tailoring"] = true, ["Cooking"] = true, ["First Aid"] = true,
    ["Fishing"] = true,
}

-- Så længe beholdes data om noget, der er væk (en droppet profession, en char der har forladt guilden),
-- før de slettes lokalt. Imens er de skjult. Kommer det tilbage inden da, er intet tabt.
local KEEP = 7 * 86400
Data.KEEP = KEEP

-- Skills-listen er tom lige efter login. Først når den har haft tid til at blive indlæst, må en
-- profession, der mangler i den, regnes for droppet.
local skillsReady = false

-- En droppet profession flyttes fra me.profs til me.dropped (med tidsstempel): så er den straks ude af
-- alle visninger og payloads, men kan lægges tilbage, hvis den dukker op igen.
function Data:RestoreDropped(me, name)
    local prof = me.dropped and me.dropped[name]
    if not prof then return false end
    me.dropped[name] = nil
    if not next(me.dropped) then me.dropped = nil end
    prof.droppedAt = nil
    me.profs[name] = me.profs[name] or prof
    self:MeChanged("info")
    self:MeChanged("recipes")
    return true
end

-- Opdaterer rank for kendte professions ud fra Skills-fanen, uden at vinduet skal åbnes, tilføjer
-- professions, man har lært, men aldrig har åbnet, og opdager professions, man har droppet.
function Data:UpdateRanks()
    local me = self:GetMe()
    local ranks, complete = ns.Compat.GetSkillRanks()
    local now = ns.Compat.Now()
    local changed = false
    for name in pairs(ranks) do
        if not self:RestoreDropped(me, name) and PROFESSIONS[name] and not me.profs[name] then
            me.profs[name] = { items = {}, enchants = {} }
            changed = true
        end
    end
    local gone = {}
    for name, prof in pairs(me.profs) do
        local r = ranks[name]
        if r and (r.rank ~= prof.rank or r.max ~= prof.max) then
            prof.rank, prof.max = r.rank, r.max
            changed = true
        elseif not r and PROFESSIONS[name] and complete and skillsReady then
            table.insert(gone, name)
        end
    end
    for _, name in ipairs(gone) do
        me.dropped = me.dropped or {}
        me.dropped[name] = me.profs[name]
        me.dropped[name].droppedAt = now
        me.profs[name] = nil
        ns:Print(string.format("%s is no longer on this character: hidden from the guild now, "
            .. "and removed from your data in %d days.", name, KEEP / 86400))
    end
    for name, prof in pairs(me.dropped or {}) do
        if now - (prof.droppedAt or now) >= KEEP then me.dropped[name] = nil end
    end
    if me.dropped and not next(me.dropped) then me.dropped = nil end
    if changed or #gone > 0 then
        self:MeChanged("info")
    end
    if #gone > 0 then
        self:MeChanged("recipes")
    end
end

-- Professionsnøgler fra før 0.15 var navnet på klientens sprog ("Alchimie"). De lægges ind under den
-- faste engelske nøgle; findes begge, slås de sammen. Gælder egne chars (deres versioner bumpes, så de
-- andre henter dem igen) og cachen af andres (her huskes det oprindelige navn til relay, se BuildPayload).
local function RenameProfessions(profs, keepRaw)
    local renames = {}
    for name in pairs(profs or {}) do
        local key = ns.Compat.ProfessionKey(name)
        if key ~= name then renames[name] = key end
    end
    for name, key in pairs(renames) do
        local old, new = profs[name], profs[key]
        profs[name] = nil
        if new then
            for id in pairs(old.items or {}) do new.items = new.items or {} new.items[id] = true end
            for id in pairs(old.enchants or {}) do new.enchants = new.enchants or {} new.enchants[id] = true end
            new.rank, new.max = new.rank or old.rank, new.max or old.max
            new.scanned = new.scanned or old.scanned
        else
            profs[key] = old
        end
        if keepRaw then profs[key].raw = name end
    end
    return next(renames) ~= nil
end

function Data:MigrateProfessionKeys()
    for _, rec in pairs(ns.db.myChars) do
        if RenameProfessions(rec.profs, false) then
            Data.Bump(rec, "info")
            Data.Bump(rec, "recipes")
        end
    end
    for _, guild in pairs(ns.db.guilds) do
        for _, c in pairs(guild.chars or {}) do
            RenameProfessions(c.profs, true)
        end
    end
end

-- Crafting-professions, man har lært, men hvis vindue aldrig har været åbnet på denne char: så er der
-- ingen recipes at dele, og intet andet fortæller en det (fundet i UX-gennemgangen). Sorteret efter navn.
-- Mining er ikke med: Smelting-vinduet har sit eget navn, og de fleste miner uden at åbne det.
local SCANNABLE = {
    ["Alchemy"] = true, ["Blacksmithing"] = true, ["Enchanting"] = true, ["Engineering"] = true,
    ["Inscription"] = true, ["Jewelcrafting"] = true, ["Leatherworking"] = true, ["Tailoring"] = true,
    ["Cooking"] = true, ["First Aid"] = true,
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

-- Egne chars, der er i den aktuelle guild (den aktuelle char er altid med). En alt, der ikke længere
-- står i guild-rosteren, er ikke med.
function Data:MyGuildChars()
    local _, guildKey = self:GetGuild()
    local current = ns.Compat.PlayerKey()
    local result = {}
    for key, rec in pairs(ns.db.myChars) do
        if key == current or (guildKey and rec.guild == guildKey and not ns.Sync:IsGone(key)) then
            result[key] = rec
        end
    end
    return result
end

-- Oprydning (kun lokalt; der sendes intet): kaldes af Sync, når guild-rosteren er komplet.
-- isMember(key) siger, om en char står i den. Chars, der ikke gør, er allerede skjult (Sync:IsGone);
-- her får de et tidsstempel første gang, fraværet ses, og slettes KEEP sekunder senere. Det tælles fra
-- første observation og ikke fra "sidst set", så en lang pause ikke sletter nogen, der stadig er med.
-- Kommer char'en tilbage inden da, fjernes mærket. Egne alts slettes aldrig; de holder bare op med at
-- høre til guilden, indtil de logger ind i den igen.
function Data:SweepGone(isMember)
    local guild, guildKey = self:GetGuild()
    if not guild then return end
    local now, removed = ns.Compat.Now(), false
    for key, c in pairs(guild.chars) do
        if isMember(key) then
            c.gone = nil
        else
            c.gone = c.gone or now
            if now - c.gone >= KEEP then
                guild.chars[key] = nil
                removed = true
            end
        end
    end
    local current = ns.Compat.PlayerKey()
    for key, rec in pairs(ns.db.myChars) do
        if key ~= current and rec.guild == guildKey then
            if isMember(key) then
                rec.gone = nil
            else
                rec.gone = rec.gone or now
                if now - rec.gone >= KEEP then
                    rec.guild, rec.gone = nil, nil
                    removed = true
                end
            end
        end
    end
    if removed then ns:Fire("DATA_CHANGED") end
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
-- Andres data sendes videre (relay) under det navn, ejeren selv brugte (p.raw, fx "Alchimie" fra en
-- tysk 0.14-klient): en relay skal give det samme som ejeren i samme version.
function Data:BuildPayload(key, kind)
    local c, mine = self:GetChar(key)
    if not c then return end

    if kind == "info" then
        local profs = {}
        for name, p in pairs(c.profs or {}) do
            profs[p.raw or name] = { p.rank or 0, p.max or 0 }
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
            profs[p.raw or name] = { i = IdList(p.items), e = IdList(p.enchants) }
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
        -- Rank fra info; recipes på eksisterende professions bevares. Navne på andre sprog (fra en
        -- ikke-engelsk 0.14-klient) lægges under den faste nøgle, hvis vi kender dem.
        local profs = {}
        for name, p in pairs(d.profs) do
            local key = ns.Compat.ProfessionKey(name)
            local prof = profs[key] or c.profs[key] or { items = {}, enchants = {} }
            prof.rank, prof.max = p[1], p[2]
            prof.raw = key ~= name and name or nil
            profs[key] = prof
        end
        c.profs = profs
    elseif kind == "recipes" then
        local sent, raw = {}, {}
        for name, r in pairs(d.p) do
            local key = ns.Compat.ProfessionKey(name)
            sent[key] = r
            if key ~= name then raw[key] = name end
        end
        for key, prof in pairs(c.profs) do
            if not sent[key] then prof.items, prof.enchants = {}, {} end
        end
        for key, r in pairs(sent) do
            local prof = c.profs[key] or {}
            prof.items, prof.enchants = IdSet(r.i), IdSet(r.e)
            prof.raw = raw[key]
            c.profs[key] = prof
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
    Data:MigrateProfessionKeys()
    Data:UpdateRanks()
    -- Lidt efter login, så Skills-listen er indlæst, og linjen ikke drukner i login-beskederne.
    C_Timer.After(8, function()
        skillsReady = true
        Data:UpdateRanks()
        Data:HintUnscanned()
    end)
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
    -- Navnet kan skrives på engelsk eller på klientens sprog.
    local wanted = (ns.Compat.ProfessionKey(arg) or ""):lower()
    for name in pairs(me.dropped or {}) do
        if arg ~= "" and (name:lower() == arg:lower() or name:lower() == wanted) then
            me.dropped[name] = nil      -- allerede skjult for guilden; nu også væk herfra
            ns:Print(name .. " removed from your data.")
            return
        end
    end
    for name in pairs(me.profs) do
        if arg ~= "" and (name:lower() == arg:lower() or name:lower() == wanted) then
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
