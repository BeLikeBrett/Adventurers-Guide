// Runs the real addon Lua (Codec.lua + WoWAI.lua) in a Lua VM with a stub
// WoW API (wow_stub.lua) and drives it through a session: login, hello, a sent
// message read back off the pixel strip, a reply delivered through a slot, the
// bridge's default folder and agent, a chat that picks another agent, a
// permission denial with Allow, and a restore.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const fengari = require('fengari');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;

const ADDON = path.join(__dirname, '..', 'addon', 'WoWAI');
const CELLS_PER_ROW = 512;
const {FrameAssembler}=require('../bridge/copilot-state');

const legacyFlags = flags => flags.split(';').filter(t => !t.startsWith('model=') && !t.startsWith('effort=')).join(';');

function newVM(saved) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const run = (code, arg) => {
    if (lauxlib.luaL_loadstring(L, to_luastring(code)) !== lua.LUA_OK) throw new Error('Lua load: ' + to_jsstring(lua.lua_tostring(L, -1)));
    let nargs = 0;
    if (arg !== undefined) { lua.lua_pushstring(L, to_luastring(arg)); nargs = 1; }
    if (lua.lua_pcall(L, nargs, 0, 0) !== lua.LUA_OK) throw new Error('Lua error: ' + to_jsstring(lua.lua_tostring(L, -1)));
  };
  // Evaluate an expression and bring it back as a string (or nil).
  const evaluate = (expr) => {
    run(`local v = (${expr}); if v == nil then RESULT = nil else RESULT = tostring(v) end`);
    lua.lua_getglobal(L, to_luastring('RESULT'));
    const isNil = lua.lua_isnil(L, -1);
    const s = isNil ? null : to_jsstring(lua.lua_tolstring(L, -1));
    lua.lua_pop(L, 1);
    return s;
  };
  const num = (expr) => Number(evaluate(expr));
  run(fs.readFileSync(path.join(__dirname, 'wow_stub.lua'), 'utf8'));
  if (saved) run(saved);
  for (const f of ['Codec.lua', 'Inbox.lua', 'WoWAI.lua', 'Integrations.lua', 'References.lua']) run(fs.readFileSync(path.join(ADDON, f), 'utf8'), 'WoWAI');
  return { run, evaluate, num, wire:new FrameAssembler() };
}

// Read the strip the addon drew, exactly like capture.ps1: 3 bits per cell,
// [C7 1A] [id] [len] [payload] [fletcher]. Returns { id, text } or null.
function readPixelFrame(vm) {
  if (vm.evaluate('WoWAIStrip and WoWAIStrip.shown') !== 'true') return null;
  vm.run(`
    local parts = {}
    for _, t in ipairs(WoWAIStrip.textures) do
      if t.shown and t.color then
        local c, r = math.floor(t.x), math.floor(-t.y)
        local v = math.floor(t.color[1]*15+.5)*256 + math.floor(t.color[2]*15+.5)*16 + math.floor(t.color[3]*15+.5)
        parts[#parts + 1] = (r * ${CELLS_PER_ROW} + c) .. ":" .. v
      end
    end
    RESULT = table.concat(parts, ",")`);
  const cells = [];
  for (const p of vm.evaluate('RESULT').split(',')) { const [i, v] = p.split(':').map(Number); cells[i] = v; }
  const bytes = [];
  let acc = 0, nbits = 0;
  for (let i = 16; i < cells.length; i++) {
    acc = (acc << 12) | (cells[i] || 0); nbits += 12;
    while (nbits >= 8) { bytes.push((acc >> (nbits - 8)) & 0xff); nbits -= 8; acc &= (1 << nbits) - 1; }
  }
  assert.equal(bytes[0], 0xc7); assert.equal(bytes[1], 0x1a);
  const id = bytes[2] * 256 + bytes[3];
  const len = bytes[4] * 256 + bytes[5];
  let s1 = 0, s2 = 0;
  for (let k = 2; k < 6 + len; k++) { s1 = (s1 + bytes[k]) % 255; s2 = (s2 + s1) % 255; }
  assert.equal(bytes[6 + len], s1, 'fletcher s1'); assert.equal(bytes[7 + len], s2, 'fletcher s2');
  return { id, text: Buffer.from(bytes.slice(6, 6 + len)).toString('utf8') };
}

function decodeStrip(vm) {
  let result,previousToken;
  for(let tick=0;tick<20;tick++) {
    const frame=readPixelFrame(vm);
    if(!frame) return result||null;
    const match=/^__WIRE2__([a-f0-9-]+):\d+:(\d+):(\d+):/.exec(frame.text);
    const accepted=vm.wire.accept(frame);
    if(accepted) result=accepted;
    if(result&&match&&previousToken===match[1]&&Number(match[2])===1) return result;
    if(match) previousToken=match[1];
    vm.run('STUB.tickers[1]()'); // advance only the transport, simulating capture
  }
  return result||null;
}

function stripRecords(vm) {
  const frame = decodeStrip(vm);
  if (!frame) return [];
  return frame.text.split('\x1E').map(r => {
    const p = r.split('\x1F');
    const withCtx = p[4].split(';').includes('c'); // a "c" flag means field 7 is the game context
    const rec = { session: p[0], chat: p[1], id: Number(p[2]), cwd: p[3], flags: p[4], name: p[5], text: p.slice(withCtx ? 7 : 6).join('\x1F') };
    if (withCtx) rec.ctx = p[6];
    return rec;
  });
}

// Make the next LoadAddOn deliver this slot data (a Lua table literal body).
function nextSlot(vm, luaBody) {
  vm.run(`STUB.onLoadAddOn = function(name) WoWAI_SlotData = ${luaBody} end`);
}

function login(vm) {
  vm.run('STUB.FireEvent("ADDON_LOADED", "WoWAI")');
  vm.run('STUB.FireEvent("PLAYER_LOGIN")');
}

// Let the bridge answer the login hello: its slot carries a fresh clock, which is
// what makes the addon consider itself connected (Send is gated on that).
function connect(vm) {
  vm.run('STUB.RunTimers()'); // C_Timer.After(3, SayHello)
  nextSlot(vm, '{ now = time(), cwd = "", replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()'); // hello poll 5 s later
  assert.equal(vm.evaluate('WoWAI.IsConnected()'), 'true', 'connected after the hello slot');
}

test('X cancels requests and hides both windows; /ai brings back the launcher', () => {
  const vm = newVM(); login(vm); connect(vm);
  vm.run('WoWAI.Send("help me quest"); WoWAICloseButton.scripts.OnClick()');
  assert.equal(vm.evaluate('WoWAIDB.settings.copilotEnabled'), 'false');
  assert.equal(vm.evaluate('WoWAIMini.shown'), 'false');
  assert.equal(vm.evaluate('WoWAIFrame.shown'), 'false');
  assert.equal(vm.evaluate('WoWAIDB.settings.shown'), 'false');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null);
  assert.equal(vm.evaluate('WoWAIDB.outbox'), null);
  assert.equal(stripRecords(vm).length, 1);
  assert.equal(stripRecords(vm)[0].text, '__COPILOT_CONTROL__:off');
  vm.run('WoWAI.Send("should not send")');
  assert.equal(stripRecords(vm).length, 1);
  vm.run('SlashCmdList.WOWAI("")');
  assert.equal(vm.evaluate('WoWAIDB.settings.copilotEnabled'), 'true');
  assert.ok(stripRecords(vm).some(r => r.text === '__COPILOT_CONTROL__:on'));
  assert.equal(vm.evaluate('WoWAIMini.shown'),'true');
  assert.equal(vm.evaluate('WoWAIFrame.shown'),'false');
  const restored = newVM('WoWAIDB = { settings = { copilotEnabled = false } }');
  login(restored); restored.run('WoWAI.SayHello()');
  assert.equal(stripRecords(restored)[0].text, '__COPILOT_CONTROL__:off');
});

test('addon loads, builds its UI and creates a first chat', () => {
  const vm = newVM();
  login(vm);
  assert.equal(vm.num('#WoWAIDB.chats'), 1);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].name'), 'Chat 1');
  assert.equal(vm.evaluate('WoWAIFrame ~= nil'), 'true');
  assert.equal(vm.evaluate('WoWAIMini ~= nil'), 'true');
  assert.equal(vm.num('#STUB.tickers'), 2);
  assert.equal(vm.evaluate('SlashCmdList.WOWAI ~= nil'), 'true');
  assert.deepEqual([1, 2, 3, 4, 5].map(i => vm.evaluate('SLASH_WOWAI' + i)), ['/wow-ai', '/wowai', '/wow-claude', '/ai', '/ask'], 'the old command name and the short forms are aliases');
  assert.equal(vm.evaluate('SlashCmdList.WOWAIASK'), null, '/ai is an alias of the one command, not a handler of its own');
});

test('hello goes out on the strip after login', () => {
  const vm = newVM();
  login(vm);
  vm.run('STUB.RunTimers()'); // C_Timer.After(3, SayHello)
  const recs = stripRecords(vm);
  assert.equal(recs.length, 1);
  assert.equal(recs[0].flags, 'h;c', 'a hello always carries the game context');
  assert.equal(recs[0].text, '');
  assert.equal(recs[0].session, vm.evaluate('WoWAIDB.session'));
});

test('outbound records replace field separators inside user text', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('WoWAI.Send("wire" .. string.char(30, 31) .. "safe")');
  const rec = stripRecords(vm).find(r => r.text === 'wire  safe');
  assert.ok(rec, 'the record keeps the full message as one wire field');
});

test('the game context describes the character and rides on the hello, then only when it changes or is turned off', () => {
  const vm = newVM();
  login(vm);
  vm.run('STUB.RunTimers()');
  const hello = stripRecords(vm)[0];
  assert.deepEqual(hello.ctx.split('\n'), [
    'Game: World of Warcraft: Forever (client 1.60.1.69913, interface 16001)',
    'Character: Testchar on Test Realm, level 23 Night Elf Hunter (Alliance), guild <Test Guild>',
    'Location: Duskwood - Darkshire',
    'Position: 45.2, 67.8 (map 1431)',
    'Money: 1g 23s 45c; XP: 1234/5000',
    'Talents: Beast Mastery 10 / Marksmanship 5 / Survival 0',
    'Professions: Skinning 75/75, First Aid 40/75',
  ]);
  // The bridge answers the hello: the context is now known to be on its side.
  nextSlot(vm, '{ now = time(), cwd = "", replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAI.IsConnected()'), 'true');
  vm.run('WoWAI.Send("hello world")');
  let rec = stripRecords(vm).find(r => r.text === 'hello world');
  assert.equal(legacyFlags(rec.flags), '', 'unchanged context is not repeated');
  assert.equal(rec.ctx, undefined);
  assert.equal(vm.evaluate('WoWAIDB.outbox.ctx'), null);
  // Moving to another zone changes it, so the next message (from another chat,
  // the first one is still waiting) carries the new version.
  vm.run('STUB.zone = "Elwynn Forest"; STUB.subzone = ""; STUB.posX = 0.1; WoWAI.NewChat("Second"); WoWAI.Send("where am I")');
  rec = stripRecords(vm).find(r => r.text === 'where am I');
  assert.equal(legacyFlags(rec.flags), 'c');
  assert.ok(rec.ctx.includes('Location: Elwynn Forest\n'), rec.ctx);
  assert.ok(rec.ctx.includes('Position: 10.0, 67.8 on Duskwood (map 1431)'), 'the map name shows when it differs from the zone');
  assert.equal(Buffer.from(vm.evaluate('WoWAIDB.outbox.ctx'), 'hex').toString('utf8'), rec.ctx, 'the reload path carries it too');
  // Turning it off sends an empty context at once (a hello), so the bridge drops what it had.
  vm.run('SlashCmdList.WOWAI("context off")');
  assert.equal(vm.evaluate('WoWAIDB.settings.context'), 'false');
  const off = stripRecords(vm).filter(r => r.flags === 'h;c');
  assert.equal(off.length, 1);
  assert.equal(off[0].ctx, '');
  assert.ok(vm.evaluate('WoWAIDB.chats[2].history[#WoWAIDB.chats[2].history].text').includes('Game context is OFF'));
  // Back on: another hello, with the context again.
  vm.run('SlashCmdList.WOWAI("context on")');
  const on = stripRecords(vm).filter(r => r.flags === 'h;c');
  assert.ok(on.some(r => r.ctx.includes('Character: Testchar')));
  assert.ok(vm.evaluate('WoWAIDB.chats[2].history[#WoWAIDB.chats[2].history].text').includes('Game context is ON'));
});

