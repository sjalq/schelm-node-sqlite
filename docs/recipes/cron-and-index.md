# Cron and index recipes

## Cron store

Use one `Options` value per database path, WAL mode (set by the worker), and a
single `Immediate` transaction for lease acquisition plus state update. Keep
lease selection and update in one `TransactionProgram`; never read and later
write in separate commands. Persist timestamps as canonical integer/text data
according to application policy. Treat `Busy` as contention and schedule a new
application attempt; the package never retries. Treat `TransactionOutcomeUnknown`
as reconciliation-required, not as permission to replay blindly.

## Session/search index

Keep the journal authoritative and SQLite reconstructable. Batch finite index
updates in a transaction. Bound reads with `CollectionLimit`, select explicit
columns, and decode them by name. Store source revision/event ids with each row
so unknown outcomes can be reconciled idempotently. Schema migration is an
application-owned ordered list of cooperative `Command` values guarded by
`PRAGMA user_version`; it runs before normal index operations.

## Cancellation

Save the `Operation` from `onStarted` only when the UI or scheduler needs to
cancel. `cancel operation` is explicit. Disappearance of a prior `Cmd` does not
mean cancellation. Before dispatch cancellation has no SQLite effect; after
dispatch a mutating operation may settle unknown.
