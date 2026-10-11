'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { CharacterNotes, identity, PROMPT_BUDGET } = require('../bridge/character-notes');
test('notes survive restart, isolate characters and realms, replace keys and expire plans', () => {
 const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wow-notes-'));
 try {
  const file = path.join(dir, 'notes.json'), book = new CharacterNotes(file), now = Date.now();
  const who = identity({snapshot:{player:{name:'TestHunter',realm:'Beta',guid:'Player-1'}}});
  const alt = identity({snapshot:{player:{name:'TestHunter',realm:'Other',guid:'Player-1'}}});
  book.remember(who,{key:'playstyle',text:'Prefer solo questing.',kind:'preference'},now);
  book.remember(who,{key:'plan',text:'Collect two hides.',kind:'quest'},now);
  book.remember(who,{key:'plan',text:'Turn in the hides.',kind:'quest'},now+1);
  assert.equal(book.get(who,now+2).notes.length,2);
  assert.equal(book.get(alt,now+2).notes.length,0);
  const restored = new CharacterNotes(file);
  assert.equal(restored.get(who,now+2).notes.at(-1).text,'Turn in the hides.');
  assert.equal(restored.get(who,now+25*3600000).notes.length,1);
  assert.equal(fs.statSync(file).mode & 0o777,0o600);
  assert.equal(restored.forget(who,'playstyle').removed,true);
  assert.equal(restored.get(who,now+25*3600000).notes.length,0);
 } finally {fs.rmSync(dir,{recursive:true,force:true});}
});
test('notebook and injected context stay bounded; corrupt memory is never overwritten', () => {
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'wow-notes-'));
 try {
  const file=path.join(dir,'notes.json'),book=new CharacterNotes(file),who={key:'x',name:'TestHunter',realm:'Beta'};
  for(let i=0;i<16;i++)book.remember(who,{key:'fact'+i,text:'x'.repeat(180),kind:'fact'});
  assert.ok(book.prompt(who).length<=PROMPT_BUDGET);
  assert.throws(()=>book.remember(who,{key:'extra',text:'overflow'}),/full/);
  assert.throws(()=>book.remember(who,{key:'bad',text:'x'.repeat(181)}),/180/);
  fs.writeFileSync(file,'invalid');
  assert.throws(()=>new CharacterNotes(file),/could not be read/);
  assert.equal(fs.readFileSync(file,'utf8'),'invalid');
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});
