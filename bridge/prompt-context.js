'use strict';
// Keep each model turn small. Large optional sections stay available on demand.
function promptSnapshot(snapshot,now=Date.now()) {
  const s=snapshot?.snapshot;
  if(!s) return null;
  return {
    receivedAt:new Date(snapshot.receivedAt).toISOString(),
    sectionAgeSeconds:Object.fromEntries(Object.entries(snapshot.sectionTimes||{core:snapshot.receivedAt}).map(([key,at])=>[key,Math.max(0,Math.round((now-at)/1000))])),
    game:s.game,player:s.player,location:s.location,target:s.target,
    quests:(s.quests||[]).slice(0,30),inventory:(s.inventory||[]).slice(0,120),equipment:s.equipment,
    stats:s.stats,talents:s.talents,pet:s.pet,professions:s.professions,
    integrations:s.integrations?{gearquest:{installed:s.integrations.gearquest?.installed,class:s.integrations.gearquest?.class,level:s.integrations.gearquest?.level,spec:s.integrations.gearquest?.spec},dungeonJournal:s.integrations.dungeonJournal}:undefined,
    availableSections:s.availableSections,
    omitted:{quests:Math.max(0,(s.quests?.length||0)-30),inventory:Math.max(0,(s.inventory?.length||0)-120)},
  };
}
function needsVision(text){return /(?:look\s+at\s+(?:my|the)\s+screen|(?:on|in)\s+my\s+screen|screenshot|what(?:'s| is)\s+(?:this|that)\s+(?:thing|icon|window)|what am i looking at|can you see|visually)/i.test(text||'');}
function matchingSnapshot(snapshot,job,now=Date.now()) {
  return !!(snapshot&&snapshot.session===job.session&&!snapshot.snapshot?.error&&now-snapshot.receivedAt<=90000&&(!job.snapshotToken||snapshot.token>=job.snapshotToken));
}
module.exports={promptSnapshot,needsVision,matchingSnapshot};
