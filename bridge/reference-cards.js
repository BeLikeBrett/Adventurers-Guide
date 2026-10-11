'use strict';
function validateCards(cards) {
  if (!Array.isArray(cards) || cards.length < 1 || cards.length > 12) throw new Error('Choose 1–12 reference cards.');
  return cards.map(c => {
    if (!['item','quest','spell','dungeon'].includes(c.kind)) throw new Error('Unknown card kind');
    if (c.kind !== 'dungeon' && (!Number.isSafeInteger(c.id) || c.id <= 0)) throw new Error('Card requires a positive game ID.');
    if (c.kind === 'dungeon' && (!c.name || c.name.length > 100)) throw new Error('Dungeon card requires a name.');
    return { kind: c.kind, ...(c.id ? {id:c.id} : {}), name: String(c.name || '').slice(0,100), note:String(c.note || '').slice(0,220) };
  });
}
function luaValue(v) {
  if (v == null) return 'nil';
  if (typeof v === 'string') return '"'+v.replace(/\\/g,'\\\\').replace(/"/g,'\\"').replace(/\n/g,'\\n').replace(/\r/g,'\\r').replace(/[\x00-\x1f]/g,c=>'\\'+String(c.charCodeAt(0)).padStart(3,'0'))+'"';
  if (typeof v === 'number') { if (!Number.isFinite(v)) return 'nil';return String(v); }
  if (typeof v === 'boolean') return String(v);
  if (Array.isArray(v)) return '{'+v.map(luaValue).join(',')+'}';
  return '{'+Object.entries(v).map(([k,x])=>'['+luaValue(k)+']='+luaValue(x)).join(',')+'}';
}

function displayMessage(text) {
  const refs=[],seen=new Set();
  const add=(kind,id,name,payload)=>{const key=payload||kind+':'+id;if(!seen.has(key)){seen.add(key);refs.push({kind,id:Number(id),name,...(payload?{payload}:{})});}};
  for(const match of text.matchAll(/\|H((item|quest|spell):(\d+)[^|]*)\|h\[([^\]]*)\]\|h/g)) add(match[2],match[3],match[4],match[1]);
  const marker='\n\n--- Linked from the game ---\n', at=text.indexOf(marker);
  if(at>=0) {
    for(const match of text.slice(at).matchAll(/^\[([^\]]+)\] (item|quest|spell) (\d+)([^\n]*)/gm)) {
      const payload=/\{link=(item:\d+(?::[-\d]*)+)\}/.exec(match[4])?.[1];
      add(match[2],match[3],match[1],payload&&payload.startsWith('item:'+match[3]+':')?payload:undefined);
    }
    text=text.slice(0,at);
  }
  text=text.replace(/\|cn[^:]+:/g,'').replace(/\|c[0-9a-fA-F]{8}/g,'').replace(/\|r/g,'').replace(/\|H[^|]+\|h(.*?)\|h/g,'$1').replace(/\|T.*?\|t|\|A.*?\|a/g,'');
  return {text,references:refs};
}
module.exports={validateCards,luaValue,displayMessage};

