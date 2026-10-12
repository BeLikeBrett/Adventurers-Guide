'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {CombatLog,parseLine,timestamp,csv}=require('../bridge/combat-log');
const date=Date.parse('2026-10-11T20:00:00.000Z');
const time=at=>{const d=new Date(at);return `${d.getUTCMonth()+1}/${d.getUTCDate()}/${d.getUTCFullYear()} ${d.getUTCHours()}:${String(d.getUTCMinutes()).padStart(2,'0')}:${String(d.getUTCSeconds()).padStart(2,'0')}.${String(d.getUTCMilliseconds()).padStart(3,'0')}0  `;};
function line(event,{source='Player-mine',sourceName='You',dest='Creature-target',destName='Target',flags='0x511',destFlags='0xa48',spell=75,name='Shot',amount=100,crit='nil',at=date-1000,advanced=false,owner='0000000000000000',off='nil'}={}){
 const fields=[event,source,JSON.stringify(sourceName),flags,'0x0',dest,JSON.stringify(destName),destFlags,'0x0'];
 const isSpell=event.startsWith('SPELL_')||event.startsWith('RANGE_');
 if(isSpell)fields.push(spell,JSON.stringify(name),'0x1');
 if(advanced)fields.push(source,owner,...Array(17).fill('0'));
 if(event.endsWith('_DAMAGE')||event==='SWING_DAMAGE_LANDED')fields.push(amount,...(advanced?[amount+50]:[]),-1,'0x1',3,4,5,crit,'nil','nil',...(advanced&&isSpell?['ST']:[off]));
 if(event.endsWith('_MISSED'))fields.push('DODGE',off,0);
 return time(at)+fields.join(',');
}
function fixture(options={}){
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'guide-combat-')),addon=path.join(dir,'Interface','AddOns'),logs=path.join(dir,'Logs');fs.mkdirSync(addon,{recursive:true});fs.mkdirSync(logs);
 let now=date;const log=new CombatLog(addon,{now:()=>now,...options}),file=path.join(logs,'WoWCombatLog.txt');
 const write=lines=>fs.writeFileSync(file,lines.join('\n')+'\n');const append=lines=>fs.appendFileSync(file,lines.join('\n')+'\n');
 return {dir,log,file,write,append,advance:ms=>now+=ms,close:()=>fs.rmSync(dir,{recursive:true,force:true}),snapshot:{player:{guid:'Player-mine'},pet:{guid:'Pet-mine'}}};
}
test('CSV handles quoted commas, escapes, advanced arrays and offsets including year rollover',()=>{
 assert.deepEqual(csv('SPELL,"A, B",[1,2],"a""b",nil'),['SPELL','A, B','[1,2]','a"b','nil']);
 assert.equal(csv('"unfinished'),null);
 assert.equal(timestamp('10/11/2026 15:00:00.123-5  TEST',date).at,date+123);
 assert.equal(timestamp('10/11/2026 22:00:00.1232  TEST',date).at,date+123);
 const jan=Date.parse('2027-01-01T00:00:00Z');
 assert.equal(timestamp('12/31 23:59:59.1230  TEST',jan).at,jan-877);
});
test('normal and modern advanced damage preserve actual health loss, mitigation, crits and weapon hand',()=>{
 const plain=parseLine(line('SPELL_DAMAGE',{crit:'1'}),date);
 assert.equal(plain.amount,100);assert.equal(plain.critical,true);assert.equal(plain.blocked,4);assert.equal(plain.absorbed,5);assert.equal(plain.effective,100);
 const advanced=parseLine(line('SPELL_DAMAGE',{advanced:true,crit:'1'}),date,22);
 assert.equal(advanced.amount,100);assert.equal(advanced.rawAmount,150);assert.equal(advanced.critical,true);assert.equal(advanced.resisted,3);
 const swing=parseLine(line('SWING_DAMAGE',{advanced:true,off:'1',crit:'1'}),date,22);
 assert.equal(swing.hand,'offhand');assert.equal(swing.critical,true);assert.equal(swing.amount,100);
 assert.equal(parseLine(line('SWING_DAMAGE_LANDED',{advanced:true}),date,22).amount,100);
 assert.equal(parseLine(line('SPELL_DAMAGE_SUPPORT',{advanced:true}),date,22),null);
 const strange=line('SPELL_DAMAGE').replace(/,100,/,',100,99,88,');assert.equal(parseLine(strange,date).unsupported,true);
});
test('reports rank incoming attackers separately from damage to your pet and outgoing owner/minions',()=>{
 const f=fixture();try{
  f.write([
   line('SPELL_DAMAGE',{amount:90,crit:'1'}),
   line('SPELL_DAMAGE',{source:'Pet-mine',sourceName:'Wolf',amount:60}),
   line('SPELL_SUMMON',{source:'Pet-mine',dest:'Creature-guardian',destName:'Guardian'}),
   line('SPELL_DAMAGE',{source:'Creature-guardian',sourceName:'Guardian',flags:'0x111',amount:30}),
   line('SPELL_DAMAGE',{source:'Player-other',flags:'0x512',amount:999}),
   line('SPELL_DAMAGE',{source:'Creature-other-pet',flags:'0x1112',amount:999}),
   line('SPELL_DAMAGE',{source:'Creature-elite',sourceName:'Enemy, Captain',flags:'0xa48',dest:'Player-mine',destName:'You',spell:88,name:'Cleave',amount:80,crit:'1'}),
   line('SWING_DAMAGE',{source:'Creature-rat',sourceName:'Rat',flags:'0xa48',dest:'Player-mine',destName:'You',amount:20}),
   line('SPELL_DAMAGE',{source:'Creature-rat',flags:'0xa48',dest:'Pet-mine',destName:'Wolf',amount:55}),
   line('SPELL_CAST_SUCCESS'),line('SWING_MISSED')]);
  const r=f.log.summary(f.snapshot,{seconds:30});
  assert.equal(r.available,true);assert.equal(r.outgoing.damage,180);assert.equal(r.outgoing.crits,1);assert.equal(r.sources.length,3);
  assert.equal(r.incoming.damage,100);assert.equal(r.incomingControlledUnits.damage,55);assert.equal(r.incoming.crits,1);assert.equal(r.incoming.critDamage,80);
  assert.equal(r.attackers[0].name,'Enemy, Captain');assert.equal(r.attackers[0].damage,80);assert.equal(r.incomingAbilities[0].name,'Cleave');
  assert.equal(r.outgoing.missTypes.DODGE,1);assert.equal(r.castSequence.length,1);assert.equal(r.capabilities.weaponIdentity,false);
  assert.equal(f.log.summary(f.snapshot,{includePets:false}).outgoing.damage,90);
 }finally{f.close();}
});
test('advanced owner GUID backfills guardian events but never claims hostile enemy ownership',()=>{
 const f=fixture();try{
  f.write([time(date-2000)+'COMBAT_LOG_VERSION,22,ADVANCED_LOG_ENABLED,1,BUILD_VERSION,12.0.1,PROJECT_ID,1',
   line('SPELL_DAMAGE',{source:'Creature-summon',flags:'0x1112',amount:25,at:date-1500}),
   line('SPELL_DAMAGE',{source:'Creature-summon',flags:'0x1112',amount:50,advanced:true,owner:'Player-mine'}),
   line('SPELL_DAMAGE',{source:'Creature-enemy',flags:'0xa48',amount:999,advanced:true,owner:'Player-mine'})]);
  const r=f.log.summary(f.snapshot);assert.equal(r.outgoing.damage,75);assert.equal(r.sources[0].kind,'guardian');assert.equal(r.recording.formatVersion,22);
 }finally{f.close();}
});
test('incremental reads wait for partial lines, retain UTF8, reset truncation and keep bounded history',()=>{
 const f=fixture({maxEvents:2});try{
  const first=line('SPELL_DAMAGE',{name:'Árrow'});fs.writeFileSync(f.file,first.slice(0,-4));f.log.read();assert.equal(f.log.events.length,0);
  fs.appendFileSync(f.file,first.slice(-4)+'\n');assert.equal(f.log.summary(f.snapshot).outgoing.damage,100);
  f.append([line('SPELL_DAMAGE',{amount:20}),line('SPELL_DAMAGE',{amount:30})]);const r=f.log.summary(f.snapshot);assert.equal(r.outgoing.damage,50);assert.equal(r.coverageComplete,false);
  f.write([line('SPELL_DAMAGE',{amount:7})]);assert.equal(f.log.summary(f.snapshot).outgoing.damage,7);
  f.advance(301000);assert.equal(f.log.summary(f.snapshot).available,false);
 }finally{f.close();}
});
test('fixed windows exclude hits after their endpoint; unknown and missing data never pretend zero',()=>{
 const f=fixture();try{
  const missing=f.log.summary(f.snapshot);assert.equal(missing.available,false);assert.match(missing.reason,/combatlog/);
  f.write([line('SPELL_DAMAGE',{at:date-2000,amount:80}),line('SPELL_DAMAGE',{at:date-500,amount:999})]);
  const r=f.log.summary(f.snapshot,{from:date-3000,to:date-1000});assert.equal(r.outgoing.damage,80);assert.equal(r.windowSeconds,2);
  assert.equal(f.log.summary({player:{guid:'Player-other'}}).available,false);
  f.write([line('SPELL_DAMAGE').replace(/,100,/,',100,99,88,')]);const unknown=f.log.summary(f.snapshot);assert.equal(unknown.available,false);assert.equal(unknown.recording.unsupportedEvents,1);
 }finally{f.close();}
});
test('absorbs and heals remain separate and do not double the damage-field absorbs',()=>{
 const f=fixture();try{
  const header=['SPELL_ABSORBED','Creature-enemy','"Enemy"','0xa48','0x0','Player-mine','"You"','0x511','0x0'];
  const absorb=time(date-1000)+[...header,'Player-mine','"You"','0x511','0x0',17,'"Shield"','0x2',40,80,'nil'].join(',');
  f.write([line('SPELL_DAMAGE',{source:'Creature-enemy',flags:'0xa48',dest:'Player-mine',amount:20}),absorb]);
  const r=f.log.summary(f.snapshot);assert.equal(r.incoming.damage,20);assert.equal(r.incoming.absorbed,5);assert.equal(r.incoming.absorbEventsAmount,40);assert.equal(r.events[1].shieldName,'Shield');
 }finally{f.close();}
});

