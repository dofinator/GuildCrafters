local _, ns = ...

-- Craft List-fanen: ens personlige liste over ting, man vil have craftet. Hvert item står med sine
-- mats lige under sig i kolonner (Need / You have / Guild has), og med status Ready / Missing.
local UI = ns.UI

local ROW = 20
local LIST_TOP = -52            -- under titel og kolonneoverskrifter

-- Kolonner (x i rækken). Tal højrestilles op mod "right".
local COL = {
    toggle = 2, icon = 20, name = 42,       -- item-række: fold-knap, ikon, navn
    matIcon = 42, matName = 60,             -- mat-række (indrykket under item-navnet)
    qty = 262, buttons = 300,
    need = { right = 344 }, have = { right = 424 }, guild = 444,
}

local rows = {}
local data = {}
local scroll, summary, empty
local Refresh

-- Items, der er Ready, foldes sammen til én linje, så det, man mangler, står tydeligt.
-- Brugeren kan folde ud/ind med knappen; valget huskes her (kun denne session).
local foldOverride = {}     -- ["i123"] = true (foldet) / false (åben)

------------------------------------------------------------------------
-- Data
------------------------------------------------------------------------

-- Andre end en selv, der har en mat: online først (dem kan man spørge nu), derefter flest først.
local function GuildHolders(id)
    local list = {}
    for _, h in ipairs(ns.Index:Holders(id)) do
        if not h.mine then
            table.insert(list, { key = h.key, count = h.bags + h.bank, online = ns.Index:IsOnline(h.key) })
        end
    end
    table.sort(list, function(a, b)
        if a.online ~= b.online then return a.online end
        if a.count ~= b.count then return a.count > b.count end
        return a.key < b.key
    end)
    return list
end

-- "Garrosh 189, Khadgar 140 +4" (højst tre navne + guild bank), eller nil hvis ingen har det.
local function GuildHasText(id)
    local parts, total = {}, 0
    for _, h in ipairs(GuildHolders(id)) do
        total = total + 1
        if #parts < 3 then table.insert(parts, UI.PersonText(h.key) .. " " .. h.count) end
    end
    local bank = ns.Index:GuildBankCount(id)
    if bank > 0 then
        total = total + 1
        if #parts < 3 then table.insert(parts, "|cffffd100Guild bank|r " .. bank) end
    end
    if total == 0 then return nil end
    local text = table.concat(parts, ", ")
    if total > #parts then text = text .. string.format(" |cffaaaaaa+%d|r", total - #parts) end
    return text
end

local function OtherHolders(id)
    local keys = {}
    for _, h in ipairs(GuildHolders(id)) do table.insert(keys, h.key) end
    return keys
end

-- Hvem laver det? Ét navn er nok til overblikket: "You", ellers en af ens egne alts, ellers den
-- første (online først), og "+N" for resten (alle står i tooltippen og i højreklik-menuen).
-- Kun det korte navn: "(alt of X)" gjorde rækken for lang i spillet.
local function CrafterText(keys)
    if #keys == 0 then return "|cffff8080No crafter in the guild|r" end
    local me = ns.Compat.PlayerKey()
    local first, mine
    for _, key in ipairs(keys) do
        if key == me then
            first = key
        elseif not mine and ns.Data:IsMine(key) then
            mine = key
        end
    end
    first = first or mine or keys[1]
    local name
    if first == me then
        name = "|cff40ff40You|r"
    else
        name = (ns.Index:IsOnline(first) and "|cff40ff40" or "|cffaaaaaa") .. ns.Compat.ShortName(first) .. "|r"
    end
    local text = "|cffaaaaaaCrafter:|r " .. name
    if #keys > 1 then text = text .. string.format(" |cffaaaaaa+%d|r", #keys - 1) end
    return text
end

