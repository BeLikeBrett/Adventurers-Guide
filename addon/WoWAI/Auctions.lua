-- Realm-scoped auction observations plus Auctionator's stable public API.
-- Prices are copper per item. Quotes never imply a listing is still available.
local open = false
local searchResult
local function safe(value,depth)
    if issecretvalue then local ok,v=pcall(issecretvalue,value);if not ok or v then return end end
    if canaccessvalue then local ok,v=pcall(canaccessvalue,value);if not ok or not v then return end end
    if type(value)~="table" then return value end
    if (depth or 0)>5 then return end
    local out={};local ok=pcall(function() for k,v in pairs(value) do if type(k)=="number" or type(k)=="string" then out[k]=safe(v,(depth or 0)+1) end end end)
    if ok then return out end
end
local function call(fn,...)
    if type(fn)~="function" then return end
    local ok,a,b,c,d,e,f,g,h,i,j,k=pcall(fn,...)
    if ok then return safe(a),safe(b),safe(c),safe(d),safe(e),safe(f),safe(g),safe(h),safe(i),safe(j),safe(k) end
end
local function market()
    local ruleset="Unknown"
    if call(RegionalUniqueNamesEnabled) and C_GameRules and type(C_GameRules.IsGameRuleActive)=="function" and Enum and Enum.GameRule then
        ruleset="PvE"
        for _,rule in ipairs({{"PvPRuleset","PvP"},{"RPRuleset","RP"},{"HardcoreRuleset","HC"}}) do
            if Enum and Enum.GameRule and call(C_GameRules and C_GameRules.IsGameRuleActive,Enum.GameRule[rule[1]]) then ruleset=rule[2];break end
        end
    end
    local realm=call(GetRealmName) or "Unknown"
    local faction=call(UnitFactionGroup,"player") or "Unknown"
    local region=call(GetCurrentRegion) or "Unknown"
    return {realm=realm,region=region,ruleset=ruleset,faction=faction,key=tostring(region)..":"..ruleset..":"..realm..":"..faction}
end
local function cache()
    if not WoWAIDB then return {} end
    local key=market().key
    local db=WoWAIDB.auctionCache
    -- A bounded local cache. Never reuse observations across realm/ruleset changes.
    if not db or db.market~=key then db={market=key,items={}};WoWAIDB.auctionCache=db end
    return db.items
end
local function remember(id,rows,at,complete)
    if not id then return end
    table.sort(rows,function(a,b) return a.unitPrice<b.unitPrice end)
    while #rows>12 do table.remove(rows) end
    cache()[tostring(id)]={itemID=id,observedAt=at,listings=rows,complete=complete}
    local count=0;for _ in pairs(cache()) do count=count+1 end
    if count>1000 then
        local oldest,when
        for k,v in pairs(cache()) do if not when or v.observedAt<when then oldest,when=k,v.observedAt end end
        cache()[oldest]=nil
    end
