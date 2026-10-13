local _, ns = ...

-- Transport: AceComm deler beskeder over 255 bytes op i chunks og sender via ChatThrottleLib.
-- AceSerializer laver Lua-tabeller om til tekst. Al protokol-logik ligger i Sync.lua.
local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "GCRAFT"
Comm.PROTO = 2   -- 2: recipes-payload med reagents ({ p = professions, g = reagents })

local AceSerializer = LibStub("AceSerializer-3.0")
LibStub("AceComm-3.0"):Embed(Comm)

local handlers = {}
local warnedNewer = false

function Comm:Handle(msgType, fn)
    handlers[msgType] = fn
end

local function DebugPrint(text)
    if ns.debugComm then
        ns:Print("|cff888888[comm] " .. text .. "|r")
    end
end

local function Log(direction, msgType, who, size)
    DebugPrint(string.format("%s %s %s (%d bytes)", direction, msgType, who, size))
end

-- Navn på et SendAddonMessageResult-tal, fx 0 -> "Success".
function Comm.ResultName(result)
    for name, value in pairs(Enum and Enum.SendAddonMessageResult or {}) do
        if value == result then return name end
    end
    return tostring(result)
end

------------------------------------------------------------------------
-- Reserve-transport. Set i spillet (2026-10-12): hos én spiller svarede API'et "Success" på
-- guild-beskeder, men serveren leverede dem aldrig (heller ikke retur til ham selv), mens whisper
-- virkede. Vi holder derfor øje med, om vores egne guild-beskeder kommer retur. Gør de ikke det to
-- gange i træk, sendes alt også som whisper direkte til de guild-medlemmer, der har addonen.
------------------------------------------------------------------------

local ECHO_WAIT = 8         -- sekunder vi venter på at se vores egen guild-besked komme retur
local MAX_DISCOVERY = 40    -- så mange online-medlemmer må vi højst whispe for at finde addon-brugere

Comm.guildBlocked = false
Comm.viaWhisper = {}        -- [key] = true: deres seneste besked kom som whisper (deres guild-kanal er blokeret)
local lastGuildEcho = -1000
local guildFails = 0
local echoCheckPending = false
local discoverPending = false
local discovered = false
local peers = {}            -- [key] = true: har sendt os noget i denne session, dvs. har addonen
local whispered = {}        -- [navn] = GetTime(): til at skjule "No player named ..." for vores whispers

local function GuildEchoSeen()
    lastGuildEcho = GetTime()
    guildFails = 0
    if Comm.guildBlocked then
        Comm.guildBlocked = false
        ns:Print("Guild addon messages are getting through again.")
    end
end

-- Kaldes, når en guild-besked er afleveret til serveren: kommer den retur inden for ECHO_WAIT?
local function WatchEcho()
    if echoCheckPending then return end
    echoCheckPending = true
    local sentAt = GetTime()
    C_Timer.After(ECHO_WAIT, function()
        echoCheckPending = false
        if lastGuildEcho >= sentAt then return end
        guildFails = guildFails + 1
        DebugPrint("guild message did not come back (" .. guildFails .. ")")
        local wasBlocked = Comm.guildBlocked
        if guildFails >= 2 and not wasBlocked then
            Comm.guildBlocked = true
            -- Kun én gang pr. session: en kanal, der skifter frem og tilbage, må ikke få os til at
            -- whispe alle online guild-medlemmer igen og igen.
            if not discovered then
                discovered = true
                discoverPending = true
            end
            ns:Print("Your addon messages are not getting through on the guild channel. "
                .. "Sending directly to guild members with GuildCrafters instead.")
        end
        -- Første gang: prøv igen. Anden gang: send HELLO som whisper. Derefter ikke flere genforsøg.
        if not wasBlocked then ns:Fire("GUILD_SEND_LOST") end
    end)
end

