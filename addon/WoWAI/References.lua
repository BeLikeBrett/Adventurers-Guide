local function readable(v)
    if issecretvalue and issecretvalue(v) then return end
    if canaccessvalue and not canaccessvalue(v) then return end
    return v
end
local function call(fn,...)
    if type(fn) ~= "function" then return end
    local ok,a,b,c,d,e,f,g,h,i,j=pcall(fn,...)
    if ok then return readable(a),readable(b),readable(c),readable(d),readable(e),readable(f),readable(g),readable(h),readable(i),readable(j) end
end
function WoWAI.PlainText(text)
    return tostring(text or ""):gsub("|cn[^:]+:", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        :gsub("|H[^|]+|h(.-)|h", "%1"):gsub("|T.-|t", ""):gsub("|A.-|a", "")
end
function WoWAI.ReferenceList(text)
    local refs, seen = {}, {}
    for payload,label in tostring(text or ""):gmatch("|H([^|]+)|h%[([^%]]*)%]|h") do
        local kind,id=payload:match("^(%a+):(%d+)")
        if id and (kind=="item" or kind=="quest" or kind=="spell") and not seen[payload] then
            seen[payload]=true; refs[#refs+1]={kind=kind,id=tonumber(id),name=WoWAI.PlainText(label),payload=payload}
        end
    end
    return refs
end
local inventory={INVTYPE_HEAD=1,INVTYPE_NECK=2,INVTYPE_SHOULDER=3,INVTYPE_BODY=4,INVTYPE_CHEST=5,INVTYPE_ROBE=5,INVTYPE_WAIST=6,INVTYPE_LEGS=7,INVTYPE_FEET=8,INVTYPE_WRIST=9,INVTYPE_HAND=10,INVTYPE_FINGER=11,INVTYPE_TRINKET=13,INVTYPE_CLOAK=15,INVTYPE_WEAPON=16,INVTYPE_2HWEAPON=16,INVTYPE_WEAPONMAINHAND=16,INVTYPE_WEAPONOFFHAND=17,INVTYPE_SHIELD=17,INVTYPE_HOLDABLE=17,INVTYPE_RANGED=18,INVTYPE_RANGEDRIGHT=18}
local stats={ {"ITEM_MOD_AGILITY_SHORT","Agility"},{"ITEM_MOD_STRENGTH_SHORT","Strength"},{"ITEM_MOD_INTELLECT_SHORT","Intellect"},{"ITEM_MOD_STAMINA_SHORT","Stamina"},{"ITEM_MOD_SPIRIT_SHORT","Spirit"},{"RESISTANCE0_NAME","Armor"},{"ITEM_MOD_ATTACK_POWER_SHORT","Attack power"},{"ITEM_MOD_RANGED_ATTACK_POWER_SHORT","Ranged power"},{"ITEM_MOD_CRIT_RATING_SHORT","Critical strike"},{"ITEM_MOD_HIT_RATING_SHORT","Hit"},{"ITEM_MOD_SPELL_POWER_SHORT","Spell power"} }
local function describe(ref)
    local name,link,quality,_,required,_,_,_,equip,icon=call((C_Item and C_Item.GetItemInfo) or GetItemInfo,ref.payload or ref.id)
    if ref.kind=="spell" then name=call(C_Spell and C_Spell.GetSpellName,ref.id);icon=call(C_Spell and C_Spell.GetSpellTexture,ref.id)
    elseif ref.kind=="quest" then name=call(C_QuestLog and C_QuestLog.GetTitleForQuestID,ref.id);icon="Interface\\Icons\\INV_Misc_Note_01"
    elseif ref.kind=="dungeon" then name=ref.name;icon="Interface\\Icons\\INV_Misc_Book_09" end
    local summary=ref.note or ref.source or ""
    if ref.kind=="item" then
        if not name and C_Item and C_Item.RequestLoadItemDataByID then call(C_Item.RequestLoadItemDataByID,ref.id) end
        local current=inventory[equip] and call(GetInventoryItemLink,"player",inventory[equip])
        local values=call((C_Item and C_Item.GetItemStats) or GetItemStats,link or ("item:"..ref.id)) or {}
        local before=current and call((C_Item and C_Item.GetItemStats) or GetItemStats,current) or {}
        local lines={}
        for _,stat in ipairs(stats) do
            local amount,old=readable(values[stat[1]]),readable(before[stat[1]]) or 0
            if type(amount)=="number" then
                local delta=amount-(type(old)=="number" and old or 0)
                lines[#lines+1]=stat[2].." "..amount..(current and (delta>=0 and " (+"..delta..")" or " ("..delta..")") or "")
            end
        end
        local label=required and required>0 and ("Requires level "..required) or "Item"
        summary=label..(#lines>0 and " · "..table.concat(lines," · ") or " · hover for details")..(summary~="" and "\n"..summary or "")
    elseif ref.kind=="quest" then
        local objectives=call(C_QuestLog and C_QuestLog.GetQuestObjectives,ref.id) or {}
        local lines={};for _,o in ipairs(objectives) do if type(o.text)=="string" then lines[#lines+1]=o.text end end
        summary=#lines>0 and table.concat(lines," · ") or summary
    end
    return name or ref.name or (ref.kind.." "..(ref.id or "")),icon or "Interface\\Icons\\INV_Misc_Book_09",WoWAI.PlainText(summary),link,quality
end
function WoWAI.RenderReferenceCards(parent,refs,width,anchor,remove)
    if not refs or #refs==0 then if parent.referenceDeck then parent.referenceDeck:Hide() end;return 0 end
    local deck=parent.referenceDeck
    if not deck then
        deck=CreateFrame("Frame",nil,parent,"BackdropTemplate");parent.referenceDeck=deck
        deck:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",tile=true,tileSize=32,edgeSize=12,insets={left=3,right=3,top=3,bottom=3}})
        deck:SetBackdropBorderColor(.58,.43,.19,1)
        deck.icon=deck:CreateTexture(nil,"ARTWORK");deck.icon:SetSize(32,32);deck.icon:SetPoint("TOPLEFT",10,-10)
        deck.title=deck:CreateFontString(nil,"OVERLAY","GameFontNormal");deck.title:SetPoint("TOPLEFT",deck.icon,"TOPRIGHT",8,0);deck.title:SetJustifyH("LEFT");deck.title:SetWordWrap(false)
        deck.detail=deck:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall");deck.detail:SetPoint("TOPLEFT",deck.title,"BOTTOMLEFT",0,-5);deck.detail:SetJustifyH("LEFT");deck.detail:SetWordWrap(true)
        local function button(label,x,action)
            local b=CreateFrame("Button",nil,deck,"UIPanelButtonTemplate");b:SetSize(26,22);b:SetPoint("BOTTOMRIGHT",x,8);b:SetText(label);b:SetScript("OnClick",action);return b
        end
        deck.prev=button("<",-70,function() deck.index=(deck.index-2)%#deck.refs+1;deck.update() end)
        deck.next=button(">",-8,function() deck.index=deck.index%#deck.refs+1;deck.update() end)
        deck.count=deck:CreateFontString(nil,"OVERLAY","GameFontDisableSmall");deck.count:SetPoint("CENTER",deck,"BOTTOMRIGHT",-49,19)
        deck.remove=button("x",-8,function() if deck.onRemove then deck.onRemove(deck.refs[deck.index]) end end);deck.remove:ClearAllPoints();deck.remove:SetPoint("TOPRIGHT",-5,-5)
        deck:EnableMouse(true)
        deck:SetScript("OnEnter",function(self)
            local r=self.refs[self.index];GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
            if r.id and r.kind~="dungeon" then
                pcall(GameTooltip.SetHyperlink,GameTooltip,r.payload or (r.kind..":"..r.id))
                if r.kind=="item" then
                    if GameTooltip_ShowCompareItem then pcall(GameTooltip_ShowCompareItem,GameTooltip) end
                end
            else GameTooltip:AddLine(r.name or "Dungeon");GameTooltip:AddLine(r.note or "",1,1,1,true) end
            GameTooltip:Show()
        end)
        deck:SetScript("OnLeave",function() GameTooltip:Hide() end)
        deck:RegisterEvent("GET_ITEM_INFO_RECEIVED")
        deck:SetScript("OnEvent",function(self,_,id) local r=self.refs and self.refs[self.index];if r and r.kind=="item" and r.id==id then self.update() end end)
        deck.update=function()
            local r=deck.refs[deck.index];local name,icon,detail,_,quality=describe(r)
            local color=quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
            deck.title:SetTextColor(color and color.r or 1,color and color.g or .82,color and color.b or 0)
            deck.title:SetText(name);deck.icon:SetTexture(icon);deck.detail:SetText(detail)
            deck.count:SetText(deck.index.."/"..#deck.refs)
            deck.prev:SetShown(#deck.refs>1);deck.next:SetShown(#deck.refs>1);deck.count:SetShown(#deck.refs>1)
            deck.remove:SetShown(deck.onRemove~=nil)
        end
    end
    deck.refs=refs;deck.index=math.min(deck.index or 1,#refs);deck.onRemove=remove
    deck:SetWidth(width);deck:SetHeight(92);deck:ClearAllPoints();deck:SetPoint("TOPLEFT",anchor or parent,"BOTTOMLEFT",0,-8)
    deck.title:SetWidth(math.max(30,width-85));deck.detail:SetWidth(math.max(30,width-66));deck.detail:SetHeight(42)
    deck.update();deck:Show();return 100
end
function WoWAI.ReceiveReferenceCards(data)
    if not data or data.session~=WoWAIDB.session or data.guid~=call(UnitGUID,"player") then return end
    local c
    for _,chat in ipairs(WoWAIDB.chats) do if chat.id==data.chat then c=chat;break end end
    if not c then return end
    c.referenceCards=c.referenceCards or {}
    c.referenceCards[tostring(data.id)]=data.cards
    for _,message in ipairs(c.history) do if message.id==data.id and message.role=="assistant" then message.references=data.cards end end
    if WoWAI.Render then WoWAI.Render() end
end
