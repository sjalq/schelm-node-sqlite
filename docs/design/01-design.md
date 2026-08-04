# 01 — `schelm-node-sqlite` broad v1 design

Status: first-turn design only. No production implementation is authorized.

## 1. Goal, first slices, and exclusions

V1 is a Node-only Elm kernel package for typed SQLite mechanics: opening one process-owned session, prepared parameter binding, typed row decoding, bounded cursor stepping, transactions, cancellation at a process boundary, and deterministic session cleanup.

The first harness slice is **cron-store**, because it needs a small schema and only upsert/get/list over JSON plus indexed scalar mirrors. The second slice is **session-index**, which adds explicit transactions, larger scans, FTS5, incremental watermarks, corruption recovery, and busy handling. The integration adapter must preserve “facts and verbs in kernel; decisions in Elm.” Cron status normalization, next-run policy, index ranking, chunking, schema-version recovery policy, and migration contents remain ordinary Elm.

V1 is deliberately broader than cron: it must coherently serve ordinary Node SQLite applications without embedding harness policy.

Non-goals: ORM/query builder, schema DSL, migration framework, automatic retry, automatic transaction nesting, connection pool, cross-process distributed transactions, extensions, custom SQL functions, backup/session changesets, replication, encryption, browser SQLite, arbitrary SQL cancellation inside the daemon thread, or SQL parsing/type inference.

## 2. Teachability: one scoped session

The core mental model is:

```text
withDatabase config
  -> one owned SQLite session in a killable child
  -> prepare typed SQL
  -> bind values and execute/query
  -> optionally enter one transaction
  -> close/kill child and make every resource absent
```

Three ordinary examples must fit on one page: execute schema SQL, query users with a row decoder, and run a transaction. Users should not need to understand `DatabaseSync`, V8 objects, IPC, or SQLite C handles.

## 3. Public module shape

Names remain reviewable, but the ownership boundaries do not.

```elm
module Schelm.Node.Sqlite exposing
    ( Database, database, memory
    , OpenOptions, defaultOptions, withBusyTimeout, readOnly
    , Program, succeed, fail, map, andThen
    , withDatabase, Cancel
    , Connection
    , Sql, sql
    , Value, null, int, int64, float, text, blob
    , Statement, prepare, release
    , Command, command, execute, Change
    , Query, query, all, one, maybeOne, cursor
    , Row, Decoder, DecodeError, field, index
    , string, integer, integer64, number, bytes, nullable
    , Cursor, next, stop
    , Transaction, transaction, executeIn, allIn, oneIn, maybeOneIn, cursorIn
    , Error, ErrorKind(..), errorKind, sqliteCode, errorMessage
    )
```

The actual execution surface is a package-owned `Program error value`, interpreted in one child session:

```elm
type Program error value              -- constructors private
type Connection state                 -- constructor private; never returned from withDatabase
type Statement access row             -- constructor private; prepared statement id + decoder
type Cursor access row                -- constructor private; live cursor id
type Transaction state                -- constructor private; transaction token

withDatabase : OpenOptions -> Program Error a -> Task Error a
```

A first hostile review must choose whether caller-domain errors are supported directly (`Program e a`) or SQL-only failure stays `Program Error a`; no kernel ABI depends on that choice.

`Connection`, `Statement`, `Transaction`, and `Cursor` states are phantom-typed and constructors remain private. They are useful only inside the scoped `Program`; none can escape into application model state because `withDatabase` returns only `a`, and resource-bearing values are not encodable as `a` by the interpreter. If Elm's rank-2 limitation prevents proving that last statement at the public type level, the API must instead expose declarative `Command`/`Query` values with internal registry ownership—never pretend a phantom alone prevents escape.

### Typed SQL and values

```elm
type Sql = Sql String                  -- opaque; validates NUL/empty once
sql : String -> Result SqlError Sql

type Value
    = Null
    | Integer Int
    | Integer64 Int64                  -- package-defined exact signed 64-bit value
    | Real Float
    | Text String
    | Blob Bytes
```

