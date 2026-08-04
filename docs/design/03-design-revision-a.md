# 03 — Design revision A

Status: response to rejection A. This supersedes the public API, ownership, process, outcome, and IPC sections of `01-design.md`. `00-feasibility.md` remains evidence. No production implementation is authorized.

## 1. Decisions

Revision A accepts every required correction:

- no public connection, statement, cursor, transaction, process, request, or generation handles;
- row decoding moves to `Schelm.Node.Sqlite.Decode` and runs in parent Elm;
- public work is declarative `Command`, `Query a`, and `TransactionProgram a`;
- one package effect manager in parent Elm is the interpreter and policy owner;
- each active database uses a persistent responsive supervisor plus a killable blocking database worker, managed by one bounded parent pool;
- prepared operations accept one statement only; transaction-control SQL is narrowly rejected and physical autocommit is checked after every operation;
- every unacknowledged potentially mutating operation has an unknown outcome, not only `COMMIT`;
- production query execution uses iterator stepping only; Node `all()` is forbidden;
- a finite versioned binary protocol meters all data before allocation/IPC;
- migrations, retries, schema recovery, cron policy, and index policy remain ordinary Elm.

## 2. Public API: descriptions, never resources

### `Schelm.Node.Sqlite`

```elm
module Schelm.Node.Sqlite exposing
    ( Database, DatabaseError(..), database, memory
    , Options, options, readOnly, withBusyTimeout
    , BusyTimeout, busyTimeout
    , Sql, SqlError(..), sql
    , Value, null, int, int64, float, text, blob
    , Int64, int64FromDecimal, int64ToDecimal, int64FromInt, int64ToInt
    , Bindings, noBindings, bind, bindings
    , Command, command
    , Query, query
    , CollectionLimit, collectionLimit
    , Changes
    , execute, queryAll, queryOne, queryMaybe
    , TransactionMode(..), TransactionProgram
    , transaction, transactionSucceed, transactionFail
    , transactionMap, transactionAndThen
    , transactionExecute, transactionQueryAll
    , transactionQueryOne, transactionQueryMaybe
    , Error, ErrorKind(..), ConstraintKind(..)
    , errorKind, sqliteCode, errorMessage
    )


type Database                         -- validated cooperative locator
type Options                          -- one Database + mode + finite limits
type Sql                              -- one non-empty/NUL-free SQL source
type Value                            -- closed SQLite value algebra
type Bindings                         -- positional values only
type Command                          -- one potentially mutating statement
type Query a                          -- one statement + bindings + Decode.Decoder a
type TransactionProgram a             -- constructors private; no resource token

command : Sql -> Bindings -> Result SqlError Command
query : Sql -> Bindings -> Decode.Decoder a -> Result SqlError (Query a)

execute : Options -> Command -> Task Error Changes
queryAll : Options -> CollectionLimit -> Query a -> Task Error (List a)
queryOne : Options -> Query a -> Task Error a
queryMaybe : Options -> Query a -> Task Error (Maybe a)

transaction : Options -> TransactionMode -> TransactionProgram a -> Task Error a
transactionSucceed : a -> TransactionProgram a
transactionFail : String -> TransactionProgram a
transactionMap : (a -> b) -> TransactionProgram a -> TransactionProgram b
transactionAndThen : (a -> TransactionProgram b) -> TransactionProgram a -> TransactionProgram b
transactionExecute : Command -> TransactionProgram Changes
transactionQueryAll : CollectionLimit -> Query a -> TransactionProgram (List a)
transactionQueryOne : Query a -> TransactionProgram a
transactionQueryMaybe : Query a -> TransactionProgram (Maybe a)
```

`Options` identifies the persistent database worker; calling an operation does not open a new process or connection. `memory` includes a unique package-generated database identity so unrelated callers never accidentally share one in-memory connection. Filesystem paths are validated cooperative locators, not security capabilities.

`Sql` is honest: arbitrary cooperative SQLite text, not an injection-safe AST and not hostile SQL containment. Dynamic values must use positional `?` bindings. `Command` and `Query` accept exactly one prepared statement. There is no public multi-statement `exec` or `schema` escape hatch: migrations are ordinary Elm lists of individual `Command` values.

