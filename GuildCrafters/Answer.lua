local _, ns = ...

-- "!craft <item>" i guild-chatten (fra v0.16): én addon-bruger svarer i guild-chatten, hvem der kan
-- crafte det. Ønsket af en spiller på CurseForge. Format valgt af brugeren ud fra mockups:
--   [Flask of the Titans]: online Anna, Bob - offline Carl, Dave +2
--   3 matches: Flask of the Titans, Flask of Supreme Power, Flask of Pure Death. Be more specific.
--   Nobody with GuildCrafters can craft "dragonscale cloak".
-- Hvem svarer: alle online addon-brugere står i samme rækkefølge (sorteret efter navn), og hver venter
-- STEP sekunder pr. plads foran sig. Den, der svarer, sender først ANS på addon-kanalen, så de andre
-- dropper deres svar. En gammel klient (0.15 og før) kender ikke ANS og ignorerer den.
-- Inde i dungeons og raids kommer guild-addon-beskeder ikke altid frem, så ANS kan gå tabt og give to
-- svar. Derfor to sikringer mere: man svarer ikke selv inde i en instance, og ser man en andens svar
-- på samme spørgsmål i guild-chatten, dropper man sit eget, også når ANS aldrig kom frem.
-- Whisper "!craft <item>" til en med addonen giver svaret som whisper (kun fra guild-medlemmer).
-- /gc answer off: man svarer aldrig selv (andre gør).
local Answer = {}
ns.Answer = Answer

local MAX_NAMES = 5      -- navne i et svar; resten bliver "+N"
local MAX_MATCHES = 3    -- navne, når flere recipes passer
local MAX_LEN = 255      -- loft over en chatlinje
local FIRST = 1          -- sekunder før den første svarer (item-navne når at blive indlæst)
local STEP = 1.5         -- ekstra sekunder pr. plads i rækkefølgen
local REPEAT = 15        -- samme spørgsmål fra samme spiller besvares kun én gang inden for så mange sek.

local pending = {}       -- [spørgsmål] = teksten efter "!craft": vi venter på vores tur
local answered = {}      -- [spørgsmål] = GetTime(): besvaret (af os eller en anden)
local afterCombat = {}   -- whispers, der kom i kamp: { key, rest }

local function Enabled()
    return ns.db and ns.db.settings.answer ~= false
end

-- "!craft titans" -> "titans" ("" uden tekst). nil, hvis det ikke er en !craft-linje.
local function Parse(text)
    local cmd, rest = text:match("^%s*(%S+)%s*(.-)%s*$")
    if cmd and cmd:lower() == "!craft" then return rest end
end

-- Spørgsmålet som nøgle, ens hos alle klienter: afsender + teksten med små bogstaver.
local function QuestionID(key, rest)
    return key .. "|" .. rest:lower():gsub("%s+", " ")
end

-- Kun chars, der er rigtige guild-medlemmer: testfigurerne fra /gc debug fake må aldrig stå i chatten.
local function IsReal(key)
    local guild = ns.Data:GetGuild()
    return (guild and guild.chars[key]) or ns.Data:MyGuildChars()[key]
end

-- "[Flask of the Titans]: online Anna, Bob - offline Carl +2"
local function CraftersLine(kind, id, label)
    local keys = {}
    for _, key in ipairs(ns.Index:Crafters(kind, id)) do
        if IsReal(key) then table.insert(keys, key) end
    end
    if #keys == 0 then return "Nobody with GuildCrafters can craft " .. label .. "." end
    local online, offline = {}, {}
    for i, key in ipairs(keys) do
        if i > MAX_NAMES then break end
        table.insert(ns.Index:IsOnline(key) and online or offline, ns.Compat.ShortName(key))
    end
    local more = #keys - #online - #offline
    local parts = {}
    if #online > 0 then table.insert(parts, "online " .. table.concat(online, ", ")) end
    if #offline > 0 then table.insert(parts, "offline " .. table.concat(offline, ", ")) end
    local text = label .. ": " .. table.concat(parts, " - ") .. (more > 0 and (" +" .. more) or "")
    if #text > MAX_LEN then text = text:sub(1, MAX_LEN) end    -- kan kun ske med meget lange links
    return text
