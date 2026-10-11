'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {spawn}=require('node:child_process');
const Core=require('../bridge/setup-core'),Sources=require('../bridge/forever-sources'),{defaultSocket}=require('../bridge/copilot-ipc');

test('portable setup finds an addon installation, isolates user data, and preserves model choices',()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'guide-setup-'));
 try{
  const wow=path.join(dir,'Game with spaces'),addon=path.join(wow,'Interface','AddOns','WoWAI');
  fs.mkdirSync(addon,{recursive:true});fs.writeFileSync(path.join(addon,'WoWAI.toc'),'');
  fs.mkdirSync(path.join(wow,'WTF','Account','Account one'),{recursive:true});
  assert.equal(Core.gameDirectory(addon),wow);assert.equal(Core.gameDirectory(path.dirname(addon)),wow);
  const cfg=Core.configuration({wow,runtime:path.join(dir,'User data'),codex:'codex.cmd',backend:'windows',platform:'win32',previous:{agents:{codex:{model:'gpt-6-luna'}},copilot:{effort:'medium'}}});
  assert.equal(cfg.agents.codex.model,'gpt-6-luna');assert.equal(cfg.copilot.effort,'medium');
  assert.equal(cfg.capture.cellsPerRow,512);assert.equal(cfg.capture.maxRows,1);assert.equal(cfg.copilot.vision,true);
  assert.equal(cfg.savedVariablesFile,path.join(wow,'WTF','Account','Account one','SavedVariables','WoWAI.lua'));
  assert.ok(cfg.agents.codex.extraArgs.some(s=>s.includes('"get_combat_summary"')));
  assert.ok(cfg.agents.codex.extraArgs.includes('features.shell_tool=false'));
  assert.ok(defaultSocket('win32',dir,'Alice').startsWith('\\\\.\\pipe\\'));
  assert.notEqual(defaultSocket('win32',dir,'Alice'),defaultSocket('win32',dir,'Bob'));
  fs.mkdirSync(path.join(wow,'WTF','Account','Account two'));assert.throws(()=>Core.configuration({wow,runtime:dir,codex:'codex',backend:'x11'}),/Choose/);
  assert.throws(()=>Core.gameDirectory(path.join(dir,'missing')),/Forever game folder/);
  assert.ok(!Core.CODE.includes('config.json')&&!Core.CODE.includes('state.json'));
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('reopening setup reuses an existing companion and ignores stale registrations',()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'guide-install-'));
 try {
  const source=path.join(dir,'package'),data=path.join(dir,'data'),runtime=path.join(dir,'installed');
  fs.mkdirSync(data);fs.mkdirSync(path.join(runtime,'bridge'),{recursive:true});
  fs.writeFileSync(path.join(runtime,'bridge','config.json'),'{}');
  fs.writeFileSync(path.join(data,'installation.json'),JSON.stringify({runtime}));
  assert.equal(Core.runtimeDirectory(source,data),runtime);
  assert.equal(Core.runtimeDirectory(source,data,true),path.join(data,'companion'));
  fs.rmSync(runtime,{recursive:true});
  assert.equal(Core.runtimeDirectory(source,data),path.join(data,'companion'));
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('Windows startup quotes spaces and special characters inside an encoded PowerShell command',()=>{
 const file=Core.startupFiles({runtime:path.join('User folder','Guide'),node:'C:\\Program Files\\node.exe',platform:'win32',home:'C:\\User',env:{APPDATA:'C:\\User\\AppData'}});
 const encoded=file.body.match(/-EncodedCommand (\S+)/)[1],script=Buffer.from(encoded,'base64').toString('utf16le');
 assert.match(script,/Start-Process -FilePath 'C:\\Program Files\\node.exe'/);
 assert.ok(script.includes('"'+path.join('User folder','Guide','bridge','bridge.js')+'"'));
 assert.ok(script.includes('-WindowStyle Hidden'));
});

test('cross-platform sources reject private hosts and preserve dated official notes through partial failures',async()=>{
 for(const url of ['http://wowforever.one/','https://127.0.0.1/','https://user@wowforever.one/','https://wowforever.one:8080/','https://wowforever.one.evil.test/'])assert.throws(()=>Sources.safeUrl(url));
 const t={id:1,slug:'notes',title:'Development notes',created_at:'old',last_posted_at:'recent'};
 const result=await Sources.search('hunter',async url=>{if(url.includes('search.json'))return JSON.stringify({topics:[t]});if(url.includes('349.json'))return JSON.stringify({topic_list:{topics:[t]}});throw new Error('temporary outage');});
 assert.equal(result.results.length,1);assert.match(result.results[0].evidence,/^official/);assert.equal(result.results[0].lastActivityAt,'recent');assert.equal(result.errors[0].source,'web');
 const page=await Sources.read(Sources.FORUM+'/t/notes/1',async url=>{assert.match(url,/\.json$/);return JSON.stringify({post_stream:{posts:[{created_at:'a',updated_at:'b',cooked:'<p>Useful &amp; safe</p><script>bad</script>'}]}});});
 assert.equal(page.posts[0].text,'Useful & safe');assert.equal(page.posts[0].updatedAt,'b');
});

test('setup page requires its private launch token and rejects cross-origin actions',async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'guide-web-'));
 const child=spawn(process.execPath,[path.join(__dirname,'../bridge/setup.mjs'),'--no-browser'],{env:{...process.env,GUIDE_SETUP_DATA:dir},stdio:['ignore','pipe','pipe']});
 try{
  const url=await new Promise((resolve,reject)=>{let output='';const timer=setTimeout(()=>reject(new Error('Setup did not start')),15000);child.stdout.on('data',b=>{output+=b;const match=output.match(/http:\/\/127\.0\.0\.1:\d+\/#([a-f0-9]+)/);if(match){clearTimeout(timer);resolve(match[0]);}});child.on('error',reject);});
  const parsed=new URL(url),token=parsed.hash.slice(1),origin=parsed.origin;
  assert.equal((await fetch(origin+'/status')).status,403);
  assert.equal((await fetch(origin+'/status',{headers:{'x-guide-token':token,Origin:'https://evil.example'}})).status,403);
  assert.equal((await fetch(origin+'/status',{headers:{'x-guide-token':token}})).status,200);
  const page=await(await fetch(origin)).text();assert.match(page,/Sign in to Codex/);assert.ok(!page.includes(token));
  const response=await fetch(origin+'/game',{method:'POST',headers:{'x-guide-token':token,'Content-Type':'application/json'},body:JSON.stringify({wow:path.join(dir,'missing')})});
  assert.equal(response.status,400);assert.match((await response.json()).error,/Forever game folder/);
 }finally{child.kill();await new Promise(r=>child.once('close',r));fs.rmSync(dir,{recursive:true,force:true});}
});
