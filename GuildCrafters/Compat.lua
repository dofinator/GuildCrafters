local _, ns = ...

-- Alle API-kald, der kan variere mellem clients (TBC Anniversary, Classic Era, WoW Forever),
-- ligger her. Resten af addonen kalder kun Compat.
local Compat = {}
ns.Compat = Compat

Compat.GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
Compat.IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded or function() return false end

-- To klient-familier: Classic-klienterne (TBC Anniversary, Classic Era) med de gamle globale funktioner,
-- og Mainline-klienten (retail og WoW Forever, interface 16001), hvor de er fjernet og erstattet af
-- C_-navnerum. Tjekket mod Forever-betaens funktionsliste (build 1.60.1.69893) 2026-10-12.
Compat.IS_MAINLINE = GetNumTradeSkills == nil and C_TradeSkillUI ~= nil and C_TradeSkillUI.GetAllRecipeIDs ~= nil

local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)

function Compat.RealmName()
    return (GetNormalizedRealmName and GetNormalizedRealmName())
        or (GetRealmName():gsub("[%s%-]", ""))
end

-- Kaldes meget (hver sammenligning i en sortering efter online-status): i belastningstesten med 200
-- addon-brugere var det 620.000 kald pr. opdatering af Crafting-fanen. Navn og realm ændrer sig ikke
-- efter login, så nøglen huskes derfra.
local playerKey
function Compat.PlayerKey()
    if playerKey then return playerKey end
    local key = UnitName("player") .. "-" .. Compat.RealmName()
    if ns.loggedIn then playerKey = key end
    return key
end

-- Navne fra guild-roster og addon-beskeder kan mangle realm. Gør dem til "Navn-Realm".
function Compat.FullName(name)
    if not name or name == "" then return end
    if name:find("-", 1, true) then return name end
    return name .. "-" .. Compat.RealmName()
end

function Compat.ShortName(key)
    return (key:match("^([^%-]+)")) or key
end

------------------------------------------------------------------------
-- Guild
------------------------------------------------------------------------

-- "Realm/Guildnavn" eller nil, hvis vi ikke er i en guild (eller den ikke er indlæst endnu).
function Compat.GuildKey()
    if not IsInGuild() then return nil end
    local guildName = GetGuildInfo("player")
    if not guildName then return nil end
    return Compat.RealmName() .. "/" .. guildName
end

function Compat.RequestGuildRoster()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

-- Returnerer en liste af { key, level, class (fil-token), online, zone, note, index }, og om listen
-- er komplet: kun så må et navn, der mangler, regnes for "ikke længere i guilden".
-- Ikke komplet: rosteren er ikke indlæst endnu (0 medlemmer), eller der kunne læses færre navne end
-- det samlede antal. Med "Show Offline Members" slået fra er det uvist, om klienten kun giver
-- online-medlemmerne (og måske også kun tæller dem); derfor kræves der så mindst ét offline medlem
-- blandt de læste, før listen regnes for hele guilden.
function Compat.GetGuildMembers()
    local members = {}
    if not IsInGuild() then return members, false end
    local total = GetNumGuildMembers() or 0
    local anyOffline = false
    for i = 1, total do
        local name, _, _, level, _, zone, note, _, online, _, classFile = GetGuildRosterInfo(i)
        if name then
            if not online then anyOffline = true end
            table.insert(members, {
                key = Compat.FullName(name),
                level = level,
                class = classFile,
                online = online and true or false,
                zone = zone,
                note = note ~= "" and note or nil,
                index = i,
            })
        end
    end
    local showsOffline = GetGuildRosterShowOffline and GetGuildRosterShowOffline() and true or false
    local complete = total > 0 and #members == total and (showsOffline or anyOffline)
    return members, complete
end

-- "3 days" / "5 hours" siden et offline medlem sidst var online, eller nil hvis det ikke kan slås op.
-- index er pladsen i rosteren fra GetGuildMembers; den kan flytte sig, så navnet tjekkes først.
function Compat.GuildLastOnline(index, key)
    if not GetGuildRosterLastOnline or not index then return nil end
    local name = GetGuildRosterInfo(index)
    if not name or Compat.FullName(name) ~= key then return nil end
    local years, months, days, hours = GetGuildRosterLastOnline(index)
    if not hours then return nil end
    local function Unit(n, word) return string.format("%d %s%s", n, word, n == 1 and "" or "s") end
    if (years or 0) > 0 then return Unit(years, "year") end
    if (months or 0) > 0 then return Unit(months, "month") end
    if (days or 0) > 0 then return Unit(days, "day") end
    if hours > 0 then return Unit(hours, "hour") end
    return "less than an hour"
