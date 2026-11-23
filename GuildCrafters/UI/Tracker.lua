local _, ns = ...

-- Mats-trackeren (fra v0.17, valgt af brugeren ud fra mockups): et lille vindue, der kan blive stående,
-- mens man farmer, med de mats craft-listen stadig mangler, have/need som i Craft List. Åbnes med
-- knappen "Tracker" i Craft List eller /gc tracker. Kan flyttes, huskes mellem sessioner og bliver
-- stående, når hovedvinduet lukkes. Når alt er samlet, lukker det sig selv.
local UI = ns.UI

local WIDTH = 230
local ROW = 16
local MAX_ROWS = 10             -- resten som "+N more"
local PAD = 10

local tracker
local rows = {}
local more
local pending = false
local Update

local function SavePosition()
    local point, _, relPoint, x, y = tracker:GetPoint()
    ns.db.settings.trackerPos = { point = point, relPoint = relPoint, x = x, y = y }
end

local function Create()
    local template = ns.Compat.HasTemplate("BackdropTemplate") and "BackdropTemplate" or nil
    tracker = CreateFrame("Frame", "GuildCraftersTracker", UIParent, template)
    tracker:SetSize(WIDTH, 40)
    tracker:SetFrameStrata("MEDIUM")
    tracker:SetClampedToScreen(true)
    tracker:SetMovable(true)
    tracker:EnableMouse(true)
    tracker:RegisterForDrag("LeftButton")
    tracker:SetScript("OnDragStart", tracker.StartMoving)
    tracker:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    -- Samme ramme som spillets tooltips: let og ikke i vejen.
    if tracker.SetBackdrop then
        tracker:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        tracker:SetBackdropColor(0, 0, 0, 0.8)
        tracker:SetBackdropBorderColor(0.6, 0.6, 0.6)
    end
    UI.FollowScale(tracker, SavePosition)
    local pos = ns.db.settings.trackerPos
    if pos then
        tracker:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    else
        tracker:SetPoint("RIGHT", UIParent, "RIGHT", -260, 80)
    end

    local title = tracker:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", PAD, -8)
    title:SetText("Still to get")

    local close = CreateFrame("Button", nil, tracker, "UIPanelCloseButton")
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function() UI.ShowTracker(false) end)

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, tracker)
        row:SetSize(WIDTH - 2 * PAD, ROW)
        row:SetPoint("TOPLEFT", PAD, -26 - (i - 1) * ROW)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(14, 14)
        row.icon:SetPoint("LEFT", 0, 0)
        row.count = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.count:SetPoint("RIGHT", 0, 0)
        row.count:SetJustifyH("RIGHT")
        row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 18, 0)
        row.name:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        -- Shift-klik: navnet i auktionshusets søgefelt (eller link i chatten, hvis chatboksen er åben).
        -- Rækken tager musen, så træk i den flytter stadig hele vinduet.
        row:EnableMouse(true)
        row:RegisterForDrag("LeftButton")
        row:SetScript("OnDragStart", function() tracker:StartMoving() end)
        row:SetScript("OnDragStop", function()
            tracker:StopMovingOrSizing()
            SavePosition()
        end)
        row:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and IsShiftKeyDown() and self.id then
                local link = ns.Compat.ItemLink(self.id)
                if link then ns.Compat.InsertLink(link) end
            end
        end)
        row:SetScript("OnEnter", function(self)
            if not self.id then return end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetHyperlink("item:" .. self.id)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Shift-click: search the auction house (or link it in chat)", 0.5, 0.5, 0.5, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[i] = row
    end
    more = tracker:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    more:SetPoint("TOPLEFT", PAD, -26 - MAX_ROWS * ROW)
    tracker:Hide()
end

-- Er der noget på craft-listen, som ikke er craftet endnu?
local function AnythingLeft()
    for _, e in ipairs(ns.db.craftList) do
        if ns.Data.CraftListLeft(e) > 0 then return true end
    end
    return false
end

Update = function()
    if not tracker or not tracker:IsShown() then return end
    local list = UI.CraftListMissing()
    if #list == 0 then
        UI.ShowTracker(false)
        -- En tømt liste er ikke "alt er samlet", og når alt er craftet, har Craft List selv sagt "Done!".
        if AnythingLeft() then ns:Print("You have all the mats for your craft list.") end
        return
    end
    local shown = math.min(#list, MAX_ROWS)
    for i, row in ipairs(rows) do
        local m = list[i]
        if m and i <= shown then
            row.id = m.id
            row.icon:SetTexture(ns.Compat.ItemIcon(m.id))
            row.name:SetText(UI.ItemTitle(m.id, m.name))
            row.count:SetText(string.format("|cffff6060%d|r/%d", m.have, m.need))
            row:Show()
        else
            row:Hide()
        end
    end
    local extra = #list - shown
    more:SetText(extra > 0 and string.format("+%d more in your craft list", extra) or "")
    more:SetShown(extra > 0)
    tracker:SetHeight(26 + shown * ROW + (extra > 0 and ROW or 0) + 8)
end

-- Samler bursts af events (tasker, data fra guilden, item-navne) til én opdatering.
local function RequestUpdate()
    if pending or not tracker or not tracker:IsShown() then return end
    pending = true
    C_Timer.After(0.3, function()
        pending = false
        Update()
    end)
end

function UI.ShowTracker(on)
    if on then
        if #ns.db.craftList == 0 then
            ns:Print("Your craft list is empty. Click + next to a recipe in the Crafting tab to add it.")
            return
        end
        if #UI.CraftListMissing() == 0 then
            ns:Print(AnythingLeft() and "You have all the mats for your craft list."
                or "Everything on your craft list is crafted.")
            return
        end
    end
    ns.db.settings.tracker = on and true or false
    if not tracker then
        if not on then return end
        Create()
    end
    tracker:SetShown(on)
    Update()
end

function UI.ToggleTracker()
    UI.ShowTracker(not (tracker and tracker:IsShown()))
end

-- Trackeren åbner igen ved login, hvis den var åben sidst (efter et øjeblik, så tasker og navne er klar).
ns:On("LOGIN", function()
    if ns.db and ns.db.settings.tracker then
        C_Timer.After(5, function()
            if ns.db.settings.tracker and #UI.CraftListMissing() > 0 then UI.ShowTracker(true) end
        end)
    end
end)

ns:On("CRAFTLIST_CHANGED", RequestUpdate)
ns:On("INDEX_CHANGED", RequestUpdate)
ns:On("ITEM_NAMES", RequestUpdate)
ns:RegisterEvent("BAG_UPDATE_DELAYED", RequestUpdate)

ns:RegisterCommand("tracker", function() UI.ToggleTracker() end,
    "/gc tracker - small window with the mats your craft list still needs")