`Sql` is not an injection-proof SQL AST. It prevents accidental empty/NUL input and keeps SQL distinct from ordinary text. Dynamic data always travels as `Value` bindings. Schema identifiers cannot be bound; applications needing dynamic identifiers must validate against their own finite algebra before constructing `Sql`.

`Int64` cannot be Elm `Int`: Node is configured with `readBigInts = true`, and the boundary uses exact signed decimal/hi-low representation. Conversion to `Int` is checked. Unsafe integer truncation is impossible.

Named and positional binding must not coexist in one value. V1 chooses positional bindings (`List Value`) only, with `?` placeholders. This avoids Node's bare-name compatibility switches and collisions among `:x`, `$x`, and `@x`. Bind-count mismatch is a checked `Binding` error before stepping when metadata permits, and always remains a host failure boundary.

### Typed row decoding

```elm
type Decoder a

succeed : a -> Decoder a
map : (a -> b) -> Decoder a -> Decoder b
map2 : (a -> b -> c) -> Decoder a -> Decoder b -> Decoder c
andThen : (a -> Decoder b) -> Decoder a -> Decoder b
fail : String -> Decoder a

field : String -> Decoder a -> Decoder a
index : Int -> Decoder a -> Decoder a
string : Decoder String
integer : Decoder Int
integer64 : Decoder Int64
number : Decoder Float
bytes : Decoder Bytes
nullable : Decoder a -> Decoder (Maybe a)
```

Rows cross IPC as a tagged SQLite value array plus column metadata, never as JSON objects whose duplicate column names overwrite each other. `field` fails on missing or ambiguous duplicate names; `index` is unambiguous and O(1). Decoding occurs in ordinary Elm from the tagged row fact. Type mismatch reports expected type and stable field/index location, never whole row contents.

`Query a` pairs `Sql`, bindings, and `Decoder a`; `Command` pairs `Sql` and bindings. `all`, `one`, and `maybeOne` share one execution primitive. `one` distinguishes `NoRows` from `TooManyRows`; `maybeOne` must also fail on too many rows (Gren prior art currently collapses that case, which v1 will not copy).

## 4. Ownership and state machines (MISI)

### Session

```text
Absent
  -- withDatabase dispatch acknowledged --> Starting(child id)
Starting
  -- open ack ---------------------------> Open(connection registry)
  -- failure/timeout/cancel -------------> Stopping
Open
  -- program terminal -------------------> Closing
  -- cancel/timeout/IPC death -----------> Stopping
Closing
  -- rollback-if-needed; cursor stop; db.close ack; child exit --> Absent(result)
Stopping
  -- cooperative request; grace; SIGTERM; grace; SIGKILL; child exit --> Absent(error)
```

A settled session is absent from the parent registry. Child id owns the process, IPC channel, database, statements, cursors, and optional transaction. There are no parallel `closed`, `cancelled`, or `settled` booleans.

### Statement and cursor

```text
Statement: Absent --prepare ack--> Ready --open cursor--> Lending --cursor reset ack--> Ready
                                      |--release--> Released(logical)
Ready/Released --connection close ack or process exit--> PhysicallyFinalized

Cursor: Absent --first step request--> Open --next--> Open
                                           --DONE/stop/error--> Absent(reset ack)
```

Only one cursor may lend a statement at a time. A `Lending` statement cannot execute or be released. `release` is honestly logical: it removes registry reachability and cache ownership but does not claim `sqlite3_finalize`; physical finalization is acknowledged only by connection close/process exit on Node 24.4.1. The implementation may avoid a public `release` if review finds that distinction too surprising.

Cursor stepping is demand-driven: one `next` request produces at most one row. There is no accumulated row buffer. A decoder failure immediately issues stop/reset before settling the failure.

### Transaction consume semantics

```elm
transaction : TransactionMode -> (Transaction Active -> Program Error (TransactionDecision a)) -> Program Error a

type TransactionDecision a
    = Commit (Transaction Active) a
    | RollBack (Transaction Active) a
```

Every `executeIn`/query operation **consumes** `Transaction Active` and returns a fresh `Transaction Active` with its value. Commit or rollback consumes the final token. This serializes use and makes “commit twice,” “use after rollback,” and parallel use of one transaction unrepresentable in straight-line Elm.

