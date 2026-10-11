'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

function screenshot(cfg) {
  const dir = path.join(__dirname, 'tmp');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const file = path.join(dir, `vision-${Date.now()}-${Math.random().toString(16).slice(2)}.png`);
  if(process.platform==='win32')execFileSync('powershell.exe',['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'capture.ps1'),'-ProcessName',cfg.capture?.processName||'WowB','-Screenshot',file],{timeout:12000,windowsHide:true,stdio:['ignore','pipe','pipe']});
  else execFileSync(cfg.capture?.python || 'python3', [path.join(__dirname, cfg.capture?.backend==='niri'?'capture_wayland.py':'capture_x11.py'),
    '--process-name', cfg.capture?.processName || 'WowB', '--screenshot', file], { timeout: 12000, stdio: ['ignore', 'pipe', 'pipe'] });
  fs.chmodSync(file, 0o600);
  return file;
}
module.exports = { screenshot };
