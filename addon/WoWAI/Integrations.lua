local function safe(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
end
local function public(v)
    if issecretvalue and issecretvalue(v) then return end
    if canaccessvalue and not canaccessvalue(v) then return end
    return v
end
local function bounded(v, n)
    v = public(v)
    if type(v) == "string" then return v:sub(1, n or 180) end
    if type(v) == "number" or type(v) == "boolean" then return v end
end
function WoWAI.IntegrationSnapshot(metadataOnly)
    local result = { gearquest = { installed = false }, dungeonJournal = { installed = false } }
    local g, d = _G.GearQuest, _G.ForeverDungeonJournal_NS
    if d and d.DB then
        local count = 0
        for _ in pairs(d.DB) do count = count + 1 end
        result.dungeonJournal = { installed = true, version = safe(C_AddOns and C_AddOns.GetAddOnMetadata, "ForeverDungeonJournal", "Version"), dungeons = count }
    end
    if not (g and g.Data and g.Data.GetTopUpgradesForSlot) then return result end
    local _, class = safe(UnitClass, "player")
    local level = public(safe(UnitLevel, "player"))
    local faction = public(safe(UnitFactionGroup, "player"))
    local spec = g.Spec and (safe(g.Spec.DetectSpecFromTalents, g.Spec, class) or
        safe(g.Spec.GetSavedSpec, g.Spec, class) or safe(g.Spec.GetDefaultSpec, g.Spec, class))
    local gear = { installed = true, version = bounded(g.VERSION), class = class, level = level, faction = faction, spec = bounded(spec), projections = {},
        simulator = { enabled = safe(g.IsPreviewEnabled, g), class = safe(g.GetEffectiveClass, g), level = safe(g.GetEffectiveLevel, g), faction = safe(g.GetEffectiveFaction, g), spec = safe(g.GetEffectiveSpec, g) },
        evidence = "GearQuest rankings and curated/datamined records; not measured combat logs." }
    result.gearquest = gear
    if metadataOnly then gear.projections=nil;gear.projectionsRequested=false;return result end
    gear.projectionsRequested=true
    if type(level) ~= "number" or not class then return result end
    -- Queries are synchronous. Preserve the addon simulator and its cache exactly.
    local names = { "GetEffectiveClass", "GetEffectiveLevel", "GetEffectiveFaction", "GetEffectiveSpec" }
    local old, cache = {}, g.Data._queryCache
    for _, name in ipairs(names) do old[name] = g[name] end
    g.GetEffectiveClass = function() return class end
    g.GetEffectiveLevel = function() return level end
    g.GetEffectiveFaction = function() return faction end
    g.GetEffectiveSpec = function() return spec end
    g.Data._queryCache = nil
    local ok, err = pcall(function()
        for _, slot in ipairs({ "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet", "Finger", "Trinket", "MainHand", "SecondaryHand", "Ranged" }) do
            local picks = safe(g.Data.GetTopUpgradesForSlot, g.Data, slot, 2) or {}
            for rank, entry in ipairs(picks) do
                local row = { slot = slot, rank = rank }
                for _, key in ipairs({ "itemId", "minLevel", "maxLevel", "sourceType", "source", "questId", "questName", "dungeon", "boss", "curatedRank", "suffix", "origin" }) do row[key] = bounded(entry[key]) end
                row.name = bounded(safe(g.Data.GetEntryDisplayName, g.Data, entry) or safe(g.Data.GetItemDisplayName, g.Data, entry.itemId))
                row.instructions = bounded(safe(g.Data.GetEntryInstructions, g.Data, entry), 220)
                row.status = bounded(safe(g.Data.GetForeverStatus, g.Data, entry.itemId))
                row.score = public(safe(g.Compare and g.Compare.GetEntryPowerScore, g.Compare, entry))
                if row.itemId then gear.projections[#gear.projections + 1] = row end
            end
        end
    end)
    for _, name in ipairs(names) do g[name] = old[name] end
    g.Data._queryCache = cache
    if not ok then gear.error = bounded(tostring(err)) end
    return result
end
