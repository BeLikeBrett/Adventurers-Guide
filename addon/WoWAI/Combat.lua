-- Bounded in-memory combat journal. Never records other players as your damage.
local events, owners, swings, samples = {}, {}, {}, {}
local first, playerGUID, enabled, restricted, started = 1, nil, false, false, nil
local measurement, droppedUntil
local MAX_EVENTS, KEEP_SECONDS = 12000, 300
local function safe(value)
    if issecretvalue then local ok,v=pcall(issecretvalue,value);if not ok or v then return nil,false end end
    if canaccessvalue then local ok,v=pcall(canaccessvalue,value);if not ok or not v then return nil,false end end
    return value,true
end
local function call(fn,...)
    if type(fn)~="function" then return end
    local ok,a,b,c,d,e=pcall(fn,...)
    if ok then return safe(a),safe(b),safe(c),safe(d),safe(e) end
end
local function combatReader()
    if C_CombatLogInternal and type(C_CombatLogInternal.GetCurrentEventInfo)=="function" then
        return C_CombatLogInternal.GetCurrentEventInfo,"COMBAT_LOG_EVENT_INTERNAL_UNFILTERED"
    end
    local legacy=CombatLogGetCurrentEventInfo or (C_CombatLog and C_CombatLog.GetCurrentEventInfo)
    if type(legacy)=="function" then return legacy,"COMBAT_LOG_EVENT_UNFILTERED" end
end
local function refreshOwners()
    local guid=call(UnitGUID,"player")
    if guid and guid~=playerGUID then
        events,owners,swings,samples={}, {}, {}, {};first=1;measurement=nil;droppedUntil=nil;started=GetTime();restricted=false
        playerGUID=guid
    end
    if guid then owners[guid]={name=call(UnitName,"player"),kind="player",lastSeen=GetTime()} end
    local pet=call(UnitGUID,"pet")
    if pet then owners[pet]={name=call(UnitName,"pet"),kind="pet",lastSeen=GetTime()} end
end
-- The file writer is an unrestricted client feature, independent of secret events.
local loggingReason
local function logState()
    if type(LoggingCombat)~="function" then return nil,"Combat logging is unavailable in this client." end
    local ok,state=pcall(LoggingCombat)
    if not ok then return nil,"The client did not allow reading the combat logging setting." end
    local value,readable=safe(state)
    if not readable or type(value)~="boolean" then return nil,"The combat logging state is unreadable." end
    return value
end
function WoWAI.CombatLoggingStatus()
    local state,reason=logState()
    local settings=WoWAIDB and WoWAIDB.settings or {}
    return {available=state~=nil,recording=state,automatic=settings.autoCombatLog~=false,
        startedByGuide=settings.guideStartedCombatLog==true,reason=loggingReason or reason}
end
function WoWAI.SyncCombatLogging()
    local settings=WoWAIDB and WoWAIDB.settings
    if not settings then return end
    local state,reason=logState();loggingReason=reason
    if state==nil then return end
    local wanted=enabled and settings.autoCombatLog~=false
    if not state then settings.guideStartedCombatLog=nil end
    if wanted and not state then
        -- Advanced logs include the owner GUID used for guardians and minions.
        local setCVar=(C_CVar and C_CVar.SetCVar) or SetCVar
        if type(setCVar)=="function" then pcall(setCVar,"advancedCombatLogging","1") end
        local ok=pcall(LoggingCombat,true)
        local active=logState()
        if ok and active==true then settings.guideStartedCombatLog=true;loggingReason=nil
        else loggingReason="The client did not start combat logging. Use /combatlog to enable it." end
    elseif not wanted and state and settings.guideStartedCombatLog then
        pcall(LoggingCombat,false)
        if logState()==false then settings.guideStartedCombatLog=nil end
    end
end
function WoWAI.SetAutoCombatLogging(value)
    if not WoWAIDB or not WoWAIDB.settings then return end
    WoWAIDB.settings.autoCombatLog=value~=false
    WoWAI.SyncCombatLogging()
    return WoWAI.CombatLoggingStatus()
end
function WoWAI.FlushCombatRecording()
    -- A synchronous stop/start closes the disk buffer. Do not interrupt combat,
    -- touch a logger that is off, or clear any recorded events.
    if not enabled or call(UnitAffectingCombat,"player") or logState()~=true then return false end
    local ok=pcall(LoggingCombat,false)
    if not ok then return false end
    local restarted=pcall(LoggingCombat,true)
    local active=logState()
    if not restarted or active~=true then loggingReason="Combat recording could not restart.";return false end
    return true
