'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
function defaultSocket(platform=process.platform,root=__dirname,user=os.userInfo().username) {
  return platform==='win32'?'\\\\.\\pipe\\adventurers-guide-'+crypto.createHash('sha256').update(user+'\0'+root).digest('hex').slice(0,24):path.join(root,'copilot.sock');
}
const SOCKET = process.env.WOW_COPILOT_SOCKET || defaultSocket();

function request(method, args = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ socketPath: SOCKET, path: '/', method: 'POST', timeout: 65000 }, res => {
      let data = '';
      res.on('data', chunk => { data += chunk; if (data.length > 32000000) req.destroy(new Error('IPC response too large')); });
      res.on('end', () => {
        try { const value = JSON.parse(data); if (value.error) reject(new Error(value.error)); else resolve(value); }
        catch (e) { reject(e); }
      });
    });
    req.on('timeout', () => req.destroy(new Error('Bridge request timed out')));
    req.on('error', e => reject(new Error('WoW bridge unavailable: ' + e.message)));
    req.end(JSON.stringify({ method, args }));
  });
}

async function serve(handler) {
  // Do not steal a socket from another live bridge.
  if (process.platform === 'win32' || fs.existsSync(SOCKET)) {
    try { await request('status'); throw new Error('A WoW bridge is already running'); }
    catch (e) { if (!/ECONNREFUSED|ENOENT/.test(e.message)) throw e; if(process.platform!=='win32') fs.unlinkSync(SOCKET); }
  }
  const server = http.createServer(async (req, res) => {
    let data = '';
    req.on('data', chunk => { data += chunk; if (data.length > 100000) req.destroy(); });
    req.on('end', async () => {
      try {
        if (req.method !== 'POST' || req.url !== '/') throw new Error('Invalid IPC request');
        const { method, args } = JSON.parse(data);
        res.end(JSON.stringify(await handler(method, args || {})));
      } catch (e) { res.statusCode = 400; res.end(JSON.stringify({ error: e.message })); }
    });
  });
  server.requestTimeout = 70000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(SOCKET, resolve); });
  if(process.platform!=='win32') fs.chmodSync(SOCKET, 0o600);
  return server;
}
module.exports = { request, serve, SOCKET, defaultSocket };