`Int64` is exact signed 64-bit data, initially canonical decimal-backed unless benchmarks prove a hi/low representation materially better. `int64FromDecimal` accepts only canonical `-9223372036854775808` through `9223372036854775807`; IPC carries the same canonical ASCII. Checked `Int` conversion cannot truncate.

### `Schelm.Node.Sqlite.Decode`

```elm
module Schelm.Node.Sqlite.Decode exposing
    ( Decoder, Error, Location(..), Expected(..)
    , succeed, fail, map, map2, map3, andThen
    , field, index
    , string, int, int64, float, number, bytes, value
    , nullable
    )
```

`Decoder a` is opaque and retained entirely in parent Elm. Child rows are arrays of tagged SQLite values plus an ordered array of column names. `field` fails if absent or duplicated; `index` is checked and unambiguous. Errors contain location and expected/actual SQLite storage class, never row contents. `int` checks Elm range; `float` accepts only SQLite REAL; explicitly broader `number` accepts REAL or exactly representable INTEGER.

### Declarative query construction

```elm
jobByIdSql : Sqlite.Sql
jobByIdSql =
    -- constructed once at the module boundary; impossible Err handled there
    validatedJobByIdSql

findJob : String -> Result Sqlite.SqlError (Sqlite.Query Job)
findJob id =
    Sqlite.query
        jobByIdSql
        (Sqlite.bindings [ Sqlite.text id ])
        (Decode.field "job_json" Decode.string
            |> Decode.andThen decodeJobJson
        )
```

The decoder closure never crosses JS or IPC. The child knows only SQL, tagged bindings, column metadata, and row values.

### Transaction programs without tokens

```elm
saveJob : Job -> Sqlite.TransactionProgram Job
saveJob job =
    Sqlite.transactionExecute (upsertJob job)
        |> Sqlite.transactionAndThen (\_ ->
            Sqlite.transactionQueryOne (findJob job.id)
        )

persist : Sqlite.Options -> Job -> Task Sqlite.Error Job
persist db job =
    Sqlite.transaction db Sqlite.Immediate (saveJob job)
```

`TransactionProgram` is a private Elm instruction tree/free program. Its leaves contain declarative commands/queries and its continuations consume decoded ordinary values—not resource ids. The effect manager interprets one instruction at a time while it alone holds an internal transaction lease. Programs cannot emit nested transactions, manual transaction control, multi-statement execution, or parallel branches. Successful exhaustion requests commit. `transactionFail` is a terminal short-circuit even when syntactically placed before `transactionAndThen`; it requests rollback and its bounded caller-authored reason is classified separately from SQLite errors. SQL/decode/interpreter failure also requests rollback.

This is sequential by construction. There is no fake linear public token to duplicate.

## 3. Exact parent-Elm interpreter

The package contains one Elm effect manager. It owns:

```text
DatabaseKey ->
  Dormant(queue)
  | Starting(supervisorGeneration, queue)
  | Ready(workerGeneration, nextRequest, queue, maybe InFlight)
  | Poisoning(generation, inFlightClassification, queue)
  | Stopping(generation, queue)
```

Its private `InFlight` algebra holds the decoder/continuation and exactly one protocol expectation:

```text
Opening
Executing PotentiallyMutating
Querying PotentiallyMutating CursorMeters DecoderContinuation
Transacting TxGeneration TxPhase TransactionContinuation
Closing
```

The manager decides admission, FIFO order, round-robin database selection, transaction sequencing, cursor demand, decode settlement, retry prohibition, worker replacement, and error classification. Kernel JS provides facts and verbs only: strict binary encode/decode, spawn, write with drain acknowledgement, observe exit, signal, and monotonic time. The blocking database worker performs SQLite verbs and structural meters but no application retry/recovery policy.

Elm functions never cross the boundary. An in-flight decoder is keyed only by the private parent request id and is removed in the same transition that settles or poisons the operation. A settled request is absent.

## 4. SQL boundary and autocommit invariant

### Narrow lexical validation

Prepared `Command` and `Query` use SQLite prepare itself to prove one statement: prepare the source, and reject non-whitespace/comment tail after the first compiled statement. Because Node's public `prepare` does not expose the tail pointer, the worker uses a bounded conservative lexer before prepare to reject top-level semicolons followed by any significant token; fixtures differential-test it against SQLite acceptance. This is cooperative validation, not a security parser.