end
local function collectItem(key,at)
    key=safe(key)
    if not key or type(key.itemID)~="number" then return end
    local rows={}
    for i=1,math.min(call(C_AuctionHouse and C_AuctionHouse.GetNumItemSearchResults,key) or 0,200) do
        local row=call(C_AuctionHouse.GetItemSearchResultInfo,key,i)
        if row and type(row.buyoutAmount)=="number" and row.buyoutAmount>0 and not row.containsOwnerItem and not row.containsAccountItem then
            local quantity=type(row.quantity)=="number" and math.max(1,row.quantity) or 1
            rows[#rows+1]={auctionID=row.auctionID,itemID=key.itemID,itemLink=row.itemLink,itemKey=row.itemKey,quantity=quantity,totalPrice=row.buyoutAmount,unitPrice=row.buyoutAmount/quantity,bidPrice=row.bidAmount,timeLeftSeconds=row.timeLeftSeconds,source="client item search"}
        end
    end
    remember(key.itemID,rows,at,call(C_AuctionHouse and C_AuctionHouse.HasFullItemSearchResults,key))
end
local function collectCommodity(id,at)
    if type(id)~="number" then return end
    local rows={}
    for i=1,math.min(call(C_AuctionHouse and C_AuctionHouse.GetNumCommoditySearchResults,id) or 0,200) do
        local row=call(C_AuctionHouse.GetCommoditySearchResultInfo,id,i)
        if row and type(row.unitPrice)=="number" and row.unitPrice>0 and not row.containsOwnerItem and not row.containsAccountItem then
            rows[#rows+1]={auctionID=row.auctionID,itemID=id,quantity=row.quantity,unitPrice=row.unitPrice,timeLeftSeconds=row.timeLeftSeconds,source="client commodity search"}
        end
    end
    remember(id,rows,at,call(C_AuctionHouse and C_AuctionHouse.HasFullCommoditySearchResults,id))
end
function WoWAI.StartAuctionSearch(terms)
    local api=Auctionator and Auctionator.API and Auctionator.API.v1
    local visible=(AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown())
    if not visible then searchResult={started=false,reason="Visit an auctioneer and open the auction house for a live search."};return end
    if not api or type(api.MultiSearch)~="function" then searchResult={started=false,reason="Auctionator is not loaded; restart WoW after installing it."};return end
    local clean={}
    for _,term in ipairs(terms or {}) do
        if type(term)=="string" and #term>0 and #term<=100 and not term:find('[;^\n\r|]') and not term:match('^%s*".*"%s*$') then clean[#clean+1]=term end
        if #clean>=8 then break end
    end
    if #clean==0 then searchResult={started=false,reason="Search needs a plain item name."};return end
    local ok,err=pcall(api.MultiSearch,"Adventurer's Guide",clean)
    searchResult={started=ok,terms=clean,at=time(),reason=not ok and "Auctionator could not start this search." or nil}
end
function WoWAI.AuctionSnapshot(query)
    query=query or {}
    local api=Auctionator and Auctionator.API and Auctionator.API.v1
    local output={market=market(),auctionHouseOpen=open or not not ((AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown())),auctionatorInstalled=not not api,search=searchResult,prices={},
        units="copper per item",limitations="Scan prices are asking prices, not confirmed sales. Age from Auctionator is in days (0 does not mean live). Native search listings may be partial and expire. Item-ID quotes may combine enchant/suffix variants; compare the exact item link. No global live realm feed."}
    local ids,seen={},{}
    local function add(id)
        if type(id)=="number" and id>0 and not seen[id] and #ids<20 then seen[id]=true;ids[#ids+1]=id end
    end
    for _,id in ipairs(query.itemIds or {}) do add(id) end
    if #ids==0 then
        for bag=0,4 do for slot=1,math.min(call(C_Container and C_Container.GetContainerNumSlots,bag) or 0,100) do local row=call(C_Container.GetContainerItemInfo,bag,slot);if row then add(row.itemID) end end end
    end
    for _,id in ipairs(ids) do
        local name,link,quality,_,required,_,_,_,equip,_,sellPrice=call((C_Item and C_Item.GetItemInfo) or GetItemInfo,id)
        local price=api and call(api.GetAuctionPriceByItemID,"Adventurer's Guide",id)
        local age=api and call(api.GetAuctionAgeByItemID,"Adventurer's Guide",id)
        price=type(price)=="number" and price>0 and price or nil
        age=type(age)=="number" and age>=0 and age or nil
        local stored=cache()[tostring(id)]
        local row={itemID=id,name=name,link=link,quality=quality,requiredLevel=required,equipLocation=equip,vendorPrice=sellPrice,
            scanPrice=price,scanAgeDays=age,scanSource=price and "Auctionator current market database" or nil,available=price~=nil or (stored~=nil and #stored.listings>0)}
        if stored then
            row.observedAt=stored.observedAt;row.observationAgeSeconds=math.max(0,time()-stored.observedAt);row.listings=stored.listings;row.listingCount=#stored.listings;row.searchComplete=stored.complete
            row.lowestObservedUnitPrice=stored.listings[1] and stored.listings[1].unitPrice
            row.live=output.auctionHouseOpen and row.observationAgeSeconds<=15 and #stored.listings>0
        end
        if query.budgetCopper and row.lowestObservedUnitPrice then row.withinBudget=row.lowestObservedUnitPrice<=query.budgetCopper end
        output.prices[#output.prices+1]=row
    end
    table.sort(output.prices,function(a,b)
        local pa,pb=a.lowestObservedUnitPrice or a.scanPrice or math.huge,b.lowestObservedUnitPrice or b.scanPrice or math.huge
        return pa<pb
    end)
    return output
end
local frame=CreateFrame("Frame")
for _,event in ipairs({"AUCTION_HOUSE_SHOW","AUCTION_HOUSE_CLOSED","ITEM_SEARCH_RESULTS_UPDATED","COMMODITY_SEARCH_RESULTS_UPDATED"}) do pcall(frame.RegisterEvent,frame,event) end
frame:SetScript("OnEvent",function(_,event,arg)
    if event=="AUCTION_HOUSE_SHOW" then open=true
    elseif event=="AUCTION_HOUSE_CLOSED" then open=false
    elseif event=="ITEM_SEARCH_RESULTS_UPDATED" then collectItem(arg,time())
    elseif event=="COMMODITY_SEARCH_RESULTS_UPDATED" then collectCommodity(safe(arg),time()) end
end)
