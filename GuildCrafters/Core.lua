local addonName, ns = ...

ns.VERSION = ns.Compat.GetAddOnMetadata(addonName, "Version") or "dev"
ns.DB_SCHEMA = 1
-- Gemte data ligger i en global opkaldt efter addon-mappen: GuildCraftersDB, og GuildCraftersTestDB
-- for testudgaven (GuildCraftersTest.toc), så de to aldrig skriver i hinandens data.
ns.DB_NAME = addonName .. "DB"
ns.IS_TEST = addonName ~= "GuildCrafters"

-- Testudgaven og den udgivne addon deler /gc, addon-beskeder og vinduer, så kun én af dem må køre.
-- Den, der indlæses sidst (testudgaven), holder sig helt i ro, hvis den anden allerede er indlæst.
local otherCopy = ns.IS_TEST and "GuildCrafters" or "GuildCraftersTest"
ns.inactive = ns.Compat.IsAddOnLoaded(otherCopy) and true or false

function ns:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99GuildCrafters|r: " .. tostring(msg))
end

-- Tekst med "|" i (fx "tank|healer|dps") til chatten: "|h" og "|a" er styrekoder, så i spillet stod der
-- "tankealer|dps|uto" i /gc help (set i tour 2026-10-13). "||" vises som ét "|".
function ns.Plain(text)
    return (text:gsub("|", "||"))
end

-- Kalder fn, men en fejl i ét modul må ikke stoppe de andre (fx minimap-knappen ved login).
-- Fejlen vises stadig i WoW's normale fejlvindue.
local function SafeCall(fn, ...)
    xpcall(fn, geterrorhandler(), ...)
end

-- WoW-events: flere moduler kan lytte på samme event.
local frame = CreateFrame("Frame")
local handlers = {}

function ns:RegisterEvent(event, fn)
    if ns.inactive then return false end
    if not handlers[event] then
        -- pcall: events, der ikke findes i den aktuelle client, ignoreres i stedet for at fejle.
        if not pcall(frame.RegisterEvent, frame, event) then return false end
        handlers[event] = {}
    end
    table.insert(handlers[event], fn)
    return true
end

frame:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(handlers[event]) do
        SafeCall(fn, event, ...)
    end
end)

if ns.inactive then
    -- Sig det én gang ved login; ellers ser det bare ud, som om addonen er død.
    frame:RegisterEvent("PLAYER_LOGIN")
    handlers.PLAYER_LOGIN = { function()
        ns:Print("|cffff4040Not running:|r " .. otherCopy .. " is enabled too. Disable one of them in the "
            .. "AddOns list, then /reload.")
    end }
end

-- Interne beskeder mellem moduler, fx "ME_CHANGED" og "ROSTER_CHANGED".
local listeners = {}

function ns:On(message, fn)
    listeners[message] = listeners[message] or {}
    table.insert(listeners[message], fn)
end

function ns:Fire(message, ...)
    for _, fn in ipairs(listeners[message] or {}) do
        SafeCall(fn, ...)
    end
end

ns:RegisterEvent("ADDON_LOADED", function(_, name)
    if name == addonName then
        ns.Data:Init()
    end
end)

ns:RegisterEvent("PLAYER_LOGIN", function()
    ns.loggedIn = true
    ns:Fire("LOGIN")
    -- Kun første gang og efter en opdatering; ved hvert login var linjen bare støj.
    local seen = ns.db and ns.db.settings.seenVersion
    if seen ~= ns.VERSION then
        ns:Print("v" .. ns.VERSION .. (seen and " installed" or " loaded")
            .. ". Type /gc to open, /gc help for commands.")
        if ns.db then ns.db.settings.seenVersion = ns.VERSION end
    end
end)

-- Slash-kommandoer: /gc <kommando> <resten>
local commands = {}
local helpLines = {}

function ns:RegisterCommand(name, fn, help)
    commands[name] = fn
    if help then table.insert(helpLines, help) end
end

ns:RegisterCommand("help", function()
    ns:Print("Commands:")
    ns:Print("  /gc <text> - search recipes, e.g. /gc flask (shift-click an item to paste its name)")
    for _, line in ipairs(helpLines) do
        ns:Print("  " .. ns.Plain(line))
    end
end)

if ns.inactive then return end    -- /gc tilhører den kopi, der kører

SLASH_GUILDCRAFTERS1 = "/gc"
SLASH_GUILDCRAFTERS2 = "/guildcrafters"
SlashCmdList.GUILDCRAFTERS = function(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "" then
        ns.UI:Toggle()
    elseif commands[cmd] then
        commands[cmd](rest)
    else
        -- Alt andet er en søgning i Crafting: "/gc flask". Et shift-klikket item ("/gc [Flask of the
        -- Titans]") bliver til sit navn.
        local text = msg:gsub("|H.-|h%[(.-)%]|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn.-:", "")
            :gsub("|r", "")
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        ns.UI.SearchRecipes(text)
    end
end
