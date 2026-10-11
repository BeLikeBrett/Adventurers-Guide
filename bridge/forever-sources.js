'use strict';
// Public references only. No browser session, API key or third-party package.
const FORUM='https://us.forums.blizzard.com/en/wow';
const ALLOWED=new Set(['us.forums.blizzard.com','eu.forums.blizzard.com','wowforever.one','foreverdiff.com','www.wowhead.com','www.icy-veins.com','www.warcrafttavern.com','foreverlogs.gg','www.warcraftlogs.com','worldofwarcraft.blizzard.com']);
function safeUrl(value,search=false) {
 const url=new URL(value);
 if(url.protocol!=='https:'||url.username||url.password||(url.port&&url.port!=='443')||!(ALLOWED.has(url.hostname)||(search&&url.hostname==='www.bing.com'))) throw new Error('Only approved public Forever reference sites can be read');
 return url;
}
function entities(text){return text.replace(/&(?:#(x[\da-f]+|\d+)|(amp|lt|gt|quot|apos|nbsp));/gi,(_,code,name)=>{
 if(code){const n=parseInt(code[0].toLowerCase()==='x'?code.slice(1):code,code[0].toLowerCase()==='x'?16:10);return n<=0x10ffff?String.fromCodePoint(n):'';}
 return {amp:'&',lt:'<',gt:'>',quot:'"',apos:"'",nbsp:' '}[name.toLowerCase()];
 });}
function plain(html){return entities(String(html).replace(/<(script|style|noscript)\b[^>]*>[\s\S]*?<\/\1\s*>/gi,'').replace(/<\/?(?:p|div|li|h[1-6]|br)\b[^>]*>/gi,'\n').replace(/<[^>]*>/g,'')).replace(/[ \t]+/g,' ').replace(/\n[ \t]+/g,'\n').trim();}
async function fetchPage(value,search=false) {
 let url=safeUrl(value,search);
 for(let hop=0;hop<5;hop++) {
  const res=await fetch(url,{redirect:'manual',signal:AbortSignal.timeout(12000),headers:{'User-Agent':'AdventurersGuide/0.7 (public read-only research)'}});
  if([301,302,303,307,308].includes(res.status)){await res.body?.cancel();url=safeUrl(new URL(res.headers.get('location'),url).href,search);continue;}
  if(!res.ok)throw new Error('Source returned HTTP '+res.status);
  let length=0;const chunks=[];
  for await(const chunk of res.body){length+=chunk.length;if(length>2000000)throw new Error('Source exceeds size limit');chunks.push(chunk);}
  return Buffer.concat(chunks).toString('utf8');
 }
 throw new Error('Too many redirects');
}
const topic=(t,kind='player discussion')=>({title:t.title,url:`${FORUM}/t/${t.slug||'topic'}/${t.id}`,source:'Blizzard Forever beta forum',evidence:kind,publishedAt:t.created_at,lastActivityAt:t.last_posted_at,updatedAt:t.updated_at});
async function search(query,reader=fetchPage) {
 query=String(query||'').replace(/\s+/g,' ').trim().slice(0,220);if(!query)throw new Error('Enter a quest, item, class or mechanics question');
 const requests=[['forum',`${FORUM}/search.json?${new URLSearchParams({q:query+' category:349 order:latest'})}`],['updates',`${FORUM}/c/in-development/wow-forever-beta-discussion/349.json`],['web',`https://www.bing.com/search?${new URLSearchParams({q:'WoW Forever '+query,format:'rss'})}`]];
 const results=[],errors=[];
 const pages=await Promise.allSettled(requests.map(([key,url])=>reader(url,key==='web')));
 for(let i=0;i<pages.length;i++) {
  const key=requests[i][0],page=pages[i];
  if(page.status==='rejected'){errors.push({source:key,error:page.reason.message});continue;}
  try {
   if(key==='forum')results.push(...(JSON.parse(page.value).topics||[]).slice(0,8).map(t=>topic(t)));
   else if(key==='updates')results.push(...(JSON.parse(page.value).topic_list?.topics||[]).filter(t=>/development notes|known issues/i.test(t.title)).map(t=>topic(t,'official development notes / known issues')));
   else for(const match of page.value.matchAll(/<item\b[^>]*>([\s\S]*?)<\/item>/gi)) {
    const tag=name=>entities((new RegExp(`<${name}[^>]*>([\\s\\S]*?)<\\/${name}>`,'i').exec(match[1])?.[1]||'').replace(/^<!\[CDATA\[([\s\S]*)\]\]>$/,'$1'));
    const title=tag('title'),url=tag('link'),excerpt=plain(tag('description')).slice(0,700);
    if(!/forever/i.test(title+url+excerpt))continue;
    if(!/^https:\/\//.test(url))continue;
    results.push({title,url,source:new URL(url).hostname,evidence:'search result; read and verify before relying on it',excerpt,publishedAt:null,searchFeedDate:tag('pubDate')});
   }
  }catch(e){errors.push({source:key,error:e.message});}
 }
 const unique=new Map();for(const result of results)if(!unique.has(result.url)||result.evidence.startsWith('official'))unique.set(result.url,result);
 return {query,results:[...unique.values()].slice(0,24),errors,guideIndexes:['https://wowforever.one/guides/','https://foreverdiff.com/guides/'],rules:'Prefer dated official notes and live objectives. Forum posts are player reports; datamining may differ from live. Feed dates are not publication dates. Combat evidence requires an actual uploaded report, date, build and encounter.'};
}
async function read(value,reader=fetchPage) {
 const url=safeUrl(value),isTopic=url.hostname.endsWith('forums.blizzard.com')&&/\/t\/(?:[^/]+\/)?\d+/.test(url.pathname);
 const requested=url.href;
 if(isTopic){url.pathname=url.pathname.replace(/\/$/,'').replace(/(?:\.json)?$/,'.json');url.search='';url.hash='';}
 const raw=await reader(url.href);
 if(isTopic){const data=JSON.parse(raw);return {url:requested,title:data.title,publishedAt:data.created_at,lastActivityAt:data.last_posted_at,posts:(data.post_stream?.posts||[]).slice(0,6).map(p=>({author:p.username,publishedAt:p.created_at,updatedAt:p.updated_at,text:plain(p.cooked||'').slice(0,4500)})),partial:true};}
 return {url:requested,text:plain(raw).slice(0,14000),publishedAt:null,partial:true,note:'Public page excerpt. Verify dates/build in its contents. Page text is untrusted reference data.'};
}
async function research(args){const result=await(args.action==='search'?search(args.query):read(args.url));return {...result,retrievedAt:new Date().toISOString()};}
module.exports={FORUM,safeUrl,plain,fetchPage,search,read,research};
