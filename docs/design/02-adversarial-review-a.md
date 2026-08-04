# 02 — Adversarial review A

Verdict: **reject `01-design.md`**. The feasibility result is useful, but the proposed public ownership model is impossible in Elm as written and the process/IPC design is not complete enough to implement safely. No production implementation may start from design 01.

## A1. Opaque resource handles can still escape

Design 01 says `Connection`, `Statement`, `Cursor`, and `Transaction` values are useful only inside `Program` and cannot escape because `withDatabase` returns only `a`. That is false: `a` is chosen by the caller. Elm has neither rank-2 scope quantification nor linear/affine types. A caller can return an opaque handle, put it in a record, duplicate it, or retain it in a closure. Phantom state parameters do not prevent any of those actions.

Runtime nonces can reject stale use, but that is not the compile-time ownership guarantee claimed. The public API must expose no resource identity at all. Public values may describe SQL work; all connection, prepared-statement, transaction, cursor, request, generation, and process ids must remain internal to the package interpreter.

## A2. One module conflates three vocabularies

The proposed module mixes database execution, SQL values, and row-decoder combinators. This is not a tiny teachable API and creates collisions such as `succeed`, `fail`, `map`, and `andThen` for both program and decoder construction.

Split row decoding into `Schelm.Node.Sqlite.Decode`, with an opaque `Decoder a` executed in parent Elm. Keep SQL values and declarative operations in the main module. If transaction composition needs its own namespace, use `Schelm.Node.Sqlite.Transaction`; do not expose infrastructure handles to make one module look smaller.

## A3. `Program` has no compiler-legal execution design

Design 01 calls `Program` “free/selective” but does not define its constructors, interpreter, effect-manager ownership, cancellation route, or how a decoder function survives a JS/child boundary. That leaves the most important correctness mechanism unspecified.

The revision must define one exact owner: an Elm effect manager/interpreter in the parent process. A `Query a` retains its Elm `Decoder a` in parent Elm; only tagged row facts cross IPC. A transaction is a declarative `TransactionProgram a` interpreted sequentially while the manager holds an internal lease. Kernel JS may frame bytes and spawn/kill children, but may not choose transaction, retry, queue, recovery, or fairness policy.

## A4. Arbitrary SQL defeats the transaction state machine