-- Hvem skal have vores beskeder som whisper: online addon-brugere, vi har hørt fra eller har i cachen.
-- Første gang efter skiftet spørges alle online guild-medlemmer (hvis de er få), så vi finder dem,
-- der har addonen, selvom de aldrig har hørt fra os.
local function WhisperTargets()
    local me = ns.Compat.PlayerKey()
    local targets, seen = {}, {}
    local function Add(key)
        if key ~= me and not seen[key] and not ns.Data:IsMine(key) then
            seen[key] = true
            table.insert(targets, key)
        end
    end
    local guild = ns.Data:GetGuild()
    for key in pairs(peers) do
        if ns.Sync:IsOnline(key) then Add(key) end
    end
    for key in pairs(guild and guild.chars or {}) do
        if ns.Sync:IsOnline(key) then Add(key) end
    end
    if discoverPending then
        discoverPending = false
        local online = {}
        for _, m in ipairs(ns.Compat.GetGuildMembers()) do
            if m.online then table.insert(online, m.key) end
        end
        if #online <= MAX_DISCOVERY then
            for _, key in ipairs(online) do Add(key) end
        end
    end
    return targets
end

local function SendToPeers(text, msgType, prio)
    for _, key in ipairs(WhisperTargets()) do
        local name = ns.Compat.ChatName(key)
        whispered[name] = GetTime()
        Log("->", msgType, name, #text)
        Comm:SendCommMessage(Comm.PREFIX, text, "WHISPER", name, prio or "BULK")
    end
end

-- Skjul "No player named 'X' is currently playing." for whispers, vi selv har sendt (X loggede lige af).
if ChatFrame_AddMessageEventFilter and ERR_CHAT_PLAYER_NOT_FOUND_S then
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, text)
        for name, at in pairs(whispered) do
            if GetTime() - at < 15 and text == ERR_CHAT_PLAYER_NOT_FOUND_S:format(name) then
                peers[ns.Compat.FullName(name)] = nil
                return true
            end
        end
        return false
    end)
end

------------------------------------------------------------------------
-- Pause i kamp (fra v0.15). Sync må aldrig kunne mærkes i en kamp eller ved et raid-pull, så i
-- kamp gør vi kun det, der ikke kan vente: ser, om vores egne guild-beskeder kommer
-- retur (ellers ville reserve-transporten slå til ved en fejl). Alt andet køes:
--   ud:  beskeder, vi ville sende, sendes efter kampen med lidt tilfældig forsinkelse (hele raidet
--        forlader kampen samtidig). Nyere beskeder af samme slags erstatter ældre.
--   ind: andres beskeder gemmes som rå tekst og behandles bagefter, nogle få ad gangen. REQ må ikke
--        gå tabt (den, der spørger, giver op efter et par minutter), så de ryddes aldrig ud.
-- Der pauses i kamp (InCombatLockdown), ikke i hele instances. Klientens lockdown-funktioner på
-- Mainline styrer ikke pausen; se Compat.InCombat for hvorfor.
------------------------------------------------------------------------

local MAX_IN_BYTES = 1000000    -- loft over gemte indgående beskeder; de ældste, der ikke er REQ, ryger først
local DRAIN_STEP = 0.1          -- sekunder mellem to gemte beskeder efter kampen (en stor DATA koster
                                -- 2-8 ms at pakke ud, målt i tools/sim/loadtest.py)
local RESUME_CHECK = 3          -- sekunder mellem tjek af, om kampen er slut (reserve for eventet)

Comm.paused = false
local outQueue, outByKey = {}, {}   -- { key, msg, distribution, target, prio }
local inQueue, inBytes = {}, 0      -- { text, distribution, sender, req = bool }
local draining = false
local SendNow, Receive

local function Pause()
    if Comm.paused then return end
    Comm.paused = true
    ns:Fire("SYNC_STATUS")
    -- PLAYER_REGEN_ENABLED afslutter normalt pausen; tjekket her dækker en lockdown uden det event.
    local function Check()
        if not Comm.paused then return end
        if ns.Compat.InCombat() then
            C_Timer.After(RESUME_CHECK, Check)
        else
            Comm.Resume()
        end
    end
    C_Timer.After(RESUME_CHECK, Check)
end