Because Elm lacks linear types, kernel ownership still enforces a monotonic transaction nonce: each operation accepts exactly the current generation and advances it; duplicate/stale generations fail `InvalidState` without touching SQLite. The public API must be explicit that compile-time consume ergonomics are backed by a runtime affine check, not true linearity.

`transaction` begins exactly once (`Deferred`, `Immediate`, or `Exclusive`), commits only from its explicit `Commit` decision, and rolls back for explicit rollback, callback/program failure, decode failure, cancellation, timeout, or child teardown. Nested `transaction` is rejected before `BEGIN`; savepoints are deferred until a coherent typed design exists.

The critical commit boundary is:

```text
CommitDispatched -> CommitPhysicallyReturned -> AckQueued -> AckObservedByParent
```

Death after dispatch but before observed acknowledgement yields `CommitOutcomeUnknown`; it must never be reported as rollback or success. Cancellation before commit dispatch guarantees no commit was requested. SQLite crash recovery preserves atomicity but cannot answer whether an acknowledgement was lost.

## 5. Errors and recovery

```elm
type ErrorKind
    = OpenFailed
    | InvalidSql
    | BindingMismatch
    | Busy
    | Locked
    | Constraint ConstraintKind
    | SchemaChanged
    | Corrupt
    | ReadOnly
    | DecodeFailed DecodeError
    | NoRows
    | TooManyRows
    | InvalidState
    | Cancelled
    | TimedOut
    | CommitOutcomeUnknown
    | UnsupportedRuntime
    | IoFailure
    | UnknownFailure

type ConstraintKind
    = Unique | PrimaryKey | ForeignKey | NotNull | Check | OtherConstraint
```

Classification uses SQLite primary/extended numeric result codes (`errcode`) first, never English-message parsing. The fixture observed code 5 for busy and 2067 for unique. `ERR_SQLITE_ERROR` alone is not useful classification. The opaque error retains optional primary and extended numeric codes, operation (`Open`, `Prepare`, `Bind`, `Step`, `Commit`, etc.), and a bounded sanitized message. It excludes SQL text, expanded SQL, bound values, row data, and filesystem secrets.

`SQLITE_SCHEMA` is `SchemaChanged`. The package does not silently re-run writes: automatic repreparation can duplicate effects when the operation boundary is uncertain. Callers may retry a known read or reopen according to application policy. `Busy`/`Locked` are likewise surfaced after the configured SQLite timeout; retry/backoff belongs to Elm policy.

`Corrupt` does not delete or rebuild a database. Session-index's current recover-and-rebuild choice remains an ordinary harness decision. Constraint errors do not guess domain meaning.

## 6. Synchronous API and process boundary

`DatabaseSync` blocks its invoking JavaScript thread for open, prepare, stepping, busy waits, PRAGMAs, and transactions. Running it in the harness daemon would stall every session, WebSocket, and timer. V1's default `withDatabase` therefore owns a dedicated child process per scoped session (a reviewed reusable child pool may be a later optimization, but pooling cannot weaken ownership or interruption semantics).

IPC operations are tagged requests with monotonically increasing ids. Exactly one response settles each request. The parent applies bounded request size, row size, rows-per-collection, total result bytes, cursor idle time, session wall time, and child count. A malicious/buggy child cannot cause an unbounded Elm mailbox or parent allocation.

Cancellation ladder:

1. mark the parent request cancelling and stop sending new database operations;
2. ask the child to stop between synchronous calls and roll back/close;
3. after grace, `SIGTERM`;
4. after grace, `SIGKILL`;
5. settle only after child exit, classifying the commit boundary honestly.

The feasibility fixture proves `SIGKILL` rollback of an uncommitted transaction and parent-loop liveness. It does not prove graceful interruption of a running SQL call, because Node exposes no `sqlite3_interrupt`.

A separately named `Schelm.Node.Sqlite.UnsafeDirect` facade may be considered only after review. It must state that every call blocks the caller event loop and offers no hard interruption. The harness must not use it on its daemon thread.

