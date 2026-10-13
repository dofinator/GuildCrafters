local _, ns = ...

-- Hovedvinduet: Blizzard-stil, én ramme med faner nederst. Fanerne registrerer sig selv via AddTab.
local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 740, 480
local TAB_WIDTH = 105          -- mindste bredde; bredere hvis en fanetekst ikke kan være der
local TAB_TEXT_MARGIN = 8      -- luft mellem tekst og fanens kanter
UI.CONTENT_HEIGHT = HEIGHT - 40     -- fanernes indholdsområde (se SelectTab)
UI.CONTENT_WIDTH = WIDTH - 24
local tabs = {}         -- { label, build = fn(content), refresh = fn(content), content }
local frame
local currentTab
local FitTabs
local status
local STATUS_WIDTH = 250       -- plads til statuslinjen til højre i fodlinjen (se CreateStatus)

------------------------------------------------------------------------
-- Fælles hjælpere til fanerne
------------------------------------------------------------------------

local ICON = "Interface\\Icons\\"

local PROF_ICONS = {
    ["Alchemy"]        = ICON .. "Trade_Alchemy",
    ["Blacksmithing"]  = ICON .. "Trade_BlackSmithing",
    ["Enchanting"]     = ICON .. "Trade_Engraving",
    ["Engineering"]    = ICON .. "Trade_Engineering",
    ["Herbalism"]      = ICON .. "Trade_Herbalism",
    ["Jewelcrafting"]  = ICON .. "INV_Misc_Gem_01",
    ["Leatherworking"] = ICON .. "Trade_LeatherWorking",
    ["Mining"]         = ICON .. "Trade_Mining",
    ["Skinning"]       = ICON .. "INV_Misc_Pelt_Wolf_01",
    ["Tailoring"]      = ICON .. "Trade_Tailoring",
    ["Cooking"]        = ICON .. "INV_Misc_Food_15",
    ["First Aid"]      = ICON .. "Spell_Holy_SealOfSacrifice",
    ["Fishing"]        = ICON .. "Trade_Fishing",
}

UI.SECONDARY_PROFS = { ["Cooking"] = true, ["First Aid"] = true, ["Fishing"] = true }

function UI.ProfIcon(name)
    return PROF_ICONS[name] or (ICON .. "INV_Misc_QuestionMark")
end

local ROLE_ICONS = {
    TANK   = ICON .. "Ability_Defend",
    HEALER = ICON .. "Spell_Holy_FlashHeal",
    DPS    = ICON .. "Ability_DualWield",
}

UI.ROLE_NAMES = { TANK = "Tank", HEALER = "Healer", DPS = "DPS" }

function UI.RoleIcon(role)
    return ROLE_ICONS[role]
end

function UI.ClassColor(class)
    local c = class and RAID_CLASS_COLORS[class]
    if not c then return 1, 1, 1 end
    return c.r, c.g, c.b
end

function UI.ColorText(text, r, g, b)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, text)
end

-- Itemnavn i kvalitetsfarve, så items ser ens ud i alle faner (og som i resten af spillet).
function UI.ItemTitle(id, name)
    local details = ns.Compat.ItemDetails(id)
    return (details and ns.Compat.QualityColor(details.quality) or "|cffffffff") .. name .. "|r"
end

-- "3 hours ago" ud fra et time()-tidsstempel.
function UI.Ago(timestamp)
    if not timestamp then return "never" end
    local s = time() - timestamp
    if s < 120 then return "just now" end
    if s < 7200 then return string.format("%d min ago", math.floor(s / 60)) end
    if s < 172800 then return string.format("%d hours ago", math.floor(s / 3600)) end
    return string.format("%d days ago", math.floor(s / 86400))
end

------------------------------------------------------------------------
-- Vindue og faner
------------------------------------------------------------------------

function UI:AddTab(label, build, refresh)
    table.insert(tabs, { label = label, build = build, refresh = refresh })
end

local function SavePosition()
    local point, _, relPoint, x, y = frame:GetPoint()
    ns.db.settings.window = { point = point, relPoint = relPoint, x = x, y = y }
