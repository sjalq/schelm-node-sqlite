/*
import Elm.Kernel.Scheduler exposing (binding, succeed)
*/
var $sqlite = require("node:sqlite");
var $fs = require("node:fs");

function $probeBasic(path) {
  try { $fs.unlinkSync(path); } catch (_) {}
  var db = new $sqlite.DatabaseSync(path, { timeout: 25, readBigInts: true, returnArrays: true });
  var facts = { node: process.version, sqlite: process.versions.sqlite, sequence: [] };
  try {
    db.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE item(id INTEGER PRIMARY KEY, name TEXT UNIQUE, payload BLOB, score REAL);");
    facts.sequence.push("open");
    var insert = db.prepare("INSERT INTO item(id,name,payload,score) VALUES(?,?,?,?)");
    facts.sequence.push("prepare");
    var result = insert.run(1n, "one", new Uint8Array([1,2,3]), 1.5);
    facts.sequence.push("bind+step");
    facts.changeCount = Number(result.changes);
    var select = db.prepare("SELECT id,name,payload,score,NULL FROM item ORDER BY id");
    var row = select.get();
    facts.row = { id: String(row[0]), name: row[1], blob: Array.from(row[2]), score: row[3], nil: row[4] };
    var iter = select.iterate();
    var first = iter.next();
    facts.cursorFirst = !first.done && String(first.value[0]) === "1";
    facts.cursorReturn = iter.return().done;
    facts.sequence.push("cursor-step+return");

    db.exec("BEGIN IMMEDIATE");
    db.prepare("INSERT INTO item(id,name,payload,score) VALUES(2,'two',X'',2.0)").run();
    db.exec("ROLLBACK");
    facts.rollback = db.prepare("SELECT count(*) FROM item").get()[0] === 1n;
    db.exec("BEGIN IMMEDIATE");
    db.prepare("INSERT INTO item(id,name,payload,score) VALUES(2,'two',X'',2.0)").run();
    db.exec("COMMIT");
    facts.commit = db.prepare("SELECT count(*) FROM item").get()[0] === 2n;
    facts.sequence.push("transaction");

    try { insert.run(3n, "one", new Uint8Array([]), 0); }
    catch (error) { facts.constraint = { code: error.code || "", errcode: error.errcode || 0, errstr: error.errstr || "" }; }
    var lock = new $sqlite.DatabaseSync(path, { timeout: 10, readBigInts: true, returnArrays: true });
    db.exec("BEGIN IMMEDIATE");
    try { lock.prepare("INSERT INTO item(id,name,payload,score) VALUES(4,'four',X'',4)").run(); }
    catch (error) { facts.busy = { code: error.code || "", errcode: error.errcode || 0, errstr: error.errstr || "" }; }
    db.exec("ROLLBACK");
    lock.close();

    var stale = db.prepare("SELECT 1");
    db.close();
    facts.sequence.push("close-finalizes-statements");
    try { stale.get(); } catch (error) { facts.staleStatement = error.code || error.name || "error"; }
    facts.closed = !db.isOpen;
    facts.hasInterrupt = typeof db.interrupt === "function";
    facts.statementHasFinalize = typeof stale.finalize === "function" || typeof stale[Symbol.dispose] === "function";
    facts.ok = facts.changeCount === 1 && facts.rollback && facts.commit && facts.closed && !facts.hasInterrupt && !facts.statementHasFinalize;
    return facts;
  } finally {
    if (db.isOpen) db.close();
  }
}

function $probeLong(path) {
  var db = new $sqlite.DatabaseSync(path, { timeout: 25, readBigInts: true, returnArrays: true });
  db.exec("PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS interruption_probe(value TEXT); BEGIN IMMEDIATE; INSERT INTO interruption_probe VALUES('uncommitted');");
  db.prepare("WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x < 1000000000) SELECT sum(x) FROM n").get();
  db.exec("COMMIT");
  db.close();
  return { ok: false, unexpectedCompletion: true };
}

var _SchelmSqliteFeasibility_probe = F2(function(mode, path) {
  return __Scheduler_binding(function(callback) {
    var facts;
    try { facts = mode === "long" ? $probeLong(path) : $probeBasic(path); }
    catch (error) { facts = { ok: false, thrown: { name: error.name || "", code: error.code || "", message: String(error.message || error) } }; }
    callback(__Scheduler_succeed(JSON.stringify(facts)));
  });
});