test('Shift-click remains native; explicitly attached links expand into name and tooltip', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  const link = '|cff1eff00|Hitem:2140:0:0:0:0:0:0:0:60:0:0|h[Fine Longsword]|h|r';
  vm.run(`STUB.tooltips["item:2140:0:0:0:0:0:0:0:60:0:0"] = { "Fine Longsword", { "Main Hand", "Sword" }, { "17 - 33 Damage", "Speed 2.70" }, "Requires Level 14" }`);
  // Without focus the link is left alone (shift-click keeps its normal meaning).
  vm.run(`WoWAIInput:SetText("is this good for me? "); WoWAIInput:ClearFocus(); ChatFrameUtil.InsertLink("${link}")`);
  assert.equal(vm.evaluate('WoWAIInput:GetText()'), 'is this good for me? ');
  // The client's own path (bags, spellbook, quest log all end here): ChatFrameUtil.InsertLink.
  vm.run(`WoWAIInput:SetFocus(); ChatFrameUtil.InsertLink("${link}")`);
  assert.equal(vm.evaluate('WoWAIInput:GetText()'), 'is this good for me? ', 'focused guide does not intercept native Shift-click');
  // The old global name is not hooked as well, so nothing is inserted twice.
  vm.run(`ChatEdit_InsertLink("${link}")`);
  assert.equal(vm.evaluate('WoWAIInput:GetText()'), 'is this good for me? ', 'legacy chat linking also stays native');
  vm.run(`WoWAIInput:SetText("is this good for me? ${link}")`);
  vm.run('WoWAI.SendFromInput()');
  const expected = [
    'is this good for me? [Fine Longsword]',
    '',
    '--- Linked from the game ---',
    '[Fine Longsword] item 2140 (Uncommon) {link=item:2140:0:0:0:0:0:0:0:60:0:0}',
    '  Fine Longsword',
    '  Main Hand  Sword',
    '  17 - 33 Damage  Speed 2.70',
    '  Requires Level 14',
  ].join('\n');
  const rec = stripRecords(vm).find(r => r.text.startsWith('is this good'));
  assert.equal(rec.text, expected);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].text'), 'is this good for me? [Fine Longsword]', 'transcript keeps clean prose while wire carries the tooltip');
  assert.equal(vm.num('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].references[1].id'),2140);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].name'), 'Is this good for me');
  // Bare links (no colour) and repeated links: one block each, tooltip or not.
  vm.run('RESULT = (WoWAI.ExpandLinks("x |Hspell:1978|h[Serpent Sting]|h y |Hspell:1978|h[Serpent Sting]|h"))');
  assert.equal(vm.evaluate('RESULT'), 'x [Serpent Sting] y [Serpent Sting]\n\n--- Linked from the game ---\n[Serpent Sting] spell 1978');
  vm.run('RESULT, COUNT = WoWAI.ExpandLinks("plain text | with a pipe")');
  assert.equal(vm.evaluate('RESULT'), 'plain text | with a pipe');
  assert.equal(vm.evaluate('COUNT'), '0');
});

test('deleting a chat tells the bridge to forget it, and a restore never brings it back', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('WoWAI.NewChat("Second")');
  assert.equal(vm.num('#WoWAIDB.chats'), 2);
  const gone = vm.evaluate('WoWAIDB.chats[2].id');
  vm.run(`WoWAI.DeleteChat("${gone}")`);
  assert.equal(vm.num('#WoWAIDB.chats'), 1);
  // A forget record for that chat is on the strip and remembered until acked.
  const rec = stripRecords(vm).find(r => r.flags === 'd');
  assert.ok(rec, 'forget record on the strip');
  assert.equal(rec.chat, gone);
  assert.equal(rec.text, '');
  assert.equal(vm.evaluate(`WoWAIDB.forget["${gone}"] ~= nil`), 'true');
  // A restore that still lists the chat is ignored for it.
  const token = vm.evaluate('WoWAIDB.session');
  nextSlot(vm, `{ now = time(), cwd = "", replies = {}, restore = { token = "${token}", chats = { { id = "${gone}", name = "Second", cwd = "", messages = { { role = "user", text = "old", id = 1, t = 1 } } } } } }`);
  vm.run('WoWAI.Connect(); STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.num('#WoWAIDB.chats'), 1, 'deleted chat not restored');
  // The bridge acks the forget record: it leaves the strip and the memory.
  const slot = String(rec.id).padStart(3, '0');
  vm.run(`STUB.sounds["Interface\\\\AddOns\\\\WoWAI\\\\ack\\\\${slot}.wav"] = true; STUB.Tick()`);
  assert.equal(vm.evaluate(`WoWAIDB.forget["${gone}"]`), null, 'forgotten once acked');
  assert.ok(!stripRecords(vm).find(r => r.flags === 'd'), 'forget record left the strip');
});

test('until the bridge answers, Connect replaces Send and a message stays in the box', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWAI.Toggle(true)');
  assert.equal(vm.evaluate('WoWAI.IsConnected()'), 'false');
  const texts = () => vm.evaluate('table.concat(STUB.texts, "|")');
  assert.ok(texts().includes('Click Connect to open the guide.'));
  // Sending while disconnected puts the text back in the box and starts a connect attempt.
  vm.run('WoWAIInput:SetText("fix the bug"); WoWAI.SendFromInput()');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null, 'nothing sent');
  assert.equal(vm.evaluate('WoWAIInput:GetText()'), 'fix the bug', 'message kept in the box');
  const hello = stripRecords(vm);
  assert.equal(hello.length, 1);
  assert.equal(hello[0].flags, 'h;c', 'a hello went out instead');
  assert.ok(texts().includes('Connecting...'));
  assert.ok(texts().includes('Opening the guide...'));
  // No answer within CONNECT_WAIT: the attempt is reported as failed, Connect is back.
  vm.run('STUB.now = STUB.now + 20; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAI.IsConnected()'), 'false');
  assert.ok(texts().includes('Guide unavailable. Click Connect to try again.'));
  assert.equal(vm.evaluate('WoWAIInput:GetText()'), 'fix the bug', 'message still in the box after a failed attempt');
  // Click Connect again; this time the bridge answers the hello poll. Nothing was
  // queued by that click, so the message waits for the user.
  vm.run('WoWAI.Connect()');
  nextSlot(vm, '{ now = time(), cwd = "C:\\\\proj", replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAI.IsConnected()'), 'true');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null, 'a plain Connect sends nothing by itself');
  vm.run('WoWAI.SendFromInput()');
  assert.ok(vm.num('WoWAIDB.chats[1].pendingId') >= 1, 'the kept message goes out once connected');
  assert.ok(stripRecords(vm).find(r => r.text === 'fix the bug'));
});

test('a message sent while disconnected goes out by itself once the bridge answers', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWAI.Toggle(true)');
  vm.run('WoWAIInput:SetText("fix the bug"); WoWAI.SendFromInput()');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null, 'nothing sent yet');
  // The bridge answers the hello poll: the queued message follows without a second click.
  nextSlot(vm, '{ now = time(), cwd = "C:\\\\proj", replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAI.IsConnected()'), 'true');
  assert.ok(vm.num('WoWAIDB.chats[1].pendingId') >= 1, 'queued message went out on connect');
  assert.ok(stripRecords(vm).find(r => r.text === 'fix the bug'));
  assert.equal(vm.evaluate('WoWAIInput:GetText()'), '', 'box cleared after the auto-send');
  // Only once: a later reconnect sends nothing.
  vm.run('WoWAI.Connect()');
  nextSlot(vm, '{ now = time(), cwd = "C:\\\\proj", replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(stripRecords(vm).filter(r => r.text === 'fix the bug').length, 1);
});

test('without the sound channel, the light stays green between idle slot polls', () => {
  // The stub has no ctl/valid.wav, so the login self-test disables the sound
  // channel: the addon is in "slot checks only" mode, like a client whose
  // PlaySoundFile reports every file as playable.
  const vm = newVM();
  login(vm);
  connect(vm);
  assert.equal(vm.evaluate('WoWAI.BridgeState()'), 'ok');
  // 90 s of silence used to mean "stale"; with no beats to hear that is normal.
  vm.run('STUB.now = STUB.now + 200; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAI.BridgeState()'), 'ok', 'still green after 200 s');
  assert.equal(vm.evaluate('WoWAI.IsConnected()'), 'true');
  // 10 minutes in, the idle poll spends a slot; the bridge's clock in it keeps the light green.
  vm.run('STUB.loadCount = 0; STUB.onLoadAddOn = function(name) STUB.loadCount = STUB.loadCount + 1; WoWAI_SlotData = { now = time(), cwd = "", replies = {} } end');
  vm.run('STUB.now = STUB.now + 410; STUB.Tick()');
  assert.equal(vm.num('STUB.loadCount'), 1, 'one idle poll');
  assert.equal(vm.evaluate('WoWAI.BridgeState()'), 'ok', 'green again after the idle poll');
  // A bridge that really is gone still shows: no slot answers, and the light drops.
  vm.run('STUB.onLoadAddOn = function(name) WoWAI_SlotData = nil end');
  vm.run('STUB.now = STUB.now + 800; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAI.BridgeState()'), 'stale');
  vm.run('STUB.now = STUB.now + 700; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAI.BridgeState()'), 'down');
});

test('the Folder... menu item (right-click a chat) opens a prompt that sets the chat folder like /wow-ai cd', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWAI.FolderPrompt()');
  assert.equal(vm.evaluate('STUB.popup.which'), 'WOWAI_FOLDER');
  assert.equal(vm.evaluate('STUB.popup.data.cwd'), '');
  // Accept the dialog the way the game would: an edit box holding the new path.
  vm.run(`
    local dialog = { editBox = { GetText = function() return "  ..\\\\realms " end } }
    StaticPopupDialogs.WOWAI_FOLDER.OnAccept(dialog, STUB.popup.data)`);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].cwd'), '..\\realms');
  assert.ok(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].text').includes('relative to'));
  vm.run('WoWAI.FolderPrompt()');
  assert.equal(vm.evaluate('STUB.popup.data.cwd'), '..\\realms', 'prompt is prefilled with the current folder');
  // A full path gets no "relative to" note; empty goes back to the default.
  vm.run('WoWAI.SetFolder("C:\\\\other")');
  assert.ok(!vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].text').includes('relative to'));
  vm.run('WoWAI.SetFolder("")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].cwd'), '');
});

test('a sent message is encoded on the strip with the chat folder, then a slot reply finishes it', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('SlashCmdList.WOWAI("cd realms")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].cwd'), 'realms');
  vm.run('WoWAI.Send("hello world")');
  const chatId = vm.evaluate('WoWAIDB.chats[1].id');
  const id = vm.num('WoWAIDB.chats[1].pendingId');
  assert.ok(id >= 1);
  const rec = stripRecords(vm).find(r => r.text === 'hello world');
  assert.ok(rec, 'message record on the strip');
  assert.equal(rec.chat, chatId);
  assert.equal(rec.id, id);
  assert.equal(rec.cwd, 'realms');
  assert.equal(legacyFlags(rec.flags), '');
  // The chat took its title from the first message.
  assert.equal(vm.evaluate('WoWAIDB.chats[1].name'), 'Hello world');

  nextSlot(vm, `{ now = time(), cwd = "C:\\\\proj", replies = { { chat = "${chatId}", id = ${id}, status = "done", text = "hi back", cwd = "x", session = "s" } } }`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()'); // first scheduled poll is 5 s after sending
  assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].role'), 'assistant');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].text'), 'hi back');
  assert.ok(vm.evaluate('table.concat(STUB.prints, "\\n")').includes('hi back'), 'reply echoed to the game chat');
  assert.equal(vm.evaluate('WoWAIStrip.shown'), 'false', 'strip cleared once nothing is pending');

  // The bridge's default folder arrived with the slot and is what "/wow-ai cd" reports.
  vm.run('SlashCmdList.WOWAI("cd")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].cwd'), '');
  assert.ok(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].text').includes('C:\\proj'));
});

