# 07 — Self-audit (in progress)

This is an honest implementation audit, not release acceptance.

## Implemented

- callback `Cmd` surface and recursive `cmdMap` over start/finish producers;
- parent-Elm operation ownership, per-database serialization, physical removal
  on cancellation, 8-worker/256-per-db/1024-global constants;
- persistent supervisor and SQLite worker processes (no application-thread
  `DatabaseSync` shortcut), parent EOF kill ladder, WAL, finite busy timeout;
- protocol version/id checks, one-message credits on both process hops, fixed
  frame cap, iterator row/byte meter and per-step autocommit checks;
- transaction instruction meter and typed domain rollback;
- uniform mutating-loss and commit/rollback unknown classifications;
- `/proc` RSS sampling, guard kill, and child reaping;
- real SQLite execute/query and significant-tail tests.

## Known gaps blocking acceptance

- manager scheduling is per-database FIFO but not yet the specified global
  deficit round-robin fairness model;
- queue overflow presently cannot emit its promised terminal callback cleanly;
- transport uses structured Node IPC rather than the frozen CRC binary framing,
  and downstream-disposal credit proof is incomplete;
- query rows are collected in the worker rather than one-demand/one-row parent
  decode flow;
- cancellation callback semantics and worker replacement require completion;
- transaction wall/row meters, idle eviction, generation identities, WAL crash,
  BUSY, parent-death, 200-session, optimized `Cmd.map`, fuzz/property, archive,
  arm64, and performance gates remain incomplete;
- private overlay application dependency resolution is currently blocking the
  generated debug/optimize fixture despite direct installed-package compilation.

Therefore this branch is **not package-complete and not approved for harness
integration**. An independent audit has not been requested.
