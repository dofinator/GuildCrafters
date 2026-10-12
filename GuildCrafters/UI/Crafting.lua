local _, ns = ...

-- Crafting-fanen: find hvem der kan crafte noget. Bygget som auktionshuset (brugerens ønske): filterlinje
-- øverst, kategorier til venstre, og resultater til højre med én linje pr. recipe og kolonner, der
-- sorterer ved klik. Søgefeltet søger i navn og tooltip-tekst (stats, effekter, slot, type).
local UI = ns.UI

local CAT_WIDTH = 180
local CAT_ROW = 18
local ROW = 20
local BAR_HEIGHT = 30           -- søgefelt, flueben og Reset
local HINT_HEIGHT = 16          -- "Open Alchemy once ..." (kun når det er relevant)
local HEADER_HEIGHT = 18        -- kolonneoverskrifter over resultaterne
local MAX_CRAFTERS = 2          -- navne i Crafters-kolonnen; resten som "+N" (alle står i tooltippen)

-- Kolonner i en resultatrække (x fra rækkens venstre kant).
local COL = { icon = 4, name = 24, nameWidth = 200, levelRight = 256, crafters = 266 }
local INDENT = 12               -- recipes under en overskrift i profession-visningen

local state = {
    query = "",
    top = nil,          -- valgt kategori (nil = alle)
    sub = nil,          -- valgt underkategori
    crafter = nil,      -- valgt crafter under "By crafter"
    expanded = {},
}
-- Gemmes mellem sessioner (UI.Saved): onlineOnly, usable, sortKey ("name"/"level"/"crafters"), sortDesc.
local saved

local catScroll, scroll, divider, headerBar, hint, empty, footer
local searchBox, usableCheck, onlineCheck
local catRows, rows = {}, {}
local catVisible, rowsVisible = 0, 0
local catEntries, data = {}, {}
local headers = {}
local collapsed = {}        -- ["Tailoring"] / ["Tailoring/Trade Goods"] = true (huskes denne session)
local Refresh

------------------------------------------------------------------------
-- Venstre side: kategorier
------------------------------------------------------------------------

