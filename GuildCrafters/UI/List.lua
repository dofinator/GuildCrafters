local _, ns = ...

-- Liste med to linjer pr. række: ikon + titel (+ tekst til højre) øverst, en grå linje under.
-- Items: { icon, title, right, sub, hyperlink, link = fn() }
local UI = ns.UI

local function IconEnter(icon)
    local item = icon:GetParent().item
    if not item or not item.hyperlink then return end
    GameTooltip:SetOwner(icon, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(item.hyperlink)
    GameTooltip:Show()
end

local function HideTooltip() GameTooltip:Hide() end

-- Klik på et item som i resten af spillet: shift = link i chatten, ctrl = prøv det på (dressing room,
-- som i auktionshuset), højreklik = menu. Et almindeligt venstreklik gør ingenting (brugeren syntes,
-- at en menu på venstreklik var irriterende).
function UI.ItemClick(item, button, row, onRightClick)
    if not item then return end
    if IsShiftKeyDown() then
        local link = item.link and item.link()
        if link then ns.Compat.InsertLink(link) end
    elseif IsControlKeyDown() then
        local link = item.link and item.link()
        if link then ns.Compat.DressUp(link) end
    elseif button == "RightButton" and onRightClick then
        onRightClick(item, button, row)
    end
end

-- opts: top, left, height (ellers til bunden over footeren), rowHeight, onRightClick(item, button, row),
--       onEnter(item, row)
function UI.CreateList(content, name, opts)
    local list = { items = {}, rows = {} }
    local rowHeight = opts.rowHeight or 36
    local top = opts.top or 0
    local height = opts.height or (UI.CONTENT_HEIGHT + top - UI.FOOTER_HEIGHT - 4)

    local scroll = CreateFrame("ScrollFrame", name, content, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", opts.left or 0, top)
    scroll:SetPoint("RIGHT", content, "RIGHT", -26, 0)
    scroll:SetHeight(height)
    list.scroll = scroll

    list.empty = content:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    list.empty:SetPoint("CENTER", scroll, "CENTER", 13, 0)
    list.empty:SetWidth(380)

    local function Update()
        local offset = FauxScrollFrame_GetOffset(scroll)
        for i, row in ipairs(list.rows) do
            local item = list.items[offset + i]
            row.item = item
            if item then
                row.icon.texture:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                row.title:SetText(item.title)
                row.right:SetText(item.right or "")
                row.sub:SetText(item.sub or "")
                row:Show()
            else
                row:Hide()
            end
        end
        FauxScrollFrame_Update(scroll, #list.items, #list.rows, rowHeight)
    end
    list.Update = Update

    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, rowHeight, Update)
    end)

    for i = 1, math.floor(height / rowHeight) do
        local row = CreateFrame("Button", nil, content)
        row:SetFrameLevel(scroll:GetFrameLevel() + 2)
        row:SetHeight(rowHeight)
        row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i - 1) * rowHeight)
        row:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        row.icon = CreateFrame("Button", nil, row)
        row.icon:SetSize(rowHeight - 6, rowHeight - 6)
        row.icon:SetPoint("LEFT", 4, 0)
        row.icon.texture = row.icon:CreateTexture(nil, "ARTWORK")
        row.icon.texture:SetAllPoints()
        row.icon:SetScript("OnEnter", IconEnter)
        row.icon:SetScript("OnLeave", HideTooltip)
        row.icon:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.icon:SetScript("OnClick", function(self, button)
            local r = self:GetParent()
            UI.ItemClick(r.item, button, r, opts.onRightClick)
        end)

        local textLeft = rowHeight + 6
        row.right = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.right:SetPoint("TOPRIGHT", -6, -5)
        row.right:SetJustifyH("RIGHT")

        row.title = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        row.title:SetPoint("TOPLEFT", textLeft, -3)
        row.title:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
        row.title:SetJustifyH("LEFT")
        row.title:SetWordWrap(false)

        row.sub = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.sub:SetPoint("TOPLEFT", textLeft, -20)
        row.sub:SetPoint("RIGHT", -6, 0)
        row.sub:SetJustifyH("LEFT")
        row.sub:SetWordWrap(false)

        row:SetScript("OnClick", function(self, button)
            UI.ItemClick(self.item, button, self, opts.onRightClick)
        end)
        if opts.onEnter then
            row:SetScript("OnEnter", function(self)
                if self.item then opts.onEnter(self.item, self) end
            end)
            row:SetScript("OnLeave", HideTooltip)
        end
        list.rows[i] = row
    end

    function list:SetItems(items, emptyText)
        self.items = items
        self.empty:SetText(emptyText or "")
        self.empty:SetShown(#items == 0)
        Update()
    end

    return list
end

-- Søgefelt med grå hjælpetekst. onChange(text) kaldes ved hver ændring.
function UI.CreateSearchBox(content, name, width, hint, onChange)
    local box = CreateFrame("EditBox", name, content, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetPoint("TOPLEFT", 8, -4)
    box:SetAutoFocus(false)
    box.hint = box:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    box.hint:SetPoint("LEFT", 2, 0)
    box.hint:SetText(hint)
    box:SetTextInsets(0, 16, 0, 0)      -- plads til x-knappen

    -- Lille "x" til højre i feltet, der rydder søgningen (vises kun, når der står noget).
    local clear = CreateFrame("Button", nil, box)
    clear:SetSize(16, 16)
    clear:SetPoint("RIGHT", -2, 0)
    clear.text = clear:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    clear.text:SetPoint("CENTER")
    clear.text:SetText("x")
    clear:SetScript("OnEnter", function(self) self.text:SetFontObject("GameFontHighlight") end)
    clear:SetScript("OnLeave", function(self) self.text:SetFontObject("GameFontDisable") end)
    clear:SetScript("OnClick", function()
        box:SetText("")
        box:ClearFocus()
    end)
    clear:Hide()
    box.clear = clear

    box:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        self.hint:SetShown(text == "")
        self.clear:SetShown(text ~= "")
        onChange(text)
    end)
    -- Esc rydder søgningen (og slipper feltet); står der ingenting, lukker næste Esc vinduet som normalt.
    box:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return box
end

-- Søgefelter, der tager imod et shift-klikket item (som søgefeltet i auktionshuset): navnet sættes
-- ind i det felt, der er synligt. setQuery(text) sætter fanens søgning med det samme, fordi
-- OnTextChanged først kommer næste frame i spillet.
local linkBoxes = {}
function UI.AcceptItemLinks(box, setQuery)
    table.insert(linkBoxes, { box = box, setQuery = setQuery })
end

ns.Compat.HookLinkInsert(function(link)
    -- Kun items og recipes; quest-, spiller- og andre links går samme vej og skal ikke havne her.
    local kind = link:match("|H(%a+):")
    local name = (kind == "item" or kind == "enchant" or kind == "spell") and link:match("|h%[(.-)%]|h")
    if not name then return false end
    for _, entry in ipairs(linkBoxes) do
        if entry.box:IsVisible() then
            entry.setQuery(name)
            if entry.box:GetText() ~= name then entry.box:SetText(name) end
            return true
        end
    end
    return false
end)

-- Fanernes flueben og sortering huskes mellem sessioner: UI.Saved("roster", { onlyOnline = false })
-- returnerer tabellen i SavedVariables med standardværdier fyldt ind.
function UI.Saved(name, defaults)
    local filters = ns.db.settings.filters
    filters[name] = filters[name] or {}
    for key, value in pairs(defaults) do
        if filters[name][key] == nil then filters[name][key] = value end
    end
    return filters[name]
end

-- Kolonneoverskrift, der sorterer ved klik og viser en pil, når den er aktiv (som i auktionshuset).
-- header:SetSort(nil) skjuler pilen; SetSort(false) = stigende, SetSort(true) = faldende.
function UI.CreateSortHeader(parent, label, width, onClick)
    local header = CreateFrame("Button", nil, parent)
    header:SetSize(width, 18)
    header.text = header:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    header.text:SetPoint("LEFT", 0, 0)
    header.text:SetText(label)
    header.arrow = header:CreateTexture(nil, "ARTWORK")
    header.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
    header.arrow:SetSize(9, 8)
    header.arrow:SetPoint("LEFT", header.text, "RIGHT", 3, -1)
    header.arrow:Hide()
    header:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    header:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        onClick()
    end)
    function header:SetSort(descending)
        self.arrow:SetShown(descending ~= nil)
        if descending then
            self.arrow:SetTexCoord(0, 0.5625, 1, 0)
        else
            self.arrow:SetTexCoord(0, 0.5625, 0, 1)
        end
    end
    return header
