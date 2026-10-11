'use strict';
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const {spawn}=require('node:child_process');
const A=require('./agents');
const TOOLS=['get_status','get_game_state','capture_screen','set_map_route','clear_map_route','lookup_game_entity','search_forever_sources','read_forever_source','get_character_notes','remember_character_note','forget_character_note','get_gear_recommendations','get_dungeon_data','show_reference_cards','get_combat_summary','measure_combat','get_auction_prices','search_auction_house'];
const CODE=['bridge.js','agents.js','protocol.js','install-slots.js','capture_wayland.py','capture_x11.py','capture_mac.py','capture.ps1','pixel_codec.py','copilot-ipc.js','copilot-mcp.mjs','copilot-state.js','copilot-vision.js','character-notes.js','forever-sources.js','addon-catalog.js','reference-cards.js','prompt-context.js','setup-core.js','setup.mjs','setup.html','setup-ui.js'];
const ADDON=['Codec.lua','Inbox.lua','WoWAI.lua','Map.lua','Integrations.lua','References.lua','Combat.lua','Auctions.lua','Snapshot.lua','WoWAI.toc','Art/GuideIcon.tga','Art/GuideIcon.png'];
function dataDirectory(platform=process.platform,env=process.env,home=os.homedir()) {
 return platform==='win32'?path.join(env.LOCALAPPDATA||path.join(home,'AppData','Local'),'AdventurersGuide'):path.join(env.XDG_DATA_HOME||path.join(home,'.local','share'),'adventurers-guide');
}
function runtimeDirectory(source,data,isolated=false) {
 if(!isolated&&fs.existsSync(path.join(source,'bridge','config.json')))return source;
 if(!isolated)try {
  const registered=JSON.parse(fs.readFileSync(path.join(data,'installation.json'),'utf8')).runtime;
  if(typeof registered==='string'&&path.isAbsolute(registered)&&fs.existsSync(path.join(registered,'bridge','config.json')))return registered;
 }catch{}
 return path.join(data,'companion');
}
function gameDirectory(value) {
 let root=path.resolve(String(value||''));
 if(fs.existsSync(path.join(root,'WoWAI.toc')))root=path.resolve(root,'../../..');
 else if(path.basename(root).toLowerCase()==='addons')root=path.resolve(root,'../..');
 if(!fs.existsSync(path.join(root,'Interface','AddOns')))throw new Error('Choose the Forever game folder containing Interface/AddOns.');
 return root;
}
function accounts(root){return fs.readdirSync(path.join(root,'WTF','Account'),{withFileTypes:true}).filter(e=>e.isDirectory()&&!['SavedVariables','.','..'].includes(e.name)).map(e=>e.name);}
function configuration({wow,account,runtime,codex,node=process.execPath,backend,platform=process.platform,previous={}}) {
 wow=gameDirectory(wow);
 const list=accounts(wow);account=account||(list.length===1?list[0]:null);
 if(!account||!list.includes(account))throw new Error('Choose your game account from the list.');
 const addonDir=path.join(wow,'Interface','AddOns');
 const extra=['--ignore-user-config','-c','web_search="live"','-c','model_reasoning_effort="low"'];
 for(const feature of ['shell_tool','unified_exec','multi_agent','apps','hooks','remote_plugin'])extra.push('-c',`features.${feature}=false`);
 extra.push('-c','mcp_servers.wow_copilot.command='+JSON.stringify(node),'-c','mcp_servers.wow_copilot.args='+JSON.stringify([path.join(runtime,'bridge','copilot-mcp.mjs')]),'-c','mcp_servers.wow_copilot.enabled_tools='+JSON.stringify(TOOLS),'-c','mcp_servers.wow_copilot.default_tools_approval_mode="auto"');
 return {...previous,addonDir,savedVariablesFile:path.join(wow,'WTF','Account',account,'SavedVariables','WoWAI.lua'),inboxFile:path.join(addonDir,'WoWAI','Inbox.lua'),defaultCwd:path.join(runtime,'copilot'),tocInterface:'16001',slots:200,actMax:60,presenceMax:2000,
  capture:{enabled:true,backend,anchor:'bottom',processName:'WowB',cellPx:1,cellsPerRow:512,maxRows:1,intervalMs:100,python:'python3'},agent:'codex',agents:{codex:{...previous.agents?.codex,path:codex,model:previous.agents?.codex?.model||'gpt-6.1-sol',permissionMode:'default',networkAccess:false,extraArgs:extra}},gameContext:true,primerFile:'copilot/PRIMER.md',maxParallel:1,pollMs:750,progressWriteMs:4000,timeoutMs:300000,copilot:{...previous.copilot,dispatchMode:'codex',vision:platform==='win32'||['niri','x11'].includes(backend),effort:previous.copilot?.effort||'low'}};
}
function copyRuntime(source,runtime) {
 fs.mkdirSync(path.join(runtime,'bridge'),{recursive:true,mode:0o700});fs.mkdirSync(path.join(runtime,'copilot'),{recursive:true,mode:0o700});
 if(path.resolve(source)===path.resolve(runtime))return;
 for(const file of CODE)fs.copyFileSync(path.join(source,'bridge',file),path.join(runtime,'bridge',file));
 for(const file of ['AGENTS.md','PRIMER.md'])fs.copyFileSync(path.join(source,'copilot',file),path.join(runtime,'copilot',file));
 for(const file of ['package.json','package-lock.json'])fs.copyFileSync(path.join(source,file),path.join(runtime,file));
}
function copyAddon(source,addon) {
 if(path.resolve(source)===path.resolve(addon))return;
 for(const file of ADDON){const dest=path.join(addon,file);if(file==='Inbox.lua'&&fs.existsSync(dest))continue;fs.mkdirSync(path.dirname(dest),{recursive:true});fs.copyFileSync(path.join(source,file),dest);}
}
function run(command,args,options={}) {
 return new Promise((resolve,reject)=>{
  const child=spawn(command,args,{windowsHide:true,stdio:['ignore','pipe','pipe'],...options});let output='';
  const collect=b=>{output=(output+b.toString()).slice(-8000);options.onOutput?.(b.toString());};child.stdout.on('data',collect);child.stderr.on('data',collect);
  child.on('error',reject);child.on('close',code=>code===0?resolve(output):reject(new Error(output.trim()||`${path.basename(command)} exited with code ${code}`)));
 });
}
async function dependencies(runtime,onOutput) {
 if(!fs.existsSync(path.join(runtime,'node_modules','@modelcontextprotocol','sdk'))||!fs.existsSync(path.join(runtime,'node_modules','@openai','codex'))) {
  const candidates=[path.join(path.dirname(process.execPath),'node_modules','npm','bin','npm-cli.js'),path.resolve(path.dirname(process.execPath),'../lib/node_modules/npm/bin/npm-cli.js')];
  const cli=candidates.find(p=>fs.existsSync(p));
  if(cli)await run(process.execPath,[cli,'ci','--omit=dev','--no-audit','--no-fund'],{cwd:runtime,onOutput});
  else if(process.platform==='win32')await run('cmd.exe',['/d','/s','/c','npm ci --omit=dev --no-audit --no-fund'],{cwd:runtime,onOutput});
  else await run('npm',['ci','--omit=dev','--no-audit','--no-fund'],{cwd:runtime,onOutput});
 }
 const entry=path.join(runtime,'node_modules','@openai','codex','bin','codex.js');
 const shim=process.platform==='win32'?A.nativeNextTo(entry,A.AGENTS.codex).find(p=>fs.existsSync(p))||entry:entry;
 const command=A.resolveCommand('codex',{path:shim});
 if(!command.found)throw new Error('Codex did not install correctly. Retry setup.');
 return {...command,shim};
}
function systemCodex(){return A.resolveCommand('codex',{});}
function startupFiles({runtime,node=process.execPath,platform=process.platform,home=os.homedir(),env=process.env}) {
 if(platform==='win32') {
  const dir=path.join(env.APPDATA||path.join(home,'AppData','Roaming'),'Microsoft','Windows','Start Menu','Programs','Startup');
  const quote=value=>"'"+value.replace(/'/g,"''")+"'";
  const script=`Start-Process -FilePath ${quote(node)} -ArgumentList @(${quote('"'+path.join(runtime,'bridge','bridge.js')+'"')}) -WorkingDirectory ${quote(runtime)} -WindowStyle Hidden`;
  return {path:path.join(dir,'AdventurersGuide.cmd'),body:'@echo off\r\npowershell.exe -NoProfile -WindowStyle Hidden -EncodedCommand '+Buffer.from(script,'utf16le').toString('base64')+'\r\n'};
 }
 const quoted=value=>JSON.stringify(value).replace(/%/g,'%%');
 return {path:path.join(home,'.config','systemd','user','adventurers-guide.service'),body:`[Unit]\nDescription=Adventurer's Guide\nAfter=graphical-session.target\n\n[Service]\nType=simple\nWorkingDirectory=${runtime.replace(/%/g,'%%').replace(/\\/g,'\\x5c').replace(/\n/g,'\\x0a')}\nExecStart=${quoted(node)} ${quoted(path.join(runtime,'bridge','bridge.js'))}\nEnvironment=${quoted('PATH='+env.PATH)}\nRestart=on-failure\nRestartSec=5\nRestartPreventExitStatus=2\nUMask=0077\n\n[Install]\nWantedBy=graphical-session.target\n`};
}
async function setStartup(enabled,options) {
 const file=startupFiles(options);fs.mkdirSync(path.dirname(file.path),{recursive:true});
 if(enabled)fs.writeFileSync(file.path,file.body);else if(fs.existsSync(file.path))fs.unlinkSync(file.path);
 if(process.platform!=='win32'){
  await run('systemctl',['--user','daemon-reload']);
  if(enabled)await run('systemctl',['--user','enable','adventurers-guide.service']);
  else await run('systemctl',['--user','disable','adventurers-guide.service']).catch(()=>{});
 }
}
function launchBridge(runtime) {
 const log=fs.openSync(path.join(runtime,'companion.log'),'a',0o600);
  const child=spawn(process.execPath,[path.join(runtime,'bridge','bridge.js')],{cwd:runtime,env:{...process.env,PATH:path.dirname(process.execPath)+path.delimiter+(process.env.PATH||'')},detached:true,windowsHide:true,stdio:['ignore',log,log]});child.unref();fs.closeSync(log);return child;
}
function openBrowser(url) {
 let command,args;
 if(process.platform==='win32'){command='rundll32.exe';args=['url.dll,FileProtocolHandler',url];}
 else {command='xdg-open';args=[url];}
 const child=spawn(command,args,{detached:true,windowsHide:true,stdio:'ignore'});child.on('error',()=>{});child.unref();
}
module.exports={TOOLS,CODE,ADDON,dataDirectory,runtimeDirectory,gameDirectory,accounts,configuration,copyRuntime,copyAddon,run,dependencies,systemCodex,startupFiles,setStartup,launchBridge,openBrowser};
