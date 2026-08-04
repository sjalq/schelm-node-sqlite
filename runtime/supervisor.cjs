'use strict';
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const VERSION=1,MAGIC=0x53514c31,MAX_FRAME=8*1024*1024,HARD_RSS_KB=Number(process.env.SCHELM_SQLITE_RSS_KB||262144);
const workerSource=Buffer.from(process.env.SCHELM_SQLITE_WORKER_B64,'base64').toString('utf8');
let worker=null,ready=false,pending=null,parentCredit=1,parentInput=Buffer.alloc(0),workerInput=Buffer.alloc(0),killing=false;
const crcTable=(()=>{const t=new Uint32Array(256);for(let n=0;n<256;n++){let c=n;for(let k=0;k<8;k++)c=(c&1)?0xedb88320^(c>>>1):c>>>1;t[n]=c>>>0;}return t;})();
function crc32(b){let c=0xffffffff;for(const x of b)c=crcTable[(c^x)&255]^(c>>>8);return(c^0xffffffff)>>>0;}
function frame(v){const b=Buffer.from(JSON.stringify(v),'utf8');if(b.length>MAX_FRAME)throw new Error('frame too large');const h=Buffer.alloc(14);h.writeUInt32BE(MAGIC,0);h.writeUInt16BE(VERSION,4);h.writeUInt32BE(b.length,6);h.writeUInt32BE(crc32(b),10);return Buffer.concat([h,b]);}
function consume(which,chunk,onValue){let b=Buffer.concat([which==='parent'?parentInput:workerInput,chunk]);for(;;){if(b.length<14)break;if(b.readUInt32BE(0)!==MAGIC||b.readUInt16BE(4)!==VERSION)throw new Error('bad header');const n=b.readUInt32BE(6);if(n>MAX_FRAME)throw new Error('oversize');if(b.length<14+n)break;const body=b.subarray(14,14+n);if(crc32(body)!==b.readUInt32BE(10))throw new Error('crc');b=b.subarray(14+n);onValue(JSON.parse(body.toString('utf8')));}if(which==='parent')parentInput=b;else workerInput=b;}
function write(stream,value,done){const ok=stream.write(frame(value),done);if(!ok)stream.once('drain',()=>{});}
function kill(signal){if(worker&&worker.exitCode===null)try{process.kill(-worker.pid,signal);}catch(_){try{worker.kill(signal);}catch(_){}}}
function rssKb(pid){try{const x=fs.readFileSync(`/proc/${pid}/status`,'utf8').match(/^VmRSS:\s+(\d+)\s+kB/m);return x?Number(x[1]):0;}catch(_){return 0;}}
function toParent(m){if(!process.connected)return;process.send(frame(m),()=>{if(m.kind==='row'||m.kind==='columns')parentCredit=1;else{pending=null;parentCredit=1;}});}
function fromWorker(m){if(m.kind==='ready'&&m.v===VERSION){ready=true;process.send(frame({v:VERSION,id:0,kind:'ready',creditMessages:1,creditBytes:MAX_FRAME}));return;}if(!pending||!m||m.v!==VERSION||m.id!==pending.id)throw new Error('worker identity');if(m.kind==='columns'||m.kind==='row'||m.kind==='done'||m.kind==='error'){toParent(m);return;}throw new Error('worker tag');}
function fromParent(m){if(!ready||parentCredit!==1||!m||m.v!==VERSION||!Number.isSafeInteger(m.id)||m.id<1)throw new Error('parent protocol');if(pending&&!(m.op==='demand'&&m.id===pending.id))throw new Error('request overlap');if(!pending)pending={id:m.id,mutating:!!m.mutating};parentCredit=0;write(worker.stdin,m);}
function boot(){worker=spawn(process.execPath,['--max-old-space-size=128','-e',workerSource],{stdio:['pipe','pipe','ignore'],detached:true});worker.stdout.on('data',c=>{try{consume('worker',c,fromWorker);}catch(_){kill('SIGKILL');}});worker.on('exit',(code,signal)=>{const p=pending;pending=null;ready=false;if(p&&process.connected)process.send(frame({v:VERSION,id:p.id,kind:'exit',code:code||0,signal:signal||''}),()=>process.exit(70));else process.exit(killing?0:70);});}
process.on('message',m=>{try{const chunk=Buffer.isBuffer(m)?m:Buffer.from(m&&m.data||[]);consume('parent',chunk,fromParent);}catch(_){kill('SIGKILL');process.exit(71);}});
const meter=setInterval(()=>{if(worker&&rssKb(worker.pid)>HARD_RSS_KB){const p=pending;killing=true;kill('SIGKILL');if(p&&process.connected)process.send(frame({v:VERSION,id:p.id,kind:'memory'}));}},25);meter.unref();
function shutdown(){if(killing)return;killing=true;if(worker&&worker.stdin)worker.stdin.end();kill('SIGTERM');setTimeout(()=>{kill('SIGKILL');},250).unref();setTimeout(()=>process.exit(0),500).unref();}
process.on('disconnect',shutdown);process.on('SIGTERM',shutdown);boot();
