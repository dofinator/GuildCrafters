local _, ns = ...

-- Scanner crafting-mats i tasker, bank og guild bank. Egne mats deles kun med opt-in
-- (/gc mats on eller checkboksen i Mats-fanen); guild bank deles altid, fordi den er guildens.
local Mats = {}
ns.Mats = Mats

local ANNOUNCE_INTERVAL = 90   -- sekunder: højst én ny mats-version pr. interval, så farming ikke spammer

local bankOpen = false
local dirty = false
local announceTimer = false

local function SameCounts(a, b)
    a, b = a or {}, b or {}
    for id, n in pairs(a) do
        if b[id] ~= n then return false end
    end
    for id in pairs(b) do
        if a[id] == nil then return false end
    end
    return true
end

-- Nye mats-data annonceres samlet efter ANNOUNCE_INTERVAL; lokalt vises de med det samme.
-- (Brugeren prøvede 5 s under test med en ven, men valgte 90 s: hurtigere er overkill til daglig brug.)
local function MarkDirty()
    dirty = true
    ns:Fire("DATA_CHANGED", ns.Compat.PlayerKey(), "mats")
    if announceTimer then return end
    announceTimer = true
    C_Timer.After(ANNOUNCE_INTERVAL, function()
        announceTimer = false
        if dirty then
            dirty = false
            ns.Data:MeChanged("mats")
        end
    end)
end

local function Store(source, counts)
    local me = ns.Data:GetMe()
    me.mats = me.mats or {}
    if SameCounts(me.mats[source], counts) then return end
    me.mats[source] = counts
    me.mats.time = ns.Compat.Now()
    MarkDirty()
end

function Mats:ScanBags()
    Store("bags", ns.Compat.CountMats(ns.Compat.BAG_IDS))
end

function Mats:ScanBank()
    if bankOpen then
        Store("bank", ns.Compat.CountMats(ns.Compat.BankIDs()))
    end
end

-- Faner, der ikke er hentet fra serveren endnu, ser tomme ud. Behold derfor de gamle data for
-- tomme faner, medmindre det er den fane, man kigger på lige nu.
function Mats:ScanGuildBank()
    if not ns.Compat.HasGuildBank() then return end
    local guild = ns.Data:GetGuild()
    if not guild then return end

    local scanned, current = ns.Compat.ReadGuildBank()
    local old = guild.guildBank and guild.guildBank.tabs or {}
    local tabs, changed = {}, false
    for tab, counts in pairs(old) do tabs[tab] = counts end
    for tab, result in pairs(scanned) do
        if result.any or tab == current then
            if not SameCounts(tabs[tab], result.counts) then changed = true end
            tabs[tab] = result.counts
        end
    end
    if changed and ns.Data:ApplyGuildBank(ns.Compat.Now(), tabs) then
        Mats:QueueGuildBankSend()
    end
end

local gbankSendPending = false
function Mats:QueueGuildBankSend()
    if gbankSendPending then return end
    gbankSendPending = true
    -- Vent, til man er færdig med at flytte ting rundt i banken.
    C_Timer.After(5, function()
        gbankSendPending = false
        ns.Sync:SendGuildBank()
    end)
end

function Mats:SetSharing(on)
    ns.db.settings.shareMats = on and true or false
    -- Info indeholder "ms"-flaget, så andre fjerner vores mats, hvis vi slår det fra.
    ns.Data:MeChanged("info")
    if on then ns.Data:MeChanged("mats") end
    ns:Print("Sharing your mats: " .. (on and "on" or "off"))
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local function Debounce(fn, delay)
    local planned = false
    return function()
        if planned then return end
        planned = true
        C_Timer.After(delay, function()
            planned = false
            fn()
        end)
    end
end

local scanBags = Debounce(function() Mats:ScanBags(); Mats:ScanBank() end, 1)
local scanGuildBank = Debounce(function() Mats:ScanGuildBank() end, 1)

ns:On("LOGIN", function() C_Timer.After(3, scanBags) end)
ns:RegisterEvent("BAG_UPDATE_DELAYED", function() if ns.loggedIn then scanBags() end end)

ns:RegisterEvent("BANKFRAME_OPENED", function()
    bankOpen = true
    scanBags()
end)
ns:RegisterEvent("BANKFRAME_CLOSED", function() bankOpen = false end)
ns:RegisterEvent("PLAYERBANKSLOTS_CHANGED", function() scanBags() end)

ns:RegisterEvent("GUILDBANKFRAME_OPENED", function()
    ns.Compat.QueryGuildBankTabs()
    scanGuildBank()
end)
ns:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED", function() scanGuildBank() end)

ns:RegisterCommand("mats", function(arg)
    arg = arg:lower()
    if arg == "on" or arg == "til" then
        Mats:SetSharing(true)
    elseif arg == "off" or arg == "fra" then
        Mats:SetSharing(false)
    else
        ns:Print("Sharing your mats is " .. (ns.db.settings.shareMats and "on" or "off")
            .. ns.Plain(". Use /gc mats on|off"))
    end
end, "/gc mats on|off - share your crafting mats with the guild")
