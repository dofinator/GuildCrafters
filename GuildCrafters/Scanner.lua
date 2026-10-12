local _, ns = ...

local Scanner = {}
ns.Scanner = Scanner

local readers = {
    trade = function() return ns.Compat.ReadTradeSkill() end,
    craft = function() return ns.Compat.ReadCraft() end,
}

local pending = {}
local expandedThisOpen = {}

local function Run(kind)
    pending[kind] = nil
    local scan = readers[kind]()
    if not scan then return end

    -- Lukkede kategorier skjuler recipes. Fold alt ud én gang pr. åbning; det udløser et nyt
    -- UPDATE-event og dermed et nyt scan.
    if scan.collapsed and not expandedThisOpen[kind] then
        expandedThisOpen[kind] = true
        ns.Compat.ExpandAll(kind)
    end

    local added = ns.Data:MergeProfession(scan)
    if added > 0 then
        ns:Print(string.format("%s: %d new recipes saved.", scan.name, added))
    end
end

-- UPDATE-events kommer i bursts, så scan først når listen har fået ro.
local function Schedule(kind)
    if pending[kind] then return end
    pending[kind] = true
    C_Timer.After(0.3, function() Run(kind) end)
end

ns:RegisterEvent("TRADE_SKILL_SHOW", function()
    expandedThisOpen.trade = nil
    Schedule("trade")
end)
ns:RegisterEvent("TRADE_SKILL_UPDATE", function() Schedule("trade") end)
-- Mainline (retail / WoW Forever) melder listen klar med disse events i stedet for TRADE_SKILL_UPDATE.
-- Events, klienten ikke kender, springes over af ns:RegisterEvent.
ns:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function() Schedule("trade") end)
ns:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED", function() Schedule("trade") end)

ns:RegisterEvent("CRAFT_SHOW", function()
    expandedThisOpen.craft = nil
    Schedule("craft")
end)
ns:RegisterEvent("CRAFT_UPDATE", function() Schedule("craft") end)
