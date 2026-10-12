local _, ns = ...

local UI = ns.UI
local Roster = {}
ns.Roster = Roster

local ROW_HEIGHT = 20
local MAX_PROF_ICONS = 5

local COLUMNS = {
    { key = "name",  label = "Name",        x = 4,   width = 270 },
    { key = "role",  label = "Role",        x = 280, width = 44 },
    { key = "level", label = "Lvl",         x = 330, width = 36 },
    { key = "profs", label = "Professions", x = 372, width = 300 },
}

local state = {
    search = "",
    onlyOnline = false,
    filter = nil,        -- nil, "TANK"/"HEALER"/"DPS" eller "PROF:<navn>"
    sortKey = "name",
    sortDesc = false,
}

local list = {}
local rows = {}
local scroll, filterButton

------------------------------------------------------------------------
-- Data: guild-roster + addon-data + egne chars + test-data
------------------------------------------------------------------------

local function AttachMine(entry, rec)
    entry.hasAddon = true
    entry.isMine = true
    entry.specTab = rec.specTab
    entry.role = rec.roleOverride or rec.role
    entry.main = ns.Data:GetMyMain()
    entry.profs = rec.profs
    entry.addonVer = ns.VERSION
end

local function AttachCached(entry, c)
    entry.hasAddon = true
    entry.specTab = c.specTab
    entry.role = c.role
    entry.main = c.main
    entry.profs = c.profs
    entry.addonVer = c.addonVer
    entry.seen = c.seen
end

local function BuildEntries()
    local entries = {}
    local myKey = ns.Compat.PlayerKey()
    local guild = ns.Data:GetGuild()
    local cache = guild and guild.chars or {}
    local foundMe = false

    for _, m in ipairs(ns.Compat.GetGuildMembers()) do
        local entry = { key = m.key, level = m.level, class = m.class, online = m.online, zone = m.zone }
        if m.key == myKey then foundMe = true end
        if ns.db.myChars[m.key] then
            AttachMine(entry, ns.db.myChars[m.key])
        elseif cache[m.key] then
            AttachCached(entry, cache[m.key])
        end
        table.insert(entries, entry)
    end

    -- Uden guild (eller før roster er indlæst) vises i det mindste ens egen char.
    if not foundMe then
        local me = ns.Data:GetMe()
        local entry = { key = myKey, level = me.level, class = me.class, online = true }
        AttachMine(entry, me)
        table.insert(entries, entry)
    end

    for _, fake in ipairs(ns.Debug and ns.Debug.fakes or {}) do
        table.insert(entries, fake)
    end
    return entries
end

local function HasProf(entry, profName)
    return entry.profs and entry.profs[profName] ~= nil
end

local function Matches(entry)
    if state.onlyOnline and not entry.online then return false end
    if state.filter then
        local prof = state.filter:match("^PROF:(.+)$")
        if prof then
            if not HasProf(entry, prof) then return false end
        elseif entry.role ~= state.filter then
            return false
        end
    end
    if state.search ~= "" then
        local needle = state.search:lower()
        local name = ns.Compat.ShortName(entry.key):lower()
        local main = entry.main and ns.Compat.ShortName(entry.main):lower() or ""
        if not name:find(needle, 1, true) and not main:find(needle, 1, true) then
            return false
        end
    end
    return true
end

local ROLE_ORDER = { TANK = 1, HEALER = 2, DPS = 3 }

local function ProfCount(entry)
    local n = 0
    for name in pairs(entry.profs or {}) do
        if not UI.SECONDARY_PROFS[name] then n = n + 1 end
    end
    return n
end

local function SortValue(entry, key)
    if key == "role" then return ROLE_ORDER[entry.role] or 9 end
    if key == "level" then return entry.level or 0 end
    if key == "profs" then return ProfCount(entry) end
    return ns.Compat.ShortName(entry.key):lower()
end