## 7. Migrations remain ordinary Elm

There is no migration DSL or hidden schema table. A migration is ordinary data and `Program` composition:

```elm
type alias Migration =
    { version : Int
    , up : Transaction Active -> Program Error ( Transaction Active, () )
    }
```

An application queries `PRAGMA user_version`, validates its own ordered migration list, runs each migration in a transaction, and sets `user_version` as the final statement. Whether migrations are one transaction, per-version transactions, forward-only, or destructive is application policy. The package may document recipes but owns no migration registry, checksum, or retry rule.

`exec` for multi-statement trusted schema text is permitted as an explicitly named primitive with no bindings and no returned rows. Dynamic values use prepared statements. This supports current cron/index schema SQL without encouraging interpolation.

## 8. Capability and security classification

- `Database` is a validated path/memory locator, not a security capability.
- child/session ids and transaction generations are cooperative unforgeable values inside generated code, backed by parent registry checks; they are not OS authorization.
- filesystem access follows the Node process identity. A future composition with `schelm-node-filesystem` permission must not be claimed until the compiler can enforce it.
- extension loading, authorizers, JS user functions, and changesets are absent, minimizing code-execution and callback reentrancy surfaces.
- defensive mode and foreign-key behavior are explicit options/facts; defaults are defined once in Elm configuration and transmitted, not duplicated in JS.

## 9. Complexity and bounds

- prepare/bind/step cost is O(SQL + parameters + current row), never O(previous rows);
- cursor `next` retains at most one tagged row and performs O(row width/bytes) work;
- `all` is explicitly bounded and costs O(total returned bytes); unbounded datasets must use `cursor`;
- statement lookup and request settlement use maps keyed by ids; transaction validation is O(1);
- no per-row IPC message contains accumulated rows, no fold uses end-append, and no hot operation scans all sessions/statements;
- close is O(resources owned by that one session), a cold terminal path;
- default limits must cover SQL chars, parameters, one value/blob, row columns/bytes, collected rows/bytes, statements, cursors, operations, session duration, and concurrent children.

At row 1,000,000, session 200, the cursor path performs one child lookup, one SQLite step, one bounded row encoding, one IPC response, and one row decode. It does not revisit rows 1–999,999.

## 10. Gren and community matrix

There is no exact official Gren equivalent.

| Surface | Transport/runtime | Typed rows/values | Transactions | Resource/interruption model | Decision |
|---|---|---|---|---|---|
| `gren-lang/node` | no official SQLite module found | n/a | n/a | n/a | no analogue to copy |
| `blaix/gren-ws4sql` 4.x | HTTP to external ws4sql server | encode values + decoder-style rows | batches statements remotely | HTTP task; server owns DB resources | useful ergonomic prior art; not equivalent to local built-in SQLite |
| `joeybright/gren-turso` | remote Turso/libSQL HTTP API | encode/decode | remote semantics | network cancellation | relevant remote prior art only |
| `better-sqlite3` | native synchronous JS | JS values/rows | closure helper | blocks thread; mature statement API | Node ergonomic prior art, but cannot define Elm ownership guarantees |
| Node 24.4.1 `node:sqlite` | built-in synchronous JS/C++ | BigInt/number/string/Uint8Array/null | SQL + `isTransaction` | connection close finalizes; no interrupt; no statement finalizer | chosen kernel verb layer |
| proposed package | Elm program over killable child | closed `Value` + Elm `Decoder` | consuming token + nonce | child-owned scoped resources; kill ladder | exact fit for Schelm/harness invariants |

Gren ws4sql validates the value/decoder/query split and `getOne`/`getAll` convenience, but its `getMaybeOne` returning `Nothing` for multiple rows is too weak. Its `Error String` is also insufficient for busy/constraint/schema recovery. No inspected Gren package offers an exact local, built-in, process-interruptible SQLite equivalent.

References:

- <https://packages.gren-lang.org/package/blaix/gren-ws4sql>
- <https://github.com/blaix/gren-ws4sql>
- <https://packages.gren-lang.org/package/joeybright/gren-turso/version/3.0.0/overview>
- <https://github.com/WiseLibs/better-sqlite3/blob/master/docs/api.md>