local function IsPaused()
    if not Comm.paused and ns.Compat.InCombat() then Pause() end
    return Comm.paused
end

-- Én gemt besked ad gangen. Næste trin planlægges, før beskeden behandles, og en fejl i en besked må
-- ikke stoppe resten: ellers blev alt, der blev gemt i denne og senere kampe, aldrig behandlet.
local function Drain()
    local entry = not Comm.paused and table.remove(inQueue, 1)
    if not entry then
        draining = false
        return
    end
    inBytes = inBytes - #entry.text
    C_Timer.After(DRAIN_STEP, Drain)
    xpcall(Receive, geterrorhandler(), entry.text, entry.distribution, entry.sender)
end

function Comm.Resume()
    if not Comm.paused or ns.Compat.InCombat() then return end
    Comm.paused = false
    ns:Fire("SYNC_STATUS")
    if #inQueue > 0 and not draining then
        draining = true
        C_Timer.After(DRAIN_STEP, Drain)
    end
    if #outQueue > 0 then
        C_Timer.After(1 + math.random() * 3, function()
            if IsPaused() then return end       -- i kamp igen: køen bliver stående
            local queue = outQueue
            outQueue, outByKey = {}, {}
            for _, e in ipairs(queue) do
                SendNow(e.msg, e.distribution, e.target, e.prio)
            end
        end)
    end
end

ns:RegisterEvent("PLAYER_REGEN_DISABLED", Pause)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() Comm.Resume() end)

local function QueueOut(msg, distribution, target, prio)
    local key = table.concat({ msg.t, msg.c or "", msg.k or "", distribution, target or "" }, "|")
    local entry = outByKey[key]
    if entry then
        if entry.msg.q then msg.q = entry.msg.q end     -- et "svar venligst" må ikke gå tabt
        entry.msg, entry.prio = msg, prio
    else
        entry = { msg = msg, distribution = distribution, target = target, prio = prio }
        outByKey[key] = entry
        table.insert(outQueue, entry)
    end
end

local function QueueIn(text, distribution, sender)
    -- Samme besked igen (den, der spørger, prøver igen hvert halve minut): én er nok.
    for _, e in ipairs(inQueue) do
        if e.sender == sender and e.text == text then return end
    end
    table.insert(inQueue, { text = text, distribution = distribution, sender = sender,
        req = text:find("^SREQ^", 1, true) ~= nil })
    inBytes = inBytes + #text
    local i = 1
    while inBytes > MAX_IN_BYTES and i <= #inQueue do
        if inQueue[i].req then
            i = i + 1
        else
            inBytes = inBytes - #inQueue[i].text
            table.remove(inQueue, i)
        end
    end
end

-- prio: "ALERT", "NORMAL" eller "BULK" (ChatThrottleLib).
function Comm:Send(msg, distribution, target, prio)
    -- Også lige efter kampen, mens køen venter på at blive sendt: ellers gik en ny HELLO ud før den
    -- gamle i køen, og den gamle (forældet rolle, level, professions) vandt hos alle modtagere.
    if IsPaused() or #outQueue > 0 then
        QueueOut(msg, distribution, target, prio)
        return
    end
    SendNow(msg, distribution, target, prio)
end

