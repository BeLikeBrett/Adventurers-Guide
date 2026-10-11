'use strict';
const token=location.hash.slice(1);history.replaceState(null,'',location.pathname);
const $=id=>document.getElementById(id);
let pending=false,initialized=false,lastAccounts='';
async function request(route,args){const res=await fetch(route,{method:args?'POST':'GET',headers:{'x-guide-token':token,'Content-Type':'application/json'},...(args?{body:JSON.stringify(args)}:{})});const result=await res.json();if(!res.ok)throw new Error(result.error||'Setup failed');return result;}
function render(state){
 if(!initialized){$('wow').value=state.wow||'';$('backend').value=state.backend;initialized=true;}
 $('backend-section').hidden=state.platform==='win32';
 const accounts=JSON.stringify(state.accounts);
 if(accounts!==lastAccounts){const old=$('account').value;$('account').replaceChildren(...state.accounts.map(name=>{const o=document.createElement('option');o.textContent=name;o.value=name;return o;}));if(state.accounts.includes(old))$('account').value=old;lastAccounts=accounts;}
 $('account-section').hidden=state.accounts.length<2;
 $('login').textContent=state.signedIn?'Codex connected':state.loginBusy?'Signing in…':state.busy?'Preparing…':'Sign in to Codex';
 $('login').disabled=state.signedIn||state.busy||state.loginBusy||pending;
 $('start').textContent=state.ready?'Guide is ready':'Start my guide';
 $('start').disabled=!state.signedIn||state.busy||state.loginBusy||pending||state.ready;
 $('check').disabled=state.busy||pending;
 $('status').textContent=state.message;
 $('login-link').hidden=!state.loginUrl;if(state.loginUrl)$('login-link').href=state.loginUrl;
}
async function action(route,args){if(pending)return;pending=true;try{render(await request(route,args));}catch(e){$('status').textContent=e.message;}finally{pending=false;await refresh();}}
$('check').onclick=()=>action('/game',{wow:$('wow').value});
$('login').onclick=()=>action('/login',{});
$('start').onclick=()=>action('/start',{wow:$('wow').value,account:$('account').value,backend:$('backend').value,autostart:$('autostart').checked});
$('wow').addEventListener('keydown',e=>{if(e.key==='Enter'){$('check').click();e.preventDefault();}});
async function refresh(){try{render(await request('/status'));}catch(e){$('status').textContent='Setup closed. Run Start Guide again to reconnect.';}}
refresh();setInterval(refresh,1200);
