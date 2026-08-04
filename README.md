# schelm-node-sqlite

Typed, bounded SQLite programs for Schelm on Node.js.

The public API is callback-based `Cmd`: `execute`, `queryAll`, `queryOne`,
`queryMaybe`, `transaction`, and explicit `cancel`. Elm owns operation identity,
queues, decoding, transaction continuations, and settlement. SQLite runs only in
a persistent supervised child process; the Elm/Node application thread never
enters `DatabaseSync`.

See [`docs/recipes/cron-and-index.md`](docs/recipes/cron-and-index.md) for normal
cron-store and search-index patterns. Design constraints and failure semantics
are frozen in `docs/design/05-design-revision-b.md` and
`docs/design/07-execution-manager-addendum.md`.

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
```

The self-contained gate runs Elm Int64/API/decoder assertions, the deterministic
200-caller scheduler model, framed-transport and SQLite failure suites,
performance evidence, pinned Elm 0.19.2 debug/optimized runtime and broad API
overlays (including `Cmd.map`), canonical kernel assembly, and two byte-identical
package archives. x64 uses the hash-verified vendored compiler; arm64 builds the
same pinned commit/tree from the repository-vendored compiler bundle. See [`docs/design/07-self-audit.md`](docs/design/07-self-audit.md)
for the package-completion audit and its deliberately stated residuals.