-- Online først, derefter valgt kolonne, derefter navn.
local function Compare(a, b)
    if a.online ~= b.online then return a.online end
    local va, vb = SortValue(a, state.sortKey), SortValue(b, state.sortKey)
    if va ~= vb then
        if state.sortDesc then return va > vb end
        return va < vb
    end
    return a.key < b.key
end

local function BuildList()
    wipe(list)
    for _, entry in ipairs(BuildEntries()) do
        if Matches(entry) then
            table.insert(list, entry)
        end
    end
    table.sort(list, Compare)
end

------------------------------------------------------------------------
-- Rækker
------------------------------------------------------------------------

-- Primære professions først, derefter secondary, alfabetisk inden for hver gruppe.
local function SortedProfs(profs)
    local names = {}
    for name in pairs(profs or {}) do table.insert(names, name) end
    table.sort(names, function(a, b)
        local sa, sb = UI.SECONDARY_PROFS[a] or false, UI.SECONDARY_PROFS[b] or false
        if sa ~= sb then return not sa end
        return a < b
    end)
    return names
end

local function DisplayName(entry)
    local short = ns.Compat.ShortName(entry.key)
    local r, g, b = UI.ClassColor(entry.class)
    if not entry.hasAddon then r, g, b = 0.5, 0.5, 0.5 end
    local text = UI.ColorText(short, r, g, b)
    if entry.main and entry.main ~= entry.key then
        text = text .. UI.ColorText(" (alt of " .. ns.Compat.ShortName(entry.main) .. ")", 0.6, 0.6, 0.6)
    end
    return text
end

local function ShowTooltip(row)
    local e = row.entry
    if not e then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(DisplayName(e))

    local spec = ns.Roles.SpecName(e.class, e.specTab)
    local className = e.class and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[e.class] or e.class) or "?"
    GameTooltip:AddLine(string.format("Level %s %s%s", tostring(e.level or "?"), className,
        spec and (" (" .. spec .. ")") or ""), 1, 1, 1)
    if e.role then
        GameTooltip:AddLine("Role: " .. UI.ROLE_NAMES[e.role], 1, 1, 1)
    end
    if e.online and e.zone then
        GameTooltip:AddLine(e.zone, 0.7, 0.7, 0.7)
    end

    if e.hasAddon then
        local names = SortedProfs(e.profs)
        if #names > 0 then
            GameTooltip:AddLine(" ")
            for _, name in ipairs(names) do
                local p = e.profs[name]
                GameTooltip:AddDoubleLine(name, string.format("%s/%s", tostring(p.rank), tostring(p.max)),
                    1, 0.82, 0, 1, 1, 1)
            end
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("GuildCrafters v" .. tostring(e.addonVer), 0.5, 0.5, 0.5)
        if not e.online and e.seen then
            GameTooltip:AddLine("Data updated " .. UI.Ago(e.seen), 0.5, 0.5, 0.5)
        end
    else
        GameTooltip:AddLine("Does not have GuildCrafters", 0.5, 0.5, 0.5)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click: whisper, invite and more", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function OpenMenu(row)
    local e = row.entry
    local items = {
        { text = ns.Compat.ShortName(e.key), isTitle = true },
        { text = "Whisper", func = function() ns.Compat.Whisper(e.key) end },
        { text = "Invite", func = function() ns.Compat.Invite(e.key) end },
    }
    if e.hasAddon then
        table.insert(items, { text = "Show recipes", func = function() UI.ShowCrafter(e.key) end })
    end
    if e.key == ns.Compat.PlayerKey() then
        for _, role in ipairs({ "TANK", "HEALER", "DPS" }) do
            table.insert(items, {
                text = "Set role: " .. UI.ROLE_NAMES[role],
                func = function() ns.Roles:SetOverride(role) end,
            })
        end
        table.insert(items, { text = "Set role: Auto", func = function() ns.Roles:SetOverride(nil) end })
    end
    if e.isMine then
        table.insert(items, {
            text = "Set as main",
            func = function() ns.Data:SetMyMain(e.key) end,
        })
    end
    ns.Compat.ContextMenu(row, items)