The same bounded lexer skips whitespace plus `--` and `/* ... */` comments, then case-insensitively classifies the first unquoted token. It rejects `BEGIN`, `COMMIT`, `END`, `ROLLBACK`, `SAVEPOINT`, and `RELEASE` for every public SQL constructor. It understands SQLite quoted strings/identifiers only enough not to treat their contents as tokens. Unterminated quotes/comments fail `InvalidSql`. Input has a hard UTF-8 byte cap before lexing.

False positives fail closed. False negatives are caught by the physical invariant below. This rule prevents accidents; cooperative code can still put transaction-changing behavior behind triggers or unusual SQL.

### Physical invariant

The Elm interpreter sends expected autocommit state on every operation:

- ordinary operation: `expectedBefore = true`, `expectedAfter = true`;
- transaction begin: `true -> false`;
- transaction action: `false -> false`;
- rollback/commit: `false -> true`.

The worker reads `database.isTransaction` immediately before and immediately after SQLite returns. A mismatch emits only `AutocommitMismatch { before, after, operationPhase }`, attempts rollback if physically in a transaction, closes the connection, and exits. The parent poisons that generation and does not dispatch queued work until a fresh worker opens. If a potentially mutating operation was dispatched without an observed valid completion, its outcome is unknown.

## 5. Operation and acknowledgement state

For each request:

```text
Queued
  -- selected/admitted --------------------------> SentToSupervisor
SentToSupervisor
  -- supervisor validates + forwards -----------> EnteredWorker
EnteredWorker
  -- worker validates pre-state + calls SQLite --> SQLiteInFlight
SQLiteInFlight
  -- SQLite returns -----------------------------> PhysicalReturned
PhysicalReturned
  -- meters + response frame accepted by pipe --> ResponseWritten
ResponseWritten
  -- parent boundary validates complete frame ---> ParentDecoded
ParentDecoded
  -- Elm manager consumes expected response -----> Observed
Observed
  -- decoder/application Task callback ----------> Settled(absent)
```

Cancellation before `SentToSupervisor` removes the request and returns `CancelledBeforeDispatch`. Cancellation after dispatch asks the supervisor to terminate the blocking worker; it never asserts that SQLite stopped cooperatively.

Outcome classification on child/protocol/cancel failure:

| Operation | Last parent fact | Result |
|---|---|---|
| read-only database operation | dispatched, not `Observed` | `Interrupted` (physical DB cannot mutate) |
| command on writable DB | dispatched, not `Observed` | `OperationOutcomeUnknown` |
| query on writable DB | dispatched, not `Observed` | `OperationOutcomeUnknown` (cooperative SQL may mutate/trigger) |
| explicit transaction, before begin dispatch | queued only | `CancelledBeforeDispatch` |
| explicit transaction, begin/actions dispatched, valid rollback observed | rollback `Observed` | original known failure/cancel |
| explicit transaction, worker dies before valid commit observed | any unobserved terminal phase | `TransactionOutcomeUnknown` |
| any response `Observed`, then Elm row decode fails | observed SQLite outcome | `DecodeFailed`, not unknown |

`Observed` means the Elm manager matched a structurally valid response for the current worker generation and request id. Merely writing a response or decoding it in JS is insufficient. On writable connections, v1 deliberately over-classifies unacknowledged queries as unknown rather than risk unsafe retry.

## 6. Persistent supervised process topology

```text
parent daemon
  └─ responsive supervisor child (one per active DatabaseKey)
       └─ blocking database worker child (owns one DatabaseSync)
```

The database worker is persistent: it opens once, applies connection options once, prepares/steps on demand, and closes on idle eviction/shutdown. It may block inside `DatabaseSync`. The supervisor never calls SQLite, remains responsive to parent IPC closure/cancel/deadline, and owns the worker process group. On escalation it sends `SIGTERM`, waits a fixed monotonic grace, sends `SIGKILL`, and reaps before reporting exit.

Parent and supervisor communicate over dedicated binary stdin/stdout pipes, not Node object-mode IPC. Supervisor and worker use a second dedicated framed pipe pair. Diagnostic stderr is capped/rate-limited and never treated as protocol.

### Parent death and orphan reaping