end

-- Er key medlem af vores guild? Bruges til at afvise addon-whispers fra fremmede.
function Compat.IsGuildMember(key)
    if not IsInGuild() then return false end
    if C_GuildInfo and C_GuildInfo.MemberExistsByName then
        if C_GuildInfo.MemberExistsByName(key) or C_GuildInfo.MemberExistsByName(Compat.ShortName(key)) then
            return true
        end
    end
    for _, m in ipairs(Compat.GetGuildMembers()) do
        if m.key == key then return true end
    end
    return false
end

-- Navn til chat/invite: uden realm, hvis det er vores egen realm.
function Compat.ChatName(key)
    local name, realm = key:match("^([^%-]+)%-(.+)$")
    if name and realm == Compat.RealmName() then return name end
    return key
end

-- Åbner en whisper, evt. med en færdig tekst. Chatboksen sætter først sin tekst næste frame, så tekst
-- indsat bagefter blev overskrevet første gang (set i spillet). Derfor åbnes chatten med hele teksten,
-- "/w Navn besked", som spillet selv laver om til "Tell Navn:" med beskeden stående.
function Compat.Whisper(key, message)
    -- Mainline har flyttet chat-funktionerne til ChatFrameUtil (de gamle navne findes stadig i Forever-betaen).
    local openChat = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    local sendTell = (ChatFrameUtil and ChatFrameUtil.SendTell) or ChatFrame_SendTell
    if message and openChat then
        openChat((SLASH_WHISPER1 or "/w") .. " " .. Compat.ChatName(key) .. " " .. message)
    else
        sendTell(Compat.ChatName(key))
    end
end

-- Indsætter et link i den åbne chatboks (shift-klik).
local insertingOwnLink = false
function Compat.InsertLink(link)
    local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
    insertingOwnLink = true      -- vores egne shift-klik skal ikke havne i søgefeltet (se HookLinkInsert)
    local ok, result = pcall(insert, link)
    insertingOwnLink = false
    return ok and result
end

-- Som i auktionshuset: shift-klik på et item (tasker, chat-links) uden åben chatboks kalder
-- fn(link); returnerer fn true, har et synligt søgefelt taget imod navnet. Spillet åbner derefter selv
-- "split stack" for stakke (linket blev jo ikke sat ind i chatten), så det vindue lukkes igen.
-- Efter-hook (hooksecurefunc): at erstatte funktionen ville gøre chatten tainted.
function Compat.HookLinkInsert(fn)
    local function OnInsert(link)
        if insertingOwnLink or type(link) ~= "string" then return end
        local active = (ChatFrameUtil and ChatFrameUtil.GetActiveWindow) or ChatEdit_GetActiveWindow
        if active and active() then return end
        if fn(link) and C_Timer and StackSplitFrame then
            C_Timer.After(0, function()
                if StackSplitFrame:IsShown() then StackSplitFrame:Hide() end
            end)
        end
    end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
        hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsert)
    elseif ChatEdit_InsertLink then
        hooksecurefunc("ChatEdit_InsertLink", OnInsert)
    end
end

function Compat.Invite(key)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(Compat.ChatName(key))
    else
        InviteUnit(Compat.ChatName(key))
    end
end

-- Er spilleren i kamp? Så venter synkroniseringen (se Comm.lua). På Mainline (Midnight-reglerne, også
-- i WoW Forever) tæller encounter-lockdown med: addon-beskeder er spærret under raid-encounters og M+.
-- Navnene er tjekket mod Forever-betaens funktionsliste (build 69893); pcall, fordi de ikke er prøvet i
-- en rigtig klient.
local LOCKDOWN_CHECKS = { "InChatMessagingLockdown", "AreOutgoingAddonChatMessagesRestricted" }
function Compat.InCombat()
    if InCombatLockdown and InCombatLockdown() then return true end
    local C = C_ChatInfo
    for _, name in ipairs(LOCKDOWN_CHECKS) do
        local fn = C and C[name]
        if fn then
            local ok, locked = pcall(fn)
            if ok and locked == true then return true end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Talents
