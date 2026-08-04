"use strict";
const fs=require("node:fs"),vm=require("node:vm");
const [file,dbPath]=process.argv.slice(2);const context={console,process,require,setTimeout,clearTimeout,Buffer,URL};vm.createContext(context);vm.runInContext(fs.readFileSync(file,"utf8"),context,{filename:file});process.send?.({type:"started"});const app=context.Elm.Main.init({flags:{mode:"long",path:dbPath}});app.ports.report.subscribe(raw=>{process.send?.({type:"result",raw});process.exit(2);});
