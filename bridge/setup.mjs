#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import Core from './setup-core.js';

const here=path.dirname(fileURLToPath(import.meta.url)),source=path.resolve(here,'..');
let sourceAddon=fs.existsSync(path.join(source,'../WoWAI.toc'))?path.resolve(source,'..'):path.join(source,'addon','WoWAI');
const data=process.env.GUIDE_SETUP_DATA||Core.dataDirectory();
const runtime=!process.env.GUIDE_SETUP_DATA&&fs.existsSync(path.join(source,'bridge','config.json'))?source:path.join(data,'companion');
const configFile=path.join(runtime,'bridge','config.json');
let previous={};try{previous=JSON.parse(fs.readFileSync(configFile,'utf8'));}catch{}
if(!fs.existsSync(path.join(sourceAddon,'WoWAI.toc'))&&previous.inboxFile)sourceAddon=path.dirname(previous.inboxFile);
let initial='';try{initial=Core.gameDirectory(sourceAddon);}catch{}
if(!initial&&previous.addonDir)try{initial=Core.gameDirectory(previous.addonDir);}catch{}
const state={signedIn:false,busy:false,loginBusy:false,ready:false,message:'Choose your game folder, then sign in.',wow:initial,accounts:[],backend:process.platform==='win32'?'windows':process.env.NIRI_SOCKET?'niri':'x11',platform:process.platform};
let codex,loginChild,preparation;
async function prepare(){
 if(preparation)return preparation;
 state.busy=true;state.message='Preparing the companion. The first setup downloads its dependencies.';
 preparation=(async()=>{Core.copyRuntime(source,runtime);codex=await Core.dependencies(runtime);return codex;})();
 try{return await preparation;}catch(e){preparation=null;throw e;}finally{state.busy=false;}
}
async function checkLogin(command){
 if(!command?.found)return false;
 try{await Core.run(command.file,[...command.args,'login','status']);state.signedIn=true;return true;}catch{state.signedIn=false;return false;}
}
function selectedAccount(wow,chosen){const options=Core.accounts(wow);return chosen||(options.length===1?options[0]:undefined);}
async function signIn(){
 if(loginChild)return;
 const command=await prepare();
 if(await checkLogin(command)){state.message='Codex is connected. Start your guide.';return;}
 state.loginBusy=true;state.message='Finish signing in in the OpenAI browser window.';state.loginUrl=null;
 loginChild=spawn(command.file,[...command.args,'login'],{cwd:runtime,windowsHide:true,stdio:['ignore','pipe','pipe']});
 const capture=data=>{
  const clean=data.toString().replace(/\x1b\[[0-9;]*[a-zA-Z]/g,'');
  const urls=clean.match(/https:\/\/[^\s]+/g)||[];
  for(const candidate of urls)try{const url=new URL(candidate);if(['auth.openai.com','chatgpt.com'].includes(url.hostname))state.loginUrl=url.href;}catch{}
 };
 loginChild.stdout.on('data',capture);loginChild.stderr.on('data',capture);
 loginChild.on('error',e=>{state.message='Sign-in could not start: '+e.message;state.loginBusy=false;loginChild=null;});
 loginChild.on('close',async code=>{loginChild=null;state.loginBusy=false;state.loginUrl=null;await checkLogin(command);state.message=state.signedIn?'Codex is connected. Start your guide.':`Sign-in did not finish${code?' (code '+code+')':''}. Click Sign in to retry.`;});
}
async function install(args){
 if(state.loginBusy)throw new Error('Finish signing in first.');
 const wow=Core.gameDirectory(args.wow),account=selectedAccount(wow,args.account);
 if(!account)throw new Error('Choose your game account.');
 const command=await prepare();if(!await checkLogin(command))throw new Error('Sign in to Codex first.');
 state.busy=true;state.message='Installing the guide and its reply cache…';
 try {
  const backend=process.platform==='win32'?'windows':args.backend;
  if(!['windows','niri','x11'].includes(backend))throw new Error('Choose a capture backend.');
  if(process.platform!=='win32'){
   await Core.run('python3',['--version']).catch(()=>{throw new Error('Install Python 3 with your Linux package manager, then retry.');});
   if(backend==='niri'){
    await Core.run('grim',['-h']).catch(()=>{throw new Error('Install grim with your Linux package manager, then retry.');});
    await Core.run('python3',['-c','import PIL']).catch(()=>{throw new Error('Install python3-pillow with your Linux package manager, then retry.');});
   }
  }
  const cfg=Core.configuration({wow,account,runtime,codex:command.shim,backend,previous});
  if(fs.existsSync(configFile))fs.copyFileSync(configFile,configFile+'.backup');
  Core.copyAddon(sourceAddon,path.join(cfg.addonDir,'WoWAI'));
  fs.writeFileSync(configFile,JSON.stringify(cfg,null,2)+'\n',{mode:0o600});previous=cfg;
  await Core.run(process.execPath,[path.join(runtime,'bridge','install-slots.js')],{cwd:runtime});
  let startupWarning='';
  try{await Core.setStartup(args.autostart===true,{runtime});}catch(e){startupWarning=' Automatic startup could not be enabled; use Start Guide when playing.';}
  const IPC=(await import(path.join(runtime,'bridge','copilot-ipc.js'))).default;
  let running=false;try{await IPC.request('status');running=true;}catch{}
  if(!running){const child=Core.launchBridge(runtime);child.on('error',e=>{state.ready=false;state.message='The companion could not start: '+e.message;});}
  // A ready UI must reflect a responding companion, not just a spawned process.
  for(let i=0;i<20;i++){
   try{await IPC.request('status');running=true;break;}catch{}
   await new Promise(resolve=>setTimeout(resolve,250));
  }
  if(!running)throw new Error('The companion did not start. Check companion.log in '+runtime);
  state.ready=true;state.message='Ready. Fully quit and reopen WoW, then click the minimap icon or type /ai.'+startupWarning;
  state.wow=wow;
 }finally{state.busy=false;}
}
if(initial)try{state.accounts=Core.accounts(initial);}catch{}
await checkLogin(Core.systemCodex());
if(state.signedIn)state.message='Codex is already connected. Start your guide.';
const token=crypto.randomBytes(24).toString('hex');let origin='';
const server=http.createServer(async(req,res)=>{
 res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');
 res.setHeader('Content-Security-Policy',"default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'");
 if(req.headers.host!==origin.replace('http://','')){res.writeHead(403);res.end();return;}
 const url=new URL(req.url,origin);
 const staticFiles={'/':'setup.html','/setup-ui.js':'setup-ui.js'};
 if(req.method==='GET'&&staticFiles[url.pathname]){
  res.setHeader('Content-Type',url.pathname.endsWith('.js')?'text/javascript':'text/html');res.end(fs.readFileSync(path.join(here,staticFiles[url.pathname])));return;
 }
 if(req.method==='GET'&&url.pathname==='/icon.png'){
  res.setHeader('Content-Type','image/png');res.end(fs.readFileSync(path.join(sourceAddon,'Art','GuideIcon.png')));return;
 }
 const supplied=Buffer.from(req.headers['x-guide-token']||'');
 if((req.headers.origin&&req.headers.origin!==origin)||supplied.length!==token.length||!crypto.timingSafeEqual(supplied,Buffer.from(token))){res.writeHead(403);res.end();return;}
 res.setHeader('Content-Type','application/json');
 try {
  if(req.method==='GET'&&url.pathname==='/status'){res.end(JSON.stringify(state));return;}
  if(req.method!=='POST')throw new Error('Unknown action');
  let body='';for await(const chunk of req){body+=chunk;if(body.length>16000)throw new Error('Request too large');}
  const args=JSON.parse(body||'{}');
  if(state.busy)throw new Error('Setup is still working.');
  if(url.pathname==='/game'){state.wow=Core.gameDirectory(args.wow);state.accounts=Core.accounts(state.wow);}
  else if(url.pathname==='/login')await signIn();
  else if(url.pathname==='/start')await install(args);
  else throw new Error('Unknown action');
  res.end(JSON.stringify(state));
 }catch(e){state.message=e.message;res.writeHead(400);res.end(JSON.stringify({error:e.message}));}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
origin='http://127.0.0.1:'+server.address().port;
const url=origin+'/#'+token;
console.log('Adventurer’s Guide setup: '+url);
if(!process.argv.includes('--no-browser'))Core.openBrowser(url);