test('a denied reply shows Allow, and Allow resends with the rules as flags', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('WoWAI.Send("search for it")');
  const chatId = vm.evaluate('WoWAIDB.chats[1].id');
  const id = vm.num('WoWAIDB.chats[1].pendingId');
  nextSlot(vm, `{ now = time(), cwd = "", replies = { { chat = "${chatId}", id = ${id}, status = "done", text = "need permission", denied = { "WebSearch", "Bash(cargo:*)" } } } }`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].denied[2]'), 'Bash(cargo:*)');
  vm.run(`WoWAI.Allow("${chatId}", { "WebSearch", "Bash(cargo:*)" })`);
  const rec = stripRecords(vm).find(r => r.flags.includes('allow='));
  assert.ok(rec, 'allow record on the strip');
  assert.equal(legacyFlags(rec.flags), 'allow=WebSearch,Bash(cargo:*)');
  assert.equal(rec.id, id + 1);
});

test('a chat can pick its agent: the strip says so, replies are labelled by their writer, unknown names are refused', () => {
  const vm = newVM();
  login(vm);
  // The hello slot carries the bridge's default agent and the ones it knows.
  vm.run('STUB.RunTimers()');
  const slot = replies => `{ now = time(), cwd = "", agent = "claude", agents = { "claude", "codex", "grok" }, replies = { ${replies || ''} } }`;
  nextSlot(vm, slot());
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAI.IsConnected()'), 'true');
  const texts = () => vm.evaluate('table.concat(STUB.texts, "|")');
  assert.ok(texts().includes("Adventurer's Guide"), 'the title stays a game guide');
  // Without an agent of its own the chat sends no agent flag, and the reply is labelled Claude.
  vm.run('WoWAI.Send("hello")');
  const chatId = vm.evaluate('WoWAIDB.chats[1].id');
  let rec = stripRecords(vm).find(r => r.text === 'hello');
  assert.equal(legacyFlags(rec.flags), '');
  assert.equal(vm.evaluate('WoWAIDB.outbox.agent'), null);
  const id = vm.num('WoWAIDB.chats[1].pendingId');
  nextSlot(vm, slot(`{ chat = "${chatId}", id = ${id}, status = "done", text = "hi", agent = "claude" }`));
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].role'), 'assistant');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].agent'), 'claude');
  assert.ok(vm.evaluate('table.concat(STUB.prints, "\\n")').includes('[Guide · '), 'the game chat echo names the agent');
  // Switch this chat to Codex: the next message carries agent=codex, on both transports.
  vm.run('SlashCmdList.WOWAI("agent Codex")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].agent'), 'codex');
  assert.ok(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].text').includes('agent set to Codex'));
  vm.run('WoWAI.Send("now with codex")');
  rec = stripRecords(vm).find(r => r.text === 'now with codex');
  assert.equal(legacyFlags(rec.flags), 'agent=codex');
  assert.equal(vm.evaluate('WoWAIDB.outbox.agent'), 'codex');
  assert.ok(!texts().includes('agent: Codex   mode: pixel'));
  const id2 = vm.num('WoWAIDB.chats[1].pendingId');
  nextSlot(vm, slot(`{ chat = "${chatId}", id = ${id2}, status = "done", text = "codex here", agent = "codex" }`));
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].agent'), 'codex');
  assert.ok(vm.evaluate('table.concat(STUB.prints, "\\n")').includes('[Guide · '));
  // Resend keeps the agent flag.
  vm.run('WoWAI.Send("again")');
  vm.run('WoWAI.Resend()');
  assert.equal(legacyFlags(stripRecords(vm).find(r => r.text === 'again').flags), 'agent=codex');
  vm.run('SlashCmdList.WOWAI("cancel")');
  // A name the bridge did not list is refused; "default" goes back to the bridge's.
  vm.run('SlashCmdList.WOWAI("agent gemini")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].agent'), 'codex');
  assert.ok(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].text').includes('Unknown agent "gemini"'));
  vm.run('SlashCmdList.WOWAI("agent default")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].agent'), '');
  assert.ok(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].text').includes('agent reset to the bridge\'s default: Claude'));
  // The Agent... menu item opens a prompt prefilled with the chat's agent.
  vm.run('WoWAI.SetAgent("grok"); WoWAI.AgentPrompt()');
  assert.equal(vm.evaluate('STUB.popup.which'), 'WOWAI_AGENT');
  assert.equal(vm.evaluate('STUB.popup.data.agent'), 'grok');
  vm.run(`
    local dialog = { editBox = { GetText = function() return " codex " end } }
    StaticPopupDialogs.WOWAI_AGENT.OnAccept(dialog, STUB.popup.data)`);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].agent'), 'codex');
  // A new chat inherits the agent, like the folder.
  vm.run('WoWAI.NewChat("Second")');
  assert.equal(vm.evaluate('WoWAIDB.chats[2].agent'), 'codex');
});

test('replies saved under the old "claude" role are read as assistant replies from Claude', () => {
  const vm = newVM();
  vm.run('WoWAIDB = { chats = { { id = "c1", name = "Old", cwd = "", history = { { role = "user", text = "q", id = 1, t = 1 }, { role = "claude", text = "a", id = 1, t = 2 } }, unread = 0, created = 1 } }, activeChat = "c1", settings = {} }');
  login(vm);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[2].role'), 'assistant');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[2].agent'), 'claude');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].agent'), '');
  // Before the bridge has said which agent it runs, the label falls back to "AI".
  vm.run('WoWAI.Toggle(true)');
  assert.ok(vm.evaluate('table.concat(STUB.texts, "|")').includes('|Guide|'), 'old replies use the game guide label');
});

test('free text that starts with a command word is sent as a message; exact commands still run', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  const sent = text => !!stripRecords(vm).find(r => r.text === text);
  const last = () => vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].text');
  // "delete the unused imports" is a message, not /wow-ai delete; "cancel" alone is the command.
  vm.run('SlashCmdList.WOWAI("delete the unused imports")');
  assert.equal(vm.num('#WoWAIDB.chats'), 1, 'no chat deleted');
  assert.ok(sent('delete the unused imports'));
  vm.run('SlashCmdList.WOWAI("cancel")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null, 'cancel ran as a command');
  // "help me with this macro" is a message; "help" alone prints the help.
  vm.run('SlashCmdList.WOWAI("help me with this macro")');
  assert.ok(sent('help me with this macro'));
  vm.run('SlashCmdList.WOWAI("cancel")');
  vm.run('SlashCmdList.WOWAI("help")');
  assert.ok(last().includes('/ai linkkey'));
  // One-word arguments keep their command; more words make it a message.
  vm.run('SlashCmdList.WOWAI("agent codex")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].agent'), 'codex');
  vm.run('SlashCmdList.WOWAI("agent smith says hi")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].agent'), 'codex');
  assert.ok(sent('agent smith says hi'));
  vm.run('SlashCmdList.WOWAI("cancel")');
  // Enumerated arguments: "context off" is the command, "context matters here" a message.
  vm.run('SlashCmdList.WOWAI("context off")');
  assert.equal(vm.evaluate('WoWAIDB.settings.context'), 'false');
  vm.run('SlashCmdList.WOWAI("context matters here")');
  assert.ok(sent('context matters here'));
  vm.run('SlashCmdList.WOWAI("cancel")');
  // "reset the counter" and "clear the cache" are messages; the transcript survives.
  vm.run('SlashCmdList.WOWAI("clear the cache")');
  assert.ok(sent('clear the cache'));
  assert.ok(vm.num('#WoWAIDB.chats[1].history') > 1, 'clear did not run');
  vm.run('SlashCmdList.WOWAI("cancel")');
  vm.run('SlashCmdList.WOWAI("reset the counter")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].resetNext'), null);
  assert.ok(sent('reset the counter'));
  vm.run('SlashCmdList.WOWAI("cancel")');
  // A chat can still be picked by number or name; "chat with me about it" is a message.
  vm.run('SlashCmdList.WOWAI("new Realms")');
  vm.run('SlashCmdList.WOWAI("chat 1")');
  assert.equal(vm.evaluate('WoWAIDB.activeChat'), vm.evaluate('WoWAIDB.chats[1].id'));
  vm.run('SlashCmdList.WOWAI("chat realms")');
  assert.equal(vm.evaluate('WoWAIDB.activeChat'), vm.evaluate('WoWAIDB.chats[2].id'));
  vm.run('SlashCmdList.WOWAI("chat with me about it")');
  assert.ok(sent('chat with me about it'));
  // /ai alone brings back the small journal tab.
  vm.run('WoWAI.Toggle(false); SlashCmdList.WOWAI("")');
  assert.equal(vm.evaluate('WoWAIFrame.shown'), 'false');
  assert.equal(vm.evaluate('WoWAIMini.shown'), 'true');
});

test('/wow-ai reset marks the next message as a new session', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('SlashCmdList.WOWAI("reset")');
  vm.run('WoWAI.Send("start over")');
  const rec = stripRecords(vm).find(r => r.text === 'start over');
  assert.equal(legacyFlags(rec.flags), 'n');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].resetNext'), null);
});

test('game chat echo: the summary by default, the first lines without one, the whole reply with "echo full"', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  assert.equal(vm.evaluate('WoWAIDB.settings.echo'), 'summary', 'summary echo is the default');
  const chatId = vm.evaluate('WoWAIDB.chats[1].id');
  const prints = () => vm.evaluate('table.concat(STUB.prints, "\\n")');
  const reply = (text, summary) => {
    vm.run('STUB.prints = {}');
    vm.run('WoWAI.Send("do it")');
    const id = vm.num('WoWAIDB.chats[1].pendingId');
    const sum = summary === undefined ? '' : `, summary = "${summary}"`;
    nextSlot(vm, `{ now = time(), cwd = "", replies = { { chat = "${chatId}", id = ${id}, status = "done", text = "${text}", agent = "claude"${sum} } } }`);
    vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
    assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null);
  };

  // With a summary only the summary is printed; the window keeps the whole reply.
  reply('Long line one\\nLong line two\\nLong line three\\n\\nTL;DR: Renamed foo.\\nTests pass.', 'Renamed foo.\\nTests pass.');
  let out = prints();
  assert.ok(out.includes('[Guide · ') && out.includes('Renamed foo.') && out.includes('Tests pass.'), 'summary lines printed: ' + out);
  assert.ok(!out.includes('Long line one'), 'the body stays out of the game chat');
  assert.ok(out.includes('[open]'), 'the open link is there');
  assert.ok(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].text').includes('Long line three'), 'the window has the full reply');

  // Without a summary: the first two lines, then a hint that there is more.
  reply('Line one\\nLine two\\nLine three\\nLine four');
  out = prints();
  assert.ok(out.includes('Line one') && out.includes('Line two'), 'first two lines: ' + out);
  assert.ok(!out.includes('Line three'), 'third line held back');
  assert.ok(out.includes('click [open]'), 'hint to open the window');

  // A short reply without a summary needs no hint.
  reply('Just this');
  out = prints();
  assert.ok(out.includes('Just this') && !out.includes('click [open] to read'), out);

  // "echo full" prints everything, as before.
  vm.run('SlashCmdList.WOWAI("echo full")');
  assert.equal(vm.evaluate('WoWAIDB.settings.echo'), 'full');
  reply('Line one\\nLine two\\nLine three\\n\\nTL;DR: Short.', 'Short.');
  out = prints();
  assert.ok(out.includes('Line one') && out.includes('Line three') && out.includes('TL;DR: Short.'), out);
  vm.run('SlashCmdList.WOWAI("echo summary")');
  assert.equal(vm.evaluate('WoWAIDB.settings.echo'), 'summary');
  vm.run('SlashCmdList.WOWAI("echo bogus")');
  assert.equal(vm.evaluate('WoWAIDB.settings.echo'), 'summary', 'an unknown mode is ignored');

  // An install that still had the old default saved moves to summary once; a mode picked on purpose stays.
  const vm2 = newVM();
  vm2.run('WoWAIDB = { settings = { echo = "full" } }');
  login(vm2);
  assert.equal(vm2.evaluate('WoWAIDB.settings.echo'), 'summary');
  const vm3 = newVM();
  vm3.run('WoWAIDB = { settings = { echo = "short" } }');
  login(vm3);
  assert.equal(vm3.evaluate('WoWAIDB.settings.echo'), 'short');
  const vm4 = newVM();
  vm4.run('WoWAIDB = { settings = { echo = "full", echoV2 = true } }');
  login(vm4);
  assert.equal(vm4.evaluate('WoWAIDB.settings.echo'), 'full');
});