test('event pagination and spell filters keep complete totals and a stable fixed window',()=>{
 const f=fixture();try{
  f.write([line('SPELL_DAMAGE',{amount:10,spell:75}),line('SPELL_DAMAGE',{amount:20,spell:88}),line('SPELL_DAMAGE',{amount:30,spell:75})]);
  const first=f.log.summary(f.snapshot,{seconds:30,eventLimit:1,spellID:75});assert.equal(first.outgoing.damage,60);assert.equal(first.events[0].damage,10);assert.equal(first.nextEventOffset,1);assert.equal(first.filteredEventCount,2);
  f.advance(5000);const next=f.log.summary(f.snapshot,{seconds:30,to:Date.parse(first.to),eventLimit:1,eventOffset:1,spellID:75});assert.equal(next.events[0].damage,30);assert.equal(next.outgoing.damage,60);assert.equal(next.nextEventOffset,null);
 }finally{f.close();}
});
test('rotated logs and timestamps from another character never attribute old pets to the current character',()=>{
 const f=fixture();try{
  f.write([line('SPELL_DAMAGE',{source:'Pet-old',flags:'0x1111',amount:999}),line('SPELL_DAMAGE',{source:'Player-old',flags:'0x511',amount:999}),line('SPELL_DAMAGE',{amount:10})]);
  assert.equal(f.log.summary(f.snapshot).outgoing.damage,10);
  fs.renameSync(f.file,f.file+'.old');f.write([line('SPELL_DAMAGE',{amount:5})]);assert.equal(f.log.summary(f.snapshot).outgoing.damage,5);
 }finally{f.close();}
});