end

function UI.CreateCheck(content, label, onClick)
    local check = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check.label = check:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
    check.label:SetText(label)
    check:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return check
end

-- Navn til visning: grøn hvis online, grå hvis offline, med "(alt of X)".
function UI.PersonText(key)
    local text = ns.Index:DisplayName(key)
    if ns.Index:IsOnline(key) then
        return "|cff40ff40" .. text .. "|r"
    end
    return "|cffaaaaaa" .. text .. "|r"
end

-- Item-link til en whisper, eller "[navn]", hvis itemet ikke er hentet fra serveren endnu.
function UI.ItemRef(item)
    return (item.link and item.link()) or ("[" .. item.name .. "]")
end

-- Åbner en whisper til en char med en færdig tekst, fx "/w Anna Hi! Could you craft [Flask] for me?".
-- Teksten sendes ikke; man kan rette den og trykke Enter selv.
function UI.WhisperAbout(key, message)
    ns.Compat.Whisper(key, message)
end

-- Menu med "Whisper <navn>" for en liste af chars (egen char udelades); message er den færdige tekst.
-- extra: ekstra menupunkter øverst, fx "Add to craft list".
function UI.WhisperMenu(owner, title, keys, message, extra)
    local items = { { text = title, isTitle = true } }
    for _, item in ipairs(extra or {}) do table.insert(items, item) end
    local me = ns.Compat.PlayerKey()
    local any = false
    for _, key in ipairs(keys or {}) do
        if key ~= me then
            any = true
            local status = ns.Index:IsOnline(key) and "" or " (offline)"
            table.insert(items, {
                text = "Whisper " .. ns.Index:DisplayName(key) .. status,
                func = function() UI.WhisperAbout(key, message) end,
            })
        end
    end
    if not any then
        table.insert(items, { text = "(nobody else to whisper)", isTitle = true })
    end
    ns.Compat.ContextMenu(owner, items)
end