test('a restore bundle addressed to this session adds the missing chats once', () => {
  const vm = newVM();
  login(vm);
  connect(vm);
  vm.run('WoWAI.Send("hi")');
  const chatId = vm.evaluate('WoWAIDB.chats[1].id');
  const id = vm.num('WoWAIDB.chats[1].pendingId');
  const token = vm.evaluate('WoWAIDB.session');
  const bundle = `restore = { token = "${token}", chats = { { id = "old1", name = "Old work", cwd = "C:\\\\old", messages = { { role = "user", id = 1, t = 1, text = "q" }, { role = "claude", id = 1, t = 2, text = "a" } } } } }`;
  nextSlot(vm, `{ now = time(), cwd = "", replies = { { chat = "${chatId}", id = ${id}, status = "done", text = "ok" } }, ${bundle} }`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.num('#WoWAIDB.chats'), 2);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].id'), 'old1');
  assert.equal(vm.num('#WoWAIDB.chats[1].history'), 2);
  // An older bridge's transcript says "claude"; it is read as an assistant reply from Claude.
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[2].role'), 'assistant');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[2].agent'), 'claude');
  assert.equal(vm.evaluate('WoWAIDB.restored'), 'true');
  // A second bundle with the same token is ignored.
  vm.run('WoWAI.Send("again")');
  const id2 = vm.num('WoWAIDB.chats[2].pendingId');
  nextSlot(vm, `{ now = time(), cwd = "", replies = { { chat = "${chatId}", id = ${id2}, status = "done", text = "ok" } }, ${bundle.replace('old1', 'old2')} }`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.num('#WoWAIDB.chats'), 2);
});

test('chat management commands: new, chat, rename, delete, clear, copy', () => {
  const vm = newVM();
  login(vm);
  vm.run('SlashCmdList.WOWAI("new Realms")');
  assert.equal(vm.num('#WoWAIDB.chats'), 2);
  assert.equal(vm.evaluate('WoWAIDB.chats[2].name'), 'Realms');
  assert.equal(vm.evaluate('WoWAIDB.activeChat'), vm.evaluate('WoWAIDB.chats[2].id'));
  vm.run('SlashCmdList.WOWAI("chat 1")');
  assert.equal(vm.evaluate('WoWAIDB.activeChat'), vm.evaluate('WoWAIDB.chats[1].id'));
  vm.run('SlashCmdList.WOWAI("rename Stuff")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].name'), 'Stuff');
  vm.run('SlashCmdList.WOWAI("help")');
  assert.ok(vm.evaluate('WoWAIDB.chats[1].history[1].text').includes('/ai linkkey'));
  vm.run('SlashCmdList.WOWAI("clear")');
  assert.equal(vm.num('#WoWAIDB.chats[1].history'), 0);
  vm.run('SlashCmdList.WOWAI("delete")');
  assert.equal(vm.num('#WoWAIDB.chats'), 1);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].name'), 'Realms');
  // The copy box builds with a proper backdrop (the stub fails on SetBackdrop(nil)).
  vm.run('WoWAI.ShowCopy("some reply")');
  assert.equal(vm.evaluate('WoWAICopy.shown'), 'true');
  assert.equal(vm.evaluate('WoWAICopyBox.text'), 'some reply');
});

test('chat rows: right-click opens a menu that renames or sets the folder of that chat, the trash can asks before deleting', () => {
  const vm = newVM();
  login(vm);
  vm.run('SlashCmdList.WOWAI("new Realms")');
  const first = vm.evaluate('WoWAIDB.chats[1].id');
  const second = vm.evaluate('WoWAIDB.chats[2].id');
  assert.equal(vm.evaluate('WoWAIDB.activeChat'), second);
  // The menu opens for the row's chat, not the active one, and toggles closed on a second open.
  vm.run(`WoWAI.ShowChatMenu("${first}", WoWAIFrame)`);
  assert.equal(vm.evaluate('WoWAIChatMenu.shown'), 'true');
  assert.equal(vm.evaluate('WoWAIChatMenu.chatId'), first);
  assert.equal(vm.evaluate('WoWAIChatMenu.title.text'), 'Chat 1');
  vm.run(`WoWAI.ShowChatMenu("${first}", WoWAIFrame)`);
  assert.equal(vm.evaluate('WoWAIChatMenu.shown'), 'false');
  // Rename and Folder prompts target the chat they were opened for.
  vm.run(`WoWAI.RenamePrompt("${first}")`);
  assert.equal(vm.evaluate('STUB.popup.which'), 'WOWAI_RENAME');
  assert.equal(vm.evaluate('STUB.popup.data.id'), first);
  vm.run(`
    local dialog = { editBox = { GetText = function() return "Old stuff" end } }
    StaticPopupDialogs.WOWAI_RENAME.OnAccept(dialog, STUB.popup.data)`);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].name'), 'Old stuff');
  assert.equal(vm.evaluate('WoWAIDB.chats[2].name'), 'Realms');
  vm.run(`WoWAI.FolderPrompt("${first}")`);
  assert.equal(vm.evaluate('STUB.popup.which'), 'WOWAI_FOLDER');
  assert.equal(vm.evaluate('STUB.popup.data.id'), first);
  // The X asks first: nothing happens until OK, then only that chat goes and the active one stays.
  vm.run(`WoWAI.ConfirmDelete("${first}")`);
  assert.equal(vm.evaluate('STUB.popup.which'), 'WOWAI_DELETE');
  assert.equal(vm.num('#WoWAIDB.chats'), 2);
  vm.run('StaticPopupDialogs.WOWAI_DELETE.OnAccept({}, STUB.popup.data)');
  assert.equal(vm.num('#WoWAIDB.chats'), 1);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].id'), second);
  assert.equal(vm.evaluate('WoWAIDB.activeChat'), second);
  // Deleting the last chat clears it instead of removing it.
  vm.run(`WoWAI.ConfirmDelete("${second}")`);
  vm.run('StaticPopupDialogs.WOWAI_DELETE.OnAccept({}, STUB.popup.data)');
  assert.equal(vm.num('#WoWAIDB.chats'), 1);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].name'), 'Chat 1');
});

test('minimize collapses to the mini bar and back; the mini bar X hides everything', () => {
  const vm = newVM();
  login(vm);
  vm.run('WoWAI.Toggle(true)');
  assert.equal(vm.evaluate('WoWAIFrame.shown'), 'true');
  vm.run('WoWAI.Minimize(true)');
  assert.equal(vm.evaluate('WoWAIFrame.shown'), 'false');
  assert.equal(vm.evaluate('WoWAIMini.shown'), 'true');
  assert.equal(vm.evaluate('WoWAIDB.settings.minimized'), 'true');
  vm.run('WoWAI.Minimize(false)');
  assert.equal(vm.evaluate('WoWAIFrame.shown'), 'true');
  assert.equal(vm.evaluate('WoWAIMini.shown'), 'false');
  vm.run('WoWAI.Toggle(false)');
  assert.equal(vm.evaluate('WoWAIFrame.shown'), 'false');
  assert.equal(vm.evaluate('WoWAIMini.shown'), 'false');
  assert.equal(vm.evaluate('WoWAIDB.settings.shown'), 'false');
});

test('reload mode writes the outbox for the bridge instead of drawing the strip', () => {
  const vm = newVM();
  login(vm);
  vm.run('SlashCmdList.WOWAI("mode reload")');
  vm.run('SlashCmdList.WOWAI("reset")');
  vm.run('WoWAI.Send("via reload", { "WebSearch", "Bash(git:*)" })');
  assert.equal(vm.evaluate('STUB.reloaded'), 'true');
  assert.equal(vm.evaluate('WoWAIDB.outbox.newSession'), 'true');
  assert.equal(vm.evaluate('WoWAIDB.outbox.text'), Buffer.from('via reload').toString('hex'));
  assert.equal(Buffer.from(vm.evaluate('WoWAIDB.outbox.allow'), 'hex').toString('utf8'), 'WebSearch\x1fBash(git:*)');
  assert.equal(decodeStrip(vm), null);
});


test('copilot snapshot collects objectives/items and streams Unicode chunks without spending message ids', () => {
  const vm = newVM(); login(vm); connect(vm);
  vm.run(fs.readFileSync(path.join(ADDON, 'Snapshot.lua'), 'utf8'), 'WoWAI');
  vm.run(`
    function UnitExists() return true end
    function UnitGUID(u) return u == "target" and "Creature-0-1-2-3-1234-00001" or "Player-1-00001" end
    C_QuestLog = {
      GetNumQuestLogEntries = function() return 1 end,
      GetSelectedQuest = function() return 77 end,
      GetInfo = function() return { questID = 77, title = "A quest", level = 23 } end,
      IsComplete = function() return false end,
      GetQuestObjectives = function() return { {text = "Collect 3 hides", numFulfilled = 1, numRequired = 3, finished = false} } end
    }
    C_Container = {
      GetContainerNumSlots = function(bag) return bag == 0 and 40 or 0 end,
      GetContainerItemInfo = function(bag, slot) return { itemID = 800 + slot, stackCount = 2, hyperlink = string.rep("É🐘", 8) } end
    }
  `);
  const original = JSON.parse(vm.evaluate('WoWAI.SnapshotJSON()'));
  assert.equal(original.target.npcID, 1234);
  assert.equal(original.quests[0].objectives[0].numFulfilled, 1);
  assert.equal(original.inventory.length, 40);
  assert.ok(Array.isArray(original.equipment));
  const seq = vm.num('WoWAIDB.lastSeq');
  vm.run('WoWAI.QueueSnapshot()');
  const { SnapshotAssembler } = require('../bridge/copilot-state');
  const a = new SnapshotAssembler();
  let complete;
  for (let step = 0; step < 30; step++) {
    const record = stripRecords(vm).find(r => r.text.startsWith('__COPILOT1__'));
    if (record) {
      assert.equal(record.id, 0);
      assert.ok(!record.text.includes('�'), 'each packet retains UTF-8 boundaries');
      const result = a.accept({ ...record, hello: true });
      if (result.snapshot) complete = result.snapshot;
    }
    vm.run('STUB.now = STUB.now + 2; STUB.RunTimers(); STUB.Tick()');
  }
  assert.deepEqual(complete, original);
  assert.equal(vm.num('WoWAIDB.lastSeq'), seq, 'snapshots do not consume chat sequence numbers');
});

test('copilot export skips secret API returns and nested fields without losing quest/inventory context', () => {
  const vm = newVM(); login(vm); connect(vm);
  vm.run(fs.readFileSync(path.join(ADDON, 'Snapshot.lua'), 'utf8'), 'WoWAI');
  vm.run(`
    function issecretvalue(v) return v == 987654 or v == "secret-name" end
    function canaccessvalue(v) return not issecretvalue(v) end
    function UnitExists() return true end
    function UnitHealth() return 987654 end
    function UnitHealthMax() return 987654 end
    function UnitName(u) return u == "target" and "secret-name" or "TestHunter" end
    C_QuestLog = {
      GetNumQuestLogEntries = function() return 1 end,
      GetInfo = function() return { questID = 77, title = "Known quest" } end,
      GetQuestObjectives = function() return { { text = "Collect hides", numFulfilled = 987654, numRequired = 3 } } end
    }
    C_Container = {
      GetContainerNumSlots = function(bag) return bag == 0 and 1 or 0 end,
      GetContainerItemInfo = function() return { itemID = 800, stackCount = 2, quality = 987654 } end
    }
    local original = math.abs
    math.abs = function(v) if v == 987654 then error("arithmetic on secret value") end return original(v) end
  `);
  const result = JSON.parse(vm.evaluate('WoWAI.SnapshotJSON()'));
  assert.equal(result.error, undefined);
  assert.equal(result.player.name, 'TestHunter');
  assert.equal(result.player.health, undefined);
  assert.equal(result.target.name, undefined);
  assert.equal(result.quests[0].title, 'Known quest');
  assert.equal(result.quests[0].objectives[0].numRequired, 3);
  assert.equal(result.quests[0].objectives[0].numFulfilled, undefined);
  assert.equal(result.inventory[0].id, 800);
  assert.equal(result.inventory[0].quality, undefined);
});