SendNow = function(msg, distribution, target, prio)
    local self = Comm
    msg.p = Comm.PROTO
    local text = AceSerializer:Serialize(msg)
    Log("->", msg.t, target or distribution, #text)
    -- AceComm kalder tilbage pr. chunk med (arg, bytes sendt, bytes i alt, didSend).
    -- Fejlårsagen kommer ikke med; brug /gc debug ping for at se den.
    self:SendCommMessage(Comm.PREFIX, text, distribution, target, prio or "NORMAL",
        function(_, sent, total, didSend)
            if didSend == false then
                DebugPrint(msg.t .. " FAILED to send (try /gc debug ping)")
            elseif sent == total then
                DebugPrint(msg.t .. " sent to the server")
                if distribution == "GUILD" then WatchEcho() end
            end
        end)
    -- Guild-kanalen sendes stadig (så vi opdager, hvis den virker igen), men når den er blokeret,
    -- får addon-brugerne også beskeden direkte.
    if distribution == "GUILD" and Comm.guildBlocked then
        SendToPeers(text, msg.t, prio)
    end
end

-- Mainline (Midnight-reglerne, også i WoW Forever): under raid-encounters og M+ kan afsender og tekst
-- være "hemmelige værdier", som addons ikke må læse eller sammenligne; selv en sammenligning giver fejl.
local function IsSecret(...)
    if not issecretvalue then return false end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return true end
    end
    return false
end

function Comm:OnCommReceived(prefix, text, distribution, sender)
    if IsSecret(prefix, text, sender) then return end
    if prefix ~= Comm.PREFIX then return end
    -- Også mens køen tømmes efter kampen: nye beskeder skal bagest i køen, ellers blev en ældre
    -- besked fra samme afsender behandlet efter den nye og vandt.
    if IsPaused() or draining or #inQueue > 0 then
        -- Afsenderen tjekkes, før noget pakkes ud: vores eget ekko må ikke vente (se WatchEcho),
        -- og resten skal ikke koste noget i kamp.
        if ns.Compat.FullName(sender) == ns.Compat.PlayerKey() then
            if distribution == "GUILD" then GuildEchoSeen() end
        else
            QueueIn(text, distribution, sender)
            if not Comm.paused and not draining then
                draining = true
                C_Timer.After(DRAIN_STEP, Drain)
            end
        end
        return
    end
    Receive(text, distribution, sender)
end

Receive = function(text, distribution, sender)
    local ok, msg = AceSerializer:Deserialize(text)
    if not ok or type(msg) ~= "table" or type(msg.t) ~= "string" or type(msg.p) ~= "number" then
        DebugPrint("invalid message from " .. tostring(sender))
        return
    end

    local key = ns.Compat.FullName(sender)
    Log("<-", msg.t, key, #text)

    local me = ns.Compat.PlayerKey()
    if key == me then
        if distribution == "GUILD" then GuildEchoSeen() end
    else
        -- Whispers (reserve-transporten) accepteres kun fra medlemmer af vores egen guild.
        if distribution == "WHISPER" and not ns.Compat.IsGuildMember(key) then
            DebugPrint("ignored whisper from non-guild member " .. key)
            return
        end
        if not peers[key] then
            peers[key] = true
            if Comm.guildBlocked then ns:Fire("PEER_FOUND", key) end
        end
        ns:Fire("HEARD", key)
        -- Sender de via whisper, ser vi ikke deres svar til andre; se REQ i Sync.lua.
        Comm.viaWhisper[key] = distribution == "WHISPER"
    end

    if msg.p > Comm.PROTO then
        if not warnedNewer then
            warnedNewer = true
            ns:Print("A newer version of GuildCrafters exists (from " .. key .. "). Please update.")
        end
        return
    end

    local fn = handlers[msg.t]
    if fn then
        fn(key, msg, distribution)
    end
end

-- En kopi, der holder sig i ro (se Core.lua), må heller ikke lytte med på addon-beskederne.
if not ns.inactive then
    Comm:RegisterComm(Comm.PREFIX, "OnCommReceived")
end

-- Rå modtagelse, før AceComm samler chunks: viser om noget overhovedet når frem.
ns:RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
    if IsSecret(prefix, text, sender) then return end
    if prefix == Comm.PREFIX or prefix == Comm.PREFIX .. "P" then
        DebugPrint(string.format("raw %s %s from %s (%d bytes)", prefix, channel, tostring(sender), #text))
    end
end)

-- Test af transporten uden AceComm/ChatThrottleLib: én lille besked direkte via API'et.
function Comm.Ping(channel, target)
    local prefix = Comm.PREFIX .. "P"
    if C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(prefix)
    end
    local result = C_ChatInfo.SendAddonMessage(prefix, "ping", channel, target)
    ns:Print(string.format("Ping via %s%s: %s", channel, target and (" to " .. target) or "",
        result == nil and "sent (no result from API)" or Comm.ResultName(result)))
end