test('environmental falls and modern normal logs preserve raw/crit field shifts',()=>{
 const fields=['ENVIRONMENTAL_DAMAGE','0000000000000000','nil','0x0','0x0','Player-mine','"You"','0x511','0x0',...Array(19).fill('0'),'Falling',85,95,-1,'0x1',0,0,0,'nil','nil','nil'];
 const fall=parseLine(time(date-1000)+fields.join(','),date,22);assert.equal(fall.name,'Falling');assert.equal(fall.amount,85);assert.equal(fall.rawAmount,95);
 const spell=line('SPELL_DAMAGE',{advanced:true,crit:'1'});const payload=csv(spell.slice(time(date-1000).length));payload.splice(12,19);const ordinary=parseLine(time(date-1000)+payload.join(','),date,22);
 assert.equal(ordinary.amount,100);assert.equal(ordinary.rawAmount,150);assert.equal(ordinary.critical,true);
 const swing=line('SWING_DAMAGE',{advanced:true,off:'1',crit:'1'});const swings=csv(swing.slice(time(date-1000).length));swings.splice(9,19);const swingOrdinary=parseLine(time(date-1000)+swings.join(','),date,22);
 assert.equal(swingOrdinary.hand,'offhand');assert.equal(swingOrdinary.critical,true);
});

