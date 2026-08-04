'use strict';
const test=require('node:test'),assert=require('node:assert/strict');

function rng(seed){let x=seed>>>0;return()=>{x^=x<<13;x^=x>>>17;x^=x<<5;return x>>>0;};}
class Model{
  constructor(){this.queues=Array.from({length:16},()=>[]);this.ready=[];this.inReady=new Set();this.live=new Set();this.maxQueued=0;}
  submit(db,id){if(this.live.size>=1024||this.queues[db].length>=256)return false;this.queues[db].push(id);this.live.add(id);this.maxQueued=Math.max(this.maxQueued,this.live.size);if(!this.inReady.has(db)){this.ready.push(db);this.inReady.add(db);}return true;}
  cancel(id){for(let db=0;db<16;db++){const i=this.queues[db].indexOf(id);if(i>=0){this.queues[db].splice(i,1);this.live.delete(id);if(!this.queues[db].length&&this.inReady.has(db)){this.ready=this.ready.filter(x=>x!==db);this.inReady.delete(db);}return true;}}return false;}
  dispatch(){if(!this.ready.length)return null;const db=this.ready.shift();this.inReady.delete(db);const id=this.queues[db].shift();this.live.delete(id);if(this.queues[db].length){this.ready.push(db);this.inReady.add(db);}return{db,id};}
}
test('independent 200-session model preserves physical bounds and FIFO',()=>{const random=rng(0x53514c31),m=new Model(),last=Array(16).fill(0);for(let step=0;step<100000;step++){const op=random()%3,db=random()%16,id=step*200+(random()%200)+1;if(op===0)m.submit(db,id);else if(op===1&&m.live.size){const pick=Array.from(m.live)[random()%m.live.size];m.cancel(pick);}else{const x=m.dispatch();if(x){assert.ok(x.id>last[x.db]);last[x.db]=x.id;}}assert.ok(m.live.size<=1024);for(const q of m.queues)assert.ok(q.length<=256);assert.equal(m.live.size,m.queues.reduce((n,q)=>n+q.length,0));}console.log('model-seed=0x53514c31 maxQueued='+m.maxQueued);});
test('deficit round robin gives every ready database one quantum per round',()=>{const m=new Model();for(let db=0;db<8;db++)for(let i=0;i<100;i++)assert.equal(m.submit(db,db*1000+i+1),true);for(let round=0;round<100;round++){const seen=new Set();for(let quantum=0;quantum<8;quantum++)seen.add(m.dispatch().db);assert.equal(seen.size,8);}});
test('overflow rejection never creates a tombstone',()=>{const m=new Model();for(let i=1;i<=256;i++)assert.equal(m.submit(0,i),true);assert.equal(m.submit(0,999),false);assert.equal(m.live.has(999),false);assert.equal(m.queues[0].length,256);});
