import test from 'node:test';
import assert from 'node:assert/strict';
import { SnapshotAssembler, FrameAssembler } from '../bridge/copilot-state.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { serve, request, SOCKET } from '../bridge/copilot-ipc.js';
import fs from 'node:fs';
import os from 'node:os';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

test('snapshot reassembly handles out-of-order packets, duplication and session isolation', () => {
  const a = new SnapshotAssembler();
  const data = JSON.stringify({ schema: 1, target: { name: 'Éléphant 🐘' }, quests: [] });
  const parts = [data.slice(0, 15), data.slice(15)];
  const packet = (i, session = 'a') => ({ hello: true, session, text: `__COPILOT1__3:${i}:2:${parts[i - 1]}` });
  assert.equal(a.accept(packet(2)).partial, true);
  assert.equal(a.accept(packet(1, 'b')).partial, true);
  assert.deepEqual(a.accept(packet(1)).snapshot, JSON.parse(data));
  assert.equal(a.accept(packet(2)).duplicate, true);
  assert.equal(a.pending.size, 1);
  assert.equal(a.accept({ hello: false, text: packet(1).text }), null);
  assert.throws(() => a.accept({ hello: true, session: 'a', text: '__COPILOT1__9:1:999:x' }), /Invalid/);
});

test('real bridge receives a desktop request, validates reply identity and publishes addon Lua', async () => {
  assert.ok(!fs.existsSync(SOCKET), 'Use a separate WOW_COPILOT_SOCKET for tests');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wow-copilot-integration-'));
  const addon = path.join(dir, 'Interface/AddOns/WoWAI');
  fs.mkdirSync(addon, { recursive: true });
  fs.writeFileSync(path.join(addon, 'WoWAI.toc'), '## Interface: 16001\n');
  const saved = path.join(dir, 'SavedVariables.lua');
  const configFile = path.join(dir, 'config.json');
  const fakeCodex = path.join(dir, 'fake-codex.js');
  const pidFile = path.join(dir, 'agent.pid');
  const fakeCapture=path.join(dir,'fake-capture.js');
  const captureFile=path.join(dir,'capture.json');
  fs.writeFileSync(fakeCapture,`#!${process.execPath}\nconst fs=require('fs');const parent=process.ppid;setInterval(()=>{try{process.kill(parent,0)}catch{process.exit(0)}if(fs.existsSync(${JSON.stringify(captureFile)})){console.log(fs.readFileSync(${JSON.stringify(captureFile)},'utf8'));fs.unlinkSync(${JSON.stringify(captureFile)})}},25);\n`,{mode:0o700});
  fs.writeFileSync(fakeCodex, `#!${process.execPath}\nrequire('fs').writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); setInterval(() => {}, 1000);\n`, { mode: 0o700 });
  fs.writeFileSync(configFile, JSON.stringify({ addonDir: path.dirname(addon), inboxFile: path.join(addon, 'Inbox.lua'), savedVariablesFile: saved,
    defaultCwd: dir, capture: { enabled: true,backend:"niri",python:fakeCapture }, agent: 'codex', primerFile: '', slots: 2, pollMs: 50,
    agents: { codex: { path: fakeCodex } }, copilot: { dispatchMode: 'desktop', vision: false } }));
  fs.writeFileSync(path.join(dir, 'state.json'), JSON.stringify({ sessions: {}, handled: {}, snapshot: { session: 'testsession', token: 1, receivedAt: Date.now(),
    snapshot: { schema: 1, player: { name: 'TestHunter', realm: 'Beta', guid: 'Player-1' }, quests: [{ id: 77, title: 'Test quest' }], inventory: [], equipment: [] } } }));
  const child = spawn(process.execPath, [path.join(root, 'bridge/bridge.js')], { cwd: dir, env: { ...process.env, WOW_COPILOT_CONFIG: configFile, WOW_COPILOT_STATE_DIR: dir }, stdio: ['ignore', 'pipe', 'pipe'] });
  let logs = ''; child.stdout.on('data', d => { logs += d; }); child.stderr.on('data', d => { logs += d; });
  async function waitFor(fn) {
    const deadline = Date.now() + 6000;
    while (Date.now() < deadline) {
      try { if (await fn()) return; } catch { /* startup race */ }
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error('Bridge did not become ready: ' + logs);
  }
  try {
    await waitFor(() => request('status').then(s => s.running));
    fs.writeFileSync(saved, `WoWAIDB = { ["outbox"] = { ["id"] = 8, ["session"] = "testsession", ["chat"] = "testchat", ["text"] = "${Buffer.from('How do I finish this?').toString('hex')}" } }`);
    await waitFor(() => request('requests').then(r => r.requests.length === 1));
    assert.equal((await request('requests')).requests[0].text, 'How do I finish this?');
    await assert.rejects(request('reply', { session: 'testsession', chat: 'testchat', id: 7, text: 'Wrong request' }), /No matching/);
    assert.equal((await request('lookup', { type: 'quest', id: 77 })).matches[0].title, 'Test quest');
    await request('remember', { key: 'playstyle', text: 'Prefer solo quests.', kind: 'preference' });
    assert.equal((await request('notes')).notes[0].text, 'Prefer solo quests.');
    assert.equal(JSON.parse(fs.readFileSync(path.join(dir, 'character-notes.json'))).version, 1);
    await assert.rejects(request('remember', { characterKey: 'another-character', key: 'bad', text: 'wrong character' }), /Character changed/);
    assert.equal((await request('forget-note', { key: 'playstyle' })).removed, true);
    const characterKey=(await request('notes')).character.key;
    await assert.rejects(request('cards',{id:8,characterKey:'wrong',cards:[{kind:'item',id:11853}]}),/matching character/);
    await request('cards',{id:8,characterKey,cards:[{kind:'item',id:11853,name:'Rambling Boots',note:'Compare to your equipped boots.'}]});
    assert.match(fs.readFileSync(path.join(addon,'Inbox.lua'),'utf8'),/Rambling Boots/);
    await assert.rejects(request('cards',{id:8,characterKey,cards:[{kind:'dungeon',name:'Invented Dungeon'}]}),/Unknown installed/);
    await assert.rejects(request('cards',{id:999,characterKey,cards:[{kind:'item',id:11853}]}),/active request/);
    await request('map', { command: { op: 'set', layer: 'quest', title: 'Test', points: [{ m: 1431, x: 50, y: 50, label: 'Objective' }] } });
    assert.equal((await request('reply', { session: 'testsession', chat: 'testchat', id: 8, text: 'Collect three hides.\nTL;DR: Collect the hides.' })).delivered, true);
    const inbox = fs.readFileSync(path.join(addon, 'Inbox.lua'), 'utf8');
    assert.match(inbox, /Collect three hides/);
    assert.match(inbox, /Collect the hides/);
    assert.match(inbox, /Objective/);
    assert.equal((await request('requests')).requests.length, 0);
    await assert.rejects(request('cards',{id:8,characterKey,cards:[{kind:'item',id:11853}]}),/active request/);
    fs.mkdirSync(path.join(addon,'refresh'));
    fs.writeFileSync(path.join(addon,'refresh/0001.wav'),'');
    for(let i=2;i<=51;i++) fs.writeFileSync(path.join(addon,'refresh/'+String(i).padStart(4,'0')+'.wav'),'');
    const refresh=request('snapshot',{section:'spells',refresh:true});
    await waitFor(()=>fs.statSync(path.join(addon,'refresh/0001.wav')).size>0);
    const refreshInbox=fs.readFileSync(path.join(addon,'Inbox.lua'),'utf8');
    const token=Number(refreshInbox.match(/\["token"\]=(\d+)/)[1]);
    const snapshot={schema:1,section:'spells',requestToken:token,player:{name:'TestHunter',realm:'Beta',guid:'Player-1',xp:2200},game:{name:'World of Warcraft: Forever'},data:[{spellID:75,name:'Auto Shot'}]};
    const packet='__COPILOT1__2:1:1:'+JSON.stringify(snapshot);
    fs.writeFileSync(captureFile,JSON.stringify({id:0,text:['testsession','','0','','h','',packet].join('\x1f')}));
    const refreshed=await refresh;
    assert.equal(refreshed.refreshed.updated,true);
    assert.equal(refreshed.data[0].spellID,75);
    assert.equal((await request('snapshot',{section:'player'})).data.xp,2200);
    assert.equal((await request('snapshot',{section:'quests'})).data[0].id,77,'partial updates preserve other sections');
    // On-demand combat and auction requests keep their query parameters through
    // the real bridge, Lua inbox and selected-section snapshot merge.
    for (const [method,args,section,data] of [
      ['combat',{seconds:30,includePets:true},'combat',{available:true,outgoing:{damage:260},sources:[{kind:'pet',damage:60}]}],
      ['measure-combat',{seconds:10,includePets:true},'combat',{available:true,measurement:{durationSeconds:10,complete:true},outgoing:{damage:100}}],
      ['auctions',{itemIds:[11853],budgetCopper:500},'auctions',{prices:[{itemID:11853,scanPrice:400,scanAgeDays:1}]}],
      ['auction-search',{terms:['Light Leather'],itemIds:[2318]},'auctions',{search:{started:true},prices:[]}]
    ]) {
      const previous=JSON.parse(fs.readFileSync(path.join(dir,'state.json'))).refreshSignal;
      const pending=request(method,args);
      await waitFor(()=>JSON.parse(fs.readFileSync(path.join(dir,'state.json'))).refreshSignal!==previous);
      const requestData=JSON.parse(fs.readFileSync(path.join(dir,'state.json'))).refreshRequest;
      assert.equal(requestData.section,section);
      if(method==='measure-combat') assert.equal(requestData.measureSeconds,10);
      if(method==='auction-search') assert.deepEqual(requestData.searchTerms,['Light Leather']);
      const selected={schema:1,section,requestToken:requestData.token,player:{name:'TestHunter',realm:'Beta',guid:'Player-1'},game:{name:'World of Warcraft: Forever'},data};
      const sequence=10+previous;
      fs.writeFileSync(captureFile,JSON.stringify({id:0,text:['testsession','','0','','h','','__COPILOT1__'+sequence+':1:1:'+JSON.stringify(selected)].join('\x1f')}));
      const result=await pending;
      assert.equal(result.reason,undefined);
      if(section==='combat') assert.equal(result.outgoing.damage,data.outgoing.damage);
      else assert.deepEqual(result.prices,data.prices);
    }
    // Detailed log queries bypass the game's reply-cache latency entirely.
    const logsDir=path.join(dir,'Logs');fs.mkdirSync(logsDir);
    const logFile=path.join(logsDir,'WoWCombatLog.txt');
    function combatLine(amount,at=Date.now(),source='Player-1',target='Enemy'){
      const d=new Date(at),stamp=`${d.getUTCMonth()+1}/${d.getUTCDate()}/${d.getUTCFullYear()} ${d.getUTCHours()}:${String(d.getUTCMinutes()).padStart(2,'0')}:${String(d.getUTCSeconds()).padStart(2,'0')}.${String(d.getUTCMilliseconds()).padStart(3,'0')}0`;
      return `${stamp}  SPELL_DAMAGE,${source},"Actor",0x511,0x0,${target},"Target",0xa48,0x0,75,"Shot",0x1,${amount},-1,0x1,0,0,0,1,nil,nil,nil\n`;
    }
    fs.writeFileSync(logFile,combatLine(90,Date.now()-100));
    const before=Date.now(),logResult=await request('combat',{seconds:30});
    assert.equal(logResult.source,'Client combat-log file');assert.equal(logResult.outgoing.damage,90);assert.equal(logResult.outgoing.crits,1);
    assert.ok(Date.now()-before<1000,'reads local numbers without a game refresh');
    assert.equal((await request('snapshot',{section:'combat',refresh:true})).data.outgoing.damage,90);
    const fixed=request('measure-combat',{seconds:1});
    await new Promise(resolve=>setTimeout(resolve,200));fs.appendFileSync(logFile,combatLine(42));
    await new Promise(resolve=>setTimeout(resolve,1000));fs.appendFileSync(logFile,combatLine(999));
    const measured=await fixed;assert.equal(measured.outgoing.damage,42);assert.equal(measured.measurement.complete,true);assert.equal(measured.coverageComplete,false);
    await assert.rejects(request('combat',{eventLimit:1000}),/Invalid eventLimit/);
    await assert.rejects(request('combat',{windowEnd:'invalid'}),/Invalid combat window end/);
    await assert.rejects(request('combat',{seconds:301}),/Invalid combat/);
    await assert.rejects(request('measure-combat',{seconds:31}),/Invalid combat/);
    await assert.rejects(request('auctions',{itemIds:[-1]}),/Invalid auction/);
    await request('mode', { mode: 'codex' });
    assert.equal(JSON.parse(fs.readFileSync(path.join(dir, 'state.json'))).dispatchMode, 'codex');
    function submitControl(id, text) {
      fs.writeFileSync(saved, `WoWAIDB = { ["outbox"] = { ["id"] = ${id}, ["session"] = "testsession", ["chat"] = "testchat", ["text"] = "${Buffer.from(text).toString('hex')}" } }`);
    }
    const cancelled=request('measure-combat',{seconds:10}).then(()=>{throw new Error('Measurement must cancel');},e=>e);
    await new Promise(resolve=>setTimeout(resolve,100));
    submitControl(9, '__COPILOT_CONTROL__:off');
    await waitFor(() => request('status').then(s => s.enabled === false));
    assert.match((await cancelled).message,/Measurement cancelled/);
    await assert.rejects(request('snapshot', {}), /guide is closed/);
    await assert.rejects(request('screenshot', {}), /guide is closed/);
    submitControl(10, 'This must not start an agent');
    await waitFor(() => JSON.parse(fs.readFileSync(path.join(dir, 'state.json'))).handled.testsession?.[10]);
    assert.equal((await request('status')).automaticJobs, 0);
    submitControl(11, '__COPILOT_CONTROL__:on');
    await waitFor(() => request('status').then(s => s.enabled === true));
    // A question must start on its small fresh player update, even while a
    // previous full snapshot has only partially arrived.
    const started=Date.now();
    const wireRecord=(id,flags,text)=>['testsession','testchat',String(id),'',flags,'',text].join('\x1f');
    fs.writeFileSync(captureFile,JSON.stringify({id:12,text:[wireRecord(0,'h','__COPILOT1__100:1:2:{"schema":1,'),wireRecord(12,'snapshot=101','Where do I turn in my quest?')].join('\x1e')}));
    await new Promise(resolve=>setTimeout(resolve,200));
    assert.equal(fs.existsSync(pidFile),false,'waits for the requested fresh player generation');
    const fresh={schema:1,section:'player',game:{name:'World of Warcraft: Forever'},player:{guid:'Player-1',name:'TestHunter',realm:'Beta',xp:2250},data:{guid:'Player-1',xp:2250}};
    fs.writeFileSync(captureFile,JSON.stringify({id:0,text:wireRecord(0,'h','__COPILOT1__101:1:1:'+JSON.stringify(fresh))}));
    await waitFor(() => fs.existsSync(pidFile));
    assert.ok(Date.now()-started<2500,'starts promptly without waiting for the unrelated full generation');
    const pid = Number(fs.readFileSync(pidFile, 'utf8'));
    assert.equal((await request('status')).automaticJobs, 1);
    submitControl(13, '__COPILOT_CONTROL__:off');
    await waitFor(() => request('status').then(s => !s.enabled && s.automaticJobs === 0));
    await waitFor(() => { try { process.kill(pid, 0); return false; } catch { return true; } });
    assert.doesNotMatch(fs.readFileSync(path.join(addon, 'Inbox.lua'), 'utf8'), /exited with code/);
  } finally {
    child.kill('SIGTERM');
    if (child.exitCode === null && child.signalCode === null) await new Promise(resolve => child.once('close', resolve));
    fs.rmSync(SOCKET, { force: true });
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('real MCP stdio handshake, schemas, calls and tool errors over owner-only IPC', async () => {
  assert.ok(!fs.existsSync(SOCKET), 'Use a separate WOW_COPILOT_SOCKET for tests');
  const calls = [];
  const bridge = await serve(async (method, args) => {
    calls.push({ method, args });
    if (method === 'status') return { running: true };
    if (method === 'snapshot') return { ageSeconds: 1, data: { name: 'Example player' } };
    if (method === 'screenshot') throw new Error('WoW not visible');
    return { delivered: true };
  });
  const client = new Client({ name: 'copilot-test', version: '1.0.0' });
  const transport = new StdioClientTransport({ command: process.execPath, args: [path.join(root, 'bridge/copilot-mcp.mjs')], env: { ...process.env } });
  try {
    if(process.platform!=='win32')assert.equal(fs.statSync(SOCKET).mode & 0o777, 0o600);
    await client.connect(transport);
    const { tools } = await client.listTools();
    assert.equal(tools.length, 21);
    assert.ok(tools.find(t => t.name === 'get_game_state').annotations.readOnlyHint);
    const status = await client.callTool({ name: 'get_status', arguments: {} });
    assert.equal(JSON.parse(status.content[0].text).running, true);
    await client.callTool({ name: 'get_game_state', arguments: {} });
    assert.deepEqual(calls.at(-1), { method: 'snapshot', args: { section: 'player', refresh:true } });
    const bad = await client.callTool({ name: 'reply_to_request', arguments: { id: -1, text: 'x' } });
    assert.equal(bad.isError, true);
    const unavailable = await client.callTool({ name: 'capture_screen', arguments: {} });
    assert.equal(unavailable.isError, true);
    assert.match(unavailable.content[0].text, /not visible/);
    await client.callTool({ name: 'set_map_route', arguments: { layer: 'quest', title: 'Turn in', points: [{ m: 1431, x: 74, y: 46, label: 'Darkshire' }] } });
    assert.equal(calls.at(-1).args.command.points[0].kind, 'quest');
  } finally {
    await client.close();
    await new Promise(resolve => bridge.close(resolve));
    fs.rmSync(SOCKET, { force: true });
  }
});

test('compact wire fragments reassemble Unicode messages and reject oversized or mixed frames',()=>{
 const a=new FrameAssembler();
 const packet=(part,text,token=1)=>({id:7,text:`__WIRE2__${token}:7:${part}:2:${text}`});
 assert.equal(a.accept(packet(2,'🐘 end')),null);
 assert.equal(a.accept(packet(1,'hello ')).text,'hello 🐘 end');
 assert.equal(a.pending.size,0);
 assert.equal(a.accept(packet(2,'🐘 end')),null);
 assert.equal(a.accept(packet(1,'hello ')),null);
 assert.equal(a.accept(packet(1,'new ',2)),null);
 assert.equal(a.accept({id:7,text:'__WIRE2__3:7:1:99:x'}),null);
 assert.equal(a.accept({id:7,text:'__WIRE2__3:7:1:1:'+ 'x'.repeat(641)}),null);
 assert.equal(a.accept({id:7,text:'__WIRE2__garbage'}),null);
 assert.equal(a.accept({id:7,text:'legacy record'}).text,'legacy record');
});
