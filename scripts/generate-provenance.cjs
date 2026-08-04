'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto'),os=require('node:os');
const root=path.resolve(__dirname,'..'),sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex'),archive=path.join(root,'build/provenance.tar.gz');
cp.execFileSync(process.execPath,['scripts/build-archive.cjs',archive],{cwd:root,stdio:'inherit'});
const commit=cp.execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),status=cp.execFileSync('git',['status','--porcelain','--untracked-files=no'],{cwd:root,encoding:'utf8'}).trim();
const body={schema:1,commit,dirty:status.length>0,generatedAt:new Date().toISOString(),platform:{os:process.platform,arch:os.arch(),node:process.version,sqlite:process.versions.sqlite},toolchain:{elmCompilerCommit:'76bbe44424106c96f915cb24cd7f50d69f5cee0e',elmCompilerSha256:'69987adf7062562b6e6dfd60b6709be3a06feeb90b096b9c84f673f2b97d8654'},artifacts:{workerSha256:sha(path.join(root,'runtime/worker.cjs')),supervisorSha256:sha(path.join(root,'runtime/supervisor.cjs')),assembledKernelSha256:sha(path.join(root,'src/Elm/Kernel/SchelmSqlite.js')),archiveSha256:sha(archive)},verify:'node scripts/verify.cjs'};
fs.writeFileSync(path.join(root,'docs/provenance/final.json'),JSON.stringify(body,null,2)+'\n');console.log(JSON.stringify(body,null,2));
