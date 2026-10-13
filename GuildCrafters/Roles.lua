local _, ns = ...

local Roles = {}
ns.Roles = Roles

-- Rolle pr. class og talent-tab. Tvetydige specs (feral, ret) gættes som DPS; brug /gc role.
local ROLE_BY_TAB = {
    WARRIOR = { "DPS", "DPS", "TANK" },
    PALADIN = { "HEALER", "TANK", "DPS" },
    HUNTER  = { "DPS", "DPS", "DPS" },
    ROGUE   = { "DPS", "DPS", "DPS" },
    PRIEST  = { "HEALER", "HEALER", "DPS" },
    SHAMAN  = { "DPS", "DPS", "HEALER" },
    MAGE    = { "DPS", "DPS", "DPS" },
    WARLOCK = { "DPS", "DPS", "DPS" },
    DRUID   = { "DPS", "DPS", "HEALER" },
}

-- Spec-navne er statiske (enUS), fordi andre classes' talent-træer ikke kan slås op via API'et.
local SPEC_NAMES = {
    WARRIOR = { "Arms", "Fury", "Protection" },
    PALADIN = { "Holy", "Protection", "Retribution" },
    HUNTER  = { "Beast Mastery", "Marksmanship", "Survival" },
    ROGUE   = { "Assassination", "Combat", "Subtlety" },
    PRIEST  = { "Discipline", "Holy", "Shadow" },
    SHAMAN  = { "Elemental", "Enhancement", "Restoration" },
    MAGE    = { "Arcane", "Fire", "Frost" },
    WARLOCK = { "Affliction", "Demonology", "Destruction" },
    DRUID   = { "Balance", "Feral", "Restoration" },
}

Roles.VALID = { TANK = true, HEALER = true, DPS = true }

function Roles.SpecName(class, tab)
    return class and tab and SPEC_NAMES[class] and SPEC_NAMES[class][tab]
end

-- Talent-tab med flest point, eller nil hvis der ikke er brugt nogen point endnu.
local function GuessSpecTab()
    local bestTab, bestPoints = nil, 0
    for tab = 1, ns.Compat.GetNumTalentTabs() do
        local points = ns.Compat.GetTalentTabPoints(tab)
        if points > bestPoints then
            bestTab, bestPoints = tab, points
        end
    end
    return bestTab
end

function Roles:Refresh()
    local me = ns.Data:GetMe()
    local specTab = GuessSpecTab()
    local role = specTab and me.class and ROLE_BY_TAB[me.class] and ROLE_BY_TAB[me.class][specTab]
    -- Mainline har ingen talent-tabs; har klienten specializations, giver den rollen direkte.
    if not specTab then role = ns.Compat.SpecRole() end
    if me.specTab ~= specTab or me.role ~= role then
        me.specTab, me.role = specTab, role
        ns.Data:MeChanged("info")
    end
end

-- Den rolle andre ser: manuel override vinder over gættet.
function Roles:MyRole()
    local me = ns.Data:GetMe()
    return me.roleOverride or me.role
end

function Roles:SetOverride(role)
    local me = ns.Data:GetMe()
    me.roleOverride = role
    ns.Data:MeChanged("info")
end

ns:On("LOGIN", function()
    Roles:Refresh()
    -- Talent-data er ikke altid klar ved login; tjek igen før første HELLO sendes.
    C_Timer.After(3, function() Roles:Refresh() end)
end)
ns:RegisterEvent("CHARACTER_POINTS_CHANGED", function() Roles:Refresh() end)
ns:RegisterEvent("PLAYER_TALENT_UPDATE", function() Roles:Refresh() end)
ns:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function() Roles:Refresh() end)
ns:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", function() Roles:Refresh() end)

ns:RegisterCommand("role", function(arg)
    arg = arg:upper()
    if arg == "HEAL" then arg = "HEALER" end
    if arg == "AUTO" then
        Roles:SetOverride(nil)
    elseif Roles.VALID[arg] then
        Roles:SetOverride(arg)
    else
        ns:Print(ns.Plain("Usage: /gc role tank|healer|dps|auto"))
        return
    end
    local me = ns.Data:GetMe()
    ns:Print("Role: " .. tostring(Roles:MyRole() or "unknown")
        .. (me.roleOverride and " (manual)" or " (auto)"))
end, "/gc role tank|healer|dps|auto - set your role")