end
function WoWAI.SetCombatEnabled(value)
    enabled=value~=false
    events,owners,swings,samples={}, {}, {}, {};first=1;measurement=nil;droppedUntil=nil;playerGUID=nil;restricted=false
    started=enabled and GetTime() or nil
    if enabled then refreshOwners() end
    WoWAI.SyncCombatLogging()
end
local function prune(now)
    for guid,owner in pairs(owners) do if owner.kind~="player" and now-(owner.lastSeen or now)>KEEP_SECONDS then owners[guid]=nil;swings[guid]=nil end end
    while first<=#events and (events[first].at<now-KEEP_SECONDS or #events-first+1>MAX_EVENTS) do droppedUntil=events[first].at;first=first+1 end
    if first>1000 then local fresh={};for i=first,#events do fresh[#fresh+1]=events[i] end;events=fresh;first=1 end
end
local function owned(guid,name,flags)
    if not guid then return end
    if owners[guid] then owners[guid].lastSeen=GetTime();return owners[guid] end
    -- MINE affiliation + PLAYER control identifies guardians summoned before
    -- collection began; party/raid affiliation must never count as ours.
    if type(flags)=="number" and flags%2==1 and math.floor(flags/256)%2==1 and not guid:match("^Player") then
        owners[guid]={name=name,kind="guardian",lastSeen=GetTime()};return owners[guid]
    end
