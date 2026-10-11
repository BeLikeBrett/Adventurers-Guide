'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Catalog = require('../bridge/addon-catalog');
const Cards = require('../bridge/reference-cards');

test('installed tables expose exact loot, routes, prerequisites and character-filtered gear', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'guide-catalog-'));
  const write = (file, text) => { fs.mkdirSync(path.dirname(path.join(dir, file)), {recursive:true}); fs.writeFileSync(path.join(dir,file),text); };
  try {
    write('ForeverDungeonJournal/Data/Dungeons.lua', 'local _,D=...;D.DB={["Test Cavern"]={level="13-18",quests={{id=77,name="Gather hides"}},bosses={{name="Test boss",loot={{11853,"Feet"}}}}}}');
    write('ForeverDungeonJournal/Data/DungeonEntrances.lua', 'local _,D=...;D.DB["Test Cavern"].entrance={mapID=1431,x=.4,y=.5}');
    write('ForeverDungeonJournal/Data/DungeonRoutes.lua', 'local _,D=...;D.DB["Test Cavern"].routeGuide={text="Follow the western road"}');
    write('ForeverDungeonJournal/Data/QuestChains.lua', 'local _,D=...;D.QUEST_PREREQ_CHAINS={[77]={76}}');
    write('GearQuestForever/Data.lua', 'local _,G=...;G.Data={entries={{itemId=11853,slot="Feet",minLevel=10,maxLevel=20,classes={HUNTER=true},factions={Horde=true},instructions="Complete a quest"},{itemId=999,slot="Feet",minLevel=50,maxLevel=60}}}');
    write('GearQuestForever/_generated/Data.ScoredStats.generated.lua', 'local _,G=...;G.Data.scoredStats={[11853]={agi=3,sta=1}}');
    write('GearQuestForever/_generated/Data.ForeverAudit.generated.lua', 'local _,G=...;G.Data.foreverAudit={[11853]={name="Rambling Boots",status="ok"}}');
    const dungeon = Catalog.queryDungeons(dir,{itemId:11853,details:true},{level:14}).records[0];
    assert.equal(dungeon.name,'Test Cavern');
    assert.equal(dungeon.entrance.mapID,1431);
    assert.match(dungeon.route.text,/western road/);
    assert.deepEqual(dungeon.questPrerequisites[77],[76]);
    const gear = Catalog.queryGear(dir,{slot:'Feet'},{level:14,class:'HUNTER',faction:'Horde'});
    assert.deepEqual(gear.records.map(r=>r.itemId),[11853]);
    assert.equal(gear.records[0].stats.agi,3);
    assert.equal(gear.records[0].audit.name,'Rambling Boots');
    assert.equal(Catalog.queryGear(dir,{slot:'Feet'},{level:14,class:'MAGE',faction:'Horde'}).records.length,0);
    assert.equal(Catalog.queryGear(dir,{itemId:1234},{level:14}).records[0].stats,undefined,'missing stats remain unknown');
    write('ForeverDungeonJournal/Data/QuestUpdates.lua', 'os.execute("touch forbidden")');
    assert.match(Catalog.dungeonCatalog(dir).errors[0],/QuestUpdates/);
    assert.equal(fs.existsSync(path.join(dir,'forbidden')),false);
  } finally { fs.rmSync(dir,{recursive:true,force:true}); }
});

test('visible transcripts retain reference cards without tooltip dumps or quality escapes', () => {
  const message = '|cnIQ2:|Hitem:11853|h[Rambling Boots]|h|r good for me?\n\n--- Linked from the game ---\n[Rambling Boots] item 11853 (Uncommon)\n  +3 Agility\n[Test quest] quest 77\n  Collect three hides';
  const clean = Cards.displayMessage(message);
  assert.equal(clean.text,'[Rambling Boots] good for me?');
  assert.deepEqual(clean.references.map(r=>[r.kind,r.id]),[['item',11853],['quest',77]]);
  assert.equal(clean.references[0].payload,'item:11853');
  assert.throws(()=>Cards.validateCards([{kind:'item',id:-1}]),/positive/);
  assert.throws(()=>Cards.validateCards(Array.from({length:13},()=>({kind:'item',id:1}))),/1–12/);
  assert.doesNotThrow(()=>Cards.validateCards([{kind:'dungeon',name:'Test Cavern'}]));
});