end

local function RestorePosition()
    local pos = ns.db.settings.window
    frame:ClearAllPoints()
    if pos then
        frame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    else
        frame:SetPoint("CENTER")
    end
end

function UI:SelectTab(index)
    currentTab = index
    ns.db.settings.lastTab = index
    PanelTemplates_SetTab(frame, index)
    FitTabs()   -- valgt/ikke-valgt fane kan ændre tekstens bredde
    UI.UpdateStatus()
    for i, tab in ipairs(tabs) do
        if i == index then
            if not tab.content then
                tab.content = CreateFrame("Frame", nil, frame)
                tab.content:SetPoint("TOPLEFT", 12, -30)
                tab.content:SetPoint("BOTTOMRIGHT", -12, 10)
                tab.build(tab.content)
            end
            tab.content:Show()
            if tab.refresh then tab.refresh(tab.content) end
        elseif tab.content then
            tab.content:Hide()
        end
    end
end

-- Samme bredde på alle faner, bred nok til den længste tekst. PanelTemplates_TabResize giver teksten
-- fanens bredde minus 2x venstre kant-tekstur; i spillet blev "Crafting" til "Craft..." ved 105 px.
-- Kaldes igen, hver gang en fane vises: templaten ændrer selv bredden ved OnShow, og tekstens
-- bredde kan først måles sikkert, når vinduet er synligt.
FitTabs = function()
    local buttons = {}
    for i = 1, #tabs do buttons[i] = _G["GuildCraftersFrameTab" .. i] end
    if #buttons == 0 or not PanelTemplates_TabResize then return end
    local width = TAB_WIDTH
    for _, button in ipairs(buttons) do
        local text = button:GetFontString()
        local name = button:GetName()
        local left = button.Left or (name and _G[name .. "Left"])
        if text then
            text:SetWidth(0)
            local sides = left and left:GetWidth() * 2 or 40
            width = math.max(width, math.ceil(text:GetStringWidth() + sides) + TAB_TEXT_MARGIN)
        end
    end
    for _, button in ipairs(buttons) do
        PanelTemplates_TabResize(button, 0, width)
        -- Sidste sikring: bliver teksten alligevel afkortet, får den den bredde, den skal bruge.
        local text = button:GetFontString()
        if text and text.IsTruncated and text:IsTruncated() then text:SetWidth(0) end
    end
end

-- Statuslinje (valgt af brugeren ud fra mockups, v0.15): til højre i fodlinjen på alle faner står én
-- kort tekst, "Synced 2 min ago · 7 with addon", som kun skifter, når der sker noget ("Syncing...",
-- "Sync paused (in combat)", ...). Resten står i tooltippen. Teksterne kommer fra Sync.lua.
function UI.UpdateStatus()
    if status and frame:IsShown() then status.text:SetText(ns.Sync:StatusText()) end
end