test('chat shares launcher corners, follows mini dragging and saves custom geometry', () => {
  const vm = newVM(); login(vm);
  vm.run(`
    UIParent.GetWidth = function() return 1920 end
    UIParent.GetHeight = function() return 1080 end
    WoWAIMini.GetLeft = function(self) return self.launcherLeft or 100 end
    WoWAIMini.GetTop = function() return 900 end
    WoWAIMini.GetPoint = function(self) return "TOPLEFT", UIParent, "TOPLEFT", self.x, self.y end
    WoWAIFrame.GetLeft = function(self) return self.x end
    WoWAIFrame.GetTop = function(self) return 1080 + self.y end
    WoWAI.Toggle(true)
  `);
  assert.equal(vm.num('WoWAIFrame.x'), 100, 'shares top-left corner');
  vm.run('WoWAI.Minimize(true); WoWAIMini.launcherLeft = 1600; WoWAI.Minimize(false)');
  assert.equal(vm.num('WoWAIFrame.x'), 1360, 'shares top-right corner near the right edge');
  vm.run('WoWAIFrame:SetSize(640, 600); WoWAIFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 900, -200); WoWAIFrame.scripts.OnDragStop(WoWAIFrame)');
  assert.equal(vm.num('WoWAIDB.settings.width'), 640);
  assert.equal(vm.num('WoWAIDB.settings.height'), 600);
  assert.equal(vm.num('WoWAIDB.settings.chatOffsetX'), -700);
  vm.run('WoWAI.Minimize(true); WoWAI.Minimize(false)');
  assert.equal(vm.num('WoWAIFrame.x'), 900);
  vm.run('WoWAI.Minimize(true); WoWAIMini.launcherLeft = 300; WoWAIMini:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 300, -180); WoWAIMini.scripts.OnDragStart(WoWAIMini); WoWAIMini.scripts.OnDragStop(WoWAIMini); WoWAI.Minimize(false)');
  assert.equal(vm.num('WoWAIFrame.x'), 300, 'dragging mini overrides the old expanded position');
  assert.equal(vm.num('WoWAIFrame.y'), -180);
  assert.equal(vm.num('WoWAIDB.settings.miniX'), 300);
  assert.equal(vm.num('WoWAIFrame.width'), 640, 'retains resized dimensions');
  vm.run('WoWAI.Minimize(true); WoWAIMini.GetTop = function() return 200 end; WoWAIMini.scripts.OnDragStop(WoWAIMini); WoWAI.Minimize(false)');
  assert.equal(vm.num('1080 + WoWAIFrame.y - WoWAIFrame.height'), 162, 'shares bottom corner near bottom edge');
  const next = newVM('WoWAIDB = {settings = {sideChatV1=true, width=640, height=600, miniPoint="TOPLEFT", miniRelPoint="TOPLEFT", miniX=1600, miniY=-180, chatOffsetX=-700, chatOffsetY=-20}}');
  login(next);
  assert.equal(next.num('WoWAIFrame.width'), 640);
  assert.equal(next.num('WoWAIFrame.height'), 600);
  assert.equal(next.num('WoWAIDB.settings.miniX'), 1600);
});

test('model and effort buttons save chat choices and send them through pixels and reload outbox', () => {
  const vm = newVM(); login(vm); connect(vm);
  vm.run('WoWAI.Toggle(true)');
  vm.run('for _, f in ipairs(STUB.frames) do if f.text == "Model: Sol 6.1" then f.scripts.OnClick(f); f.scripts.OnClick(f); break end end');
  vm.run('for _, f in ipairs(STUB.frames) do if f.text == "Effort: low" then f.scripts.OnClick(f); break end end');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].model'), 'gpt-6-luna');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].effort'), 'medium');
  vm.run('WoWAI.Send("quest help")');
  const rec = stripRecords(vm).find(r => r.text === 'quest help');
  const flags = require('../bridge/protocol').parseFlags(rec.flags);
  assert.equal(flags.model, 'gpt-6-luna'); assert.equal(flags.effort, 'medium');
  assert.equal(vm.evaluate('WoWAIDB.outbox.model'), 'gpt-6-luna');
  assert.equal(vm.evaluate('WoWAIDB.outbox.effort'), 'medium');
});

test('resizing respects screen bounds and independently changes width or height at UI scale', () => {
 const vm = newVM();login(vm);
 vm.run(`
  WoWAIFrame.GetLeft = function(self) return self.x or 120 end
  WoWAIFrame.GetTop = function(self) return 1080 + (self.y or -180) end
  WoWAIFrame.GetPoint = function(self) return "TOPLEFT", UIParent, "TOPLEFT", self.x, self.y end
  WoWAIMini.GetLeft = function() return 120 end
  WoWAIMini.GetTop = function() return 900 end
  UIParent.GetEffectiveScale = function() return 2 end
  GetCursorPosition = function() return CURSOR_X or 0, CURSOR_Y or 0 end
  WoWAIFrame:SetSize(640, 500)
  WoWAIFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 120, -180)
  WoWAI.BeginChatResize("width")
  CURSOR_X, CURSOR_Y = 100000, -100000
  WoWAI.UpdateChatResize()
 `);
 assert.equal(vm.num('WoWAIFrame.width'),1800);
 assert.equal(vm.num('WoWAIFrame.height'),500,'width resize leaves height alone');
 vm.run('WoWAI.EndChatResize(); WoWAI.BeginChatResize("height"); CURSOR_Y = -200000; WoWAI.UpdateChatResize()');
 assert.equal(vm.num('WoWAIFrame.height'),900);
 assert.equal(vm.num('WoWAIFrame.width'),1800,'height resize leaves width alone');
 vm.run('WoWAI.EndChatResize(); WoWAI.BeginChatResize("both"); CURSOR_X, CURSOR_Y = -200000, 200000; WoWAI.UpdateChatResize(); WoWAI.EndChatResize()');
 assert.equal(vm.num('WoWAIFrame.width'),480);
 assert.equal(vm.num('WoWAIFrame.height'),320);
 assert.equal(vm.num('WoWAIDB.settings.width'),480);
 assert.equal(vm.num('WoWAIDB.settings.height'),320);
 vm.run('WoWAIFrame:SetSize(3000, 2000); WoWAIFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -500, 900); WoWAI.ClampChatBounds()');
 assert.equal(vm.num('WoWAIFrame.width'),1920);
 assert.equal(vm.num('WoWAIFrame.height'),1080);
 assert.equal(vm.num('WoWAIFrame.x'),0);
 assert.equal(vm.num('WoWAIFrame.y'),0);
 vm.run('UIParent:SetSize(1280, 720); STUB.FireEvent("DISPLAY_SIZE_CHANGED")');
 assert.equal(vm.num('WoWAIFrame.width'),1280);
 assert.equal(vm.num('WoWAIFrame.height'),720);
 assert.equal(vm.num('WoWAIDB.settings.width'),1280);
});

test('hover shortcut attaches bag items and spell tooltips without focus; Attach uses recent inspected tooltip', () => {
 const vm=newVM();
 vm.run('STUB.bindings["BUTTON3"] = "TOGGLEAUTORUN"');
 login(vm);connect(vm);
 assert.equal(vm.evaluate('STUB.lastOverrideOwner.overrideBindings["ALT-CTRL-BUTTON3"]'),'CLICK WoWAIHoverAttachButton:LeftButton');
 assert.equal(vm.evaluate('STUB.bindings["BUTTON3"]'),'TOGGLEAUTORUN');
 assert.equal(vm.evaluate('WoWAIInput.hooks.OnKeyDown'),null,'attachment does not intercept typed letters');
 vm.run(`
  IsControlKeyDown = function() return true end
  IsAltKeyDown = function() return true end
  IsShiftKeyDown = function() return false end
  TooltipUtil = {
   GetDisplayedItem = function(t) if t.hoverItem then return "Fine Longsword", t.hoverItem, 2140 end end,
   GetDisplayedSpell = function(t) if t.hoverSpell then return "Serpent Sting", t.hoverSpell end end,
  }
  STUB.tooltips["item:2140"] = { "Fine Longsword", "Forever-specific item stat" }
  STUB.tooltips["spell:1978"] = { "Serpent Sting", "Forever-specific spell damage" }
  GameTooltip.hoverItem = "|cff1eff00|Hitem:2140|h[Fine Longsword]|h|r"
  GameTooltip:SetHyperlink("item:2140")
  GameTooltip:Show()
  WoWAIInput:SetText("Is this useful?")
  WoWAIInput:ClearFocus()
  WoWAIHoverAttachButton.scripts.OnClick(WoWAIHoverAttachButton, "LeftButton", false)
  assert(WoWAIInput:GetText() == "Is this useful?", "release edge must not attach")
  WoWAIHoverAttachButton.scripts.OnClick(WoWAIHoverAttachButton, "LeftButton", true)
 `);
 assert.ok(vm.evaluate('WoWAIInput:GetText()').includes('[Fine Longsword]'));
 assert.equal(vm.evaluate('WoWAIFrame.shown'),'true');
 vm.run('WoWAI.RememberHoveredTooltip(GameTooltip); GameTooltip:Hide(); WoWAIAttachButton.scripts.OnClick()');
 assert.equal((vm.evaluate('WoWAIInput:GetText()').match(/Fine Longsword/g)||[]).length,1,'same link is not duplicated');
 vm.run('WoWAI.SendFromInput()');
 const sent=stripRecords(vm).find(r=>r.text.startsWith('Is this useful?'));
 assert.ok(sent.text.includes('Forever-specific item stat'),'copies the hovered tooltip rather than losing custom context');
 vm.run(`
  SlashCmdList.WOWAI("cancel")
  WoWAIInput:SetText("Explain ")
  GameTooltip.hoverItem = nil
  GameTooltip.hoverSpell = 1978
  GameTooltip:SetHyperlink("spell:1978")
  GameTooltip:Show()
  WoWAI.AttachHovered(false)
  RESULT = (WoWAI.ExpandLinks(WoWAIInput:GetText()))
 `);
 assert.ok(vm.evaluate('RESULT').includes('[Serpent Sting] spell 1978'));
 assert.ok(vm.evaluate('RESULT').includes('Forever-specific spell damage'));
 vm.run('WoWAI.RememberHoveredTooltip(GameTooltip); GameTooltip:Hide(); STUB.now = STUB.now + 31; WoWAIInput:SetText("unchanged"); WoWAIAttachButton.scripts.OnClick()');
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'unchanged','stale inspected tooltip is not attached');
});

test('attachment binding respects existing keys, supports custom key and releases while off', () => {
 const vm=newVM();
 vm.run('STUB.bindings["ALT-CTRL-BUTTON3"] = "TOGGLEBACKPACK"');
 login(vm);
 assert.equal(vm.evaluate('STUB.bindings["ALT-CTRL-BUTTON3"]'),'TOGGLEBACKPACK');
 assert.equal(vm.evaluate('STUB.lastOverrideOwner'),null,'occupied default key is not stolen');
 vm.run('SlashCmdList.WOWAI("linkkey CTRL-ALT-J")');
 assert.equal(vm.evaluate('STUB.lastOverrideOwner.overrideBindings["ALT-CTRL-J"]'),'CLICK WoWAIHoverAttachButton:LeftButton');
 assert.equal(vm.evaluate('WoWAIDB.settings.linkKey'),'ALT-CTRL-J');
 vm.run('WoWAIMiniCloseButton.scripts.OnClick()');
 assert.equal(vm.evaluate('next(STUB.lastOverrideOwner.overrideBindings)'),null);
 vm.run('SlashCmdList.WOWAI("")');
 assert.ok(vm.evaluate('STUB.lastOverrideOwner.overrideBindings["ALT-CTRL-J"]'));
 vm.run('SlashCmdList.WOWAI("linkkey off")');
 assert.equal(vm.evaluate('WoWAIDB.settings.linkKey'),'');
 assert.equal(vm.evaluate('next(STUB.lastOverrideOwner.overrideBindings)'),null);
});