test('model context excludes heavy cached sections and only explicit visual questions attach screenshots',()=>{
 const {promptSnapshot,needsVision,matchingSnapshot}=require('../bridge/prompt-context');
 const snapshot={session:'session',token:5,receivedAt:1000,sectionTimes:{player:1000,quests:500},snapshot:{player:{guid:'Player-1'},quests:Array.from({length:40},(_,id)=>({id})),inventory:Array.from({length:140},(_,id)=>({id})),spells:Array(1000).fill('spell'),bank:{huge:true},combat:{events:['private']},integrations:{gearquest:{installed:true,projections:Array(500).fill('gear')}}}};
 const context=promptSnapshot(snapshot,1500);
 assert.equal(context.quests.length,30);assert.equal(context.inventory.length,120);assert.equal(context.omitted.quests,10);
 assert.equal(context.spells,undefined);assert.equal(context.bank,undefined);assert.equal(context.combat,undefined);assert.equal(context.integrations.gearquest.projections,undefined);
 assert.equal(needsVision('where do I get light hide?'),false);assert.equal(needsVision('look at my screen'),true);
 assert.equal(matchingSnapshot(snapshot,{session:'session',snapshotToken:4},2000),true);
 assert.equal(matchingSnapshot(snapshot,{session:'other'},2000),false);
 assert.equal(matchingSnapshot(snapshot,{session:'session',snapshotToken:6},2000),false);
});

test('expanded attachment metadata preserves distinct item variants on transcript restore',()=>{
 const clean=Cards.displayMessage('Compare these\n\n--- Linked from the game ---\n[Knife of Agility] item 2140 {link=item:2140:0:0:0:0:0:15}\n  +3 Agility\n[Knife of Stamina] item 2140 {link=item:2140:0:0:0:0:0:16}\n  +3 Stamina');
 assert.equal(clean.text,'Compare these');
 assert.deepEqual(clean.references.map(r=>r.payload),['item:2140:0:0:0:0:0:15','item:2140:0:0:0:0:0:16']);
});


test('Guide prompts avoid legacy coding-agent instructions and duplicate closing summaries',()=>{
 const {guidePrompt}=require('../bridge/prompt-context');
 const prompt=guidePrompt('Character: TestHunter','Use fresh character data.','How much damage did I do?');
 assert.ok(prompt.includes('player’s journal')&&prompt.includes('Character: TestHunter'));
 assert.ok(!prompt.includes('TL;DR')&&!prompt.includes('WOW_AI_MAP_FILE')&&!prompt.includes('writing addons'));
 assert.equal(prompt.match(/Use fresh character data/g).length,1);
 assert.ok(!prompt.includes('wowmacro'));
 assert.ok(guidePrompt('','', 'Write a macro').includes('255 characters'));
});


test('question context keeps relevant data and exposes omitted sections without implying emptiness',()=>{
 const {promptSnapshot}=require('../bridge/prompt-context');
 const snapshot={receivedAt:1000,snapshot:{player:{level:14},quests:[{id:1}],inventory:Array(120).fill({itemID:11853,name:'Rambling Boots',tooltip:'Leather boots, 51 Armor, 3 Agility, 1 Stamina'}),equipment:[{slot:8}],stats:{agility:24},talents:[{name:'Hunter'}],pet:{name:'Bear'}}};
 const full=promptSnapshot(snapshot,1500);
 const quest=promptSnapshot(snapshot,1500,'Where do I turn in my quest?');
 assert.equal(quest.inventory,undefined);assert.equal(quest.equipment,undefined);assert.equal(quest.quests.length,1);
 assert.ok(JSON.stringify(quest).length<JSON.stringify(full).length/3);
 const gear=promptSnapshot(snapshot,1500,'Are these good? item:11853');
 assert.deepEqual(gear.equipment,snapshot.snapshot.equipment);assert.equal(gear.inventory.length,120);
 const combat=promptSnapshot(snapshot,1500,'Rank my damage and crits');
 assert.deepEqual(combat.pet,snapshot.snapshot.pet);assert.equal(combat.quests,undefined);
 assert.ok(combat.omitted.explanation.includes('does not mean empty'));
 const partial=promptSnapshot({receivedAt:1000,snapshot:{player:{level:14}}},1500,'Where do I go?');
 assert.equal(partial.quests,undefined);assert.equal(partial.inventory,undefined);
});