------------------------------------------------------------------------

-- Point brugt i et talent-træ. GetTalentTabInfo har forskellige returværdier mellem clients:
-- Classic/TBC: name, icon, pointsSpent, ...   Wrath+: id, name, description, icon, pointsSpent, ...
function Compat.GetTalentTabPoints(tab)
    local a, _, c, _, e = GetTalentTabInfo(tab)
    if type(a) == "string" then
        return tonumber(c) or 0
    end
    return tonumber(e) or 0
end

function Compat.GetNumTalentTabs()
    return GetNumTalentTabs and GetNumTalentTabs() or 0
end

-- Mainline har ingen talent-tabs (talents ligger i C_Traits). Har klienten specializations (retail),
-- giver den rollen direkte: "TANK", "HEALER" eller "DPS". Ellers nil, og man bruger /gc role.
function Compat.SpecRole()
    local S = C_SpecializationInfo
    if not (S and S.GetSpecialization and S.GetSpecializationInfo) then return nil end
    local ok, role = pcall(function()
        local index = S.GetSpecialization()
        if not index then return nil end
        return (select(5, S.GetSpecializationInfo(index)))
    end)
    if not ok then return nil end
    if role == "DAMAGER" then return "DPS" end
    if role == "TANK" or role == "HEALER" then return role end
    return nil
end

function Compat.SpellName(id)
    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(id)
    end
    return (GetSpellInfo(id))
end

-- Returnerer "item"/"enchant" og ID ud fra et item-, enchant- eller spell-link.
function Compat.ParseLink(link)
    if not link then return end
    local id = link:match("item:(%d+)")
    if id then return "item", tonumber(id) end
    id = link:match("enchant:(%d+)") or link:match("spell:(%d+)")
    if id then return "enchant", tonumber(id) end
end

------------------------------------------------------------------------
-- Professionsnøgler: det engelske navn ("Alchemy"), uanset klientens sprog
------------------------------------------------------------------------

-- Classic-klienterne giver kun professionens navn på klientens sprog, og det navn var nøglen i data og
-- beskeder: en tysk klient sendte "Alchimie", som ingen andre kunne slå op (intet ikon, ingen filtre).
-- Nøglen er nu altid det engelske navn, så enUS-klienter og 0.14-klienter ser det, de altid har set.