test('shortcut reads real bag slot and hovered quest row when tooltip helpers cannot identify them', () => {
 const vm=newVM();login(vm);connect(vm);
 vm.run(`
  Enum = { TooltipDataType = { Item = 0, Spell = 1 } }
  C_Container = { GetContainerItemLink = function(bag, slot) if bag == 0 and slot == 3 then return "|Hitem:800|h[Light Hide]|h" end end }
  local button = CreateFrame("Button", "TestBagSlot", UIParent)
  button.GetBagID = function() return 0 end
  button.GetID = function() return 3 end
  GetMouseFoci = function() return {button} end
  STUB.tooltips["item:800"] = { "Light Hide", "Crafting reagent" }
  GameTooltip:SetHyperlink("item:800"); GameTooltip:Show()
  WoWAIInput:SetText("bag ")
  WoWAI.AttachHovered(false)
  RESULT = (WoWAI.ExpandLinks(WoWAIInput:GetText()))
 `);
 assert.ok(vm.evaluate('RESULT').includes('[Light Hide] item 800'));
 assert.ok(vm.evaluate('RESULT').includes('Crafting reagent'));
 vm.run(`
  local row = CreateFrame("Button", "TestQuestRow", UIParent)
  row.info = { questID = 77 }
  GetMouseFoci = function() return { row } end
  C_QuestLog = {}
  C_QuestLog.GetTitleForQuestID = function(id) return "Beasts of Thunder Ridge" end
  C_QuestLog.GetQuestObjectives = function(id) return { { text = "Cured Light Hide: 0/2" } } end
  GameTooltip:Hide()
  WoWAIInput:SetText("quest ")
  WoWAI.AttachHovered(false)
  RESULT = (WoWAI.ExpandLinks(WoWAIInput:GetText()))
 `);
 assert.ok(vm.evaluate('RESULT').includes('[Beasts of Thunder Ridge] quest 77'));
 assert.ok(vm.evaluate('RESULT').includes('Cured Light Hide: 0/2'));
 assert.equal(vm.evaluate('WoWAIHoverAttachButton.scripts.OnClick ~= nil'),'true');
});

test('global mouse attachment reaches consumed UI clicks and deduplicates override dispatch', () => {
 const vm=newVM();login(vm);connect(vm);
 vm.run(`
  IsControlKeyDown = function() return true end
  IsAltKeyDown = function() return true end
  IsShiftKeyDown = function() return false end
  C_Container = { GetContainerItemLink = function() return "|Hitem:800|h[Light Hide]|h" end }
  local slot = CreateFrame("Button", "ConsumedBagSlot", UIParent)
  slot.GetBagID = function() return 0 end
  slot.GetID = function() return 3 end
  GetMouseFoci = function() return {slot} end
  STUB.tooltips["item:800"] = { "Light Hide", "Crafting reagent" }
  GameTooltip:SetHyperlink("item:800"); GameTooltip:Show()
  WoWAIInput:SetText("Check ")
  STUB.FireEvent("GLOBAL_MOUSE_DOWN", "RightButton")
  assert(WoWAIInput:GetText() == "Check ")
  STUB.FireEvent("GLOBAL_MOUSE_DOWN", "MiddleButton")
 `);
 assert.ok(vm.evaluate('WoWAIInput:GetText()').includes('[Light Hide]'));
 vm.run(`
  WoWAIInput:SetText("hold")
  WoWAIHoverAttachButton.scripts.OnClick(WoWAIHoverAttachButton, "LeftButton", true)
  STUB.FireEvent("GLOBAL_MOUSE_DOWN", "MiddleButton")
 `);
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'hold','same held press is processed only once');
 vm.run(`
  STUB.FireEvent("GLOBAL_MOUSE_UP", "MiddleButton")
  C_Container = nil
  local row = CreateFrame("Button", "ConsumedQuestRow", UIParent)
  row.info = { questID = 77 }
  GetMouseFoci = function() return {row} end
  C_QuestLog = { GetTitleForQuestID = function() return "Thunder Ridge" end, GetQuestObjectives = function() return {{text="Boars: 0/5"}} end }
  GameTooltip:Hide()
  WoWAIInput:SetText("Quest ")
  STUB.FireEvent("GLOBAL_MOUSE_DOWN", "MiddleButton")
  RESULT = WoWAI.ExpandLinks(WoWAIInput:GetText())
 `);
 assert.ok(vm.evaluate('RESULT').includes('Boars: 0/5'));
 vm.run(`
  STUB.FireEvent("GLOBAL_MOUSE_UP", "MiddleButton")
  GetMouseFoci = function() return {} end
  TooltipUtil = { GetDisplayedSpell = function() return "Serpent Sting", 1978 end }
  STUB.tooltips["spell:1978"] = { "Serpent Sting", "Poison damage" }
  GameTooltip:SetHyperlink("spell:1978"); GameTooltip:Show()
  WoWAIInput:SetText("Spell ")
  STUB.FireEvent("GLOBAL_MOUSE_DOWN", "MiddleButton")
 `);
 assert.ok(vm.evaluate('WoWAIInput:GetText()').includes('[Serpent Sting]'));
 vm.run(`
  STUB.FireEvent("GLOBAL_MOUSE_UP", "MiddleButton")
  IsAltKeyDown = function() return false end
  WoWAIInput:SetText("plain")
  STUB.FireEvent("GLOBAL_MOUSE_DOWN", "MiddleButton")
 `);
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'plain','plain or partially modified mouse clicks do nothing');
 vm.run(`
  IsAltKeyDown = function() return true end
  WoWAIMiniCloseButton.scripts.OnClick()
  STUB.FireEvent("GLOBAL_MOUSE_DOWN", "MiddleButton")
 `);
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'plain','off disables global mouse attachment');
});

test('tracker headers, nested objective rows and non-interactive objective text attach their owning quest', () => {
 const vm=newVM();login(vm);connect(vm);
 vm.run(`
  C_QuestLog = { GetTitleForQuestID = function(id) return "Tracker quest " .. id end,
   GetQuestObjectives = function(id) return {{text="Cured Light Hide: 0/2"}} end }
  QuestObjectiveTracker = CreateFrame("Frame", "QuestObjectiveTracker", UIParent)
  QuestObjectiveTracker.GetDebugReportInfo = function(self, block) return {questID=block.id} end
  local block = CreateFrame("Frame", "TrackedBlock", QuestObjectiveTracker)
  block.id = 989; block.parentModule = QuestObjectiveTracker
  local header = CreateFrame("Button", "TrackedHeader", block)
  block.HeaderText = header
  local line = CreateFrame("Frame", "TrackedObjective", UIParent)
  line.parentBlock = block
  local text = CreateFrame("Frame", "TrackedObjectiveText", line)
  for _, focus in ipairs({ header, text }) do
   GetMouseFoci = function() return {focus} end
   WoWAIInput:SetText("")
   WoWAI.AttachHovered(false)
   assert(WoWAIInput:GetText():find("Tracker quest 989",1,true))
  end
  block.usedLines = { [1] = line }
  line.Text = text
  text.IsMouseOver = function() return true end
  QuestObjectiveTracker.EnumerateActiveBlocks = function(self, fn) fn(block) end
  GetMouseFoci = function() return {QuestObjectiveTracker} end
  GameTooltip:Hide()
  WoWAIInput:SetText("text ")
  WoWAI.AttachHovered(false)
  RESULT = WoWAI.ExpandLinks(WoWAIInput:GetText())
 `);
 assert.ok(vm.evaluate('RESULT').includes('[Tracker quest 989] quest 989'));
 assert.ok(vm.evaluate('RESULT').includes('Cured Light Hide: 0/2'));
 vm.run(`
  TrackedBlock:Hide()
  WoWAIInput:SetText("hidden")
  WoWAI.AttachHovered(false)
 `);
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'hidden','hidden tracker blocks are not attached by hit detection');
});

test('pointed spellbook, action-bar and equipment entities win over a stale tooltip', () => {
 const vm=newVM();login(vm);connect(vm);
 vm.run(`
  TooltipUtil = { GetDisplayedItem = function() return "Wrong item", "|Hitem:999|h[Wrong item]|h",999 end }
  GameTooltip:Show()
  C_Spell = { GetSpellLink=function(id) return "|Hspell:"..id.."|h[Spell "..id.."]|h" end }
  GetActionInfo = function(slot) return "spell", 1978 end
  GetInventoryItemLink = function(unit,slot) if unit=="player" and slot==16 then return "|Hitem:2140|h[Longsword]|h" end end
  STUB.tooltips["spell:1978"] = {"Serpent Sting", "Correct spell damage"}
  STUB.tooltips["item:2140"] = {"Longsword", "Correct weapon damage"}
  local book = CreateFrame("Frame", "BookItem",UIParent)
  book.spellBookItemInfo = {spellID=1978}
  local bookChild = CreateFrame("Button", "BookItemButton",book)
  local action = CreateFrame("Button", "TestAction", UIParent)
  action.action = 3
  local equipped = CreateFrame("Button", "CharacterMainHandSlot", UIParent)
  equipped.GetID = function() return 16 end
  for _, focus in ipairs({bookChild, action, equipped}) do
   GetMouseFoci = function() return {focus} end
   WoWAIInput:SetText("")
   WoWAI.AttachHovered(false)
   local expanded = WoWAI.ExpandLinks(WoWAIInput:GetText())
   assert(not expanded:find("Wrong item",1,true))
   assert(expanded:find(focus==equipped and "Correct weapon damage" or "Correct spell damage",1,true))
  end
 `);
});

test('arbitrary tracker IDs and empty tracker areas do not become quest attachments', () => {
 const vm=newVM();login(vm);connect(vm);
 vm.run(`
  local module = CreateFrame("Frame", "AchievementTracker", UIParent)
  module.GetDebugReportInfo = function() return {debugType="Achievement", achievementID=989} end
  local block = CreateFrame("Frame", "AchievementBlock", module)
  block.id=989; block.parentModule=module
  GetMouseFoci = function() return {block} end
  GameTooltip:Hide()
  WoWAIInput:SetText("unchanged")
  WoWAI.AttachHovered(false)
 `);
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'unchanged');
});


test('GearQuest queries the real character and restores simulator functions and cache',()=>{
  const vm=newVM();login(vm);
  vm.run(`
    UnitClass=function() return "Hunter","HUNTER" end
    UnitFactionGroup=function() return "Horde" end
    GearQuest={VERSION="test",GetEffectiveClass=function() return "MAGE" end,GetEffectiveLevel=function() return 60 end,GetEffectiveFaction=function() return "Alliance" end,GetEffectiveSpec=function() return "frost" end,IsPreviewEnabled=function() return true end,
      Spec={DetectSpecFromTalents=function() return "beast_mastery" end},Data={_queryCache={saved=true}},Compare={GetEntryPowerScore=function() return 42 end}}
    oldCache=GearQuest.Data._queryCache;oldLevel=GearQuest.GetEffectiveLevel
    GearQuest.Data.GetTopUpgradesForSlot=function(self,slot,n)
      assert(GearQuest:GetEffectiveClass()=="HUNTER" and GearQuest:GetEffectiveLevel()==STUB.level)
      assert(GearQuest:GetEffectiveFaction()=="Horde" and GearQuest:GetEffectiveSpec()=="beast_mastery")
      return {{itemId=11853,minLevel=10,maxLevel=20,sourceType="quest",questId=77}}
    end
    GearQuest.Data.GetEntryDisplayName=function() return "Rambling Boots" end
    result=WoWAI.IntegrationSnapshot()
  `);
  assert.equal(vm.evaluate('result.gearquest.class'),'HUNTER');
  assert.equal(vm.num('result.gearquest.level'),23);
  assert.equal(vm.num('result.gearquest.simulator.level'),60);
  assert.equal(vm.num('#result.gearquest.projections'),15);
  assert.equal(vm.evaluate('GearQuest.Data._queryCache==oldCache and GearQuest.GetEffectiveLevel==oldLevel'),'true');
  vm.run('GearQuest.Data.GetTopUpgradesForSlot=function() return 7 end; failed=WoWAI.IntegrationSnapshot()');
  vm.run('metadata=WoWAI.IntegrationSnapshot(true)');
  assert.equal(vm.evaluate('metadata.gearquest.projectionsRequested'),'false');
  assert.equal(vm.evaluate('metadata.gearquest.projections'),null);
  assert.equal(vm.evaluate('GearQuest.Data._queryCache==oldCache and GearQuest.GetEffectiveLevel==oldLevel'),'true');
  assert.ok(vm.evaluate('failed.gearquest.error'));
});

