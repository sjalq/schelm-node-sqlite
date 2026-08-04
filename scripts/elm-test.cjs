'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),toolchain=require('./toolchain.cjs');
const entry=toolchain.config.elmTest,archive=path.join(toolchain.root,'vendor/toolchain',entry.archive),dest=path.join(toolchain.root,'build/toolchain/elm-test-'+entry.version),binary=path.join(dest,'package/bin/elm-test');
if(toolchain.sha(archive)!==entry.sha256)throw new Error('elm-test archive integrity failure');
if(!fs.existsSync(binary)){fs.mkdirSync(dest,{recursive:true});cp.execFileSync('tar',['xzf',archive,'-C',dest]);}
const result=cp.spawnSync(process.execPath,[binary,'--compiler',toolchain.compiler(),...process.argv.slice(2)],{cwd:toolchain.root,env:process.env,stdio:'inherit'});process.exit(result.status===null?1:result.status);
