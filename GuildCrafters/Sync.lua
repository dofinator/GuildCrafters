local _, ns = ...

-- Protokol (se SPEC.md afsnit 5):
--   HELLO  ens egen info + versioner. q = "svar venligst" (sendes ved login).
--   INVR   liste over offline chars og de versioner, afsenderen har i cache (svar på HELLO med q).
--   REQ    "send mig <kind> for <char>, jeg har version h".
--   DATA   <kind> for <char> i version v. Ejeren svarer hurtigt, andre (relay) kun hvis ejeren er offline.
--   GBANK  guild bankens indhold med scan-tidspunkt; nyeste vinder.
-- Alt går over GUILD, så alle lytter med og opdaterer deres cache gratis.
local Sync = {}
ns.Sync = Sync

local KINDS = { "info", "recipes", "mats" }
local MIN_INTERVAL = 10      -- sekunder mellem to HELLO fra os
local REQ_TIMEOUT = 30       -- sekunder før en ubesvaret REQ må sendes igen
local MAX_REQ_TRIES = 4      -- så mange gange spørger vi igen, hvis svaret ikke når frem
local HEARTBEAT = 600        -- sekunder mellem HELLO uden ændringer (retter tabte beskeder)
local MAX_IDS = 2000         -- øvre grænse for lister i modtagne beskeder

local lastSent = -MIN_INTERVAL
local pending = false
local pendingQuery = false
local started = false
local warnedVersion = false

local online = {}            -- [key] = true for online guildmedlemmer
local reqSeen = {}           -- [key|kind] = GetTime() for sendt/set REQ
local wanted = {}            -- [key|kind] = { v = version vi mangler, tries = antal genforsøg }
local dataPlanned = {}       -- [key|kind] = { v = version, cancelled = bool }
local invPlanned             -- { seen = { liste af modtagne INVR-lister } }
local gbankPlanned           -- { cancelled = bool }

local function Rand(a, b) return a + math.random() * (b - a) end

------------------------------------------------------------------------
-- Online-status
------------------------------------------------------------------------

local function RefreshOnline()
    wipe(online)
    for _, m in ipairs(ns.Compat.GetGuildMembers()) do
        if m.online then online[m.key] = true end
    end
    online[ns.Compat.PlayerKey()] = true
end

function Sync:IsOnline(key)
    return online[key] or false
end

------------------------------------------------------------------------
-- Validering af modtagne data
------------------------------------------------------------------------

local function IsNumberList(t)
    if type(t) ~= "table" or #t > MAX_IDS then return false end
    for _, v in ipairs(t) do
        if type(v) ~= "number" then return false end
    end
    return true
end

