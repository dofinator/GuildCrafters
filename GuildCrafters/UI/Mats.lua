local _, ns = ...

-- Mats-fanen: hvem har hvilke crafting-mats (tasker, bank, guild bank)?
local UI = ns.UI
local MAX_RESULTS = 300

local query = ""
local onlyCraftList = false
local list, countText, shareCheck

-- De mats, ens craft-liste skal bruge: { [itemID] = true }.
local function CraftListMats()
    local set = {}
    for _, e in ipairs(ns.db.craftList) do
        local _, reagents = ns.Index:Reagents(e.kind, e.id)
        for _, r in ipairs(reagents or {}) do set[r.id] = true end
    end
    return set
end

local function HolderText(h)
    local total = h.bags + h.bank
    local where
    if h.bags > 0 and h.bank > 0 then
        where = string.format("%d bags, %d bank", h.bags, h.bank)
    elseif h.bank > 0 then
        where = "bank"
    else
        where = "bags"
    end
    return string.format("%s %d (%s)", UI.PersonText(h.key), total, where)
end

local function Line(id)
    local parts = {}
    for _, h in ipairs(ns.Index:Holders(id)) do
        table.insert(parts, HolderText(h))
    end
    local bank = ns.Index:GuildBankCount(id)
    if bank > 0 then
        table.insert(parts, "|cffffd100Guild bank|r " .. bank)
    end
    return table.concat(parts, " · ")
end

local function ShowTooltip(item, row)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(item.title)
    for _, h in ipairs(ns.Index:Holders(item.id)) do
        GameTooltip:AddDoubleLine(HolderText(h), UI.Ago(h.time), 1, 1, 1, 0.5, 0.5, 0.5)
    end
    local bank, bankTime = ns.Index:GuildBankCount(item.id)
    if bank > 0 then
        GameTooltip:AddDoubleLine("Guild bank " .. bank, UI.Ago(bankTime), 1, 0.82, 0, 0.5, 0.5, 0.5)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click: ask someone who has it. Shift-click: link in chat", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function Refresh()
    if not list then return end
    shareCheck:SetChecked(ns.db.settings.shareMats)

    local needle = query:lower()
    local wanted = onlyCraftList and CraftListMats()
    local results = {}
    for _, id in ipairs(ns.Index:AllMats()) do
        local name = ns.Compat.ItemName(id)
        if (not wanted or wanted[id]) and (needle == "" or (name and name:lower():find(needle, 1, true))) then
            table.insert(results, { id = id, name = name or ("item:" .. id) })
        end
    end
    table.sort(results, function(a, b) return a.name < b.name end)

    local items = {}
    for i = 1, math.min(#results, MAX_RESULTS) do
        local r = results[i]
        local keys = {}
        for _, h in ipairs(ns.Index:Holders(r.id)) do table.insert(keys, h.key) end
        table.insert(items, {
            id = r.id, name = r.name,
            icon = ns.Compat.ItemIcon(r.id),
            title = UI.ItemTitle(r.id, r.name),
            sub = Line(r.id),
            hyperlink = "item:" .. r.id,
            link = function() return ns.Compat.ItemLink(r.id) end,
            keys = keys,
        })
    end

    countText:SetText(string.format("%d mats · bags and bank are shared by those who turned on \"Share my mats\"",
        #results))
    local emptyText
    if onlyCraftList and #ns.db.craftList == 0 then
        emptyText = "Your craft list is empty."
    elseif onlyCraftList then
        emptyText = "Nobody in the guild has the mats for your craft list (that we know of)."
    elseif query ~= "" then
        emptyText = "Nobody has that mat."
    else
        emptyText = "No mats yet. Turn on \"Share my mats\", and open your bank (and guild bank)."
    end
    list:SetItems(items, emptyText)
end

local function Build(content)
    UI.CreateSearchBox(content, "GuildCraftersMatsSearch", 200, "Search mats, e.g. \"thorium\"", function(text)
        query = text
        Refresh()
    end)

    shareCheck = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    shareCheck:SetSize(24, 24)
    shareCheck:SetPoint("TOPLEFT", 225, -2)
    local label = shareCheck:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("LEFT", shareCheck, "RIGHT", 2, 0)
    label:SetText("Share my mats")
    shareCheck:SetScript("OnClick", function(self)
        ns.Mats:SetSharing(self:GetChecked())
        Refresh()
    end)
    shareCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Share my mats")
        GameTooltip:AddLine("The guild can see the crafting mats in your bags and bank.", 1, 1, 1, true)
        GameTooltip:AddLine("The guild bank is always shared.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    shareCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local craftListCheck = UI.CreateCheck(content, "Only my craft list", function(checked)
        onlyCraftList = checked
        Refresh()
    end)
    craftListCheck:SetPoint("TOPLEFT", 360, -2)

    countText = UI.CreateFooter(content)

    list = UI.CreateList(content, "GuildCraftersMatsScroll", {
        top = -32,
        onRightClick = function(item, _, row)
            UI.WhisperMenu(row, "Ask for " .. item.name, item.keys,
                "Hi! Do you have any " .. UI.ItemRef(item) .. " to spare?")
        end,
        onEnter = ShowTooltip,
    })
end

UI:AddTab("Mats", Build, Refresh)