-- En manglende mat, som ingen har, men som nogen kan crafte (fx Bolt of Linen Cloth til en vest):
-- "Bob can craft it" i stedet for "Nobody in the guild".
local function CanCraftText(keys)
    local me = ns.Compat.PlayerKey()
    for _, key in ipairs(keys) do
        if key == me then return "|cff40ff40You|r can craft it" end
    end
    return UI.PersonText(keys[1]) .. " can craft it"
end

-- Én række pr. item efterfulgt af dets mats. "You have" fordeles ovenfra og ned, så to items,
-- der bruger samme mat, ikke begge regner med de samme stk.
local function BuildData()
    wipe(data)
    local pool = {}
    local ready, missingIds, missingCount = 0, {}, 0
    for _, e in ipairs(ns.db.craftList) do
        local name = ns.Index.Name(e.kind, e.id) or "Loading..."
        local item = {
            entry = e, kind = e.kind, id = e.id, name = name,
            title = e.kind == "i" and UI.ItemTitle(e.id, name) or ("|cff71d5ff" .. name .. "|r"),
            icon = ns.Index.Icon(e.kind, e.id),
            keys = ns.Index:Crafters(e.kind, e.id),
            hyperlink = ns.Index.Hyperlink(e.kind, e.id),
            link = function() return ns.Index.Link(e.kind, e.id) end,
        }
        item.crafter = CrafterText(item.keys)
        table.insert(data, item)

        local made, reagents = ns.Index:Reagents(e.kind, e.id)
        if reagents then
            local crafts = math.ceil(e.qty / made)
            local missing = 0
            local mats = {}
            for _, r in ipairs(reagents) do
                if pool[r.id] == nil then pool[r.id] = ns.Index:OwnCount(r.id) end
                local need, have = r.count * crafts, pool[r.id]
                pool[r.id] = math.max(0, have - need)
                if have < need then
                    missing = missing + 1
                    if not missingIds[r.id] then
                        missingIds[r.id] = true
                        missingCount = missingCount + 1
                    end
                end
                local matName = ns.Compat.ItemName(r.id) or "Loading..."
                table.insert(mats, {
                    id = r.id, name = matName, title = UI.ItemTitle(r.id, matName),
                    icon = ns.Compat.ItemIcon(r.id),
                    need = need, have = have, forName = name,
                    guild = GuildHasText(r.id), keys = OtherHolders(r.id),
                    crafters = ns.Index:Crafters("i", r.id),
                    hyperlink = "item:" .. r.id,
                    link = function() return ns.Compat.ItemLink(r.id) end,
                })
            end
            item.missing = missing
            if missing == 0 then ready = ready + 1 end
            local folded = foldOverride[e.kind .. e.id]
            if folded == nil then folded = missing == 0 end
            item.folded = folded
            if not folded then
                for _, m in ipairs(mats) do table.insert(data, m) end
            end
        else
            item.unknown = true
            table.insert(data, { note = "Reagents unknown: the crafter needs the latest GuildCrafters "
                .. "and must open the profession once." })
        end
    end
    return ready, missingCount
end

------------------------------------------------------------------------
-- Tooltips og klik
------------------------------------------------------------------------