local function IsCountMap(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for k, v in pairs(t) do
        n = n + 1
        if type(k) ~= "number" or type(v) ~= "number" or n > MAX_IDS then return false end
    end
    return true
end

local VALIDATORS = {
    info = function(d)
        if type(d.class) ~= "string" or type(d.level) ~= "number" or type(d.profs) ~= "table" then
            return false
        end
        if d.spec ~= nil and type(d.spec) ~= "number" then return false end
        if d.role ~= nil and not ns.Roles.VALID[d.role] then return false end
        if d.main ~= nil and type(d.main) ~= "string" then return false end
        for name, p in pairs(d.profs) do
            if type(name) ~= "string" or type(p) ~= "table"
                or type(p[1]) ~= "number" or type(p[2]) ~= "number" then
                return false
            end
        end
        return true
    end,
    recipes = function(d)
        if type(d.p) ~= "table" then return false end
        for name, r in pairs(d.p) do
            if type(name) ~= "string" or type(r) ~= "table" then return false end
            if not IsNumberList(r.i or {}) or not IsNumberList(r.e or {}) then return false end
        end
        if d.g ~= nil and type(d.g) ~= "table" then return false end
        local n = 0
        for key, list in pairs(d.g or {}) do
            n = n + 1
            -- { made, id, antal, id, antal, ... }: ulige længde, højst 20 reagents.
            if n > MAX_IDS or type(key) ~= "string" or not key:match("^[ie]%d+$")
                or not IsNumberList(list) or #list < 3 or #list % 2 ~= 1 or #list > 41 then
                return false
            end
        end
        return true
    end,
    mats = function(d)
        return IsCountMap(d.b or {}) and IsCountMap(d.k or {})
            and (d.t == nil or type(d.t) == "number")
    end,
}

local function Valid(kind, d)
    local fn = VALIDATORS[kind]
    return fn ~= nil and type(d) == "table" and fn(d)
end

local function ValidKey(key)
    return type(key) == "string" and key:match("^[^%-]+%-.+$") ~= nil
end

------------------------------------------------------------------------
-- HELLO
------------------------------------------------------------------------

local function BuildHello(query)
    local me, key = ns.Data:GetMe()
    local msg = ns.Data:BuildPayload(key, "info")
    msg.t = "HELLO"
    msg.q = query or nil
    msg.v = {
        info = me.v.info,
        recipes = me.v.recipes,
        mats = ns.db.settings.shareMats and me.v.mats or nil,
    }
    msg.gb = ns.Data:GuildBankTime()
    return msg
end

-- Returnerer false, hvis vi ikke er i en guild (eller guilden ikke er indlæst endnu).
function Sync:SendHello(query)
    if not ns.Compat.GuildKey() then return false end
    ns.Comm:Send(BuildHello(query), "GUILD", nil, "NORMAL")
    lastSent = GetTime()
    return true
end

-- Til test uden guild: send HELLO som whisper til os selv, så hele kæden kan ses i /gc debug comm.
function Sync:SendHelloToSelf()
    ns.Comm:Send(BuildHello(false), "WHISPER", UnitName("player"), "NORMAL")
end

-- Samler flere ønsker om at sende HELLO til én besked og overholder MIN_INTERVAL.
function Sync:QueueHello(delay, query)
    if query then pendingQuery = true end
    if pending then return end
    pending = true
    delay = math.max(delay, lastSent + MIN_INTERVAL - GetTime())
    C_Timer.After(delay, function()
        pending = false
        local q = pendingQuery
        pendingQuery = false
        Sync:SendHello(q)
    end)
end

------------------------------------------------------------------------
-- REQ / DATA
------------------------------------------------------------------------

local function Id(key, kind) return key .. "|" .. kind end

-- Serveren kan tabe addon-beskeder uden fejl (set i spillet), og en andens REQ kan få os til at vente
-- på et svar, der aldrig når os. Derfor husker vi, hvilken version vi mangler, og spørger igen efter
-- REQ_TIMEOUT, indtil den er kommet (højst MAX_REQ_TRIES gange; næste HELLO starter forfra).
local function WatchWanted(key, kind)
    local id = Id(key, kind)
    C_Timer.After(REQ_TIMEOUT + Rand(1, 6), function()
        local w = wanted[id]
        if not w then return end
        if ns.Data:HeldVersion(key, kind) >= w.v or w.tries >= MAX_REQ_TRIES then
            wanted[id] = nil
            return
        end
        w.tries = w.tries + 1
        reqSeen[id] = nil
        Sync:QueueReq(key, kind)
        WatchWanted(key, kind)
    end)
end

-- Beder om data, medmindre en anden allerede har bedt om det samme for nylig.
-- want: den version, vi ved findes (fra HELLO/INVR).
function Sync:QueueReq(key, kind, want)
    local id = Id(key, kind)
    if want then
        local w = wanted[id]
        if not w then
            w = { v = want, tries = 0 }
            wanted[id] = w
            WatchWanted(key, kind)
        elseif want > w.v then
            w.v, w.tries = want, 0
        end
    end
    if reqSeen[id] and GetTime() - reqSeen[id] < REQ_TIMEOUT then return end
    local planned = GetTime()
    reqSeen[id] = planned
    C_Timer.After(Rand(0.5, 3), function()
        -- En andens REQ i mellemtiden opdaterer reqSeen; så kommer DATA alligevel til os.
        if reqSeen[id] ~= planned then return end
        ns.Comm:Send({ t = "REQ", c = key, k = kind, h = ns.Data:HeldVersion(key, kind) },
            "GUILD", nil, "NORMAL")
    end)
end

local function PlanData(key, kind, delay)
    local id = Id(key, kind)
    if dataPlanned[id] then return end
    local plan = { v = ns.Data:HeldVersion(key, kind) }
    dataPlanned[id] = plan
    C_Timer.After(delay, function()
        dataPlanned[id] = nil
        if plan.cancelled then return end
        local d = ns.Data:BuildPayload(key, kind)
        if not d then return end
        ns.Comm:Send({ t = "DATA", c = key, k = kind, v = ns.Data:HeldVersion(key, kind), d = d },
            "GUILD", nil, "BULK")
    end)
end

ns.Comm:Handle("REQ", function(sender, msg)
    local key, kind = msg.c, msg.k
    if not ValidKey(key) or not VALIDATORS[kind] or type(msg.h) ~= "number" then return end

    -- En andens REQ dækker også os, fordi svaret kommer på guild-kanalen. Det gælder ikke, når ejeren
    -- kun kan svare med whisper (blokeret guild-kanal): så må hver især spørge selv.
    if not ns.Comm.viaWhisper[key] then
        reqSeen[Id(key, kind)] = GetTime()
    end
    if ns.Data:HeldVersion(key, kind) <= msg.h then return end

    -- Ejeren svarer hurtigt; egne alts er vi også ejer af. Andre svarer kun for offline chars.
    local delay
    if key == ns.Compat.PlayerKey() then
        delay = Rand(0.2, 1)
    elseif ns.Data:IsMine(key) then
        delay = Rand(0.5, 1.5)
    elseif not Sync:IsOnline(key) then
        delay = Rand(2, 6)
    else
        return
    end
    PlanData(key, kind, delay)
end)

ns.Comm:Handle("DATA", function(sender, msg)
    local key, kind, version = msg.c, msg.k, msg.v
    if not ValidKey(key) or type(version) ~= "number" or not Valid(kind, msg.d) then return end

    local id = Id(key, kind)
    reqSeen[id] = nil
    local plan = dataPlanned[id]
    if plan and version >= plan.v then plan.cancelled = true end

    if version > ns.Data:HeldVersion(key, kind) then
        ns.Data:ApplyPayload(key, kind, version, msg.d)
    end
end)

------------------------------------------------------------------------
-- INVR: hvem har data om offline chars?
------------------------------------------------------------------------

local function BuildInventory(exclude)
    local list = {}
    local guild = ns.Data:GetGuild()
    local function Add(key)
        if key == exclude or Sync:IsOnline(key) then return end
        local entry, any = {}, false
        for i, kind in ipairs(KINDS) do
            entry[i] = ns.Data:HeldVersion(key, kind)
            if entry[i] > 0 then any = true end
        end
        if any then list[key] = entry end
    end
    for key in pairs(guild and guild.chars or {}) do Add(key) end
    for key in pairs(ns.Data:MyGuildChars()) do Add(key) end
    return list
end

-- Har en anden allerede annonceret denne char i samme eller nyere versioner?
local function Covered(entry, others)
    for _, other in ipairs(others) do
        local all = true
        for i = 1, #KINDS do
            if (other[i] or 0) < (entry[i] or 0) then all = false end
        end
        if all then return true end
    end
    return false
end

local function PlanInventory(newcomer)
    if invPlanned then return end
    local plan = { seen = {} }
    invPlanned = plan
    C_Timer.After(Rand(2, 8), function()
        invPlanned = nil
        local list, any = {}, false
        for key, entry in pairs(BuildInventory(newcomer)) do
            local others = {}
            for _, seenList in ipairs(plan.seen) do
                if type(seenList[key]) == "table" then table.insert(others, seenList[key]) end
            end
            if not Covered(entry, others) then
                list[key] = entry
                any = true
            end
        end
        if any then
            ns.Comm:Send({ t = "INVR", l = list }, "GUILD", nil, "BULK")
        end
    end)
end

ns.Comm:Handle("INVR", function(sender, msg)
    if type(msg.l) ~= "table" then return end
    if invPlanned then table.insert(invPlanned.seen, msg.l) end

    for key, entry in pairs(msg.l) do
        if ValidKey(key) and type(entry) == "table"
            and not ns.Data:IsMine(key) and not Sync:IsOnline(key) then
            for i, kind in ipairs(KINDS) do
                local v = entry[i]
                if type(v) == "number" and v > ns.Data:HeldVersion(key, kind) then
                    Sync:QueueReq(key, kind, v)
                end
            end
        end
    end
end)

------------------------------------------------------------------------
-- Guild bank
------------------------------------------------------------------------

function Sync:SendGuildBank()
    local guild = ns.Data:GetGuild()
    if not guild or not guild.guildBank then return end
    ns.Comm:Send({ t = "GBANK", s = guild.guildBank.s, d = guild.guildBank.tabs }, "GUILD", nil, "BULK")
end

local function PlanGuildBank()
    if gbankPlanned then return end
    local plan = {}
    gbankPlanned = plan
    C_Timer.After(Rand(2, 6), function()
        gbankPlanned = nil
        if not plan.cancelled then Sync:SendGuildBank() end
    end)
end

ns.Comm:Handle("GBANK", function(sender, msg)
    if type(msg.s) ~= "number" or type(msg.d) ~= "table" then return end
    for tab, counts in pairs(msg.d) do
        if type(tab) ~= "number" or not IsCountMap(counts) then return end
    end
    if gbankPlanned and msg.s >= ns.Data:GuildBankTime() then gbankPlanned.cancelled = true end
    ns.Data:ApplyGuildBank(msg.s, msg.d)
end)

------------------------------------------------------------------------
-- Modtagelse af HELLO
------------------------------------------------------------------------

local function ParseVersion(s)
    local a, b, c = tostring(s):match("^(%d+)%.(%d+)%.(%d+)")
    if not a then return end
    return tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)
