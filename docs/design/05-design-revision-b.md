# 05 — Final design revision B

Status: final design gate. Supersedes conflicting parts of 01 and 03. Production implementation may begin only after this document and 06 are committed and pushed.

## 1. Frozen public model

Public modules are `Schelm.Node.Sqlite` and `Schelm.Node.Sqlite.Decode`. The signatures are mechanically represented by `design-fixtures/api-contract/package`; `design-fixtures/api-contract/app/Main.elm` compiles with the private Elm 0.19.2 compiler in debug and optimize. It demonstrates query construction, JSON-from-TEXT decoding, bounded collection, dependent transaction steps, and typed domain rollback.

There are no public resource handles. `Database`, `Options`, `Sql`, `Value`, `Bindings`, `Command`, `Query a`, and `TransactionProgram e a` are inert descriptions. Parent Elm's package effect manager owns every live id and interprets descriptions. JS cannot choose queue, retry, transaction, recovery, or fairness policy.

### Construction and validation: one contract

Pure constructors perform only cheap, deterministic shape checks:

- `database`, `busyTimeout`, `collectionLimit`, and exact `Int64` constructors return `Result ShapeError`;
- `sql` rejects empty, NUL, over-byte-limit, malformed Elm scalar text, and conservatively recognized transaction-control source;
- `command : Sql -> Bindings -> Command` and `query : Sql -> Bindings -> Decode.Decoder a -> Query a` are total pure constructors.

These values prove only bounded shape. They do **not** prove SQLite grammar, one statement, placeholder count, or execution mode. Worker prepare is authoritative. It returns numeric/typed `InvalidSql` or `BindingMismatch`. The worker rejects significant SQL tail and the physical autocommit invariant catches lexical false negatives. Documentation uses “cooperative SQL description,” never “validated statement.”

### Typed transaction result

```elm
type TransactionProgram domainError a

type TransactionFailure domainError
    = DomainFailure domainError
    | SqlFailure Error

transaction :
    Options
    -> TransactionMode
    -> TransactionProgram domainError a
    -> Task Error (Result (TransactionFailure domainError) a)

transactionFail : domainError -> TransactionProgram domainError a
```

A domain failure requests rollback and settles as `Ok (Err (DomainFailure e))` only after rollback acknowledgement. SQL/process failure settles the outer task as `Err`, except a known SQL error after acknowledged rollback may be represented as `Ok (Err (SqlFailure error))`; implementation chooses one representation once and tests it, never conflates it with domain data. Unknown transaction outcome is always outer `Err TransactionOutcomeUnknown`.

### Complete Decode module

`Decode` exposes:

- `succeed`, bounded `fail`, `map`, `map2`…`map8`, `apply`, `andThen`, and bounded deterministic `oneOf`;
- `field`, `index`, and `nullable`;
- `value`, `string`, `int`, `int64`, `float`, `number`, `bytes`;
- `foldValues : (Value -> state -> Result String state) -> state -> Decoder state` for application-defined row folds.

`Decode.Error` has a non-empty `List PathStep` (`Field`, `Index`, `Branch`) from outermost to innermost, `Expected`, `Actual`, and a bounded package/caller reason. Missing and duplicate fields are explicit actual states; ambiguity reports count only. `oneOf` caps branches and retained failures. Raw `value` permits application policy without exposing row/resource identity.

JSON remains ordinary Elm:

```elm
jsonValue =
    Decode.string
        |> Decode.andThen (\raw ->
            case Json.Decode.decodeString Json.Decode.value raw of
                Ok value -> Decode.succeed value
                Err _ -> Decode.fail "invalid JSON"
        )
```

No JSON parser or schema policy exists in kernel JS.

## 2. Internal identities and acceptance

Types are defined once inside the package manager domain:

```text
RequestId, DatabaseKey, ParentGeneration, SupervisorGeneration,
WorkerGeneration, TransactionId, StatementId, CursorId
```

They are aliases suitable for `Dict` keys but never exposed. Parent generation is random 128-bit startup identity; child generations are random 128-bit identities; request/transaction/statement/cursor ids are monotonic nonzero 64-bit counters within their generation. Exhaustion rotates the generation instead of wrapping.

An incoming fact is accepted only when protocol version, parent generation, supervisor generation, worker generation, request id, expected transaction id, and expected statement/cursor id all match the single `InFlight` constructor. Unknown, duplicate, absent, stale, or impossible identities poison the generation; they never create state or resurrect a settled request.

## 3. Every physical query step is checked

For ordinary operations expected autocommit is true; transaction actions expect false. Worker checks `database.isTransaction`:

