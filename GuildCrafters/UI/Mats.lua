local _, ns = ...

-- Mats-fanen: hvem i guilden har hvilke crafting-mats (tasker, bank, guild bank)?
-- Samme udseende som Crafting (valgt af brugeren ud fra en før/efter-skitse, v0.16): én linje pr. mat
-- med kolonnerne Name | Who has it, og overskrifter, der sorterer ved klik. Opdelingen i tasker og bank
-- og hvornår det sidst er opdateret, står i tooltippen. Den char, man selv spiller, er ikke med: det
-- står allerede i taskerne (samme regel som "Guild has" i item-tooltips). Ens alts er med.
local UI = ns.UI

local ROW = 20
local BAR_HEIGHT = 30           -- søgefelt og flueben
local HEADER_HEIGHT = 18        -- kolonneoverskrifter
local MAX_HOLDERS = 4           -- navne på en række; resten som "+N" (alle står i tooltippen)
local COL = { icon = 4, name = 24, nameWidth = 230, holders = 264 }

local query = ""
local filters               -- gemmes mellem sessioner (UI.Saved): onlyCraftList, sortKey, sortDesc
local rows, data, headers = {}, {}, {}
local scroll, empty, countText, shareCheck
local Refresh

-- De mats, ens craft-liste skal bruge: { [itemID] = true }.
local function CraftListMats()
    local set = {}
    for _, e in ipairs(ns.db.craftList) do
        local _, reagents = ns.Index:Reagents(e.kind, e.id)
        for _, r in ipairs(reagents or {}) do set[r.id] = true end
    end
    return set
end

-- Alle andre end den char, man spiller, der har en mat (flest først, som Index giver dem).
local function OtherHolders(id)
    local me = ns.Compat.PlayerKey()
    local list = {}
    for _, h in ipairs(ns.Index:Holders(id)) do
        if h.key ~= me then table.insert(list, h) end
    end
    return list
end