end

local function CheckVersion(sender, av)
    if warnedVersion then return end
    local theirs, ours = ParseVersion(av), ParseVersion(ns.VERSION)
    if theirs and ours and theirs > ours then
        warnedVersion = true
        ns:Print(string.format("%s has a newer version (%s). You have %s.",
            ns.Compat.ShortName(sender), av, ns.VERSION))
    end
end

ns.Comm:Handle("HELLO", function(sender, msg)
    -- Vores egen besked kommer også retur, og egne alts er vi selv kilden til.
    if ns.Data:IsMine(sender) then return end
    if not Valid("info", msg) or type(msg.v) ~= "table" then return end

    online[sender] = true
    ns.Data:ApplyPayload(sender, "info", tonumber(msg.v.info) or 0, msg)
    local c = ns.Data:GetChar(sender)
    if c then c.seen = time() end
    CheckVersion(sender, msg.av)

    for _, kind in ipairs({ "recipes", "mats" }) do
        local v = tonumber(msg.v[kind])
        if v and v > ns.Data:HeldVersion(sender, kind) then
            Sync:QueueReq(sender, kind, v)
        end
    end

    -- Har vi en nyere guild bank end afsenderen, så del den (medmindre en anden når det først).
    local ourBank = ns.Data:GuildBankTime()
    if ourBank > 0 and ourBank > (tonumber(msg.gb) or 0) then
        PlanGuildBank()
    end

    if msg.q then
        Sync:QueueHello(Rand(1, 5))
        PlanInventory(sender)
    end
end)

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

