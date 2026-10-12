local _, ns = ...

-- Tilføjer "Crafted by" og "Guild has" på item-tooltips.
local MAX_NAMES = 4

local function Colored(key)
    local name = ns.Compat.ShortName(key)
    if ns.Index:IsOnline(key) then
        return "|cff40ff40" .. name .. "|r"
    end
    return "|cffaaaaaa" .. name .. "|r"
end

local function Join(parts, total)
    local text = table.concat(parts, ", ")
    if total > #parts then
        text = text .. string.format(" (+%d)", total - #parts)
    end
    return text
end

local function AddCrafters(tooltip, itemID)
    local keys = ns.Index:Crafters("i", itemID)
    if #keys == 0 then return false end
    local parts = {}
    for i = 1, math.min(#keys, MAX_NAMES) do
        parts[i] = Colored(keys[i])
    end
    tooltip:AddLine("|cff33ff99Crafted by:|r " .. Join(parts, #keys), 1, 1, 1, true)
    return true
end

-- Hvem i guilden har tingen (delte mats + guild bank). Den char, man selv spiller, er ikke med: det
-- står allerede i taskerne. Ens alts er med.
local function AddHolders(tooltip, itemID)
    local me = ns.Compat.PlayerKey()
    local list = {}
    for _, h in ipairs(ns.Index:Holders(itemID)) do
        if h.key ~= me then table.insert(list, h) end
    end
    local bank = ns.Index:GuildBankCount(itemID)
    if #list == 0 and bank == 0 then return false end

    local parts = {}
    for i = 1, math.min(#list, MAX_NAMES) do
        local h = list[i]
        parts[i] = Colored(h.key) .. " " .. (h.bags + h.bank)
    end
    local total = #list
    if bank > 0 then
        table.insert(parts, "Guild bank " .. bank)
        total = total + 1
    end
    tooltip:AddLine("|cff33ff99Guild has:|r " .. Join(parts, total), 1, 1, 1, true)
    return true
end

ns.Compat.HookItemTooltip(function(tooltip, itemID)
    if not ns.db then return end
    local added = AddCrafters(tooltip, itemID)
    added = AddHolders(tooltip, itemID) or added
    if added then tooltip:Show() end
end)