Each supervisor receives `{ parentPid, parentStartIdentity, parentGeneration, workerGeneration }`. Parent and supervisor exchange a nonce challenge after spawn so an inherited/stale control endpoint cannot claim the generation. Its control pipe EOF is the primary parent-death fact. On EOF it immediately climbs the worker kill ladder, reaps, removes its ownership record, and exits. Because the supervisor event loop never enters SQLite, a blocked worker cannot prevent this.

Before advertising readiness, a supervisor writes atomically under a package runtime directory an ownership record containing protocol version, uid, supervisor pid/start identity, worker pid/start identity, parent pid/start identity, and random 128-bit parent generation. No SQL, database path, or values are stored. On clean exit it removes the record.

At package-manager startup, the parent scans only this private directory. A stale record is eligible for reaping only when uid matches, process start identity matches `/proc` (Linux v1), executable/argv marker matches the installed supervisor, and recorded parent identity is absent. Any ambiguity is reported and left untouched. Reaping always signals the recorded supervisor process group, waits, then dry-verifies disappearance. It never signals by pid alone. Linux x64/arm64 is the initial normative platform; unsupported `/proc` semantics fail `UnsupportedRuntime` rather than weakening orphan safety.

SQLite crash recovery owns database/WAL consistency after `SIGKILL`. The package never deletes `-wal` or `-shm` during worker recovery.

## 7. Pool, admission, queueing, and fairness

Defaults are defined once in Elm and validated against hard kernel maxima:

- at most 8 active database supervisors globally (configurable down, never above hard cap);
- at most 256 queued operations per database;
- at most 1024 queued operations globally;
- one in-flight operation per database worker;
- one transaction or cursor collection exclusively occupies that database worker;
- finite transaction instruction, cursor row, and wall-clock limits;
- 30-second idle eviction default after queues drain (configurable within bounds).

Admission first checks per-database then global queue caps; overflow returns `AdmissionRejected` synchronously without dispatch. Each database queue is FIFO. Ready workers each run one ordinary operation as a quantum before rejoining a parent Elm round-robin ready ring. A transaction and a public collection are one exclusive quantum but have instruction/row/time meters, preventing infinite monopolization. Single-row demand cursors are internal to that quantum and cannot be retained by callers.

When fewer than 8 workers exist, the next non-empty database in the round-robin waiting ring starts. At capacity, a new database waits; an idle, queue-empty worker may be evicted least-recently-used only at a quantum boundary. Active transactions/collections are never preempted for fairness. Cancellation marks a private request id absent in an Elm `Dict` in O(log queued requests); FIFO nodes become tombstones and are skipped once at dequeue. It never scans all queues or rewrites a queue per tick.

A future pool of workers that switch database files is rejected for v1: connection PRAGMAs, prepared state, WAL behavior, and failure generation are safer with one active worker bound to one database.

## 8. Versioned binary IPC

### Frame

Every frame is:

```text
4 bytes  magic "SQE1"
2 bytes  protocol major (big endian)
2 bytes  protocol minor
1 byte   direction/tag family
1 byte   flags (unknown bits rejected)
16 bytes parent generation
16 bytes worker generation
8 bytes  request id (unsigned, nonzero, big endian)
4 bytes  payload length
N bytes  payload
4 bytes  CRC32C of header-without-magic + payload
```

The incremental decoder retains at most the fixed header until length validation, then allocates exactly the validated payload length. It rejects wrong magic/major, unsupported required minor feature, generation mismatch, unknown tag/flags, payload above the tag-specific and absolute 8 MiB cap, or non-canonical lengths **before allocating payload**. Partial frame at EOF, trailing bytes after a terminal frame, checksum mismatch, duplicate response, impossible tag for state, request id zero/reuse/wrap, or response for an absent request poisons that worker generation. Request ids never wrap: exhaustion rotates the worker generation before further admission.

Protocol negotiation is `Hello(minMajor,maxMajor,features,hardLimits)` / `Welcome(chosen,features,hardLimits)` before database paths or SQL are sent. Incompatibility returns `UnsupportedRuntime` and stops the generation.

### Payload algebra

Payloads use a package-specific length-delimited binary algebra, not JSON or JS structured clone:

```text
Utf8       = u32 byteLength + strict UTF-8 bytes
Bytes      = u32 byteLength + raw bytes
Int64      = u8 asciiLength + canonical signed decimal ASCII (1..20 bytes)
Value      = tag Null | Integer(Int64) | Real(IEEE754 binary64) | Text(Utf8) | Blob(Bytes)
Values     = u32 count + repeated Value
Columns    = u32 count + repeated Utf8
Row        = u32 scalarCount + repeated Value
ErrorFact  = numeric primary/extended code + operation tag + bounded Utf8
```

NaN and infinities are rejected for bindings because SQLite/Node coercion is not a stable public contract. Text decoding is strict UTF-8. Before encoding Elm text, the boundary rejects lone UTF-16 surrogates rather than allowing replacement. Blob bytes are copied once into a bounded frame; chunks above the per-value cap are rejected before dispatch.

### Request/response tags

Finite parent requests:

```text
Hello, Open, PrepareAndExecute, PrepareAndStartQuery,
QueryDemandOne, QueryStop, Begin, TransactionExecute,
TransactionStartQuery, Commit, Rollback, Close, CancelGeneration
```

Finite worker facts:

```text
Welcome, Opened, Entered, ExecuteReturned, QueryStarted,
Row, QueryDone, RollbackReturned, CommitReturned, Closed,
SqliteFailed, LimitFailed, AutocommitMismatch, ProtocolFailed, WorkerExited
```

`Entered` is a supervisor-observed worker acceptance fact, not SQLite completion. Outcome remains unknown until the matching terminal response is `Observed` by Elm.

### Backpressure and meters

Production code never calls `StatementSync.all()`. It prepares, binds, then uses `iterate()` and explicit `next()` only. The parent sends one `QueryDemandOne`; the worker performs at most one `next()` and returns one `Row` or `QueryDone`. It will not step again without demand. `QueryStop` calls iterator `return()` and must receive reset acknowledgement before reuse/transaction completion.

Before writing any row frame, the worker increments and checks:

- rows in this query/collection;
- scalars in this row and aggregate scalars;
- UTF-8 text bytes, blob bytes, row bytes, and aggregate result bytes;
- elapsed monotonic query/session time.

Limits are included in the structurally validated request and capped by handshake hard limits. Overflow stops/resets the iterator before returning `LimitFailed`. The supervisor also enforces frame caps independently. Every pipe write honors the Boolean return from `write`; no next frame/read is accepted until `drain`. Parent demand plus pipe drain bounds retained data to one row frame at each hop. Public `queryAll` collects only in parent Elm and requires `CollectionLimit`; `queryOne`/`queryMaybe` request at most two rows to detect cardinality.

## 9. Statement lifecycle and schema change

Statement ids and iterators exist only inside the worker generation. V1 defaults to prepare-per-operation, then drops logical reachability after iterator reset/operation completion. Because Node 24.4.1 lacks public per-statement finalization, no individual finalization acknowledgement is exposed or transmitted. Connection close/process exit physically finalizes all tracked statements.

A bounded internal statement cache is deferred unless benchmarks demonstrate necessity. If later added, it is worker mechanism keyed by exact SQL plus row mode and capped in Elm options; eviction still cannot claim immediate physical finalize on Node 24.4.1.

`SQLITE_SCHEMA` surfaces `SchemaChanged`; writes are never automatically re-prepared/replayed. The generation may continue only if autocommit matches and SQLite documents the statement reset as safe; otherwise it is poisoned. Revision B must demand a real fixture before allowing continuation—the fail-closed default is poison/reopen.

## 10. WAL, busy, shutdown, and recovery

Open options are explicit immutable facts per `DatabaseKey`: read-only/read-write, finite busy timeout, foreign keys, journal mode request, synchronous mode request, and hard limits. Two operations that name the same file with different immutable open options fail `ConflictingOptions`; there is one connection authority per active database key.

The worker reports actual `journal_mode`, `foreign_keys`, and `synchronous` facts after open. Elm decides whether they satisfy application requirements. The package does not silently force WAL for all users. Harness adapters explicitly request current behavior: cron WAL/NORMAL/busy timeout; index WAL/foreign keys/busy timeout.

Busy timeout is finite and blocks only the DB worker. Numeric SQLite primary/extended codes classify `Busy`, `Locked`, constraints, schema, readonly, IO, and corrupt. No English matching and no automatic retry. On worker death, the supervisor reaps it; parent Elm marks uncertain in-flight work correctly, fails that operation, starts a fresh generation for later queued work, and lets SQLite reopen/recover WAL. Queued but undispatched operations retain FIFO order and may proceed only after successful reopen.