-- Første HELLO sendes, når guilden er indlæst, med tilfældig forsinkelse (login-storm).
local function TryStart()
    local guildKey = ns.Compat.GuildKey()
    if started or not ns.loggedIn or not guildKey then return end
    started = true
    ns.Data:GetMe().guild = guildKey
    RefreshOnline()
    Sync:QueueHello(Rand(5, 15), true)
end

ns:On("LOGIN", function()
    ns.Compat.RequestGuildRoster()
    TryStart()
    -- Fallback, hvis guild-events kom før login.
    C_Timer.After(20, TryStart)
end)

ns:RegisterEvent("PLAYER_GUILD_UPDATE", function()
    TryStart()
    ns:Fire("ROSTER_CHANGED")
end)

ns:RegisterEvent("GUILD_ROSTER_UPDATE", function()
    if ns.loggedIn then RefreshOnline() end
    TryStart()
    ns:Fire("ROSTER_CHANGED")
end)

ns:On("ME_CHANGED", function()
    if started then
        Sync:QueueHello(5)
    end
    ns:Fire("ROSTER_CHANGED")
end)

ns:On("DATA_CHANGED", function()
    ns:Fire("ROSTER_CHANGED")
end)

-- Hjerteslag: en HELLO uden ændringer med jævne mellemrum. Modtagerne sammenligner versioner og
-- beder om det, de mangler, så tabte beskeder bliver rettet af sig selv.
C_Timer.NewTicker(HEARTBEAT, function()
    if started then Sync:QueueHello(Rand(0, 30)) end
end)

-- Reserve-transporten er slået til, og vi hører fra en addon-bruger for første gang: send dem vores
-- data med det samme (de har aldrig hørt fra os, fordi vores guild-beskeder ikke når frem).
ns:On("PEER_FOUND", function()
    if started then Sync:QueueHello(2) end
end)

-- Vores guild-besked kom ikke retur (se Comm.lua): send HELLO igen. Første gang på guild-kanalen,
-- anden gang er reserve-transporten slået til, og den går som whisper til addon-brugerne.
ns:On("GUILD_SEND_LOST", function()
    if started then Sync:QueueHello(2, true) end
end)
