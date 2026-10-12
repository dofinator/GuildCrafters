local _, ns = ...

-- Måder at åbne vinduet på ud over /gc: minimap-knap og en knap i Blizzards guild-vindue.

local ICON = "Interface\\Icons\\Trade_BlackSmithing"
local LDBIcon = LibStub("LibDBIcon-1.0")

local function SetupMinimap()
    local launcher = LibStub("LibDataBroker-1.1"):NewDataObject("GuildCrafters", {
        type = "launcher",
        icon = ICON,
        OnClick = function() ns.UI:Toggle() end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("GuildCrafters")
            tooltip:AddLine("Click to open", 1, 1, 1)
        end,
    })
    LDBIcon:Register("GuildCrafters", launcher, ns.db.settings.minimap)
end

ns:RegisterCommand("minimap", function()
    local settings = ns.db.settings.minimap
    settings.hide = not settings.hide
    if settings.hide then
        LDBIcon:Hide("GuildCrafters")
        ns:Print("Minimap button hidden. /gc minimap shows it again.")
    else
        LDBIcon:Show("GuildCrafters")
    end
end, "/gc minimap - show/hide the minimap button")

-- Knap i guild-vinduet. GuildFrame findes ved login i Classic-clients; i nyere clients loades
-- guild-UI'et først senere, så vi prøver også igen, når Blizzards addons loader.
local guildButton
local function AttachGuildButton()
    local parent = _G.GuildFrame
    if guildButton or not parent then return end
    guildButton = CreateFrame("Button", "GuildCraftersGuildButton", parent, "UIPanelButtonTemplate")
    guildButton:SetSize(100, 20)
    -- Til venstre for "Show Offline Members" (GuildFrameLFGButton i Classic-clients). Den gamle
    -- placering lå i spillet klemt ned over kolonneoverskrifterne.
    local offline = _G.GuildFrameLFGButtonText or _G.GuildFrameLFGButton
    if offline then
        guildButton:SetPoint("RIGHT", offline, "LEFT", -10, 0)
    else
        guildButton:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -44, -24)
    end
    guildButton:SetText("GuildCrafters")
    guildButton:SetScript("OnClick", function() ns.UI:Toggle() end)
end

ns:On("LOGIN", function()
    SetupMinimap()
    AttachGuildButton()
end)

ns:RegisterEvent("ADDON_LOADED", function(_, name)
    if ns.loggedIn and name:find("^Blizzard_") then
        AttachGuildButton()
    end
end)