local function ItemTooltip(item, row)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(item.hyperlink)
    -- Items får "Crafted by" fra den globale tooltip-hook; enchants skal have det her.
    if item.kind == "e" then
        local names = {}
        for _, key in ipairs(item.keys) do table.insert(names, UI.PersonText(key)) end
        GameTooltip:AddLine("|cff33ff99Crafted by:|r " .. (#names > 0 and table.concat(names, ", ") or "nobody"),
            1, 1, 1, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click: whisper a crafter", 0.5, 0.5, 0.5, true)
    GameTooltip:AddLine("Shift-click: link in chat. Ctrl-click: try it on", 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
end

local function MaterialTooltip(item, row)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(item.hyperlink)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Needed for " .. item.forName, item.need, 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("You have", item.have, 1, 0.82, 0, 1, 1, 1)
    local holders = GuildHolders(item.id)
    if #holders > 0 then GameTooltip:AddLine("In the guild (online first):", 1, 0.82, 0) end
    for _, h in ipairs(holders) do
        GameTooltip:AddDoubleLine("  " .. UI.PersonText(h.key), h.count, 1, 1, 1, 1, 1, 1)
    end
    local bank = ns.Index:GuildBankCount(item.id)
    if bank > 0 then GameTooltip:AddDoubleLine("  Guild bank", bank, 1, 0.82, 0, 1, 1, 1) end
    GameTooltip:AddLine(" ")
    local craftable = item.have < item.need and #item.crafters > 0
    GameTooltip:AddLine((craftable and "Right-click: add it to your craft list or ask for it."
        or "Right-click: ask someone who has it.") .. " Shift-click: link in chat", 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
end

-- Færdige whisper-tekster, fx "Hi! Could you craft 2x [Bolt of Runecloth] for me? I have the mats."
local function CraftMessage(item)
    local qty = item.entry.qty > 1 and (item.entry.qty .. "x ") or ""
    local verb = item.kind == "e" and "do " or "craft "
    local text = "Hi! Could you " .. verb .. qty .. UI.ItemRef(item) .. " for me?"
    if item.missing == 0 then text = text .. " I have the mats." end
    return text
end

-- "Hi! Could you spare 4x [Linen Cloth]? I need it for Bolt of Linen Cloth." (antal = det, man mangler)
local function AskMessage(item)
    local amount = item.have < item.need and (item.need - item.have) or item.need
    return string.format("Hi! Could you spare %dx %s? I need it for %s.", amount, UI.ItemRef(item), item.forName)
end

local function OpenMenu(item, _, row)
    if item.entry then
        UI.WhisperMenu(row, item.name, item.keys, CraftMessage(item))
        return
    end
    -- Mat: mangler man den, og kan nogen crafte den, kan den lægges på listen som sit eget punkt.
    local missing = item.need - item.have
    local extra
    if missing > 0 and #item.crafters > 0 then
        extra = { { text = string.format("Add %dx to craft list", missing), func = function()
            ns.Data:CraftListAdd("i", item.id, missing)
        end } }
    end
    if #item.keys == 0 and extra then
        -- Ingen har den liggende: spørg en, der kan lave den.
        UI.WhisperMenu(row, item.name, item.crafters,
            string.format("Hi! Could you craft %dx %s for me?", missing, UI.ItemRef(item)), extra)
    else
        UI.WhisperMenu(row, "Ask for " .. item.name, item.keys, AskMessage(item), extra)
    end
end

local function OnClick(row, button)
    if row.item and not row.item.note then UI.ItemClick(row.item, button, row, OpenMenu) end
end

------------------------------------------------------------------------
-- Rækker
------------------------------------------------------------------------

local function Text(row, font, justify)
    local fs = row:CreateFontString(nil, "ARTWORK", font)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function SmallButton(row, text, tooltip, x, onClick)
    local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    btn:SetSize(20, 18)
    btn:SetPoint("LEFT", x, 0)
    btn:SetText(text)
    btn:SetScript("OnClick", function() if row.item and row.item.entry then onClick(row.item) end end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(tooltip)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

local function SetQty(item, qty) ns.Data:CraftListSetQty(item.kind, item.id, qty) end

-- +/- ændrer antallet med 1, shift-klik med 5. Shift-minus går ikke under 1 (fjern med x).
local function ChangeQty(item, sign)
    if IsShiftKeyDown() then
        SetQty(item, math.max(1, item.entry.qty + 5 * sign))
    else
        SetQty(item, item.entry.qty + sign)
    end
end

local function ToggleFold(toggle)
    local item = toggle:GetParent().item
    if not item or not item.entry then return end
    foldOverride[item.kind .. item.id] = not item.folded
    Refresh()
end

local function CreateRow(content, index)
    local row = CreateFrame("Button", nil, content)
    row:SetFrameLevel(scroll:GetFrameLevel() + 2)
    row:SetHeight(ROW)
    row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * ROW)
    row:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    -- Lys baggrund på item-rækker, så hver gruppe er nem at se.
    row.band = row:CreateTexture(nil, "BACKGROUND")
    row.band:SetAllPoints()
    row.band:SetColorTexture(1, 1, 1, 0.07)

    -- +/- foran item-rækker: fold mats ind/ud (samme knap som overskrifter i quest-loggen).
    row.toggle = CreateFrame("Button", nil, row)
    row.toggle:SetSize(14, 14)
    row.toggle:SetPoint("LEFT", COL.toggle, 0)
    row.toggle:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
    row.toggle:SetScript("OnClick", ToggleFold)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.name = Text(row, "GameFontHighlight")
    row.qty = Text(row, "GameFontHighlightSmall")
    row.qty:SetPoint("LEFT", COL.qty, 0)
    row.status = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.status:SetPoint("RIGHT", -6, 0)
    row.need = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.need:SetPoint("RIGHT", row, "LEFT", COL.need.right, 0)
    row.have = Text(row, "GameFontHighlightSmall", "RIGHT")
    row.have:SetPoint("RIGHT", row, "LEFT", COL.have.right, 0)
    row.guild = Text(row, "GameFontHighlightSmall")
    row.guild:SetPoint("LEFT", COL.guild, 0)
    row.guild:SetPoint("RIGHT", -6, 0)

    row.buttons = {
        SmallButton(row, "-", "One less (shift-click: 5 less)", COL.buttons, function(item) ChangeQty(item, -1) end),
        SmallButton(row, "+", "One more (shift-click: 5 more)", COL.buttons + 22, function(item) ChangeQty(item, 1) end),
        SmallButton(row, "x", "Remove from list", COL.buttons + 44, function(item) SetQty(item, 0) end),
    }

    row:SetScript("OnClick", OnClick)
    row:SetScript("OnEnter", function(self)
        local item = self.item
        if not item or item.note then return end
        if item.entry then ItemTooltip(item, self) else MaterialTooltip(item, self) end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function ShowItemRow(row, item)
    row.band:Show()
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", COL.icon, 0)
    row.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    row.icon:Show()
    row.name:SetFontObject("GameFontHighlight")
    row.name:SetPoint("LEFT", COL.name, 0)
    row.name:SetWidth(COL.qty - COL.name - 6)
    row.name:SetText(item.title)
    row.qty:SetText("x" .. item.entry.qty)
    if item.unknown then
        row.toggle:Hide()
    else
        local tex = item.folded and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up"
        row.toggle:SetNormalTexture(tex)
        row.toggle:Show()
    end
    if item.unknown then
        row.status:SetText("|cffaaaaaaReagents unknown|r")
    elseif item.missing == 0 then
        row.status:SetText("|cff40ff40Ready|r")
    else
        row.status:SetText(string.format("|cffff6060Missing %d mat%s|r", item.missing,
            item.missing == 1 and "" or "s"))
    end
    row.need:SetText("")
    row.have:SetText("")
    row.guild:SetPoint("RIGHT", row.status, "LEFT", -8, 0)
    row.guild:SetText(item.crafter)    -- samme kolonne som "Guild has" på mat-rækkerne
    for _, b in ipairs(row.buttons) do b:Show() end
end

local function ShowMaterialRow(row, item)
    row.band:Hide()
    row.toggle:Hide()
    row.icon:SetSize(14, 14)
    row.icon:SetPoint("LEFT", COL.matIcon, 0)
    row.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    row.icon:Show()
    row.name:SetFontObject("GameFontHighlightSmall")
    row.name:SetPoint("LEFT", COL.matName, 0)
    row.name:SetWidth(COL.need.right - 40 - COL.matName)
    row.name:SetText(item.title)
    row.qty:SetText("")
    row.status:SetText("")
    row.need:SetText(item.need)
    row.guild:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    local enough = item.have >= item.need
    row.have:SetText((enough and "|cff40ff40" or "|cffff6060") .. item.have .. "|r")
    if item.guild then
        row.guild:SetText(item.guild)
    elseif enough then
        row.guild:SetText("|cffaaaaaa-|r")
    elseif #item.crafters > 0 then
        row.guild:SetText(CanCraftText(item.crafters))
    else
        row.guild:SetText("|cffff8080Nobody in the guild|r")
    end
    for _, b in ipairs(row.buttons) do b:Hide() end
end

local function ShowNoteRow(row, item)
    row.band:Hide()
    row.toggle:Hide()
    row.icon:Hide()
    row.name:SetFontObject("GameFontDisableSmall")
    row.name:SetPoint("LEFT", COL.matName, 0)
    row.name:SetWidth(600)
    row.name:SetText(item.note)
    row.qty:SetText("")
    row.status:SetText("")
    row.need:SetText("")
    row.have:SetText("")
    row.guild:SetText("")
    for _, b in ipairs(row.buttons) do b:Hide() end
end

local function UpdateRows()
    local offset = FauxScrollFrame_GetOffset(scroll)
    for i, row in ipairs(rows) do
        local item = data[offset + i]
        row.item = item
        if not item then
            row:Hide()
        else
            if item.entry then
                ShowItemRow(row, item)
            elseif item.note then
                ShowNoteRow(row, item)
            else
                ShowMaterialRow(row, item)
            end
            row:Show()
        end
    end
    FauxScrollFrame_Update(scroll, #data, #rows, ROW)
end

------------------------------------------------------------------------
-- Opdatering og opbygning
------------------------------------------------------------------------

Refresh = function()
    if not scroll then return end
    local ready, missing = BuildData()
    local count = #ns.db.craftList
    if count == 0 then
        summary:SetText("")
    elseif ready == count then
        summary:SetText(string.format("|cff40ff40All %d ready|r - you have every mat", count))
    else
        summary:SetText(string.format("%d of %d ready - |cffff6060%d mat%s missing|r", ready, count,
            missing, missing == 1 and "" or "s"))
    end
    empty:SetShown(count == 0)
    UpdateRows()
end

local function Header(content, text, x, justifyRight)
    local fs = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    if justifyRight then
        fs:SetPoint("TOPRIGHT", content, "TOPLEFT", x, -36)
    else
        fs:SetPoint("TOPLEFT", x, -36)
    end
    fs:SetText(text)
end

local function Build(content)
    local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -8)
    title:SetText("My craft list")

    summary = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    summary:SetPoint("LEFT", title, "RIGHT", 16, 0)

    local clear = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    clear:SetSize(90, 22)
    clear:SetPoint("TOPRIGHT", -30, -4)
    clear:SetText("Clear list")
    -- Spørg først, så ét forkert klik ikke sletter hele listen.
    StaticPopupDialogs["GUILDCRAFTERS_CLEAR_LIST"] = {
        text = "Remove everything from your craft list?",
        button1 = YES, button2 = NO,
        OnAccept = function() ns.Data:CraftListClear() end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
    clear:SetScript("OnClick", function()
        if #ns.db.craftList > 0 then StaticPopup_Show("GUILDCRAFTERS_CLEAR_LIST") end
    end)

    Header(content, "MATERIAL", COL.matName)
    Header(content, "NEED", COL.need.right, true)
    Header(content, "YOU HAVE", COL.have.right, true)
    Header(content, "GUILD HAS", COL.guild)

    local height = UI.CONTENT_HEIGHT + LIST_TOP - UI.FOOTER_HEIGHT - 4
    scroll = CreateFrame("ScrollFrame", "GuildCraftersCraftListScroll", content, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, LIST_TOP)
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
    empty:SetText("Your craft list is empty.\nClick + next to a recipe in the Crafting tab to add it.")

    local legend = UI.CreateFooter(content)
    legend:SetText("|cff40ff40Green|r = you have enough. |cffff6060Red|r = missing: right-click it to ask who has it. "
        .. "Right-click an item to whisper its crafter.")
end

UI:AddTab("Craft List", Build, Refresh)