1. immediately before and after prepare/bind execution;
2. immediately before and after every `iterator.next()`;
3. immediately before and after `iterator.return()`/reset;
4. before and after begin, rollback, and commit.

Mismatch emits facts, attempts rollback when physically in transaction, closes, and exits. A writable iterator remains potentially mutating until parent Elm observes terminal `QueryDone` **including reset acknowledgement**. Partial row delivery, `QueryStop`, cancellation, or lost terminal acknowledgement is `OperationOutcomeUnknown` on writable DB.

Uniform rule: **after dispatch, any potentially mutating operation without its matching terminal acknowledgement observed by parent Elm has unknown outcome.** No inference from child exit, expected rollback, error text, or absent rows weakens this.

## 4. Physically bounded admission and numeric fairness

The manager has maximum 8 active database workers, 256 physically stored queued requests/database, and 1024 globally. Queues contain compact request ids in front/back arrays plus a `Dict RequestId Request`; cancellation removes both the request and its queue node with an indexed bounded deque implementation—no tombstones. A property asserts physical node count equals live queued count.

Per database FIFO is strict. Across databases, deficit round-robin gives each non-empty ready database one quantum per round. An ordinary request costs one quantum. A collection/transaction reserves one worker but is limited to 1,000 instructions, 100,000 rows, and 30 seconds by defaults (all configurable downward); after admission, at most `activeDatabaseCount - 1` other ordinary quanta precede its next dispatch, hence at most 7. If the queue/wall bound cannot be accepted, admission returns `AdmissionRejected`; the package does not promise scheduler latency while another finite exclusive transaction physically occupies the same SQLite connection.

## 5. Two-hop credit protocol

Parent↔supervisor and supervisor↔worker each negotiate independent byte and message credits. Initial credits are no more than two fixed headers plus one maximum row/request frame per direction. A sender may write a frame only with both message and byte credit. Pipe `drain` is additionally required; it is not itself credit.

Credit is replenished only after the receiver validates, consumes, and drops the credited frame, and—on the supervisor hop—only after downstream has accepted/disposed its corresponding frame. Rows use one-demand/one-row credit end to end. The supervisor never acknowledges parent row/request credit merely for buffering. Each endpoint retains at most one in-progress validated frame plus one credited outbound frame; aggregate protocol retention is the sum of negotiated fixed caps.

Frames, canonical Int64, strict UTF-8, blobs, CRC, generation checks, and tags remain as specified in 03. Both hop decoders are independently fuzzed.

## 6. Honest outer memory boundary

Protocol memory is hard bounded. SQLite/native worker RSS is **not** hard bounded by row meters. V1 initially uses a measured kill boundary:

- worker starts with a bounded V8 old-space option;
- supervisor samples Linux `/proc/<pid>/status` RSS every 25 ms while work runs;
- soft threshold requests termination; hard threshold immediately uses `SIGKILL`;
- observed RSS may overshoot by allocation rate × 25 ms plus kernel accounting lag;
- outcome uses the uniform unknown-mutating rule.

This is called `WorkerMemoryGuard`, never a memory cap. CI measures peak and overshoot. If deployment provides delegated cgroup v2, an optional launcher may set `memory.max` and report `CgroupLimited`; absence is not silently presented as equivalent. `setrlimit` is not claimed from pure Node. Extensions/custom functions are absent; SQLite page cache and temp-store settings are explicit options and reported facts.

## 7. Process, WAL, busy, and death

Persistent topology, ownership records, `/proc` start-identity checks, responsive supervisor, process-group kill ladder, and stale orphan reaping remain from 03. Parent EOF makes supervisor kill/reap a blocked worker. Parent also maintains a backstop registry and reaps supervisor groups it owns after crash detection.

SQLite owns WAL recovery. Package never unlinks WAL/SHM on crash. Busy timeout is finite and blocks only worker; numeric BUSY/LOCKED codes surface without retry. New worker generation opens/reports actual PRAGMAs before queued work resumes. Conflicting immutable options for one database key reject.

## 8. Implementation and integration gate

Implementation must include the broad API, parent Elm effect manager, internal ids, versioned two-hop supervisor/worker protocol, bounded iterators, typed errors, crash recovery, tests, benchmarks, archive/provenance gates, and self-audit.

No harness integration branch starts before:

1. broad package implementation is committed and pushed;
2. all package tests pass on final commit;
3. `07-self-audit.md` is committed;
4. an independent package audit accepts it.

Only then: cron differential/cutover evidence first, session-index second. No production dual authority and no deployment from integration branches.
