'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const supervisor = fs.readFileSync(path.join(root, 'runtime/supervisor.cjs'), 'utf8');
const worker = fs.readFileSync(path.join(root, 'runtime/worker.cjs'), 'utf8');
function start() {
  const child = spawn(process.execPath, ['-e', supervisor], { stdio: ['ignore','ignore','pipe','ipc'], detached:true, env:{...process.env,SCHELM_SQLITE_WORKER_B64:Buffer.from(worker).toString('base64')} });
  let id=1; const wait=[]; child.on('message',m=>{ const i=wait.findIndex(x=>x.id===m.id); if(i>=0)wait.splice(i,1)[0].resolve(m); });
  return {child, request(op, extra={}) { const message={v:1,id:id++,op,mutating:false,inTransaction:false,sql:'',bindings:[],rowLimit:10,byteLimit:100000,mode:'',options:null,...extra}; return new Promise((resolve,reject)=>{wait.push({id:message.id,resolve});child.send(message,e=>e&&reject(e));});}, ready:new Promise(resolve=>child.once('message',resolve))};
}
function value(t,v){return v===undefined?{t}:{t,v}}
test('persistent worker executes and queries with typed values', async t => {
  const s=start(); t.after(()=>{try{process.kill(-s.child.pid,'SIGKILL')}catch{}}); await s.ready;
  assert.equal((await s.request('open',{options:{path:':memory:',readOnly:false,busyTimeout:100}})).kind,'done');
  assert.equal((await s.request('execute',{mutating:true,sql:'CREATE TABLE x(i INTEGER, s TEXT)'})).kind,'done');
  assert.equal((await s.request('execute',{mutating:true,sql:'INSERT INTO x VALUES(?,?)',bindings:[value('integer','7'),value('text','ok')]})).changedRows,1);
  const result=await s.request('query',{sql:'SELECT i,s FROM x'}); assert.equal(result.kind,'done'); assert.deepEqual(result.columns,['i','s']); assert.deepEqual(result.rows,[[value('integer','7'),value('text','ok')]]);
});
test('significant SQL tail is rejected before stepping', async t => {
  const s=start(); t.after(()=>{try{process.kill(-s.child.pid,'SIGKILL')}catch{}}); await s.ready; await s.request('open',{options:{path:':memory:',readOnly:false,busyTimeout:100}});
  const result=await s.request('execute',{mutating:true,sql:'CREATE TABLE a(x); CREATE TABLE b(x)'}); assert.equal(result.kind,'error'); assert.equal(result.entered,false);
});