-- Rækkens tekst: "Garrosh 129, Uther 3 +1 · Guild bank 200". Korte navne, online i grøn.
local function HoldersText(holders, bank)
    local parts = {}
    for i = 1, math.min(#holders, MAX_HOLDERS) do
        local h = holders[i]
        local color = ns.Index:IsOnline(h.key) and "|cff40ff40" or "|cffaaaaaa"
        parts[i] = string.format("%s%s|r %d", color, ns.Compat.ShortName(h.key), h.bags + h.bank)
    end
    local text = table.concat(parts, ", ")
    if #holders > #parts then text = text .. string.format(" |cffaaaaaa+%d|r", #holders - #parts) end
    if bank > 0 then
        text = text .. (text ~= "" and " · " or "") .. "|cffffd100Guild bank|r " .. bank
    end
    return text
end

-- Tooltippen har det hele: fulde navne, tasker/bank og hvornår det sidst er opdateret.
local function HolderLine(h)
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

local function ShowTooltip(item, row)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(item.title)
    for _, h in ipairs(item.holders) do
        GameTooltip:AddDoubleLine(HolderLine(h), UI.Ago(h.time), 1, 1, 1, 0.5, 0.5, 0.5)
    end
    local bank, bankTime = ns.Index:GuildBankCount(item.id)
    if bank > 0 then
        GameTooltip:AddDoubleLine("Guild bank " .. bank, UI.Ago(bankTime), 1, 0.82, 0, 0.5, 0.5, 0.5)
    end
    local own = ns.Compat.ItemCount(item.id)
    if own > 0 then
        GameTooltip:AddDoubleLine("You have", own, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click: ask someone who has it. Shift-click: link in chat", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function OpenMenu(item, _, row)
    UI.WhisperMenu(row, "Ask for " .. item.name, item.keys,
        "Hi! Do you have any " .. UI.ItemRef(item) .. " to spare?")
end

------------------------------------------------------------------------
-- Rækker
------------------------------------------------------------------------

local function UpdateRows()
    local offset = FauxScrollFrame_GetOffset(scroll)
    for i, row in ipairs(rows) do
        local item = data[offset + i]
        row.item = item
        if item then
            row.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.label:SetText(item.title)
            row.holders:SetText(item.text)
            row:Show()
        else
            row:Hide()
        end
    end
    FauxScrollFrame_Update(scroll, #data, #rows, ROW)
end

local function CreateRow(content, index)
    local row = CreateFrame("Button", nil, content)
    row:SetFrameLevel(scroll:GetFrameLevel() + 2)
    row:SetHeight(ROW)
    row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * ROW)
    row:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", COL.icon, 0)

    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", COL.name, 0)
    row.label:SetWidth(COL.nameWidth)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

    row.holders = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.holders:SetPoint("LEFT", COL.holders, 0)
    row.holders:SetPoint("RIGHT", -6, 0)
    row.holders:SetJustifyH("LEFT")
    row.holders:SetWordWrap(false)

    row:SetScript("OnClick", function(self, button) UI.ItemClick(self.item, button, self, OpenMenu) end)
    row:SetScript("OnEnter", function(self)
        if self.item then ShowTooltip(self.item, self) end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

-- Klik på en overskrift sorterer; klik igen vender rækkefølgen. "Who has it" sorterer efter, hvor
-- meget der er i alt (mest først ved første klik), uden at tallet vises.
local function CreateHeaders(content)
    local bar = CreateFrame("Frame", nil, content)
    bar:SetSize(10, HEADER_HEIGHT)
    bar:SetPoint("TOPLEFT", 0, -BAR_HEIGHT)
    local function Add(key, label, x, width, firstDesc)
        local header = UI.CreateSortHeader(bar, label, width, function()
            if filters.sortKey == key then
                filters.sortDesc = not filters.sortDesc
            else
                filters.sortKey, filters.sortDesc = key, firstDesc
            end
            Refresh()
        end)
        header:SetPoint("LEFT", bar, "LEFT", x, 0)
        headers[key] = header
    end
    Add("name", "Name", COL.name, 120, false)
    Add("amount", "Who has it", COL.holders, 110, true)
end

local function Sort(items)
    local key, desc = filters.sortKey, filters.sortDesc
    table.sort(items, function(a, b)
        if key == "amount" and a.total ~= b.total then
            if desc then return a.total > b.total end
            return a.total < b.total
        end
        if a.name ~= b.name then
            if desc and key == "name" then return a.name > b.name end
            return a.name < b.name
        end
        return a.id < b.id
    end)
end

------------------------------------------------------------------------
-- Opdatering og opbygning
------------------------------------------------------------------------

Refresh = function()
    if not scroll then return end
    shareCheck:SetChecked(ns.db.settings.shareMats)

    local needle = query:lower()
    local onlyCraftList = filters.onlyCraftList
    local wanted = onlyCraftList and CraftListMats()
    wipe(data)
    for _, id in ipairs(ns.Index:AllMats()) do
        local name = ns.Compat.ItemName(id)
        if (not wanted or wanted[id]) and (needle == "" or (name and name:lower():find(needle, 1, true))) then
            local holders = OtherHolders(id)
            local bank = ns.Index:GuildBankCount(id)
            if #holders > 0 or bank > 0 then
                local keys, total = {}, bank
                for _, h in ipairs(holders) do
                    table.insert(keys, h.key)
                    total = total + h.bags + h.bank
                end
                name = name or "Loading..."
                table.insert(data, {
                    id = id, name = name, total = total, holders = holders, keys = keys,
                    icon = ns.Compat.ItemIcon(id),
                    title = UI.ItemTitle(id, name),
                    text = HoldersText(holders, bank),
                    hyperlink = "item:" .. id,
                    link = function() return ns.Compat.ItemLink(id) end,
                })
            end
        end
    end
    Sort(data)
    for key, header in pairs(headers) do
        if key == filters.sortKey then header:SetSort(filters.sortDesc) else header:SetSort(nil) end
    end

    countText:SetText(string.format("%d mat%s · from members with \"Share my mats\" on",
        #data, #data == 1 and "" or "s"))
    local text
    if onlyCraftList and #ns.db.craftList == 0 then
        text = "Your craft list is empty."
    elseif onlyCraftList then
        text = "Nobody in the guild has the mats for your craft list (that we know of)."
    elseif query ~= "" then
        text = "Nobody has that mat."
    else
        text = "Nobody else in the guild shares mats yet.\nTurn on \"Share my mats\", so the others can see yours."
    end
    empty:SetText(text)
    empty:SetShown(#data == 0)
    UpdateRows()
end

local function Build(content)
    filters = UI.Saved("mats", { onlyCraftList = false, sortKey = "name", sortDesc = false })

    local box = UI.CreateSearchBox(content, "GuildCraftersMatsSearch", 200, "Search mats, e.g. \"thorium\"",
        function(text)
            query = text
            Refresh()
        end)
    UI.AcceptItemLinks(box, function(name)
        query = name
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
        filters.onlyCraftList = checked
        Refresh()
    end)
    craftListCheck:SetPoint("TOPLEFT", 360, -2)
    craftListCheck:SetChecked(filters.onlyCraftList)

    countText = UI.CreateFooter(content)
    CreateHeaders(content)

    local top = -BAR_HEIGHT - HEADER_HEIGHT
    local height = UI.CONTENT_HEIGHT + top - UI.FOOTER_HEIGHT - 4
    scroll = CreateFrame("ScrollFrame", "GuildCraftersMatsScroll", content, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, top)
    scroll:SetPoint("RIGHT", content, "RIGHT", -26, 0)
    scroll:SetHeight(height)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW, UpdateRows)
    end)
    for i = 1, math.floor(height / ROW) do
        rows[i] = CreateRow(content, i)
    end

    empty = content:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    empty:SetPoint("CENTER", scroll, "CENTER", 13, 0)
    empty:SetWidth(380)
end

UI:AddTab("Mats", Build, Refresh)