## 11. Harness migration slices

### Slice 1: cron store

Differentially run old JS and package adapters against fresh and legacy fixture DBs for:

- WAL, synchronous, busy timeout, additive schema migration;
- upsert/get/list ordering and null fields;
- JSON corruption behavior;
- lock contention and constraint classification;
- repeated open/close and daemon/session failure isolation.

Elm owns `normalizeStatus`, job projection, schema migration list, and JSON policy. The package owns only database mechanics. No deploy occurs from the integration branch.

### Slice 2: session index

Only after cron parity:

- schema/FTS availability and quick-check facts;
- `BEGIN IMMEDIATE` atomic event/chunk/watermark update;
- bounded cursor scans and search result decoding;
- busy, schema, corrupt, and process-kill failure injection;
- old/new differential catalog/search/index behavior;
- verify index rebuild policy remains Elm and journal disk remains source of truth.

The index may be rebuilt after a typed `Corrupt` decision from Elm; the package never unlinks it automatically.

## 12. Test architecture and guarantee map

The later `06-property-test-plan.md` must make these executable, but the design already commits to the classes:

1. **Pure properties:** `Sql` validation; exact Int64 round trips and overflow; `Value` tagged round trips; decoder applicative/monad laws where applicable; field ambiguity; nullable/type mismatch; numeric error classification.
2. **Reference model/state machine:** generated open/prepare/bind/step/cursor-stop/release/begin/execute/commit/rollback/cancel traces against a pure model. Invalid transitions must be generated deliberately and leave the DB unchanged.
3. **Real DB properties:** arbitrary CRUD command sequences compared with an in-memory model; transaction atomicity; unique/FK/check/not-null; schema change; two-process busy/locked; WAL reopen; blobs and Unicode; duplicate columns; exact 64-bit boundaries.
4. **Failure injection:** child death before/after dispatch and acknowledgements, IPC truncation, timeout, oversized row/result, cursor abandonment, decoder failure, close failure, commit acknowledgement race, corrupt DB, and parent disconnect.
5. **Debug/optimize differential:** every production state-machine fixture compiled and run in both modes; artifact gate proves fixture hooks are absent from production kernels.
6. **Old-host/new-package compatibility:** supported Node matrix begins at pinned 24.4.1; probe built-in option and error shapes on each accepted point release. Unknown host behavior fails `UnsupportedRuntime`, not silent degradation.
7. **Harness differential:** cron first, then session-index, with golden DB files and operation traces. Compare logical results, persisted rows, PRAGMAs, restart recovery, and error categories—not unstable English text.
8. **Performance/bounds:** million-row cursor constant-retention test, row/result caps, no O(n²) accumulation, event-loop ticks continue under long child query, cancellation wall bound, and child/resource leak census.

Every public guarantee maps to one of: type-level constructor test, pure property, model trace, real SQLite test, debug/opt differential, or explicit platform precondition. Claims without such a map are removed.

## 13. Open decisions for independent review

1. Can the scoped `Program` API prevent resource escape clearly enough in Elm 0.19.2, or should v1 use only declarative `Command`/`Query` values and hide connection tokens entirely?
2. Is logical statement `release` too misleading without public Node finalization? Prefer omitting it unless ergonomic need outweighs the teaching cost.
3. Should every session be a fresh child, or can a supervised reusable child own exactly one connection sequentially while preserving kill semantics and clean state?
4. What bounded collection defaults make `all` useful without encouraging accidental memory spikes?
5. Should exact 64-bit integers use a package `Int64` hi/low representation or decimal-backed validated value? This requires property/performance evidence before API freeze.
6. Can a direct unsafe facade be omitted entirely from v1? The default answer is yes.

## 14. Gate

This artifact plus `00-feasibility.md` completes only first-turn feasibility and design. Implementation remains blocked on independent `02-adversarial-review-a.md`, `03-design-revision-a.md`, `04-adversarial-review-b.md`, `05-design-revision-b.md`, and `06-property-test-plan.md` as required by the Schelm constitution.