test('Forever landed-only incoming swings survive while paired swings count once across reads',()=>{
 const f=fixture();try{
  f.write([time(date-2000)+'COMBAT_LOG_VERSION,22,ADVANCED_LOG_ENABLED,0,BUILD_VERSION,1.60.1,PROJECT_ID,18',
   line('SWING_DAMAGE_LANDED',{advanced:true,source:'Enemy',flags:'0xa48',dest:'Player-mine',amount:45,crit:'1'}),
   line('SWING_DAMAGE',{advanced:true,amount:100})]);
  assert.equal(f.log.summary(f.snapshot).incoming.damage,45);
  f.append([line('SWING_DAMAGE_LANDED',{advanced:true,amount:100})]);const r=f.log.summary(f.snapshot);
  assert.equal(r.outgoing.damage,100);assert.equal(r.incoming.damage,45);assert.equal(r.incoming.crits,1);
  f.append([line('SWING_DAMAGE_LANDED',{advanced:true,source:'Enemy',flags:'0xa48',dest:'Player-mine',amount:45,crit:'1'})]);
  assert.equal(f.log.summary(f.snapshot).incoming.damage,90,'identical events of the same kind remain distinct');
 }finally{f.close();}
});

test('ranged casts, hits and misses share one ability total instead of zero-damage duplicates',()=>{
 const f=fixture();try{
  f.write([line('SPELL_CAST_SUCCESS'),line('RANGE_DAMAGE',{amount:25}),line('SPELL_MISSED')]);
  const r=f.log.summary(f.snapshot);assert.equal(r.abilities.length,1);assert.equal(r.abilities[0].damage,25);assert.equal(r.abilities[0].hits,1);assert.equal(r.abilities[0].casts,1);assert.equal(r.abilities[0].misses,1);
 }finally{f.close();}
});

test('flushing an old segment and opening a new header does not lose the fight',()=>{
 const f=fixture();try{
  f.write([line('SPELL_DAMAGE',{amount:25,dest:'Sunscale-1',destName:'Sunscale'})]);f.log.read();
  f.append([line('SPELL_DAMAGE',{amount:40,dest:'Sunscale-1',destName:'Sunscale'})]);
  const second=path.join(path.dirname(f.file),'WoWCombatLog-new.txt');fs.writeFileSync(second,time(date)+'COMBAT_LOG_VERSION,22,ADVANCED_LOG_ENABLED,1,BUILD_VERSION,1.60.1,PROJECT_ID,18\n');
  let r=f.log.summary(f.snapshot);assert.equal(r.outgoing.damage,65);assert.equal(r.targets[0].name,'Sunscale');assert.equal(r.targets[0].abilities[0].damage,65);
  fs.appendFileSync(second,line('SPELL_DAMAGE',{amount:10,dest:'Kodo-1',destName:'Kodo'})+'\n');
  r=f.log.summary(f.snapshot);assert.equal(r.outgoing.damage,75);assert.equal(r.targets.length,2);assert.equal(r.targets.find(t=>t.name==='Kodo').damage,10);assert.equal(r.targets.find(t=>t.name==='Sunscale').damage,65);
 }finally{f.close();}
});
