local addonName, ns = ...

ns.VERSION = ns.Compat.GetAddOnMetadata(addonName, "Version") or "dev"
ns.DB_SCHEMA = 1

function ns:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99GuildCrafters|r: " .. tostring(msg))
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
    ns:Print("v" .. ns.VERSION .. " loaded. Type /gc to open, /gc help for commands.")
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
    for _, line in ipairs(helpLines) do
        ns:Print("  " .. line)
    end
end)

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
        commands.help()
    end
end
