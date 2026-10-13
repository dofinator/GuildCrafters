-- Minimal WoW-API til at køre GuildCrafters uden for spillet (Lua 5.1 via lupa).
-- Python-siden leverer: sim_py_now(), sim_py_send(prefix, text, channel, target), sim_py_print(text)
-- og sætter sim_me (spilleren) før addonen loades.

local BASE_TIME = 1790000000

sim_events = {}       -- event -> { frame, ... }
sim_allFrames = {}
sim_timers = {}
sim_prints = {}
sim_menu = nil
sim_whispers = {}
sim_errors = {}

------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------

local Methods = {}
local WidgetMT = {}
local NIL_FIELDS = { TitleText = true, Inset = true, Text = true, Left = true, Middle = true, Right = true }

WidgetMT.__index = function(t, k)
    local m = Methods[k]
    if m then return m end
    if type(k) ~= "string" or NIL_FIELDS[k] then return nil end
    if k:match("^Create") then return function(self) return __NewWidget(k, nil, self) end end
    if k:match("^Get") then return function() return 0 end end
    if k:match("^Is") then return function() return false end end
    if k:match("^%u") then return function() end end
    return nil
end

local function NewWidget(kind, name, parent)
    local w = setmetatable({
        sim_kind = kind, sim_scripts = {}, sim_shown = true, sim_text = "", sim_parent = parent,
        sim_level = parent and (rawget(parent, "sim_level") or 1) + 1 or 1, sim_lines = {},
    }, WidgetMT)
    if name then _G[name] = w end
    table.insert(sim_allFrames, w)
    return w
end
__NewWidget = NewWidget

function Methods:SetScript(k, fn) self.sim_scripts[k] = fn end
function Methods:GetScript(k) return self.sim_scripts[k] end
function Methods:HasScript() return true end
function Methods:GetFontString()
    self.sim_fontString = rawget(self, "sim_fontString") or NewWidget("FontString", nil, self)
    self.sim_fontString.sim_text = self.sim_text
    return self.sim_fontString
end
function Methods:HookScript(k, fn)
    local old = self.sim_scripts[k]
    self.sim_scripts[k] = function(...)
        if old then old(...) end
        fn(...)
    end
end
function Methods:RegisterEvent(e)
    sim_events[e] = sim_events[e] or {}
    table.insert(sim_events[e], self)
end
function Methods:UnregisterEvent(e)
    for i, f in ipairs(sim_events[e] or {}) do
        if f == self then table.remove(sim_events[e], i) return end
    end
end
function Methods:UnregisterAllEvents()
    for e in pairs(sim_events) do self:UnregisterEvent(e) end
end
function Methods:IsEventRegistered(e)
    for _, f in ipairs(sim_events[e] or {}) do if f == self then return true end end
    return false
end
function Methods:Show()
    local was = self.sim_shown
    self.sim_shown = true
    if not was and self.sim_scripts.OnShow then self.sim_scripts.OnShow(self) end
end
function Methods:Hide()
    local was = self.sim_shown
    self.sim_shown = false
    if was and self.sim_scripts.OnHide then self.sim_scripts.OnHide(self) end
end
function Methods:SetShown(v) if v then self:Show() else self:Hide() end end
function Methods:IsShown() return self.sim_shown end
function Methods:IsVisible()
    local w = self
    while w do
        if not w.sim_shown then return false end
        w = w.sim_parent
    end
    return true
end
function Methods:SetText(t)
    self.sim_text = t
    -- Som i WoW: SetText på en EditBox udløser OnTextChanged.
    if self.sim_kind == "EditBox" and self.sim_scripts.OnTextChanged then
        self.sim_scripts.OnTextChanged(self, false)
    end
end
function Methods:SetFontObject(f)
    local t = type(f)
    assert(t == "string" or t == "table" or t == "nil",
        "FontString:SetFontObject(): Arguments: (font or \"font\" or nil)")
end
function Methods:GetText() return self.sim_text end
function Methods:SetChecked(v) self.sim_checked = v and true or false end
function Methods:GetChecked() return self.sim_checked or false end
function Methods:GetFrameLevel() return self.sim_level end
function Methods:SetFrameLevel(l) self.sim_level = l end
function Methods:GetHeight() return 20 end
function Methods:GetWidth() return 100 end
function Methods:GetPoint() return "CENTER", UIParent, "CENTER", 0, 0 end
function Methods:GetParent() return self.sim_parent end
function Methods:GetChildren()
    local children = {}
    for _, w in ipairs(sim_allFrames) do
        if w.sim_parent == self and w.sim_kind ~= "FontString" and w.sim_kind ~= "Texture" then
            table.insert(children, w)
        end
    end
    return unpack(children)