end
function WoWAI.RecordCombatEvent(...)
    if not enabled then return end
    local raw={...}
    for i=1,select("#",...) do
        local value,accessible=safe(raw[i])
        if not accessible then restricted=true;return end
        raw[i]=value
    end
    refreshOwners()
    local kind,source,sourceName,sourceFlags,dest,destName,destFlags=raw[2],raw[4],raw[5],raw[6],raw[8],raw[9],raw[10]
    if type(kind)~="string" then return end
    local actor=owned(source,sourceName,sourceFlags)
    if (kind=="SPELL_SUMMON" or kind=="SPELL_CREATE") and actor and dest then
        owners[dest]={name=destName,kind=dest==call(UnitGUID,"pet") and "pet" or "guardian",lastSeen=GetTime()};return
    end
    local recipient=owned(dest,destName,destFlags)
    if not actor and not recipient then return end
    local at=GetTime()
    local spellID,spellName,base=0,"Melee",12
    if kind:match("^SPELL_") or kind:match("^RANGE_") or kind:match("^DAMAGE_SHIELD") or kind=="DAMAGE_SPLIT" then spellID,spellName,base=raw[12],raw[13],15
    elseif kind=="ENVIRONMENTAL_DAMAGE" then spellName,base=raw[12],13 end
    if actor and (kind=="SWING_DAMAGE" or kind=="SWING_MISSED" or kind=="RANGE_DAMAGE" or kind=="RANGE_MISSED") then
        local hand=kind:match("^RANGE") and "ranged" or ((kind=="SWING_DAMAGE" and raw[base+9] or kind=="SWING_MISSED" and raw[base+1]) and "offhand" or "mainhand")
        swings[source]=swings[source] or {};swings[source][hand]=at
    end
    local event={at=at,source=source,sourceName=sourceName,sourceKind=actor and actor.kind,dest=dest,destName=destName,destKind=recipient and recipient.kind,spellID=spellID,name=spellName,event=kind}
    if kind:match("_DAMAGE$") or kind=="DAMAGE_SHIELD" or kind=="DAMAGE_SPLIT" then
        local amount=raw[base]
        if type(amount)~="number" then return end
        event.type="damage";event.amount=math.max(0,amount);event.overkill=math.max(0,tonumber(raw[base+1]) or 0)
        event.effective=math.max(0,event.amount-event.overkill);event.critical=raw[base+6]==true
        event.resisted=tonumber(raw[base+3]) or 0;event.blocked=tonumber(raw[base+4]) or 0;event.absorbed=tonumber(raw[base+5]) or 0
    elseif kind=="SPELL_HEAL" or kind=="SPELL_PERIODIC_HEAL" then
        if type(raw[base])~="number" then return end
        event.type="healing";event.amount=math.max(0,raw[base]);event.overheal=math.max(0,tonumber(raw[base+1]) or 0)
        event.effective=math.max(0,event.amount-event.overheal);event.critical=raw[base+3]==true
    elseif kind:match("_MISSED$") then event.type="miss";event.missType=raw[base]
    elseif kind=="SPELL_CAST_SUCCESS" then event.type="cast"
    else return end
    events[#events+1]=event;prune(at)
end
local function threat(unit,target)
    local tank,status,scaled,raw,value=call(UnitDetailedThreatSituation,unit,target)
    return {unit=unit,guid=call(UnitGUID,unit),targetGUID=call(UnitGUID,target),isTanking=tank,status=status or call(UnitThreatSituation,unit,target),scaledPercent=scaled,rawPercent=raw,threat=value,available=value~=nil or status~=nil}
end
local function sampleThreat()
    if not enabled then return end
    refreshOwners()
    if not call(UnitAffectingCombat,"player") then return end
    local now=GetTime()
    local row={at=now,player=threat("player","target"),pet=threat("pet","target")}
    samples[#samples+1]=row
    while #samples>300 or (#samples>0 and samples[1].at<now-KEEP_SECONDS) do table.remove(samples,1) end
end
local function totals()
    return {damage=0,effectiveDamage=0,hits=0,crits=0,critDamage=0,normalDamage=0,misses=0,healing=0,effectiveHealing=0,overheal=0,absorbed=0,resisted=0,blocked=0,casts=0}
end
local function add(t,e)
    if e.type=="damage" then
        t.damage=t.damage+e.amount;t.effectiveDamage=t.effectiveDamage+e.effective;t.hits=t.hits+1
        t.absorbed=t.absorbed+e.absorbed;t.resisted=t.resisted+e.resisted;t.blocked=t.blocked+e.blocked
        if e.critical then t.crits=t.crits+1;t.critDamage=t.critDamage+e.amount else t.normalDamage=t.normalDamage+e.amount end
    elseif e.type=="healing" then t.healing=t.healing+e.amount;t.effectiveHealing=t.effectiveHealing+e.effective;t.overheal=t.overheal+e.overheal
    elseif e.type=="miss" then t.misses=t.misses+1
    elseif e.type=="cast" then t.casts=t.casts+1 end
end
local function sorted(rows)
    local list={};for _,row in pairs(rows) do list[#list+1]=row end
    table.sort(list,function(a,b) if a.damage~=b.damage then return a.damage>b.damage end;return (a.name or "")<(b.name or "") end)
    while #list>40 do table.remove(list) end
    return list
end
-- The Forever meter supplies readable fight aggregates after combat even when
-- addon combat-log events are unavailable. Never treat aggregates as raw hits.
local function publicTable(fn,...)
    if type(fn)~="function" then return nil end
    local ok,value=pcall(fn,...)
    if not ok then return nil end
    local function copy(v,depth)
        local clean,accessible=safe(v)
        if not accessible then return nil end
        if type(clean)~="table" then return clean end
        if depth>6 then return nil end
        local out={};local count=0
        for k,child in pairs(clean) do
            local key,readable=safe(k)
            if readable then out[key]=copy(child,depth+1) end
            count=count+1;if count>500 then break end
        end
        return out
    end
    local copied,result=pcall(copy,value,0)
    if copied and type(result)=="table" then return result end
end
local function spellName(id)
    if id==0 then return "Melee" end
    local info=publicTable(C_Spell and C_Spell.GetSpellInfo,id)
    return info and info.name or call(GetSpellInfo,id) or ("Spell "..tostring(id))
end
function WoWAI.NativeCombatSnapshot(seconds)
    if not C_DamageMeter or type(C_DamageMeter.GetCombatSessionFromType)~="function" then return nil end
    if call(UnitAffectingCombat,"player") then
        return {available=false,source="Blizzard damage meter",reason="Fight details are restricted during combat. Ask after the fight ends.",requestedWindowSeconds=seconds}
    end
    local current=Enum and Enum.DamageMeterSessionType and Enum.DamageMeterSessionType.Current or 1
    local damageType=Enum and Enum.DamageMeterType and Enum.DamageMeterType.DamageDone or 0
    local session=publicTable(C_DamageMeter.GetCombatSessionFromType,current,damageType)
    local function playerSource(data)
        for _,row in ipairs(data and data.combatSources or {}) do
            if row.isLocalPlayer or (playerGUID and row.sourceGUID==playerGUID) then return row end
        end
    end
    refreshOwners()
    local row=playerSource(session)
    if not row or type(row.totalAmount)~="number" then
        return {available=false,source="Blizzard damage meter",reason="No readable recorded player fight is available. Enable the built-in damage meter and finish a fight.",requestedWindowSeconds=seconds}
    end
    local detail=publicTable(C_DamageMeter.GetCombatSessionSourceFromType,current,damageType,row.sourceGUID or playerGUID,row.sourceCreatureID)
    local duration=session.durationSeconds or call(C_DamageMeter.GetSessionDurationSeconds,current)
    local result={available=true,source="Blizzard damage meter",windowMode="fightAggregate",requestedWindowSeconds=seconds,
        windowSeconds=duration,coverageSeconds=duration,includePets=true,petAttribution="Units attributed to the player by Blizzard; separate pet totals may be unavailable.",
        outgoing={damage=row.totalAmount,dps=row.amountPerSecond},incoming={},abilities={},incomingAbilities={},sources={{guid=row.sourceGUID,name=row.name,kind="playerWithControlledUnits",damage=row.totalAmount}},
        capabilities={abilityTotals=true,individualHits=false,crits=false,exactTimeWindow=false,weaponIdentity=false},
        limitations="Latest current fight totals, not an exact rolling time window. Individual hit timestamps, critical counts, weapon identity and cast order are not supplied by this API. Pet attribution follows the game meter."}
    local function abilities(data,field)
        for _,spell in ipairs(data and data.combatSpells or {}) do
            if type(spell.totalAmount)=="number" and type(spell.spellID)=="number" then
                field[#field+1]={spellID=spell.spellID,name=spellName(spell.spellID),damage=spell.totalAmount,
                    overkill=spell.overkillAmount,creatureName=spell.creatureName,unit=spell.combatSpellDetails and spell.combatSpellDetails.unitName}
            end
        end
        table.sort(field,function(a,b) return a.damage>b.damage end)
        while #field>40 do table.remove(field) end
    end
    abilities(detail,result.abilities)
    for _,ability in ipairs(result.abilities) do ability.damageShare=row.totalAmount>0 and ability.damage/row.totalAmount*100 or 0 end
    local incomingType=Enum and Enum.DamageMeterType and Enum.DamageMeterType.DamageTaken or 7
    local taken=playerSource(publicTable(C_DamageMeter.GetCombatSessionFromType,current,incomingType))
    if taken then
        result.incoming.damage=taken.totalAmount
        abilities(publicTable(C_DamageMeter.GetCombatSessionSourceFromType,current,incomingType,taken.sourceGUID or playerGUID,taken.sourceCreatureID),result.incomingAbilities)
    end
    return result
end

function WoWAI.CombatSnapshot(seconds,from,to,includePets)
    if not enabled then return {available=false,reason="Guide is closed."} end
    refreshOwners();local now=GetTime();prune(now)
    local accessor,eventName=combatReader()
    if type(accessor)~="function" or restricted then
        local native=WoWAI.NativeCombatSnapshot(seconds)
        if native then return native end
    end
    seconds=math.max(1,math.min(300,tonumber(seconds) or 30));to=to or now;from=from or to-seconds
    local result={available=type(accessor)=="function" and not restricted,restricted=restricted,source="Readable "..tostring(eventName or "combat").." events",windowSeconds=to-from,
        coverageSeconds=math.max(0,to-math.max(from,started or to,droppedUntil or from)),
        includePets=includePets~=false,outgoing=totals(),incoming=totals(),abilities={},sources={},incomingAbilities={},critEvents={},castSequence={},threat={player=threat("player","target"),pet=threat("pet","target")},swings={},
        limitations="Observed events only. Threat is target-specific; changes include threat modifiers/resets. Swing predictions are estimates and may reset. Ability order does not prove causation."}
    if not result.available then result.reason=restricted and "Combat event fields are restricted by the client." or "This client does not expose readable combat events." end
    local ability,sourceRows,incoming={},{},{}
    for i=first,#events do
        local e=events[i]
        if e.at>=from and e.at<=to then
            local mine=e.sourceKind and (includePets~=false or e.sourceKind=="player")
            local ours=e.destKind and (includePets~=false or e.destKind=="player")
            if mine then
                add(result.outgoing,e)
                local key=tostring(e.spellID)..":"..tostring(e.name)
                ability[key]=ability[key] or totals();ability[key].spellID=e.spellID;ability[key].name=e.name;add(ability[key],e)
                sourceRows[e.source]=sourceRows[e.source] or totals();local row=sourceRows[e.source];row.guid=e.source;row.name=e.sourceName;row.kind=e.sourceKind;add(row,e)
                if e.type=="damage" and e.critical and #result.critEvents<40 then result.critEvents[#result.critEvents+1]={secondsIntoWindow=e.at-from,spellID=e.spellID,name=e.name,source=e.sourceName,target=e.destName,damage=e.amount} end
                if e.type=="cast" and #result.castSequence<40 then result.castSequence[#result.castSequence+1]={secondsIntoWindow=e.at-from,spellID=e.spellID,name=e.name,source=e.sourceName} end
            end
            if ours then
                add(result.incoming,e)
                local key=tostring(e.spellID)..":"..tostring(e.name)
                incoming[key]=incoming[key] or totals();incoming[key].spellID=e.spellID;incoming[key].name=e.name;add(incoming[key],e)
            end
        end
    end
    result.critEventsTruncated=result.outgoing.crits>#result.critEvents
    result.castSequenceTruncated=result.outgoing.casts>#result.castSequence
    result.abilities=sorted(ability);result.sources=sorted(sourceRows);result.incomingAbilities=sorted(incoming)
    for _,a in ipairs(result.abilities) do a.damageShare=result.outgoing.damage>0 and a.damage/result.outgoing.damage*100 or 0 end
    result.outgoing.dps=result.outgoing.damage/math.max(1,to-from)
    for _,unit in ipairs({"player","pet"}) do
        local guid=call(UnitGUID,unit);local main,off=call(UnitAttackSpeed,unit);local ranged=call(UnitRangedDamage,unit)
        local row={unit=unit,guid=guid,mainhandSpeed=main,offhandSpeed=off,rangedSpeed=ranged,last=guid and swings[guid] or {}}
        row.estimatedNext={}
        for _,hand in ipairs({"mainhand","offhand","ranged"}) do
            local last=row.last and row.last[hand];local speed=hand=="mainhand" and main or hand=="offhand" and off or ranged
            if last and type(speed)=="number" and speed>0 and last+speed>=now then row.estimatedNext[hand]=last+speed-now end
        end
        result.swings[#result.swings+1]=row
        local current=result.threat[unit];local earliest,latest
        for _,s in ipairs(samples) do local t=s[unit];if s.at>=from and s.at<=to and t.guid==current.guid and t.targetGUID==current.targetGUID and type(t.threat)=="number" then earliest=earliest or s;latest=s end end
        if earliest and latest and latest.at>earliest.at then current.sampledDelta=latest[unit].threat-earliest[unit].threat;current.sampledSeconds=latest.at-earliest.at;current.netThreatPerSecond=current.sampledDelta/current.sampledSeconds end
    end
    return result
end
function WoWAI.BeginCombatMeasurement(seconds,token,includePets)
    if not enabled then return end
    seconds=math.max(1,math.min(30,tonumber(seconds) or 10))
    local native=not combatReader() and WoWAI.NativeCombatSnapshot(seconds)
    if native then
        measurement={token=token,result=native}
        measurement.result.measurement={token=token,durationSeconds=seconds,complete=false,supported=false,
            reason="The built-in meter supplies whole fights. Exact timed measurements require the client's combat-log file."}
        return WoWAI.QueueSnapshot(false,"combat",token)
    end
    local item={token=token,from=GetTime(),to=GetTime()+seconds,includePets=includePets}
    measurement=item
    C_Timer.After(seconds,function()
        if measurement~=item or not enabled then return end
        item.result=WoWAI.CombatSnapshot(seconds,item.from,item.to,includePets)
        item.result.measurement={token=token,durationSeconds=seconds,complete=true}
        local function send()
            if measurement~=item or not enabled then return end
            if not WoWAI.QueueSnapshot(false,"combat",token) then C_Timer.After(.5,send) end
        end
        send()
    end)
    return true
end
function WoWAI.CollectCombatRequest(request)
    if measurement and measurement.token==request and measurement.result then return measurement.result end
    local options=WoWAI.combatQuery or {}
    return WoWAI.CombatSnapshot(options.seconds,nil,nil,options.includePets)
end
local frame=CreateFrame("Frame")
local registeredEvent
local function registerCombatReader()
    local getter,event=combatReader()
    if event and event~=registeredEvent then
        if registeredEvent then frame:UnregisterEvent(registeredEvent) end
        local ok=pcall(frame.RegisterEvent,frame,event)
        if ok then registeredEvent=event end
    end
end
registerCombatReader()
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent",function(_,event)
    if event=="PLAYER_LOGIN" then registerCombatReader();WoWAI.SetCombatEnabled(not WoWAIDB or WoWAIDB.settings.copilotEnabled~=false);return end
    if event=="PLAYER_ENTERING_WORLD" then WoWAI.SyncCombatLogging();return end
    if not enabled or event~=registeredEvent then return end
    local getter=combatReader()
    if type(getter)=="function" then local ok=pcall(function() WoWAI.RecordCombatEvent(getter()) end);if not ok then restricted=true end end
end)
if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(1,sampleThreat) end