local function BuildCategoryEntries()
    wipe(catEntries)
    local tree = ns.Index:CategoryTree()
    local total = #ns.Index:Recipes()
    table.insert(catEntries, { type = "all", label = "All recipes", count = total })
    for _, top in ipairs(tree) do
        table.insert(catEntries, { type = "top", name = top.name, label = top.name, count = top.count })
        if state.expanded[top.name] then
            for _, sub in ipairs(top.subs) do
                table.insert(catEntries, { type = "sub", top = top.name, name = sub.name,
                    label = sub.name, count = sub.count })
            end
        end
    end
    local crafters = ns.Index:CrafterList()
    table.insert(catEntries, { type = "crafters", label = "By crafter", count = #crafters })
    if state.expanded["By crafter"] then
        for _, c in ipairs(crafters) do
            table.insert(catEntries, { type = "crafter", key = c.key, label = UI.PersonText(c.key),
                count = c.count })
        end
    end
end

local function IsSelected(e)
    if e.type == "all" then return not state.top and not state.crafter end
    if e.type == "top" then return state.top == e.name and not state.sub end
    if e.type == "sub" then return state.top == e.top and state.sub == e.name end
    if e.type == "crafter" then return state.crafter == e.key end
    return false
end

local function SelectEntry(e)
    if e.type == "all" then
        state.top, state.sub, state.crafter = nil, nil, nil
    elseif e.type == "top" then
        if state.top == e.name and not state.sub then
            state.expanded[e.name] = not state.expanded[e.name]
        else
            state.expanded[e.name] = true
        end
        state.top, state.sub, state.crafter = e.name, nil, nil
    elseif e.type == "sub" then
        state.top, state.sub, state.crafter = e.top, e.name, nil
    elseif e.type == "crafters" then
        state.expanded["By crafter"] = not state.expanded["By crafter"]
    elseif e.type == "crafter" then
        state.top, state.sub, state.crafter = nil, nil, e.key
    end
    Refresh()
end

local function UpdateCategories()
    local offset = FauxScrollFrame_GetOffset(catScroll)
    for i, row in ipairs(catRows) do
        local e = i <= catVisible and catEntries[offset + i] or nil
        row.entry = e
        if e then
            local indent = (e.type == "sub" or e.type == "crafter") and 16 or 4
            local arrow = ""
            if e.type == "top" then
                arrow = state.expanded[e.name] and "- " or "+ "
            elseif e.type == "crafters" then
                arrow = state.expanded["By crafter"] and "- " or "+ "
            end
            row.label:SetPoint("LEFT", indent, 0)
            row.label:SetText(arrow .. e.label)
            row.count:SetText(e.count)
            if IsSelected(e) then
                row.selected:Show()
                row.label:SetFontObject("GameFontHighlightSmall")
            else
                row.selected:Hide()
                local child = e.type == "sub" or e.type == "crafter"
                row.label:SetFontObject(child and "GameFontHighlightSmall" or "GameFontNormalSmall")
            end
            row:Show()
        else
            row:Hide()
        end
    end
    FauxScrollFrame_Update(catScroll, #catEntries, catVisible, CAT_ROW)
end

local function CreateCategoryPane(content, maxHeight)
    catScroll = CreateFrame("ScrollFrame", "GuildCraftersCategoryScroll", content, "FauxScrollFrameTemplate")
    catScroll:SetWidth(CAT_WIDTH - 22)
    catScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, CAT_ROW, UpdateCategories)
    end)

    for i = 1, math.floor(maxHeight / CAT_ROW) do
        local row = CreateFrame("Button", nil, content)
        row:SetFrameLevel(catScroll:GetFrameLevel() + 2)
        row:SetHeight(CAT_ROW)
        row:SetPoint("TOPLEFT", catScroll, "TOPLEFT", 0, -(i - 1) * CAT_ROW)
        row:SetPoint("RIGHT", catScroll, "RIGHT", 0, 0)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.selected = row:CreateTexture(nil, "BACKGROUND")
        row.selected:SetAllPoints()
        row.selected:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.selected:SetBlendMode("ADD")
        row.selected:SetVertexColor(1, 0.82, 0, 0.6)
        row.label = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        row.label:SetPoint("LEFT", 4, 0)
        row.label:SetPoint("RIGHT", -28, 0)
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        row.count = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        row.count:SetPoint("RIGHT", -2, 0)
        row:SetScript("OnClick", function(self)
            if self.entry then SelectEntry(self.entry) end
        end)
        catRows[i] = row
    end

    -- Lodret streg mellem kategorier og resultater.
    divider = content:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.12)
    divider:SetWidth(1)
end

------------------------------------------------------------------------
-- Højre side: resultater
------------------------------------------------------------------------

local function CraftersLine(keys)
    local parts = {}
    for _, key in ipairs(keys) do table.insert(parts, UI.PersonText(key)) end
    return table.concat(parts, ", ")
end