-- Mainline har et fast ID pr. profession (skill line).
local PROF_BY_ID = {
    [171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting", [202] = "Engineering",
    [182] = "Herbalism", [773] = "Inscription", [755] = "Jewelcrafting", [165] = "Leatherworking",
    [186] = "Mining", [393] = "Skinning", [197] = "Tailoring", [185] = "Cooking", [129] = "First Aid",
    [356] = "Fishing",
}

-- Classic: professionens spell hedder det samme som professionen på klientens sprog (Apprentice-rank).
-- Herbalism er undtagelsen: dens spell hedder "Herb Gathering", så den kommer kun fra tabellen nedenfor.
local PROF_SPELLS = {
    ["Alchemy"] = 2259, ["Blacksmithing"] = 2018, ["Enchanting"] = 7411, ["Engineering"] = 4036,
    ["Jewelcrafting"] = 25229, ["Leatherworking"] = 2108, ["Mining"] = 2575, ["Skinning"] = 8613,
    ["Tailoring"] = 3908, ["Cooking"] = 2550, ["First Aid"] = 3273, ["Fishing"] = 7620,
}

-- Kendte navne på andre sprog. Bruges til navne modtaget fra ikke-engelske 0.14-klienter (dem kan
-- vores egen klient ikke slå op) og som reserve for ens eget sprog. Skrevet efter hukommelsen og ikke
-- tjekket i de enkelte klienter: et navn, der ikke står her, vises bare, som det er.
local PROF_NAMES = {
    ["Alchemy"] = { "Alchemie", "Alchimie", "Alquimia", "Alchimia", "Алхимия", "연금술", "炼金术", "鍊金術" },
    ["Blacksmithing"] = { "Schmiedekunst", "Forge", "Herrería", "Ferraria", "Forgiatura", "Кузнечное дело",
        "대장기술", "锻造", "鍛造" },
    ["Enchanting"] = { "Verzauberkunst", "Enchantement", "Encantamiento", "Encantamento", "Incantamento",
        "Наложение чар", "마법부여", "附魔" },
    ["Engineering"] = { "Ingenieurskunst", "Ingénierie", "Ingeniería", "Engenharia", "Ingegneria",
        "Инженерное дело", "기계공학", "工程学", "工程學" },
    ["Herbalism"] = { "Kräuterkunde", "Herboristerie", "Herboristería", "Herborismo", "Erbalismo",
        "Травничество", "약초채집", "草药学", "草藥學" },
    ["Inscription"] = { "Inschriftenkunde", "Calligraphie", "Inscripción", "Escrivania", "Runografia",
        "Начертание", "주문각인", "铭文", "銘文學" },
    ["Jewelcrafting"] = { "Juwelenschleifen", "Juwelierskunst", "Joaillerie", "Joyería", "Joalheria",
        "Oreficeria", "Ювелирное дело", "보석세공", "珠宝加工", "珠寶設計" },
    ["Leatherworking"] = { "Lederverarbeitung", "Travail du cuir", "Peletería", "Couraria", "Conciatura",
        "Кожевничество", "가죽세공", "制皮", "製皮" },
    ["Mining"] = { "Bergbau", "Minage", "Minería", "Mineração", "Estrazione", "Горное дело", "채광", "采矿",
        "採礦" },
    ["Skinning"] = { "Kürschnerei", "Dépeçage", "Desuello", "Esfolamento", "Scuoiatura", "Снятие шкур",
        "무두질", "剥皮", "剝皮" },
    ["Tailoring"] = { "Schneiderei", "Couture", "Sastrería", "Alfaiataria", "Sartoria", "Портняжное дело",
        "재봉술", "裁缝", "裁縫" },
    ["Cooking"] = { "Kochkunst", "Cuisine", "Cocina", "Culinária", "Cucina", "Кулинария", "요리", "烹饪",
        "烹飪" },
    ["First Aid"] = { "Erste Hilfe", "Secourisme", "Primeros auxilios", "Primeiros Socorros",
        "Primo Soccorso", "Первая помощь", "응급치료", "急救" },
    ["Fishing"] = { "Angeln", "Pêche", "Pesca", "Рыбная ловля", "낚시", "钓鱼", "釣魚" },
}

local profKeys          -- [navn] = engelsk nøgle
local spellsMissing     -- spellnavne, der ikke var indlæst, da tabellen blev bygget
local keyBuilds = 0     -- en spell, klienten slet ikke har (Jewelcrafting i Classic Era), kommer aldrig:
local MAX_KEY_BUILDS = 5 -- prøv kun et par gange, ellers blev tabellen bygget igen for hvert ukendt navn

local function BuildProfKeys()
    keyBuilds = keyBuilds + 1
    profKeys, spellsMissing = {}, false
    for key, names in pairs(PROF_NAMES) do
        for _, name in ipairs(names) do profKeys[name] = key end
    end
    -- Klientens egne navne vinder over tabellen.
    if not Compat.IS_MAINLINE and GetLocale and GetLocale() ~= "enUS" then
        for key, spellID in pairs(PROF_SPELLS) do
            local name = Compat.SpellName(spellID)
            if name then profKeys[name] = key else spellsMissing = true end
        end
    end
    for key in pairs(PROF_NAMES) do profKeys[key] = key end
end

-- Den faste nøgle for en profession ud fra navnet (på et hvilket som helst kendt sprog) og, på
-- Mainline, dens ID. Ukendte navne returneres uændret.
function Compat.ProfessionKey(name, id)
    if id and PROF_BY_ID[id] then return PROF_BY_ID[id] end
    if not name then return nil end
    if not profKeys or (spellsMissing and not profKeys[name] and keyBuilds < MAX_KEY_BUILDS) then
        BuildProfKeys()
    end
    return profKeys[name] or name
end

local function NewScan(name, rank, maxRank)
    return { name = name, rank = rank, max = maxRank, items = {}, enchants = {}, reagents = {},
        collapsed = false }
end

-- Reagents gemmes som { made = antal der laves, r = { itemID, antal, itemID, antal, ... } }.
-- Gemmes kun, hvis alle reagent-links var tilgængelige (ellers er listen ufuldstændig).
local function ReadReagents(numReagents, getLink, getInfo, made)
    local list = {}
    for r = 1, numReagents do
        local link = getLink(r)
        local id = link and tonumber(link:match("item:(%d+)"))
        local _, _, count = getInfo(r)
        if not id or not count then return nil end
        table.insert(list, id)
        table.insert(list, count)
    end
    if #list == 0 then return nil end
    return { made = made or 1, r = list }
end

local function AddRecipe(scan, link, reagents)
    local kind, id = Compat.ParseLink(link)
    if kind == "item" then
        scan.items[id] = true
        if reagents then scan.reagents["i" .. id] = reagents end
    elseif kind == "enchant" then
        scan.enchants[id] = true
        if reagents then scan.reagents["e" .. id] = reagents end
    end
end

-- Mainline (retail / WoW Forever): professions læses med C_TradeSkillUI. Alle professions, også
-- Enchanting, bruger samme vindue; der er intet Craft-vindue. En recipe er et spell-ID; laver den et
-- item, gemmes item-ID'et ("i"), ellers recipe-ID'et som enchant ("e"), ligesom i Classic-klienterne.
local function ReadTradeSkillMainline()
    local T = C_TradeSkillUI
    if T.IsTradeSkillReady and not T.IsTradeSkillReady() then return end
    if (T.IsTradeSkillLinked and T.IsTradeSkillLinked()) or (T.IsTradeSkillGuild and T.IsTradeSkillGuild())
        or (T.IsNPCCrafting and T.IsNPCCrafting()) then
        return      -- en andens profession (link), guildens eller en NPC's
    end
    local info = T.GetBaseProfessionInfo and T.GetBaseProfessionInfo()
    local name = info and (info.parentProfessionName or info.professionName)
    if not name or name == "" then return end
    name = Compat.ProfessionKey(name, info.parentProfessionID or info.professionID)

    local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
    local scan = NewScan(name, info.skillLevel or 0, info.maxSkillLevel or 0)
    for _, recipeID in ipairs(T.GetAllRecipeIDs() or {}) do
        local recipe = T.GetRecipeInfo(recipeID)
        if recipe and recipe.learned then
            local schematic = T.GetRecipeSchematic and T.GetRecipeSchematic(recipeID, false)
            -- Faste reagents: første (laveste) kvalitet i hver påkrævet plads.
            local list, complete = {}, true
            for _, slot in ipairs(schematic and schematic.reagentSlotSchematics or {}) do
                if slot.required ~= false and (basic == nil or slot.reagentType == basic) then
                    local first = slot.reagents and slot.reagents[1]
                    if first and first.itemID and slot.quantityRequired then
                        table.insert(list, first.itemID)
                        table.insert(list, slot.quantityRequired)
                    else
                        complete = false
                    end
                end
            end
            local reagents = complete and #list > 0
                and { made = schematic and schematic.quantityMin or 1, r = list } or nil
            local itemID = schematic and schematic.outputItemID
            if itemID then
                scan.items[itemID] = true
                if reagents then scan.reagents["i" .. itemID] = reagents end
            else
                scan.enchants[recipeID] = true
                if reagents then scan.reagents["e" .. recipeID] = reagents end
            end
        end
    end
    return scan
end

-- Læser det åbne TradeSkill-vindue. Returnerer nil, hvis intet (eget) vindue er åbent.
function Compat.ReadTradeSkill()
    if Compat.IS_MAINLINE then return ReadTradeSkillMainline() end
    if not GetNumTradeSkills then return end
    if IsTradeSkillLinked and IsTradeSkillLinked() then return end
    local name, rank, maxRank = GetTradeSkillLine()
    if not name or name == "UNKNOWN" then return end
    name = Compat.ProfessionKey(name)

    local scan = NewScan(name, rank, maxRank)
    for i = 1, GetNumTradeSkills() do
        local _, skillType, _, isExpanded = GetTradeSkillInfo(i)
        if skillType == "header" or skillType == "subheader" then
            if not isExpanded then scan.collapsed = true end
        elseif skillType then
            local made = GetTradeSkillNumMade and GetTradeSkillNumMade(i)
            local reagents = GetTradeSkillNumReagents and ReadReagents(GetTradeSkillNumReagents(i),
                function(r) return GetTradeSkillReagentItemLink(i, r) end,
                function(r) return GetTradeSkillReagentInfo(i, r) end, made)
            AddRecipe(scan, GetTradeSkillItemLink(i)
                or (GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(i)), reagents)
        end
    end
    return scan
end

-- Læser det åbne Craft-vindue (Enchanting i Classic-clients).
-- Hunterens Beast Training bruger samme vindue, men har ingen skill line, så den springes over.
function Compat.ReadCraft()
    if not GetNumCrafts then return end
    local name, rank, maxRank = GetCraftDisplaySkillLine()
    if not name then return end
    name = Compat.ProfessionKey(name)

    local scan = NewScan(name, rank, maxRank)
    for i = 1, GetNumCrafts() do
        local _, _, craftType, _, isExpanded = GetCraftInfo(i)
        if craftType == "header" then
            if not isExpanded then scan.collapsed = true end
        elseif craftType then
            local reagents = GetCraftNumReagents and ReadReagents(GetCraftNumReagents(i),
                function(r) return GetCraftReagentItemLink(i, r) end,
                function(r) return GetCraftReagentInfo(i, r) end, 1)
            AddRecipe(scan, GetCraftItemLink(i), reagents)
        end
    end
    return scan
end

function Compat.ExpandAll(kind)
    if kind == "trade" and ExpandTradeSkillSubClass then
        ExpandTradeSkillSubClass(0)
    elseif kind == "craft" and ExpandCraftSkillLine then
        ExpandCraftSkillLine(0)
    end
end

-- Returnerer { [nøgle] = { rank, max } } for alle synlige skill lines (professions under deres faste
-- nøgle, se Compat.ProfessionKey), og om listen er komplet.
-- Lukkede headers i Skills-fanen skjuler linjer, og lige efter login er listen tom: kun en komplet
-- liste må bruges til at konkludere, at en profession er droppet.
function Compat.GetSkillRanks()
    local ranks = {}
    if not GetNumSkillLines then
        -- Mainline: GetProfessions() giver et indeks pr. profession (med huller for dem, man ikke har).
        if not (GetProfessions and GetProfessionInfo) then return ranks, false end
        local indexes = { GetProfessions() }
        for i = 1, select("#", GetProfessions()) do
            local index = indexes[i]
            if index then
                local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
                if name then ranks[Compat.ProfessionKey(name, skillLine)] = { rank = rank, max = maxRank } end
            end
        end
        -- En tom liste kan være "ikke indlæst endnu" lige så vel som "ingen professions": ikke komplet.
        return ranks, next(ranks) ~= nil
    end
    local headers, collapsed = 0, false
    for i = 1, GetNumSkillLines() do
        local name, isHeader, isExpanded, rank, _, _, maxRank = GetSkillLineInfo(i)
        if isHeader then
            headers = headers + 1
            if not isExpanded then collapsed = true end
        elseif name then
            ranks[Compat.ProfessionKey(name)] = { rank = rank, max = maxRank }
        end
    end
    return ranks, headers > 0 and not collapsed
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------

-- Findes en XML-template i denne client? Uden C_XMLUtil antager vi ja.
function Compat.HasTemplate(name)
    if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
        return C_XMLUtil.GetTemplateInfo(name) ~= nil
    end
    return true
end

-- Fane-template og afstanden mellem faner for den template.
function Compat.TabTemplate()
    if C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo("PanelTabButtonTemplate") then
        return "PanelTabButtonTemplate", 3
    end
    return "CharacterFrameTabButtonTemplate", -16
end

-- Højreklik-menu. items = { { text = "...", func = fn } | { text = "...", isTitle = true } }
-- Bruger det nye Menu-API, hvis det findes, ellers UIDropDownMenu.
local dropdown
function Compat.ContextMenu(owner, items)
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(owner, function(_, root)
            for _, item in ipairs(items) do
                if item.isTitle then
                    root:CreateTitle(item.text)
                else
                    root:CreateButton(item.text, item.func)
                end
            end
        end)
        return
    end

    dropdown = dropdown or CreateFrame("Frame", "GuildCraftersContextMenu", UIParent, "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(dropdown, function(_, level)
        for _, item in ipairs(items) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = item.text
            info.isTitle = item.isTitle
            info.notCheckable = true
            info.func = item.func
            UIDropDownMenu_AddButton(info, level)
        end
    end, "MENU")
    ToggleDropDownMenu(1, nil, dropdown, "cursor", 0, 0)
end

------------------------------------------------------------------------
-- Items, spells og tid
------------------------------------------------------------------------

Compat.Now = GetServerTime or time

local GetInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

function Compat.ItemClassID(id)
    if GetInstant then
        local _, _, _, _, _, classID = GetInstant(id)
        return classID
    end
    return (select(12, GetItemInfo(id)))
end

-- Crafting-mats: Trade Goods (7), Reagent (5) og Gem (3).
local MAT_CLASSES = { [7] = true, [5] = true, [3] = true }
function Compat.IsCraftingMat(id)
    return MAT_CLASSES[Compat.ItemClassID(id) or -1] or false
end

local requested = {}
-- Navn på et item, eller nil hvis det ikke er i cachen endnu (så bestilles det fra serveren,
-- og GET_ITEM_INFO_RECEIVED kommer, når det er klar).
function Compat.ItemName(id)
    local name = GetItemInfo(id)
    if not name and not requested[id] then
        requested[id] = true
        if C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(id)
        end
    end
    return name
end

function Compat.ItemLink(id)
    local _, link = GetItemInfo(id)
    return link
end

-- Detaljer til kategorier og visning, eller nil hvis itemet ikke er i cachen endnu.
function Compat.ItemDetails(id)
    local name, link, quality, itemLevel, reqLevel, itemType, subType, _, equipLoc, icon,
        _, classID, subclassID = GetItemInfo(id)
    if not name then
        Compat.ItemName(id)   -- bestil fra serveren
        return nil
    end
    return {
        name = name, link = link, quality = quality, itemLevel = itemLevel, reqLevel = reqLevel,
        itemType = itemType, subType = subType, equipLoc = equipLoc, icon = icon,
        classID = classID, subclassID = subclassID,
    }
end

function Compat.QualityColor(quality)
    local c = ITEM_QUALITY_COLORS and quality and ITEM_QUALITY_COLORS[quality]
    if c and c.hex then return c.hex end
    if c then return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
    return "|cffffffff"
end

-- Antal af et item i tasker + bank på den aktuelle char.
function Compat.ItemCount(id)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id, true) or 0 end
    return GetItemCount(id, true) or 0
