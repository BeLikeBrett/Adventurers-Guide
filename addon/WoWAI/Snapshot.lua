-- Structured context for MCP. APIs are optional on the Forever beta.
-- Restricted values must be filtered before any comparisons, arithmetic,
-- tostring, or JSON encoding. Even out of combat, target stats may be secret.
local function readable(value)
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return false end
    end
    if type(canaccessvalue) == "function" then
        local ok, accessible = pcall(canaccessvalue, value)
        if not ok or not accessible then return false end
    end
    return true
end

local function clean(value, depth)
    if not readable(value) then return nil end
    if type(value) ~= "table" then return value end
    depth = (depth or 0) + 1
    if depth > 8 then return nil end
    local out = {}
    local ok = pcall(function()
        for key, child in pairs(value) do
            if readable(key) then out[key] = clean(child, depth) end
        end
    end)
    if ok then return out end
end

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return clean(value) end
end

local function quote(s)
    return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c)
        return string.format('\\u%04x', string.byte(c))
    end) .. '"'
end
local function array(v) return setmetatable(v or {}, { __jsonArray = true }) end
local function json(v)
    if not readable(v) then return "null" end
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then return (v == v and math.abs(v) < math.huge) and tostring(v) or "null" end
    if t == "string" then return quote(v) end
    if t ~= "table" then return "null" end
    local parts = {}
    if #v > 0 or (getmetatable(v) or {}).__jsonArray then
        for i = 1, #v do parts[#parts + 1] = json(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, value in pairs(v) do parts[#parts + 1] = quote(k) .. ":" .. json(value) end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

local function unit(name)
    if not call(UnitExists, name) then return {} end
    local guid = call(UnitGUID, name)
    return { name = call(UnitName, name), guid = guid, npcID = guid and tonumber(guid:match("^[^-]+%-[^-]+%-[^-]+%-[^-]+%-[^-]+%-(%d+)%-")),
        level = call(UnitLevel, name), class = call(UnitClass, name), race = call(UnitRace, name),
        health = call(UnitHealth, name), maxHealth = call(UnitHealthMax, name), dead = call(UnitIsDead, name) }
end

