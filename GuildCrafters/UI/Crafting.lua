local _, ns = ...

-- Crafting-fanen: find hvem der kan crafte noget. Kategorier til venstre (som i auktionshuset),
-- resultater til højre. Søgefeltet søger i navn og tooltip-tekst (stats, effekter, slot, type).
local UI = ns.UI

local CAT_WIDTH = 180
local CAT_ROW = 18

local state = {
    query = "",
    onlineOnly = false,
    top = nil,          -- valgt kategori (nil = alle)
    sub = nil,          -- valgt underkategori
    crafter = nil,      -- valgt crafter under "By crafter"
    expanded = {},
}

local results, catScroll, footer
local catRows = {}
local catEntries = {}

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

local Refresh

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
        local e = catEntries[offset + i]
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
    FauxScrollFrame_Update(catScroll, #catEntries, #catRows, CAT_ROW)
end

local function CreateCategoryPane(content)
    local height = UI.CONTENT_HEIGHT - 32 - UI.FOOTER_HEIGHT - 4
    catScroll = CreateFrame("ScrollFrame", "GuildCraftersCategoryScroll", content, "FauxScrollFrameTemplate")
    catScroll:SetPoint("TOPLEFT", 0, -32)
    catScroll:SetSize(CAT_WIDTH - 22, height)
    catScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, CAT_ROW, UpdateCategories)
    end)

    for i = 1, math.floor(height / CAT_ROW) do
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
    local divider = content:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.12)
    divider:SetPoint("TOPLEFT", CAT_WIDTH - 2, -32)
    divider:SetSize(1, height)
end

------------------------------------------------------------------------
-- Højre side: resultater
------------------------------------------------------------------------