test('reference cards cycle, retain random-enchant links, compare equipment and refresh uncached names',()=>{
  const vm=newVM();login(vm);
  vm.run(`
    C_Item={GetItemInfo=function(link) if link=="item:11853:0:0:0:0:0:15" then return "Rambling Boots",link,2,20,14,"Armor","Leather",1,"INVTYPE_FEET","boots" end end,
      GetItemStats=function(link) return {ITEM_MOD_AGILITY_SHORT=link=="equipped" and 2 or 3} end,RequestLoadItemDataByID=function(id) requested=id end}
    GetInventoryItemLink=function(_,slot) assert(slot==8);return "equipped" end
    parent=CreateFrame("Frame",nil,UIParent)
    refs={{kind="item",id=11853,payload="item:11853:0:0:0:0:0:15"},{kind="quest",id=77,name="Test quest"}}
    WoWAI.RenderReferenceCards(parent,refs,260,nil,function(ref) removed=ref.id end)
  `);
  assert.equal(vm.evaluate('parent.referenceDeck.title.text'),'Rambling Boots');
  assert.match(vm.evaluate('parent.referenceDeck.detail.text'),/Agility 3 \(\+1\)/);
  vm.run('parent.referenceDeck.next.scripts.OnClick()');
  assert.equal(vm.evaluate('parent.referenceDeck.title.text'),'Test quest');
  assert.equal(vm.evaluate('parent.referenceDeck.count.text'),'2/2');
  vm.run('parent.referenceDeck.next.scripts.OnClick();parent.referenceDeck.remove.scripts.OnClick()');
  assert.equal(vm.num('removed'),11853);
  vm.run('WoWAI.RenderReferenceCards(parent,{{kind="item",id=123}},260)');
  assert.equal(vm.num('requested'),123);
  vm.run('WoWAI.RenderReferenceCards(parent,{},260)');
  assert.equal(vm.evaluate('parent.referenceDeck.shown'),'false');
});

test('modern quality codes stay out of display and assistant cards cannot cross characters',()=>{
  const vm=newVM();login(vm);
  assert.equal(vm.evaluate('WoWAI.PlainText("|cnIQ2:|Hitem:11853|h[Rambling Boots]|h|r")'),'[Rambling Boots]');
  vm.run(`
    UnitGUID=function() return "Player-current" end
    c=WoWAIDB.chats[1];c.history={{role="assistant",id=8,text="Try these boots."}}
    WoWAI.ReceiveReferenceCards({session=WoWAIDB.session,chat=c.id,id=8,guid="Player-other",cards={{kind="item",id=11853}}})
  `);
  assert.equal(vm.evaluate('c.referenceCards'),null);
  vm.run('WoWAI.ReceiveReferenceCards({session=WoWAIDB.session,chat=c.id,id=8,guid="Player-current",cards={{kind="item",id=11853}}})');
  assert.equal(vm.num('c.history[1].references[1].id'),11853);
});

test('fresh detailed character sections remain small, secret-safe and request-scoped',()=>{
  const vm=newVM();login(vm);
  vm.run(fs.readFileSync(path.join(ADDON,'Snapshot.lua'),'utf8'),'WoWAI');
  vm.run(`
    UnitExists=function() return true end
    UnitGUID=function() return "Player-current" end
    UnitXP=function() return 2400 end;UnitXPMax=function() return 5000 end;GetXPExhaustion=function() return 3000 end
    secret={hidden=true};issecretvalue=function(v) return v==secret end
    UnitStat=function() return secret,30,0,0 end
    Enum={SpellBookSpellBank={Player=0}}
    C_SpellBook={GetSpellBookItemInfo=function(index) if index==1 then return {spellID=75,name="Auto Shot"} end end}
  `);
  const core=JSON.parse(vm.evaluate('WoWAI.SnapshotJSON()'));
  assert.equal(core.player.xp,2400);assert.equal(core.player.restedXP,3000);
  assert.equal(core.stats.attributes[0].base,undefined);assert.equal(core.stats.attributes[0].effective,30);
  const spells=JSON.parse(vm.evaluate('WoWAI.SnapshotJSON("spells",123)'));
  assert.equal(spells.section,'spells');assert.equal(spells.requestToken,123);
  assert.equal(spells.data[0].spellID,75);assert.equal(spells.inventory,undefined);
  vm.run('calls=0;WoWAI.QueueSnapshot=function(_,section,token) calls=calls+1;lastSection=section;return token end;WoWAI.ReceiveSnapshotRequest({session="wrong",token=1,section="spells"})');
  assert.equal(vm.num('calls'),0);
  vm.run('r={session=WoWAIDB.session,token=2,section="spells"};WoWAI.ReceiveSnapshotRequest(r);WoWAI.ReceiveSnapshotRequest(r)');
  assert.equal(vm.num('calls'),1);assert.equal(vm.evaluate('lastSection'),'spells');
});

test('small live refreshes skip heavy collections and preempt a pending background snapshot',()=>{
 const vm=newVM();login(vm);connect(vm);
 vm.run(fs.readFileSync(path.join(ADDON,'Snapshot.lua'),'utf8'),'WoWAI');
 vm.run(`
  calls=0;WoWAI.IntegrationSnapshot=function() calls=calls+1;return {} end
  WoWAI.CollectSnapshot("player");assert(calls==0)
  WoWAI.CollectSnapshot("integrations");assert(calls==1)
  WoWAI.QueueSnapshot(false)
  before=WoWAIDB.snapshotSeq
  WoWAI.QueueSnapshot(false,"player","priority-token")
 `);
 assert.equal(vm.num('WoWAIDB.snapshotSeq'),vm.num('before')+1);
 assert.ok(decodeStrip(vm).text.includes('priority-token'));
});

test('chat status refreshes preserve scroll position; wheel steps are fine and delayed renders cannot undo a user scroll',()=>{
 const vm=newVM();login(vm);connect(vm);
 vm.run('WoWAIScroll.scrollRange=600;WoWAIScroll:SetVerticalScroll(600);WoWAI.Render();STUB.RunTimers()');
 assert.equal(vm.num('WoWAIScroll:GetVerticalScroll()'),600);
 vm.run('WoWAIScroll.scripts.OnMouseWheel(WoWAIScroll,1);WoWAIScroll.scripts.OnUpdate(WoWAIScroll,.1)');
 assert.equal(vm.num('WoWAIScroll:GetVerticalScroll()'),588);
 vm.run('WoWAI.Render();WoWAIScroll.scripts.OnMouseWheel(WoWAIScroll,3);WoWAIScroll.scripts.OnUpdate(WoWAIScroll,.1);STUB.RunTimers()');
 assert.equal(vm.num('WoWAIScroll:GetVerticalScroll()'),552);
 vm.run('WoWAIScroll.scrollRange=800;WoWAI.Render();STUB.RunTimers()');
 assert.equal(vm.num('WoWAIScroll:GetVerticalScroll()'),552);
 vm.run('WoWAIScroll:SetVerticalScroll(800);WoWAIScroll.scrollRange=850;WoWAI.Render();STUB.RunTimers()');
 // Being at bottom before new content is captured by the explicit follow flag.
 assert.equal(vm.num('WoWAIScroll:GetVerticalScroll()'),850);
});

test('composer has a fixed compact height and a horizontal width anchor',()=>{
 const vm=newVM();login(vm);
 assert.equal(vm.num('WoWAIInputBackground:GetHeight()'),42);
 assert.equal(vm.evaluate('WoWAIInputBackground.points[2][1]'),'RIGHT');
 assert.equal(vm.num('WoWAIInputBackground.points[1][5]'),44);
});

test('custom journal tooltips are remembered and attached with their original item link',()=>{
 const vm=newVM();login(vm);connect(vm);
 vm.run(`
  local owner=CreateFrame("Button","DungeonLootCard",UIParent);owner.IsMouseOver=function() return true end
  custom=CreateFrame("GameTooltip","ForeverDungeonJournalItemTooltip",UIParent)
  custom.GetItem=function() return "Enchanted Boots","|Hitem:11853:0:0:0:0:0:15|h[Enchanted Boots]|h" end
  custom.GetOwner=function() return owner end
  STUB.tooltips["item:11853:0:0:0:0:0:15"]={"Enchanted Boots","+3 Agility"}
  custom:SetHyperlink("item:11853:0:0:0:0:0:15")
  GameTooltip:Hide();GetMouseFoci=function() return {owner} end
  WoWAI.RememberHoveredTooltip(custom);WoWAI.AttachHovered(false)
 `);
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'[Enchanted Boots]');
 vm.run('WoWAIInput:SetText("");custom:Hide();WoWAI.AttachHovered(true)');
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'[Enchanted Boots]');
});

test('legacy custom tooltips can be discovered at attachment time without a tooltip processor',()=>{
 const vm=newVM();login(vm);connect(vm);
 vm.run(`
  local owner=CreateFrame("Button","ThirdPartyLootCard",UIParent);owner.IsMouseOver=function() return true end
  local tip=CreateFrame("GameTooltip","ThirdPartyTooltip",UIParent)
  tip.GetObjectType=function() return "GameTooltip" end;tip.GetOwner=function() return owner end
  tip.GetItem=function() return "Test Sword","|Hitem:19019|h[Test Sword]|h" end
  EnumerateFrames=function(prev) if not prev then return tip end end
  GetMouseFoci=function() return {owner} end;GameTooltip:Hide();WoWAI.AttachHovered(false)
 `);
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'[Test Sword]');
});

test('chat loot links attach without a tooltip, retain item variants, and stop being selected on leave',()=>{
 const vm=newVM();
 vm.run('ChatFrame1=CreateFrame("ScrollingMessageFrame","ChatFrame1",UIParent)');
 login(vm);connect(vm);
 vm.run(`
  GameTooltip:Hide();ChatFrame1.IsMouseOver=function() return true end
  GetMouseFoci=function() return {ChatFrame1} end
  IsControlKeyDown=function() return true end;IsAltKeyDown=function() return true end
  for _,fn in ipairs(ChatFrame1.hooks.OnHyperlinkEnter) do fn(ChatFrame1,"item:1735:0:0:0:0:0:15","|cffffffff|Hitem:1735:0:0:0:0:0:15|h[Fine Loose Hair]|h|r") end
  STUB.now=STUB.now+60
  STUB.FireEvent("GLOBAL_MOUSE_DOWN","MiddleButton")
 `);
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'[Fine Loose Hair]');
 connect(vm); // renew the bridge heartbeat after testing a long stationary hover
 vm.run('WoWAI.Send(WoWAIInput:GetText())');
 assert.ok(stripRecords(vm).find(r=>r.text.includes('item:1735:0:0:0:0:0:15')));
 vm.run(`
  STUB.FireEvent("GLOBAL_MOUSE_UP","MiddleButton")
  for _,fn in ipairs(ChatFrame1.hooks.OnHyperlinkLeave) do fn(ChatFrame1) end
  WoWAIInput:SetText("");WoWAI.AttachHovered(false)
 `);
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'');
 vm.run(`
  WoWAI.RememberHoveredHyperlink(ChatFrame1,"achievement:123","[Unrelated]")
  WoWAI.AttachHovered(false)
 `);
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'');
});

test('loot rolls resolve the exact item from the parent roll and new chat windows are hooked once',()=>{
 const vm=newVM();login(vm);connect(vm);
 vm.run(`
  GameTooltip:Hide()
  local roll=CreateFrame("Frame","GroupLootFrame1",UIParent);roll.rollID=27
  local icon=CreateFrame("Button","GroupLootFrame1IconFrame",roll)
  GetLootRollItemLink=function(id) if id==27 then return "|Hitem:2140:0:0:0:0:0:15|h[Carving Knife of Agility]|h" end end
  GetMouseFoci=function() return {icon} end;WoWAI.AttachHovered(false)
  ChatFrame2=CreateFrame("ScrollingMessageFrame","ChatFrame2",UIParent)
  CHAT_FRAMES={"ChatFrame2"};STUB.FireEvent("ADDON_LOADED","Blizzard_ChatFrame")
  WoWAI.HookChatLinks()
 `);
 assert.equal(vm.evaluate('WoWAIInput:GetText()'),'[Carving Knife of Agility]');
 assert.equal(vm.num('#ChatFrame2.hooks.OnHyperlinkEnter'),1);
});

