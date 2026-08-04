# 07 — Package completion self-audit

Audit target: `sjalq/schelm-node-sqlite` 1.0.0 on Node 24.4.1 / SQLite
3.50.2. This audit closes the blockers recorded by the earlier in-progress
version. It approves **package completion only**; harness integration still
requires an independent audit.

## Closed implementation blockers

- The parent Elm effect manager owns admission, opaque operations, physical
  queues, per-database FIFO, a global ready-ring (one database quantum per
  round), an eight-worker pool, idle-worker rotation, callback acknowledgement,
  and cancellation settlement.
- Queue nodes are physically bounded at 256/database and 1024/global. Rejection
  still emits `onStarted` followed by exactly one `AdmissionRejected` terminal
  callback. Queued cancellation physically removes its node and emits
  `CancelledBeforeDispatch`.
- Dispatched cancellation kills the process group, settles with the appropriate
  unknown-outcome classification, and starts a fresh supervisor/worker
  generation before queued work resumes.
- Parent↔supervisor and supervisor↔worker use the same frozen v1 binary envelope:
  `SQL1` magic, version, payload length, CRC-32, strict JSON payload, and an 8 MiB
  structural cap. Each hop allows one outstanding message. Supervisor credit is
  returned only after downstream or parent disposal.
- Queries are worker iterators. `columns` does not step; each `demand` causes at
  most one `iterator.next()` and one `row`. The next demand is sent only after
  the prior row reaches and is retained by parent Elm. Row/byte overflow calls
  `iterator.return()` and checks autocommit before settlement.
- Potentially mutating requests that lose terminal acknowledgement settle as
  `OperationOutcomeUnknown`; commit/rollback acknowledgement loss settles as
  `TransactionOutcomeUnknown`.
- Worker V8 old-space is bounded, Linux RSS is sampled every 25 ms, the hard
  guard kills the worker process group, and supervisor/worker exits are reaped.
  Parent IPC death runs the TERM→KILL ladder.
- SQLite owns WAL recovery; the package never removes `-wal` or `-shm`.
  BUSY/LOCKED is numeric and not retried.
- The broad pure API and complete decoder API remain exposed. The debug and
  optimized application overlays compile, including an explicit `Cmd.map` over
  a SQLite command.

## Executable evidence

`node scripts/verify.cjs` is the package gate. It verifies canonical kernel
assembly, runs Node tests, compiles debug and optimized overlays with the pinned
Elm 0.19.2 compiler, builds two isolated deterministic archives, and compares
archive hashes.

The checked suites cover:

- real execute/query, significant SQL tail, one-demand/one-row, exact collection
  overflow, WAL crash recovery, BUSY, RSS kill/reap, and parent death;
- a deterministic independent 100,000-step model using 200 logical caller ids,
  physical queue accounting, cancellation, FIFO, overflow, and round-robin;
- CRC corruption fuzz over every bit of a representative frame;
- cold and warm p50/p95/p99 evidence with a portable regression ceiling;
- Linux x64 and arm64 CI declarations.

## Honest residuals

The process protocol is hard-bounded; SQLite/native RSS remains a measured kill
boundary, not a memory cap. CI arm64 evidence is produced by the hosted runner,
not this x64 workstation. The deterministic model/fuzz suite is independent of
manager implementation but is not a formal proof. Idle rotation is demand
triggered rather than timer based: a ninth database rotates an idle worker when
scheduler work is next evaluated.

No package-completion blocker from the prior audit remains. The branch is ready
for independent package audit and is **not yet approved for harness
integration**.