Graceful idle/shutdown sequence is stop query if any, rollback if physically in transaction, close database (thereby finalizing statements), worker exit, supervisor reap/exit, ownership-record removal. Any missing acknowledgement escalates; an unobserved potential mutation retains unknown outcome.

## 11. Migrations and ordinary Elm

Migrations remain ordinary Elm lists of versioned `TransactionProgram ()` values. The application queries `PRAGMA user_version`, validates gaps/checksums according to its own policy, executes one or more transaction programs, and changes `user_version` as the final command. The package has no migration table, discovery, ordering, retry, destructive-change, or rebuild policy.

V1 omits public multi-statement `schema`/`exec`. Each migration statement is a validated `Command`, normally sequenced in a `TransactionProgram`. SQL text that SQLite requires outside a transaction runs as one ordinary command at a time, with the same acknowledgement and unknown-outcome rules. This trades convenience for one execution/acknowledgement boundary per statement.

## 12. Error algebra

```elm
type ErrorKind
    = InvalidDatabase
    | InvalidSql
    | BindingMismatch
    | AdmissionRejected
    | Busy
    | Locked
    | Constraint ConstraintKind
    | SchemaChanged
    | Corrupt
    | ReadOnly
    | DecodeFailed Decode.Error
    | NoRows
    | TooManyRows
    | LimitExceeded
    | CancelledBeforeDispatch
    | Interrupted
    | OperationOutcomeUnknown
    | TransactionOutcomeUnknown
    | ConflictingOptions
    | ProtocolFailure
    | UnsupportedRuntime
    | IoFailure
    | UnknownFailure
```

Errors are opaque. Accessors expose stable kind, operation phase, optional numeric SQLite primary/extended code, and bounded sanitized message. They never expose SQL, expanded SQL, bindings, row contents, database path, child argv, or raw IPC. `errorMessage` is package-authored from stable facts, not raw exception laundering.

Recovery guidance is structural:

- `Busy`/`Locked`: application may retry according to policy;
- `SchemaChanged`: reopen/rebuild/retry only according to known operation policy;
- `Corrupt`: application decides whether its database is reconstructible;
- unknown outcomes: do not blind retry non-idempotent work; reconcile from durable application identity/state;
- protocol/unsupported: stop using that generation/version.

## 13. Harness authority transitions

### Cron first

| Phase | production read/write authority | differential authority |
|---|---|---|
| before | `elm-pkg-js/cron-store.js` | none |
| integration tests | old JS against DB A; package adapter against cloned DB B | test-only comparator |
| cutover commit | package adapter only | old JS callable only from tests |
| cleanup | package adapter only; old production imports deleted | golden/differential fixture retained |

Elm owns job validation, status normalization, JSON encoding/decoding policy, migration list, and retry decisions. Package operations cover open facts, commands, bounded queries, and transactions. Persistent-worker benchmarks must show warm upsert/get/list amortization before cutover.

### Session index second

The same authority sequence applies only after cron passes. Elm retains schema-version/rebuild policy, journal scanning/chunking, ranking, embedding policy, and corrupt-index replacement decision. The package provides bounded queries, FTS-compatible SQL mechanics, one atomic event/chunk/watermark transaction, busy/schema/corrupt facts, and worker recovery. Disk journals remain source of truth. Production never dual-writes old and new index authorities.

## 14. Required executable evidence and properties

Revision A adds these mandatory classes to the later `06-property-test-plan.md`:

### API/type properties

- compile-fail fixtures prove no public type can name or return connection, statement, cursor, transaction, request, process, or generation identity;
- decoder laws and field-ambiguity/type/range properties;
- canonical Int64 and Value binary round trips, including min/max and malformed encodings;
- transaction programs can sequence/data-depend but cannot express parallel/nested/manual transaction control.

### SQL/autocommit model

- generated comment/quote/semicolon/control-token inputs differential-tested with SQLite prepare behavior;
- every operation trace runs against a pure expected-autocommit model and production worker;
- injected trigger/manual-control escape causes mismatch, rollback attempt, poison, close, generation rotation, and no queued dispatch on old generation.

### Protocol model