local function CreateStatus()
    status = CreateFrame("Button", nil, frame)
    status:SetSize(STATUS_WIDTH, 14)
    status:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 11)
    status:SetFrameLevel(frame:GetFrameLevel() + 10)    -- over fanernes indhold, så musen rammer den
    status.text = status:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    status.text:SetAllPoints()
    status.text:SetJustifyH("RIGHT")
    status:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        for _, line in ipairs(ns.Sync:StatusLines()) do
            GameTooltip:AddLine(line, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    status:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- "2 min ago" skal følge med tiden, også når intet andet opdaterer vinduet.
    C_Timer.NewTicker(15, UI.UpdateStatus)
end

local function CreateMainFrame()
    local template = ns.Compat.HasTemplate("BasicFrameTemplateWithInset")
        and "BasicFrameTemplateWithInset" or "BasicFrameTemplate"
    frame = CreateFrame("Frame", "GuildCraftersFrame", UIParent, template)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    RestorePosition()

    local title = frame.TitleText
    if not title then
        title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", 0, -5)
    end
    title:SetText(ns.IS_TEST and "GuildCrafters |cffff8000[TEST]|r" or "GuildCrafters")

    -- ESC lukker vinduet.
    table.insert(UISpecialFrames, "GuildCraftersFrame")

    -- Den nye fane-stil (PanelTabButtonTemplate) har små mellemrum mellem fanerne; den gamle
    -- (CharacterFrameTabButtonTemplate) har gennemsigtige kanter og skal overlappe.
    local tabTemplate, spacing = ns.Compat.TabTemplate()
    for i, tab in ipairs(tabs) do
        local button = CreateFrame("Button", "GuildCraftersFrameTab" .. i, frame, tabTemplate)
        button:SetID(i)
        button:SetText(tab.label)
        if i == 1 then
            button:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 10, 2)
        else
            button:SetPoint("LEFT", _G["GuildCraftersFrameTab" .. (i - 1)], "RIGHT", spacing, 0)
        end
        button:SetScript("OnClick", function(self)
            PlaySound(SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB or 841)
            UI:SelectTab(self:GetID())
        end)
        button:HookScript("OnShow", FitTabs)
    end
    PanelTemplates_SetNumTabs(frame, #tabs)
    FitTabs()
    CreateStatus()

    frame:Hide()
    UI:SelectTab(math.min(ns.db.settings.lastTab or 1, #tabs))
end

function UI:Toggle()
    if not frame then CreateMainFrame() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        UI:SelectTab(currentTab)
    end
end

-- Åbner vinduet på fanen med det navn og returnerer fanens indholdsframe (bruges af /gc debug tour).
function UI:ShowTab(label)
    if not frame then CreateMainFrame() end
    frame:Show()
    for i, tab in ipairs(tabs) do
        if tab.label == label then
            UI:SelectTab(i)
            return tab.content
        end
    end
end

function UI:CurrentTab() return currentTab end

-- Hører en frame (fx ejeren af en tooltip) til addonens vindue?
function UI.Owns(owner)
    if not frame then return false end
    for _ = 1, 20 do
        if type(owner) ~= "table" then return false end
        if owner == frame then return true end
        owner = owner.GetParent and owner:GetParent()
    end
    return false
end

-- Opdatér den synlige fane, når data ændrer sig. Samler bursts af events til én opdatering.
-- I kamp venter opdateringen, til kampen er slut: en opdatering af Crafting-fanen var det eneste i
-- belastningstesten (600 medlemmer, 200 med addonen), der nåede over 200 ms. Det, man selv klikker
-- på, opdaterer stadig med det samme.
local refreshPending = false
local refreshAfterCombat = false
function UI:RequestRefresh()
    if not frame or not frame:IsShown() or refreshPending then return end
    if ns.Compat.InCombat() then
        refreshAfterCombat = true
        return
    end
    refreshPending = true
    C_Timer.After(0.3, function()
        refreshPending = false
        local tab = tabs[currentTab]
        if frame:IsShown() and tab and tab.refresh and tab.content then
            tab.refresh(tab.content)
        end
        UI.UpdateStatus()
    end)
end

ns:On("ROSTER_CHANGED", function() UI:RequestRefresh() end)
ns:On("INDEX_CHANGED", function() UI:RequestRefresh() end)
ns:On("ITEM_NAMES", function() UI:RequestRefresh() end)
ns:On("CRAFTLIST_CHANGED", function() UI:RequestRefresh() end)
ns:On("SYNC_STATUS", function() UI.UpdateStatus() end)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if refreshAfterCombat then
        refreshAfterCombat = false
        UI:RequestRefresh()
    end
end)

-- Fodlinje nederst i en fane (antal, "Not in a guild" osv.). Den højre del af linjen tilhører
-- statuslinjen (CreateStatus), så teksten her må ikke brede sig derind.
function UI.CreateFooter(content)
    local footer = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", 8, 2)
    footer:SetPoint("BOTTOMRIGHT", -(STATUS_WIDTH + 16), 2)
    footer:SetJustifyH("LEFT")
    if footer.SetWordWrap then footer:SetWordWrap(false) end
    return footer
end

UI.FOOTER_HEIGHT = 16
