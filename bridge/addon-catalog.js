'use strict';
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');
const caches = new Map();
const files = ['Data/Dungeons.lua', 'Data/DungeonEntrances.lua', 'Data/DungeonRoutes.lua', 'Data/Bosses.lua', 'Data/QuestMaps.lua', 'Data/QuestChains.lua', 'Data/QuestRewards.lua', 'Data/QuestShareability.lua', 'Data/QuestUpdates.lua', 'UI/ItemComparisonData.lua'];
function readCatalog(addonDir, addonName, sourceFiles, namespace, bootstrap) {
  const dir = path.join(addonDir, addonName);
  const files = sourceFiles;
  const cache = caches.get(dir);
  const present = files.filter(f => fs.existsSync(path.join(dir, f)));
  const key = present.map(f => `${f}:${fs.statSync(path.join(dir, f)).mtimeMs}`).join('|');
  if (cache?.dir === dir && cache.key === key) return cache.data;
  if (!present.length) return { installed: false, dungeons: {} };
  const L = lauxlib.luaL_newstate(); lualib.luaL_openlibs(L);
  const run = code => {
    if (lauxlib.luaL_loadstring(L, to_luastring(code)) !== lua.LUA_OK || lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
  };
  // The isolated Lua VM has no filesystem, process, network or package access.
  run('io=nil;os=nil;package=nil;require=nil;dofile=nil;loadfile=nil;debug=nil; GetLocale=function() return "enUS" end; ' + bootstrap);
  const errors = [];
  for (const file of present) {
    try { run(`local function source(...)\n${fs.readFileSync(path.join(dir, file), 'utf8')}\nend\nsource("${addonName}",${namespace})`); }
    catch (e) { errors.push(`${file}: ${e.message}`); lua.lua_settop(L, 0); }
  }
  run(`local function quote(v) return '"'..tostring(v):gsub('[%z\\1-\\31\\\\"]',function(c) return string.format('\\\\u%04x',string.byte(c)) end)..'"' end
local seen={}
local function encode(v,depth)
 if type(v)=='string' then return quote(v) elseif type(v)=='number' then return tostring(v) elseif type(v)=='boolean' then return tostring(v) end
 if type(v)~='table' or depth>12 or seen[v] then return 'null' end
 seen[v]=true;local out={};local array=#v>0
 if array then for k in pairs(v) do if type(k)~='number' or k<1 or k>#v or k%1~=0 then array=false;break end end end
 if array then for i=1,#v do out[#out+1]=encode(v[i],depth+1) end
 else for k,x in pairs(v) do if type(x)~='function' then out[#out+1]=quote(k)..':'..encode(x,depth+1) end end end
 seen[v]=nil;return (array and '[' or '{')..table.concat(out,',')..(array and ']' or '}')
end
RESULT=encode(${namespace},0)`);
  lua.lua_getglobal(L, to_luastring('RESULT'));
  const data = { installed: true, source: `Installed ${addonName}`, errors, ...JSON.parse(to_jsstring(lua.lua_tostring(L, -1))) };
  caches.set(dir, {dir, key, data});return data;
}
function dungeonCatalog(addonDir) {
  return readCatalog(addonDir, 'ForeverDungeonJournal', files, 'FDJ', 'FDJ={Constants={ALBA_FAIRMOON_LOCATION="Alba Fairmoon, Sentinel Hill inn, Westfall"}}; ForeverDungeonJournal_NS=FDJ');
}
function gearCatalog(addonDir) {
  return readCatalog(addonDir, 'GearQuestForever', ['Data.lua', ...['StatWeights','ScoringWeights','CraftSkills','Data.ForeverAudit','Data.ScoredStats','Data.Coordinates','Data.QuestFaction'].map(f=>'_generated/'+f+'.generated.lua')], 'GQ', 'GQ={}; GearQuest=GQ');
}
function queryGear(addonDir,args={},character={}) {
  const catalog=gearCatalog(addonDir),data=catalog.Data||{};
  const entries=(data.entries||[]).filter(e=>args.itemId ? e.itemId===args.itemId :
    (!args.slot||e.slot?.toLowerCase()===args.slot.toLowerCase()) &&
    (!e.minLevel||character.level>=e.minLevel) && (!e.maxLevel||character.level<=e.maxLevel) &&
    (!e.classes||e.classes[character.class]) && (!e.factions||e.factions[character.faction]) && (!e.specs||e.specs[character.spec]));
  const records=entries.slice(0,args.limit||12).map(e=>({...e,
    audit:data.foreverAudit?.[e.itemId],stats:data.scoredStats?.[e.itemId],coordinates:data.coordinates?.[e.itemId],questFaction:data.questFaction?.[e.questId]}));
  // Linked items can be outside the current upgrade band but still have audit data.
  if(args.itemId&&!records.length) records.push({itemId:args.itemId,audit:data.foreverAudit?.[args.itemId],stats:data.scoredStats?.[args.itemId]});
  return {installed:catalog.installed,errors:catalog.errors,totalCandidates:entries.length,records,
    statWeights:catalog.StatWeights?.[character.class]?.[character.spec],scoringWeights:catalog.ScoringWeights?.[character.class]?.[character.spec],levelingWeights:catalog.ScoringLeveling,
    evidence:'Installed GearQuest curated/datamined tables. Live item tooltips take precedence; missing stats are unknown.'};
}
function containsItem(value,id) {
  if(!value || typeof value!=='object') return false;
  if(value.itemId===id || value.itemID===id || value.id===id || (Array.isArray(value)&&value[0]===id)) return true;
  return Object.values(value).some(v=>containsItem(v,id));
}
function queryDungeons(addonDir, args = {}, player = {}) {
  const catalog = dungeonCatalog(addonDir);
  const matches = Object.entries(catalog.DB || {}).filter(([name, d]) => {
    if (args.name && !name.toLowerCase().includes(args.name.toLowerCase())) return false;
    if (args.itemId && !containsItem(d,args.itemId)) return false;
    if (args.level) { const band = String(d.level).match(/(\d+).*?(\d+)/); if (band && (args.level < +band[1] - 3 || args.level > +band[2] + 5)) return false; }
    return true;
  }).slice(0, args.name ? 8 : 4);
  return { installed: catalog.installed, source: catalog.source, errors: catalog.errors,
    characterLevel: player.level, records: matches.map(([name, d]) => args.details ? { name, ...d,
      entrance: d.entrance || catalog.DUNGEON_ENTRANCES?.[name], route: d.routeGuide || catalog.DUNGEON_ROUTES?.[name],
      questPrerequisites: Object.fromEntries((d.quests || []).filter(q=>catalog.QUEST_PREREQ_CHAINS?.[q.id]).map(q=>[q.id,catalog.QUEST_PREREQ_CHAINS[q.id]]))
    } : { name, level: d.level, location: d.location, bosses: (d.bosses || []).map(b => b.name), quests: (d.quests || []).map(q=>({id:q.id,name:q.name,requires:q.requires,faction:q.faction})) }) };
}
module.exports = { dungeonCatalog, queryDungeons, gearCatalog, queryGear };
