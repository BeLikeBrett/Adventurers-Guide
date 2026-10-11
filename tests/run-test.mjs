import {spawnSync} from 'node:child_process';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
const id=crypto.randomBytes(8).toString('hex');
const env={...process.env,WOW_COPILOT_SOCKET:process.platform==='win32'?`\\\\.\\pipe\\guide-test-${id}`:path.join(os.tmpdir(),`guide-test-${id}.sock`)};
const steps=[['tests/order_check.js'],['--test','tests/bridge_test.js','tests/agents_test.js','tests/restore_test.js','tests/addon_test.js','tests/map_test.js','tests/map_addon_test.js','tests/macro_test.js','tests/character_notes_test.js','tests/reference_catalog_test.js','tests/setup_test.js','tests/combat_log_test.js'],['tests/codec_test.js'],['--test','tests/copilot_test.mjs']];
for(const args of steps){const result=spawnSync(process.execPath,args,{env,stdio:'inherit'});if(result.status!==0)process.exit(result.status||1);}