end

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetFrameLevel(scroll:GetFrameLevel() + 2)   -- over scroll-rammen, så klik når frem
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetSize(12, 12)
    row.dot:SetPoint("LEFT", COLUMNS[1].x, 0)

    row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", COLUMNS[1].x + 16, 0)
    row.name:SetWidth(COLUMNS[1].width - 16)
    row.name:SetJustifyH("LEFT")

    row.role = row:CreateTexture(nil, "ARTWORK")
    row.role:SetSize(16, 16)
    row.role:SetPoint("LEFT", COLUMNS[2].x + 6, 0)

    row.level = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.level:SetPoint("LEFT", COLUMNS[3].x, 0)
    row.level:SetWidth(COLUMNS[3].width)
    row.level:SetJustifyH("LEFT")

    row.profs = {}
    for i = 1, MAX_PROF_ICONS do
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", COLUMNS[4].x + (i - 1) * 50, 0)
        local rank = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        rank:SetPoint("LEFT", icon, "RIGHT", 2, 0)
        row.profs[i] = { icon = icon, rank = rank }
    end

    row:SetScript("OnEnter", ShowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Kun højreklik gør noget (menu med Whisper, Invite osv.); en whisper på venstreklik var irriterende.
    row:SetScript("OnClick", function(self, button)
        if self.entry and button == "RightButton" then OpenMenu(self) end
    end)
    return row
end

local function UpdateRow(row, e)
    row.entry = e
    row.dot:SetTexture(e.online and "Interface\\COMMON\\Indicator-Green" or "Interface\\COMMON\\Indicator-Gray")
    row.name:SetText(DisplayName(e))
    row.level:SetText(e.level or "")
    if e.hasAddon then
        row.level:SetTextColor(1, 1, 1)
    else
        row.level:SetTextColor(0.5, 0.5, 0.5)
    end

    local roleIcon = e.hasAddon and UI.RoleIcon(e.role)
    row.role:SetTexture(roleIcon or nil)
    row.role:SetShown(roleIcon and true or false)

    local names = e.hasAddon and SortedProfs(e.profs) or {}
    for i, slot in ipairs(row.profs) do
        local name = names[i]
        if name then
            slot.icon:SetTexture(UI.ProfIcon(name))
            slot.rank:SetText(e.profs[name].rank or "")
            slot.icon:Show()
            slot.rank:Show()
        else
            slot.icon:Hide()
            slot.rank:Hide()
        end
    end
    row:Show()
end

local function UpdateRows()
    local offset = FauxScrollFrame_GetOffset(scroll)
    for i, row in ipairs(rows) do
        local e = list[offset + i]
        if e then
            UpdateRow(row, e)
        else
            row.entry = nil
            row:Hide()
        end
    end
    FauxScrollFrame_Update(scroll, #list, #rows, ROW_HEIGHT)
end

------------------------------------------------------------------------
-- Toplinje: søgning, filter, kun online
------------------------------------------------------------------------

local function FilterLabel()
    if not state.filter then return "Filter: All" end
    local prof = state.filter:match("^PROF:(.+)$")
    return "Filter: " .. (prof or UI.ROLE_NAMES[state.filter])
end

local function SetFilter(value)
    state.filter = value
    filterButton:SetText(FilterLabel())
    Roster.Refresh()
end

local function OpenFilterMenu(button)
    local items = {
        { text = "Role", isTitle = true },
        { text = "All", func = function() SetFilter(nil) end },
    }
    for _, role in ipairs({ "TANK", "HEALER", "DPS" }) do
        table.insert(items, { text = UI.ROLE_NAMES[role], func = function() SetFilter(role) end })
    end

    -- Professions, som mindst én i rosteren har.
    local seen, profNames = {}, {}
    for _, e in ipairs(BuildEntries()) do
        for name in pairs(e.profs or {}) do
            if not seen[name] then
                seen[name] = true
                table.insert(profNames, name)
            end
        end
    end
    table.sort(profNames)
    if #profNames > 0 then
        table.insert(items, { text = "Profession", isTitle = true })
        for _, name in ipairs(profNames) do
            table.insert(items, { text = name, func = function() SetFilter("PROF:" .. name) end })
        end
    end
    ns.Compat.ContextMenu(button, items)
end

local function CreateHeader(content, col)
    local button = CreateFrame("Button", nil, content)
    button:SetSize(col.width, 18)
    button:SetPoint("TOPLEFT", content, "TOPLEFT", col.x, -34)
    local text = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    text:SetPoint("LEFT", 0, 0)
    text:SetText(col.label)
    button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    button:SetScript("OnClick", function()
        if state.sortKey == col.key then
            state.sortDesc = not state.sortDesc
        else
            state.sortKey, state.sortDesc = col.key, false
        end
        Roster.Refresh()
    end)
end

local function Build(content)
    local search = CreateFrame("EditBox", "GuildCraftersRosterSearch", content, "InputBoxTemplate")
    search:SetSize(160, 20)
    search:SetPoint("TOPLEFT", 8, -4)
    search:SetAutoFocus(false)
    search.hint = search:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    search.hint:SetPoint("LEFT", 2, 0)
    search.hint:SetText("Search name")
    search:SetScript("OnTextChanged", function(self)
        state.search = self:GetText()
        self.hint:SetShown(state.search == "")
        Roster.Refresh()
    end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    filterButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    filterButton:SetSize(150, 22)
    filterButton:SetPoint("LEFT", search, "RIGHT", 12, 0)
    filterButton:SetText(FilterLabel())
    filterButton:SetScript("OnClick", OpenFilterMenu)

    local online = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    online:SetSize(24, 24)
    online:SetPoint("LEFT", filterButton, "RIGHT", 12, 0)
    local onlineLabel = online:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    onlineLabel:SetPoint("LEFT", online, "RIGHT", 2, 0)
    onlineLabel:SetText("Online only")
    online:SetScript("OnClick", function(self)
        state.onlyOnline = self:GetChecked() and true or false
        Roster.Refresh()
    end)

    content.count = UI.CreateFooter(content)

    for _, col in ipairs(COLUMNS) do
        CreateHeader(content, col)
    end

    scroll = CreateFrame("ScrollFrame", "GuildCraftersRosterScroll", content, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -54)
    scroll:SetPoint("BOTTOMRIGHT", -26, UI.FOOTER_HEIGHT + 4)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, UpdateRows)
    end)

    local numRows = math.floor((UI.CONTENT_HEIGHT - 58 - UI.FOOTER_HEIGHT) / ROW_HEIGHT)
    for i = 1, numRows do
        rows[i] = CreateRow(content, i)
    end

    -- Guild-roster opdateres kun, når serveren bliver spurgt; spørg jævnligt, mens fanen er åben.
    content:SetScript("OnShow", function() ns.Compat.RequestGuildRoster() end)
    C_Timer.NewTicker(20, function()
        if content:IsVisible() then ns.Compat.RequestGuildRoster() end
    end)
end

function Roster.Refresh(content)
    if not scroll then return end
    BuildList()
    local online, withAddon = 0, 0
    for _, e in ipairs(list) do
        if e.online then online = online + 1 end
        if e.hasAddon then withAddon = withAddon + 1 end
    end
    local text = string.format("%d shown · %d online · %d with GuildCrafters", #list, online, withAddon)
    if not ns.Compat.GuildKey() then
        text = "|cffff8080Not in a guild|r · " .. text
    end
    scroll:GetParent().count:SetText(text)
    UpdateRows()
end

UI:AddTab("Roster", Build, Roster.Refresh)
