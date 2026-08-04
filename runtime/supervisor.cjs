'use strict';
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const VERSION = 1, HARD_RSS_KB = Number(process.env.SCHELM_SQLITE_RSS_KB || 262144);
const workerSource = Buffer.from(process.env.SCHELM_SQLITE_WORKER_B64, 'base64').toString('utf8');
let worker = null, ready = false, pending = null, parentCredit = 1;
function envelopeOk(m) { return m && m.v === VERSION && Number.isSafeInteger(m.id) && m.id > 0; }
function kill(signal) { if (worker && worker.exitCode === null) { try { process.kill(-worker.pid, signal); } catch (_) { try { worker.kill(signal); } catch (_) {} } } }
function rssKb(pid) { try { const x = fs.readFileSync(`/proc/${pid}/status`, 'utf8').match(/^VmRSS:\s+(\d+)\s+kB/m); return x ? Number(x[1]) : 0; } catch (_) { return 0; } }
function boot() {
  worker = spawn(process.execPath, ['--max-old-space-size=128', '-e', workerSource], { stdio: ['ignore','ignore','ignore','ipc'], detached: true });
  worker.on('message', m => {
    if (m && m.kind === 'ready' && m.v === VERSION) { ready = true; process.send({v:VERSION,id:0,kind:'ready',creditMessages:1,creditBytes:8388608}); return; }
    if (!pending || !m || m.v !== VERSION || m.id !== pending.id) { kill('SIGKILL'); return; }
    process.send(m, () => { pending = null; parentCredit = 1; });
  });
  worker.on('exit', (code, signal) => { const p = pending; pending = null; ready = false; if (p && process.connected) process.send({v:VERSION,id:p.id,kind:'exit',code:code||0,signal:signal||''}); process.exit(70); });
}
process.on('message', m => {
  if (!ready || pending || parentCredit !== 1 || !envelopeOk(m)) { kill('SIGKILL'); process.exit(71); return; }
  const size = Buffer.byteLength(JSON.stringify(m)); if (size > 8388608) { process.exit(72); return; }
  parentCredit = 0; pending = { id:m.id, mutating:!!m.mutating }; worker.send(m);
});
const meter = setInterval(() => { if (worker && rssKb(worker.pid) > HARD_RSS_KB) { const p=pending; kill('SIGKILL'); if (p && process.connected) process.send({v:VERSION,id:p.id,kind:'memory'}); } }, 25); meter.unref();
process.on('disconnect', () => { kill('SIGTERM'); setTimeout(() => { kill('SIGKILL'); process.exit(0); }, 250).unref(); });
process.on('SIGTERM', () => { kill('SIGTERM'); setTimeout(() => { kill('SIGKILL'); process.exit(0); }, 250).unref(); });
boot();
