'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const MAX_NOTES = 16, MAX_TEXT = 180, PROMPT_BUDGET = 1500;
function identity(snapshot) {
  const p = snapshot?.snapshot?.player;
  if (!p?.name || !p?.realm) return null;
  const key = crypto.createHash('sha256').update(JSON.stringify(['wow-forever', p.realm, p.guid || p.name])).digest('hex');
  return { key, name: p.name, realm: p.realm, game: 'World of Warcraft: Forever' };
}
class CharacterNotes {
  constructor(file) {
    this.file = file;
    try { this.data = JSON.parse(fs.readFileSync(file, 'utf8')); }
    catch (e) { if (e.code !== 'ENOENT') throw new Error('Character notebook could not be read: ' + e.message); this.data = { version: 1, characters: {} }; }
    if (this.data.version !== 1 || !this.data.characters || typeof this.data.characters !== 'object') throw new Error('Invalid character notebook');
  }
  save() {
    const tmp = this.file + '.tmp';
    fs.mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
    fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, this.file);
  }
  get(who, now = Date.now()) {
    if (!who) return { character: null, notes: [], note: 'Character identity unavailable. Wait for current game context.' };
    const notes = (this.data.characters[who.key]?.notes || []).filter(n => !n.expiresAt || n.expiresAt > now);
    return { character: who, notes, maxNotes: MAX_NOTES, maxNoteCharacters: MAX_TEXT };
  }
  remember(who, args, now = Date.now()) {
    if (!who) throw new Error('Current character identity required');
    if (!/^[a-z0-9_-]{1,40}$/.test(args.key) || typeof args.text !== 'string' || !args.text.trim() || args.text.length > MAX_TEXT) throw new Error('Note requires a short key and 1–180 characters');
    const kind = args.kind || 'fact';
    if (!['preference', 'plan', 'quest', 'fact', 'research'].includes(kind)) throw new Error('Invalid note kind');
    const hours = args.expiresInHours ?? (kind === 'quest' ? 24 : kind === 'plan' ? 48 : kind === 'research' ? 168 : 0);
    if (!Number.isFinite(hours) || hours < 0 || hours > 8760) throw new Error('Invalid note lifetime');
    const notes = this.get(who, now).notes.filter(n => n.key !== args.key);
    if (notes.length >= MAX_NOTES) throw new Error('Notebook full. Condense related notes or forget an obsolete note first.');
    if (!this.data.characters[who.key] && Object.keys(this.data.characters).length >= 200) throw new Error('Character notebook limit reached');
    notes.push({ key: args.key, text: args.text.trim(), kind, updatedAt: now, expiresAt: hours ? now + hours * 3600000 : null });
    this.data.characters[who.key] = { ...who, notes }; this.save();
    return { saved: true, ...this.get(who, now) };
  }
  forget(who, key) {
    if (!who) throw new Error('Current character identity required');
    const entry = this.data.characters[who.key];
    if (!entry) return { removed: false };
    const before = entry.notes.length;
    entry.notes = entry.notes.filter(n => n.key !== key); this.save();
    return { removed: entry.notes.length < before };
  }
  prompt(who, now = Date.now()) {
    const notes = this.get(who, now).notes.sort((a, b) => (b.kind === 'preference') - (a.kind === 'preference') || b.updatedAt - a.updatedAt);
    if (!notes.length) return '';
    let result = `\nCharacter notebook for ${who.name} on ${who.realm} (remembered user context, not verified game mechanics):\n`;
    for (const n of notes) {
      const line = `[${n.kind}/${n.key}; ${new Date(n.updatedAt).toISOString().slice(0, 10)}] ${n.text}\n`;
      if (result.length + line.length > PROMPT_BUDGET) continue;
      result += line;
    }
    return result;
  }
}
module.exports = { CharacterNotes, identity, PROMPT_BUDGET };