function WoWAI.CollectSnapshot(section,requestToken)
    local mapID = call(C_Map and C_Map.GetBestMapForUnit, "player")
    local pos = mapID and call(C_Map.GetPlayerMapPosition, mapID, "player")
    local snapshot = { schema = 1, player = unit("player"), target = unit("target"),
        location = { zone = call(GetZoneText), subzone = call(GetSubZoneText), mapID = mapID,
            x = pos and call(function() return pos.x * 100 end), y = pos and call(function() return pos.y * 100 end) },
        quests = array(), inventory = array(), equipment = array(), professions = array(call(WoWAI.SkillLines)) }
    snapshot.game = call(function()
        local version, build, _, interface = GetBuildInfo()
        return { name = "World of Warcraft: Forever", version = version, build = build, interface = interface }
    end) or { name = "World of Warcraft: Forever" }
    snapshot.player.realm = call(GetRealmName)
    snapshot.player.money = call(GetMoney)
    snapshot.player.faction = call(UnitFactionGroup, "player")
    snapshot.player.xp = call(UnitXP, "player")
    snapshot.player.xpMax = call(UnitXPMax, "player")
    snapshot.player.restedXP = call(GetXPExhaustion)
    snapshot.player.guild = call(GetGuildInfo,"player")
    snapshot.player.classToken = call(function() return select(2,UnitClass("player")) end)
    snapshot.player.raceToken = call(function() return select(2,UnitRace("player")) end)
    snapshot.player.powerType = call(UnitPowerType,"player")
    snapshot.player.power = call(UnitPower,"player")
    snapshot.player.maxPower = call(UnitPowerMax,"player")
    snapshot.player.freeTalentPoints = call(GetUnspentTalentPoints)
    snapshot.player.inCombat = call(UnitAffectingCombat,"player")
    snapshot.player.resting = call(IsResting)
    snapshot.player.mounted = call(IsMounted)
    snapshot.player.swimming = call(IsSwimming)
    snapshot.player.speed = call(GetUnitSpeed,"player")
    snapshot.target.classification = call(UnitClassification,"target")
    snapshot.target.creatureType = call(UnitCreatureType,"target")
    snapshot.target.creatureFamily = call(UnitCreatureFamily,"target")
    snapshot.target.reaction = call(UnitReaction,"player","target")
    snapshot.target.attackable = call(UnitCanAttack,"player","target")
    snapshot.target.inCombat = call(UnitAffectingCombat,"target")
    -- Small live refreshes must not run every bag, talent and gear projection.
    if section=="player" or section=="location" or section=="target" or section=="combat" or section=="auctions" or section=="integrations" then
        if section=="combat" then snapshot.combat=call(WoWAI.CollectCombatRequest,requestToken)
        elseif section=="auctions" then snapshot.auctions=call(WoWAI.AuctionSnapshot,WoWAI.auctionQuery)
        elseif section=="integrations" then snapshot.integrations=call(WoWAI.IntegrationSnapshot) end
        return {schema=1,section=section,requestToken=requestToken,player=snapshot.player,game=snapshot.game,capturedAt=call(time),data=snapshot[section] or {}}
    end
    snapshot.stats = { armor=call(function() local a,b,c,d,e=UnitArmor("player");return {base=a,effective=b,armor=c,positive=d,negative=e} end),
        attackPower=call(function() local a,b,c=UnitAttackPower("player");return {base=a,positive=b,negative=c} end),
        rangedAttackPower=call(function() local a,b,c=UnitRangedAttackPower("player");return {base=a,positive=b,negative=c} end),
        meleeDamage=call(function() local a,b,c,d,e,f,g=UnitDamage("player");return {min=a,max=b,offMin=c,offMax=d,positive=e,negative=f,multiplier=g} end),
        rangedDamage=call(function() local a,b,c,d,e,f=UnitRangedDamage("player");return {speed=a,min=b,max=c,positive=d,negative=e,multiplier=f} end),
        crit=call(GetCritChance),rangedCrit=call(GetRangedCritChance),dodge=call(GetDodgeChance),parry=call(GetParryChance),block=call(GetBlockChance),attributes=array() }
    for i=1,5 do snapshot.stats.attributes[i]=call(function() local a,b,c,d=UnitStat("player",i);return {index=i,base=a,effective=b,positive=c,negative=d} end) or {} end
    snapshot.pet = unit("pet")
    snapshot.pet.happiness = call(GetPetHappiness)
    snapshot.pet.power = call(UnitPower,"pet")
    snapshot.pet.maxPower = call(UnitPowerMax,"pet")
    snapshot.talents = array()
    for tab=1,math.min(call(GetNumTalentTabs) or 0,6) do
        local row=call(function() local name,icon,spent=GetTalentTabInfo(tab);return {name=name,icon=icon,pointsSpent=spent,talents=array()} end) or {talents=array()}
        for index=1,math.min(call(GetNumTalents,tab) or 0,100) do
            local talent=call(function() local name,icon,tier,column,rank,maxRank=GetTalentInfo(tab,index);return {name=name,icon=icon,tier=tier,column=column,rank=rank,maxRank=maxRank} end)
            if talent then row.talents[#row.talents+1]=talent end
        end
        snapshot.talents[#snapshot.talents+1]=row
    end
    if C_QuestLog then
        snapshot.selectedQuestID = call(C_QuestLog.GetSelectedQuest)
        for i = 1, math.min(call(C_QuestLog.GetNumQuestLogEntries) or 0, 40) do
            local q = call(C_QuestLog.GetInfo, i)
            if q and not q.isHeader and q.questID then
                local objectives = call(C_QuestLog.GetQuestObjectives, q.questID)
                local clean = array()
                for _, o in ipairs(objectives or {}) do
                    clean[#clean + 1] = { text = o.text, type = o.type, finished = o.finished,
                        numFulfilled = o.numFulfilled, numRequired = o.numRequired }
                end
                snapshot.quests[#snapshot.quests + 1] = { id = q.questID, title = q.title, level = q.level,
                    complete = call(C_QuestLog.IsComplete, q.questID), objectives = clean }
            end
        end
    end
    if C_Container then
        for bag = 0, 4 do
            for slot = 1, math.min(call(C_Container.GetContainerNumSlots, bag) or 0, 100) do
                local item = call(C_Container.GetContainerItemInfo, bag, slot)
                if item then snapshot.inventory[#snapshot.inventory + 1] = { bag = bag, slot = slot,
                    id = item.itemID, count = item.stackCount, quality = item.quality, link = item.hyperlink } end
            end
        end
    end
    for slot = 1, 19 do
        local id = call(GetInventoryItemID, "player", slot)
        if id then snapshot.equipment[#snapshot.equipment + 1] = { slot = slot, id = id,
            link = call(GetInventoryItemLink, "player", slot),
            stats = call((C_Item and C_Item.GetItemStats) or GetItemStats, call(GetInventoryItemLink, "player", slot) or ("item:"..id)) } end
    end
    snapshot.integrations = call(WoWAI.IntegrationSnapshot,true)
    snapshot.player.faction = call(UnitFactionGroup, "player")
    snapshot.availableSections = {"player","location","target","quests","inventory","equipment","professions","integrations","stats","talents","pet","spells","reputations","currencies","actionBars","completedQuests","auras","bank","combat","auctions"}
    if section=="auctions" then snapshot.auctions=call(WoWAI.AuctionSnapshot,WoWAI.auctionQuery)
    elseif section=="combat" then snapshot.combat=call(WoWAI.CollectCombatRequest,requestToken)
    elseif section=="spells" then
        snapshot.spells=array()
        local modern=C_SpellBook and C_SpellBook.GetSpellBookItemInfo
        local bank=Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
        for index=1,1000 do
            local info=modern and call(modern,index,bank)
            if info then info.name=info.name or call(C_Spell and C_Spell.GetSpellName,info.spellID);snapshot.spells[#snapshot.spells+1]=info
            else
                local row=call(function() local name,rank=GetSpellBookItemName(index,BOOKTYPE_SPELL or "spell");local kind,id=GetSpellBookItemInfo(index,BOOKTYPE_SPELL or "spell");if name then return {name=name,rank=rank,kind=kind,spellID=id} end end)
                if not row then break end
                snapshot.spells[#snapshot.spells+1]=row
            end
        end
    elseif section=="reputations" then
        snapshot.reputations=array()
        local count=call(C_Reputation and C_Reputation.GetNumFactions) or call(GetNumFactions) or 0
        for index=1,math.min(count,300) do
            local row=call(C_Reputation and C_Reputation.GetFactionDataByIndex,index) or call(function() local name,description,standing,min,max,value,atWar,_,isHeader,collapsed,hasRep,watched,child,id=GetFactionInfo(index);return {name=name,description=description,standingID=standing,barMin=min,barMax=max,barValue=value,atWar=atWar,isHeader=isHeader,collapsed=collapsed,hasRep=hasRep,watched=watched,isChild=child,factionID=id} end)
            if row then snapshot.reputations[#snapshot.reputations+1]=row end
        end
    elseif section=="currencies" then
        snapshot.currencies=array()
        for index=1,math.min(call(C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize) or 0,100) do
            local info=call(C_CurrencyInfo.GetCurrencyListInfo,index);if info then snapshot.currencies[#snapshot.currencies+1]=info end
        end
    elseif section=="actionBars" then
        snapshot.actionBars=array()
        for slot=1,180 do
            local action=call(function() local kind,id,subType=GetActionInfo(slot);if kind then return {slot=slot,kind=kind,id=id,subType=subType,usable=call(IsUsableAction,slot),cooldown=call(function() local start,duration,enabled=GetActionCooldown(slot);return {start=start,duration=duration,enabled=enabled} end)} end end)
            if action then snapshot.actionBars[#snapshot.actionBars+1]=action end
        end
    elseif section=="auras" then
        snapshot.auras={}
        for _,unitName in ipairs({"player","target","pet"}) do
            snapshot.auras[unitName]=array()
            for _,filter in ipairs({"HELPFUL","HARMFUL"}) do
                for index=1,80 do
                    local info=call(C_UnitAuras and C_UnitAuras.GetAuraDataByIndex,unitName,index,filter)
                    if not info then break end
                    info.filter=filter;snapshot.auras[unitName][#snapshot.auras[unitName]+1]=info
                end
            end
        end
    elseif section=="bank" then
        snapshot.bank={items=array(),availability="Bank API cache; open the bank to populate missing entries."}
        local bags={-1};for bag=5,4+(NUM_BANKBAGS or 7) do bags[#bags+1]=bag end
        for _,bag in ipairs(bags) do
            for slot=1,math.min(call(C_Container and C_Container.GetContainerNumSlots,bag) or 0,100) do
                local info=call(C_Container and C_Container.GetContainerItemInfo,bag,slot)
                if info then snapshot.bank.items[#snapshot.bank.items+1]={bag=bag,slot=slot,id=info.itemID,count=info.stackCount,quality=info.quality,link=info.hyperlink} end
            end
        end
    elseif section=="completedQuests" then snapshot.completedQuests=array(call(C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs)) end
    snapshot.capturedAt = call(time)
    snapshot.requestToken=requestToken
    if section and section~="all" then return {schema=1,section=section,requestToken=requestToken,player=snapshot.player,game=snapshot.game,capturedAt=snapshot.capturedAt,data=snapshot[section] or {}} end
    return snapshot
end

function WoWAI.SnapshotJSON(section,requestToken)
    local ok, result = pcall(function() return json(WoWAI.CollectSnapshot(section,requestToken)) end)
    if ok then return result end
    return json({ schema = 1, error = "Some game context is unavailable: " .. tostring(result) })
end

if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(60, function() if WoWAI.QueueSnapshot then WoWAI.QueueSnapshot(true,"player") end end)
end

local lastRequest
function WoWAI.ReceiveSnapshotRequest(request)
    if not request or request.session~=WoWAIDB.session or request.token==lastRequest or WoWAIDB.settings.copilotEnabled==false then return end
    if request.section=="auctions" then
        WoWAI.auctionQuery={itemIds=request.itemIds,budgetCopper=request.budgetCopper}
        if request.searchTerms and WoWAI.StartAuctionSearch then WoWAI.StartAuctionSearch(request.searchTerms) end
    end
    if request.section=="combat" then
        WoWAI.combatQuery={seconds=request.seconds,includePets=request.includePets}
        if request.measureSeconds and WoWAI.BeginCombatMeasurement then
            if WoWAI.BeginCombatMeasurement(request.measureSeconds,request.token,request.includePets) then lastRequest=request.token end
            return
        end
    end
    if WoWAI.QueueSnapshot(false,request.section,request.token) then lastRequest=request.token
    elseif C_Timer then C_Timer.After(1,function() WoWAI.ReceiveSnapshotRequest(request) end) end
end
local refreshHead
local function refreshSound(index)
    if not PlaySoundFile then return false end
    local ok,plays,handle=pcall(PlaySoundFile,string.format("Interface\\AddOns\\WoWAI\\refresh\\%04d.wav",index),"Master")
    if ok and plays and handle and StopSound then pcall(StopSound,handle) end
    return ok and plays
end
if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(.5,function()
    if not WoWAIDB or WoWAIDB.settings.copilotEnabled==false then return end
    if refreshHead==nil then
        local lo,hi=0,2000
        while lo<hi do local mid=math.floor((lo+hi+1)/2);if refreshSound(mid) then lo=mid else hi=mid-1 end end
        refreshHead=lo
    end
    local nextIndex=refreshHead%2000+1
    if refreshSound(nextIndex) then
        refreshHead=nextIndex
        if WoWAI.LoadContextSlot then WoWAI.LoadContextSlot() end
    end
end) end
