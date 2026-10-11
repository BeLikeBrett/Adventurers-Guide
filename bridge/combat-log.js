'use strict';
// Read-only local log tail. Layout reference: https://wowcoach.gg/docs/combat-log
// File events are independent of the client's restricted addon event API.
const fs=require('node:fs');
const path=require('node:path');
const {StringDecoder}=require('node:string_decoder');
const KEEP_MS=300000,MAX_EVENTS=16000,MAX_READ=4*1024*1024;
const damageEvents=new Set(['SWING_DAMAGE','RANGE_DAMAGE','SPELL_DAMAGE','SPELL_PERIODIC_DAMAGE','DAMAGE_SHIELD','DAMAGE_SPLIT','ENVIRONMENTAL_DAMAGE']);
const numeric=v=>v!==''&&v!=='nil'&&v!==undefined&&Number.isFinite(Number(v))?Number(v):null;
const positive=v=>Math.max(0,numeric(v)||0);
const flag=v=>v==='1'||v==='true';
function csv(input){
 const out=[];let value='',quoted=false,depth=0;
 for(let i=0;i<input.length;i++){
  const c=input[i];
  if(c==='"'){
   if(quoted&&input[i+1]==='"'){value+='"';i++;}
   else quoted=!quoted;
  }else if(c==='\\'&&quoted&&['"','\\'].includes(input[i+1])) value+=input[++i];
  else if(!quoted&&c===','&&depth===0){out.push(value);value='';}
  else {if(!quoted&&c==='[')depth++;if(!quoted&&c===']')depth--;value+=c;}
 }
 if(quoted||depth!==0)return null;
 out.push(value);return out;
}
function timestamp(input,now){
 const m=input.match(/^(\d{1,2})\/(\d{1,2})(?:\/(\d{4}))? (\d{1,2}):(\d{2}):(\d{2})\.(\d{3})([+-]?\d{1,2})?\s{2,}|^(\d{1,2})\/(\d{1,2})(?:\/(\d{4}))? (\d{1,2}):(\d{2}):(\d{2})\.(\d{3})([+-]?\d{1,2})?\t/);
 if(!m)return null;
 const a=m[1]?m.slice(1,9):m.slice(9,17);
 const [month,day,year,hour,min,sec,millis,offset]=a;
 if(+month<1||+month>12||+day<1||+day>31||+hour>23||+min>59||+sec>59||offset!==undefined&&Math.abs(+offset)>14)return null;
 const build=y=>offset===undefined?new Date(y,+month-1,+day,+hour,+min,+sec,+millis).getTime():Date.UTC(y,+month-1,+day,+hour,+min,+sec,+millis)-Number(offset)*3600000;
 let at=build(year?+year:new Date(now).getFullYear());
 if(!year){for(const y of [new Date(now).getFullYear()-1,new Date(now).getFullYear()+1]){const candidate=build(y);if(Math.abs(candidate-now)<Math.abs(at-now))at=candidate;}}
 return {at,text:input.slice(m[0].length)};
}
function parseLine(line,now=Date.now(),version){
 const time=timestamp(line.trimEnd(),now)||(line.startsWith('COMBAT_LOG_VERSION,')?{at:now,text:line.trimEnd()}:null);if(!time)return null;
 const f=csv(time.text);if(!f)return null;
 if(f[0]==='COMBAT_LOG_VERSION')return {header:true,version:numeric(f[1]),advanced:f[f.indexOf('ADVANCED_LOG_ENABLED')+1]==='1',build:f[f.indexOf('BUILD_VERSION')+1]};
 if(f.length<9)return null;
 const event=f[0];
 if(event.includes('_SUPPORT')||event==='SWING_DAMAGE_LANDED')return null;
 const e={at:time.at,event,source:f[1],sourceName:f[2]==='nil'?null:f[2],sourceFlags:numeric(f[3]),dest:f[5],destName:f[6]==='nil'?null:f[6],destFlags:numeric(f[7])};
 const spell=event.startsWith('SPELL_')&&event!=='SPELL_ABSORBED'||event.startsWith('RANGE_')||['DAMAGE_SHIELD','DAMAGE_SPLIT'].includes(event);
 e.spellID=spell?numeric(f[9]):0;e.name=spell?f[10]:'Melee';e.school=spell?numeric(f[11]):1;
 if(spell&&(e.spellID===null||!e.name))return {unsupported:true,at:e.at,event};
 if(['SPELL_SUMMON','SPELL_CREATE'].includes(event)){e.type='ownership';return e;}
 if(event==='UNIT_DIED'||event==='UNIT_DESTROYED'){e.type='death';return e;}
 let base=spell?12:9;
 if(damageEvents.has(event)){
  let raw=false,advanced=false;
  if(event==='ENVIRONMENTAL_DAMAGE'){
   if(f.length===39){base=29;e.name=f[28];raw=true;advanced=true;}
   else if(f.length===19||f.length===20){e.name=f[9];base=10;raw=f.length===20&&version!==undefined&&version>=22;}
   else return {unsupported:true,at:e.at,event};
  }else if(spell&&f.length===42||!spell&&(f.length===38||f.length===39)&&version!==undefined&&version>=22){base+=19;raw=true;advanced=true;}
  else if(spell&&f.length===23&&['ST','AOE'].includes(f[22])||!spell&&f.length===20&&version!==undefined&&version>=22){raw=true;}
  else if(f.length===base+10){}
  else if(version!==undefined&&version<22&&f.length===base+27){base+=17;advanced=true;}
  else return {unsupported:true,at:e.at,event};
  const shift=raw?1:0,amount=numeric(f[base]),school=numeric(f[base+2+shift]);
  // Reject unknown shifts instead of converting a crit flag or GUID into damage.
  if(amount===null||amount<0||school===null||!Number.isInteger(school)||school<1||school>127||raw&&(numeric(f[base+1])===null||numeric(f[base+1])<0)||![undefined,'nil','1','0','true','false'].includes(f[base+6+shift]))return {unsupported:true,at:e.at,event};
  e.type='damage';e.amount=amount;e.rawAmount=raw?numeric(f[base+1]):undefined;
  e.overkill=positive(f[base+1+shift]);e.effective=Math.max(0,amount-e.overkill);e.school=school;
  e.resisted=positive(f[base+3+shift]);e.blocked=positive(f[base+4+shift]);e.absorbed=positive(f[base+5+shift]);
  e.critical=flag(f[base+6+shift]);e.glancing=flag(f[base+7+shift]);e.crushing=flag(f[base+8+shift]);
  if(!spell&&event!=='ENVIRONMENTAL_DAMAGE')e.hand=flag(f[base+9+shift])?'offhand':'mainhand';
  if(event.startsWith('RANGE_'))e.hand='ranged';
  if(advanced){const start=spell?12:9;e.advancedGUID=f[start];e.ownerGUID=f[start+1];}
  e.periodic=event==='SPELL_PERIODIC_DAMAGE';return e;
 }
 if(event==='SPELL_HEAL'||event==='SPELL_PERIODIC_HEAL'){
  if(f.length===36){base=31;e.advancedGUID=f[12];e.ownerGUID=f[13];base++;}
  else if(f.length!==16)return {unsupported:true,at:e.at,event};
  if(numeric(f[base])===null)return {unsupported:true,at:e.at,event};
  e.type='healing';e.amount=positive(f[base]);e.overheal=positive(f[base+1]);e.effective=Math.max(0,e.amount-e.overheal);e.critical=flag(f[base+3]);return e;
 }
 if(event.endsWith('_MISSED')){
  if(!['MISS','DODGE','PARRY','BLOCK','EVADE','IMMUNE','DEFLECT','ABSORB','RESIST','REFLECT'].includes(f[base]))return {unsupported:true,at:e.at,event};
  e.type='miss';e.missType=f[base];e.absorbed=e.missType==='ABSORB'?positive(f[base+2]):0;e.hand=!spell?(flag(f[base+1])?'offhand':'mainhand'):event.startsWith('RANGE')?'ranged':undefined;return e;
 }
 if(event==='SPELL_CAST_SUCCESS'||event==='SPELL_CAST_FAILED'){e.type='cast';e.failed=event.endsWith('FAILED');e.failureReason=e.failed?f[base]:undefined;return e;}
 if(event==='SPELL_INTERRUPT'||event==='SPELL_DISPEL'){e.type='utility';e.extraSpellID=numeric(f[base]);e.extraSpellName=f[base+1];return e;}
 // Absorbs are kept separately from damage-field absorbs to avoid double counting.
 if(event==='SPELL_ABSORBED'){
  if(![17,20,19,22].includes(f.length))return {unsupported:true,at:e.at,event};
  const hasSpell=f.length===20||f.length===22;
  const caster=hasSpell?12:9,shield=caster+4,amount=shield+3;
  if(numeric(f[amount])===null||numeric(f[shield])===null)return {unsupported:true,at:e.at,event};
  e.type='absorb';e.spellID=hasSpell?numeric(f[9]):0;e.name=hasSpell?f[10]:'Melee';e.shieldCaster=f[caster];e.shieldSpellID=numeric(f[shield]);e.shieldName=f[shield+1];e.amount=positive(f[amount]);e.critical=f.length===22||f.length===19?flag(f[amount+2]):undefined;return e;
 }
 return null;
}
function totals(){return {damage:0,effectiveDamage:0,hits:0,crits:0,critDamage:0,normalDamage:0,misses:0,missTypes:{},absorbed:0,absorbEventsAmount:0,resisted:0,blocked:0,overkill:0,glancing:0,crushing:0,healing:0,effectiveHealing:0,overheal:0,casts:0,failedCasts:0,deaths:0,interrupts:0,dispels:0,minHit:null,maxHit:null};}
function add(t,e){
 if(e.type==='damage'){
  t.damage+=e.amount;t.effectiveDamage+=e.effective;t.hits++;t.absorbed+=e.absorbed;t.resisted+=e.resisted;t.blocked+=e.blocked;t.overkill+=e.overkill;t.glancing+=Number(e.glancing);t.crushing+=Number(e.crushing);
  t.minHit=t.minHit===null?e.amount:Math.min(t.minHit,e.amount);t.maxHit=t.maxHit===null?e.amount:Math.max(t.maxHit,e.amount);
  if(e.critical){t.crits++;t.critDamage+=e.amount;}else t.normalDamage+=e.amount;
 }else if(e.type==='miss'){t.misses++;t.missTypes[e.missType]=(t.missTypes[e.missType]||0)+1;t.absorbed+=e.absorbed;}
 else if(e.type==='absorb')t.absorbEventsAmount+=e.amount;
 else if(e.type==='healing'){t.healing+=e.amount;t.effectiveHealing+=e.effective;t.overheal+=e.overheal;}
 else if(e.type==='cast'){if(e.failed)t.failedCasts++;else t.casts++;}
 else if(e.type==='death')t.deaths++;
 else if(e.type==='utility') {if(e.event==='SPELL_INTERRUPT')t.interrupts++;else t.dispels++;}
}
function ranked(rows,total){return [...rows.values()].sort((a,b)=>b.damage-a.damage||b.effectiveHealing-a.effectiveHealing||(a.name||'').localeCompare(b.name||'')).map(row=>({...row,damageShare:total?row.damage/total*100:0,critPercent:row.hits?row.crits/row.hits*100:0,averageHit:row.hits?row.damage/row.hits:null}));}
function row(rows,key,meta,e){let r=rows.get(key);if(!r){r={...totals(),...meta};rows.set(key,r);}add(r,e);}
class CombatLog {
 constructor(addonDir,{now=Date.now,maxEvents=MAX_EVENTS,maxRead=MAX_READ}={}){
  this.directory=path.resolve(addonDir,'../..','Logs');this.now=now;this.maxEvents=maxEvents;this.maxRead=maxRead;this.events=[];this.offset=0;this.pending='';this.decoder=new StringDecoder('utf8');this.lastDiscovery=0;this.error=null;this.droppedUntil=0;this.unsupported=[];this.started=now();
 }
 reset(){this.events=[];this.unsupported=[];this.offset=0;this.pending='';this.decoder=new StringDecoder('utf8');this.version=undefined;this.build=undefined;this.started=this.now();this.droppedUntil=0;this.lastAt=null;this.firstAt=null;}
 read(){
  const now=this.now();
  try{
   if(!this.file||now-this.lastDiscovery>=2000){
    this.lastDiscovery=now;
    const files=fs.readdirSync(this.directory).filter(n=>/^WoWCombatLog.*\.txt$/i.test(n)).map(n=>{const file=path.join(this.directory,n);return {file,stat:fs.statSync(file)};}).filter(f=>f.stat.isFile()).sort((a,b)=>b.stat.mtimeMs-a.stat.mtimeMs);
    if(files[0]&&files[0].file!==this.file){this.file=files[0].file;this.identity=null;this.reset();}
   }
   if(!this.file)return this.status();
   const stat=fs.statSync(this.file),identity=stat.dev+':'+stat.ino;
   if(this.identity&&this.identity!==identity||stat.size<this.offset||stat.size===this.offset&&stat.mtimeMs!==this.mtime){this.reset();}
   this.identity=identity;this.mtime=stat.mtimeMs;this.size=stat.size;
   let fd;
   try{
    fd=fs.openSync(this.file,'r');
    if(this.offset===0){
     const head=Buffer.alloc(Math.min(stat.size,65536));fs.readSync(fd,head,0,head.length,0);
     for(const line of head.toString('utf8').split('\n')){const e=parseLine(line,now);if(e?.header){this.version=e.version;this.build=e.build;break;}}
     if(stat.size>this.maxRead){this.offset=stat.size-this.maxRead;this.skipPartial=true;this.droppedUntil=now-KEEP_MS;}
    }
    const length=Math.min(this.maxRead,stat.size-this.offset);
    if(length){const bytes=Buffer.alloc(length),count=fs.readSync(fd,bytes,0,length,this.offset);this.offset+=count;let text=this.pending+this.decoder.write(bytes.subarray(0,count));
     if(this.skipPartial){const end=text.indexOf('\n');if(end<0){this.pending='';return this.status();}text=text.slice(end+1);this.skipPartial=false;}
     const lines=text.split('\n');this.pending=lines.pop();if(this.pending.length>1000000){this.pending='';this.skipPartial=true;}
     for(const line of lines){const e=parseLine(line,now,this.version);if(!e)continue;if(e.header){this.version=e.version;this.build=e.build;continue;}if(e.at<now-KEEP_MS||e.at>now+5000)continue;
      this.lastAt=Math.max(this.lastAt||0,e.at);this.firstAt=this.firstAt===null?e.at:Math.min(this.firstAt,e.at);
      if(e.unsupported)this.unsupported.push(e.at);else this.events.push(e);
     }
    }
   }finally{if(fd!==undefined)fs.closeSync(fd);}
   const cutoff=now-KEEP_MS;this.events=this.events.filter(e=>e.at>=cutoff);this.unsupported=this.unsupported.filter(at=>at>=cutoff).slice(-MAX_EVENTS);
   if(this.events.length>this.maxEvents){this.droppedUntil=Math.max(this.droppedUntil,...this.events.slice(0,this.events.length-this.maxEvents).map(e=>e.at));this.events=this.events.slice(-this.maxEvents);}
   this.error=null;
  }catch(e){this.error=e.code==='ENOENT'?'No combat-log file found. Type /combatlog in WoW to enable recording.':'Combat-log file is not readable ('+(e.code||'read failure')+').';}
  return this.status();
 }
 status(){return {file:this.file?path.basename(this.file):null,readable:!!this.file&&!this.error,reason:this.error||(!this.file?'Type /combatlog in WoW to enable detailed recording.':null),lastEventAt:this.lastAt?new Date(this.lastAt).toISOString():null,lastEventAgeSeconds:this.lastAt?Math.max(0,(this.now()-this.lastAt)/1000):null,bufferedEvents:this.events.length,unsupportedEvents:this.unsupported.length,backlogBytes:Math.max(0,(this.size||0)-this.offset),formatVersion:this.version,build:this.build};}
 summary(snapshot,{seconds=30,includePets=true,from,to,limit=60,eventLimit=12,eventOffset=0,spellID,sourceGUID,targetGUID}={}){
  this.read();const now=this.now();to=to??now;from=from??to-seconds*1000;
  const player=snapshot?.player?.guid,pet=snapshot?.player?.petGUID||snapshot?.pet?.guid,status=this.status();
  if(!player)return {available:false,source:'Client combat-log file',reason:'Fresh character GUID is required.',recording:status};
  const relevant=this.events.filter(e=>e.at>=from&&e.at<=to),owners=new Map([[player,'player']]);if(pet)owners.set(pet,'pet');
  // Ownership edges come only from GUIDs and summons, never pet family or party flags.
  const edges=new Map();
  const link=(parent,child)=>{if(parent&&child&&parent!==child){const children=edges.get(parent)||[];children.push(child);edges.set(parent,children);}};
  for(const e of this.events){
   if(e.type==='ownership')link(e.source,e.dest);
   if((e.sourceFlags&0x100)&&!(e.sourceFlags&0x40)&&e.advancedGUID===e.source)link(e.ownerGUID,e.source);
  }
  const queue=[...owners.keys()];
  for(let i=0;i<queue.length;i++)for(const child of edges.get(queue[i])||[])if(!owners.has(child)){owners.set(child,child===pet?'pet':'guardian');queue.push(child);}
  const mine=guid=>owners.has(guid)&&(includePets||guid===player);
  const r={available:status.readable&&this.firstAt!==null,source:'Client combat-log file',windowMode:'eventTimeline',windowSeconds:(to-from)/1000,from:new Date(from).toISOString(),to:new Date(to).toISOString(),includePets,recording:status,
   coverageSeconds:Math.max(0,(to-Math.max(from,this.started,this.droppedUntil))/1000),recordingContinuityKnown:false,coverageComplete:false,coverageReason:'The file does not prove uninterrupted logging or completed disk flushing.',unsupportedEventsInWindow:this.unsupported.filter(at=>at>=from&&at<=to).length,bufferCoverageComplete:this.started<=from&&this.droppedUntil<=from&&this.offset>=this.size&&this.unsupported.every(at=>at<from||at>to),
   outgoing:totals(),incoming:totals(),incomingControlledUnits:totals(),abilities:[],incomingAbilities:[],attackers:[],sources:[],critEvents:[],incomingCritEvents:[],castSequence:[],events:[],
   capabilities:{abilityTotals:true,individualHits:true,crits:true,exactTimeWindow:true,weaponIdentity:false},
   limitations:'Recorded events only; the client may buffer file writes. Incoming totals cover your character; damage to controlled units is separate. Weapon IDs are not in damage events. Cast order shows correlation, not proven causes. Damage is the logged hit amount; effectiveDamage subtracts overkill. Absorb event amounts and damage-field absorbs overlap and must not be added together.'};
  if(!r.available){r.reason=status.reason||'The log has no recent supported combat events. Fight after enabling /combatlog.';return r;}
  const abilities=new Map(),incoming=new Map(),attackers=new Map(),sources=new Map();
  let matched=0,filtered=0,allCasts=0,crits=0,incomingCrits=0;
  for(const e of relevant){const outgoing=mine(e.source)&&e.event!=='DAMAGE_SPLIT',hurt=e.dest===player,controlled=e.dest!==player&&mine(e.dest);if(!outgoing&&!hurt&&!controlled)continue;matched++;
   const meta={spellID:e.spellID,name:e.name,school:e.school,periodic:e.periodic,hand:e.hand},key=[e.spellID,e.name,e.hand,e.periodic].join(':');
   if(outgoing){add(r.outgoing,e);row(abilities,key,meta,e);row(sources,e.source,{guid:e.source,name:e.sourceName,kind:owners.get(e.source)},e);}
   if(hurt){add(r.incoming,e);row(incoming,[e.source,key].join(':'),{...meta,attacker:e.sourceName||'Environment',attackerGUID:e.source},e);row(attackers,e.source,{guid:e.source,name:e.sourceName||'Environment'},e);}
   if(controlled)add(r.incomingControlledUnits,e);
   const detail={at:new Date(e.at).toISOString(),secondsIntoWindow:(e.at-from)/1000,event:e.event,type:e.type,source:e.sourceName,sourceGUID:e.source,target:e.destName,targetGUID:e.dest,sourceKind:owners.get(e.source),targetKind:owners.get(e.dest),spellID:e.spellID,name:e.name,hand:e.hand,school:e.school,damage:e.type==='damage'?e.amount:undefined,effectiveDamage:e.effective,rawAmount:e.rawAmount,critical:e.critical,blocked:e.blocked,resisted:e.resisted,absorbed:e.absorbed,overkill:e.overkill,glancing:e.glancing,crushing:e.crushing,missType:e.missType,healing:e.type==='healing'?e.amount:undefined,overheal:e.overheal,shieldSpellID:e.shieldSpellID,shieldName:e.shieldName,shieldAmount:e.type==='absorb'?e.amount:undefined,failureReason:e.failureReason};
   if((spellID===undefined||e.spellID===spellID)&&(!sourceGUID||e.source===sourceGUID)&&(!targetGUID||e.dest===targetGUID)){if(filtered++>=eventOffset&&r.events.length<eventLimit)r.events.push(detail);}
   if(e.type==='damage'&&e.critical){if(outgoing){crits++;if(r.critEvents.length<eventLimit)r.critEvents.push(detail);}if(hurt){incomingCrits++;if(r.incomingCritEvents.length<eventLimit)r.incomingCritEvents.push(detail);}}
   if(outgoing&&e.type==='cast'){allCasts++;if(r.castSequence.length<eventLimit)r.castSequence.push(detail);}
  }
  r.abilities=ranked(abilities,r.outgoing.damage);r.incomingAbilities=ranked(incoming,r.incoming.damage);r.attackers=ranked(attackers,r.incoming.damage);r.sources=ranked(sources,r.outgoing.damage);
  r.rowsTruncated=false;for(const k of ['abilities','incomingAbilities','attackers','sources']){if(r[k].length>limit){r.rowsTruncated=true;r[k]=r[k].slice(0,limit);}}
  r.filteredEventCount=filtered;r.eventOffset=eventOffset;r.nextEventOffset=filtered>eventOffset+r.events.length?eventOffset+r.events.length:null;r.eventsTruncated=filtered>r.events.length;r.matchedEvents=matched;r.critEventsTruncated=crits>r.critEvents.length;r.incomingCritEventsTruncated=incomingCrits>r.incomingCritEvents.length;r.castSequenceTruncated=allCasts>r.castSequence.length;
  r.outgoing.dps=r.outgoing.damage/Math.max(1,r.windowSeconds);r.incoming.damagePerSecond=r.incoming.damage/Math.max(1,r.windowSeconds);
  if(!matched){r.available=false;r.reason='No recorded events for this character in that window. Recording may be disabled, buffered, or the fight may be older. Do not treat missing data as zero.';}
  return r;
 }
}
module.exports={CombatLog,parseLine,csv,timestamp};
