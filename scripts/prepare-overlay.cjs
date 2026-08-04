"use strict";
const fs=require("node:fs"),path=require("node:path"),cp=require("node:child_process"),crypto=require("node:crypto"),toolchain=require("./toolchain.cjs");
const root=path.resolve(__dirname,".."),tool=toolchain.config,archive=toolchain.packageSeed();
const key=crypto.createHash("sha256").update(JSON.stringify(tool)).digest("hex"),cache=path.join(root,"build/cache",key),lock=cache+".lock";
fs.mkdirSync(path.dirname(cache),{recursive:true});
if(!fs.existsSync(cache)){
  try{fs.mkdirSync(lock);}catch(e){if(e.code!=="EEXIST")throw e;const until=Date.now()+30000;while(fs.existsSync(lock)&&Date.now()<until)Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,50);if(!fs.existsSync(cache))throw new Error("cache population lock timed out");}
  if(fs.existsSync(lock))try{const temp=cache+`.tmp-${process.pid}`;fs.rmSync(temp,{recursive:true,force:true});fs.mkdirSync(temp,{recursive:true});cp.execFileSync("tar",["xzf",archive,"-C",temp]);const extracted=path.join(temp,"0.19.2");fs.renameSync(extracted,path.join(temp,"content"));fs.renameSync(path.join(temp,"content"),cache);fs.rmSync(temp,{recursive:true,force:true});}finally{fs.rmSync(lock,{recursive:true,force:true});}
}
const home=fs.mkdtempSync(path.join(root,"build/elm-home-"));fs.mkdirSync(path.join(home,"0.19.2"),{recursive:true});fs.cpSync(cache,path.join(home,"0.19.2"),{recursive:true});
const packages=path.join(home,"0.19.2/packages");
function install(name,source,entries){const [author,project]=name.split("/"),dest=path.join(packages,author,project,"1.0.0");fs.mkdirSync(dest,{recursive:true});for(const entry of entries)fs.cpSync(path.join(source,entry),path.join(dest,entry),{recursive:true});}
install("sjalq/schelm-node-sqlite",root,["src","elm.json","README.md","LICENSE"]);
let registry=fs.readFileSync(path.join(packages,"registry.dat"));
function entries(buf){let pos=16,n=Number(buf.readBigUInt64BE(8)),xs=[];for(let i=0;i<n;i++){const start=pos,la=buf[pos++],author=buf.subarray(pos,pos+la).toString();pos+=la;const lp=buf[pos++],project=buf.subarray(pos,pos+lp).toString();pos+=lp;const major=buf[pos++];if(major===255)throw new Error("large version unsupported");pos+=2;const previous=Number(buf.readBigUInt64BE(pos));pos+=8+3*previous;xs.push({author,project,start});}return{n,xs};}
function add(buf,author,project){const {n,xs}=entries(buf),key=`${author}/${project}`;if(xs.some(x=>`${x.author}/${x.project}`===key))return buf;const index=xs.findIndex(x=>`${x.author}/${x.project}`>key),at=index<0?buf.length:xs[index].start;const entry=Buffer.concat([Buffer.from([Buffer.byteLength(author)]),Buffer.from(author),Buffer.from([Buffer.byteLength(project)]),Buffer.from(project),Buffer.from([1,0,0]),Buffer.alloc(8)]),out=Buffer.concat([buf.subarray(0,at),entry,buf.subarray(at)]);out.writeBigUInt64BE(buf.readBigUInt64BE(0)+1n,0);out.writeBigUInt64BE(BigInt(n+1),8);return out;}
registry=add(registry,"sjalq","schelm-node-sqlite");fs.writeFileSync(path.join(packages,"registry.dat"),registry);
process.stdout.write(home);
