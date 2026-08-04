'use strict';
const { DatabaseSync } = require('node:sqlite');
const VERSION = 1;
let db = null;
let config = null;
let expected = 1;

function send(id, kind, body = {}) { process.send({ v: VERSION, id, kind, ...body }); }
function sqliteKind(error) {
  const n = Number(error && error.errcode);
  if (n === 5) return 'busy';
  if (n === 6) return 'locked';
  if (n === 8) return 'read-only';
  if (n === 11) return 'corrupt';
  if (n === 17) return 'schema-changed';
  if (n >= 19 && n < 20) return 'constraint';
  return 'io-failure';
}
function fail(id, error, entered) {
  send(id, 'error', { entered, errorKind: sqliteKind(error), errorCode: Number(error && error.errcode) || 0, errorMessage: String(error && error.message || 'SQLite operation failed').slice(0, 512) });
}
function assertAuto(expectedTransaction) {
  if (!!db.isTransaction !== expectedTransaction) throw Object.assign(new Error('autocommit invariant violated'), { errcode: 21 });
}
function decode(v) {
  switch (v.t) {
    case 'null': return null;
    case 'integer': return BigInt(v.v);
    case 'real': if (!Number.isFinite(v.v)) throw new TypeError('non-finite REAL'); return v.v;
    case 'text': return v.v;
    case 'blob': return Uint8Array.from(v.v);
    default: throw new TypeError('invalid binding');
  }
}
function encode(v) {
  if (v === null) return { t: 'null' };
  if (typeof v === 'bigint') return { t: 'integer', v: String(v) };
  if (typeof v === 'number') return { t: 'real', v };
  if (typeof v === 'string') return { t: 'text', v };
  if (v instanceof Uint8Array) return { t: 'blob', v: Array.from(v) };
  throw new TypeError('unsupported SQLite value');
}
function significantTail(sql) {
  let quote = null, line = false, block = false, firstSemi = -1;
  for (let i = 0; i < sql.length; i++) {
    const c = sql[i], n = sql[i + 1];
    if (line) { if (c === '\n' || c === '\r') line = false; continue; }
    if (block) { if (c === '*' && n === '/') { block = false; i++; } continue; }
    if (quote) { if (c === quote) { if (n === quote) i++; else quote = null; } continue; }
    if ((c === "'" || c === '"' || c === '`')) { quote = c; continue; }
    if (c === '[') { quote = ']'; continue; }
    if (c === '-' && n === '-') { line = true; i++; continue; }
    if (c === '/' && n === '*') { block = true; i++; continue; }
    if (c === ';') { firstSemi = i; break; }
  }
  if (firstSemi < 0) return false;
  const tail = sql.slice(firstSemi + 1).replace(/--[^\r\n]*(?:\r?\n|$)|\/\*[\s\S]*?\*\//g, '').trim();
  return tail.length > 0;
}
function statement(req) {
  if (significantTail(req.sql)) throw Object.assign(new Error('significant SQL tail'), { errcode: 1 });
  const stmt = db.prepare(req.sql);
  return { stmt, args: req.bindings.map(decode) };
}
function open(req) {
  if (db) return;
  config = req.options;
  db = new DatabaseSync(config.path, { readOnly: config.readOnly, timeout: config.busyTimeout, readBigInts: true, returnArrays: true });
  db.exec('PRAGMA foreign_keys=ON');
  if (!config.readOnly) db.exec('PRAGMA journal_mode=WAL');
  db.exec('PRAGMA synchronous=FULL');
  db.exec('PRAGMA temp_store=MEMORY');
  assertAuto(false);
}
function handle(req) {
  const id = req.id;
  if (req.v !== VERSION || id !== expected++) throw new Error('protocol sequence');
  let entered = false;
  try {
    if (req.op === 'open') { open(req); send(id, 'done'); return; }
    if (!db) throw new Error('not open');
    const inTx = req.inTransaction === true;
    assertAuto(inTx);
    if (req.op === 'execute') {
      const { stmt, args } = statement(req); entered = true;
      const r = stmt.run(...args); assertAuto(inTx);
      send(id, 'done', { changedRows: Number(r.changes), lastInsertRowId: String(r.lastInsertRowid) }); return;
    }
    if (req.op === 'query') {
      const { stmt, args } = statement(req); entered = true;
      const columns = stmt.columns().map(c => c.name);
      const iterator = stmt.iterate(...args); const rows = []; let bytes = 0;
      for (;;) {
        assertAuto(inTx); const item = iterator.next(); assertAuto(inTx);
        if (item.done) break;
        const row = item.value.map(encode); bytes += Buffer.byteLength(JSON.stringify(row));
        if (rows.length >= req.rowLimit || bytes > req.byteLimit) { iterator.return(); assertAuto(inTx); throw Object.assign(new Error('collection limit exceeded'), { errcode: 18 }); }
        rows.push(row);
      }
      assertAuto(inTx); send(id, 'done', { columns, rows }); return;
    }
    if (req.op === 'begin') { db.exec('BEGIN ' + req.mode); assertAuto(true); send(id, 'done'); return; }
    if (req.op === 'commit') { entered = true; db.exec('COMMIT'); assertAuto(false); send(id, 'done'); return; }
    if (req.op === 'rollback') { db.exec('ROLLBACK'); assertAuto(false); send(id, 'done'); return; }
    throw new Error('unknown operation');
  } catch (error) {
    try { if (db && db.isTransaction && req.op !== 'execute' && req.op !== 'query') db.exec('ROLLBACK'); } catch (_) {}
    fail(id, error, entered);
  }
}
process.on('message', handle);
process.on('disconnect', () => { try { if (db && db.isTransaction) db.exec('ROLLBACK'); } catch (_) {} try { if (db) db.close(); } catch (_) {} process.exit(0); });
process.send({ v: VERSION, id: 0, kind: 'ready', creditMessages: 1, creditBytes: 8388608 });