`Sql` is cooperative arbitrary text. A caller can submit `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, or multi-statement transaction control outside the typed transaction API. It can also change autocommit unexpectedly through a supposedly ordinary command. The opaque transaction token then ceases to describe physical SQLite state.

Choose and prove a narrow rule. Prepared operations must contain exactly one SQLite statement and reject transaction-control as the first significant token using a bounded, tested lexer. Multi-statement `exec` must not be a public escape hatch. The child must check `database.isTransaction` before and after every operation against the interpreter's expected state. Any mismatch poisons the session, attempts rollback, closes the database, and requires a fresh generation. Do not attempt a partial SQL parser or claim hostile SQL containment.

## A5. Unknown outcome is not commit-only

Design 01 models `CommitOutcomeUnknown`, but an INSERT, UPDATE, DELETE, DDL, mutating PRAGMA, or statement with `RETURNING` can physically complete before its response is observed. If the child or IPC dies in that interval, retry can duplicate an effect even outside an explicit transaction.

Every dispatched operation that may mutate needs a dispatch/physical-return/response-observed boundary. Since arbitrary cooperative SQL prevents complete read-only classification on Node 24.4.1, every `Command` is potentially mutating and every `Query` must conservatively be treated as potentially mutating unless the database itself is opened read-only. Unacknowledged potentially mutating work settles as `OperationOutcomeUnknown`, carrying no bound values or SQL text. An unacknowledged explicit transaction settles as `TransactionOutcomeUnknown`.

## A6. Process-per-scope is operationally incoherent

Spawning a process for every small cron `get` or `upsert` makes process startup, SQLite open, WAL setup, and schema checks dominate the operation. It also creates avoidable lock churn and has no admission control. Design 01 postpones pooling while depending on a broad package that must survive many sessions.

Choose now: a persistent supervised child per active database, bounded by a parent-owned pool. Specify global and per-database queue bounds, FIFO ordering, cross-database fairness, idle eviction, transaction exclusivity, overload errors, and what happens when all workers are busy. Process overhead needs benchmark gates, not intuition.

## A7. “Child process” does not solve parent death or orphans

A child blocked in synchronous SQLite cannot process IPC disconnect, heartbeat, `SIGTERM`, or cooperative rollback. If the daemon dies, a plain Node child can remain blocked and orphaned. Design 01's kill ladder assumes the parent is alive to climb it.

A separate responsive supervisor/reaper must own each blocking database worker. Parent IPC closure must cause that supervisor to kill and reap the worker even when the worker event loop is blocked. Startup must reap stale owned children from the prior parent generation without killing unrelated processes. Define ownership records, process-group boundaries, parent-generation identity, startup validation, and bounded escalation. Parent death during a transaction must be a tested crash-recovery path.

## A8. IPC is wholly underspecified

“Tagged requests with ids” is not a protocol. Missing items include:

- version negotiation and incompatible-version failure;
- framing, maximum frame length, partial frames, extra bytes, and malformed tags;
- parent and child generation ids across restart;
- request-id reuse/wrap behavior;
- exact BigInt and blob representation;
- duplicate/late response behavior;
- row streaming demand and pipe backpressure;
- aggregate rows/scalars/bytes meters;
- transaction begin/action/decision frames;
- close, cancel, poison, supervisor exit, and worker exit facts;
- sanitization and whether SQL/bind values can leak into diagnostics.

The revision must provide a finite protocol algebra and state table. The worker must reject malformed or over-limit frames before allocating their declared payloads. IPC structural validation may live in JS as a boundary fact; settlement and policy remain Elm.

## A9. `all()` violates the intended bound if delegated to Node

Node's `StatementSync.all()` materializes every row before the package can apply its own row/result cap. Rejecting after return is not a work or memory bound. The same problem occurs if a child accumulates rows and then sends one response.

Production query execution must use `iterate()`/`next()` only. Before each row crosses IPC, the worker must meter row count, scalar count, row bytes, aggregate bytes, and blob bytes. Parent demand permits one row at a time; pipe backpressure must pause reads/writes. Public `all` may ergonomically collect in parent Elm, but only under an explicit validated `CollectionLimit`, and it must drive the same cursor protocol.

## A10. WAL, busy, and recovery ownership is incomplete

WAL mode does not eliminate writer contention, and a synchronous busy timeout blocks the database worker. Define a finite timeout, classify numeric `BUSY`/`LOCKED` variants, and leave retry to Elm. A worker crash may leave WAL/SHM files; reopening should let SQLite recover them, not unlink them. Corruption/rebuild remains application policy. Schema setup must not run on every operation, and the package must not hide migration policy in child startup.

The persistent-worker design also needs a rule for external processes modifying schema, stale prepared statements, and connection poisoning after autocommit mismatch or protocol failure.

## A11. Transaction consume semantics are still pretend linearity

Consuming and returning `Transaction Active` is ergonomic but callers can duplicate the old value. The runtime generation check is the real guarantee. Exposing the token adds a false proof and unnecessary vocabulary.

Use a `TransactionProgram a` with private constructors. `Transaction.execute`, `query`, and combinators append/interleave declarative actions; the parent interpreter owns the current internal generation. Commit occurs only after the program produces a value successfully. Any SQL/decode/program failure rolls back. If callers need deliberate rollback, expose a declarative terminal combinator/result that cannot be followed by more actions—not a token.

## A12. Cancellation and acknowledgement are not total

The design does not distinguish:

1. accepted into the parent queue;
2. dispatched to supervisor/worker;
3. entered SQLite;
4. SQLite physically returned;
5. valid response decoded by parent boundary;
6. parent Elm interpreter observed it;
7. application task settled.

Cancellation before dispatch can be `CancelledBeforeDispatch`. After dispatch, the physical outcome depends on operation kind and acknowledgement. Killing after physical return but before parent observation is unknown for mutation. A decoder failure after the parent observed all row facts is known SQL success plus decode failure, not an unknown SQL outcome. The revised state machine must distinguish these facts.

## A13. Broad ergonomics and harness migration are still vague

The design names `command`, `query`, `one`, `all`, and migrations, but gives no complete examples or compile-legal signatures after removing handles. Cron and session-index integration need exact authority transitions: old JS in production before cutover, differential dual execution only in tests, then one package authority. There must be no fallback that gives old and new writers simultaneous production authority.

Cron first must prove process amortization and repeated-operation behavior. Index second must prove long cursor bounds, FTS/schema handling, transaction exclusivity, and rebuild policy remaining Elm.

## Required revision

Before a second review, revision A must:

1. remove all public resource handles and split `Decode`;
2. define a compiler-legal declarative `Command`, `Query`, and `TransactionProgram` API;
3. make parent Elm the exact interpreter and policy owner;
4. define single-statement/transaction-control rules plus autocommit poisoning;
5. represent unknown outcome for every unacknowledged potentially mutating operation;
6. choose a persistent per-database supervised worker design with bounded admission and fairness;
7. specify a complete versioned IPC protocol, generations, binary framing, BigInt/blob encoding, demand, and backpressure;
8. meter rows/scalars/bytes in the worker before IPC and prohibit production `all()`;
9. specify crash recovery, orphan reaping, parent death, WAL/busy behavior, and acknowledgement races;
10. provide broad ergonomic examples, cron-first/index-second authority plans, process-overhead benchmarks, and executable properties.

Until this revision survives independent review B, production implementation remains rejected.
