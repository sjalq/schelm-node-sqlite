# schelm-node-sqlite

Typed, bounded SQLite programs for Schelm on Node.js.

The public API is callback-based `Cmd`: `execute`, `queryAll`, `queryOne`,
`queryMaybe`, `transaction`, `close`, and explicit `cancel`. Inspect `Error`
with `errorKind`, `errorMessage`, and `errorCode`. `transactionAndThen` can
change the program result type, so execute-then-query in one transaction is
expressible. Elm owns operation identity, queues, decoding, transaction
continuations, and settlement. SQLite runs only in a persistent supervised child
process; the Elm/Node application thread never enters `DatabaseSync`. Call
`close` when the database is finished so the supervisor child is released and
the Node event loop can exit.

See [`docs/recipes/cron-and-index.md`](docs/recipes/cron-and-index.md) for normal
cron-store and search-index patterns. Design constraints and failure semantics
are frozen in `docs/design/05-design-revision-b.md` and
`docs/design/07-execution-manager-addendum.md`. The 1.0.3 done-frame contract,
tolerant decoding, begin-rollback, `close`, FIFO `Cmd.batch`, and the typed
`transactionAndThen` change are in
[`docs/design/08-1.0.3-frame-contract.md`](docs/design/08-1.0.3-frame-contract.md).

## Runtime contract

- Node 24.4.1 / SQLite 3.50.2 is the pinned runtime.
- Up to eight database workers; one physical operation per database.
- Queue limits: 256 per database and 1024 globally.
- Query collections are row/byte bounded; transactions are instruction bounded.
- WAL recovery is SQLite-owned. BUSY/LOCKED is surfaced without retry.
- Cancellation kills the process boundary. A dispatched potentially-mutating
  request without terminal acknowledgement is `OperationOutcomeUnknown`; a
  commit/rollback acknowledgement race is `TransactionOutcomeUnknown`.
- Protocol retention is bounded. Worker RSS is sampled every 25 ms and guarded,
  not described as a hard memory cap.

This package intentionally does not expose connections, statements, cursors,
or transaction tokens.

## Verify a release candidate

```sh
node scripts/verify.cjs
node scripts/schelm-gate.cjs
```

`verify.cjs` is the self-contained Linux Elm 0.19.2 gate: Elm Int64/API/decoder
assertions, the deterministic 200-caller scheduler model, framed-transport and
SQLite failure suites, performance evidence, pinned compiler debug/optimized
overlays (including `Cmd.map`), canonical kernel assembly, and two
byte-identical package archives. x64 uses the hash-verified vendored compiler;
arm64 builds the same pinned commit/tree from the repository-vendored compiler
bundle.

`schelm-gate.cjs` is the 1.0.3 Schelm compiler gate. It sets `SCHELM_HOME` to a
temporary directory (never `~/.schelm`) and runs `~/.local/bin/schelm make
--no-wire` in debug and `--optimize`. Both bundles execute `queryAll`,
`queryOne`, `queryMaybe`, `transaction` (execute then query), FIFO `Cmd.batch`,
and `close`, then must exit naturally. See
[`docs/design/07-self-audit.md`](docs/design/07-self-audit.md) for the
package-completion audit and its deliberately stated residuals.