end
function Methods:GetName() return nil end
function Methods:SetID(id) self.sim_id = id end
function Methods:GetID() return self.sim_id or 0 end
function Methods:CreateFontString() return NewWidget("FontString", nil, self) end
function Methods:CreateTexture() return NewWidget("Texture", nil, self) end
function Methods:GetEffectiveScale() return 1 end
function Methods:GetCenter() return 0, 0 end

-- Tooltip
function Methods:SetOwner(owner) self.sim_lines = {} self.sim_owner = owner end
function Methods:GetOwner() return rawget(self, "sim_owner") end
local function SetLineText(self, i, text)
    local name = rawget(self, "sim_name")
    if not name then return end
    local fs = _G[name .. "TextLeft" .. i] or NewWidget("FontString", name .. "TextLeft" .. i, self)
    fs.sim_text = text
end
function Methods:AddLine(text)
    table.insert(self.sim_lines, tostring(text))
    SetLineText(self, #self.sim_lines, tostring(text))
end
function Methods:AddDoubleLine(a, b)
    table.insert(self.sim_lines, tostring(a) .. " | " .. tostring(b))
    SetLineText(self, #self.sim_lines, tostring(a) .. " | " .. tostring(b))
end
function Methods:NumLines() return #self.sim_lines end
function Methods:GetItem() return self.sim_itemName, self.sim_itemLink end
function Methods:ClearLines() self.sim_lines = {} end
function Methods:SetHyperlink(link)
    self.sim_lines = {}
    if self.sim_scripts.OnTooltipCleared then self.sim_scripts.OnTooltipCleared(self) end
    local id = tonumber(link:match("item:(%d+)"))
    local enchant = tonumber(link:match("enchant:(%d+)"))
    if id then
        local name, itemLink = sim_ItemInfo(id)
        local it = sim_items[id]
        if name then
            table.insert(self.sim_lines, name)
            for line in (it.text or ""):gmatch("[^;]+") do table.insert(self.sim_lines, line) end
        else
            table.insert(self.sim_lines, "Retrieving item information")
        end
        self.sim_itemName, self.sim_itemLink = name or "?", itemLink or ("|Hitem:" .. id .. "|h[?]|h")
    elseif enchant and sim_spells[enchant] then
        table.insert(self.sim_lines, sim_spells[enchant])
        table.insert(self.sim_lines, sim_spellText[enchant] or "")
    end
    local name = rawget(self, "sim_name")
    if name then
        for i, text in ipairs(self.sim_lines) do
            local fs = _G[name .. "TextLeft" .. i] or NewWidget("FontString", name .. "TextLeft" .. i, self)
            fs.sim_text = text
        end
        for i = #self.sim_lines + 1, #self.sim_lines + 5 do
            if _G[name .. "TextLeft" .. i] then _G[name .. "TextLeft" .. i].sim_text = nil end
        end
    end
    if id and self.sim_scripts.OnTooltipSetItem then self.sim_scripts.OnTooltipSetItem(self) end
    if id then
        for _, fn in ipairs(sim_tooltipPostCalls or {}) do fn(self, { id = id }) end
    end
end

function CreateFrame(kind, name, parent, template)
    local w = NewWidget(kind, name, parent)
    w.sim_name = name
    w.sim_template = template
    return w
end

UIParent = NewWidget("Frame", "UIParent")
Minimap = NewWidget("Frame", "Minimap")
GameTooltip = NewWidget("GameTooltip", "GameTooltip")
GameTooltip.sim_name = "GameTooltip"      -- giver GameTooltipTextLeftN, som i WoW
ItemRefTooltip = NewWidget("GameTooltip", "ItemRefTooltip")
DEFAULT_CHAT_FRAME = NewWidget("Frame", "DEFAULT_CHAT_FRAME")
function DEFAULT_CHAT_FRAME:AddMessage(text)
    local clean = tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    -- Som chatten i spillet: "||" vises som ét "|", mens et enkelt "|h"/"|a" er en styrekode og
    -- forsvinder ("tank|healer|dps|auto" blev til "tankealer|dps|uto", set 2026-10-13).
    clean = clean:gsub("||", "\1"):gsub("|h", ""):gsub("|a", "|"):gsub("\1", "|")
    table.insert(sim_prints, clean)
    sim_py_print(clean)
end
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    DEFAULT_CHAT_FRAME:AddMessage(table.concat(parts, " "))
end

------------------------------------------------------------------------
-- Events og tid
------------------------------------------------------------------------

function sim_fire(event, ...)
    local list = {}
    for _, f in ipairs(sim_events[event] or {}) do table.insert(list, f) end
    for _, f in ipairs(list) do
        local fn = f.sim_scripts.OnEvent
        if fn then fn(f, event, ...) end
    end
end

function GetTime() return sim_py_now() end
-- sim_py_epoch: et spring i kalenderen (fx to uger logget af), uden at alle timere skal køres igennem.
function time() return BASE_TIME + math.floor(sim_py_now()) + (sim_py_epoch and sim_py_epoch() or 0) end
GetServerTime = time

C_Timer = {}
function C_Timer.After(delay, fn)
    table.insert(sim_timers, { at = sim_py_now() + delay, fn = fn })
end
function C_Timer.NewTicker(delay, fn)
    local ticker = { cancelled = false }
    local function Tick()
        if ticker.cancelled then return end
        fn(ticker)
        C_Timer.After(delay, Tick)
    end
    C_Timer.After(delay, Tick)
    function ticker:Cancel() self.cancelled = true end
    return ticker
end

local lastTick = 0
function sim_tick()
    local now = sim_py_now()
    local due = {}
    local rest = {}
    for _, t in ipairs(sim_timers) do
        if t.at <= now then table.insert(due, t) else table.insert(rest, t) end
    end
    sim_timers = rest
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do t.fn() end
    local elapsed = now - lastTick
    lastTick = now
    for _, f in ipairs(sim_allFrames) do
        local fn = f.sim_scripts.OnUpdate
        if fn and f:IsVisible() then fn(f, elapsed) end
    end
end

------------------------------------------------------------------------
-- Diverse WoW-globaler
------------------------------------------------------------------------

-- WoW's xpcall sender ekstra argumenter videre (som Lua 5.2); det gør standard Lua 5.1 ikke.
local rawXpcall = xpcall
function xpcall(fn, handler, ...)
    local n, args = select("#", ...), { ... }
    return rawXpcall(function() return fn(unpack(args, 1, n)) end, handler)
end

function wipe(t) for k in pairs(t) do t[k] = nil end return t end
table.wipe = wipe       -- ChatThrottleLib bruger table.wipe, når beskedkøen er travl
tinsert, tremove = table.insert, table.remove
strsub, strfind, strmatch, format = string.sub, string.find, string.match, string.format
local errorHandler = function(err)
    table.insert(sim_errors, tostring(err))
    sim_py_print("LUA-FEJL: " .. tostring(err))
end
function geterrorhandler() return errorHandler end
function seterrorhandler(fn) errorHandler = fn end
function debugstack() return "(stack)" end
date = os.date
function GetBuildInfo() return "2.5.6", "99999", "Oct 1 2026", 20506 end
function GetScreenWidth() return 1920 end
function GetScreenHeight() return 1080 end
sim_screenshots = 0
function Screenshot()
    sim_screenshots = sim_screenshots + 1
    sim_fire("SCREENSHOT_SUCCEEDED")
end
function securecallfunction(fn, ...) return fn(...) end
function hooksecurefunc(a, b, c)
    local tbl, name, fn = a, b, c
    if type(a) == "string" then tbl, name, fn = _G, a, b end
    local orig = tbl[name]
    tbl[name] = function(...)
        local r = { orig(...) }
        fn(...)
        return unpack(r)
    end
end
function GetFramerate() return 60 end
function GetCursorPosition() return 0, 0 end
function GetMinimapShape() return "ROUND" end
WOW_PROJECT_ID = 5
WOW_PROJECT_MAINLINE = 1
sim_shift, sim_ctrl = false, false
function IsShiftKeyDown() return sim_shift end
function IsControlKeyDown() return sim_ctrl end
sim_dressUp = {}
function DressUpItemLink(link) table.insert(sim_dressUp, link) return true end
function PlaySound() end
SOUNDKIT = {}
UISpecialFrames = {}
SlashCmdList = {}
function PanelTemplates_SetNumTabs(f, n) f.numTabs = n end
function PanelTemplates_SetTab(f, i) f.selectedTab = i end
function PanelTemplates_TabResize() end
function FauxScrollFrame_GetOffset() return 0 end
function FauxScrollFrame_Update() end
function FauxScrollFrame_OnVerticalScroll() end
function UIDropDownMenu_Initialize(frame, init) frame.sim_init = init end
function UIDropDownMenu_CreateInfo() return {} end
function UIDropDownMenu_AddButton(info) table.insert(sim_menu, info) end
function ToggleDropDownMenu(_, _, frame)
    sim_menu = {}
    frame.sim_init(frame, 1)
end
function ChatFrame_SendTell(name) table.insert(sim_whispers, name) end
SLASH_WHISPER1 = "/w"
-- Som i WoW: "/w Navn besked" bliver til en whisper til Navn med "besked" stående i chatboksen.
function ChatFrame_OpenChat(text)
    local name, msg = text:match("^/w (%S+) (.*)$")
    if name then
        table.insert(sim_whispers, name)
        table.insert(sim_chatText, msg)
    end
end
StaticPopupDialogs = {}
YES, NO = "Yes", "No"
sim_popups = {}
function StaticPopup_Show(name) table.insert(sim_popups, name) end
sim_chatText = {}
-- Som i WoW: linket sættes kun ind, hvis en chatboks er åben (sim_chatOpen); ellers returneres false.
sim_chatOpen = true
function ChatEdit_GetActiveWindow() return sim_chatOpen and {} or nil end
function ChatEdit_InsertLink(text)
    if not sim_chatOpen then return false end
    table.insert(sim_chatText, text)
    return true
end
function InviteUnit() end
sim_inCombat = false
function InCombatLockdown() return sim_inCombat end

RAID_CLASS_COLORS = {}
LOCALIZED_CLASS_NAMES_MALE = {}
for _, c in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
    RAID_CLASS_COLORS[c] = { r = 0.5, g = 0.6, b = 0.7 }
    LOCALIZED_CLASS_NAMES_MALE[c] = c:sub(1, 1) .. c:sub(2):lower()
end

-- sim_addon er mappenavnet, addonen indlæses under ("GuildCrafters" eller testudgaven "GuildCraftersTest");
-- sim_loaded er andre addons, der allerede er indlæst. Begge sættes fra Python før denne fil køres.
sim_addon = sim_addon or "GuildCrafters"
sim_loaded = sim_loaded or {}
C_AddOns = {
    GetAddOnMetadata = function(_, field) return field == "Version" and sim_version or nil end,
    IsAddOnLoaded = function(name) return sim_loaded[name] or false end,
}

------------------------------------------------------------------------
-- Spiller, guild og talents (fra sim_me)
------------------------------------------------------------------------

function UnitName(unit) return sim_me.name end
function UnitClass() return sim_me.class:sub(1, 1) .. sim_me.class:sub(2):lower(), sim_me.class end
function UnitLevel() return sim_me.level end
function GetRealmName() return sim_me.realm end
function GetNormalizedRealmName() return sim_me.realm end
function Ambiguate(name, _)
    local short, realm = name:match("^([^%-]+)%-(.+)$")
    if short and realm == sim_me.realm then return short end
    return name
end

function IsInGuild() return sim_me.guild ~= nil end
function GetGuildInfo() return sim_me.guild end
sim_roster = {}
-- sim_rosterTotal: det samlede antal medlemmer, når rosteren kun viser nogle af dem ("Show Offline
-- Members" slået fra). 0 rækker = rosteren er ikke indlæst endnu.
sim_rosterTotal = nil
sim_showOffline = true
function GetGuildRosterShowOffline() return sim_showOffline end
function GetNumGuildMembers()
    local online = 0
    for _, m in ipairs(sim_roster) do
        if m.online then online = online + 1 end
    end
    return sim_rosterTotal or #sim_roster, online, online
end
function GetGuildRosterInfo(i)
    local m = sim_roster[i]
    if not m then return end
    return m.name, "Member", 1, m.level, m.class, "Shattrath City", m.note or "", "", m.online, 0, m.class
end
-- Offline medlemmer var sidst online for 3 dage og 5 timer siden.
function GetGuildRosterLastOnline(i)
    local m = sim_roster[i]
    if not m or m.online then return 0, 0, 0, 0 end
    return 0, 0, 3, 5
end
C_GuildInfo = {
    GuildRoster = function()
        C_Timer.After(0.2, function() sim_fire("GUILD_ROSTER_UPDATE") end)
    end,
}

function GetNumTalentTabs() return 3 end
function GetTalentTabInfo(tab) return "Tab" .. tab, "icon", sim_me.talents[tab] or 0, "bg" end

------------------------------------------------------------------------
-- Items og spells
------------------------------------------------------------------------

sim_items = {}        -- [id] = { name, class }
sim_cached = {}       -- items som klienten har i cache
function GetItemInfo(id)
    if type(id) == "string" then id = tonumber(id:match("item:(%d+)")) end
    local it = sim_items[id]
    if not it then return end
    if not sim_cached[id] then
        -- Første opslag: ikke i cache endnu; serveren svarer lidt senere.
        sim_cached[id] = "pending"
        C_Timer.After(0.5, function()
            sim_cached[id] = true
            sim_fire("GET_ITEM_INFO_RECEIVED", id, true)
        end)
        return
    end
    if sim_cached[id] ~= true then return end
    local link = "|cffffffff|Hitem:" .. id .. "::::::::|h[" .. it.name .. "]|h|r"
    return it.name, link, it.quality or 1, it.ilvl or 1, it.req or 1, "Type", it.subType or "Sub", 20,
        it.equip or "", "icon" .. id, 1, it.class, it.sub or 0
end
sim_ItemInfo = GetItemInfo      -- til mock'ens egen tooltip, også når GetItemInfo er fjernet (Mainline)
function GetItemInfoInstant(id)
    local it = sim_items[id]
    return id, "Type", "Sub", "", "icon" .. id, it and it.class or 15, it and it.sub or 0
end
function GetItemCount(id)
    local n = 0
    for _, bag in pairs(sim_me.bags) do
        for _, slot in ipairs(bag) do
            if slot[1] == id then n = n + slot[2] end
        end
    end
    return n
end
ITEM_QUALITY_COLORS = {}
for q = 0, 5 do ITEM_QUALITY_COLORS[q] = { r = 1, g = 1, b = 1, hex = "|cffffffff" } end
sim_spellText = {}
function GetItemIcon(id) return "icon" .. id end

------------------------------------------------------------------------
-- Klientsprog: sim_me.profs bruger engelske navne, men API'et svarer på klientens sprog.
-- "deDE" har de rigtige tyske navne. "xxXX" er et opdigtet sprog, som addonen ikke kan have en
-- færdig tabel for; det viser, at opslaget via spellnavne virker.
------------------------------------------------------------------------

sim_locale = sim_locale or "enUS"
function GetLocale() return sim_locale end

local PROF_NAMES = {
    deDE = { ["Alchemy"] = "Alchemie", ["Blacksmithing"] = "Schmiedekunst", ["Enchanting"] = "Verzauberkunst",
        ["Engineering"] = "Ingenieurskunst", ["Herbalism"] = "Kräuterkunde", ["Jewelcrafting"] = "Juwelenschleifen",
        ["Leatherworking"] = "Lederverarbeitung", ["Mining"] = "Bergbau", ["Skinning"] = "Kürschnerei",
        ["Tailoring"] = "Schneiderei", ["Cooking"] = "Kochkunst", ["First Aid"] = "Erste Hilfe",
        ["Fishing"] = "Angeln" },
}
function sim_profName(name)
    if sim_locale == "xxXX" then return name .. "~xx" end
    local names = PROF_NAMES[sim_locale]
    return names and names[name] or name
end

-- Professionernes spells (Apprentice). Herbalism har ingen spell med professionens navn: den hedder
-- "Herb Gathering" (deDE "Kräutersammeln").
local PROF_SPELLS = { [2259] = "Alchemy", [2018] = "Blacksmithing", [7411] = "Enchanting", [4036] = "Engineering",
    [25229] = "Jewelcrafting", [2108] = "Leatherworking", [2575] = "Mining", [8613] = "Skinning",
    [3908] = "Tailoring", [2550] = "Cooking", [3273] = "First Aid", [7620] = "Fishing", [2366] = "Herb Gathering" }
-- Mainline: skill line-ID pr. profession.
sim_profIDs = { ["Alchemy"] = 171, ["Blacksmithing"] = 164, ["Enchanting"] = 333, ["Engineering"] = 202,
    ["Herbalism"] = 182, ["Jewelcrafting"] = 755, ["Leatherworking"] = 165, ["Mining"] = 186, ["Skinning"] = 393,
    ["Tailoring"] = 197, ["Cooking"] = 185, ["First Aid"] = 129, ["Fishing"] = 356 }

function sim_spellName(id)
    if sim_spells[id] then return sim_spells[id] end
    local prof = PROF_SPELLS[id]
    if not prof then return nil end
    if prof == "Herb Gathering" then return sim_locale == "deDE" and "Kräutersammeln" or prof end
    return sim_profName(prof)
end

sim_spells = {}
function GetSpellInfo(id) return sim_spellName(id) end
function GetSpellTexture(id) return "spellicon" .. id end
function GetSpellLink(id) return sim_spells[id] and ("|Hspell:" .. id .. "|h[" .. sim_spells[id] .. "]|h") end

------------------------------------------------------------------------
-- Professions (TradeSkill + Craft) og skills
------------------------------------------------------------------------

sim_openTrade, sim_openCraft = nil, nil

local function ProfByName(name)
    for _, p in ipairs(sim_me.profs) do if p.name == name then return p end end
end

function GetTradeSkillLine()
    local p = sim_openTrade and ProfByName(sim_openTrade)
    if not p then return "UNKNOWN", 0, 0 end
    return sim_profName(p.name), p.rank, p.max
end
function GetNumTradeSkills()
    local p = sim_openTrade and ProfByName(sim_openTrade)
    return p and (#p.recipes + 1) or 0
end
function GetTradeSkillInfo(i)
    if i == 1 then return "Header", "header", 0, true end
    return "Recipe", "optimal", 0, false
end
function GetTradeSkillItemLink(i)
    local p = ProfByName(sim_openTrade)
    local id = p.recipes[i - 1]
    return id and ("|Hitem:" .. id .. "::::|h[x]|h")
end

local function TradeReagents(i)
    local p = ProfByName(sim_openTrade)
    return p.reagents and p.reagents[p.recipes[i - 1]] or {}
end
function GetTradeSkillNumReagents(i) return #TradeReagents(i) / 2 end
function GetTradeSkillReagentInfo(i, r)
    local list = TradeReagents(i)
    return "Reagent", "icon", list[r * 2], 0
end
function GetTradeSkillReagentItemLink(i, r)
    local list = TradeReagents(i)
    return "|Hitem:" .. list[r * 2 - 1] .. "::|h[x]|h"
end
function GetTradeSkillNumMade() return 1, 1 end

local function CraftReagents(i)
    local p = ProfByName(sim_openCraft)
    return p.reagents and p.reagents[p.recipes[i]] or {}
end
function GetCraftNumReagents(i) return #CraftReagents(i) / 2 end
function GetCraftReagentInfo(i, r) return "Reagent", "icon", CraftReagents(i)[r * 2], 0 end
function GetCraftReagentItemLink(i, r) return "|Hitem:" .. CraftReagents(i)[r * 2 - 1] .. "::|h[x]|h" end

function GetCraftDisplaySkillLine()
    local p = sim_openCraft and ProfByName(sim_openCraft)
    if not p then return nil end
    return sim_profName(p.name), p.rank, p.max
end
function GetNumCrafts()
    local p = sim_openCraft and ProfByName(sim_openCraft)
    return p and #p.recipes or 0
end
function GetCraftInfo(i) return "Enchant", "", "optimal", 0, false end
function GetCraftItemLink(i)
    local p = ProfByName(sim_openCraft)
    return "|Henchant:" .. p.recipes[i] .. "|h[x]|h"
end

-- Skills-listen som i spillet: overskrifter med linjer under. sim_skillsCollapsed lukker
-- "Professions", så professionerne ikke er med; sim_skillsLoaded = false er lige efter login,
-- før listen er indlæst.
sim_skillsCollapsed = false
sim_skillsLoaded = true
local function SkillLines()
    if not sim_skillsLoaded then return {} end
    local lines = { { name = "Professions", header = true, expanded = not sim_skillsCollapsed } }
    if not sim_skillsCollapsed then
        for _, p in ipairs(sim_me.profs) do
            table.insert(lines, { name = sim_profName(p.name), rank = p.rank, max = p.max })
        end
    end
    table.insert(lines, { name = "Languages", header = true, expanded = true })
    table.insert(lines, { name = "Common", rank = 300, max = 300 })
    return lines
end
function GetNumSkillLines() return #SkillLines() end
function GetSkillLineInfo(i)
    local line = SkillLines()[i]
    if not line then return end
    if line.header then return line.name, true, line.expanded, 0, 0, 0, 0 end
    return line.name, false, false, line.rank, 0, 0, line.max
end

------------------------------------------------------------------------
-- Tasker, bank og guild bank
------------------------------------------------------------------------

NUM_BAG_SLOTS, NUM_BANKBAGSLOTS, BANK_CONTAINER = 4, 7, -1
C_Container = {
    GetContainerNumSlots = function(bag)
        local b = sim_me.bags[bag]
        return b and #b or 0
    end,
    GetContainerItemInfo = function(bag, slot)
        local s = sim_me.bags[bag] and sim_me.bags[bag][slot]
        if not s then return nil end
        return { itemID = s[1], stackCount = s[2] }
    end,
}

sim_gbank = { { 23445, 20 }, { 10620, 40 } }    -- én fane
function GetNumGuildBankTabs() return 1 end
function GetGuildBankTabInfo() return "Tab", "icon", true end
function QueryGuildBankTab() end
function GetCurrentGuildBankTab() return 1 end
function GetGuildBankItemLink(tab, slot)
    local s = sim_gbank[slot]
    return s and ("|Hitem:" .. s[1] .. "::|h[x]|h")
end
function GetGuildBankItemInfo(tab, slot)
    local s = sim_gbank[slot]
    return "icon", s and s[2] or 0, false
end
MAX_GUILDBANK_SLOTS_PER_TAB = 98

------------------------------------------------------------------------
-- Netværk
------------------------------------------------------------------------

Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, NotInGroup = 5,
    ChannelThrottle = 8, GeneralError = 9 } }
local prefixes = {}
C_ChatInfo = {
    RegisterAddonMessagePrefix = function(p) prefixes[p] = true return true end,
    IsAddonMessagePrefixRegistered = function(p) return prefixes[p] or false end,
    SendAddonMessage = function(prefix, text, channel, target)
        assert(#text <= 255, "addon-besked over 255 bytes")
        if channel == "GUILD" and not sim_me.guild then return 9 end
        sim_py_send(prefix, text, channel, target)
        return 0
    end,
}
C_ChatInfo.SendAddonMessageLogged = C_ChatInfo.SendAddonMessage
function sim_deliver(prefix, text, channel, sender)
    if prefixes[prefix] then sim_fire("CHAT_MSG_ADDON", prefix, text, channel, sender) end
end

------------------------------------------------------------------------
-- Mainline-profil (retail / WoW Forever): sim_flavor == "mainline"
-- De gamle Classic-globaler fjernes, og C_-navnerummene, der erstatter dem, tilføjes. Listen over,
-- hvad der findes og ikke findes, følger Forever-betaens funktionsliste (build 1.60.1.69893).
------------------------------------------------------------------------

sim_tooltipPostCalls = {}

if sim_flavor == "mainline" then
    WOW_PROJECT_ID = 1
    function issecretvalue() return false end
    -- Midnight-reglerne: addon-beskeder er spærret under encounters og M+, også mellem kampene.
    sim_lockdown = false
    C_ChatInfo.InChatMessagingLockdown = function() return sim_lockdown end

    -- Items og spells
    C_Item = {
        GetItemInfo = GetItemInfo, GetItemInfoInstant = GetItemInfoInstant, GetItemCount = GetItemCount,
        GetItemIconByID = GetItemIcon, RequestLoadItemDataByID = function() end,
    }
    C_Spell = {
        GetSpellName = sim_spellName,
        GetSpellTexture = GetSpellTexture, GetSpellLink = GetSpellLink,
    }
    GetItemInfo, GetItemInfoInstant, GetItemCount, GetItemIcon = nil, nil, nil, nil
    GetSpellInfo, GetSpellTexture, GetSpellLink = nil, nil, nil

    -- Professions: C_TradeSkillUI i stedet for TradeSkill-/Craft-funktionerne. Alle professions, også
    -- Enchanting, åbnes i samme vindue (sim_openTrade). En recipe er et spell-ID.
    local RECIPE_BASE = 100000      -- recipe-ID for et item = RECIPE_BASE + item-ID
    local UNLEARNED = 999999        -- en recipe, man ikke har lært (må ikke komme med)
    local function OpenProf() return sim_openTrade and ProfByName(sim_openTrade) end
    Enum.CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3 }
    C_TradeSkillUI = {
        IsTradeSkillReady = function() return OpenProf() ~= nil end,
        IsTradeSkillLinked = function() return sim_tradeLinked or false end,
        IsTradeSkillGuild = function() return false end,
        IsNPCCrafting = function() return false end,
        GetBaseProfessionInfo = function()
            local p = OpenProf()
            if not p then return { professionName = "" } end
            return { professionName = sim_profName(p.name), professionID = sim_profIDs[p.name],
                skillLevel = p.rank, maxSkillLevel = p.max }
        end,
        GetAllRecipeIDs = function()
            local p, ids = OpenProf(), {}
            for _, id in ipairs(p and p.recipes or {}) do
                table.insert(ids, p.name == "Enchanting" and id or RECIPE_BASE + id)
            end
            table.insert(ids, UNLEARNED)
            return ids
        end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = recipeID ~= UNLEARNED }
        end,
        GetRecipeSchematic = function(recipeID)
            local p = OpenProf()
            local enchant = p.name == "Enchanting"
            local id = enchant and recipeID or recipeID - RECIPE_BASE
            local slots = {}
            local list = p.reagents and p.reagents[id] or {}
            for i = 1, #list, 2 do
                table.insert(slots, { reagents = { { itemID = list[i] }, { itemID = list[i] + 1000000 } },
                    quantityRequired = list[i + 1], reagentType = 1, required = true })
            end
            -- Valgfri plads (fx finishing reagent): må ikke tælles som fast reagent.
            table.insert(slots, { reagents = { { itemID = 6948 } }, quantityRequired = 1, reagentType = 2,
                required = false })
            return { recipeID = recipeID, outputItemID = (not enchant) and id or nil, quantityMin = 1,
                reagentSlotSchematics = slots }
        end,
    }
    GetNumTradeSkills, GetTradeSkillLine, GetTradeSkillInfo, GetTradeSkillItemLink = nil, nil, nil, nil
    GetTradeSkillNumReagents, GetTradeSkillReagentInfo, GetTradeSkillReagentItemLink = nil, nil, nil
    GetTradeSkillNumMade = nil
    GetNumCrafts, GetCraftInfo, GetCraftItemLink, GetCraftDisplaySkillLine = nil, nil, nil, nil
    GetCraftNumReagents, GetCraftReagentInfo, GetCraftReagentItemLink = nil, nil, nil

    -- Skills: GetProfessions/GetProfessionInfo i stedet for skill lines.
    GetNumSkillLines, GetSkillLineInfo = nil, nil
    function GetProfessions()
        local indexes = {}
        for i = 1, #sim_me.profs do indexes[i] = i end
        return unpack(indexes)
    end
    function GetProfessionInfo(index)
        local p = sim_me.profs[index]
        return sim_profName(p.name), "icon", p.rank, p.max, 0, 0, sim_profIDs[p.name]
    end

    -- Talents: ingen talent-tabs. Rollen kommer fra specialization, hvis spilleren har en.
    GetNumTalentTabs, GetTalentTabInfo = nil, nil
    C_SpecializationInfo = {
        GetSpecialization = function() return sim_me.specRole and 1 or nil end,
        GetSpecializationInfo = function() return 1, "Spec", "", "icon", sim_me.specRole end,
    }

    -- Bank: købte faner i stedet for bank-tasker. Reagent-taske som 5. taske.
    BANK_CONTAINER, NUM_BANKBAGSLOTS = nil, nil
    NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5
    Enum.BankType = { Character = 0, Guild = 1, Account = 2 }
    C_Bank = { FetchPurchasedBankTabIDs = function() return { 12, 13 } end }

    -- Menuer: MenuUtil i stedet for UIDropDownMenu. Punkterne lander i sim_menu ligesom før.
    MenuUtil = {
        CreateContextMenu = function(owner, generator)
            sim_menu = {}
            generator(owner, {
                CreateTitle = function(_, text) table.insert(sim_menu, { text = text, isTitle = true }) end,
                CreateButton = function(_, text, func) table.insert(sim_menu, { text = text, func = func }) end,
            })
        end,
    }
    UIDropDownMenu_Initialize, UIDropDownMenu_CreateInfo, UIDropDownMenu_AddButton = nil, nil, nil
    ToggleDropDownMenu = nil

    -- Tooltips: TooltipDataProcessor i stedet for OnTooltipSetItem.
    Enum.TooltipDataType = { Item = 0, Spell = 1 }
    TooltipDataProcessor = {
        AddTooltipPostCall = function(_, fn) table.insert(sim_tooltipPostCalls, fn) end,
    }
    function Methods:HasScript(name) return name ~= "OnTooltipSetItem" end

    -- Templates og guild
    C_XMLUtil = { GetTemplateInfo = function(name) return name ~= "CharacterFrameTabButtonTemplate" and {} or nil end }
    C_GuildInfo.MemberExistsByName = function(name)
        for _, m in ipairs(sim_roster) do
            if m.name == name or m.name:match("^([^%-]+)") == name then return true end
        end
        return false
    end
end

------------------------------------------------------------------------
-- SavedVariables: serialisering til tekst (simulerer logout/login)
------------------------------------------------------------------------

local function Dump(v, indent)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    local parts = {}
    for k, val in pairs(v) do
        local key = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
        table.insert(parts, key .. "=" .. Dump(val))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
function sim_dump(v) return Dump(v) end
function sim_load_sv(text)
    if text and text ~= "" then _G[sim_addon .. "DB"] = loadstring("return " .. text)() end
end

-- Indlæser en addon-fil med (addonName, ns) som varargs, ligesom WoW.
function sim_load_file(path, code, ns)
    local chunk, err = loadstring(code, "@" .. path)
    if not chunk then error(err) end
    chunk(sim_addon, ns)
end