-- Crafters-kolonnen: korte navne (online grøn og først), højst MAX_CRAFTERS, resten som "+N".
local function CraftersShort(keys)
    local parts = {}
    for i = 1, math.min(#keys, MAX_CRAFTERS) do
        local color = ns.Index:IsOnline(keys[i]) and "|cff40ff40" or "|cffaaaaaa"
        parts[i] = color .. ns.Compat.ShortName(keys[i]) .. "|r"
    end
    local text = table.concat(parts, ", ")
    if #keys > #parts then text = text .. string.format(" |cffaaaaaa+%d|r", #keys - #parts) end
    return text
end

-- 0 = en anden end en selv er online og kan lave det nu, 1 = ellers (til sortering på Crafters).
local function Availability(keys)
    local me = ns.Compat.PlayerKey()
    for _, key in ipairs(keys) do
        if key ~= me and ns.Index:IsOnline(key) then return 0 end
    end
    return 1
end

-- + lægger 1 på listen; shift-klik lægger 5 på (fx potions eller bolts).
local function AddToList(item)
    local qty = IsShiftKeyDown() and 5 or 1
    ns.Data:CraftListAdd(item.kind, item.id, qty)
    local entry = ns.Data:CraftListFind(item.kind, item.id)
    ns:Print(string.format("%s added to your craft list (x%d).", item.name, entry and entry.qty or qty))
end

-- Reagents i tooltippen, med hvor mange man selv har.
function UI.AddReagentLines(tooltip, kind, id, multiplier)
    local made, reagents = ns.Index:Reagents(kind, id)
    tooltip:AddLine(" ")
    if not reagents then
        tooltip:AddLine("Reagents: unknown (the crafter needs the latest GuildCrafters and must open the profession once)",
            0.6, 0.6, 0.6, true)
        return
    end
    local header = "Reagents"
    if made > 1 then header = header .. string.format(" (makes %d)", made) end
    tooltip:AddLine(header .. ":", 1, 0.82, 0)
    for _, r in ipairs(reagents) do
        local need = r.count * (multiplier or 1)
        local have = ns.Index:OwnCount(r.id)
        local name = ns.Compat.ItemName(r.id) or "Loading..."
        local color = have >= need and "|cff40ff40" or "|cffff6060"
        tooltip:AddDoubleLine(string.format("%dx %s", need, name),
            string.format("%syou have %d|r", color, have), 1, 1, 1, 1, 1, 1)
    end
end

local function ShowResultTooltip(item, row)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(item.hyperlink)
    -- Items får "Crafted by" fra den globale tooltip-hook; enchants skal have det her.
    if item.kind == "e" then
        GameTooltip:AddLine("|cff33ff99Crafted by:|r " .. CraftersLine(item.keys), 1, 1, 1, true)
    end
    UI.AddReagentLines(GameTooltip, item.kind, item.id)
    GameTooltip:AddLine(" ")
    local entry = ns.Data:CraftListFind(item.kind, item.id)
    if entry then
        GameTooltip:AddLine("On your craft list: x" .. entry.qty, 0.25, 1, 0.25)
    end
    GameTooltip:AddLine("Right-click: whisper a crafter or add to list", 0.5, 0.5, 0.5, true)
    GameTooltip:AddLine("Shift-click: link in chat. Ctrl-click: try it on", 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
end

-- Rækker til visning ud fra Index:Find. Lvl = required level (tom for enchants og ting uden krav).
local function ResultItems(found)
    local items = {}
    for _, r in ipairs(found) do
        local color = r.details and ns.Compat.QualityColor(r.details.quality) or "|cff71d5ff"
        local level = r.details and r.details.reqLevel or 0
        table.insert(items, {
            kind = r.kind, id = r.id, name = r.name, keys = r.keys,
            icon = ns.Index.Icon(r.kind, r.id),
            title = color .. r.name .. "|r",
            level = level,
            levelText = level > 1 and tostring(level) or "",
            crafters = CraftersShort(r.keys),
            available = Availability(r.keys),
            hyperlink = ns.Index.Hyperlink(r.kind, r.id),
            link = function() return ns.Index.Link(r.kind, r.id) end,
        })
    end
    return items
end

-- Sortering efter den valgte kolonne; navn (og id) afgør resten, så rækkefølgen altid er den samme.
local function Sort(items)
    local key, desc = saved.sortKey, saved.sortDesc
    table.sort(items, function(a, b)
        local va, vb
        if key == "level" then
            va, vb = a.level, b.level
        elseif key == "crafters" then
            va, vb = a.available, b.available
        else
            va, vb = a.name, b.name
        end
        if va ~= vb then
            if desc then return va > vb end
            return va < vb
        end
        if a.name ~= b.name then return a.name < b.name end
        return a.kind .. a.id < b.kind .. b.id
    end)
end

local function RecipeMenu(item, _, row)
    local verb = item.kind == "e" and "do " or "craft "
    local extra = { { text = "Add to craft list", func = function() AddToList(item) end } }
    if ns.Data:CraftListFind(item.kind, item.id) then
        table.insert(extra, { text = "Remove from craft list", func = function()
            ns.Data:CraftListSetQty(item.kind, item.id, 0)
        end })
    end
    UI.WhisperMenu(row, item.name, item.keys, "Hi! Could you " .. verb .. UI.ItemRef(item) .. " for me?", extra)
end

------------------------------------------------------------------------
-- Profession-visning: når én person er valgt, grupperes recipes pr. profession (med rank) og kategori,
-- som i spillets eget profession-vindue (brugeren valgte det ud fra tre mockups). Samme rækker og
-- kolonner som den almindelige liste, bare med overskrifter imellem.
------------------------------------------------------------------------

-- Overskrift inde i en profession: underkategorien for Consumables og Enchants (Flasks, Bracer ...),
-- ellers hovedkategorien (Armor, Trade Goods ...). Rækkefølge som i auktionshuset.
local function GroupOf(kind, id)
    local top, sub = ns.Index.Category(kind, id)
    if not top then return "Other", 99 end
    local order = 99
    for i, name in ipairs(ns.Index.TOP_ORDER) do
        if name == top then order = i end
    end
    if top == "Consumables" or top == "Enchants" then return sub, order end
    return top, order
end

-- Primære professions først (alfabetisk), derefter Cooking, First Aid og Fishing.
local function ProfessionOrder(a, b)
    local sa, sb = UI.SECONDARY_PROFS[a.name] or false, UI.SECONDARY_PROFS[b.name] or false
    if sa ~= sb then return not sa end
    return a.name < b.name
end

-- Bygger rækkerne: profession-overskrift, kategori-overskrifter og recipes. Returnerer professions.
local function BuildProfData(items)
    wipe(data)
    local profs = ns.Index:Professions(state.crafter)
    table.sort(profs, ProfessionOrder)
    local placed = {}
    for _, prof in ipairs(profs) do
        local groups, order, count = {}, {}, 0
        for _, item in ipairs(items) do     -- items er allerede sorteret, så grupperne bliver det også
            local key = item.kind .. item.id
            if prof.recipes[key] and not placed[key] then
                placed[key] = true
                count = count + 1
                local name, rank = GroupOf(item.kind, item.id)
                if not groups[name] then
                    groups[name] = { name = name, rank = rank, items = {} }
                    table.insert(order, groups[name])
                end
                table.insert(groups[name].items, item)
            end
        end
        if count > 0 then
            table.sort(order, function(a, b)
                if a.rank ~= b.rank then return a.rank < b.rank end
                return a.name < b.name
            end)
            table.insert(data, { header = "prof", key = prof.name, name = prof.name,
                rank = prof.rank, max = prof.max })
            if not collapsed[prof.name] then
                for _, g in ipairs(order) do
                    local key = prof.name .. "/" .. g.name
                    table.insert(data, { header = "group", key = key, name = g.name, count = #g.items })
                    if not collapsed[key] then
                        for _, item in ipairs(g.items) do table.insert(data, item) end
                    end
                end
            end
        end
    end
    return profs
end

local function ShowHeaderRow(row, d)
    local arrow = collapsed[d.key] and "+ " or "- "
    row.icon:Hide()
    row.add:Hide()
    row.right:SetText("")
    row.crafters:SetText("")
    row.onList:SetText("")
    row.label:SetWidth(300)
    if d.header == "prof" then
        row.band:Show()
        row.label:SetFontObject("GameFontNormal")
        row.label:SetPoint("LEFT", 4, 0)
        row.label:SetText(arrow .. d.name:upper())
        row.info:SetText(string.format("%s/%s", tostring(d.rank or "?"), tostring(d.max or "?")))
    else
        row.band:Hide()
        row.label:SetFontObject("GameFontNormalSmall")
        row.label:SetPoint("LEFT", 14, 0)
        row.label:SetText(arrow .. d.name)
        row.info:SetText("|cff808080" .. d.count .. "|r")
    end
end

local function ShowRecipeRow(row, d)
    local indent = state.crafter and INDENT or 0
    row.band:Hide()
    row.icon:SetPoint("LEFT", COL.icon + indent, 0)
    row.icon:SetTexture(d.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    row.icon:Show()
    row.label:SetFontObject("GameFontHighlightSmall")
    row.label:SetPoint("LEFT", COL.name + indent, 0)
    row.label:SetWidth(COL.nameWidth - indent)
    row.label:SetText(d.title)
    row.right:SetText(d.levelText)
    -- Én person er valgt: alle rækker har samme crafter, så kolonnen er tom.
    row.crafters:SetText(state.crafter and "" or d.crafters)
    local entry = ns.Data:CraftListFind(d.kind, d.id)
    row.onList:SetText(entry and ("|cff40ff40x" .. entry.qty .. "|r") or "")
    row.info:SetText("")
    row.add:Show()
end

local function UpdateRows()
    local offset = FauxScrollFrame_GetOffset(scroll)
    for i, row in ipairs(rows) do
        local d = i <= rowsVisible and data[offset + i] or nil
        row.header = d and d.header and d or nil
        row.item = d and not d.header and d or nil
        if not d then
            row:Hide()
        else
            if d.header then ShowHeaderRow(row, d) else ShowRecipeRow(row, d) end
            row:Show()
        end
    end
    FauxScrollFrame_Update(scroll, #data, rowsVisible, ROW)
end

local function CreateRow(content, index)
    local row = CreateFrame("Button", nil, content)
    row:SetFrameLevel(scroll:GetFrameLevel() + 2)
    row:SetHeight(ROW)
    row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * ROW)
    row:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.band = row:CreateTexture(nil, "BACKGROUND")
    row.band:SetAllPoints()
    row.band:SetColorTexture(1, 1, 1, 0.07)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", COL.icon, 0)

    row.add = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.add:SetSize(20, 18)
    row.add:SetPoint("RIGHT", -4, 0)
    row.add:SetText("+")
    row.add:SetScript("OnClick", function() if row.item then AddToList(row.item) end end)
    row.add:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Add to craft list (shift-click: add 5)")
        GameTooltip:Show()
    end)
    row.add:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- "x2" (grøn) lige før +: så mange står der allerede på ens craft-liste.
    row.onList = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.onList:SetPoint("RIGHT", -28, 0)
    row.onList:SetJustifyH("RIGHT")

    -- Overskrifter: rank ("287/375") eller antal helt til højre.
    row.info = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.info:SetPoint("RIGHT", -6, 0)
    row.info:SetJustifyH("RIGHT")

    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", COL.name, 0)
    row.label:SetWidth(COL.nameWidth)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

    row.right = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", row, "LEFT", COL.levelRight, 0)
    row.right:SetJustifyH("RIGHT")

    row.crafters = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.crafters:SetPoint("LEFT", COL.crafters, 0)
    row.crafters:SetPoint("RIGHT", -54, 0)
    row.crafters:SetJustifyH("LEFT")
    row.crafters:SetWordWrap(false)

    -- Overskrifter folder ind/ud ved klik (som kategorierne til venstre); recipes som alle andre items.
    row:SetScript("OnClick", function(self, button)
        if self.header then
            if button == "LeftButton" then
                collapsed[self.header.key] = not collapsed[self.header.key]
                Refresh()
            end
        else
            UI.ItemClick(self.item, button, self, RecipeMenu)
        end
    end)
    row:SetScript("OnEnter", function(self)
        if self.item then ShowResultTooltip(self.item, self) end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

-- Kolonneoverskrifter over resultaterne. Klik sorterer; klik igen vender rækkefølgen.
local function CreateHeaders(content)
    headerBar = CreateFrame("Frame", nil, content)
    headerBar:SetSize(10, HEADER_HEIGHT)
    local function Add(key, label, x, width)
        local header = UI.CreateSortHeader(headerBar, label, width, function()
            if saved.sortKey == key then
                saved.sortDesc = not saved.sortDesc
            else
                saved.sortKey, saved.sortDesc = key, false
            end
            Refresh()
        end)
        header:SetPoint("LEFT", headerBar, "LEFT", x, 0)
        headers[key] = header
    end
    Add("name", "Name", COL.name, 120)
    Add("level", "Lvl", COL.levelRight - 26, 34)
    Add("crafters", "Crafters", COL.crafters, 90)
end

------------------------------------------------------------------------
-- Layout: hintet om uåbnede professions får sin egen linje under filterlinjen, når det vises, og
-- kategorier, overskrifter og resultater rykker tilsvarende ned (med én række færre).
------------------------------------------------------------------------

local layoutHint

local function Layout(showHint)
    if layoutHint == showHint then return end
    layoutHint = showHint
    local top = -BAR_HEIGHT - (showHint and HINT_HEIGHT or 0)
    local catHeight = UI.CONTENT_HEIGHT + top - UI.FOOTER_HEIGHT - 4
    local listHeight = catHeight - HEADER_HEIGHT

    catScroll:SetPoint("TOPLEFT", 0, top)
    catScroll:SetHeight(catHeight)
    catVisible = math.min(#catRows, math.floor(catHeight / CAT_ROW))
    divider:SetPoint("TOPLEFT", CAT_WIDTH - 2, top)
    divider:SetHeight(catHeight)

    headerBar:SetPoint("TOPLEFT", CAT_WIDTH + 4, top)
    scroll:SetPoint("TOPLEFT", CAT_WIDTH + 4, top - HEADER_HEIGHT)
    scroll:SetPoint("TOPRIGHT", -26, top - HEADER_HEIGHT)
    scroll:SetHeight(listHeight)
    rowsVisible = math.min(#rows, math.floor(listHeight / ROW))
end

local function UpdateHint()
    local names = ns.Data:UnscannedProfessions()
    if #names > 0 then
        hint:SetText(string.format("Open %s once, so the guild can see your recipes.", ns.Data.JoinNames(names)))
    end
    hint:SetShown(#names > 0)
    Layout(#names > 0)
end

local function SelectionLabel()
    if state.crafter then return "recipes " .. ns.Index:DisplayName(state.crafter) .. " can craft" end
    if state.sub then return state.top .. " > " .. state.sub end
    if state.top then return state.top end
    return "all recipes"
end

-- "Usable items" som i auktionshuset: kun det, ens level kan bruge (enchants og ting uden krav er med).
local function OnlyUsable(found)
    local level = ns.Data:GetMe().level or 0
    local kept = {}
    for _, r in ipairs(found) do
        if not r.details or (r.details.reqLevel or 0) <= level then table.insert(kept, r) end
    end
    return kept
end

Refresh = function()
    if not scroll then return end
    UpdateHint()
    BuildCategoryEntries()
    UpdateCategories()

    local found, unresolved = ns.Index:Find({
        top = state.top, sub = state.sub, crafter = state.crafter,
        query = state.query, onlineOnly = saved.onlineOnly,
    })
    if saved.usable then found = OnlyUsable(found) end
    local total = #ns.Index:Recipes()
    local text
    if total == 0 then
        text = "No recipes yet.\nOpen your profession windows, and wait for data from the guild."
    elseif #found == 0 and unresolved > 0 then
        -- Item-navne er på vej fra serveren (kold cache lige efter login); "Nothing here" ville være forkert.
        text = "Loading recipes..."
    elseif state.query ~= "" then
        text = "No matches for \"" .. state.query .. "\" in " .. SelectionLabel() .. "."
    elseif saved.onlineOnly or saved.usable then
        text = "Nothing here with these filters. Reset clears them."
    else
        text = "Nothing here."
    end

    local items = ResultItems(found)
    Sort(items)
    for key, header in pairs(headers) do
        if key == saved.sortKey then header:SetSort(saved.sortDesc) else header:SetSort(nil) end
    end
    headers.crafters:SetShown(not state.crafter)

    local status
    if state.crafter then
        -- Én person valgt: grupperet pr. profession og kategori.
        local profs = BuildProfData(items)
        local parts = {}
        for _, p in ipairs(profs) do
            table.insert(parts, string.format("%s %s", p.name, tostring(p.rank or "?")))
        end
        status = string.format("%d recipe%s · %s: %s", #found, #found == 1 and "" or "s",
            ns.Index:DisplayName(state.crafter), #parts > 0 and table.concat(parts, ", ") or "no professions")
    else
        wipe(data)
        for _, item in ipairs(items) do table.insert(data, item) end
        status = string.format("%d of %d recipes · %s", #found, total, SelectionLabel())
    end
    empty:SetText(text)
    empty:SetShown(#data == 0)
    UpdateRows()

    if unresolved > 0 then status = status .. string.format(" · loading %d items...", unresolved) end
    if not ns.Compat.GuildKey() then status = "|cffff8080Not in a guild|r · " .. status end
    footer:SetText(status)
end

-- Sætter søgefeltets tekst. state.query sættes først, fordi OnTextChanged fra SetText først kommer
-- næste frame i spillet.
local function SetQuery(text)
    state.query = text
    if searchBox and searchBox:GetText() ~= text then searchBox:SetText(text) end
end

-- Åbner Crafting-fanen med én persons recipes (fra "Show recipes" i rosterens højreklik-menu).
function UI.ShowCrafter(key)
    state.top, state.sub, state.crafter = nil, nil, key
    state.expanded["By crafter"] = true
    state.query = ""
    UI:ShowTab("Crafting")
    SetQuery("")
    Refresh()
end

-- Åbner Crafting-fanen med en søgning i alle recipes (fra "/gc flask").
function UI.SearchRecipes(text)
    state.top, state.sub, state.crafter = nil, nil, nil
    state.query = text
    UI:ShowTab("Crafting")
    SetQuery(text)
    Refresh()
end

-- Reset som i auktionshuset: rydder søgning, flueben og valgt kategori/person (sorteringen bliver).
local function Reset()
    state.top, state.sub, state.crafter = nil, nil, nil
    saved.onlineOnly, saved.usable = false, false
    usableCheck:SetChecked(false)
    onlineCheck:SetChecked(false)
    searchBox:ClearFocus()
    SetQuery("")
    Refresh()
end

local function Build(content)
    saved = UI.Saved("crafting", { onlineOnly = false, usable = false, sortKey = "name", sortDesc = false })

    searchBox = UI.CreateSearchBox(content, "GuildCraftersCraftingSearch", 270,
        "Search name or stats, e.g. \"fire res\"", function(text)
            state.query = text
            Refresh()
        end)
    UI.AcceptItemLinks(searchBox, function(name)
        state.query = name
        Refresh()
    end)

    usableCheck = UI.CreateCheck(content, "Usable items", function(checked)
        saved.usable = checked
        Refresh()
    end)
    usableCheck:SetPoint("TOPLEFT", 292, -2)
    usableCheck:SetChecked(saved.usable)
    usableCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Usable items")
        GameTooltip:AddLine("Only show what your level can use.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    usableCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    onlineCheck = UI.CreateCheck(content, "Online crafters only", function(checked)
        saved.onlineOnly = checked
        Refresh()
    end)
    onlineCheck:SetPoint("TOPLEFT", 400, -2)
    onlineCheck:SetChecked(saved.onlineOnly)

    local reset = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    reset:SetSize(64, 22)
    reset:SetPoint("TOPRIGHT", -26, -3)
    reset:SetText("Reset")
    reset:SetScript("OnClick", Reset)

    hint = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", 8, -BAR_HEIGHT)
    hint:SetPoint("TOPRIGHT", -8, -BAR_HEIGHT)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(false)
    hint:Hide()

    -- Rækker oprettes til det højeste layout (uden hint); Layout skjuler den nederste, når hintet vises.
    local maxHeight = UI.CONTENT_HEIGHT - BAR_HEIGHT - UI.FOOTER_HEIGHT - 4
    CreateCategoryPane(content, maxHeight)
    CreateHeaders(content)

    scroll = CreateFrame("ScrollFrame", "GuildCraftersResultScroll", content, "FauxScrollFrameTemplate")
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW, UpdateRows)
    end)
    for i = 1, math.floor((maxHeight - HEADER_HEIGHT) / ROW) do
        rows[i] = CreateRow(content, i)
    end
    empty = content:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    empty:SetPoint("CENTER", scroll, "CENTER", 13, 0)
    empty:SetWidth(380)

    footer = UI.CreateFooter(content)
    Layout(false)
end

UI:AddTab("Crafting", Build, Refresh)