end

-- Al tekst fra et items (eller en enchants) tooltip, så man kan søge i stats og effekter.
-- Returnerer nil, hvis itemet ikke er indlæst endnu.
local scanTip
function Compat.TooltipText(hyperlink)
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "GuildCraftersScanTip", UIParent, "GameTooltipTemplate")
    end
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetHyperlink(hyperlink)
    local parts = {}
    for i = 1, scanTip:NumLines() do
        for _, side in ipairs({ "Left", "Right" }) do
            local line = _G["GuildCraftersScanTipText" .. side .. i]
            local text = line and line:GetText()
            if text and text ~= "" then table.insert(parts, text) end
        end
    end
    scanTip:Hide()
    if #parts == 0 then return nil end
    return table.concat(parts, "\n")
end

function Compat.ItemIcon(id)
    if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(id) end
    return GetItemIcon(id)
end

function Compat.SpellIcon(id)
    if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(id) end
    return GetSpellTexture(id)
end

function Compat.SpellLink(id)
    if C_Spell and C_Spell.GetSpellLink then return C_Spell.GetSpellLink(id) end
    return GetSpellLink and GetSpellLink(id)
end

------------------------------------------------------------------------
-- Tasker og bank
------------------------------------------------------------------------

local NUM_BAGS = NUM_BAG_SLOTS or 4
local NUM_BANK_BAGS = NUM_BANKBAGSLOTS or 7

