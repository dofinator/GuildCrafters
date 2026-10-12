local _, ns = ...

local Debug = { fakes = {}, fakeReagents = {} }
ns.Debug = Debug

local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function ItemText(id)
    return ns.Compat.ItemLink(id) or ("item:" .. id)
end

local function EnchantText(id)
    return ns.Compat.SpellLink(id) or ns.Compat.SpellName(id) or ("enchant:" .. id)
end

-- /gc debug dump            -> oversigt over egne data og guild-cache
-- /gc debug dump alchemy    -> alle recipes i én profession
local function Dump(filter)
    local me, key = ns.Data:GetMe()
    ns:Print(string.format("%s  lvl %s %s  spec=%s role=%s%s  main=%s",
        key, tostring(me.level), tostring(me.class), tostring(me.specTab), tostring(ns.Roles:MyRole()),
        me.roleOverride and " (manual)" or "", tostring(ns.Data:GetMyMain())))
    ns:Print(string.format("  versions: info=%d recipes=%d mats=%d", me.v.info, me.v.recipes, me.v.mats))

    filter = filter:lower()
    for name, prof in pairs(me.profs) do
        if filter == "" then
            ns:Print(string.format("  %s %s/%s: %d items, %d enchants",
                name, tostring(prof.rank), tostring(prof.max), Count(prof.items), Count(prof.enchants)))
        elseif name:lower():find(filter, 1, true) then
            ns:Print(string.format("  %s %s/%s:", name, tostring(prof.rank), tostring(prof.max)))
            for id in pairs(prof.items) do ns:Print("    " .. ItemText(id)) end
            for id in pairs(prof.enchants) do ns:Print("    " .. EnchantText(id)) end
        end
    end

    if filter == "" then
        local guild, guildKey = ns.Data:GetGuild()
        if guild then
            ns:Print(string.format("Guild %s: %d others with the addon in cache, %d in roster",
                guildKey, Count(guild.chars), #ns.Compat.GetGuildMembers()))
        else
            ns:Print("Not in a guild (or guild not loaded yet).")
        end
    end
end

------------------------------------------------------------------------
-- Test-data til UI: /gc debug fake N
------------------------------------------------------------------------

local FAKE_NAMES = { "Thrall", "Jaina", "Anduin", "Sylvanas", "Varian", "Tyrande", "Malfurion",
    "Uther", "Arthas", "Garrosh", "Velen", "Illidan", "Khadgar", "Bolvar", "Baine", "Vol'jin",
    "Rexxar", "Brann", "Muradin", "Alleria" }
local FAKE_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local FAKE_PROFS = { "Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Herbalism",
    "Jewelcrafting", "Leatherworking", "Mining", "Skinning", "Tailoring" }
local FAKE_ROLES = { "TANK", "HEALER", "DPS", "DPS" }
local function Pick(t) return t[math.random(#t)] end

-- Rigtige item-ID'er, så søgning og tooltips kan testes uden en guild.
local FAKE_RECIPES = { 13510, 13446, 13452, 22861, 22832, 12359, 14530, 14048, 1251, 2996, 2568, 4344 }
local FAKE_MATS = { 10620, 14047, 13468, 12363, 22785, 23424, 21877, 2589, 2770 }

local function PickSet(source, n)
    local set = {}
    for _ = 1, n do set[Pick(source)] = true end
    return set
end

local function MakeFake(i)
    local name = FAKE_NAMES[(i - 1) % #FAKE_NAMES + 1] .. (i > #FAKE_NAMES and tostring(i) or "")
    local key = name .. "-Test"
    local profs = {}
    for _ = 1, 2 do
        profs[Pick(FAKE_PROFS)] = { rank = math.random(1, 375), max = 375,
            items = PickSet(FAKE_RECIPES, 4), enchants = {} }
    end
    if math.random() < 0.6 then
        profs["Cooking"] = { rank = math.random(1, 375), max = 375, items = {}, enchants = {} }
    end
    local hasAddon = math.random() < 0.75
    return {
        key = key,
        class = Pick(FAKE_CLASSES),
        level = math.random(55, 70),
        online = math.random() < 0.5,
        zone = "Shattrath City",
        hasAddon = hasAddon,
        specTab = hasAddon and math.random(1, 3) or nil,
        role = hasAddon and Pick(FAKE_ROLES) or nil,
        profs = hasAddon and profs or nil,
        addonVer = hasAddon and ns.VERSION or nil,
        matsShared = hasAddon,
        mats = hasAddon and {
            bags = { [Pick(FAKE_MATS)] = math.random(1, 40) },
            bank = { [Pick(FAKE_MATS)] = math.random(20, 200) },
            time = time() - math.random(0, 86400),
        } or nil,
        seen = time() - math.random(0, 86400 * 3),
    }
end

local function MakeFakes(n)
    wipe(Debug.fakes)
    -- Opdigtede reagents til test-recipes, så Craft List kan testes uden rigtige data.
    wipe(Debug.fakeReagents)
    for _, id in ipairs(FAKE_RECIPES) do
        -- Hver mat højst én gang pr. recipe, ligesom i rigtige recipes.
        local r = {}
        for mat in pairs(PickSet(FAKE_MATS, math.random(1, 3))) do
            table.insert(r, mat)
            table.insert(r, math.random(1, 5))
        end
        Debug.fakeReagents["i" .. id] = { made = 1, r = r }
    end
    for i = 1, n do
        table.insert(Debug.fakes, MakeFake(i))
    end
    -- Gør hver fjerde til alt af den forrige.
    for i = 4, n, 4 do
        if Debug.fakes[i].hasAddon then Debug.fakes[i].main = Debug.fakes[i - 1].key end
    end
    ns:Fire("DATA_CHANGED")
    ns:Print(n .. " fake guild members created (in memory only). /gc debug clear removes them.")
end

------------------------------------------------------------------------
-- Rundtur til visuel test: /gc debug tour
-- Klikker selv gennem alle faner og tager et screenshot ved hvert trin. Lua-fejl, trin og fanernes
-- placering gemmes i GuildCraftersDB.debugTour, så Claude kan læse dem efter /reload.
------------------------------------------------------------------------

local STEP_WAIT = 1.5   -- sek. fra handling til screenshot (UI-refresh + item-info fra serveren)
local SHOT_WAIT = 1.2   -- sek. efter screenshot, før næste trin (filnavne har sekund-opløsning)

local tour              -- den aktive rundtur, nil når ingen kører

local function RecordError(msg)
    if not tour then return end
    table.insert(tour.report.errors, {
        step = tour.stepName, msg = tostring(msg), stack = debugstack and debugstack(2) or nil,
    })
end

local function Need(value, what)
    if not value then error("tour: found no " .. what, 0) end
    return value
end

-- Synlige børne-frames af parent i oprettelsesrækkefølge (= rækkefølgen på skærmen for listerækker).
local function FindChild(parent, pred, n)
    n = n or 1
    for _, child in ipairs({ parent:GetChildren() }) do
        if child:IsVisible() and pred(child) then
            n = n - 1
            if n == 0 then return child end
        end
    end
end

local function ListRow(pred)
    return function(f)
        return f.item ~= nil and f:GetScript("OnEnter") ~= nil and (not pred or pred(f.item))
    end
end

local function CategoryRow(entryType)
    return function(f) return f.entry ~= nil and f.entry.type == entryType end
end

-- Tooltippens tekst gemmes i rapporten, så indholdet kan tjekkes uden at læse screenshottet.
local function Hover(row)
    row:GetScript("OnEnter")(row)
    local lines = {}
    for i = 1, GameTooltip:NumLines() do
        local left, right = _G["GameTooltipTextLeft" .. i], _G["GameTooltipTextRight" .. i]
        local text = left and left:GetText() or ""
        if right and right:IsShown() and right:GetText() then text = text .. " | " .. right:GetText() end
        table.insert(lines, text)
    end
    tour.tooltip = lines
end
local function Click(f, button) f:GetScript("OnClick")(f, button or "LeftButton") end

-- Den lille knap med teksten text ("+", "-", "x") i en listerække.
local function RowButton(row, text)
    return FindChild(row, function(f) return f.GetText and f:GetText() == text end)
end

local function Search(boxName, text)
    local box = Need(_G[boxName], boxName)
    box:SetText(text)
    box:ClearFocus()
    -- I spillet kommer OnTextChanged først næste frame; kald den nu, så næste handling ser resultatet.
    box:GetScript("OnTextChanged")(box, true)
end

local function CloseMenus()
    if Menu and Menu.GetManager then pcall(function() Menu.GetManager():CloseMenus() end) end
    if CloseDropDownMenus then CloseDropDownMenus() end
end

local function Tab(t, label)
    t.content = Need(ns.UI:ShowTab(label), "tab " .. label)
end

-- Kategorier: vælg "All recipes", så første klik på en kategori altid folder den ud.
local function CraftingReset(t)
    Tab(t, "Crafting")
    Search("GuildCraftersCraftingSearch", "")
    Click(Need(FindChild(t.content, CategoryRow("all")), "\"All recipes\" category"))
end

local TOUR_STEPS = {
    { "roster", function(t) Tab(t, "Roster") end },
    { "roster-tooltip", function(t)
        Hover(Need(FindChild(t.content, function(f)
            return f.entry ~= nil and f.entry.hasAddon and f:GetScript("OnEnter") ~= nil
        end), "roster member with the addon"))
    end },
    { "crafting-all", CraftingReset },
    { "crafting-category", function(t)
        Click(Need(FindChild(t.content, CategoryRow("top")), "top category"))
    end },
    { "crafting-subcategory", function(t)
        Click(Need(FindChild(t.content, CategoryRow("sub")), "subcategory"))
    end },
    { "crafting-by-crafter", function(t)
        if not FindChild(t.content, CategoryRow("crafter")) then
            Click(Need(FindChild(t.content, CategoryRow("crafters")), "\"By crafter\" category"))
        end
        Click(Need(FindChild(t.content, CategoryRow("crafter")), "crafter under \"By crafter\""))
    end },
    { "search-flask", function(t)
        CraftingReset(t)
        Search("GuildCraftersCraftingSearch", "flask")
    end },
    { "search-stamina", function()
        Search("GuildCraftersCraftingSearch", "stamina")
    end },
    { "result-tooltip", function(t)
        Search("GuildCraftersCraftingSearch", "flask")
        Hover(Need(FindChild(t.content, ListRow()), "search result for \"flask\""))
    end },
    { "add-to-craft-list", function(t)
        Search("GuildCraftersCraftingSearch", "")
        for n = 1, 3 do
            local row = Need(FindChild(t.content, ListRow(), n), "result row " .. n)
            Click(Need(RowButton(row, "+"), "+ button"))
        end
    end },
    { "whisper-menu", function(t)
        Click(Need(FindChild(t.content, ListRow()), "result row"), "RightButton")
    end },
    { "craft-list", function(t)
        CloseMenus()
        Tab(t, "Craft List")
    end },
    { "craft-list-qty-tooltip", function(t)
        local row = Need(FindChild(t.content, ListRow(function(item) return item.entry end)), "craft list entry")
        Click(Need(RowButton(row, "+"), "+ button"))
        Hover(row)
    end },
    { "craft-list-material-tooltip", function(t)
        local function MaterialRow() return FindChild(t.content, ListRow(function(item) return item.need end)) end
        -- Ready-items er foldet sammen; fold det første ud, hvis ingen mats er synlige.
        if not MaterialRow() then
            local row = Need(FindChild(t.content, ListRow(function(item) return item.folded end)), "folded item")
            Click(row.toggle)
        end
        Hover(Need(MaterialRow(), "material row"))
    end },
    { "mats", function(t) Tab(t, "Mats") end },
    { "mats-tooltip", function(t)
        Hover(Need(FindChild(t.content, ListRow()), "mats row"))
    end },
}

-- Fanernes placering, så mellemrum/overlap kan tjekkes ud fra tal og ikke kun screenshots.
local function TabGeometry()
    local result, prevRight = {}, nil
    for i = 1, 20 do
        local button = _G["GuildCraftersFrameTab" .. i]
        if not button then break end
        local left, right = button:GetLeft(), button:GetRight()
        local fs = button:GetFontString()
        table.insert(result, {
            text = button:GetText(), left = left, right = right, width = button:GetWidth(),
            truncated = fs and fs.IsTruncated and fs:IsTruncated() or nil,
            gap = (left and prevRight) and (left - prevRight) or nil,
        })
        prevRight = right
    end
    return result
end

local function SetScreenshotMessage(enabled)
    -- "Screen captured" midt på skærmen ville ellers komme med på de næste screenshots.
    if not (ActionStatus and ActionStatus.UnregisterEvent) then return end
    if enabled then
        if tour.statusWasRegistered then ActionStatus:RegisterEvent("SCREENSHOT_SUCCEEDED") end
    else
        tour.statusWasRegistered = ActionStatus:IsEventRegistered("SCREENSHOT_SUCCEEDED")
        ActionStatus:UnregisterEvent("SCREENSHOT_SUCCEEDED")
    end
end

local function FinishTour()
    local t = tour
    CloseMenus()
    GameTooltip:Hide()
    t.stepName = "finish"
    -- Hver oprydning for sig: en fejl ét sted må ikke forhindre, at craft-listen genskabes.
    wipe(ns.db.craftList)
    for _, e in ipairs(t.savedCraftList) do table.insert(ns.db.craftList, e) end
    ns:Fire("CRAFTLIST_CHANGED")
    xpcall(function() t.report.tabs = TabGeometry() end, RecordError)
    xpcall(Search, RecordError, "GuildCraftersCraftingSearch", "")
    if t.savedTab then xpcall(ns.UI.SelectTab, RecordError, ns.UI, t.savedTab) end
    SetScreenshotMessage(true)
    seterrorhandler(t.oldHandler)
    t.report.finished = date("%Y-%m-%d %H:%M:%S")
    t.report.aborted = t.aborted or nil
    tour = nil
    ns:Print(string.format("Tour %s: %d steps, %d screenshots, %d errors. Your craft list was restored.",
        t.aborted and "stopped" or "done", #t.report.steps, t.report.shotsOk, #t.report.errors))
    ns:Print("Type /reload so the report is saved, then tell Claude the tour is done.")
end

local function NextStep()
    local t = tour
    if not t then return end
    t.index = t.index + 1
    local step = TOUR_STEPS[t.index]
    if not step or t.aborted then return FinishTour() end
    t.stepName = step[1]
    t.tooltip = nil
    GameTooltip:Hide()
    local errorsBefore = #t.report.errors
    xpcall(step[2], RecordError, t)
    C_Timer.After(STEP_WAIT, function()
        if tour ~= t then return end
        table.insert(t.report.steps, {
            n = t.index, name = step[1], time = date("%H:%M:%S"),
            failed = #t.report.errors > errorsBefore or nil,
            tooltip = t.tooltip,
        })
        Screenshot()
        C_Timer.After(SHOT_WAIT, NextStep)
    end)
end

local function StartTour()
    if tour then
        ns:Print("The tour is already running. /gc debug tour stop stops it.")
        return
    end
    local saved = {}
    for i, e in ipairs(ns.db.craftList) do saved[i] = { kind = e.kind, id = e.id, qty = e.qty } end
    local width, height = GetScreenWidth(), GetScreenHeight()
    tour = {
        index = 0,
        savedCraftList = saved,
        savedTab = ns.UI:CurrentTab(),
        oldHandler = geterrorhandler(),
        report = {
            version = ns.VERSION, client = (GetBuildInfo()), started = date("%Y-%m-%d %H:%M:%S"),
            screen = { width = width, height = height, uiScale = UIParent:GetEffectiveScale() },
            steps = {}, errors = {}, shotsOk = 0, shotsFailed = 0,
        },
    }
    ns.db.debugTour = tour.report     -- gemmes også, hvis rundturen afbrydes af /reload
    -- Fejl fra events og timers under rundturen (fx en refresh) skal også med i rapporten.
    local old = tour.oldHandler
    seterrorhandler(function(msg, ...)
        RecordError(msg)
        return old(msg, ...)
    end)
    SetScreenshotMessage(false)

    if #Debug.fakes == 0 then MakeFakes(15) end
    ns.Data:CraftListClear()
    ns:Print(string.format("Tour started: %d steps, about %d seconds. Keep the mouse away from the window.",
        #TOUR_STEPS, math.ceil(#TOUR_STEPS * (STEP_WAIT + SHOT_WAIT))))
    -- Lidt tid til at item-info fra serveren når frem, før første screenshot.
    C_Timer.After(1, NextStep)
end

local function CountShot(event)
    if not tour then return end
    if event == "SCREENSHOT_SUCCEEDED" then
        tour.report.shotsOk = tour.report.shotsOk + 1
    else
        tour.report.shotsFailed = tour.report.shotsFailed + 1
    end
end
ns:RegisterEvent("SCREENSHOT_SUCCEEDED", CountShot)
ns:RegisterEvent("SCREENSHOT_FAILED", CountShot)

ns:RegisterCommand("debug", function(rest)
    local sub, arg = rest:match("^(%S*)%s*(.-)$")
    if sub == "dump" then
        Dump(arg)
    elseif sub == "fake" then
        MakeFakes(math.max(1, math.min(tonumber(arg) or 10, 200)))
    elseif sub == "clear" then
        wipe(Debug.fakes)
        wipe(Debug.fakeReagents)
        ns:Fire("DATA_CHANGED")
        ns:Print("Fake guild members removed.")
    elseif sub == "comm" then
        ns.debugComm = not ns.debugComm
        ns:Print("Addon message log: " .. (ns.debugComm and "on" or "off"))
    elseif sub == "ping" then
        ns.debugComm = true
        ns.Comm.Ping("GUILD")
        ns.Comm.Ping("WHISPER", UnitName("player"))
        ns:Print("Waiting for replies... (addon message log is on)")
        C_Timer.After(5, function()
            ns:Print(string.format("Diagnosis: in guild=%s, guildKey=%s, prefix registered=%s",
                tostring(IsInGuild()), tostring((ns.Compat.GuildKey())),
                tostring(C_ChatInfo.IsAddonMessagePrefixRegistered
                    and C_ChatInfo.IsAddonMessagePrefixRegistered(ns.Comm.PREFIX))))
        end)
    elseif sub == "hello" then
        ns.debugComm = true
        if ns.Sync:SendHello(true) then
            ns:Print("HELLO sent to the guild.")
        else
            ns.Sync:SendHelloToSelf()
            ns:Print("You are not in a guild. HELLO sent as a whisper to yourself instead (transport test).")
        end
    elseif sub == "tour" then
        if arg == "stop" then
            if tour then tour.aborted = true else ns:Print("No tour is running.") end
        else
            StartTour()
        end
    else
        ns:Print("Usage: /gc debug dump [profession] | fake [count] | clear | comm | hello | ping | tour [stop]")
    end
end, "/gc debug dump|fake N|clear|comm|hello|ping|tour - test tools")
