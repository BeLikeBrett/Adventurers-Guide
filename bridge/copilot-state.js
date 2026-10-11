'use strict';
// Multipart snapshots are acknowledged independently; incomplete generations
// never replace the last complete snapshot.
class SnapshotAssembler {
  constructor() { this.pending = new Map(); this.completed = new Set(); }
  accept(job) {
    const match = /^__COPILOT1__(\d+):(\d+):(\d+):([\s\S]*)$/.exec(job.text || '');
    if (!match || !job.hello) return null;
    const [, token, rawPart, rawTotal, data] = match;
    const part = Number(rawPart), total = Number(rawTotal);
    if (total < 1 || total > 128 || part < 1 || part > total || data.length > 2400) throw new Error('Invalid snapshot chunk');
    const key = `${job.session}:${token}`;
    if (this.completed.has(key)) return { duplicate: true };
    for (const [k, v] of this.pending) if (Date.now() - v.at > 120000) this.pending.delete(k);
    if (this.pending.size >= 8 && !this.pending.has(key)) this.pending.delete(this.pending.keys().next().value);
    let set = this.pending.get(key);
    if (!set) this.pending.set(key, set = { total, parts: new Map(), at: Date.now() });
    if (set.total !== total) throw new Error('Snapshot chunk count changed');
    set.parts.set(part, data);
    if (set.parts.size !== total) return { partial: true };
    const text = Array.from({ length: total }, (_, i) => set.parts.get(i + 1)).join('');
    if(Buffer.byteLength(text,'utf8')>64000) throw new Error('Snapshot too large');
    const snapshot = JSON.parse(text);
    if (snapshot.schema !== 1 || typeof snapshot !== 'object') throw new Error('Unsupported snapshot schema');
    this.pending.delete(key);
    this.completed.add(key);
    if (this.completed.size > 32) this.completed.delete(this.completed.values().next().value);
    return { snapshot, token: Number(token), session: job.session, receivedAt: Date.now() };
  }
}
class FrameAssembler {
  constructor(){this.pending=new Map();this.completed=new Set();}
  accept(frame){
    if(!frame.text?.startsWith('__WIRE2__')) return frame;
    const match=/^__WIRE2__([a-f0-9-]{1,64}):(\d+):(\d+):(\d+):([\s\S]*)$/.exec(frame.text);
    if(!match) return null;
    const [,token,id,partText,totalText,data]=match,part=Number(partText),total=Number(totalText);
    if(total<1||total>8||part<1||part>total||Buffer.byteLength(data,'utf8')>640) return null;
    for(const [k,v] of this.pending) if(Date.now()-v.at>15000) this.pending.delete(k);
    const key=token+':'+id;
    if(this.completed.has(key)) return null;
    if(this.pending.size>8&&!this.pending.has(key)) this.pending.delete(this.pending.keys().next().value);
    let set=this.pending.get(key);
    if(!set) this.pending.set(key,set={parts:new Map(),total,at:Date.now()});
    if(set.total!==total) return null;
    set.parts.set(part,data);
    if(set.parts.size!==total) return null;
    const text=Array.from({length:total},(_,i)=>set.parts.get(i+1)).join('');
    if(Buffer.byteLength(text,'utf8')>3200) return null;
    this.pending.delete(key);
    this.completed.add(key);
    if(this.completed.size>128) this.completed.delete(this.completed.values().next().value);
    return {id:Number(id),text};
  }
}
module.exports = { SnapshotAssembler, FrameAssembler };
