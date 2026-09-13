# 00 — Node SQLite kernel feasibility

Status: first-turn spike, 2026-04-01. This records executable evidence and narrows the design. It is not a public implementation.

## Question and runtime

Can a private Elm 0.19.2 kernel package on Node 24 safely expose the mechanics needed by the harness cron store and, later, the session index?

Pinned probe runtime:

- Node `v24.4.1`, built-in `node:sqlite`, SQLite `3.50.2`;
- private Elm 0.19.2 compiler fork, real `make` and `make --optimize` artifacts;
- `DatabaseSync` configured with `timeout`, `readBigInts = true`, and `returnArrays = true`;
- an Elm worker calls only a test-only kernel package. The fixture is deliberately outside the proposed production package.

Run from this commit:

```sh
node scripts/prepare-feasibility-overlay.cjs
compiler=$(node -e "process.stdout.write(require('./scripts/toolchain.cjs').compiler())")
(cd feasibility/app && ELM_HOME=../../build/elm-home "$compiler" make Main.elm --output=../../build/feasibility-debug.js)
(cd feasibility/app && ELM_HOME=../../build/elm-home "$compiler" make Main.elm --output=../../build/feasibility-optimize.js --optimize)
node feasibility/run.cjs
```

The last command exits zero only if both generated artifacts satisfy the probe. Generated databases and JS are ignored build evidence, not package sources.

## Results

Both debug and optimized Elm artifacts proved:

1. **Connection and preparation:** open, PRAGMAs, schema creation, and `prepare` work through a package kernel.
2. **Binding and stepping:** positional `BigInt`, `String`, `Uint8Array`, `Float`, and `null`-capable rows cross the boundary. `run`, `get`, and iterator `next` work. The probe received integer `1`, text, blob `[1,2,3]`, real `1.5`, and null without JSON conversion.
3. **Cursor reset:** `iterator.return()` returns `{ done = true }` and calls `sqlite3_reset` in Node's source. This is a usable deterministic cursor-release acknowledgement.
4. **Transactions:** ordinary `BEGIN IMMEDIATE`/`COMMIT` and `ROLLBACK` work. A rolled-back row was absent and a committed row present.
5. **Typed error facts:** UNIQUE violation surfaced `ERR_SQLITE_ERROR`, extended code `2067` (`SQLITE_CONSTRAINT_UNIQUE`); lock contention surfaced extended code `5` (`SQLITE_BUSY`) after the configured timeout.
6. **Connection finalization:** `DatabaseSync.close()` closes the handle and makes an old statement fail with `ERR_INVALID_STATE`. Node's implementation first finalizes every tracked statement, deletes sessions, then calls `sqlite3_close_v2`.
7. **Crash rollback:** a separate process was killed with `SIGKILL` while holding an uncommitted write transaction and running a long recursive query. Reopening observed zero inserted rows in debug and optimize runs.
8. **Main-loop isolation:** while that separate process was blocked in synchronous SQLite, the parent continued ticking every 5 ms (29–30 ticks in roughly 153–155 ms).

Representative evidence is retained by `node feasibility/run.cjs`; the checked fixture itself is the reproducible evidence source.

## Source-level findings that change the API

Node 24.4.1's public API and `src/node_sqlite.cc` establish these facts:

- `DatabaseSync`, `StatementSync.run/get/all/iterate`, and most transaction SQL are synchronous. A call blocks the JavaScript thread that invoked it.
- There is **no public `DatabaseSync.interrupt()`** in v24.4.1. Node issue #62227 requests `sqlite3_interrupt()` exposure.
- There is **no public statement `finalize()` or statement `Symbol.dispose`**. `StatementSync::~StatementSync` finalizes on collection, and `DatabaseSync.close()` eagerly calls `FinalizeStatements()` before close.
- `StatementSyncIterator.return()` resets the statement; iterator completion also resets it.
- each statement operation resets before binding/stepping and has scope cleanup to reset afterward; bindings are cleared before each bind.
- `DatabaseSync.isTransaction` reflects `sqlite3_get_autocommit` and is useful as a boundary invariant, not as transaction policy.
- Node's SQLite module is stability 1.1 (active development) in 24.4.1. The package must pin and compatibility-test its minimum host rather than promise all Node 24 point releases are identical.

Primary references:

- Node 24.4.1 SQLite docs: <https://nodejs.org/download/release/v24.4.1/docs/api/sqlite.html>
- Node 24.4.1 JS shim: <https://github.com/nodejs/node/blob/v24.4.1/lib/sqlite.js>
- Node 24.4.1 native implementation: <https://github.com/nodejs/node/blob/v24.4.1/src/node_sqlite.cc>
- interruption API gap: <https://github.com/nodejs/node/issues/62227>
- SQLite result and extended result codes: <https://www.sqlite.org/rescode.html>

## Interruption conclusion

A cooperative Elm cancellation token cannot interrupt an already-entered synchronous SQLite call. It can only prevent the next call. Ordinary `worker.terminate()` was also not a dependable bounded escape in the initial probe: termination waited behind the native synchronous call and the overall run timed out.

A **killable child process** is the only interruption boundary proved here. `SIGKILL` stopped the query promptly and SQLite rolled back the open transaction on the next connection. Therefore:

- direct mode may be suitable only for short, bounded daemon-local operations and must document event-loop blocking;
- the broad v1 safe path must execute a database session in a dedicated child process (or a separately proven equivalent), with IPC and a kill ladder;
- `cancel` means “cancellation requested”; only child exit is physical interruption acknowledgement;
- worker threads may isolate normal latency, but v1 must not claim they provide hard interruption;
- killing a process provides rollback, not proof of durable commit outcome if death races a commit acknowledgement. The result must represent `CommitOutcomeUnknown` where that race is possible.

## Resource-finalization conclusion

Connection close is deterministic and transitively finalizes all statements. Cursor return/reset is deterministic. Individual statement finalization is not publicly acknowledgeable on Node 24.4.1. A v1 API must therefore not claim that releasing one statement has physically finalized it. It may:

1. bound and own prepared statements under one connection/session;
2. acknowledge that a statement became unreachable to the package registry;
3. deterministically finalize all statements by closing that connection;
4. use short-lived child sessions where process exit is the final backstop.

This limitation rules out an API that hands raw long-lived `StatementSync` identity to arbitrary Elm code with a `finalize : Statement -> ...` promise.

## Feasibility verdict

**Feasible with a process-owned session boundary and narrowed guarantees.** Connection, prepare, bind, step, transaction, cursor reset, error facts, and connection-wide finalization are proven in real debug/optimize Elm artifacts. In-process hard interruption and per-statement physical finalization are not feasible on Node 24.4.1's public API. The design must encode those absences rather than paper over them.

No production implementation is authorized by this document. The two independent adversarial reviews, revisions, and property-test plan required by the Schelm constitution still precede implementation.
