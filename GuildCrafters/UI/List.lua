local _, ns = ...

-- Fælles byggeklodser til fanerne: klik på items, søgefelt, sorterbare overskrifter, whisper-menu.
local UI = ns.UI

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

-- Menu med "Whisper <navn>" for en liste af chars; message er den færdige tekst. Ens egne chars er
-- ikke med (man kan ikke whispe sin egen alt). extra: ekstra menupunkter øverst, fx "Add to craft list".
function UI.WhisperMenu(owner, title, keys, message, extra)
    local items = { { text = title, isTitle = true } }
    for _, item in ipairs(extra or {}) do table.insert(items, item) end
    local me = ns.Compat.PlayerKey()
    local any = false
    for _, key in ipairs(keys or {}) do
        if key ~= me and not ns.Data:IsMine(key) then
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
