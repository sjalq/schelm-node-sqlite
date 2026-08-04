'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'..'),out=process.argv[2]||path.join(root,'build/schelm-node-sqlite-1.0.0.tar.gz');
const files=cp.execFileSync('git',['ls-files'],{cwd:root,encoding:'utf8'}).trim().split('\n').filter(x=>x&&!x.startsWith('docs/provenance/final.json'));
fs.mkdirSync(path.dirname(out),{recursive:true});
const list=path.join(root,'build/archive-files.txt');fs.mkdirSync(path.dirname(list),{recursive:true});fs.writeFileSync(list,files.join('\n')+'\n');
const tarPath=out.replace(/\.gz$/,'');cp.execFileSync('tar',['--sort=name','--mtime=UTC 2020-01-01','--owner=0','--group=0','--numeric-owner','-cf',tarPath,'-T',list],{cwd:root});const zipped=cp.execFileSync('gzip',['-n','-c',tarPath]);fs.writeFileSync(out,zipped);fs.rmSync(tarPath);
console.log(JSON.stringify({path:out,sha256:crypto.createHash('sha256').update(fs.readFileSync(out)).digest('hex'),files:files.length}));