local function CraftersLine(keys)
    local parts = {}
    for _, key in ipairs(keys) do table.insert(parts, UI.PersonText(key)) end
    return table.concat(parts, ", ")
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
        local name = ns.Compat.ItemName(r.id) or ("item:" .. r.id)
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
    GameTooltip:AddLine("Right-click: whisper a crafter or add to list", 0.5, 0.5, 0.5, true)
    GameTooltip:AddLine("Shift-click: link in chat. Ctrl-click: try it on", 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
end

local function LevelText(details)
    if not details then return "" end
    if details.reqLevel and details.reqLevel > 1 then return "lvl " .. details.reqLevel end
    if details.itemLevel and details.itemLevel > 1 then return "ilvl " .. details.itemLevel end
    return ""
end

-- "On list x2" (grøn) foran niveauet, hvis recipen allerede står på ens craft-liste.
local function RightText(r)
    local level = LevelText(r.details)
    local entry = ns.Data:CraftListFind(r.kind, r.id)
    if not entry then return level end
    local onList = "|cff40ff40On list x" .. entry.qty .. "|r"
    return level ~= "" and (onList .. "  " .. level) or onList
end

local function ResultItems(found)
    local items = {}
    for _, r in ipairs(found) do
        local color = r.details and ns.Compat.QualityColor(r.details.quality) or "|cff71d5ff"
        table.insert(items, {
            kind = r.kind, id = r.id, name = r.name, keys = r.keys,
            icon = ns.Index.Icon(r.kind, r.id),
            title = color .. r.name .. "|r",
            right = RightText(r),
            sub = CraftersLine(r.keys),
            hyperlink = ns.Index.Hyperlink(r.kind, r.id),
            link = function() return ns.Index.Link(r.kind, r.id) end,
        })
    end
    return items
end

local function RecipeMenu(item, _, row)
    local verb = item.kind == "e" and "do " or "craft "
    UI.WhisperMenu(row, item.name, item.keys, "Hi! Could you " .. verb .. UI.ItemRef(item) .. " for me?", {
        { text = "Add to craft list", func = function() AddToList(item) end },
    })
end

------------------------------------------------------------------------
-- Profession-visning: når én person er valgt, grupperes recipes pr. profession (med rank) og kategori,
-- som i spillets eget profession-vindue (brugeren valgte det ud fra tre mockups). Én linje pr. recipe.
------------------------------------------------------------------------

local PROF_ROW = 20
local profScroll, profEmpty
local profRows = {}
local profData = {}
local collapsed = {}        -- ["Tailoring"] / ["Tailoring/Trade Goods"] = true (huskes denne session)

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
local function BuildProfData(found)
    wipe(profData)
    local profs = ns.Index:Professions(state.crafter)
    table.sort(profs, ProfessionOrder)
    local items = ResultItems(found)
    local placed = {}
    for _, prof in ipairs(profs) do
        local groups, order, count = {}, {}, 0
        for _, item in ipairs(items) do
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
            table.insert(profData, { header = "prof", key = prof.name, name = prof.name,
                rank = prof.rank, max = prof.max })
            if not collapsed[prof.name] then
                for _, g in ipairs(order) do
                    local key = prof.name .. "/" .. g.name
                    table.insert(profData, { header = "group", key = key, name = g.name, count = #g.items })
                    if not collapsed[key] then
                        for _, item in ipairs(g.items) do table.insert(profData, item) end
                    end
                end
            end
        end
    end
    return profs
end

local function UpdateProfRows()
    local offset = FauxScrollFrame_GetOffset(profScroll)
    for i, row in ipairs(profRows) do
        local d = profData[offset + i]
        row.header = d and d.header and d or nil
        row.item = d and not d.header and d or nil
        if not d then
            row:Hide()
        else
            if d.header then
                local arrow = collapsed[d.key] and "+ " or "- "
                row.icon:Hide()
                row.add:Hide()
                if d.header == "prof" then
                    row.band:Show()
                    row.label:SetFontObject("GameFontNormal")
                    row.label:SetPoint("LEFT", 4, 0)
                    row.label:SetText(arrow .. d.name:upper())
                    row.right:SetText(string.format("%s/%s", tostring(d.rank or "?"), tostring(d.max or "?")))
                else
                    row.band:Hide()
                    row.label:SetFontObject("GameFontNormalSmall")
                    row.label:SetPoint("LEFT", 14, 0)
                    row.label:SetText(arrow .. d.name)
                    row.right:SetText("|cff808080" .. d.count .. "|r")
                end
            else
                row.band:Hide()
                row.icon:SetTexture(d.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                row.icon:Show()
                row.label:SetFontObject("GameFontHighlightSmall")
                row.label:SetPoint("LEFT", 48, 0)
                row.label:SetText(d.title)
                row.right:SetText(d.right or "")
                row.add:Show()
            end
            row:Show()
        end
    end
    FauxScrollFrame_Update(profScroll, #profData, #profRows, PROF_ROW)
end

local function CreateProfRow(content, index)
    local row = CreateFrame("Button", nil, content)
    row:SetFrameLevel(profScroll:GetFrameLevel() + 2)
    row:SetHeight(PROF_ROW)
    row:SetPoint("TOPLEFT", profScroll, "TOPLEFT", 0, -(index - 1) * PROF_ROW)
    row:SetPoint("RIGHT", profScroll, "RIGHT", 0, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.band = row:CreateTexture(nil, "BACKGROUND")
    row.band:SetAllPoints()
    row.band:SetColorTexture(1, 1, 1, 0.07)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 28, 0)

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

    row.right = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", -30, 0)
    row.right:SetJustifyH("RIGHT")
    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.label:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

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

local function CreateProfessionView(content)
    local height = UI.CONTENT_HEIGHT - 32 - UI.FOOTER_HEIGHT - 4
    profScroll = CreateFrame("ScrollFrame", "GuildCraftersProfessionScroll", content, "FauxScrollFrameTemplate")
    profScroll:SetPoint("TOPLEFT", CAT_WIDTH + 4, -32)
    profScroll:SetPoint("RIGHT", content, "RIGHT", -26, 0)
    profScroll:SetHeight(height)
    profScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, PROF_ROW, UpdateProfRows)
    end)
    for i = 1, math.floor(height / PROF_ROW) do
        profRows[i] = CreateProfRow(content, i)
    end
    profEmpty = content:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    profEmpty:SetPoint("CENTER", profScroll, "CENTER", 13, 0)
    profEmpty:SetWidth(380)
end

local function ShowProfessionView(shown)
    profScroll:SetShown(shown)
    if not shown then
        for _, row in ipairs(profRows) do row:Hide() end
        profEmpty:Hide()
    end
end

local function SelectionLabel()
    if state.crafter then return "recipes " .. ns.Index:DisplayName(state.crafter) .. " can craft" end
    if state.sub then return state.top .. " > " .. state.sub end
    if state.top then return state.top end
    return "all recipes"
end

Refresh = function()
    if not results then return end
    BuildCategoryEntries()
    UpdateCategories()

    local found, unresolved = ns.Index:Find({
        top = state.top, sub = state.sub, crafter = state.crafter,
        query = state.query, onlineOnly = state.onlineOnly,
    })
    local total = #ns.Index:Recipes()
    local empty
    if total == 0 then
        empty = "No recipes yet.\nOpen your profession windows, and wait for data from the guild."
    elseif state.query ~= "" then
        empty = "No matches for \"" .. state.query .. "\" in " .. SelectionLabel() .. "."
    else
        empty = "Nothing here" .. (state.onlineOnly and " with an online crafter." or ".")
    end
    local text
    if state.crafter then
        -- Én person valgt: profession-visningen i stedet for den almindelige liste.
        results:SetShown(false)
        ShowProfessionView(true)
        local profs = BuildProfData(found)
        profEmpty:SetText(empty)
        profEmpty:SetShown(#profData == 0)
        UpdateProfRows()
        local parts = {}
        for _, p in ipairs(profs) do
            table.insert(parts, string.format("%s %s", p.name, tostring(p.rank or "?")))
        end
        text = string.format("%d recipes · %s: %s", #found, ns.Index:DisplayName(state.crafter),
            #parts > 0 and table.concat(parts, ", ") or "no professions")
    else
        ShowProfessionView(false)
        results:SetShown(true)
        results:SetItems(ResultItems(found), empty)
        text = string.format("%d of %d recipes · %s", #found, total, SelectionLabel())
    end
    if unresolved > 0 then text = text .. string.format(" · loading %d items...", unresolved) end
    if not ns.Compat.GuildKey() then text = "|cffff8080Not in a guild|r · " .. text end
    footer:SetText(text)
end

-- Åbner Crafting-fanen med én persons recipes (fra "Show recipes" i rosterens højreklik-menu).
function UI.ShowCrafter(key)
    state.top, state.sub, state.crafter = nil, nil, key
    state.expanded["By crafter"] = true
    state.query = ""        -- OnTextChanged fra SetText nedenfor kommer først næste frame i spillet
    UI:ShowTab("Crafting")
    local box = _G.GuildCraftersCraftingSearch
    if box and box:GetText() ~= "" then box:SetText("") end
    Refresh()
end

local function Build(content)
    UI.CreateSearchBox(content, "GuildCraftersCraftingSearch", 300,
        "Search name or stats, e.g. \"stamina\" or \"fire res\"", function(text)
            state.query = text
            Refresh()
        end)

    local online = UI.CreateCheck(content, "Online crafters only", function(checked)
        state.onlineOnly = checked
        Refresh()
    end)
    online:SetPoint("TOPLEFT", 330, -2)

    CreateCategoryPane(content)

    results = UI.CreateList(content, "GuildCraftersResultScroll", {
        top = -32,
        left = CAT_WIDTH + 4,
        buttons = { { text = "+", tooltip = "Add to craft list (shift-click: add 5)", onClick = AddToList } },
        onRightClick = RecipeMenu,
        onEnter = ShowResultTooltip,
    })
    CreateProfessionView(content)
    footer = UI.CreateFooter(content)
end

UI:AddTab("Crafting", Build, Refresh)