-- Mainline har en ekstra reagent-taske (NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5).
Compat.BAG_IDS = {}
for bag = 0, (Compat.IS_MAINLINE and NUM_TOTAL_EQUIPPED_BAG_SLOTS) or NUM_BAGS do
    table.insert(Compat.BAG_IDS, bag)
end

local CLASSIC_BANK_IDS = { BANK_CONTAINER or -1 }
for bag = NUM_BAGS + 1, NUM_BAGS + NUM_BANK_BAGS do table.insert(CLASSIC_BANK_IDS, bag) end

-- Bankens containere. Mainline-banken består af købte faner (hver fane er en container); de slås op,
-- når der scannes, fordi man kan købe flere undervejs.
function Compat.BankIDs()
    local bankType = Enum and Enum.BankType and Enum.BankType.Character
    if C_Bank and C_Bank.FetchPurchasedBankTabIDs and bankType then
        return C_Bank.FetchPurchasedBankTabIDs(bankType) or {}
    end
    return CLASSIC_BANK_IDS
end

local function ContainerSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then
        return C_Container.GetContainerNumSlots(bag) or 0
    end
    return GetContainerNumSlots(bag) or 0
end

local function ContainerItem(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then return info.itemID, info.stackCount end
        return
    end
    local _, count, _, _, _, _, link, _, _, itemID = GetContainerItemInfo(bag, slot)
    if not itemID and link then itemID = tonumber(link:match("item:(%d+)")) end
    return itemID, count
end

-- Tæller crafting-mats i en række containere: { [itemID] = antal }.
function Compat.CountMats(bagIDs)
    local counts = {}
    for _, bag in ipairs(bagIDs) do
        for slot = 1, ContainerSlots(bag) do
            local id, count = ContainerItem(bag, slot)
            if id and Compat.IsCraftingMat(id) then
                counts[id] = (counts[id] or 0) + (count or 1)
            end
        end
    end
    return counts
end

------------------------------------------------------------------------
-- Guild bank (kun TBC og senere)
------------------------------------------------------------------------

function Compat.HasGuildBank()
    return GetNumGuildBankTabs ~= nil and GetGuildBankItemLink ~= nil
end

function Compat.QueryGuildBankTabs()
    for tab = 1, GetNumGuildBankTabs() do
        local _, _, isViewable = GetGuildBankTabInfo(tab)
        if isViewable then QueryGuildBankTab(tab) end
    end
end

-- Returnerer { [tab] = { counts = {[itemID]=antal}, any = bool } } for synlige faner og den aktive fane.
-- Faner, der ikke er hentet fra serveren endnu, ser tomme ud; derfor "any".
function Compat.ReadGuildBank()
    local tabs = {}
    local slots = MAX_GUILDBANK_SLOTS_PER_TAB or 98
    for tab = 1, GetNumGuildBankTabs() do
        local _, _, isViewable = GetGuildBankTabInfo(tab)
        if isViewable then
            local counts, any = {}, false
            for slot = 1, slots do
                local link = GetGuildBankItemLink(tab, slot)
                local id = link and tonumber(link:match("item:(%d+)"))
                if id then
                    any = true
                    if Compat.IsCraftingMat(id) then
                        local _, count = GetGuildBankItemInfo(tab, slot)
                        counts[id] = (counts[id] or 0) + (count or 1)
                    end
                end
            end
            tabs[tab] = { counts = counts, any = any }
        end
    end
    return tabs, GetCurrentGuildBankTab and GetCurrentGuildBankTab()
end

------------------------------------------------------------------------
-- Tooltip
------------------------------------------------------------------------

-- fn(tooltip, itemID) kaldes, hver gang et item vises i GameTooltip eller ItemRefTooltip.
-- Ctrl-klik: vis itemet på ens egen char i dressing room (som i auktionshuset). Ikke-udstyr ignoreres.
function Compat.DressUp(link)
    if DressUpItemLink then return DressUpItemLink(link) end
end

-- Begge mekanismer installeres: i TBC Anniversary manglede "Crafted by" i spillet, selvom
-- TooltipDataProcessor findes (den bliver tilsyneladende ikke kaldt for alle tooltips).
-- gcItemID sikrer, at linjerne kun kommer én gang, hvis begge kaldes.
function Compat.HookItemTooltip(fn)
    local function Add(tooltip, id)
        if id and tooltip.gcItemID ~= id then
            tooltip.gcItemID = id
            fn(tooltip, id)
        end
    end

    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
        and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            if (tooltip == GameTooltip or tooltip == ItemRefTooltip) and data then
                Add(tooltip, data.id)
            end
        end)
    end

    for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
        tooltip:HookScript("OnTooltipCleared", function(self) self.gcItemID = nil end)
        if tooltip:HasScript("OnTooltipSetItem") then
            tooltip:HookScript("OnTooltipSetItem", function(self)
                local _, link = self:GetItem()
                Add(self, link and tonumber(link:match("item:(%d+)")))
            end)
        end
    end
end