- byte-by-byte frame fragmentation and coalescing;
- wrong versions, tags, flags, generations, ids, lengths, CRC, UTF-8, decimal Int64, duplicate/late frames, EOF, and trailing bytes;
- allocations never exceed accepted cap plus fixed header;
- producer/consumer backpressure model proves at most one demanded row per hop;
- debug/optimize production-boundary differential, with fixture hooks absent from production artifacts.

### Database state machine

- generated declarative CRUD traces compared with a pure map model;
- transaction atomicity and failure rollback;
- unknown-outcome injection before dispatch, after dispatch, after SQLite return, after response write, after parent decode, and after Elm observation for command, writable query, and commit;
- decoder failure after observation is known decode failure;
- busy/locked/constraint/schema/corrupt/read-only numeric classification;
- WAL crash/reopen without package file deletion.

### Process and pool

- kill blocked worker while parent and supervisor remain responsive;
- kill parent with worker blocked; supervisor kills/reaps worker and removes ownership record;
- kill supervisor; parent detects exit, reaps process group/backstop, rotates generation;
- stale record with pid reuse/mismatched start identity is never signalled;
- FIFO per database, round-robin across databases, queue caps, LRU idle eviction, transaction non-preemption, starvation bound under finite transactions;
- 8 active databases plus at least 200 queued callers without per-tick scans or unbounded processes.

### Process-overhead benchmark gates

Measure on pinned Linux Node 24.4.1 in debug and optimize generated Elm artifacts:

1. cold supervisor+worker spawn/open/first query;
2. warm persistent `get`, `upsert`, and three-row list latency/throughput;
3. process-per-operation baseline for the same cron mix;
4. eight-database contention and ninth-database admission/eviction;
5. 100k-row cursor throughput and peak RSS;
6. cancellation wall bound for a blocked query;
7. idle process/RSS/fd census before and after eviction.

Acceptance is relative and bounded: warm persistent cron mix must be at least 5x faster in median latency than process-per-operation and add no process spawn after warm-up; 100k-row peak retained IPC/query memory must remain within fixed configured aggregate limit plus 25%; cancellation/reaping must meet the documented ladder bound; process/fd count must return to baseline after idle eviction. Absolute latency budgets are recorded from the first stable CI runner and then treated as regression gates, not invented in prose.

### Harness differential

Cron golden DBs cover fresh/legacy schema, WAL settings, upsert/get/list order, nulls, corrupt JSON, lock contention, restart, parent death, and unknown mutation outcomes. Index golden DBs add FTS, quick check, event/chunk/watermark atomicity, long bounded scans, schema mismatch, corruption/rebuild decision, and search parity. Compare persisted facts and typed outcomes, never unstable English errors.

## 15. Complexity budget

For row `n`, worker and parent perform O(current row bytes/scalars), independent of rows `1..n-1`. One demand produces one step and one row frame. No Node `all()`, accumulated child buffer, accumulated IPC delta, queue scan per tick, or global process scan per operation is permitted.

Queue admission/id lookup uses Elm `Dict` and costs O(log queued requests/databases). Per-database FIFO dequeue is amortized O(1); ready-ring selection is O(1); idle eviction uses a bounded-size (maximum eight) structure. Closing is O(resources in one worker), a cold path. Public `queryAll` is O(returned bounded result) in parent Elm by definition; it builds reverse-first or an `Array`, never end-appends to an accumulated list.

## 16. Platform and compatibility

Normative v1: Linux x64/arm64, Node exactly 24.4.1 initially, SQLite 3.50.2 as reported by that runtime, private Elm 0.19.2 compiler fork. New Node 24 point releases enter the supported matrix only after protocol, option, numeric error, finalization, kill/recovery, debug/optimize, and harness differential suites pass. The package fails `UnsupportedRuntime` for unknown/missing built-in behavior; it does not silently fall back to another binding or direct daemon-thread SQLite.

There is still no exact Gren equivalent. Gren ws4sql remains ergonomic decoder/remote-transaction prior art, not ownership or process-interruption precedent.

## 17. Gate

Revision A resolves the first review but does not approve implementation. An independent review B must attack this revised API, lexer/autocommit defense, supervisor/reaper protocol, unknown-outcome table, binary framing, pool fairness, and benchmark thresholds. `05-design-revision-b.md` and `06-property-test-plan.md` remain required before production source begins.