end

-- Svaret på "!craft <rest>", eller nil hvis der ikke er noget at svare.
function Answer.Reply(rest)
    local kind, id = ns.Compat.LinkRecipe(rest)
    if kind then
        -- Linket fra spørgsmålet genbruges: så kræver svaret ikke, at itemet er i vores cache.
        local link = rest:match("|c[^|]*|H.-|h|r") or rest:match("|H.-|h") or ns.StripLinks(rest)
        return CraftersLine(kind, id, link)
    end
    local query = ns.StripLinks(rest):lower():gsub("%s+", " ")
    if query == "" then return nil end
    local words = {}
    for word in query:gmatch("%S+") do table.insert(words, word) end
    local matches = {}
    for _, r in ipairs(ns.Index:Recipes()) do
        local name = ns.Index.Name(r.kind, r.id)
        local low = name and name:lower()
        if low == query then
            matches = { { kind = r.kind, id = r.id, name = name } }
            break
        elseif low then
            local ok = true
            for _, word in ipairs(words) do
                if not low:find(word, 1, true) then ok = false break end
            end
            if ok then table.insert(matches, { kind = r.kind, id = r.id, name = name }) end
        end
    end
    if #matches == 0 then
        local shown = ns.StripLinks(rest)
        if #shown > 60 then shown = shown:sub(1, 57) .. "..." end
        return 'Nobody with GuildCrafters can craft "' .. shown .. '".'
    elseif #matches == 1 then
        local m = matches[1]
        local label = (m.kind == "i" and ns.Compat.ItemLink(m.id)) or m.name
        return CraftersLine(m.kind, m.id, label)
    end
    table.sort(matches, function(a, b) return a.name < b.name end)
    local names = {}
    for i = 1, math.min(MAX_MATCHES, #matches) do names[i] = matches[i].name end
    local text = #matches .. " matches: " .. table.concat(names, ", ")
        .. (#matches > MAX_MATCHES and ", ..." or "") .. ". Be more specific."
    return text:sub(1, MAX_LEN)
end

-- "Post crafters to guild chat" i højreklik-menuerne i Crafting og Craft List (fra v0.17): samme linje
-- som svaret på "!craft", sendt af en selv.
function Answer.Post(kind, id)
    local label = (kind == "i" and ns.Compat.ItemLink(id)) or ns.Index.Name(kind, id)
    if label then ns.Compat.SendChat(CraftersLine(kind, id, label), "GUILD") end
end

-- Menupunktet til en recipe, eller nil uden guild.
function Answer.PostMenuItem(kind, id)
    if not ns.Compat.GuildKey() then return nil end
    return { text = "Post crafters to guild chat", func = function() Answer.Post(kind, id) end }
end

-- Vores plads i rækkefølgen: 0 = vi svarer først. Alle online addon-brugere i guilden, sorteret efter
-- navn, så alle klienter (næsten altid) når frem til samme rækkefølge.
local function Rank()
    local me = ns.Compat.PlayerKey()
    local guild = ns.Data:GetGuild()
    local keys = { me }
    for key in pairs(guild and guild.chars or {}) do
        if key ~= me and not ns.Sync:IsGone(key) and ns.Sync:IsOnline(key) then
            table.insert(keys, key)
        end
    end
    table.sort(keys)
    for i, key in ipairs(keys) do
        if key == me then return i - 1 end
    end
    return 0
end

local function Recent(id)
    return answered[id] and GetTime() - answered[id] < REPEAT
end

-- Hvad et svar handler om, så to svar på samme spørgsmål kan genkendes, selvom navnene i dem er
-- forskellige (hver klient ser sin egen online-status). nil, hvis linjen ikke ligner et svar.
local function AnswerKey(line)
    if line:find("^Nobody with GuildCrafters can craft ") or line:find("^%d+ matches: .*Be more specific%.$") then
        return line:lower()
    end
    local label = line:match("^(.-): online ") or line:match("^(.-): offline ")
    if not label then return nil end
    local kind, id = ns.Compat.LinkRecipe(label)
    if kind then return kind .. id end
    return label:lower()
end

-- En andens svar i guild-chatten: drop vores eget svar på samme spørgsmål.
local function SeenAnswer(text)
    local key = next(pending) and AnswerKey(text)
    if not key then return end
    for id, rest in pairs(pending) do
        if AnswerKey(Answer.Reply(rest) or "") == key then
            pending[id] = nil
            answered[id] = GetTime()
        end
    end
end

ns.Comm:Handle("ANS", function(sender, msg)
    if sender == ns.Compat.PlayerKey() or type(msg.a) ~= "string" then return end
    pending[msg.a] = nil
    answered[msg.a] = GetTime()
end)

ns:RegisterEvent("CHAT_MSG_GUILD", function(_, text, sender)
    if ns.Comm.IsSecret(text, sender) or type(text) ~= "string" or type(sender) ~= "string" then return end
    local rest = Parse(text)
    local from = ns.Compat.FullName(sender)
    if not rest then
        if from ~= ns.Compat.PlayerKey() then SeenAnswer(text) end
        return
    end
    if rest == "" or not Enabled() or not ns.Data:GetGuild() then return end
    local id = QuestionID(from, rest)
    if pending[id] or Recent(id) then return end
    pending[id] = rest
    Answer.Reply(rest)      -- bestiller item-navne fra serveren, så de er klar, når det er vores tur
    C_Timer.After(FIRST + Rank() * STEP + math.random() * 0.5, function()
        if not pending[id] then return end      -- en anden har svaret
        pending[id] = nil
        -- I kamp, i en instance (ANS når ikke altid frem) eller med sync på pause: næste i rækken svarer.
        if ns.Compat.InCombat() or ns.Compat.InInstance() or ns.Comm.paused or not Enabled() then
            return
        end
        local reply = Answer.Reply(rest)
        if not reply then return end
        answered[id] = GetTime()
        ns.Comm:Send({ t = "ANS", a = id }, "GUILD", nil, "ALERT")
        ns.Compat.SendChat(reply, "GUILD")
    end)
end)

local function Whisper(key, rest)
    local reply = rest == "" and "Usage: !craft <item name or link>" or Answer.Reply(rest)
    if reply then ns.Compat.SendChat(reply, "WHISPER", key) end
end

ns:RegisterEvent("CHAT_MSG_WHISPER", function(_, text, sender)
    if ns.Comm.IsSecret(text, sender) or type(text) ~= "string" or type(sender) ~= "string" then return end
    local rest = Parse(text)
    if not rest or not Enabled() then return end
    local key = ns.Compat.FullName(sender)
    if key == ns.Compat.PlayerKey() or not ns.Compat.IsGuildMember(key) then return end
    local id = QuestionID(key, rest)
    if Recent(id) then return end
    answered[id] = GetTime()
    Answer.Reply(rest)      -- bestil item-navne
    C_Timer.After(FIRST, function()
        if ns.Compat.InCombat() then
            table.insert(afterCombat, { key = key, rest = rest })
        else
            Whisper(key, rest)
        end
    end)
end)

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    local list = afterCombat
    afterCombat = {}
    for _, w in ipairs(list) do Whisper(w.key, w.rest) end
end)

ns:RegisterCommand("answer", function(arg)
    arg = (arg or ""):lower()
    if arg == "on" or arg == "off" then
        ns.db.settings.answer = arg == "on"
    end
    ns:Print("Answering !craft <item> in guild chat and whispers is "
        .. (Enabled() and "on" or "off") .. ns.Plain(". Use /gc answer on|off"))
end, "/gc answer on|off - answer !craft <item> in guild chat and whispers (default on)")