test('minimap icon stays available after X, reopens and resumes the guide, and saves dragged position',()=>{
 const vm=newVM();
 vm.run(`
  Minimap=CreateFrame("Frame","Minimap",UIParent);Minimap:SetSize(140,140)
  Minimap.GetCenter=function() return 500,500 end;Minimap.GetEffectiveScale=function() return 1 end
  GetCursorPosition=function() return 600,500 end
 `);
 login(vm);connect(vm);
 vm.run('WoWAI.Toggle(true);WoWAI.CloseGuide()');
 assert.equal(vm.evaluate('WoWAIMinimapButton:IsShown()'),'true');
 assert.equal(vm.evaluate('WoWAIFrame:IsShown()'),'false');
 assert.equal(vm.evaluate('WoWAIMini:IsShown()'),'false');
 assert.equal(vm.evaluate('WoWAIDB.settings.copilotEnabled'),'false');
 vm.run('WoWAIMinimapButton.scripts.OnClick(WoWAIMinimapButton)');
 assert.equal(vm.evaluate('WoWAIDB.settings.copilotEnabled'),'true');
 assert.equal(vm.evaluate('WoWAIFrame:IsShown()'),'true');
 vm.run('WoWAIMinimapButton.scripts.OnDragStart(WoWAIMinimapButton);WoWAIMinimapButton.scripts.OnUpdate();WoWAIMinimapButton.scripts.OnDragStop(WoWAIMinimapButton)');
 assert.equal(vm.num('WoWAIDB.settings.minimapAngle'),0);
 assert.equal(vm.num('WoWAIMinimapButton.x'),78);
 vm.run('WoWAI.CloseGuide();WoWAIMinimapButton.scripts.OnClick(WoWAIMinimapButton)');
 assert.equal(vm.evaluate('WoWAIFrame:IsShown()'),'false','ending a drag does not reopen the guide');
 vm.run('STUB.RunTimers();WoWAIMinimapButton.scripts.OnClick(WoWAIMinimapButton)');
 assert.equal(vm.evaluate('WoWAIFrame:IsShown()'),'true');
});

test('combat includes pet and nested guardians, ranks crit damage, and excludes unrelated players',()=>{
 const vm=newVM();login(vm);
 vm.run(`
  UnitGUID=function(unit) if unit=="player" then return "Player-mine" elseif unit=="pet" then return "Pet-mine" elseif unit=="target" then return "Creature-target" end end
  UnitName=function(unit) return unit end
  CombatLogGetCurrentEventInfo=function() end
  UnitDetailedThreatSituation=function(unit) return false,1,30,20,unit=="player" and 400 or 100 end
  UnitAttackSpeed=function() return 2 end
  UnitRangedDamage=function() return 2.5 end
 `);
 vm.run(fs.readFileSync(path.join(ADDON,'Combat.lua'),'utf8'),'WoWAI');
 vm.run(fs.readFileSync(path.join(ADDON,'Snapshot.lua'),'utf8'),'WoWAI');
 vm.run(`
  WoWAI.SetCombatEnabled(true)
  function damage(source,name,flags,spell,amount,crit,dest)
    WoWAI.RecordCombatEvent(0,"SPELL_DAMAGE",false,source,name,flags,0,dest or "Creature-target","Target",0,0,spell,"Ability "..spell,1,amount,0,1,0,0,0,crit,false,false,false)
  end
  STUB.now=STUB.now+1
  damage("Player-mine","You",257,75,100,true)
  damage("Pet-mine","Wolf",257,17253,60,false)
  WoWAI.RecordCombatEvent(0,"SPELL_SUMMON",false,"Pet-mine","Wolf",257,0,"Creature-guard","Guardian",257,0,9,"Summon",1)
  damage("Creature-guard","Guardian",257,123,90,true)
  damage("Player-party","Party",258,75,999,true)
  damage("Creature-party-pet","Other Pet",258,17253,999,false)
  damage("Creature-older-summon","Older Guardian",257,123,10,false)
  damage("Creature-enemy","Enemy",0,77,35,true,"Player-mine")
  WoWAI.RecordCombatEvent(0,"SPELL_CAST_SUCCESS",false,"Player-mine","You",257,0,"Creature-target","Target",0,0,75,"Auto Shot",1)
 `);
 const data=JSON.parse(vm.evaluate('WoWAI.SnapshotJSON("combat",12)')).data;
 assert.equal(data.available,true);assert.equal(data.outgoing.damage,260);assert.equal(data.outgoing.crits,2);assert.equal(data.outgoing.critDamage,190);
 assert.equal(data.incoming.damage,35);assert.equal(data.incoming.crits,1);assert.equal(data.abilities[0].damage,100);
 assert.equal(data.sources.length,4);assert.equal(data.castSequence[0].spellID,75);assert.equal(data.threat.player.threat,400);
 vm.run('WoWAI.combatQuery={includePets=false}');
 const solo=JSON.parse(vm.evaluate('WoWAI.SnapshotJSON("combat",13)')).data;
 assert.equal(solo.outgoing.damage,100);assert.equal(solo.sources.length,1);
});

test('combat fixed measurements stop at their requested endpoint, bound history and cancel when closed',()=>{
 const vm=newVM();login(vm);
 vm.run(`
  UnitGUID=function(u) return u=="player" and "Player-mine" end
  CombatLogGetCurrentEventInfo=function() end
 `);
 vm.run(fs.readFileSync(path.join(ADDON,'Combat.lua'),'utf8'),'WoWAI');
 vm.run(`
  WoWAI.SetCombatEnabled(true);WoWAI.QueueSnapshot=function(_,section,token) delivered=token;return true end
  STUB.timers={};WoWAI.BeginCombatMeasurement(10,88,true)
  function hit(amount) WoWAI.RecordCombatEvent(0,"SWING_DAMAGE",false,"Player-mine","You",257,0,"Enemy","Enemy",0,0,amount,0,1,0,0,0,true,false,false,false) end
  STUB.now=1005;hit(100);STUB.now=1010;STUB.RunTimers()
  STUB.now=1011;hit(999);fixed=WoWAI.CollectCombatRequest(88)
 `);
 assert.equal(vm.num('fixed.outgoing.damage'),100);assert.equal(vm.num('fixed.measurement.durationSeconds'),10);assert.equal(vm.num('delivered'),88);
 vm.run('WoWAI.BeginCombatMeasurement(10,89);WoWAI.SetCombatEnabled(false);STUB.RunTimers()');
 assert.equal(vm.num('delivered'),88);assert.equal(vm.evaluate('WoWAI.CombatSnapshot().available'),'false');
 vm.run('WoWAI.SetCombatEnabled(true);STUB.now=1100;hit(22);STUB.now=1500;empty=WoWAI.CombatSnapshot(30)');
 assert.equal(vm.num('empty.outgoing.damage'),0);
});

test('restricted combat data is unknown and is never compared or coerced',()=>{
 const vm=newVM();login(vm);
 vm.run('UnitGUID=function() return "Player-mine" end;CombatLogGetCurrentEventInfo=function() end;secret={};issecretvalue=function(v) return v==secret end');
 vm.run(fs.readFileSync(path.join(ADDON,'Combat.lua'),'utf8'),'WoWAI');
 vm.run('WoWAI.SetCombatEnabled(true);WoWAI.RecordCombatEvent(0,"SPELL_DAMAGE",false,"Player-mine","You",257,0,"Enemy","Enemy",0,0,75,"Shot",1,secret);restricted=WoWAI.CombatSnapshot()');
 assert.equal(vm.evaluate('restricted.available'),'false');assert.equal(vm.evaluate('restricted.restricted'),'true');
 assert.match(vm.evaluate('restricted.reason'),/restricted/);
});

test('auction prices preserve day-based scan age, unit/stack costs and exclude your own auctions',()=>{
 const vm=newVM();login(vm);
 vm.run(`
  UnitFactionGroup=function() return "Horde" end;GetCurrentRegion=function() return 1 end
  Auctionator={API={v1={GetAuctionPriceByItemID=function(_,id) return id==11853 and 1200 end,GetAuctionAgeByItemID=function() return 2 end}}}
  C_Item={GetItemInfo=function(id) return "Boots","item:"..id,2,20,14,"Armor","Leather",1,"INVTYPE_FEET","boots",55 end}
  C_AuctionHouse={GetNumItemSearchResults=function() return 3 end,GetItemSearchResultInfo=function(_,i)
    if i==1 then return {buyoutAmount=900,quantity=3,itemLink="item:11853",auctionID=1} elseif i==2 then return {buyoutAmount=100,quantity=1,containsOwnerItem=true} else return {buyoutAmount=0,bidAmount=10} end end,
    HasFullItemSearchResults=function() return true end}
 `);
 vm.run(fs.readFileSync(path.join(ADDON,'Auctions.lua'),'utf8'),'WoWAI');
 vm.run('STUB.FireEvent("AUCTION_HOUSE_SHOW");STUB.FireEvent("ITEM_SEARCH_RESULTS_UPDATED",{itemID=11853});price=WoWAI.AuctionSnapshot({itemIds={11853,12345},budgetCopper=500})');
 assert.equal(vm.num('price.prices[1].scanAgeDays'),2);assert.equal(vm.num('price.prices[1].lowestObservedUnitPrice'),300);
 assert.equal(vm.num('price.prices[1].listings[1].totalPrice'),900);assert.equal(vm.num('price.prices[1].listingCount'),1);
 assert.equal(vm.evaluate('price.prices[1].withinBudget'),'true');assert.equal(vm.num('price.prices[1].vendorPrice'),55);
 assert.equal(vm.evaluate('price.prices[2].available'),'false');assert.equal(vm.evaluate('price.prices[1].live'),'true');
 vm.run('STUB.now=STUB.now+20;price=WoWAI.AuctionSnapshot({itemIds={11853}})');
 assert.equal(vm.evaluate('price.prices[1].live'),'false');
 vm.run('C_AuctionHouse.GetNumItemSearchResults=function() return 0 end;STUB.FireEvent("ITEM_SEARCH_RESULTS_UPDATED",{itemID=11853});price=WoWAI.AuctionSnapshot({itemIds={11853}})');
 assert.equal(vm.num('price.prices[1].listingCount'),0);assert.equal(vm.evaluate('price.prices[1].lowestObservedUnitPrice'),null);
});

test('auction searches use Auctionator only at an auctioneer and observations cannot cross markets',()=>{
 const vm=newVM();login(vm);
 vm.run(`
  region=1;realm="Beta";GetRealmName=function() return realm end;GetCurrentRegion=function() return region end
  Auctionator={API={v1={MultiSearch=function(_,terms) searches=(searches or 0)+1;term=terms[1] end}}}
  AuctionHouseFrame=CreateFrame("Frame","AuctionHouseFrame",UIParent);AuctionHouseFrame:Hide()
 `);
 vm.run(fs.readFileSync(path.join(ADDON,'Auctions.lua'),'utf8'),'WoWAI');
 vm.run('WoWAI.StartAuctionSearch({"Light Leather"});price=WoWAI.AuctionSnapshot()');
 assert.equal(vm.evaluate('price.search.started'),'false');assert.equal(vm.evaluate('searches'),null);
 vm.run('AuctionHouseFrame:Show();WoWAI.StartAuctionSearch({"Light Leather"});price=WoWAI.AuctionSnapshot()');
 assert.equal(vm.num('searches'),1);assert.equal(vm.evaluate('price.search.started'),'true');assert.equal(vm.evaluate('term'),'Light Leather');
 vm.run('WoWAI.StartAuctionSearch({"bad;query"});price=WoWAI.AuctionSnapshot()');
 assert.equal(vm.num('searches'),1);assert.equal(vm.evaluate('price.search.started'),'false');
 vm.run('WoWAI.AuctionSnapshot({itemIds={11853}});WoWAIDB.auctionCache.items["11853"]={observedAt=time(),listings={{unitPrice=1}}};realm="Other";price=WoWAI.AuctionSnapshot({itemIds={11853}})');
 assert.equal(vm.evaluate('price.prices[1].lowestObservedUnitPrice'),null);
});
