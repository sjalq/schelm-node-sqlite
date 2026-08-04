# 04 — Adversarial review B

Verdict: **reject revision A until one final narrowing**. Revision A fixes escaping handles and identifies the right process boundary, but several remaining claims are not yet executable contracts.

## B1. Construction has two competing validators

Revision A says `command : Sql -> Bindings -> Result SqlError Command`, yet exact one-statement validity ultimately requires SQLite prepare in the worker. A pure constructor cannot prove placeholder count, accepted syntax, or prepare tail. Either construction is pure/cooperative and worker validation is authoritative, or construction performs an effect. Do not return `Result` as if lexical acceptance proved execution validity.

Final design must state one contract: `sql`, `command`, and `query` are total pure descriptions after cheap bounded shape validation; worker prepare is authoritative and returns typed `InvalidSql`/`BindingMismatch`. Transaction-control lexical rejection is a conservative pure guard, while autocommit observation is the physical backstop.

## B2. Transaction failure cannot be `String`

`transactionFail : String -> TransactionProgram a` loses an application's typed domain reason and encourages message parsing. Parameterize the program: `TransactionProgram domainError a`; `transactionFail : e -> TransactionProgram e a`; settlement returns `Result (TransactionFailure e) a` inside the SQL task result or an equivalent non-conflating shape. SQL/process failure and deliberate domain rollback must remain distinct.

## B3. Decode is still not a complete ergonomic module

The proposed decoder list is too small for broad use and underspecifies errors. It needs `map4` through at least `map8`, `apply`, indexed path accumulation, `oneOf` only if failures remain bounded/deterministic, access to raw `Value`, and a fold/list recipe. JSON is TEXT/BLOB application data, so document an ordinary `Json.Decode.decodeString` recipe rather than importing JSON policy into the kernel package.

Errors must preserve a non-empty path (`Field name`, `Index n`, composition steps), expected storage class, actual class, and bounded caller failure—not only one location. Duplicate field names must identify ambiguity without row contents.

## B4. Per-operation autocommit checks miss iterator mutation

A writable query can mutate through `RETURNING`, user schema effects, or cooperative SQL. Checking `isTransaction` only before query start and after query completion misses state drift between physical steps and reset. The worker must check expected autocommit immediately before and after every `iterator.next()`, and immediately before and after `iterator.return()`/reset acknowledgement. A writable iterator remains potentially mutating and unknown until its terminal reset/`QueryDone` acknowledgement is observed by parent Elm.

## B5. Fairness has adjectives, not a numeric guarantee

“Round robin” and finite transactions do not state maximum delay. Choose a number. With eight workers and bounded queues, ordinary operations need a maximum number of other admitted quanta before dispatch, or admission must reject when that bound cannot be met. Long transactions/collections cannot silently consume unbounded time; enforce instruction, row, and wall meters. Physical queues must be bounded structures; tombstones retain abandoned payloads and can make a nominally bounded queue physically unbounded under cancel churn.

## B6. Backpressure is only one-hop

Parent→supervisor and supervisor→worker are two independent pipe hops. A credit on the worker hop does not prevent the supervisor buffering unlimited parent frames, and `drain` alone does not bound application-level queued frames. Define credits independently on both hops, including row and request credits, credit replenishment only after downstream disposal, and maximum bytes retained at each endpoint.

## B7. Worker RSS is not bounded by protocol frames

SQLite can consume memory internally for sort, temp structures, page cache, recursive queries, and extensions even when one returned row is tiny. The design claims bounded resources but provides no outer memory boundary. Node 24 offers process V8 limits, but native SQLite memory is outside V8. Use a Linux cgroup v2/rlimit wrapper if available, or make the honest v1 claim: protocol retention is bounded, worker RSS is measured and guarded by a supervisor kill threshold with sampling lag and overshoot explicitly documented—not hard bounded. Never call the latter a memory cap.

## B8. Unknown outcomes must be mechanically uniform

The table is close but must say one rule: after dispatch, every operation classified potentially mutating whose terminal acknowledgement is not observed is unknown. This includes command failure frames lost in transit, writable query partial rows, iterator stop/reset, transaction rollback/commit, schema-changing PRAGMAs, and cancellation. No special-case inference from process exit, expected rollback, or missing row is allowed.

## B9. Parent interpreter/resource ids need a total type model

Revision A says ids are internal but does not show which owner mints/maps them. Final design must define parent request id, database generation, supervisor generation, worker generation, transaction id, statement id, and cursor id once, all internal. Each response is accepted only when every relevant generation/id matches the unique expected state; mismatch poisons without dictionary insertion or accidental resurrection.

## B10. API examples have not compiled

The examples contain hand-waved `validatedJobByIdSql` and uncertain `Result` signatures. Before design freeze, compile a test-only package and application in debug and optimize using the private compiler. Include ordinary query, JSON decode recipe, typed domain rollback, transaction dependency, migration commands, and bounded list examples. The final signatures must be copied from that passing fixture.

## B11. Test plan needs provenance and 200-session scale

The final plan must name deterministic seeds, fixture timeouts, final-commit provenance generation, archive/artifact gates, old-host/new-package compatibility, and a 200-session/8-worker queue test. Crash tests must cover WAL recovery, busy lock, parent death, supervisor death, worker death, every acknowledgement cut point, and orphan reaping. Cron and index differentials must be package tests only; harness integration remains blocked until independent package audit.

## Required final revision

1. one pure-description/worker-validation contract;
2. typed domain transaction failure;
3. complete Decode API and recipes;
4. autocommit checks around every physical iterator step and reset;
5. numeric fairness/admission with physically bounded queues and no tombstones;
6. explicit two-hop credits and byte retention;
7. honest worker-RSS boundary;
8. uniform unknown-mutating rule;
9. one internal id/generation model;
10. real debug/optimize compile-tested examples;
11. complete property/model/crash/performance/provenance plan;
12. no harness integration before implementation self-audit and an independent package audit.
